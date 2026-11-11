local t = require "skytest"
local crypto = require "crypto"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local orm = require "orm"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/critical.lua")

-- 最小 schema：只要能让 orm.decode/orm.new 正常工作，字段名与真实 role 无关
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
    function self:_check_kv(k, value)
        assert(self[k])
        assert(type(value) == "number")
    end
    function self.new(data)
        return orm.new(self, data)
    end
    return self
end

local HASH = crypto.hmac_sha256
local EQ = crypto.const_equals

-- 假 dbmgr：只实现 critical 依赖的那几个原语，但语义与真实实现一致
-- （状态机、_version 推进走 orm.advance_persisted_version、UNKNOWN 隔离）
local function fake_dbmgr(store)
    local M = {}
    M.STATE = {
        NORMAL = "NORMAL",
        PREPARING = "PREPARING",
        CRITICAL_QUARANTINED = "CRITICAL_QUARANTINED",
        DISCARDED = "DISCARDED",
    }
    store.updates = {}
    store.state = M.STATE.NORMAL

    function M.cached_critical()
        return store.critical
    end

    function M.set_critical(_, _, _, critical)
        store.critical = critical
        return true
    end

    function M.begin_critical()
        if store.state ~= M.STATE.NORMAL then
            return false, store.state
        end
        store.state = M.STATE.PREPARING
        return true
    end

    function M.end_critical(_, _, _, _, ok)
        if ok then
            if store.state ~= M.STATE.PREPARING then
                return false, store.state
            end
            store.state = M.STATE.NORMAL
            return true
        end
        store.state = M.STATE.CRITICAL_QUARANTINED
        return true
    end

    function M.quarantine_critical()
        store.state = M.STATE.CRITICAL_QUARANTINED
        return true
    end

    function M.critical_update(_, _, _, _, expected, update, opts)
        store.updates[#store.updates + 1] = { expected = expected, update = update, handle = opts and opts.handle }
        local n = #store.updates
        if store.state == M.STATE.CRITICAL_QUARANTINED then
            return "REJECTED", "CRITICAL_QUARANTINED"
        end
        -- unknown_at / reject_at 只让第 N 次写入失败，用来单独覆盖 PREPARE 与 COMMIT 两条路径
        if store.unknown and (store.unknown_at == nil or store.unknown_at == n) then
            store.state = M.STATE.CRITICAL_QUARANTINED
            return "UNKNOWN", store.unknown
        end
        if store.reject and (store.reject_at == nil or store.reject_at == n) then
            return "REJECTED", "cas mismatch"
        end
        if store.doc._version ~= expected then
            return "REJECTED", "version mismatch"
        end
        local next_version = expected + 1
        assert(orm.advance_persisted_version(store.doc, expected, next_version))
        return "CONFIRMED", { version = next_version, n = 1, nModified = 1 }
    end

    return M
end

local function harness()
    local schema = role_schema()
    local doc = orm.new(schema, { rid = 7, _version = 0, gold = 100 })
    local store = { doc = doc, critical = {} }
    local h = {
        doc = doc,
        store = store,
        now = 1700000000,
        applied = 0,
        validated = 0,
    }
    h.dbmgr = fake_dbmgr(store)
    h.entity = {
        rid = 7,
        dbname = "demo",
        dbcoll = "role",
        key = "rid",
        unique_id = 7,
        handle = { fence = 5, valid = true },
        doc = doc,
    }
    local imports = {
        ["skyext.dbmgr"] = h.dbmgr,
        ["skyext.log"] = {
            debug = function() end,
            info = function() end,
            warn = function() end,
            error = function() end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.critical = assert(loadfile(source, "t", env))()
    h.grant = require "skyext.grant"
    h.capability = require "skyext.capability"

    -- 有效 Grant：rid=7、5 个 seq、1 小时内有效
    function h.new_grant(over)
        local fields = {
            version = 1,
            rid = 7,
            grant_id = string.rep("a", 32),
            issued_at = h.now - 10,
            expires_at = h.now + 3600,
            max_seq = 5,
            key_id = "k1",
        }
        for k, v in pairs(over or {}) do
            fields[k] = v
        end
        fields.mac = assert(h.grant.sign(fields, HASH))
        return fields
    end

    function h.handlers(over)
        local handlers = {
            validate = function()
                h.validated = h.validated + 1
                return true
            end,
            apply = function(_, params)
                h.applied = h.applied + 1
                h.doc.gold = h.doc.gold + (params and params.amount or 0)
                return true
            end,
        }
        for k, v in pairs(over or {}) do
            handlers[k] = v
        end
        return handlers
    end

    function h.client(seq, params, over)
        return h.critical.execute_client(
            h.entity,
            h.new_grant(),
            seq,
            "shop.buy",
            params or { amount = 1 },
            h.handlers(over),
            {
                hmac_fn = HASH,
                hash_fn = HASH,
                equal_fn = EQ,
                now = h.now,
            }
        )
    end

    return h
end

t.describe("critical 客户端入口", function()
    t.it("commits once and replays the stored result for the same op", function()
        local h = harness()
        local first = h.client(1)
        t.expect(first.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(first.cache_policy).to.equal(h.critical.CACHEABLE)
        t.expect(h.applied).to.equal(1)
        t.expect(h.doc.gold).to.equal(101)
        t.expect(h.doc._version).to.equal(2) -- PREPARE + COMMIT

        -- 重放：不重新执行 apply，直接回历史结果
        local second = h.client(1)
        t.expect(second.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(h.applied).to.equal(1)
        t.expect(h.doc.gold).to.equal(101)
        t.expect(#h.store.updates).to.equal(2)
    end)

    t.it("rejects the same op id with different parameters", function()
        local h = harness()
        t.expect(h.client(1, { amount = 1 }).status).to.equal(h.critical.STATUS.COMMITTED)
        local conflict = h.client(1, { amount = 99 })
        t.expect(conflict.status).to.equal(h.critical.STATUS.OP_CONFLICT)
        t.expect(h.applied).to.equal(1)
        t.expect(h.doc.gold).to.equal(101)
    end)

    t.it("refuses an expired grant without writing anything", function()
        local h = harness()
        -- 先按签发时间造 Grant，再把"现在"推到有效期之后
        local signed = h.new_grant()
        h.now = 1700000000 + 7200
        local result = h.critical.execute_client(h.entity, signed, 1, "shop.buy", { amount = 1 }, h.handlers(), {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
        t.expect(result.status).to.equal(h.critical.STATUS.EXPIRED)
        t.expect(result.cache_policy).to.equal(h.critical.NO_CACHE)
        t.expect(#h.store.updates).to.equal(0)
        t.expect(h.applied).to.equal(0)
        t.expect(h.store.state).to.equal("NORMAL")
    end)

    t.it("refuses a seq beyond the grant range and a tampered mac", function()
        local h = harness()
        t.expect(h.client(6).status).to.equal(h.critical.STATUS.EXPIRED)
        local forged = h.new_grant()
        forged.max_seq = 9
        local result = h.critical.execute_client(h.entity, forged, 1, "shop.buy", { amount = 1 }, h.handlers(), {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(#h.store.updates).to.equal(0)
    end)

    t.it("refuses a grant issued for another role", function()
        local h = harness()
        local result = h.critical.execute_client(
            h.entity,
            h.new_grant({ rid = 8 }),
            1,
            "shop.buy",
            { amount = 1 },
            h.handlers(),
            {
                hmac_fn = HASH,
                hash_fn = HASH,
                equal_fn = EQ,
                now = h.now,
            }
        )
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(#h.store.updates).to.equal(0)
    end)

    -- PRECHECK_REJECTED 是"这次条件不满足"，不是 op 的持久化终态：
    -- 不能写意图、不能声明已拒绝、更不能进 L1
    t.it("does not persist a pure-read precheck rejection", function()
        local h = harness()
        local balance = 0
        local handlers = h.handlers({
            validate = function()
                if balance < 10 then
                    return false, { errcode = 4001 }
                end
                return true
            end,
        })
        local rejected = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, handlers, {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
        t.expect(rejected.status).to.equal(h.critical.STATUS.PRECHECK_REJECTED)
        t.expect(rejected.cache_policy).to.equal(h.critical.NO_CACHE)
        t.expect(rejected.response.errcode).to.equal(4001)
        t.expect(#h.store.updates).to.equal(0)
        t.expect(h.store.critical._critical_intent_v1).to.be_nil()
        t.expect(h.doc._version).to.equal(0)

        -- 条件变化后同一个 op_id 可以重新预检
        balance = 100
        local ok = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, handlers, {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
        t.expect(ok.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(h.applied).to.equal(1)
    end)

    t.it("persists a business rejection decided during apply", function()
        local h = harness()
        local handlers = h.handlers({
            apply = function()
                return false, { errcode = 4002 }
            end,
        })
        local result = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, handlers, {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
        t.expect(result.status).to.equal(h.critical.STATUS.BUSINESS_REJECTED)
        t.expect(result.cache_policy).to.equal(h.critical.CACHEABLE)
        -- 业务拒绝也必须清掉意图，否则后续操作永远被 IN_PROGRESS 挡住
        t.expect(h.store.critical._critical_intent_v1).to.be_nil()
        local op = h.store.critical._critical_ops_v1["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001"]
        t.expect(op.status).to.equal(h.critical.STATUS.BUSINESS_REJECTED)
        -- 拒绝不改资产
        t.expect(h.doc.gold).to.equal(100)

        -- 重放返回同一个拒绝结果
        local again = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, handlers, {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
        t.expect(again.status).to.equal(h.critical.STATUS.BUSINESS_REJECTED)
    end)

    -- 同 owner 快速续做：PREPARE 已确认、COMMIT 从未发出（进程内可以证明），
    -- 重试必须直接进 COMMIT，而不是再写一次 PREPARE
    t.it("resumes from a confirmed PREPARE without writing it twice", function()
        local h = harness()
        local param_hash = h.critical.param_hash("shop.buy", { amount = 1 }, HASH)
        local op_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001"
        h.store.critical._critical_intent_v1 = {
            op_id = op_id,
            op_type = "shop.buy",
            param_hash = param_hash,
            owner_fence = 5,
            state = "PREPARED",
        }
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(#h.store.updates).to.equal(1) -- 只有 COMMIT
        t.expect(h.doc.gold).to.equal(101)
        t.expect(h.store.critical._critical_intent_v1).to.be_nil()
    end)

    t.it("refuses to start a second op while another intent is pending", function()
        local h = harness()
        h.store.critical._critical_intent_v1 = {
            op_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0009",
            op_type = "shop.buy",
            param_hash = "x",
        }
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.IN_PROGRESS)
        t.expect(result.cache_policy).to.equal(h.critical.NO_CACHE)
        t.expect(#h.store.updates).to.equal(0)
    end)

    t.it("quarantines and reports UNKNOWN when the prepare write is unknown", function()
        local h = harness()
        h.store.unknown = "write concern timeout"
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.UNKNOWN)
        t.expect(result.cache_policy).to.equal(h.critical.NO_CACHE)
        t.expect(result.recovery_id).to.equal("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001")
        t.expect(h.store.state).to.equal("CRITICAL_QUARANTINED")
        -- 预检过了，但 apply 绝不能执行
        t.expect(h.applied).to.equal(0)
    end)

    t.it("quarantines when apply raises and never sends the commit", function()
        local h = harness()
        local handlers = h.handlers({
            apply = function()
                error("boom")
            end,
        })
        local result = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, handlers, {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
        t.expect(result.status).to.equal(h.critical.STATUS.UNKNOWN)
        t.expect(h.store.state).to.equal("CRITICAL_QUARANTINED")
        -- 只有 PREPARE 那一次写，COMMIT 从未发出
        t.expect(#h.store.updates).to.equal(1)
    end)
end)

t.describe("critical 内部入口", function()
    local function internal(h, cap, op_id, params, handlers)
        return h.critical.execute_internal(
            h.entity,
            op_id,
            "pay.grant",
            params or { amount = 1 },
            handlers or h.handlers(),
            {
                capability = cap,
                hmac_fn = HASH,
                hash_fn = HASH,
                source_id = "order_1",
                now = h.now,
            }
        )
    end

    local function issuer()
        return assert((require "skyext.capability").new_issuer("payment", { "pay.grant" }))
    end

    local function issue(h, over)
        local iss = issuer()
        local fields = {
            rid = 7,
            service_op_id = string.rep("srv_", 1) .. string.rep("b", 64),
            op_type = "pay.grant",
            payload_hash = h.critical.param_hash("pay.grant", { amount = 1 }, HASH),
            source_id = "order_1",
        }
        for k, v in pairs(over or {}) do
            fields[k] = v
        end
        return assert(h.capability.issue(iss, fields))
    end

    t.it("requires a capability object, not a source string", function()
        local h = harness()
        local result = h.critical.execute_internal(
            h.entity,
            "srv_" .. string.rep("b", 64),
            "pay.grant",
            { amount = 1 },
            h.handlers(),
            {
                hmac_fn = HASH,
                hash_fn = HASH,
                now = h.now,
            }
        )
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(#h.store.updates).to.equal(0)

        local forged = internal(h, { source = "payment" }, "srv_" .. string.rep("b", 64))
        t.expect(forged.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(#h.store.updates).to.equal(0)
    end)

    t.it("commits through the same kernel as the client entry", function()
        local h = harness()
        local result = internal(h, issue(h), "srv_" .. string.rep("b", 64))
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(h.doc.gold).to.equal(101)
        t.expect(h.doc._version).to.equal(2)
    end)

    t.it("refuses a capability issued for another role or another op", function()
        local h = harness()
        local other_rid = internal(h, issue(h, { rid = 8 }), "srv_" .. string.rep("b", 64))
        t.expect(other_rid.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)

        local other_op =
            internal(h, issue(h, { service_op_id = "srv_" .. string.rep("c", 64) }), "srv_" .. string.rep("b", 64))
        t.expect(other_op.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(#h.store.updates).to.equal(0)
    end)

    t.it("consumes a capability exactly once", function()
        local h = harness()
        local cap = issue(h)
        t.expect(internal(h, cap, "srv_" .. string.rep("b", 64)).status).to.equal(h.critical.STATUS.COMMITTED)
        -- 同一枚 cap 不能用于第二次分发（即便 op 相同、已提交）
        t.expect(internal(h, cap, "srv_" .. string.rep("b", 64)).status).to
            .equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
    end)

    t.it("rejects a capability whose payload hash does not match the parameters", function()
        local h = harness()
        local cap = issue(h)
        local result = h.critical.execute_internal(
            h.entity,
            "srv_" .. string.rep("b", 64),
            "pay.grant",
            { amount = 999 },
            h.handlers(),
            {
                capability = cap,
                hmac_fn = HASH,
                hash_fn = HASH,
                source_id = "order_1",
                now = h.now,
            }
        )
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(#h.store.updates).to.equal(0)
    end)
end)

t.describe("critical 操作键", function()
    t.it("maps event_id to service_op_id byte for byte", function()
        local critical = require "skyext.critical"
        local evt = "evt_" .. string.rep("a", 64)
        t.expect(critical.service_op_id_from_event(evt)).to.equal("srv_" .. string.rep("a", 64))
        -- 幂等：同一个事件重复映射结果相同
        t.expect(critical.service_op_id_from_event(evt)).to.equal(critical.service_op_id_from_event(evt))
    end)

    t.it("refuses malformed event ids", function()
        local critical = require "skyext.critical"
        local cases = {
            nil,
            "",
            "evt_",
            "evt_" .. string.rep("a", 63),
            "evt_" .. string.rep("a", 65),
            "evt_" .. string.rep("A", 64),
            "srv_" .. string.rep("a", 64),
            "evt_" .. string.rep("a", 63) .. "z",
        }
        for _, evt in ipairs(cases) do
            t.expect(critical.service_op_id_from_event(evt)).to.be_nil()
        end
    end)

    t.it("only accepts canonical service op ids", function()
        local critical = require "skyext.critical"
        t.expect(critical.validate_service_op_id("srv_" .. string.rep("a", 64))).to.equal(true)
        t.expect(critical.validate_service_op_id("srv_" .. string.rep("a", 63))).to.equal(false)
        t.expect(critical.validate_service_op_id("evt_" .. string.rep("a", 64))).to.equal(false)
        t.expect(critical.validate_service_op_id(123)).to.equal(false)
    end)

    t.it("rejects op ids that are not safe Mongo field names", function()
        local critical = require "skyext.critical"
        t.expect(critical.field_name_safe("abc_0001")).to.equal(true)
        t.expect(critical.field_name_safe("a.b")).to.equal(false)
        t.expect(critical.field_name_safe("$x")).to.equal(false)
        t.expect(critical.field_name_safe("a\0b")).to.equal(false)
        t.expect(critical.field_name_safe("")).to.equal(false)
    end)
end)

t.describe("critical 查询与恢复", function()
    t.it("reports NOT_STARTED, IN_PROGRESS and the committed result", function()
        local h = harness()
        t.expect(h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001").status).to.equal("NOT_STARTED")
        h.client(1)
        local q = h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001")
        t.expect(q.status).to.equal(h.critical.STATUS.COMMITTED)
    end)

    t.it("reports EXPIRED_NOT_EXECUTED only when there is no record", function()
        local h = harness()
        local q = h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0002", {
            grant_expires_at = h.now - 1,
            now = h.now,
        })
        t.expect(q.status).to.equal(h.critical.STATUS.EXPIRED_NOT_EXECUTED)
    end)

    t.it("never claims NOT_STARTED when the document is not loaded", function()
        local h = harness()
        h.store.critical = nil
        local q = h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001")
        t.expect(q.status).to.equal(h.critical.STATUS.UNKNOWN)
    end)

    -- 取消未决意图：一次 CAS 同时写 ABORTED 与清意图，不能只做 $unset
    t.it("aborts a pending intent with a single write", function()
        local h = harness()
        h.store.unknown = "timeout"
        t.expect(h.client(1).status).to.equal(h.critical.STATUS.UNKNOWN)

        -- 恢复：模拟隔离解除后重新拿到可写状态
        h.store.state = "NORMAL"
        h.store.unknown = nil
        h.store.critical._critical_intent_v1 = {
            op_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001",
            op_type = "shop.buy",
            param_hash = "x",
        }
        h.store.critical._critical_ops_v1 = nil
        h.doc._version = 0

        local state, detail = h.critical.abort_intent(h.entity, { now = h.now })
        t.expect(state).to.equal("CONFIRMED")
        t.expect(detail.op_id).to.equal("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001")
        t.expect(h.store.critical._critical_intent_v1).to.be_nil()
        t.expect(h.store.critical._critical_ops_v1["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001"].status).to.equal("ABORTED")
        -- ABORTED 不等于已消费：查询回到 NOT_STARTED
        t.expect(h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001").status).to.equal("NOT_STARTED")
    end)

    t.it("refuses to abort when there is no pending intent", function()
        local h = harness()
        local state, reason = h.critical.abort_intent(h.entity)
        t.expect(state).to.equal("REJECTED")
        t.expect(reason).to.equal("no pending intent")
    end)
end)

t.describe("critical 恢复任务与索引", function()
    local function fake_jobs()
        local jobs = { store = {}, indexes = {} }
        local function state_matches(doc, cond)
            if cond == nil then
                return true
            end
            if type(cond) == "table" and cond["$in"] then
                for _, want in ipairs(cond["$in"]) do
                    if doc.state == want then
                        return true
                    end
                end
                return false
            end
            return doc.state == cond
        end
        local function lease_matches(doc, ors, now)
            if not ors then
                return true
            end
            for _, cond in ipairs(ors) do
                local l = cond.lease_until
                if l and l["$lte"] then
                    if doc.lease_until ~= nil and doc.lease_until <= l["$lte"] then
                        return true
                    end
                elseif l and l["$exists"] == false then
                    if doc.lease_until == nil then
                        return true
                    end
                end
            end
            return false
        end
        function jobs:find_one(query)
            for _, doc in pairs(self.store) do
                if
                    doc.rid == query.rid
                    and doc.op_id == query.op_id
                    and state_matches(doc, query.state)
                    and lease_matches(doc, query["$or"], query.now or os.time())
                then
                    return doc
                end
            end
            return nil
        end
        function jobs:find_and_modify(opts)
            local existing = self:find_one(opts.query)
            if existing then
                if opts.update["$set"] then
                    for k, v in pairs(opts.update["$set"]) do
                        existing[k] = v
                    end
                end
                if opts.update["$inc"] then
                    for k, v in pairs(opts.update["$inc"]) do
                        existing[k] = (existing[k] or 0) + v
                    end
                end
                return { ok = 1, value = opts.new and existing or existing }
            end
            if not opts.upsert then
                return { ok = 1, value = "\0" }
            end
            local doc = {}
            for k, v in pairs(opts.update["$setOnInsert"] or {}) do
                doc[k] = v
            end
            self.store[doc.task_id] = doc
            return { ok = 1, value = doc }
        end
        function jobs:critical_find_and_modify(opts)
            local doc = self:find_one(opts.query)
            if not doc then
                return "CONFIRMED", { value = "\0" }
            end
            if doc.job_version ~= opts.query.job_version then
                return "CONFIRMED", { value = "\0" }
            end
            for k, v in pairs(opts.update["$set"] or {}) do
                doc[k] = v
            end
            for k, v in pairs(opts.update["$inc"] or {}) do
                doc[k] = (doc[k] or 0) + v
            end
            for k in pairs(opts.update["$unset"] or {}) do
                doc[k] = nil
            end
            return "CONFIRMED", { value = doc }
        end
        function jobs:create_index(keys)
            self.indexes[#self.indexes + 1] = keys
            return true
        end
        return jobs
    end

    t.it("creates one logical job per (rid, op_id)", function()
        local h = harness()
        local jobs = fake_jobs()
        local first = assert(h.critical.reconcile(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", { now = h.now }))
        t.expect(first.task_id).to.equal("7:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001")
        t.expect(first.state).to.equal(h.critical.JOB_STATE.PENDING)
        local again =
            assert(h.critical.reconcile(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", { now = h.now + 5 }))
        t.expect(again.task_id).to.equal(first.task_id)
        t.expect(again.updated_at).to.equal(h.now + 5)
        t.expect(again.created_at).to.equal(h.now)
    end)

    t.it("claims a job once and refuses a second claim with a stale version", function()
        local h = harness()
        local jobs = fake_jobs()
        assert(h.critical.reconcile(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", { now = h.now }))
        local ok, job = h.critical.claim_job(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", "node1", h.now + 30, {
            job_version = 0,
            now = h.now,
        })
        t.expect(ok).to.equal(true)
        t.expect(job.owner).to.equal("node1")
        t.expect(job.job_version).to.equal(1)

        local again = h.critical.claim_job(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", "node2", h.now + 60, {
            job_version = 0,
            now = h.now,
        })
        t.expect(again).to.equal(false)
    end)

    t.it("finishes a job with a version CAS", function()
        local h = harness()
        local jobs = fake_jobs()
        assert(h.critical.reconcile(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", { now = h.now }))
        assert(h.critical.claim_job(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", "node1", h.now + 30, {
            job_version = 0,
            now = h.now,
        }))
        t.expect(
            h.critical.finish_job(
                jobs,
                7,
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001",
                1,
                h.critical.JOB_STATE.COMPLETED_COMMITTED,
                {
                    now = h.now + 1,
                }
            )
        ).to
            .equal(true)
        local job = assert(h.critical.reconcile_status(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001"))
        t.expect(job.state).to.equal(h.critical.JOB_STATE.COMPLETED_COMMITTED)
        t.expect(job.owner).to.be_nil()
    end)

    t.it("refuses to enable critical modules when an index cannot be created", function()
        local h = harness()
        local role, ledger = fake_jobs(), fake_jobs()
        local jobs = fake_jobs()
        t.expect(h.critical.ensure_indexes({ role = role, jobs = jobs, ledger = ledger })).to.equal(true)
        t.expect(#jobs.indexes).to.equal(2)
        -- 唯一索引必须带 unique=true，否则多协调者会为同一 op 建出多份任务
        t.expect(jobs.indexes[1].unique).to.equal(true)
        t.expect(jobs.indexes[2].unique).to.be_nil()

        local broken = fake_jobs()
        function broken:create_index()
            return false, "not authorized"
        end
        local ok, err = h.critical.ensure_indexes({ role = role, jobs = broken, ledger = ledger })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("create_index failed")
    end)

    t.it("fails the gate when a collection is missing", function()
        local h = harness()
        local ok, err = h.critical.ensure_indexes({ role = fake_jobs(), jobs = fake_jobs() })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("missing collection")
    end)
end)

t.describe("critical 隔离路径", function()
    -- PREPARE 成功、COMMIT 未确认：内存已经被 apply 改过，必须隔离且不能重试成"没写"
    t.it("quarantines when the commit write is unknown", function()
        local h = harness()
        h.store.unknown = "commit timeout"
        h.store.unknown_at = 2
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.UNKNOWN)
        t.expect(result.recovery_id).to.equal("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001")
        t.expect(h.store.state).to.equal("CRITICAL_QUARANTINED")
        -- apply 确实跑过（内存已变），但消费记录没有写进去
        t.expect(h.applied).to.equal(1)
        t.expect(h.store.critical._critical_ops_v1).to.be_nil()
    end)

    t.it("quarantines when the commit CAS does not match", function()
        local h = harness()
        h.store.reject = "cas mismatch"
        h.store.reject_at = 2
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.UNKNOWN)
        t.expect(h.store.state).to.equal("CRITICAL_QUARANTINED")
    end)

    -- apply 返回 false 却改了内存：脏字段会留在回存轮上，下一次普通 save 就把它写进库
    t.it("quarantines when apply reports rejection but mutates the document", function()
        local h = harness()
        local handlers = h.handlers({
            apply = function()
                h.doc.gold = 1
                return false, { errcode = 4003 }
            end,
        })
        local result = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, handlers, {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
        t.expect(result.status).to.equal(h.critical.STATUS.UNKNOWN)
        t.expect(h.store.state).to.equal("CRITICAL_QUARANTINED")
        -- 拒绝结果不能被写成持久化终态
        t.expect(h.store.critical._critical_ops_v1).to.be_nil()
    end)

    -- 进程重启/换 owner 后，同 op 的意图还在但"COMMIT 从未发出"无法证明
    t.it("refuses to resume an intent left by another owner", function()
        local h = harness()
        h.store.critical._critical_intent_v1 = {
            op_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001",
            op_type = "shop.buy",
            param_hash = h.critical.param_hash("shop.buy", { amount = 1 }, HASH),
            owner_fence = 4,
            state = "PREPARED",
        }
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.UNKNOWN)
        t.expect(result.recovery_id).to.equal("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001")
        t.expect(#h.store.updates).to.equal(0)
        t.expect(h.applied).to.equal(0)
    end)

    t.it("refuses to reuse a pending intent with different parameters", function()
        local h = harness()
        h.store.critical._critical_intent_v1 = {
            op_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001",
            op_type = "shop.buy",
            param_hash = "deadbeef",
            owner_fence = 5,
            state = "PREPARED",
        }
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.OP_CONFLICT)
        t.expect(#h.store.updates).to.equal(0)
    end)

    t.it("refuses new critical operations once the ledger is full", function()
        local h = harness()
        local ops = {}
        for i = 1, h.critical.MAX_OPS do
            ops[string.format("%032x_%04x", i, i)] = { status = "COMMITTED" }
        end
        h.store.critical._critical_ops_v1 = ops
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.CAPACITY_EXCEEDED)
        t.expect(result.cache_policy).to.equal(h.critical.NO_CACHE)
        t.expect(#h.store.updates).to.equal(0)
    end)

    -- 纯读预检拒绝不产生写入，也不该烧掉内部凭证
    t.it("does not consume the capability on a precheck rejection", function()
        local h = harness()
        local iss = assert(h.capability.new_issuer("payment", { "pay.grant" }))
        local cap = assert(h.capability.issue(iss, {
            rid = 7,
            service_op_id = "srv_" .. string.rep("b", 64),
            op_type = "pay.grant",
            payload_hash = h.critical.param_hash("pay.grant", { amount = 1 }, HASH),
            source_id = "order_1",
        }))
        local rejecting = h.handlers({
            validate = function()
                return false, { errcode = 4004 }
            end,
        })
        local rejected = h.critical.execute_internal(
            h.entity,
            "srv_" .. string.rep("b", 64),
            "pay.grant",
            { amount = 1 },
            rejecting,
            {
                capability = cap,
                hmac_fn = HASH,
                hash_fn = HASH,
                source_id = "order_1",
                now = h.now,
            }
        )
        t.expect(rejected.status).to.equal(h.critical.STATUS.PRECHECK_REJECTED)
        -- 凭证仍然可用：换成会通过的预检后能正常提交
        local ok = h.critical.execute_internal(
            h.entity,
            "srv_" .. string.rep("b", 64),
            "pay.grant",
            { amount = 1 },
            h.handlers(),
            {
                capability = cap,
                hmac_fn = HASH,
                hash_fn = HASH,
                source_id = "order_1",
                now = h.now,
            }
        )
        t.expect(ok.status).to.equal(h.critical.STATUS.COMMITTED)
    end)
end)

t.describe("critical 任务抢占边界", function()
    local function fake_jobs()
        local jobs = { store = {}, indexes = {} }
        local function state_ok(doc, cond)
            if cond == nil then
                return true
            end
            if type(cond) == "table" and cond["$in"] then
                for _, want in ipairs(cond["$in"]) do
                    if doc.state == want then
                        return true
                    end
                end
                return false
            end
            return doc.state == cond
        end
        local function lease_ok(doc, ors)
            if not ors then
                return true
            end
            for _, cond in ipairs(ors) do
                local l = cond.lease_until
                if l and l["$lte"] then
                    if doc.lease_until ~= nil and doc.lease_until <= l["$lte"] then
                        return true
                    end
                elseif l and l["$exists"] == false then
                    if doc.lease_until == nil then
                        return true
                    end
                end
            end
            return false
        end
        function jobs:find_one(query)
            for _, doc in pairs(self.store) do
                if
                    doc.rid == query.rid
                    and doc.op_id == query.op_id
                    and state_ok(doc, query.state)
                    and lease_ok(doc, query["$or"])
                then
                    return doc
                end
            end
            return nil
        end
        function jobs:find_and_modify(opts)
            local existing = self:find_one(opts.query)
            if existing then
                for k, v in pairs(opts.update["$set"] or {}) do
                    existing[k] = v
                end
                return { ok = 1, value = existing }
            end
            local doc = {}
            for k, v in pairs(opts.update["$setOnInsert"] or {}) do
                doc[k] = v
            end
            self.store[doc.task_id] = doc
            return { ok = 1, value = doc }
        end
        function jobs:critical_find_and_modify(opts)
            local doc = self:find_one(opts.query)
            if not doc or doc.job_version ~= opts.query.job_version then
                return "CONFIRMED", { value = "\0" }
            end
            for k, v in pairs(opts.update["$set"] or {}) do
                doc[k] = v
            end
            for k, v in pairs(opts.update["$inc"] or {}) do
                doc[k] = (doc[k] or 0) + v
            end
            for k in pairs(opts.update["$unset"] or {}) do
                doc[k] = nil
            end
            return "CONFIRMED", { value = doc }
        end
        function jobs:create_index(keys)
            self.indexes[#self.indexes + 1] = keys
            return { ok = 1 }
        end
        return jobs
    end

    t.it("requires an integer job_version and lease", function()
        local h = harness()
        local jobs = fake_jobs()
        assert(h.critical.reconcile(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", { now = h.now }))
        local ok, err = h.critical.claim_job(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", "node1", h.now + 30, {
            now = h.now,
        })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("job_version must be an integer")

        ok, err = h.critical.claim_job(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", "node1", 1.5, {
            job_version = 0,
            now = h.now,
        })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("lease_until must be an integer")
    end)

    t.it("does not let a finished job be claimed again", function()
        local h = harness()
        local jobs = fake_jobs()
        assert(h.critical.reconcile(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", { now = h.now }))
        assert(h.critical.claim_job(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", "node1", h.now + 30, {
            job_version = 0,
            now = h.now,
        }))
        assert(
            h.critical.finish_job(
                jobs,
                7,
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001",
                1,
                h.critical.JOB_STATE.COMPLETED_COMMITTED,
                {
                    now = h.now + 1,
                }
            )
        )
        local ok = h.critical.claim_job(jobs, 7, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", "node2", h.now + 90, {
            job_version = 2,
            now = h.now + 60,
        })
        t.expect(ok).to.equal(false)
    end)

    -- 驱动把 runCommand 的原始回复返回：{ok=0} 是失败，不能当成功放行
    t.it("treats a non-ok command reply as an index failure", function()
        local h = harness()
        local bad = fake_jobs()
        function bad:create_index()
            return { ok = 0, errmsg = "not authorized" }
        end
        local ok, err = h.critical.ensure_indexes({ role = fake_jobs(), jobs = bad, ledger = fake_jobs() })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("not authorized")
    end)
end)

-- P13 源侧：Outbox 事件必须和资产增量进同一次 CAS
t.describe("critical 源侧 Outbox", function()
    local OP_ID = "srv_" .. string.rep("a", 64)
    local EVENT_ID = "evt_" .. string.rep("a", 64)
    local PAYLOAD = { item = 1 }

    local function internal(h, opts)
        opts = opts or {}
        local payload = opts.payload or PAYLOAD
        local hash = assert(h.critical.param_hash_of(opts.op_type or "mail.send", payload, HASH))
        local issuer = assert(h.capability.new_issuer("outbox", {}))
        local cap = assert(h.capability.issue(issuer, {
            rid = 7,
            service_op_id = OP_ID,
            op_type = opts.op_type or "mail.send",
            payload_hash = hash,
            source_id = "role:9",
            now = h.now,
        }))
        local event = {
            event_id = EVENT_ID,
            target_type = "role",
            target_id = 9,
            op_type = opts.op_type or "mail.send",
            param_hash = hash,
            payload = payload,
            status = "PENDING",
            attempt = 0,
            created_at = h.now,
        }
        local outbox = opts.outbox
        if outbox == nil then
            outbox = { event }
        end
        return h.critical.execute_internal(
            h.entity,
            OP_ID,
            opts.op_type or "mail.send",
            payload,
            h.handlers(opts.handlers),
            {
                capability = cap,
                hash_fn = HASH,
                source_namespace = "outbox",
                source_id = "role:9",
                now = h.now,
                outbox = outbox,
            }
        ),
            event
    end

    t.it("persists the event and the pending counter in the commit CAS", function()
        local h = harness()
        local result, event = internal(h)
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)

        local commit = h.store.updates[#h.store.updates].update
        t.expect(commit["$set"]["_critical_outbox_v1." .. event.event_id]).to.equal(event)
        t.expect(commit["$set"]["_critical_outbox_pending_count"]).to.equal(1)
        -- 内存副本必须跟上，否则下一轮 worker 读不到这条事件
        t.expect(h.store.critical._critical_outbox_pending_count).to.equal(1)
        t.expect(h.store.critical._critical_outbox_v1[event.event_id].status).to.equal("PENDING")
    end)

    t.it("does not enqueue events when the business rejects", function()
        local h = harness()
        local result = internal(h, {
            handlers = {
                apply = function()
                    return false, "not enough gold"
                end,
            },
        })
        t.expect(result.status).to.equal(h.critical.STATUS.BUSINESS_REJECTED)
        local commit = h.store.updates[#h.store.updates].update
        t.expect(commit["$set"]["_critical_outbox_pending_count"]).to.be_nil()
    end)

    t.it("refuses a malformed event before writing anything", function()
        local h = harness()
        local result = internal(h, {
            outbox = { { event_id = "evt_short", status = "PENDING" } },
        })
        t.expect(result.status).to.equal(h.critical.STATUS.PRECHECK_REJECTED)
        t.expect(h.applied).to.equal(0)
        t.expect(#h.store.updates).to.equal(0)
    end)

    -- 无上限增长会让角色在下次加载时撞上 512 KiB 关键字段预算
    t.it("refuses new events when the outbox is full", function()
        local h = harness()
        local existing = {}
        for i = 1, h.critical.MAX_OUTBOX do
            existing[string.format("evt_%064x", i)] = { status = "ENQUEUED" }
        end
        h.store.critical = { _critical_outbox_v1 = existing, _critical_outbox_pending_count = 0 }
        local result = internal(h)
        t.expect(result.status).to.equal(h.critical.STATUS.CAPACITY_EXCEEDED)
        t.expect(h.applied).to.equal(0)
    end)
end)
