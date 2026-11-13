local t = require "skytest"

local critical = require "skyext.critical"
local maintenance = require "skyext.critical_maintenance"

-- 每个参数是一页（文档数组）。用可变参数而不是单表：`fake_coll({ { rid = 1 } })`
-- 里的外层大括号只是"一个页面"，单表参数会把它当成页面列表本身
local function fake_coll(...)
    local pages = { ... }
    local coll = { calls = {} }
    function coll:find_many(query, opts)
        self.calls[#self.calls + 1] = { query = query, opts = opts }
        return pages[#self.calls] or {}
    end
    return coll
end

t.describe("critical_maintenance 归档滞后口径", function()
    t.it("only measures the delay past the retention window", function()
        -- 扫描候选必然已超期；now - oldest 会恒 >= retention，必须减掉保留期
        t.expect(maintenance.archive_lag(100, 1000, 500)).to.equal(400)
        t.expect(maintenance.archive_lag(500, 1000, 500)).to.equal(0)
        -- 时钟回拨/异常候选不能产生负滞后
        t.expect(maintenance.archive_lag(900, 1000, 500)).to.equal(0)
    end)
end)

t.describe("critical_maintenance 扫描", function()
    t.it("queries roles whose oldest hot op is past the retention window", function()
        local coll = fake_coll({ { rid = 1, [critical.OPS_OLDEST_FIELD] = 100 } })
        local list = assert(maintenance.scan_archive(coll, { now = 1000, retention = 500 }))
        t.expect(#list).to.equal(1)
        t.expect(list[1].rid).to.equal(1)
        -- 走索引字段，不是全表扫描
        t.expect(coll.calls[1].query[critical.OPS_OLDEST_FIELD]["$lte"]).to.equal(500)
    end)

    -- 卡住的文档不会离开候选集：不轮转的话它会永远占住前 limit 个名额，
    -- 后面的角色一个都排不进来，最终撞上 MAX_OPS 后该角色所有关键操作被拒
    t.it("rotates the archive scan so stuck documents cannot starve the rest", function()
        local page1 = {
            { rid = 1, [critical.OPS_OLDEST_FIELD] = 100 },
            { rid = 2, [critical.OPS_OLDEST_FIELD] = 101 },
        }
        local page2 = { { rid = 3, [critical.OPS_OLDEST_FIELD] = 102 } }
        -- 顺序：第一轮 archive -> intents；第二轮 archive -> intents
        local coll = fake_coll(page1, {}, page2, {})
        local deps = {
            role_coll = coll,
            archive = function()
                return true, { archived = 0 }
            end,
            ensure_job = function() end,
        }
        local opts = { now = 1000, retention = 500, limit = 2 }

        assert(maintenance.run_once(deps, opts))
        t.expect(coll.calls[1].opts.skip).to.equal(0)
        -- 满页：游标翻到下一页
        t.expect(deps.archive_cursor).to.equal(2)

        assert(maintenance.run_once(deps, opts))
        t.expect(coll.calls[3].opts.skip).to.equal(2)
        -- 不满页：回到开头，下一轮从第一个角色重新开始
        t.expect(deps.archive_cursor).to.equal(0)
    end)

    t.it("queries roles that still hold a PREPARED intent", function()
        local coll = fake_coll({
            { rid = 2, [critical.INTENT_FIELD] = { op_id = "srv_x", prepared_at = 10 } },
        })
        local list = assert(maintenance.scan_intents(coll))
        t.expect(#list).to.equal(1)
        t.expect(list[1].op_id).to.equal("srv_x")
        t.expect(coll.calls[1].query[critical.INTENT_FIELD .. ".state"]).to.equal("PREPARED")
    end)

    t.it("rotates prepared intents with a keyset cursor", function()
        local first = {
            { rid = 1, [critical.INTENT_FIELD] = { op_id = "srv_a" } },
            { rid = 2, [critical.INTENT_FIELD] = { op_id = "srv_b" } },
        }
        local second = {
            { rid = 3, [critical.INTENT_FIELD] = { op_id = "srv_c" } },
        }
        local coll = fake_coll(first, second)

        local page, err = maintenance.scan_intents(coll, { limit = 2 })
        t.expect(err).to.be_nil()
        t.expect(page[2].rid).to.equal(2)
        t.expect(coll.calls[1].opts.sort[1].rid).to.equal(1)

        local next_page, next_err = maintenance.scan_intents(coll, { limit = 2, cursor = 2 })
        t.expect(next_err).to.be_nil()
        -- rid <= 2 的意图已经处理过，下一页必须从 3 开始，否则卡住的角色会反复占位
        t.expect(coll.calls[2].query["$and"][1].rid["$gt"]).to.equal(2)
        t.expect(next_page[1].rid).to.equal(3)
    end)

    t.it("ignores documents without a usable intent", function()
        local coll = fake_coll({ { rid = 3, [critical.INTENT_FIELD] = { state = "PREPARED" } } })
        local list = assert(maintenance.scan_intents(coll))
        t.expect(#list).to.equal(0)
    end)

    t.it("reports a scan failure instead of an empty page", function()
        local ok, err = maintenance.scan_archive({
            find_many = function()
                error("mongo down")
            end,
        })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("mongo down")
    end)

    t.it("requires a role collection", function()
        t.expect(maintenance.scan_archive(nil)).to.be_nil()
        t.expect(maintenance.scan_intents(nil)).to.be_nil()
    end)
end)

t.describe("critical_maintenance 单轮", function()
    t.it("archives candidates and ensures a job for every prepared intent", function()
        -- 两次扫描各取一页：归档候选、未决意图
        local coll = fake_coll(
            { { rid = 1, [critical.OPS_OLDEST_FIELD] = 100 } },
            { { rid = 2, [critical.INTENT_FIELD] = { op_id = "srv_a" } } }
        )
        local archived, ensured = {}, {}
        local stats = assert(maintenance.run_once({
            role_coll = coll,
            archive = function(rid)
                archived[#archived + 1] = rid
                return true, { archived = 3 }
            end,
            ensure_job = function(rid, op_id)
                ensured[#ensured + 1] = { rid = rid, op_id = op_id }
                return true, { task_id = "t" }
            end,
        }, { now = 1000 }))
        t.expect(stats.archived).to.equal(3)
        t.expect(stats.intents).to.equal(1)
        t.expect(archived[1]).to.equal(1)
        t.expect(ensured[1].op_id).to.equal("srv_a")
    end)

    t.it("uses scan_limit for both scans and archive_limit for the per-role archive", function()
        local coll = fake_coll(
            { { rid = 1, [critical.OPS_OLDEST_FIELD] = 100 } },
            { { rid = 2, [critical.INTENT_FIELD] = { op_id = "srv_a" } } }
        )
        local archive_limit
        local stats = assert(maintenance.run_once({
            role_coll = coll,
            archive = function(_, limit)
                archive_limit = limit
                return true, { archived = 0 }
            end,
            ensure_job = function()
                return true
            end,
        }, { scan_limit = 1, archive_limit = 7, now = 1000 }))
        t.expect(stats.intents).to.equal(1)
        t.expect(coll.calls[1].opts.limit).to.equal(1)
        t.expect(coll.calls[2].opts.limit).to.equal(1)
        t.expect(archive_limit).to.equal(7)
    end)

    t.it("counts a failing archive as failed and keeps going", function()
        local coll = fake_coll({ { rid = 1, [critical.OPS_OLDEST_FIELD] = 100 } })
        local stats = assert(maintenance.run_once({
            role_coll = coll,
            archive = function()
                error("entity lease expired")
            end,
        }, {}))
        t.expect(stats.failed).to.equal(1)
        t.expect(stats.archived).to.equal(0)
    end)

    t.it("skips when the owner entry is not provided", function()
        local coll = fake_coll({ { rid = 1, [critical.OPS_OLDEST_FIELD] = 100 } })
        local stats = assert(maintenance.run_once({ role_coll = coll }, {}))
        t.expect(stats.skipped).to.equal(1)
    end)

    t.it("requires a role collection", function()
        t.expect(maintenance.run_once({}, {})).to.be_nil()
    end)
end)

t.describe("critical_maintenance 配置校验", function()
    t.it("accepts positive integer limits", function()
        t.expect(maintenance.validate_opts({
            interval = 1,
            scan_limit = 1,
            archive_limit = 1,
            reconcile_scan = 1,
            reconcile_lease = 1,
        })).to
            .equal(true)
    end)

    t.it("rejects zero interval and zero limits", function()
        local ok, err = maintenance.validate_opts({
            interval = 0,
            scan_limit = 1,
            archive_limit = 1,
            reconcile_scan = 1,
            reconcile_lease = 1,
        })
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("interval")

        ok, err = maintenance.validate_opts({
            interval = 1,
            scan_limit = 0,
            archive_limit = 1,
            reconcile_scan = 1,
            reconcile_lease = 1,
        })
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("scan_limit")
    end)
end)

-- 探针入口：语义在 mongo_conn，这里只保证"结果不被吞、原因不丢"
t.describe("critical_maintenance 多数派探针", function()
    local function probe_coll(result, err)
        local coll = {}
        function coll:critical_probe()
            if result == "raise" then
                error("socket closed")
            end
            return result, err
        end
        return coll
    end

    t.it("passes a confirmed probe through with the collection it checked", function()
        local ok, info = maintenance.probe({
            collection = probe_coll(true),
            type_name = "role",
            collection_name = "role.role",
        })
        t.expect(ok).to.equal(true)
        t.expect(info.type_name).to.equal("role")
        t.expect(info.collection).to.equal("role.role")
    end)

    t.it("surfaces the probe's reason instead of a generic failure", function()
        local ok, err = maintenance.probe({
            collection = probe_coll(nil, "probe majority write not confirmed (UNKNOWN): not majority"),
        })
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("not confirmed")
    end)

    t.it("turns a raised probe into a readable failure", function()
        local ok, err = maintenance.probe({ collection = probe_coll("raise") })
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("probe raised")
    end)

    t.it("refuses a collection without the probe channel", function()
        local ok, err = maintenance.probe({ collection = {} })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("collection has no critical_probe")
        t.expect(maintenance.probe({})).to.equal(false)
    end)
end)
