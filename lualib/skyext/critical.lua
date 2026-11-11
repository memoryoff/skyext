-- 关键经济操作的统一提交内核（P08）。
--
-- 两个入口、一个内核：
--   critical.execute_client(entity, grant, seq, op_type, params, handlers)
--     —— 客户端已认证请求。校验 Grant 签名、rid、有效期、seq 范围。
--   critical.execute_internal(entity, service_op_id, op_type, params, handlers)
--     —— 可信内部调用（支付回调 / Outbox 接收方 / Saga 步骤）。不接受 Grant，
--        只认 capability（见 skyext.capability）。
--
-- 两者都进入同一个 critical_commit_core：
--   实体队列 -> dbmgr 行锁 -> 纯读预检 -> PREPARE(majority) -> COMMIT(majority)
--
-- 状态只由持久化文档说话：
--   _critical_intent_v1            未决意图（PREPARE 写了，COMMIT 清掉）
--   _critical_ops_v1[op_id]        已结算操作（COMMITTED / BUSINESS_REJECTED / ABORTED）
--
-- 关键约束：
--   * PREPARE 只写意图与 _version，**不写普通 ORM 脏字段**；
--   * `validate` / `apply` 必须是纯内存、不 yield、不 DB、不 RPC、不推送；
--   * UNKNOWN 一律隔离缓存并返回 recovery 信息，绝不重试成"没写"，也不声称成功。
local capability = require "skyext.capability"
local dbmgr = require "skyext.dbmgr"
local fingerprint = require "skyext.fingerprint"
local grant = require "skyext.grant"
local log = require "skyext.log"
local metrics = require "skyext.metrics"
local orm = require "orm"

local M = {}

M.STATUS = {
    COMMITTED = "COMMITTED",
    BUSINESS_REJECTED = "BUSINESS_REJECTED",
    PRECHECK_REJECTED = "PRECHECK_REJECTED",
    OP_CONFLICT = "OP_CONFLICT",
    EXPIRED = "EXPIRED",
    INTERNAL_AUTH_DENIED = "INTERNAL_AUTH_DENIED",
    UNKNOWN = "UNKNOWN",
    -- 只出现在 query 结果里
    NOT_STARTED = "NOT_STARTED",
    IN_PROGRESS = "IN_PROGRESS",
    EXPIRED_NOT_EXECUTED = "EXPIRED_NOT_EXECUTED",
    CAPACITY_EXCEEDED = "CAPACITY_EXCEEDED",
}

-- 单文档 16 MB 上限之前的安全阈值。超过就受控拒绝新的关键操作并告警，
-- 靠归档吞吐保证平时不触达；不能等 Mongo 报文档过大再处理
M.MAX_OPS = 512

-- 与 sproto_api 的缓存处置保持同一组字面量：PRECHECK_REJECTED / UNKNOWN 是瞬时结果，
-- 一旦进 L1 就会被固定成"永远拒绝"或"永远未知"
M.CACHEABLE = "cacheable"
M.NO_CACHE = "no_cache"

M.INTENT_FIELD = "_critical_intent_v1"
M.OPS_FIELD = "_critical_ops_v1"
M.OUTBOX_FIELD = "_critical_outbox_v1"

M.EVENT_PREFIX = "evt_"
M.SERVICE_PREFIX = "srv_"
M.HEX64_LEN = 64

M.JOB_STATE = {
    PENDING = "PENDING",
    CLAIMING_FENCE = "CLAIMING_FENCE",
    READING = "READING",
    RESOLVING = "RESOLVING",
    COMPLETED_COMMITTED = "COMPLETED_COMMITTED",
    COMPLETED_NOT_COMMITTED = "COMPLETED_NOT_COMMITTED",
    RETRY_WAIT = "RETRY_WAIT",
    MANUAL_REVIEW = "MANUAL_REVIEW",
}

-- 关键路径必须能观测：三态次数、隔离原因、恢复任务状态。
-- 这些都是本 VM 的本地累加，抓取时由 .metrics 服务合并
local m_decisions =
    metrics.counter("skyext_critical_decisions_total", "Critical operation decisions by status", { "status" })
local m_quarantined =
    metrics.counter("skyext_critical_quarantined_total", "Critical caches quarantined by reason", { "reason" })

local function hex(bytes)
    return (bytes:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

local function now_of(opts)
    return (opts and opts.now) or os.time()
end

-- ---------------------------------------------------------------------------
-- 操作键
-- ---------------------------------------------------------------------------

-- event_id -> service_op_id：**字节级一一映射**，不依赖 HMAC / 密钥 / 进程 / 时间。
-- 同一事件在任何节点、任何进程、任何测试工具上结果都相同；重试不得重新随机生成。
function M.service_op_id_from_event(event_id)
    if type(event_id) ~= "string" or #event_id ~= #M.EVENT_PREFIX + M.HEX64_LEN then
        return nil, "invalid event_id"
    end
    if event_id:sub(1, #M.EVENT_PREFIX) ~= M.EVENT_PREFIX then
        return nil, "invalid event_id"
    end
    local suffix = event_id:sub(#M.EVENT_PREFIX + 1)
    if not suffix:match("^[0-9a-f]+$") then
        return nil, "invalid event_id"
    end
    return M.SERVICE_PREFIX .. suffix
end

-- 只接受规范形式，不做归一化：op_id 直接当 Mongo 字段名与去重键
function M.validate_service_op_id(service_op_id)
    if type(service_op_id) ~= "string" or #service_op_id ~= #M.SERVICE_PREFIX + M.HEX64_LEN then
        return false, "invalid service_op_id"
    end
    if service_op_id:sub(1, #M.SERVICE_PREFIX) ~= M.SERVICE_PREFIX then
        return false, "invalid service_op_id"
    end
    if not service_op_id:sub(#M.SERVICE_PREFIX + 1):match("^[0-9a-f]+$") then
        return false, "invalid service_op_id"
    end
    return true
end

-- Mongo 字段名不能含 NUL / `.` / 以 `$` 开头。op_id 会直接拼进 `$set` 的路径
local function field_name_safe(op_id)
    if type(op_id) ~= "string" or #op_id == 0 or #op_id > 128 then
        return false
    end
    if op_id:find("%z") or op_id:find("%.") or op_id:sub(1, 1) == "$" then
        return false
    end
    return true
end
M.field_name_safe = field_name_safe

-- ---------------------------------------------------------------------------
-- 上下文与决策
-- ---------------------------------------------------------------------------

-- entity 只需提供 db 坐标。真实实体是 { rid, dbname, dbcoll, key, unique_id, handle }；
-- 测试可以直接给 db_coords
local function coords_of(entity)
    local c = entity.db_coords or entity
    local dbname, dbcoll = c.dbname, c.dbcoll
    if type(dbname) ~= "string" or type(dbcoll) ~= "string" then
        return nil, "entity has no db coordinates"
    end
    local key = c.key or "rid"
    local unique_id = c.unique_id or entity.rid
    if unique_id == nil then
        return nil, "entity has no unique id"
    end
    return {
        entity = entity,
        dbname = dbname,
        dbcoll = dbcoll,
        key = key,
        unique_id = unique_id,
        handle = c.handle or entity.handle,
        rid = entity.rid or unique_id,
        doc = c.doc or entity.doc,
    }
end
M.coords_of = coords_of

local function decision(status, response, cache_policy, extra)
    local out = {
        status = status,
        response = response,
        cache_policy = cache_policy or M.NO_CACHE,
    }
    for k, v in pairs(extra or {}) do
        out[k] = v
    end
    -- 所有返回路径都经过这里，计数不会漏
    m_decisions:inc(1, { status = status })
    return out
end
M.decision = decision

local function critical_of(ctx)
    return dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
end

local function lookup_op(critical, op_id)
    local ops = critical and critical[M.OPS_FIELD]
    return ops and ops[op_id] or nil
end

-- 把缓存的 critical 复制一份再做增量修改，避免 set_critical 之前就污染了读到的表
-- 两层深拷贝：`_critical_ops_v1` / `_critical_outbox_v1` 都是 map of record，
-- 只拷一层的话 `copy[OPS][op_id] = ...` 写的还是缓存里那张子表，
-- "set_critical 之前不污染缓存"就不成立了
local function copy_value(v, depth)
    if type(v) ~= "table" or depth <= 0 then
        return v
    end
    local out = {}
    for k, sub in pairs(v) do
        out[k] = copy_value(sub, depth - 1)
    end
    return out
end

local function copy_critical(critical)
    return copy_value(critical or {}, 3)
end

-- apply 返回 false 时用它判断 handler 有没有偷偷改内存：ORM 的 revision 变化
-- 或脏字段集合变化都说明"拒绝了但已经改了"
local function deep_equal(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

-- 参数摘要。用与上行幂等同一条规范化 + HMAC 通道：同一 op 换参数必须能被发现
local function param_hash_of(op_type, params, hash_fn)
    local digest, err = fingerprint.compute(op_type, params or {}, hash_fn)
    if not digest then
        return nil, err
    end
    return hex(digest)
end
M.param_hash = param_hash_of

-- ---------------------------------------------------------------------------
-- 提交内核
-- ---------------------------------------------------------------------------

local function fence_of(ctx)
    return ctx.handle and ctx.handle.fence or nil
end

-- 返回 decision。req:
--   op_id / op_type / param_hash / source_namespace / source_id / params / response_meta
local function commit_core(ctx, req, handlers)
    local critical = critical_of(ctx)
    if critical == nil then
        -- 文档没进缓存（或已被隔离）：不能凭空判断"没执行过"
        return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = "document not loaded" })
    end

    -- 内部凭证按需核销：纯读预检拒绝不消耗 cap，其余会暴露状态或产生写入的路径
    -- 都必须先授权。req.authorize 由 execute_internal 提供
    local authorized = false
    local function authorize()
        if authorized then
            return true
        end
        if not req.authorize then
            authorized = true
            return true
        end
        local ok, err = req.authorize()
        if ok then
            authorized = true
            return true
        end
        return false, err
    end

    local function deny(err)
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = err })
    end

    local existing = lookup_op(critical, req.op_id)
    if existing then
        local same = existing.op_type == req.op_type
            and existing.param_hash == req.param_hash
            and existing.source_namespace == req.source_namespace
            and existing.source_id == req.source_id
        if not same then
            -- 同 op_id 换业务类型/参数/来源：这是冲突，不是重放
            local ok, err = authorize()
            if not ok then
                return deny(err)
            end
            return decision(
                M.STATUS.OP_CONFLICT,
                nil,
                M.CACHEABLE,
                { reason = "op_id reused with different parameters" }
            )
        end
        if existing.status == M.STATUS.COMMITTED or existing.status == M.STATUS.BUSINESS_REJECTED then
            local ok, err = authorize()
            if not ok then
                return deny(err)
            end
            return decision(existing.status, existing.response, M.CACHEABLE)
        end
        -- ABORTED / 其它中间态：允许重新 PREPARE，但必须重新过一遍参数校验
    end

    local intent = critical[M.INTENT_FIELD]
    if intent then
        if intent.op_id ~= req.op_id then
            -- 另一个关键操作还没结算。不能让两个意图同时挂在一份文档上
            local ok, err = authorize()
            if not ok then
                return deny(err)
            end
            return decision(
                M.STATUS.IN_PROGRESS,
                nil,
                M.NO_CACHE,
                { reason = "another critical operation is in flight" }
            )
        end
        -- 同 op 的意图：业务类型与参数摘要必须一致，否则就是拿旧意图当新操作的通行证
        if intent.op_type ~= req.op_type or intent.param_hash ~= req.param_hash then
            local ok, err = authorize()
            if not ok then
                return deny(err)
            end
            return decision(
                M.STATUS.OP_CONFLICT,
                nil,
                M.CACHEABLE,
                { reason = "pending intent has different parameters" }
            )
        end
        if intent.owner_fence ~= fence_of(ctx) then
            -- 进程重启/换 owner：同 op 的意图还在，但"COMMIT 从未发出"已经无法证明。
            -- 必须走多数派 Fence 屏障（abort_intent + 重新 PREPARE），不能直接续做
            local ok, err = authorize()
            if not ok then
                return deny(err)
            end
            return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, {
                reason = "pending intent belongs to another owner",
                recovery_id = req.op_id,
            })
        end
    end

    -- 单文档容量硬阈值：超了就受控拒绝新的关键操作，而不是等 Mongo 报文档过大
    local op_count = 0
    for _ in pairs(critical[M.OPS_FIELD] or {}) do
        op_count = op_count + 1
    end
    if op_count >= M.MAX_OPS then
        log.error("critical op ledger is full", "rid", tostring(ctx.rid), "count", op_count, "max", M.MAX_OPS)
        return decision(M.STATUS.CAPACITY_EXCEEDED, nil, M.NO_CACHE, { reason = "critical op ledger is full" })
    end

    -- 纯读预检：不写 PREPARED、不声明持久化拒绝、不进 L1
    if handlers.validate then
        local ok, pass, rejection = pcall(handlers.validate, ctx.entity, req.params)
        if not ok then
            log.error("critical validate raised", "op_id", req.op_id, "err", pass)
            return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = "validate raised" })
        end
        if pass ~= true then
            return decision(M.STATUS.PRECHECK_REJECTED, rejection, M.NO_CACHE)
        end
    end

    -- ---- PREPARE：只写意图 + _version ----
    -- 第一个写入点：到这里才核销内部凭证，纯读预检拒绝不会烧掉 cap
    do
        local ok, err = authorize()
        if not ok then
            return deny(err)
        end
    end
    if not intent then
        local begun, begin_err = dbmgr.begin_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle)
        if not begun then
            return decision(
                M.STATUS.UNKNOWN,
                nil,
                M.NO_CACHE,
                { reason = "cannot enter critical state: " .. tostring(begin_err) }
            )
        end
        local intent_doc = {
            op_id = req.op_id,
            op_type = req.op_type,
            param_hash = req.param_hash,
            source_namespace = req.source_namespace,
            source_id = req.source_id,
            owner_fence = fence_of(ctx),
            prepared_at = req.now,
            state = "PREPARED",
        }
        local state, detail = dbmgr.critical_update(
            ctx.dbname,
            ctx.dbcoll,
            ctx.key,
            ctx.unique_id,
            ctx.doc._version,
            { ["$set"] = { [M.INTENT_FIELD] = intent_doc } },
            { handle = ctx.handle }
        )
        if state ~= "CONFIRMED" then
            if state == "UNKNOWN" then
                dbmgr.end_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle, false)
                return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, {
                    reason = tostring(detail),
                    recovery_id = req.op_id,
                })
            end
            dbmgr.end_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle, true)
            return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = "prepare rejected: " .. tostring(detail) })
        end
        critical = copy_critical(critical)
        critical[M.INTENT_FIELD] = intent_doc
        dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, critical, ctx.handle)
    else
        -- 同 owner 续做：已经有一份同 op 的 PREPARED 意图。仍然要重新进入 PREPARING，
        -- 否则普通回存在 COMMIT 之前插进来推进 _version，COMMIT 的 CAS 条件就失效了
        local begun, begin_err = dbmgr.begin_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle)
        if not begun then
            return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, {
                reason = "cannot resume critical state: " .. tostring(begin_err),
            })
        end
    end

    -- ---- COMMIT：apply 是纯内存，之后一次 CAS 同时写资产与消费记录 ----
    -- 记录 apply 之前的 ORM 快照：handler 违反"拒绝时不得改内存"的约定时，
    -- 脏字段会留在回存轮上，下一次普通 save 就会把被拒绝的操作写进库
    local _, before_snapshot = orm.snapshot_mongo(ctx.doc)
    local ok_apply, applied, rejection = pcall(handlers.apply, ctx.entity, req.params)
    if not ok_apply then
        -- apply 可能已经改了内存但抛错：COMMIT 从未发出，但内存不可信
        dbmgr.quarantine_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle, "apply raised")
        m_quarantined:inc(1, { reason = "apply_raised" })
        log.error("critical apply raised", "op_id", req.op_id, "err", applied)
        return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, {
            reason = "apply raised",
            recovery_id = req.op_id,
        })
    end

    local write
    local op_status
    if applied == true then
        op_status = M.STATUS.COMMITTED
        local dirty, update, revision = orm.snapshot_mongo(ctx.doc)
        write = update or {}
        write["$set"] = write["$set"] or {}
        write["$unset"] = write["$unset"] or {}
        write["$unset"][M.INTENT_FIELD] = true
        ctx.revision = revision
        ctx.dirty = dirty
    else
        -- 业务拒绝：ORM 必须原样不动。改了就不能继续——这份内存再也说不清
        -- 到底哪些改动属于被拒绝的操作，只能隔离重载
        local _, after_snapshot = orm.snapshot_mongo(ctx.doc)
        if not deep_equal(before_snapshot, after_snapshot) then
            dbmgr.quarantine_critical(
                ctx.dbname,
                ctx.dbcoll,
                ctx.unique_id,
                ctx.handle,
                "apply rejected after mutating"
            )
            log.error("critical apply mutated state but reported rejection", "op_id", req.op_id)
            return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, {
                reason = "apply mutated state but reported rejection",
                recovery_id = req.op_id,
            })
        end
        op_status = M.STATUS.BUSINESS_REJECTED
        write = { ["$set"] = {}, ["$unset"] = { [M.INTENT_FIELD] = true } }
    end

    local op_doc = {
        status = op_status,
        op_type = req.op_type,
        param_hash = req.param_hash,
        source_namespace = req.source_namespace,
        source_id = req.source_id,
        response = rejection,
        at = req.now,
    }
    write["$set"][M.OPS_FIELD .. "." .. req.op_id] = op_doc

    local state, detail = dbmgr.critical_update(
        ctx.dbname,
        ctx.dbcoll,
        ctx.key,
        ctx.unique_id,
        ctx.doc._version,
        write,
        { handle = ctx.handle }
    )
    if state ~= "CONFIRMED" then
        if state ~= "UNKNOWN" then
            -- CAS 未命中但内存已经被 apply 改过：这份内存不能回存，也不能继续用
            dbmgr.quarantine_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle, "commit rejected")
            m_quarantined:inc(1, { reason = "commit_rejected" })
        end
        log.error("critical commit not confirmed", "op_id", req.op_id, "state", state, "detail", tostring(detail))
        return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, {
            reason = "commit " .. tostring(state):lower(),
            recovery_id = req.op_id,
        })
    end

    if applied == true then
        -- 数据库已确认：清掉普通脏字段。revision 变了说明 apply 期间有别的写入，
        -- 那是契约被破坏，但已提交的事实不能否认
        local unchanged = orm.ack_mongo(ctx.doc, ctx.revision, detail.version)
        if not unchanged then
            log.error("critical commit changed revision unexpectedly", "op_id", req.op_id)
        end
    end

    critical = copy_critical(critical)
    critical[M.INTENT_FIELD] = nil
    critical[M.OPS_FIELD] = critical[M.OPS_FIELD] or {}
    critical[M.OPS_FIELD][req.op_id] = op_doc
    dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, critical, ctx.handle)
    local ended, end_err = dbmgr.end_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle, true)
    if not ended then
        -- 事务已经提交，状态机没回到 NORMAL 只影响后续能否普通回存，
        -- 不影响已落库的事实，记日志即可
        log.error(
            "critical committed but state did not return to NORMAL",
            "op_id",
            req.op_id,
            "state",
            tostring(end_err)
        )
    end

    return decision(op_status, rejection, M.CACHEABLE, { version = detail.version })
end

-- ---------------------------------------------------------------------------
-- 入口
-- ---------------------------------------------------------------------------

-- grant_fields 是完整 Grant（含 mac）。hmac_fn(key_id, canonical_bytes) 由调用方注入。
function M.execute_client(entity, grant_fields, seq, op_type, params, handlers, opts)
    opts = opts or {}
    handlers = handlers or {}
    if type(grant_fields) ~= "table" then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = "grant is required" })
    end
    if type(opts.hmac_fn) ~= "function" then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = "hmac_fn is required" })
    end
    local ok, err = grant.verify(grant_fields, grant_fields.mac, opts.hmac_fn, opts.equal_fn)
    if not ok then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = err })
    end

    local ctx, cerr = coords_of(entity)
    if not ctx then
        return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = cerr })
    end
    if grant_fields.rid ~= ctx.rid then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = "grant rid mismatch" })
    end

    local now = now_of(opts)
    if now >= grant_fields.expires_at then
        -- 过期授权绝不执行业务；只允许查询
        return decision(M.STATUS.EXPIRED, nil, M.NO_CACHE, { reason = "grant expired" })
    end
    if math.type(seq) ~= "integer" or seq < 1 or seq > grant_fields.max_seq then
        return decision(M.STATUS.EXPIRED, nil, M.NO_CACHE, { reason = "seq out of range" })
    end

    local op_id, operr = grant.op_id(grant_fields.grant_id, seq)
    if not op_id then
        return decision(M.STATUS.EXPIRED, nil, M.NO_CACHE, { reason = operr })
    end
    if not field_name_safe(op_id) then
        return decision(M.STATUS.EXPIRED, nil, M.NO_CACHE, { reason = "op_id is not a safe field name" })
    end

    -- 摘要函数必须单独注入：grant 的 hmac_fn 是按 key_id 选密钥的 (key_id, bytes)，
    -- 直接拿来当摘要函数会让每个请求都算不出 hash
    if type(opts.hash_fn) ~= "function" then
        return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = "hash_fn is required" })
    end
    local param_hash, herr = param_hash_of(op_type, params, opts.hash_fn)
    if not param_hash then
        return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = "param hash failed: " .. tostring(herr) })
    end

    return commit_core(ctx, {
        op_id = op_id,
        op_type = op_type,
        param_hash = param_hash,
        source_namespace = "grant",
        source_id = grant_fields.grant_id,
        params = params,
        now = now,
    }, handlers)
end

-- 可信内部入口：cap 是唯一凭证，字符串 source 不构成鉴权
function M.execute_internal(entity, service_op_id, op_type, params, handlers, opts)
    opts = opts or {}
    handlers = handlers or {}
    local ok, verr = M.validate_service_op_id(service_op_id)
    if not ok then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = verr })
    end

    local ctx, cerr = coords_of(entity)
    if not ctx then
        return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = cerr })
    end

    if type(opts.hash_fn) ~= "function" then
        return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = "hash_fn is required" })
    end
    local param_hash, herr = param_hash_of(op_type, params, opts.hash_fn)
    if not param_hash then
        return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = "param hash failed: " .. tostring(herr) })
    end

    -- 来源必须由分发器显式给出：cap 里已经绑定了 source_id，落库归属不能由
    -- 调用方随手改写，也不能缺省成 nil 让冲突检测失效
    if type(opts.source_id) ~= "string" or #opts.source_id == 0 then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = "source_id is required" })
    end

    local cap = opts.capability
    if cap == nil then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = "capability is required" })
    end
    -- 先做一次无副作用核验：明显伪造/过期/绑定不符的 cap 不必走到读取状态
    local verified, cap_err = capability.verify(cap, {
        rid = ctx.rid,
        service_op_id = service_op_id,
        op_type = op_type,
        payload_hash = param_hash,
        source_id = opts.source_id,
    }, now_of(opts))
    if not verified then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = cap_err })
    end

    return commit_core(ctx, {
        op_id = service_op_id,
        op_type = op_type,
        param_hash = param_hash,
        source_namespace = opts.source_namespace or "internal",
        source_id = opts.source_id,
        params = params,
        now = now_of(opts),
        -- 真正核销放在第一个写入点之前：纯读预检拒绝不该烧掉凭证
        authorize = function()
            return capability.consume(cap, {
                rid = ctx.rid,
                service_op_id = service_op_id,
                op_type = op_type,
                payload_hash = param_hash,
                source_id = opts.source_id,
            }, now_of(opts))
        end,
    }, handlers)
end

-- ---------------------------------------------------------------------------
-- 查询
-- ---------------------------------------------------------------------------

-- 只报告**持久化消费状态**，不报告未持久化的纯读预检
function M.query(entity, op_id, opts)
    opts = opts or {}
    local ctx, cerr = coords_of(entity)
    if not ctx then
        return { status = M.STATUS.UNKNOWN, reason = cerr }
    end
    local critical = critical_of(ctx)
    if critical == nil then
        -- 读不到不等于没执行过
        return { status = M.STATUS.UNKNOWN, reason = "document not loaded" }
    end
    local op = lookup_op(critical, op_id)
    if op then
        if op.status == M.STATUS.COMMITTED or op.status == M.STATUS.BUSINESS_REJECTED then
            return { status = op.status, response = op.response }
        end
        if op.status == "ABORTED" then
            -- 取消不等于已消费：没有业务效果，但参数一致性仍由后续 PREPARE 检查
            return { status = M.STATUS.NOT_STARTED }
        end
        return { status = M.STATUS.IN_PROGRESS }
    end
    if critical[M.INTENT_FIELD] then
        return { status = M.STATUS.IN_PROGRESS }
    end
    if opts.grant_expires_at and now_of(opts) >= opts.grant_expires_at then
        return { status = M.STATUS.EXPIRED_NOT_EXECUTED }
    end
    return { status = M.STATUS.NOT_STARTED }
end

-- ---------------------------------------------------------------------------
-- 恢复：取消未决意图
-- ---------------------------------------------------------------------------

-- 只在调用方**已经用多数派 Fence 屏障证明旧 owner 不可能再提交**之后调用。
-- 一次 CAS 同时写 ABORTED 终态与清除意图：只做 $unset 的话，ACK 丢失后
-- 无法区分"取消成功"和"根本没取消"。
function M.abort_intent(ctx_or_entity, opts)
    opts = opts or {}
    local ctx = ctx_or_entity.dbname and ctx_or_entity or coords_of(ctx_or_entity)
    if not ctx then
        return "REJECTED", "invalid context"
    end
    local critical = critical_of(ctx)
    local intent = critical and critical[M.INTENT_FIELD]
    if not intent then
        return "REJECTED", "no pending intent"
    end
    local op_doc = {
        status = "ABORTED",
        op_type = intent.op_type,
        param_hash = intent.param_hash,
        source_namespace = intent.source_namespace,
        source_id = intent.source_id,
        at = opts.now or os.time(),
    }
    local state, detail = dbmgr.critical_update(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, ctx.doc._version, {
        ["$set"] = { [M.OPS_FIELD .. "." .. intent.op_id] = op_doc },
        ["$unset"] = { [M.INTENT_FIELD] = true },
    }, { handle = ctx.handle })
    if state ~= "CONFIRMED" then
        return state, detail
    end
    local copy = copy_critical(critical)
    copy[M.INTENT_FIELD] = nil
    copy[M.OPS_FIELD] = copy[M.OPS_FIELD] or {}
    copy[M.OPS_FIELD][intent.op_id] = op_doc
    dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, copy, ctx.handle)
    return "CONFIRMED", { version = detail.version, op_id = intent.op_id }
end

-- ---------------------------------------------------------------------------
-- 恢复任务（critical_reconcile_jobs）
-- ---------------------------------------------------------------------------
--
-- 任务表只负责调度与观察，**不是资产状态权威**。资产结果永远取角色文档的
-- _critical_* 与多数派 Fence 认领结果。

local function job_id(rid, op_id)
    return tostring(rid) .. ":" .. op_id
end
M.job_id = job_id

-- 幂等补建/唤醒：同一 (rid, op_id) 只对应一份逻辑任务
function M.reconcile(jobs_coll, rid, op_id, opts)
    opts = opts or {}
    if not field_name_safe(op_id) then
        return nil, "invalid op_id"
    end
    local now = opts.now or os.time()
    local ret, err = jobs_coll:find_and_modify({
        query = { rid = rid, op_id = op_id },
        update = {
            ["$setOnInsert"] = {
                task_id = job_id(rid, op_id),
                rid = rid,
                op_id = op_id,
                state = M.JOB_STATE.PENDING,
                attempt = 0,
                job_version = 0,
                old_fence = opts.old_fence,
                target_fence = opts.target_fence,
                created_at = now,
            },
            ["$set"] = { updated_at = now, last_error = opts.last_error },
        },
        upsert = true,
        new = true,
    })
    if type(ret) ~= "table" or ret.ok ~= 1 then
        return nil, (type(ret) == "table" and ret.errmsg) or err or "reconcile upsert failed"
    end
    local job = ret.value
    if type(job) ~= "table" then
        -- upsert 命中已有文档但 new=true 未返回：回读一次
        job = jobs_coll:find_one({ rid = rid, op_id = op_id })
    end
    if type(job) ~= "table" then
        return nil, "reconcile job not readable"
    end
    return job
end

function M.reconcile_status(jobs_coll, rid, op_id)
    local job = jobs_coll:find_one({ rid = rid, op_id = op_id })
    if type(job) ~= "table" then
        return nil, "not found"
    end
    return job
end

-- 原子抢占：只有 (owner, lease_until, job_version) 都匹配的旧租约才能被接管。
-- 返回 true 表示这次调用拿到了任务
function M.claim_job(jobs_coll, rid, op_id, owner, lease_until, opts)
    opts = opts or {}
    -- job_version 缺省会让这个字段根本不进 BSON，query 就退化成"没有版本条件"，
    -- 任何协调者都能抢走正在被处理的任务
    if math.type(opts.job_version) ~= "integer" then
        return false, "job_version must be an integer"
    end
    if math.type(lease_until) ~= "integer" then
        return false, "lease_until must be an integer"
    end
    local now = opts.now or os.time()
    local query = {
        rid = rid,
        op_id = op_id,
        job_version = opts.job_version,
        -- 已终结的任务不能再被抢：finish_job 会 $unset lease_until，
        -- 只按"租约过期"匹配的话它会重新变成可认领
        state = { ["$in"] = { M.JOB_STATE.PENDING, M.JOB_STATE.CLAIMING_FENCE, M.JOB_STATE.RETRY_WAIT } },
        ["$or"] = {
            { lease_until = { ["$lte"] = now } },
            { lease_until = { ["$exists"] = false } },
        },
    }
    local state, ret = jobs_coll:critical_find_and_modify({
        query = query,
        update = {
            ["$set"] = {
                owner = owner,
                lease_until = lease_until,
                updated_at = now,
                state = M.JOB_STATE.CLAIMING_FENCE,
            },
            ["$inc"] = { job_version = 1, attempt = 1 },
        },
        new = true,
    })
    if state ~= "CONFIRMED" then
        return false, state
    end
    local value = type(ret) == "table" and ret.value or nil
    if type(value) ~= "table" then
        return false, "already claimed"
    end
    return true, value
end

function M.finish_job(jobs_coll, rid, op_id, job_version, state_name, opts)
    opts = opts or {}
    local state, ret = jobs_coll:critical_find_and_modify({
        query = { rid = rid, op_id = op_id, job_version = job_version },
        update = {
            ["$set"] = { state = state_name, updated_at = opts.now or os.time(), last_error = opts.last_error },
            ["$unset"] = { lease_until = true, owner = true },
            ["$inc"] = { job_version = 1 },
        },
        new = true,
    })
    if state ~= "CONFIRMED" then
        return false, state
    end
    return type(ret) == "table" and type(ret.value) == "table"
end

-- ---------------------------------------------------------------------------
-- 索引
-- ---------------------------------------------------------------------------
--
-- 索引不存在或不符合预期时**禁止启用关键业务模块**：没有
-- `_critical_intent_v1.state` 的索引，恢复扫描就是全表扫描；没有唯一索引，
-- 多协调者会为同一 op 建出多份任务。

function M.index_specs(colls)
    return {
        {
            colls.role,
            {
                { ["_critical_intent_v1.state"] = 1 },
                { rid = 1 },
                name = "critical_intent_state",
                partialFilterExpression = { ["_critical_intent_v1.state"] = "PREPARED" },
            },
        },
        { colls.jobs, { { rid = 1 }, { op_id = 1 }, name = "rid_op_id", unique = true } },
        { colls.jobs, { { state = 1 }, { lease_until = 1 }, name = "state_lease" } },
        { colls.ledger, { { rid = 1 }, { op_id = 1 }, name = "rid_op_id", unique = true } },
    }
end

-- 返回 true 或 nil, err；任一索引建失败都视为门禁未通过
function M.ensure_indexes(colls)
    for _, spec in ipairs(M.index_specs(colls)) do
        local coll, keys = spec[1], spec[2]
        if not coll then
            return nil, "missing collection for index " .. tostring(keys.name)
        end
        local called, ok, err = pcall(coll.create_index, coll, keys)
        if not called then
            return nil, "create_index raised: " .. tostring(ok)
        end
        -- 驱动把 runCommand 的原始回复直接返回：失败是 {ok=0, errmsg=...} 的表，
        -- 只看 nil/false 会把失败当成功，门禁在最需要它的时候放行
        if type(ok) == "table" then
            if ok.ok ~= 1 then
                return nil, "create_index failed: " .. tostring(ok.errmsg or keys.name)
            end
        elseif ok ~= true then
            return nil, "create_index failed: " .. tostring(err or keys.name)
        end
    end
    return true
end

return M
