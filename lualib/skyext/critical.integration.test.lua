-- 真实 MongoDB 上的关键写入语义。需要 `SKYTEST_INTEGRATION=1`，且本机 Mongo 可用。
--
-- 覆盖的是文档 §4.4.1 的 DDL 门禁与 §3 B1-01 的 CAS 事实：
--   * 索引真的建得出来、unique 真的生效；
--   * `_version` 作为 CAS 谓词时，命中与 miss 的返回结构（n / value）；
--   * 保留字段写入后能原样读回。
-- 单节点副本集下 `w:"majority"` 只证明命令被接受，**不证明**多数派语义；
-- stepdown 与旧 primary 迟到写需要副本集，见 docs/design/p17_verification.md。
local t = require "skytest"
local skynet = require "skynet"

if os.getenv("SKYTEST_INTEGRATION") ~= "1" then
    return
end

local mongo = require "skynet.db.mongo"
local critical = require "skyext.critical"

local unique = string.format("%d_%d_%d", os.time(), skynet.self(), math.random(1, 1000000000))
local dbname = "skyext_critical_it_" .. unique
local h = {}

local function index_capable(coll)
    return {
        create_index = function(_, keys)
            return coll:createIndex(keys)
        end,
    }
end

t.describe("critical 关键写入（真实 MongoDB）", function()
    t.before_all(function()
        local host = os.getenv("MONGO_HOST") or "127.0.0.1"
        local port = tonumber(os.getenv("MONGO_PORT")) or 27017
        h.client = mongo.client({ host = host, port = port })
        h.db = h.client[dbname]
        local ping = h.db:runCommand("ping", 1)
        t.expect(ping.ok).to.equal(1)
        h.role = h.db.role
        h.ledger = h.db.op_ledger
        h.jobs = h.db.critical_reconcile_jobs
    end)

    t.after_all(function()
        if h.db then
            h.db:runCommand("dropDatabase", 1)
        end
    end)

    t.it("builds the DDL indexes and can be re-run idempotently", function()
        local colls = {
            role = index_capable(h.role),
            ledger = index_capable(h.ledger),
            jobs = index_capable(h.jobs),
        }
        t.expect(critical.ensure_indexes(colls)).to.equal(true)
        -- 门禁会在每次启动时跑，必须幂等
        t.expect(critical.ensure_indexes(colls)).to.equal(true)

        local listed = h.db:runCommand("listIndexes", "op_ledger")
        t.expect(listed.ok).to.equal(1)
        local found
        for _, spec in ipairs(listed.cursor.firstBatch) do
            if spec.name == "rid_op_id" then
                found = spec
            end
        end
        t.expect(found ~= nil).to.equal(true)
        t.expect(found.unique).to.equal(true)
    end)

    t.it("enforces the unique (rid, op_id) key on the cold ledger", function()
        local ok = h.ledger:safe_insert({ rid = 7, op_id = "srv_" .. string.rep("a", 64), status = "COMMITTED" })
        t.expect(ok).to.equal(true)
        local dup, err = h.ledger:safe_insert({ rid = 7, op_id = "srv_" .. string.rep("a", 64), status = "COMMITTED" })
        -- werror 的约定是 boolean false + errmsg，不是 nil
        t.expect(dup).to.equal(false)
        t.expect(tostring(err):find("duplicate key") ~= nil).to.equal(true)
    end)

    t.it("uses _version as the CAS predicate and reports a miss without mutating", function()
        t.expect(h.role:safe_insert({ rid = 7, _version = 0, gold = 100 })).to.equal(true)

        local hit = h.role:findAndModify({
            query = { rid = 7, _version = 0 },
            update = { ["$set"] = { _version = 1, gold = 101 } },
            new = true,
        })
        t.expect(hit.ok).to.equal(1)
        -- runCommand 的 value 是原始 BSON，不做二次解码；后像统一用 findOne 读
        local after_hit = h.role:findOne({ rid = 7 })
        t.expect(after_hit._version).to.equal(1)
        t.expect(after_hit.gold).to.equal(101)

        -- 文档 §3：nModified/nMatched 的返回结构取决于命令选项，必须实测而非猜
        local miss = h.role:findAndModify({
            query = { rid = 7, _version = 0 },
            update = { ["$set"] = { _version = 1, gold = 999 } },
            new = true,
        })
        t.expect(miss.ok).to.equal(1)
        t.expect(miss.lastErrorObject.n).to.equal(0)
        local after_miss = h.role:findOne({ rid = 7 })
        t.expect(after_miss.gold).to.equal(101)
        t.expect(after_miss._version).to.equal(1)
    end)

    t.it("round-trips reserved _critical_* fields without losing the intent", function()
        local intent = {
            op_id = "srv_" .. string.rep("b", 64),
            op_type = "shop.buy",
            param_hash = string.rep("c", 64),
            owner_fence = 5,
            prepared_at = 1700000000,
            state = "PREPARED",
        }
        t.expect(h.role:safe_insert({ rid = 8, _version = 0, _critical_intent_v1 = intent })).to.equal(true)
        local doc = h.role:findOne({ rid = 8 })
        t.expect(doc._critical_intent_v1.param_hash).to.equal(string.rep("c", 64))
        t.expect(doc._critical_intent_v1.state).to.equal("PREPARED")
        t.expect(doc._critical_intent_v1.owner_fence).to.equal(5)
    end)
end)
