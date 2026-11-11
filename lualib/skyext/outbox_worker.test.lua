local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/outbox_worker.lua")

local FIELD = "_critical_outbox_pending_count"

-- 假集合：记录查询条件，按注入的页返回文档
local function fake_coll(docs, fail)
    local coll = { calls = {} }
    function coll:find_many(query, opts)
        self.calls[#self.calls + 1] = { query = query, opts = opts }
        if fail then
            error(fail)
        end
        local out = {}
        local skip = (opts and opts.skip) or 0
        local limit = (opts and opts.limit) or #docs
        for i = skip + 1, math.min(#docs, skip + limit) do
            out[#out + 1] = docs[i]
        end
        return out
    end
    return coll
end

local function harness(over)
    over = over or {}
    local h = {
        pumped = {},
        pump_result = function()
            return true, { enqueued = 1, failed = 0, unknown = 0, already = 0, batches = 1, pending = 0 }
        end,
        loaded_result = function()
            return true, { enqueued = 2, failed = 0, unknown = 0, already = 0, batches = 2, pending = 0 }
        end,
    }
    local fake_outbox = {
        DEFAULT_LIMIT = 16,
        PENDING_COUNT_FIELD = FIELD,
        pump = function(ctx, deliver, opts)
            h.pump_call = { ctx = ctx, deliver = deliver, opts = opts }
            if h.pump_returns then
                return h.pump_returns[1], h.pump_returns[2]
            end
            return { enqueued = 1, failed = 0, unknown = 0, already = 0, batches = 1, pending = 3, oldest_age = 42 }
        end,
    }
    local fake_critical = {
        coords_of = function(entity)
            if over.no_coords then
                return nil, "entity has no db coordinates"
            end
            return { dbname = "demo", dbcoll = "role", key = "rid", unique_id = entity.id, doc = {} }
        end,
    }
    local env = setmetatable({
        require = function(name)
            if name == "skyext.outbox" then
                return fake_outbox
            end
            if name == "skyext.critical" then
                return fake_critical
            end
            if name == "skyext.log" then
                return { debug = function() end, info = function() end, warn = function() end, error = function() end }
            end
            return require(name)
        end,
    }, { __index = _G })
    h.mod = assert(loadfile(source, "t", env))()
    return h
end

t.describe("outbox_worker 扫描", function()
    t.it("queries only roles with a positive pending count", function()
        local h = harness()
        local coll = fake_coll({ { rid = 3, [FIELD] = 2 }, { rid = 4, [FIELD] = 1 } })
        local list, next_skip = h.mod.scan(coll, { limit = 10 })
        t.expect(#list).to.equal(2)
        t.expect(list[1].rid).to.equal(3)
        t.expect(list[1].pending).to.equal(2)
        -- 索引字段是查询条件：没有它就只能全表扫描
        t.expect(coll.calls[1].query[FIELD]).to.equal({ ["$gt"] = 0 })
        t.expect(coll.calls[1].opts.limit).to.equal(10)
        -- 这一页没满 -> 下一轮从头开始
        t.expect(next_skip).to.equal(0)
    end)

    t.it("advances the cursor when a page is full", function()
        local h = harness()
        local docs = {}
        for i = 1, 6 do
            docs[i] = { rid = i, [FIELD] = 1 }
        end
        local coll = fake_coll(docs)
        local list, next_skip = h.mod.scan(coll, { limit = 4 })
        t.expect(#list).to.equal(4)
        t.expect(next_skip).to.equal(4)
    end)

    t.it("reports a scan error instead of an empty page", function()
        local h = harness()
        local coll = fake_coll({}, "mongo down")
        local list, err = h.mod.scan(coll)
        t.expect(list).to.be_nil()
        t.expect(err).to.match("mongo down")
    end)

    t.it("rejects a missing collection", function()
        local h = harness()
        t.expect(h.mod.scan(nil)).to.be_nil()
    end)
end)

t.describe("outbox_worker 索引门禁", function()
    t.it("fails the gate when the index build is rejected", function()
        local h = harness()
        local coll = {
            create_index = function()
                return { ok = 0, errmsg = "unauthorized" }
            end,
        }
        local ok, err = h.mod.ensure_indexes({ role = coll })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("unauthorized")
    end)

    t.it("accepts a confirmed index build", function()
        local h = harness()
        local seen
        local coll = {
            create_index = function(_, keys)
                seen = keys
                return true
            end,
        }
        t.expect(h.mod.ensure_indexes({ role = coll })).to.equal(true)
        t.expect(seen.name).to.equal("critical_outbox_pending")
        t.expect(seen.partialFilterExpression[FIELD]).to.equal({ ["$gt"] = 0 })
    end)

    t.it("treats a raising create_index as a failed gate", function()
        local h = harness()
        local coll = {
            create_index = function()
                error("socket closed")
            end,
        }
        local ok, err = h.mod.ensure_indexes({ role = coll })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("socket closed")
    end)
end)

t.describe("outbox_worker 单轮调度", function()
    t.it("pumps every candidate and merges the statistics", function()
        local h = harness()
        local deps = {
            role_coll = fake_coll({ { rid = 1, [FIELD] = 2 }, { rid = 2, [FIELD] = 1 } }),
            pump = function(rid)
                return true, { enqueued = 1, failed = 0, unknown = 0, already = 0, batches = 1, pending = 1 }
            end,
        }
        local stats = assert(h.mod.run_once(deps, {}))
        t.expect(stats.scanned).to.equal(2)
        t.expect(stats.pumped).to.equal(2)
        t.expect(stats.enqueued).to.equal(2)
        t.expect(stats.pending).to.equal(2)
    end)

    t.it("skips roles whose indexed count is already zero", function()
        local h = harness()
        local calls = 0
        local deps = {
            role_coll = fake_coll({ { rid = 1, [FIELD] = 0 } }),
            pump = function()
                calls = calls + 1
                return true, {}
            end,
        }
        local stats = assert(h.mod.run_once(deps, {}))
        t.expect(calls).to.equal(0)
        t.expect(stats.skipped).to.equal(1)
    end)

    -- 实体不在内存时受控加载：离线角色的积压也要能排空，但不能一轮全捞起来
    t.it("falls back to a loading pump within the load budget", function()
        local h = harness()
        local loaded = 0
        local deps = {
            role_coll = fake_coll({ { rid = 1, [FIELD] = 1 }, { rid = 2, [FIELD] = 1 }, { rid = 3, [FIELD] = 1 } }),
            pump = function()
                return false, "entity not loaded"
            end,
            pump_loaded = function()
                loaded = loaded + 1
                return true, { enqueued = 1, failed = 0, unknown = 0, already = 0, batches = 1, pending = 0 }
            end,
        }
        local stats = assert(h.mod.run_once(deps, { max_loads = 2 }))
        t.expect(loaded).to.equal(2)
        t.expect(stats.loads).to.equal(2)
        t.expect(stats.pumped).to.equal(2)
        t.expect(stats.skipped).to.equal(1)
    end)

    t.it("counts a failed pump as skipped instead of failing the round", function()
        local h = harness()
        local deps = {
            role_coll = fake_coll({ { rid = 1, [FIELD] = 1 } }),
            pump = function()
                return false, "boom"
            end,
        }
        local stats = assert(h.mod.run_once(deps, {}))
        t.expect(stats.skipped).to.equal(1)
        t.expect(stats.pumped).to.equal(0)
    end)

    t.it("requires a pump function", function()
        local h = harness()
        t.expect(h.mod.run_once({ role_coll = fake_coll({}) })).to.be_nil()
    end)

    t.it("propagates a scan failure", function()
        local h = harness()
        local ok, err = h.mod.run_once({ role_coll = fake_coll({}, "mongo down"), pump = function() end }, {})
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("mongo down")
    end)
end)

t.describe("outbox_worker 实体内投递", function()
    t.it("builds the pump context from the entity coordinates", function()
        local h = harness()
        local entity = { type_name = "role", id = 7 }
        local stats = assert(h.mod.pump_entity(entity, { limit = 4, now = 100 }))
        t.expect(h.pump_call.ctx.dbname).to.equal("demo")
        t.expect(h.pump_call.ctx.unique_id).to.equal(7)
        t.expect(h.pump_call.opts.limit).to.equal(4)
        t.expect(h.pump_call.opts.source.type).to.equal("role")
        t.expect(h.pump_call.opts.source.id).to.equal(7)
        t.expect(stats.pending).to.equal(3)
        t.expect(stats.type).to.equal("role")
    end)

    t.it("refuses an entity without db coordinates", function()
        local h = harness({ no_coords = true })
        local stats, err = h.mod.pump_entity({ type_name = "role", id = 7 }, {})
        t.expect(stats).to.be_nil()
        t.expect(err).to.equal("entity has no db coordinates")
    end)

    t.it("passes the pump error through", function()
        local h = harness()
        h.pump_returns = { nil, "document not loaded" }
        local stats, err = h.mod.pump_entity({ type_name = "role", id = 7 }, {})
        t.expect(stats).to.be_nil()
        t.expect(err).to.equal("document not loaded")
    end)
end)
