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

    t.it("queries roles that still hold a PREPARED intent", function()
        local coll = fake_coll({
            { rid = 2, [critical.INTENT_FIELD] = { op_id = "srv_x", prepared_at = 10 } },
        })
        local list = assert(maintenance.scan_intents(coll))
        t.expect(#list).to.equal(1)
        t.expect(list[1].op_id).to.equal("srv_x")
        t.expect(coll.calls[1].query[critical.INTENT_FIELD .. ".state"]).to.equal("PREPARED")
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
