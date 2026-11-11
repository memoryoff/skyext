local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local orm = require "orm"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/outbox.lua")

local function role_schema()
    local self = {
        type = "struct",
        rid = { type = "integer" },
        _version = { type = "integer" },
        gold = { type = "integer" },
    }
    local names = { "_version", "gold", "rid" }
    function self.fields()
        return names
    end
    function self:_parse_k(k)
        assert(self[k], "unknown key: " .. tostring(k))
        return k
    end
    function self:_check_k(k)
        self:_parse_k(k)
    end
    function self:_check_kv(_, value)
        assert(type(value) == "number")
    end
    function self.new(data)
        return orm.new(self, data)
    end
    return self
end

local EVENT = "evt_" .. string.rep("a", 64)
local HASH = string.rep("b", 64)

-- 假 dbmgr：实现 outbox 依赖的 cached_critical / critical_update / set_critical
local function fake_dbmgr(store)
    local M = {}
    function M.cached_critical()
        return store.critical
    end
    function M.set_critical(_, _, _, value)
        store.critical = value
        return true
    end
    function M.critical_update(_, _, _, _, expected, update, opts)
        store.cas = store.cas or {}
        store.cas[#store.cas + 1] = { expected = expected, update = update, opts = opts }
        if store.unknown then
            return "UNKNOWN", store.unknown
        end
        if store.reject then
            return "REJECTED", "cas mismatch"
        end
        if store.doc._version ~= expected then
            return "REJECTED", "version mismatch"
        end
        assert(orm.advance_persisted_version(store.doc, expected, expected + 1))
        return "CONFIRMED", { version = expected + 1, n = 1, nModified = 1 }
    end
    return M
end

local function harness()
    local doc = orm.new(role_schema(), { rid = 7, _version = 0, gold = 100 })
    local store = { doc = doc, critical = {} }
    local h = { doc = doc, store = store, now = 1700000000 }
    h.dbmgr = fake_dbmgr(store)
    h.ctx = {
        dbname = "demo",
        dbcoll = "role",
        key = "rid",
        unique_id = 7,
        handle = { fence = 5, valid = true },
        doc = doc,
    }
    local env = setmetatable({
        require = function(name)
            if name == "skyext.dbmgr" then
                return h.dbmgr
            end
            if name == "skyext.log" then
                return { debug = function() end, info = function() end, warn = function() end, error = function() end }
            end
            return require(name)
        end,
    }, { __index = _G })
    h.outbox = assert(loadfile(source, "t", env))()

    function h.event(over)
        local opts = {
            event_id = EVENT,
            target_type = "role",
            target_id = 9,
            op_type = "mail.send",
            param_hash = HASH,
            payload = { item = 1 },
            now = h.now,
        }
        for k, v in pairs(over or {}) do
            opts[k] = v
        end
        return h.outbox.event(opts)
    end

    function h.seed(events, count)
        local outbox = {}
        for _, e in ipairs(events) do
            outbox[e.event_id] = e
        end
        h.store.critical = {
            _critical_outbox_v1 = outbox,
            _critical_outbox_pending_count = count or #events,
        }
    end

    return h
end

t.describe("outbox 事件与信封", function()
    t.it("generates a stable-format event id", function()
        local h = harness()
        local id = assert(h.outbox.new_event_id(function(n)
            return string.rep("\1", n)
        end))
        t.expect(#id).to.equal(68)
        t.expect(id:sub(1, 4)).to.equal("evt_")
        t.expect(id:sub(5)).to.equal(string.rep("01", 32))
    end)

    t.it("refuses a random source that returns the wrong size", function()
        local h = harness()
        t.expect(h.outbox.new_event_id(function()
            return "short"
        end)).to
            .be_nil()
    end)

    t.it("builds an event and validates its fields", function()
        local h = harness()
        local event = assert(h.event())
        t.expect(event.status).to.equal(h.outbox.STATUS.PENDING)
        t.expect(event.attempt).to.equal(0)
        t.expect(h.event({ event_id = "bad" })).to.be_nil()
        t.expect(h.event({ target_type = "" })).to.be_nil()
        t.expect(h.event({ op_type = "" })).to.be_nil()
        t.expect(h.event({ param_hash = "short" })).to.be_nil()
    end)

    t.it("wraps an event in an envelope that survives validation", function()
        local h = harness()
        local event = assert(h.event())
        local env = assert(h.outbox.envelope(event, { type = "role", id = 7 }))
        t.expect(env.version).to.equal(1)
        t.expect(env.event_id).to.equal(EVENT)
        t.expect(env.source_type).to.equal("role")
        t.expect(env.source_id).to.equal(7)
        t.expect(h.outbox.validate_envelope(env)).to.equal(true)
        -- 业务键是 event_id 的字节级映射
        t.expect(h.outbox.service_op_id(env)).to.equal("srv_" .. string.rep("a", 64))
    end)

    t.it("rejects a malformed envelope", function()
        local h = harness()
        local event = assert(h.event())
        local base = assert(h.outbox.envelope(event, { type = "role", id = 7 }))
        local function mutate(over)
            local copy = {}
            for k, v in pairs(base) do
                copy[k] = v
            end
            for k, v in pairs(over) do
                copy[k] = v
            end
            return copy
        end
        t.expect(h.outbox.validate_envelope(nil)).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ version = 2 }))).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ event_id = "evt_short" }))).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ target_type = "" }))).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ param_hash = "x" }))).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ source_type = "" }))).to.be_nil()
        -- nil 不会出现在 pairs 里，必须显式删
        local no_source = mutate({})
        no_source.source_id = nil
        t.expect(h.outbox.validate_envelope(no_source)).to.be_nil()
    end)
end)

t.describe("outbox 状态推进", function()
    t.it("lists pending events in creation order", function()
        local h = harness()
        local older = assert(h.event({ event_id = "evt_" .. string.rep("1", 64), now = 10 }))
        local newer = assert(h.event({ event_id = "evt_" .. string.rep("2", 64), now = 20 }))
        local done = assert(h.event({ event_id = "evt_" .. string.rep("3", 64), now = 5 }))
        done.status = h.outbox.STATUS.DELIVERED
        h.seed({ newer, older, done })

        local pending = h.outbox.pending_events(h.store.critical, 10)
        t.expect(#pending).to.equal(2)
        t.expect(pending[1].event_id).to.equal(older.event_id)
        t.expect(pending[2].event_id).to.equal(newer.event_id)
        t.expect(h.outbox.count_pending(h.store.critical)).to.equal(2)
    end)

    t.it("respects the batch limit", function()
        local h = harness()
        local events = {}
        for i = 1, 5 do
            events[i] = assert(h.event({ event_id = "evt_" .. string.format("%064x", i), now = i }))
        end
        h.seed(events)
        t.expect(#h.outbox.pending_events(h.store.critical, 2)).to.equal(2)
    end)

    -- pending_count 只能减一次：重复推进同一事件不能把它减成负数
    t.it("decrements the pending count exactly once per event", function()
        local h = harness()
        local event = assert(h.event())
        h.seed({ event })

        local next_table = assert(h.outbox.transition(h.store.critical, EVENT, h.outbox.STATUS.ENQUEUED, 100))
        t.expect(next_table._critical_outbox_pending_count).to.equal(0)
        t.expect(next_table._critical_outbox_v1[EVENT].status).to.equal("ENQUEUED")
        t.expect(next_table._critical_outbox_v1[EVENT].attempt).to.equal(1)
        -- 原表不能被就地修改
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("PENDING")

        local again = assert(h.outbox.transition(next_table, EVENT, h.outbox.STATUS.DELIVERED, 101))
        t.expect(again._critical_outbox_pending_count).to.equal(0)
    end)

    t.it("refuses to transition an unknown event", function()
        local h = harness()
        h.seed({})
        t.expect(h.outbox.transition(h.store.critical, EVENT, h.outbox.STATUS.ENQUEUED, 100)).to.be_nil()
    end)
end)

t.describe("outbox 投递", function()
    t.it("delivers, then CASes the status and the pending count", function()
        local h = harness()
        h.seed({ assert(h.event()) })

        local delivered = {}
        local stats = assert(h.outbox.pump(h.ctx, function(env)
            delivered[#delivered + 1] = env
            return true
        end, { now = 100, source = { type = "role", id = 7 } }))

        t.expect(#delivered).to.equal(1)
        t.expect(stats.enqueued).to.equal(1)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("ENQUEUED")
        t.expect(h.store.critical._critical_outbox_pending_count).to.equal(0)
        -- CAS 必须带"该事件仍是 PENDING"的条件，否则另一个 worker 推进过就会重复减计数
        local cas = h.store.cas[#h.store.cas]
        t.expect(cas.opts.extra_query["_critical_outbox_v1." .. EVENT .. ".status"]).to.equal("PENDING")
        t.expect(cas.update["$set"]["_critical_outbox_pending_count"]).to.equal(0)
    end)

    -- 投递未确认时保持 PENDING，允许底层 msg_id 重复，业务靠 event_id 去重
    t.it("keeps the event pending when the delivery is not confirmed", function()
        local h = harness()
        h.seed({ assert(h.event()) })
        local stats = assert(h.outbox.pump(h.ctx, function()
            return false
        end, { now = 100 }))
        t.expect(stats.failed).to.equal(1)
        t.expect(stats.enqueued).to.equal(0)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("PENDING")
        t.expect(#(h.store.cas or {})).to.equal(0)
    end)

    t.it("treats a raising deliver function as an unconfirmed delivery", function()
        local h = harness()
        h.seed({ assert(h.event()) })
        local stats = assert(h.outbox.pump(h.ctx, function()
            error("network down")
        end, { now = 100 }))
        t.expect(stats.failed).to.equal(1)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("PENDING")
    end)

    -- CAS 未命中不是"资产已执行但 ACK 丢失"，只是另一个 worker 先推进了
    t.it("treats a CAS miss as a retry, not as an unknown asset state", function()
        local h = harness()
        h.seed({ assert(h.event()) })
        h.store.reject = "cas mismatch"
        local stats = assert(h.outbox.pump(h.ctx, function()
            return true
        end, { now = 100 }))
        t.expect(stats.failed).to.equal(1)
        t.expect(stats.unknown).to.equal(0)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("PENDING")
    end)

    -- 状态未决时必须停下来：在不确定的文档上继续叠加写入只会让恢复更难
    t.it("stops the batch when the status CAS is unknown", function()
        local h = harness()
        local a = assert(h.event({ event_id = "evt_" .. string.rep("1", 64), now = 1 }))
        local b = assert(h.event({ event_id = "evt_" .. string.rep("2", 64), now = 2 }))
        h.seed({ a, b })
        h.store.unknown = "write concern timeout"

        local calls = 0
        local stats = assert(h.outbox.pump(h.ctx, function()
            calls = calls + 1
            return true
        end, { now = 100 }))
        t.expect(stats.unknown).to.equal(1)
        t.expect(calls).to.equal(1)
    end)

    t.it("does nothing when the document is not loaded", function()
        local h = harness()
        h.store.critical = nil
        local ok, err = h.outbox.pump(h.ctx, function()
            return true
        end)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("document not loaded")
    end)

    t.it("returns an empty result when there is nothing pending", function()
        local h = harness()
        h.seed({})
        local stats = assert(h.outbox.pump(h.ctx, function()
            return true
        end))
        t.expect(stats.enqueued).to.equal(0)
        t.expect(#(h.store.cas or {})).to.equal(0)
    end)
end)
