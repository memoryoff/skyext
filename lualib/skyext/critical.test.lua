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
    -- 与真实 dbmgr 的 M.REASON 同名：critical 靠 code 决定要不要隔离缓存，
    -- 桩只回两个值会让那条分支永远测不到
    M.REASON = {
        INVALID_UPDATE = "invalid_update",
        NOT_CACHED = "not_cached",
        OWNER_CHANGED = "owner_changed",
        STATE_INVALID = "state_invalid",
        VERSION_MISMATCH = "version_mismatch",
        CAS_MISMATCH = "cas_mismatch",
        LEASE_EXPIRED = "lease_expired",
        MAJORITY_UNAVAILABLE = "majority_unavailable",
        SERVER_REJECTED = "server_rejected",
        UNKNOWN = "unknown",
        MEMORY_DIVERGED = "memory_diverged",
    }
    store.updates = {}
    store.state = M.STATE.NORMAL

    function M.cached_critical()
        return store.critical
    end

    -- 多数派读：真实实现从库里重新提取关键元数据并推进 _version。
    -- 桩用 persisted_critical / persisted_version 模拟"库里的真相"——
    -- 它可以比内存多一条 PREPARE 意图（PREPARE 落库但 ACK 丢失就是这个状态）
    function M.refresh_critical()
        if store.refresh_fails then
            return nil, store.refresh_fails
        end
        if store.persisted_version and store.doc then
            while store.doc._version < store.persisted_version do
                local current = store.doc._version
                assert(orm.advance_persisted_version(store.doc, current, current + 1))
            end
        end
        if store.persisted_critical then
            store.critical = store.persisted_critical
        end
        return true, store.doc and store.doc._version or 0
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

    -- 只读观测：abort_intent 用它判断"原本是不是隔离态"，只有隔离态
    -- 才需要在清意图之后标作废
    function M.state_of()
        return store.state
    end

    -- 隔离态取消意图之后标作废：内存可能带着 apply 的痕迹，不能再回 NORMAL
    function M.mark_discarded()
        if store.mark_discarded_fails then
            return false, "owner changed"
        end
        if store.state ~= M.STATE.CRITICAL_QUARANTINED then
            return false, store.state
        end
        store.state = M.STATE.DISCARDED
        return true
    end

    function M.quarantine_critical()
        store.state = M.STATE.CRITICAL_QUARANTINED
        return true
    end

    function M.critical_update(_, _, _, _, expected, update, opts)
        store.updates[#store.updates + 1] = { expected = expected, update = update, handle = opts and opts.handle }
        local n = #store.updates
        if store.state == M.STATE.CRITICAL_QUARANTINED and not (opts and opts.allow_quarantined_intent_abort) then
            return "REJECTED", "CRITICAL_QUARANTINED", M.REASON.STATE_INVALID
        end
        if opts and opts.metadata_only and store.metadata_unknown then
            if store.metadata_unknown_apply then
                local op_prefix = "_critical_ops_v1."
                for path in pairs(update["$unset"] or {}) do
                    if path:sub(1, #op_prefix) == op_prefix then
                        local op_id = path:sub(#op_prefix + 1)
                        store.critical._critical_ops_v1 = store.critical._critical_ops_v1 or {}
                        store.critical._critical_ops_v1[op_id] = nil
                    end
                end
                store.doc._version = expected + 1
            end
            return "UNKNOWN", store.metadata_unknown, M.REASON.UNKNOWN
        end
        -- unknown_at / reject_at 只让第 N 次写入失败，用来单独覆盖 PREPARE 与 COMMIT 两条路径
        if store.unknown and (store.unknown_at == nil or store.unknown_at == n) then
            store.state = M.STATE.CRITICAL_QUARANTINED
            return "UNKNOWN", store.unknown, M.REASON.UNKNOWN
        end
        if store.reject and (store.reject_at == nil or store.reject_at == n) then
            return "REJECTED", "cas mismatch", store.reject_code or M.REASON.CAS_MISMATCH
        end
        if store.doc._version ~= expected then
            return "REJECTED", "version mismatch", M.REASON.VERSION_MISMATCH
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

    function h.client(seq, params, over, opts_over)
        local opts = {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        }
        for k, v in pairs(opts_over or {}) do
            opts[k] = v
        end
        return h.critical.execute_client(
            h.entity,
            h.new_grant(),
            seq,
            "shop.buy",
            params or { amount = 1 },
            h.handlers(over),
            opts
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

    -- 漏传 equal_fn 时 grant.verify 会静默退回 `==`。这种接线错误必须当场拒绝，
    -- 否则生产环境就在用非常量时间比较验签，而且没有任何信号
    t.it("refuses a client call without a constant-time comparator", function()
        local h = harness()
        local result = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, h.handlers(), {
            hmac_fn = HASH,
            hash_fn = HASH,
            now = h.now,
        })
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(result.reason).to.equal("equal_fn is required")
        t.expect(#h.store.updates).to.equal(0)
        t.expect(h.applied).to.equal(0)

        -- 传了但不是函数（拼错字段之类）同样拒绝，不能降级
        local wrong = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, h.handlers(), {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = true,
            now = h.now,
        })
        t.expect(wrong.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(#h.store.updates).to.equal(0)
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

    -- validate 抛错发生在 PREPARE 之前：库里什么都没写，报 UNKNOWN 会让调用方
    -- 去查恢复任务，而查询侧只会回 NOT_STARTED —— 两个答案互相矛盾
    t.it("reports a validation error without pretending the write is unknown", function()
        local h = harness()
        local handlers = h.handlers({
            validate = function()
                error("nil field in params")
            end,
        })
        local result = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, handlers, {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_ERROR)
        t.expect(result.cache_policy).to.equal(h.critical.NO_CACHE)
        t.expect(result.recovery_id).to.be_nil()
        -- 没有任何持久化写入，也不该隔离缓存
        t.expect(#h.store.updates).to.equal(0)
        t.expect(h.store.critical._critical_intent_v1).to.be_nil()
        t.expect(h.store.state).to.equal("NORMAL")
        t.expect(h.applied).to.equal(0)
        -- 查询侧与提交侧一致：这次操作确实没开始
        t.expect(h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001").status).to.equal("NOT_STARTED")
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
        -- 业务拒绝同样占一条热账本：水位不维护的话维护扫描永远不命中，
        -- 攒到 MAX_OPS 之后所有关键操作都会被容量拒绝，且没有任何自动恢复路径
        t.expect(h.store.critical._critical_ops_oldest_at).to.equal(h.now)
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

    -- PREPARE 被拒是**确定没写**，不能报 UNKNOWN（那会让调用方去找恢复任务，
    -- 而 critical.query 只会回 NOT_STARTED）。但缓存是否还可信要看原因码
    t.it("quarantines the stale cache when the prepare CAS misses", function()
        local h = harness()
        h.store.reject = "cas mismatch"
        h.store.reject_at = 1
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_ERROR)
        t.expect(result.cache_policy).to.equal(h.critical.NO_CACHE)
        t.expect(result.recovery_id).to.be_nil()
        t.expect(h.store.state).to.equal("CRITICAL_QUARANTINED")
        t.expect(h.applied).to.equal(0)
    end)

    t.it("keeps the cache writable when the prepare rejection is not about staleness", function()
        local h = harness()
        h.store.reject = "unsupported update operator"
        h.store.reject_code = h.dbmgr.REASON.INVALID_UPDATE
        h.store.reject_at = 1
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_ERROR)
        -- 格式错不代表内存过期：隔离它只会让玩家多一次无谓重载
        t.expect(h.store.state).to.equal("NORMAL")
    end)

    t.it("leaves a cache owned by another handle untouched", function()
        local h = harness()
        h.store.reject = "owner changed"
        h.store.reject_code = h.dbmgr.REASON.OWNER_CHANGED
        h.store.reject_at = 1
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_ERROR)
        -- 条目已经归新 owner，旧 handle 连"改成隔离"的资格都没有
        t.expect(h.store.state).to.equal("PREPARING")
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

    t.it("refuses a capability that contradicts the trusted dispatch context", function()
        local h = harness()
        local op_id = "srv_" .. string.rep("b", 64)
        local cap_a = issue(h)
        local cap_b = issue(h)
        local result
        h.capability.run_with(cap_a, function()
            result = internal(h, cap_b, op_id)
        end)
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(h.applied).to.equal(0)
        t.expect(#h.store.updates).to.equal(0)
    end)

    t.it("accepts a capability supplied only through the dispatch context", function()
        local h = harness()
        local op_id = "srv_" .. string.rep("b", 64)
        local cap = issue(h)
        local result
        h.capability.run_with(cap, function()
            result = h.critical.execute_internal(h.entity, op_id, "pay.grant", { amount = 1 }, h.handlers(), {
                hmac_fn = HASH,
                hash_fn = HASH,
                source_id = "order_1",
                now = h.now,
            })
        end)
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(h.applied).to.equal(1)
    end)

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

    t.it("accepts only canonical service or Grant op ids for queries", function()
        local critical = require "skyext.critical"
        t.expect(critical.validate_op_id("srv_" .. string.rep("a", 64))).to.equal(true)
        t.expect(critical.validate_op_id(string.rep("a", 32) .. "_0001")).to.equal(true)
        for _, invalid in ipairs({
            nil,
            "",
            string.rep("A", 32) .. "_0001",
            string.rep("a", 31) .. "_0001",
            string.rep("a", 32) .. "_001",
            string.rep("a", 32) .. "_0000",
            "srv_" .. string.rep("A", 64),
            "srv_" .. string.rep("a", 63),
        }) do
            t.expect(critical.validate_op_id(invalid)).to.equal(false)
        end
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
    t.it("rejects a malformed op id before reading memory or persisted state", function()
        local h = harness()
        local reads = 0
        local ledger = {
            critical_find = function()
                reads = reads + 1
                return nil, "must not be read"
            end,
        }
        h.store.persisted_critical = { _critical_intent_v1 = { op_id = "srv_" .. string.rep("a", 64) } }

        local result = h.critical.query(h.entity, string.rep("A", 32) .. "_0001", {
            majority_read = true,
            ledger = ledger,
        })
        t.expect(result.status).to.equal(h.critical.STATUS.UNKNOWN)
        t.expect(result.reason).to.equal("invalid op_id")
        t.expect(reads).to.equal(0)
        -- 没有发生多数派读，也就不会把任何持久化状态装回内存
        t.expect(h.store.refresh_calls or 0).to.equal(0)
    end)

    t.it("reports NOT_STARTED, IN_PROGRESS and the committed result", function()
        local h = harness()
        t.expect(h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001").status).to.equal("NOT_STARTED")
        h.client(1)
        local q = h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001")
        t.expect(q.status).to.equal(h.critical.STATUS.COMMITTED)
    end)

    -- 恢复任务要知道"挂着的意图是不是自己这条 op"：只有自己那条才能在持新 fence
    -- 的前提下主动取消。不带归属时 query 永远回 IN_PROGRESS，任务永远 RETRY_WAIT，
    -- 同角色其它关键操作也一直被挡
    t.it("reports which op holds the pending intent", function()
        local h = harness()
        local own = "srv_" .. string.rep("a", 64)
        local other = "srv_" .. string.rep("b", 64)
        h.store.critical = { _critical_intent_v1 = { op_id = own, state = "PREPARED" } }

        local q = h.critical.query(h.entity, own)
        t.expect(q.status).to.equal(h.critical.STATUS.IN_PROGRESS)
        t.expect(q.intent_op_id).to.equal(own)

        local q2 = h.critical.query(h.entity, other)
        t.expect(q2.status).to.equal(h.critical.STATUS.IN_PROGRESS)
        t.expect(q2.intent_op_id).to.equal(own)
    end)

    -- PREPARE 落库但 ACK 丢失：commit_core 的 UNKNOWN 分支不会 set_critical，
    -- 所以内存里没有意图，而库里有一条 PREPARED。恢复任务若按内存判定，
    -- 会把"已写入 PREPARE"当成"从未执行"，任务写成 COMPLETED 后再也复不开
    t.it("reads the persisted intent when asked for a majority read", function()
        local h = harness()
        local own = "srv_" .. string.rep("c", 64)
        h.store.persisted_critical = { _critical_intent_v1 = { op_id = own, state = "PREPARED" } }
        h.store.persisted_version = 2

        -- 默认读内存：看不到库里的意图
        t.expect(h.critical.query(h.entity, own).status).to.equal("NOT_STARTED")

        -- 多数派读：看到库里的 PREPARED，并带回归属
        local proof = h.critical.query(h.entity, own, { majority_read = true })
        t.expect(proof.status).to.equal(h.critical.STATUS.IN_PROGRESS)
        t.expect(proof.intent_op_id).to.equal(own)
        t.expect(h.doc._version).to.equal(2)
    end)

    t.it("reports UNKNOWN instead of NOT_STARTED when the majority read fails", function()
        local h = harness()
        h.store.refresh_fails = "socket closed"
        local proof = h.critical.query(h.entity, "srv_" .. string.rep("d", 64), { majority_read = true })
        t.expect(proof.status).to.equal(h.critical.STATUS.UNKNOWN)
    end)

    -- abort_intent 也要能按库里的意图取消：只读内存会回 "no pending intent"，
    -- 库里那条 PREPARED 就永远清不掉，角色重载后所有关键操作回 IN_PROGRESS
    t.it("aborts a persisted intent after aligning with the majority read", function()
        local h = harness()
        local own = "srv_" .. string.rep("e", 64)
        h.store.persisted_critical = {
            _critical_intent_v1 = { op_id = own, op_type = "buy", param_hash = string.rep("a", 64) },
        }
        h.store.persisted_version = 1
        h.store.state = h.dbmgr.STATE.CRITICAL_QUARANTINED

        local state = h.critical.abort_intent(h.entity, { majority_read = true })
        t.expect(state).to.equal("CONFIRMED")
        -- 隔离态取消意图后必须标作废：内存可能带着 apply 的痕迹，不能回 NORMAL
        t.expect(h.store.state).to.equal(h.dbmgr.STATE.DISCARDED)
        t.expect(h.store.critical._critical_intent_v1).to.be_nil()
    end)

    -- 标记作废失败不能报成功：库里意图已清、内存意图还在，
    -- scan_intents 不再按库建任务，这个实体就永远出不去了
    t.it("reports UNKNOWN when a quarantined entry cannot be marked discarded", function()
        local h = harness()
        local own = "srv_" .. string.rep("f", 64)
        h.store.persisted_critical = {
            _critical_intent_v1 = { op_id = own, op_type = "buy", param_hash = string.rep("a", 64) },
        }
        h.store.persisted_version = 1
        h.store.state = h.dbmgr.STATE.CRITICAL_QUARANTINED
        h.store.mark_discarded_fails = true

        local state = h.critical.abort_intent(h.entity, { majority_read = true })
        t.expect(state).to.equal("UNKNOWN")
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

    -- 冷账本读取必须和提交路径一样有 pcall：驱动抛错时不能把异常抛给对账调用方，
    -- 否则支付对账会因为一次连接抖动直接崩在查询上
    t.it("turns a raising ledger read into a structured UNKNOWN", function()
        local h = harness()
        local ledger = {
            critical_find = function()
                error("driver closed")
            end,
        }
        local q = h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", { ledger = ledger })
        t.expect(q.status).to.equal(h.critical.STATUS.UNKNOWN)
        t.expect(q.reason:find("ledger read raised", 1, true) ~= nil).to.equal(true)
    end)

    t.it("still reports the archived record when the ledger answers", function()
        local h = harness()
        local ledger = {
            critical_find = function()
                return { status = "COMMITTED", response = { gold = 7 } }
            end,
        }
        local q = h.critical.query(h.entity, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_0001", { ledger = ledger })
        t.expect(q.status).to.equal("COMMITTED")
        t.expect(q.archived).to.equal(true)
        t.expect(q.response.gold).to.equal(7)
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
        t.expect(h.store.critical._critical_ops_oldest_at).to.equal(h.now)
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

    t.it("archives settled operations before rejecting a full ledger", function()
        local h = harness()
        local ops = {}
        for i = 1, h.critical.MAX_OPS do
            ops[string.format("%032x_%04x", i, i)] = {
                status = "COMMITTED",
                op_type = "shop.buy",
                param_hash = string.rep("a", 64),
                at = h.now - 100,
            }
        end
        h.store.critical._critical_ops_v1 = ops
        h.store.critical._critical_ops_oldest_at = h.now - 100
        local archived = 0
        local ledger = {
            critical_find = function()
                return nil
            end,
            critical_find_and_modify = function()
                archived = archived + 1
                return "CONFIRMED", { n = 1, nModified = 1 }
            end,
        }

        local result = h.client(1, nil, nil, { ledger = ledger })
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(archived).to.equal(h.critical.CAPACITY_ARCHIVE_LIMIT)
        local left = 0
        for _ in pairs(h.store.critical._critical_ops_v1) do
            left = left + 1
        end
        t.expect(left).to.equal(h.critical.MAX_OPS - h.critical.CAPACITY_ARCHIVE_LIMIT + 1)
    end)

    t.it("refreshes a capacity archive whose metadata CAS result is unknown", function()
        local h = harness()
        local ops = {}
        for i = 1, h.critical.MAX_OPS do
            ops[string.format("%032x_%04x", i, i)] = {
                status = "COMMITTED",
                op_type = "shop.buy",
                param_hash = string.rep("a", 64),
                at = h.now - 100,
            }
        end
        h.store.critical._critical_ops_v1 = ops
        h.store.critical._critical_ops_oldest_at = h.now - 100
        h.store.metadata_unknown = "write concern timeout"
        h.store.metadata_unknown_apply = true
        local ledger = {
            critical_find = function()
                return nil
            end,
            critical_find_and_modify = function()
                return "CONFIRMED", { n = 1, nModified = 1 }
            end,
        }

        local result = h.client(1, nil, nil, { ledger = ledger })
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        local left = 0
        for _ in pairs(h.store.critical._critical_ops_v1 or {}) do
            left = left + 1
        end
        t.expect(left).to.equal(h.critical.MAX_OPS - h.critical.CAPACITY_ARCHIVE_LIMIT + 1)
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
        local issuer = assert(h.capability.new_issuer("outbox", { opts.op_type or "mail.send" }))
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

    t.it("refuses a param_hash that is 64 characters but not hex", function()
        local h = harness()
        local event = {
            event_id = EVENT_ID,
            target_type = "role",
            target_id = 9,
            op_type = "mail.send",
            param_hash = string.rep("z", 64),
            payload = PAYLOAD,
            status = "PENDING",
            attempt = 0,
            created_at = h.now,
        }
        local result = internal(h, { outbox = { event } })
        t.expect(result.status).to.equal(h.critical.STATUS.PRECHECK_REJECTED)
        t.expect(result.reason).to.match("64 hex param_hash")
        t.expect(#h.store.updates).to.equal(0)
    end)

    -- 同一批里两个分片用了同一个 event_id：`$set` 同一路径写两次只留最后一份，
    -- 但 pending_count 按 #events 计。第二个分片的业务效果永久丢失，计数还永不收敛
    t.it("refuses a batch that reuses an event_id", function()
        local h = harness()
        local event_id = "evt_" .. string.rep("1", 64)
        local function shard()
            return {
                event_id = event_id,
                target_type = "role",
                target_id = 9,
                op_type = "mail.send",
                param_hash = string.rep("a", 64),
                status = "PENDING",
            }
        end

        local result = internal(h, { outbox = { shard(), shard() } })
        t.expect(result.status).to.equal(h.critical.STATUS.PRECHECK_REJECTED)
        t.expect(h.applied).to.equal(0)
        t.expect(#h.store.updates).to.equal(0)
    end)

    -- 带洞数组：`#` 对带洞表的结果不确定，而计数与写入都用它。
    -- 口径不一致时 pending_count 会永久偏高，worker 每轮命中永不收敛
    t.it("refuses a sparse outbox array", function()
        local h = harness()
        local function shard(suffix)
            return {
                event_id = "evt_" .. string.rep(suffix, 64),
                target_type = "role",
                target_id = 9,
                op_type = "mail.send",
                param_hash = string.rep("a", 64),
                status = "PENDING",
            }
        end
        local sparse = { [1] = shard("1"), [3] = shard("2") }
        local result = internal(h, { outbox = sparse })
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

    -- 事件只增不减会让角色被永久拒绝：到上限时先腾终态事件，再决定是否拒绝
    t.it("evicts settled events instead of refusing the new one", function()
        local h = harness()
        local existing = {}
        for i = 1, h.critical.MAX_OUTBOX do
            existing[string.format("evt_%064x", i)] = {
                status = "DELIVERED",
                created_at = h.now - 1000,
                updated_at = h.now - 1000,
                op_type = "mail.send",
            }
        end
        h.store.critical = { _critical_outbox_v1 = existing, _critical_outbox_pending_count = 0 }

        local result, event = internal(h)
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        local commit = h.store.updates[#h.store.updates].update
        t.expect(commit["$set"]["_critical_outbox_v1." .. event.event_id]).to.equal(event)

        -- 腾挪必须与新增在同一次写入里：单独先删会留下"事件没了、资产没提交"
        local unset = commit["$unset"] or {}
        local removed = 0
        for key in pairs(unset) do
            if key:find("^_critical_outbox_v1%.") then
                removed = removed + 1
            end
        end
        t.expect(removed).to.equal(1)
        -- 内存副本同步：否则下一次容量判断会少腾一条
        t.expect(h.store.critical._critical_outbox_v1[event.event_id].status).to.equal("PENDING")
    end)

    -- FAILED 是"资产已扣、可靠消息从未落库"的唯一记录。容量腾挪把
    -- delivered_retention 传成 0，如果 FAILED 沿用同一个值，一条刚失败的事件
    -- 会在下一次提交时被静默抹掉：既不能重投，也没有补偿依据
    t.it("keeps a young FAILED event even when the outbox is at capacity", function()
        local h = harness()
        local existing = {}
        for i = 1, h.critical.MAX_OUTBOX do
            existing[string.format("evt_%064x", i)] = {
                status = "FAILED",
                created_at = h.now - 10,
                updated_at = h.now - 10,
                failed_reason = "mongo down",
                op_type = "mail.send",
            }
        end
        h.store.critical = { _critical_outbox_v1 = existing, _critical_outbox_pending_count = 0 }

        -- 没有可腾的：宁可受控拒绝新事件（调用方拿到可重试错误），
        -- 也不能把 512 条"资产已扣"的证据一起删掉
        local result = internal(h)
        t.expect(result.status).to.equal(h.critical.STATUS.CAPACITY_EXCEEDED)
        local failed_left = 0
        for _, ev in pairs(h.store.critical._critical_outbox_v1) do
            if ev.status == "FAILED" then
                failed_left = failed_left + 1
            end
        end
        t.expect(failed_left).to.equal(h.critical.MAX_OUTBOX)
    end)

    -- 但最小保留期只是下限，不是永久占位：过了下限，容量压力下仍可腾，
    -- 否则角色会被一批陈年 FAILED 永久锁死
    t.it("evicts a FAILED event once it is past the minimum retention", function()
        local h = harness()
        local existing = {}
        local old = h.now - h.critical.OUTBOX_FAILED_MIN_RETENTION - 1
        for i = 1, h.critical.MAX_OUTBOX do
            existing[string.format("evt_%064x", i)] = {
                status = "FAILED",
                created_at = old,
                updated_at = old,
                failed_reason = "mongo down",
                op_type = "mail.send",
            }
        end
        h.store.critical = { _critical_outbox_v1 = existing, _critical_outbox_pending_count = 0 }

        local result = internal(h)
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
    end)

    -- 没投出去的事件永远不腾：删了就是业务效果永久丢失
    t.it("never evicts events that were not delivered yet", function()
        local h = harness()
        local now = 10000
        -- 容量触顶时会显式放弃 DELIVERED 保留期
        local ids = h.critical.evictable_outbox_events({
            a = { status = "PENDING", created_at = now - 8 * 24 * 3600 },
            b = { status = "DELIVERED", updated_at = now - 1 },
            c = { status = "ENQUEUED", updated_at = now - 8 * 24 * 3600 },
        }, now, 10, { delivered_retention = 0 })
        t.expect(#ids).to.equal(2)
        t.expect(ids[1]).to.equal("c")
        t.expect(ids[2]).to.equal("b")
    end)

    t.it("keeps freshly delivered events until their retention expires", function()
        local h = harness()
        local now = 10000
        -- 默认调用（cleanup 口径）与 outbox.DELIVERED_RETENTION 同源，
        -- 刚 ACK 的记录不能被静默删掉，否则迟到重复回执查不到审计痕迹
        local ids = h.critical.evictable_outbox_events({
            fresh = { status = "DELIVERED", updated_at = now - 1 },
            old = { status = "DELIVERED", updated_at = now - 8 * 24 * 3600 },
            failed_old = { status = "FAILED", updated_at = now - 8 * 24 * 3600 },
            failed_fresh = { status = "FAILED", updated_at = now - 1 },
        }, now, 10)
        t.expect(#ids).to.equal(2)
        t.expect(ids[1]).to.equal("failed_old")
        t.expect(ids[2]).to.equal("old")
        t.expect(h.critical.OUTBOX_DELIVERED_RETENTION).to.equal(7 * 24 * 3600)
    end)
end)

-- 归档：热 _critical_ops_v1 -> 冷 op_ledger
t.describe("critical 归档", function()
    local OP_A = "srv_" .. string.rep("a", 64)
    local OP_B = "srv_" .. string.rep("b", 64)

    local function fake_ledger(over)
        local l = { upserts = {}, state = "CONFIRMED" }
        for k, v in pairs(over or {}) do
            l[k] = v
        end
        function l:critical_find_and_modify(opts)
            l.upserts[#l.upserts + 1] = opts
            return l.state, { value = opts.update["$setOnInsert"] }
        end
        function l:critical_find(query)
            l.find = query
            return l.archived_doc
        end
        return l
    end

    local function with_ops(h, ops, oldest)
        h.store.critical = {
            _critical_ops_v1 = ops,
            _critical_ops_oldest_at = oldest,
        }
        return h
    end

    t.it("moves settled and expired ops to the ledger, then removes them", function()
        local h = harness()
        with_ops(h, {
            [OP_A] = { status = "COMMITTED", op_type = "shop.buy", at = 100, param_hash = string.rep("1", 64) },
            [OP_B] = { status = "COMMITTED", op_type = "shop.buy", at = 900, param_hash = string.rep("2", 64) },
        }, 100)
        local ledger = fake_ledger()

        local stats = assert(h.critical.archive_ops(h.entity, { ledger = ledger }, { now = 1000, retention = 500 }))
        t.expect(stats.archived).to.equal(1)
        -- 先写冷账本、确认后才删热条目
        t.expect(#ledger.upserts).to.equal(1)
        t.expect(ledger.upserts[1].query.op_id).to.equal(OP_A)
        t.expect(ledger.upserts[1].upsert).to.equal(true)
        t.expect(h.store.critical._critical_ops_v1[OP_A]).to.be_nil()
        t.expect(h.store.critical._critical_ops_v1[OP_B]).to_not.be_nil()
        -- 剩下的最老一条要重算，否则扫描会一直命中
        t.expect(h.store.critical._critical_ops_oldest_at).to.equal(900)
    end)

    t.it("keeps the hot record when the ledger write is not confirmed", function()
        local h = harness()
        with_ops(h, {
            [OP_A] = { status = "COMMITTED", op_type = "shop.buy", at = 100 },
        }, 100)
        local ledger = fake_ledger({ state = "UNKNOWN" })

        local stats, err = h.critical.archive_ops(h.entity, { ledger = ledger }, { now = 1000, retention = 500 })
        t.expect(stats.archived).to.equal(0)
        t.expect(err).to.match("ledger")
        -- 冷账本没确认就删热条目 = 两边都没有，那个操作记录就永久消失了
        t.expect(h.store.critical._critical_ops_v1[OP_A]).to_not.be_nil()
    end)

    t.it("keeps the hot record when the ledger driver raises", function()
        local h = harness()
        with_ops(h, {
            [OP_A] = { status = "COMMITTED", op_type = "shop.buy", at = 100 },
        }, 100)
        local ledger = fake_ledger()
        function ledger:critical_find_and_modify()
            error("mongo down")
        end

        -- 驱动抛异常必须转成结构化失败，不能冒到维护服务里被吞成一轮静默失败
        local called, stats, err = pcall(
            h.critical.archive_ops,
            h.entity,
            { ledger = ledger },
            { now = 1000, retention = 500 }
        )
        t.expect(called).to.equal(true)
        t.expect(stats.archived).to.equal(0)
        t.expect(err).to.match("raised")
        t.expect(h.store.critical._critical_ops_v1[OP_A]).to_not.be_nil()
    end)

    t.it("never archives an unsettled op", function()
        local h = harness()
        with_ops(h, {
            [OP_A] = { status = "ABORTED", op_type = "shop.buy", at = 100 },
            [OP_B] = { status = "IN_PROGRESS", op_type = "shop.buy", at = 100 },
        }, 100)
        local ledger = fake_ledger()
        local stats = assert(h.critical.archive_ops(h.entity, { ledger = ledger }, { now = 1000, retention = 500 }))
        t.expect(stats.archived).to.equal(1)
        t.expect(h.store.critical._critical_ops_v1[OP_A]).to.be_nil()
        t.expect(h.store.critical._critical_ops_v1[OP_B]).to_not.be_nil()
    end)

    -- 同一个 op_id 可能先以 ABORTED 归档、之后被重放成 COMMITTED 再归档一次。
    -- 只写 $setOnInsert 会让冷账本永久停在第一次的状态，query 从此报"未执行"，
    -- 调用方据此重放 → 二次入账
    t.it("writes mutable fields with $set so a re-archive can correct the status", function()
        local h = harness()
        with_ops(h, { [OP_A] = { status = "ABORTED", op_type = "shop.buy", at = 100 } }, 100)
        local ledger = fake_ledger()
        assert(h.critical.archive_ops(h.entity, { ledger = ledger }, { now = 1000, retention = 500 }))
        local update = ledger.upserts[1].update
        t.expect(update["$setOnInsert"].op_id).to.equal(OP_A)
        t.expect(update["$setOnInsert"].status).to.be_nil()
        t.expect(update["$set"].status).to.equal("ABORTED")
    end)

    -- 冷分支与热分支必须同口径：热路径把 ABORTED 归一成 NOT_STARTED，
    -- 冷路径原样回 ABORTED 会让对账（只认 NOT_STARTED 才重投）把订单永久停在 GRANTING
    t.it("maps an archived ABORTED op to NOT_STARTED like the hot path", function()
        local h = harness()
        h.store.critical = {}
        local ledger = {
            critical_find = function()
                return { status = "ABORTED", response = { errcode = 4003 } }
            end,
        }
        local q = h.critical.query(h.entity, OP_A, { ledger = ledger })
        t.expect(q.status).to.equal("NOT_STARTED")
    end)

    t.it("does nothing when nothing is old enough", function()
        local h = harness()
        with_ops(h, {
            [OP_A] = { status = "COMMITTED", op_type = "shop.buy", at = 990 },
        }, 990)
        local ledger = fake_ledger()
        local stats = assert(h.critical.archive_ops(h.entity, { ledger = ledger }, { now = 1000, retention = 500 }))
        t.expect(stats.archived).to.equal(0)
        t.expect(#ledger.upserts).to.equal(0)
    end)

    t.it("requires a ledger collection", function()
        local h = harness()
        with_ops(h, {}, nil)
        local stats, err = h.critical.archive_ops(h.entity, {}, {})
        t.expect(stats).to.be_nil()
        t.expect(err).to.match("ledger")
    end)

    -- 批处理中途失败时，前面几条只是**写进了冷账本**，热账本一条都没删。
    -- 如果这时报 archived=#moved，维护服务会把"没归档"计成"已归档"，
    -- 指标虚高、积压被掩盖，而热账本其实还在增长
    t.it("reports zero archived when the batch fails midway", function()
        local h = harness()
        local OP_C = "srv_" .. string.rep("c", 64)
        with_ops(h, {
            [OP_A] = { status = "COMMITTED", op_type = "shop.buy", at = 100 },
            [OP_B] = { status = "COMMITTED", op_type = "shop.buy", at = 200 },
            [OP_C] = { status = "COMMITTED", op_type = "shop.buy", at = 300 },
        }, 100)
        local ledger = fake_ledger()
        local n = 0
        function ledger:critical_find_and_modify()
            n = n + 1
            if n == 2 then
                error("mongo down")
            end
            return "CONFIRMED"
        end

        local stats, err = h.critical.archive_ops(h.entity, { ledger = ledger }, { now = 1000, retention = 500 })
        t.expect(err).to.match("raised")
        -- 冷账本确实写了 1 条，但热账本一条都没删，所以"已归档"必须是 0
        t.expect(stats.archived).to.equal(0)
        t.expect(stats.written).to.equal(1)
        t.expect(stats.pending).to.equal(3)
        t.expect(stats.retry).to.equal(true)
        t.expect(h.store.critical._critical_ops_v1[OP_A]).to_not.be_nil()
        t.expect(h.store.critical._critical_ops_v1[OP_B]).to_not.be_nil()
        t.expect(h.store.critical._critical_ops_v1[OP_C]).to_not.be_nil()
    end)

    -- 热条目已归档时，查询必须回落到冷账本；否则会把"已提交"报成"没执行"
    t.it("falls back to the ledger when the hot record is gone", function()
        local h = harness()
        with_ops(h, {}, nil)
        local ledger = fake_ledger({ archived_doc = { status = "COMMITTED", response = { gold = 1 } } })

        local result = h.critical.query(h.entity, OP_A, { ledger = ledger })
        t.expect(result.status).to.equal("COMMITTED")
        t.expect(result.archived).to.equal(true)
        t.expect(ledger.find.op_id).to.equal(OP_A)
    end)

    t.it("reports UNKNOWN when the ledger read fails", function()
        local h = harness()
        with_ops(h, {}, nil)
        local ledger = fake_ledger()
        function ledger:critical_find()
            return nil, "socket closed"
        end
        local result = h.critical.query(h.entity, OP_A, { ledger = ledger })
        -- 读失败不等于没有记录
        t.expect(result.status).to.equal("UNKNOWN")
    end)
end)

-- PREPARE 写进库的东西，必须能被 dbmgr.load 的 extract 原样读回来。
-- 曾经生产写 64 位 hex、加载侧只收 32 字符，导致任何残留 PREPARED 的角色
-- 在崩溃恢复时被拒绝加载；测试桩用假摘要，所以全绿也没能发现
t.describe("critical 保留字段往返", function()
    t.it("PREPARE 写入的意图能通过加载侧校验", function()
        local h = harness()
        local critical_fields = require "skyext.critical_fields"
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)

        local prepare = h.store.updates[1]
        local intent = assert(prepare.update["$set"]["_critical_intent_v1"])
        t.expect(critical_fields.is_param_hash(intent.param_hash)).to.equal(true)
        t.expect(h.critical.PARAM_HASH_HEX_LEN).to.equal(critical_fields.PARAM_HASH_HEX_LEN)

        local clean, critical = critical_fields.extract({
            rid = 7,
            _version = 1,
            _critical_intent_v1 = intent,
        })
        t.expect(clean ~= nil).to.equal(true)
        -- 关键字段必须从交给 orm.decode 的那张表里剥离，不能进 dropped
        t.expect(clean["_critical_intent_v1"] == nil).to.equal(true)
        t.expect(critical["_critical_intent_v1"].param_hash).to.equal(intent.param_hash)
    end)

    t.it("拒绝截断的或非十六进制的摘要", function()
        local critical_fields = require "skyext.critical_fields"
        local function rejected(hash)
            local clean = critical_fields.extract({
                rid = 7,
                _critical_intent_v1 = {
                    op_id = string.rep("a", 32) .. "_0001",
                    op_type = "shop.buy",
                    param_hash = hash,
                    state = "PREPARED",
                },
            })
            return clean == nil
        end
        t.expect(rejected(string.rep("a", 32))).to.equal(true)
        t.expect(rejected(string.rep("z", 64))).to.equal(true)
        t.expect(rejected(string.rep("a", 64))).to.equal(false)
    end)
end)

-- 归档把热条目 $unset 之后，同一个 op_id 的历史只剩冷账本。
-- 提交内核若不回落查询，就会把"已发奖"当成第一次执行，重复扣费/发奖
t.describe("critical 归档后重放", function()
    local function call(h, ledger)
        return h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, h.handlers(), {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
            ledger = ledger,
        })
    end

    t.it("replays an archived commit instead of writing a second one", function()
        local h = harness()
        local hash = assert(h.critical.param_hash("shop.buy", { amount = 1 }, HASH))
        local ledger = {
            critical_find = function()
                return {
                    op_type = "shop.buy",
                    param_hash = hash,
                    source_namespace = "grant",
                    source_id = string.rep("a", 32),
                    status = "COMMITTED",
                    response = { gold = 999 },
                }
            end,
        }
        local result = call(h, ledger)
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(result.response.gold).to.equal(999)
        t.expect(h.applied).to.equal(0)
        t.expect(#h.store.updates).to.equal(0)
    end)

    t.it("returns UNKNOWN instead of committing when the ledger read fails", function()
        local h = harness()
        local ledger = {
            critical_find = function()
                return nil, "socket closed"
            end,
        }
        local result = call(h, ledger)
        t.expect(result.status).to.equal(h.critical.STATUS.UNKNOWN)
        t.expect(h.applied).to.equal(0)
        t.expect(#h.store.updates).to.equal(0)
    end)

    t.it("still commits a first-time op when no ledger is configured", function()
        local h = harness()
        local result = call(h, nil)
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(h.applied).to.equal(1)
    end)
end)

-- 触顶是受控拒绝，不会自动扩容：必须在 80% 就看到趋势。
-- 预警按实体只打一次，否则 80% 之后每条操作都刷一行日志
t.describe("critical 容量预警", function()
    local function many_ops(h, n)
        local ops = {}
        for i = 1, n do
            ops[string.format("srv_%064x", i)] = { status = "COMMITTED", at = h.now - 100000 }
        end
        return ops
    end

    t.it("warns once when the op ledger crosses the warning line", function()
        local h = harness()
        h.store.critical = { _critical_ops_v1 = many_ops(h, 420) }
        local result = h.client(1)
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(h.entity.capacity_warned_ops).to.equal(true)
    end)

    t.it("warns once when the outbox crosses the warning line", function()
        local h = harness()
        local box = {}
        for i = 1, 420 do
            box[string.format("evt_%064x", i)] = { status = "DELIVERED", updated_at = h.now - 100 }
        end
        h.store.critical = { _critical_outbox_v1 = box, _critical_outbox_pending_count = 0 }
        local result = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, h.handlers(), {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
            outbox = {
                {
                    event_id = "evt_" .. string.rep("e", 64),
                    target_type = "role",
                    target_id = 9,
                    op_type = "mail.send",
                    param_hash = string.rep("a", 64),
                    status = "PENDING",
                },
            },
        })
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(h.entity.capacity_warned_outbox).to.equal(true)
    end)

    -- 真正触顶、开始腾挪时最需要预警：旧的 elseif 恰好漏掉这一刻
    t.it("still warns when the outbox is full and eviction kicks in", function()
        local h = harness()
        local box = {}
        for i = 1, h.critical.MAX_OUTBOX do
            box[string.format("evt_%064x", i)] = { status = "DELIVERED", updated_at = h.now - 100 }
        end
        h.store.critical = { _critical_outbox_v1 = box, _critical_outbox_pending_count = 0 }
        local result = h.critical.execute_client(h.entity, h.new_grant(), 1, "shop.buy", { amount = 1 }, h.handlers(), {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
            outbox = {
                {
                    event_id = "evt_" .. string.rep("e", 64),
                    target_type = "role",
                    target_id = 9,
                    op_type = "mail.send",
                    param_hash = string.rep("a", 64),
                    status = "PENDING",
                },
            },
        })
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(h.entity.capacity_warned_outbox).to.equal(true)
    end)
end)

-- 签发侧与验证侧时钟不同步：偏差窗口内的未来签发放行，超出窗口拒绝
t.describe("critical Grant 时钟偏差", function()
    local function run(h, over)
        return h.critical.execute_client(h.entity, h.new_grant(over), 1, "shop.buy", { amount = 1 }, h.handlers(), {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
        })
    end

    t.it("rejects a grant issued beyond the allowed skew", function()
        local h = harness()
        local result = run(h, { issued_at = h.now + h.critical.GRANT_CLOCK_SKEW + 1 })
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(result.reason).to.equal("grant issued in the future")
        t.expect(h.applied).to.equal(0)
        t.expect(#h.store.updates).to.equal(0)
    end)

    t.it("accepts a grant issued within the allowed skew", function()
        local h = harness()
        local result = run(h, { issued_at = h.now + h.critical.GRANT_CLOCK_SKEW })
        t.expect(result.status).to.equal(h.critical.STATUS.COMMITTED)
        t.expect(h.applied).to.equal(1)
    end)

    -- 整值浮点是"未来时间检查"的经典绕过口：JSON 往返、TS Number 序列化、
    -- 某些 driver 的 BSON 解码都可能把 1700000000 变成 1700000000.0。
    -- 用 math.type(...)=="integer" 当门会让这类值整条跳过检查，等于门不存在
    t.it("rejects a future grant whose issued_at is an integer-valued float", function()
        local h = harness()
        local future = (h.now + h.critical.GRANT_CLOCK_SKEW + 3600) + 0.0
        t.expect(math.type(future)).to.equal("float")
        -- expires_at 必须晚于 issued_at，否则签名阶段就会以 "invalid expires_at" 拒绝，
        -- 测不到未来时间检查本身
        local result = run(h, { issued_at = future, expires_at = future + 3600 })
        t.expect(result.status).to.equal(h.critical.STATUS.INTERNAL_AUTH_DENIED)
        t.expect(result.reason).to.equal("grant issued in the future")
        t.expect(h.applied).to.equal(0)
        t.expect(#h.store.updates).to.equal(0)
    end)
end)

-- 同一秒创建的事件只靠 created_at 排不出确定顺序；因果序号在同一次 CAS 里分配
t.describe("critical Outbox 因果序号", function()
    local function commit(h, seq, event_id)
        return h.critical.execute_client(h.entity, h.new_grant(), seq, "shop.buy", { amount = 1 }, h.handlers(), {
            hmac_fn = HASH,
            hash_fn = HASH,
            equal_fn = EQ,
            now = h.now,
            outbox = {
                {
                    event_id = event_id,
                    target_type = "role",
                    target_id = 9,
                    op_type = "mail.send",
                    param_hash = string.rep("a", 64),
                    status = "PENDING",
                },
            },
        })
    end

    t.it("assigns a monotonic causal sequence across commits", function()
        local h = harness()
        local e1 = "evt_" .. string.rep("1", 64)
        local e2 = "evt_" .. string.rep("2", 64)
        assert(commit(h, 1, e1))
        assert(commit(h, 2, e2))
        local box = h.store.critical._critical_outbox_v1
        t.expect(box[e1].causal_seq).to.equal(1)
        t.expect(box[e2].causal_seq).to.equal(2)
        -- 序号水位与事件同一次 CAS 落库
        t.expect(h.store.critical._critical_outbox_seq).to.equal(2)
    end)

    -- 版本冲突下最容易出的问题不是重号，而是"水位被失败的那次写推进了"：
    -- 序号出现空洞（1,3,4），排序仍对但会让人误判丢事件。
    -- COMMIT 的 CAS 失败会返回 UNKNOWN 交给调用方重试，这里断言那次失败
    -- 既没有落事件，也没有推进水位
    t.it("does not advance the sequence for a commit that never landed", function()
        local h = harness()
        local e1 = "evt_" .. string.rep("3", 64)
        -- PREPARE 是第 1 次写入，COMMIT 是第 2 次：只让 COMMIT 失败一次
        h.store.reject = true
        h.store.reject_at = 2
        local first = commit(h, 1, e1)
        t.expect(first.status).to.equal(h.critical.STATUS.UNKNOWN)
        -- 落库侧什么都没留下：水位没推进、事件没写入
        t.expect(h.store.critical._critical_outbox_seq).to.be_nil()
        t.expect(h.store.critical._critical_outbox_v1).to.be_nil()

        -- CAS 未命中说明 apply 已经改过内存，这份内存不能再回存：必须隔离重载。
        -- 重试由重载后的实体发起，水位从 1 重新开始，不会出现空洞
        t.expect(h.store.state).to.equal("CRITICAL_QUARANTINED")
    end)
end)
