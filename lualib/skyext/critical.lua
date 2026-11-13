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
local critical_fields = require "skyext.critical_fields"
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
    -- 确定**零写入**的内部/环境故障：纯读预检（validate）抛错，或 PREPARE 被拒
    -- （版本/CAS/fence/租约不符、更新非法、多数派通道缺失）。
    -- 不能复用 UNKNOWN —— 那是"可能写了"，会触发隔离与恢复任务，而查询侧只会看到
    -- NOT_STARTED，调用方拿到的两个答案互相矛盾。允许受控重试。
    -- 缓存是否一并隔离由拒绝原因决定：内存已不是库的副本时必须隔离（见 PREPARE_STALE_CODES）
    INTERNAL_ERROR = "INTERNAL_ERROR",
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
-- 归档保留期与单次搬运上限
M.ARCHIVE_RETENTION = 7 * 24 * 3600
M.ARCHIVE_LIMIT = 64
-- 只有已结算的状态才能离开热账本：PREPARED/中间态搬走等于丢掉未决证据
M.ARCHIVE_SETTLED = {
    [M.STATUS.COMMITTED] = true,
    [M.STATUS.BUSINESS_REJECTED] = true,
    ["ABORTED"] = true,
}

-- 单角色未清理的 Outbox 条目上限。超过就拒绝新事件：`_critical_outbox_v1`
-- 和 `_critical_ops_v1` 共享 512 KiB 的关键字段预算，无上限增长会让角色
-- 在下次加载时直接 fail-closed
M.MAX_OUTBOX = 512
-- 允许签发侧与验证侧的时钟偏差（秒）。超过这个窗口的"未来签发"直接拒绝：
-- 否则一个时钟偏快的签发节点可以让 Grant 提前生效，而时钟偏慢的验证节点
-- 会把合法 Grant 误判成过期。两个方向共用同一个窗口。
M.GRANT_CLOCK_SKEW = 60

-- 已投递 / 停在 ENQUEUED 的事件的保留期。到达上限时**不等**保留期：
-- 先腾掉这些事件让新事件进来（见 evictable_outbox_events）
-- 定义在 critical_fields 里：outbox 也要用同一份数字，而两边都会被测试桩替换
M.OUTBOX_DELIVERED_RETENTION = critical_fields.OUTBOX_DELIVERED_RETENTION
M.OUTBOX_ENQUEUED_RETENTION = critical_fields.OUTBOX_ENQUEUED_RETENTION
-- FAILED（投递彻底失败）的最小保留期。容量腾挪时**不能**沿用
-- delivered_retention：那条路径把它传成 0，一条"资产已扣、可靠消息从未落库"
-- 的事件会在下一秒被静默抹掉，连排查和补偿的依据都不剩。
-- 1 小时足够让告警打出来、人工看到 failed_reason
M.OUTBOX_FAILED_MIN_RETENTION = critical_fields.OUTBOX_FAILED_MIN_RETENTION

-- 容量预警线：到 80% 就告警，给归档与清理留出反应时间。
-- 触顶是受控拒绝（不是自动扩容），所以必须提前看到趋势
M.CAPACITY_WARN_RATIO = 0.8

-- 与 sproto_api 的缓存处置保持同一组字面量：PRECHECK_REJECTED / UNKNOWN 是瞬时结果，
-- 一旦进 L1 就会被固定成"永远拒绝"或"永远未知"
M.CACHEABLE = "cacheable"
M.NO_CACHE = "no_cache"

-- 字段名只有一处定义（critical_fields.M.FIELDS 的白名单）。这里全部引用它，
-- 不再各写一份字面量：曾经因为两边各写一个字面量，导致残留 PREPARED 的角色
-- 文档在加载时被当成损坏数据拒绝。新增 `_critical_*` 字段时，
-- 只要登记进 critical_fields，这里自动跟随，不会再出现"写了但加载被拒"
M.INTENT_FIELD = critical_fields.INTENT
M.OPS_FIELD = critical_fields.OPS
M.OUTBOX_FIELD = critical_fields.OUTBOX
-- 待发事件计数：既是索引字段，也是"离开 PENDING 时恰减一次"的凭据
M.OUTBOX_PENDING_FIELD = critical_fields.OUTBOX_PENDING
-- 持久化因果序号：同一角色的事件按它排序，不依赖秒级 created_at。
-- 与可靠消息的 msg_id 是两件事：msg_id 只保证唯一，不保证因果顺序。
M.OUTBOX_SEQ_FIELD = critical_fields.OUTBOX_SEQ
-- 终态清理时刻：worker 靠它找到"回执丢了、pending_count 已归零"的角色
M.OUTBOX_CLEANUP_FIELD = critical_fields.OUTBOX_CLEANUP
-- 热账本最老一条操作的 `at`：归档扫描的索引字段
M.OPS_OLDEST_FIELD = critical_fields.OPS_OLDEST

M.EVENT_PREFIX = "evt_"
M.SERVICE_PREFIX = "srv_"
M.HEX64_LEN = 64

-- 摘要格式只在这里定义一次，加载侧的校验也用同一个常量
M.PARAM_HASH_HEX_LEN = critical_fields.PARAM_HASH_HEX_LEN

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
local m_archive = metrics.counter("skyext_critical_archive_total", "Critical op archive attempts", { "result" })
local m_outbox_evicted = metrics.counter(
    "skyext_critical_outbox_evicted_total",
    "Outbox events evicted from the source document to make room",
    { "reason" }
)
local m_capacity_warn = metrics.counter(
    "skyext_critical_capacity_warning_total",
    "Entities that crossed the critical capacity warning line",
    { "kind" }
)
local m_same_owner_resume = metrics.counter(
    "skyext_critical_same_owner_resume_total",
    "Critical operations resumed by the same owner after a PREPARE",
    { "op_type" }
)

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

-- 源侧 Outbox 事件的形状校验。生产端把事件交给提交内核，由内核与资产增量
-- 在**同一次 CAS** 里落库；形状不对的事件必须在 PREPARE 之前拒绝，
-- 否则会写进一个投递端永远解析不了的记录
local function validate_outbox_events(events)
    if type(events) ~= "table" then
        return nil, "outbox must be a table"
    end
    -- 必须是连续数组：`#` 对带洞表的结果不确定，而调用方用 `#events` 计数、
    -- 这里按下标写入。两者口径不一致时，一条畸形输入就能让 pending_count
    -- 永久偏高（正是"丢分片且计数永不收敛"那条）
    local count = 0
    local max_index = 0
    for k in pairs(events) do
        if math.type(k) ~= "integer" or k < 1 then
            return nil, "outbox must be a dense array"
        end
        count = count + 1
        if k > max_index then
            max_index = k
        end
    end
    if max_index ~= count then
        return nil, "outbox must be a dense array"
    end
    -- 批内 event_id 必须唯一：同一次 CAS 里 `$set` 同一路径写两次只留最后一份，
    -- 而 pending_count 按条数计。结果是第二个分片的业务效果永久丢失
    local seen = {}
    for i = 1, count do
        local ev = events[i]
        if type(ev) ~= "table" then
            return nil, "outbox event #" .. i .. " must be a table"
        end
        if not field_name_safe(ev.event_id) then
            return nil, "outbox event #" .. i .. " has an invalid event_id"
        end
        if seen[ev.event_id] then
            return nil, "outbox event #" .. i .. " duplicates event_id " .. ev.event_id
        end
        seen[ev.event_id] = true
        local _, oerr = M.service_op_id_from_event(ev.event_id)
        if oerr then
            return nil, "outbox event #" .. i .. " has an invalid event_id"
        end
        if type(ev.target_type) ~= "string" or #ev.target_type == 0 then
            return nil, "outbox event #" .. i .. " needs target_type"
        end
        if ev.target_id == nil then
            return nil, "outbox event #" .. i .. " needs target_id"
        end
        if type(ev.op_type) ~= "string" or #ev.op_type == 0 then
            return nil, "outbox event #" .. i .. " needs op_type"
        end
        if type(ev.param_hash) ~= "string" or #ev.param_hash ~= 64 then
            return nil, "outbox event #" .. i .. " needs a 64 hex param_hash"
        end
        if ev.status ~= "PENDING" then
            return nil, "outbox event #" .. i .. " must start as PENDING"
        end
    end
    return true
end
M.validate_outbox_events = validate_outbox_events

-- 容量不足时可以腾掉哪些事件（最老的在前，最多 need 个）：
--   DELIVERED  终态，只用于审计，随时可删
--   ENQUEUED   超过保留期说明接收方长期没上线；可靠消息已经把消息持久化，
--              源端副本删掉不影响业务效果（去重键由 event_id 派生）
--   FAILED     投递彻底失败（可靠消息从未落库）。**它是这条事件唯一的记录**：
--              源端资产已经扣了，删掉之后既不能重投也没有补偿依据。所以它有
--              与终态一致的 7 天最小保留期（不能沿用容量路径的 delivered=0），
--              到期被腾时还要单独打 error 与 failed_lost 指标
--   PENDING    永不腾：它还没投出去
-- 状态字面量来自 skyext.outbox.STATUS；这里不 require outbox，避免循环依赖
function M.evictable_outbox_events(outbox_table, now, need, opts)
    opts = opts or {}
    if type(need) ~= "number" or need <= 0 then
        return {}
    end
    -- 默认与 outbox.cleanup 共用同一份保留期。容量压力下由调用方显式传 0，
    -- 不再靠"没传 opts"隐式把 DELIVERED 变成 0 秒即删（两套口径会让刚 ACK
    -- 的审计记录立刻消失，迟到重复回执只能走 unknown event）。
    local delivered_retention = opts.delivered_retention or M.OUTBOX_DELIVERED_RETENTION
    local enqueued_retention = opts.enqueued_retention or M.OUTBOX_ENQUEUED_RETENTION
    local failed_retention = opts.failed_retention or M.OUTBOX_FAILED_MIN_RETENTION
    local list = {}
    for event_id, event in pairs(outbox_table or {}) do
        if type(event) == "table" then
            local age = now - (event.updated_at or event.created_at or now)
            local evict
            if event.status == "DELIVERED" then
                evict = age >= delivered_retention
            elseif event.status == "ENQUEUED" then
                evict = age >= enqueued_retention
            elseif event.status == "FAILED" then
                -- 不能沿用 delivered_retention：容量路径把它传成 0，
                -- 一条"资产已扣、消息从未投出"的事件会在下一秒被静默抹掉
                evict = age >= failed_retention
            end
            if evict then
                list[#list + 1] = { id = event_id, age = age, status = event.status }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.age ~= b.age then
            return a.age > b.age
        end
        return a.id < b.id
    end)
    local out = {}
    for i = 1, math.min(#list, need) do
        out[i] = list[i].id
    end
    return out
end

-- ---------------------------------------------------------------------------
-- 上下文与决策
-- ---------------------------------------------------------------------------

-- entity 只需提供 db 坐标。真实实体是 { rid, dbname, dbcoll, key, unique_id, handle }；
-- 测试可以直接给 db_coords。
--
-- 实体系统本身不往 entity 上塞 dbname/dbcoll：坐标在 `entity_mgr.type_config` 里，
-- 只有 `db_name/db_coll/id_field`。这里做一次回退，否则所有真实实体调用都会
-- 变成"entity has no db coordinates"，只能靠游戏层自己补 db_coords
local function coords_of(entity)
    local c = entity.db_coords or entity
    local dbname, dbcoll = c.dbname, c.dbcoll
    local tc = entity.entity_mgr and entity.entity_mgr.type_config
    if type(dbname) ~= "string" or type(dbcoll) ~= "string" then
        if type(tc) == "table" then
            dbname, dbcoll = tc.db_name, tc.db_coll
        end
    end
    if type(dbname) ~= "string" or type(dbcoll) ~= "string" then
        return nil, "entity has no db coordinates"
    end
    local key = c.key or (tc and tc.id_field) or "rid"
    local unique_id = c.unique_id or entity.rid or entity.id
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
        -- 实体把 ORM 文档放在 data 里；dbmgr 的 _version 就挂在它上面
        doc = c.doc or entity.doc or entity.data,
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
    local out = hex(digest)
    -- 写进去的长度必须与 critical_fields.validate_intent 的校验一致。
    -- 这里直接 fail-closed，避免再次出现"写得出、加载不回"的元数据
    if not critical_fields.is_param_hash(out) then
        return nil, "param hash has an unexpected format"
    end
    return out
end
-- 接收方（Outbox / Saga）要用同一个摘要函数校验"同一事件换了参数"，
-- 因此导出而不是复制一份实现：两份实现的规范化差异就是两套指纹
M.param_hash_of = param_hash_of
M.param_hash = param_hash_of

-- ---------------------------------------------------------------------------
-- 提交内核
-- ---------------------------------------------------------------------------

local function fence_of(ctx)
    return ctx.handle and ctx.handle.fence or nil
end

-- dbmgr 的原因码（测试桩可能不带，按空表处理：缺省时一律当作"缓存仍可信"，
-- 也就是退回加白名单之前的处置方式，不会凭空隔离玩家）
local REASON = dbmgr.REASON or {}

-- PREPARE 被拒时，哪些原因说明**缓存已经不是库的副本**。
-- 这几类继续用旧缓存回存只会每轮 CAS 失败刷日志，玩家读到的也是过期数据；
-- 必须隔离，等实体重载后再重试。格式/配置类拒绝（更新非法、多数派通道缺失）
-- 不影响缓存可信度，回到 NORMAL 即可。
local PREPARE_STALE_CODES = {
    [REASON.VERSION_MISMATCH] = true,
    [REASON.CAS_MISMATCH] = true,
    [REASON.LEASE_EXPIRED] = true,
    [REASON.STATE_INVALID] = true,
}

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
    -- 热条目被归档移走后，同 op_id 的历史事实只剩冷账本。不查就把"已发奖"
    -- 报成 NOT_STARTED，重放会二次入账。读失败一律 UNKNOWN，绝不猜测"没执行过"
    if not existing and req.ledger then
        local called, archived, aerr = pcall(req.ledger.critical_find, req.ledger, {
            rid = ctx.rid,
            op_id = req.op_id,
        }, { _id = false })
        if not called then
            return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, { reason = "ledger read raised" })
        end
        if archived == nil and aerr ~= nil then
            return decision(M.STATUS.UNKNOWN, nil, M.NO_CACHE, {
                reason = "ledger read failed: " .. tostring(aerr),
            })
        end
        if type(archived) == "table" then
            existing = archived
        end
    end
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

    -- 同 owner 续做：同一个 op 的意图还在，说明上一次 PREPARE 之后进程没崩。
    -- 这个比例高说明 COMMIT 经常没发出，是容量/延迟问题的先兆
    if intent and intent.op_id == req.op_id and intent.owner_fence == fence_of(ctx) then
        m_same_owner_resume:inc(1, { op_type = req.op_type })
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
    if op_count >= M.MAX_OPS * M.CAPACITY_WARN_RATIO then
        -- 只告警一次（按实体）：否则 80% 之后每条操作都刷一行
        if ctx.entity and not ctx.entity.capacity_warned_ops then
            ctx.entity.capacity_warned_ops = true
            m_capacity_warn:inc(1, { kind = "ops" })
            log.warn(
                "critical op ledger is approaching capacity",
                "rid",
                tostring(ctx.rid),
                "count",
                op_count,
                "max",
                M.MAX_OPS
            )
        end
    end

    -- 源侧 Outbox：与资产增量进同一次 CAS。形状/容量在 PREPARE 之前校验，
    -- 免得把一条投递端永远解析不了的事件写进文档
    local new_events = req.outbox
    -- 容量不足时腾掉的事件：必须和 COMMIT 写在同一次 CAS 里，
    -- 单独先删会让"删了事件但资产没提交"变成一个新的不一致
    local evicted_events
    if new_events ~= nil then
        local ok, oerr = validate_outbox_events(new_events)
        if not ok then
            log.error("critical outbox event rejected", "op_id", req.op_id, "err", oerr)
            return decision(M.STATUS.PRECHECK_REJECTED, nil, M.NO_CACHE, { reason = oerr })
        end
        local existing_events = 0
        for _ in pairs(critical[M.OUTBOX_FIELD] or {}) do
            existing_events = existing_events + 1
        end
        if existing_events + #new_events > M.MAX_OUTBOX then
            -- 先腾终态/超期事件：DELIVERED 只是审计，留着不如让新事件进来。
            -- 不这么做的话，事件只增不减，这个角色最终会被永久拒绝
            local need = existing_events + #new_events - M.MAX_OUTBOX
            -- 触顶是有意放弃 DELIVERED 保留期：先腾终态再决定是否拒绝，
            -- 但必须显式写出来，不能依赖"没传 opts 就当 0"的隐式行为。
            -- FAILED 单独给最小保留期：它是"资产已扣、消息从未投出"的唯一记录
            evicted_events = M.evictable_outbox_events(critical[M.OUTBOX_FIELD], req.now, need, {
                delivered_retention = 0,
                failed_retention = M.OUTBOX_FAILED_MIN_RETENTION,
            })
            existing_events = existing_events - #evicted_events
            if #evicted_events > 0 then
                m_outbox_evicted:inc(#evicted_events, { reason = "capacity" })
                -- 腾掉 FAILED 是**丢证据**：必须单独打一条 error，带 event_id 与
                -- failed_reason，否则事后既查不到是哪笔、也查不到为什么失败
                for _, victim in ipairs(evicted_events) do
                    if victim.status == "FAILED" then
                        local ev = (critical[M.OUTBOX_FIELD] or {})[victim.id]
                        m_outbox_evicted:inc(1, { reason = "failed_lost" })
                        log.error(
                            "evicting a FAILED outbox event at capacity; this is the last record of a deducted asset",
                            "rid",
                            tostring(ctx.rid),
                            "event",
                            tostring(victim.id),
                            "age",
                            tostring(victim.age),
                            "failed_reason",
                            tostring(ev and ev.failed_reason)
                        )
                    end
                end
                log.warn(
                    "outbox is at capacity, evicting settled events",
                    "rid",
                    tostring(ctx.rid),
                    "evicted",
                    #evicted_events
                )
            end
        end
        -- 预警必须独立于腾挪：真正触顶、开始删事件时最需要告警，
        -- 挂在 elseif 上恰好把这一刻排除掉了。只按实体打一次，避免刷屏。
        if existing_events >= M.MAX_OUTBOX * M.CAPACITY_WARN_RATIO then
            if ctx.entity and not ctx.entity.capacity_warned_outbox then
                ctx.entity.capacity_warned_outbox = true
                m_capacity_warn:inc(1, { kind = "outbox" })
                log.warn(
                    "critical outbox is approaching capacity",
                    "rid",
                    tostring(ctx.rid),
                    "count",
                    existing_events,
                    "max",
                    M.MAX_OUTBOX
                )
            end
        end
        if existing_events + #new_events > M.MAX_OUTBOX then
            log.error(
                "critical outbox is full",
                "rid",
                tostring(ctx.rid),
                "count",
                existing_events,
                "max",
                M.MAX_OUTBOX
            )
            return decision(M.STATUS.CAPACITY_EXCEEDED, nil, M.NO_CACHE, { reason = "outbox is full" })
        end
    end

    -- 纯读预检：不写 PREPARED、不声明持久化拒绝、不进 L1
    if handlers.validate then
        local ok, pass, rejection = pcall(handlers.validate, ctx.entity, req.params)
        if not ok then
            -- 这里还没进 PREPARE，库里的状态仍然是"没执行过"。报 UNKNOWN 会让调用方
            -- 去查恢复任务、隔离缓存，而 critical.query 只会回 NOT_STARTED
            log.error("critical validate raised", "op_id", req.op_id, "err", pass)
            return decision(M.STATUS.INTERNAL_ERROR, nil, M.NO_CACHE, { reason = "validate raised" })
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
        local state, detail, code = dbmgr.critical_update(
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
            -- 到这里**确定没有写入**：返回 UNKNOWN 会让调用方去查恢复任务、隔离缓存，
            -- 而 critical.query 只会回 NOT_STARTED，两个答案互相矛盾。
            -- 但"没写"不等于"缓存还能用"：版本/CAS/fence/租约类拒绝说明内存已经
            -- 不是库的副本，继续回存只会每轮失败并把过期数据喂给玩家 —— 隔离等重载。
            --
            -- owner_changed 例外：条目已经归新的 owner，旧 handle 连改状态的资格都没有，
            -- 这里什么都不做（也不去碰 end_critical）
            if code ~= REASON.OWNER_CHANGED then
                if PREPARE_STALE_CODES[code] then
                    dbmgr.end_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle, false)
                    m_quarantined:inc(1, { reason = "prepare_" .. tostring(code) })
                    log.error(
                        "critical prepare rejected with a stale cache, quarantining",
                        "op_id",
                        req.op_id,
                        "code",
                        tostring(code),
                        "detail",
                        tostring(detail)
                    )
                else
                    -- 格式/配置类拒绝：缓存仍然可信，回到 NORMAL 才能继续普通回存
                    dbmgr.end_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle, true)
                end
            end
            return decision(M.STATUS.INTERNAL_ERROR, nil, M.NO_CACHE, {
                reason = "prepare rejected: " .. tostring(code or detail),
            })
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
        -- 源侧扣减与 Outbox 必须同一次 CAS：先扣资源再单独写事件，
        -- 中间崩溃就会留下"钱扣了、事件没发"的永久不一致
        if new_events and #new_events > 0 then
            -- 因果序号与事件同一次 CAS 分配：重启、重试、多节点都不会重号，
            -- 同秒创建的事件也能靠它排出确定顺序
            local seq_base = math.tointeger(critical[M.OUTBOX_SEQ_FIELD]) or 0
            for _, ev in ipairs(new_events) do
                seq_base = seq_base + 1
                ev.causal_seq = seq_base
                write["$set"][M.OUTBOX_FIELD .. "." .. ev.event_id] = ev
            end
            write["$set"][M.OUTBOX_SEQ_FIELD] = seq_base
            write["$set"][M.OUTBOX_PENDING_FIELD] = (critical[M.OUTBOX_PENDING_FIELD] or 0) + #new_events
        end
        if evicted_events and #evicted_events > 0 then
            -- 与新增事件同一次写入：容量腾挪不能单独提交
            for _, event_id in ipairs(evicted_events) do
                write["$unset"][M.OUTBOX_FIELD .. "." .. event_id] = true
            end
        end
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
    -- 归档扫描的索引字段：只增不减的最小值，归档自己会重算。
    -- **必须两种终态都维护**：BUSINESS_REJECTED 同样占一条热账本，只给 COMMITTED 写
    -- 水位会让这些角色永远不被归档扫描命中，攒到 MAX_OPS 之后连新操作都提交不了
    local oldest = critical[M.OPS_OLDEST_FIELD]
    if math.type(oldest) ~= "integer" or (math.type(req.now) == "integer" and req.now < oldest) then
        write["$set"][M.OPS_OLDEST_FIELD] = req.now
    end

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
    -- 与库里同口径：业务拒绝也要推进水位，否则内存副本会比库"更早忘记"还有老操作
    local oldest = critical[M.OPS_OLDEST_FIELD]
    if math.type(oldest) ~= "integer" or (math.type(req.now) == "integer" and req.now < oldest) then
        critical[M.OPS_OLDEST_FIELD] = req.now
    end
    if applied == true and new_events and #new_events > 0 then
        critical[M.OUTBOX_FIELD] = critical[M.OUTBOX_FIELD] or {}
        local seq_base = math.tointeger(critical[M.OUTBOX_SEQ_FIELD]) or 0
        for _, ev in ipairs(new_events) do
            -- 写入分支已经分配过；这里只同步内存副本的序号水位
            if math.type(ev.causal_seq) == "integer" and ev.causal_seq > seq_base then
                seq_base = ev.causal_seq
            end
            critical[M.OUTBOX_FIELD][ev.event_id] = copy_value(ev, 3)
        end
        critical[M.OUTBOX_SEQ_FIELD] = seq_base
        critical[M.OUTBOX_PENDING_FIELD] = (critical[M.OUTBOX_PENDING_FIELD] or 0) + #new_events
    end
    if applied == true and evicted_events and #evicted_events > 0 and critical[M.OUTBOX_FIELD] then
        -- 内存副本也要删：库里已经 $unset，留着会让下一次容量判断少腾一条
        for _, event_id in ipairs(evicted_events) do
            critical[M.OUTBOX_FIELD][event_id] = nil
        end
    end
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
    -- 漏传 equal_fn 会让 grant.verify 静默退回 `==`：mac 比较变成非常量时间，
    -- 而且违反模块自己写的使用约定。这种接线错误必须在入口就炸掉，不能靠注释提醒
    if type(opts.equal_fn) ~= "function" then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = "equal_fn is required" })
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
    -- 未来签发超过允许的时钟偏差：拒绝，避免时钟偏快的签发侧让 Grant 提前生效。
    -- 窗口内的偏差放行，否则两边时钟差几秒就会误伤合法请求。
    --
    -- 必须用 math.tointeger 归一化后再比，不能用 math.type(...)=="integer" 当门：
    -- 那是个 fail-open 的类型门，`issued_at = 1700000000.0`（JSON 往返或 TS Number
    -- 序列化都可能产生整值浮点）会整条跳过检查，伪造的未来 Grant 直接放行。
    -- 归一化失败说明字段本身不合法，按 fail-closed 拒绝
    local issued_at = math.tointeger(grant_fields.issued_at)
    if not issued_at then
        return decision(
            M.STATUS.INTERNAL_AUTH_DENIED,
            nil,
            M.NO_CACHE,
            { reason = "grant issued_at is not an integer" }
        )
    end
    if issued_at > now + M.GRANT_CLOCK_SKEW then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = "grant issued in the future" })
    end
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
        outbox = opts.outbox,
        ledger = opts.ledger,
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

    -- 优先取受控分发上下文（capability.run_with）。旧调用方显式传 opts.capability
    -- 仍然兼容，但两者同时存在且不一致时必须拒绝，不能让旁路参数盖过当前上下文
    local current_cap = capability.current()
    if current_cap ~= nil and opts.capability ~= nil and current_cap ~= opts.capability then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, {
            reason = "capability does not match the dispatch context",
        })
    end
    local cap = current_cap or opts.capability
    if cap == nil then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, { reason = "capability is required" })
    end
    -- cap 必须来自受信任分发入口的命名空间，不能是任意自造 issuer 签出来的
    local cap_namespace = capability.namespace_of(cap)
    if not cap_namespace or not capability.ALLOWED_NAMESPACES[cap_namespace] then
        return decision(M.STATUS.INTERNAL_AUTH_DENIED, nil, M.NO_CACHE, {
            reason = "capability has an untrusted namespace",
        })
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
        outbox = opts.outbox,
        ledger = opts.ledger,
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
    if opts.majority_read then
        -- 内存副本可能落后于库：PREPARE 落库但 ACK 丢失时，`commit_core` 的 UNKNOWN
        -- 分支不会 `set_critical`，内存里根本没有那条意图。恢复任务若按内存判定，
        -- 就会把"已写入 PREPARE"当成"从未执行"，把任务写成 COMPLETED 后再也复不开。
        -- 这里用多数派读把版本与关键元数据对齐，之后的判断才代表持久化事实
        local ok, ver = dbmgr.refresh_critical(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, { handle = ctx.handle })
        if not ok then
            return { status = M.STATUS.UNKNOWN, reason = "majority read failed: " .. tostring(ver) }
        end
        critical = critical_of(ctx)
        if critical == nil then
            return { status = M.STATUS.UNKNOWN, reason = "document not loaded" }
        end
    end
    local op = lookup_op(critical, op_id)
    if not op and opts.ledger then
        -- 热条目已经被归档：不查冷账本就会把"已提交"报成"没执行"，
        -- 那会让调用方重放一次本该只执行一次的操作。
        -- 驱动抛错与返回 err 一样处理：读失败不等于没有记录，必须回结构化 UNKNOWN
        -- （提交路径的同一处查询用的是 pcall，这里不能比它更弱）
        local called, archived, aerr = pcall(opts.ledger.critical_find, opts.ledger, {
            rid = ctx.rid,
            op_id = op_id,
        }, { _id = false })
        if not called then
            return { status = M.STATUS.UNKNOWN, reason = "ledger read raised: " .. tostring(archived) }
        end
        if archived == nil and aerr ~= nil then
            -- 读失败不等于没有记录
            return { status = M.STATUS.UNKNOWN, reason = "ledger read failed: " .. tostring(aerr) }
        end
        if type(archived) == "table" then
            -- 与热路径同口径：取消不等于已消费。冷分支原样回 ABORTED 会让
            -- 对账（只认 NOT_STARTED 才重投）把订单永久停在 GRANTING
            local status = archived.status == "ABORTED" and M.STATUS.NOT_STARTED or archived.status
            return { status = status, response = archived.response, archived = true }
        end
    end
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
        -- 带上意图归属：恢复任务要判断"挂着的是不是自己这条 op"，
        -- 只有自己那条才能在持新 fence 的前提下主动取消
        local intent = critical[M.INTENT_FIELD]
        return {
            status = M.STATUS.IN_PROGRESS,
            intent_op_id = type(intent) == "table" and intent.op_id or nil,
        }
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
    if opts.majority_read then
        -- 与 query 同因：内存里没有意图不代表库里没有。恢复任务必须先对齐持久化状态
        local ok, ver = dbmgr.refresh_critical(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, { handle = ctx.handle })
        if not ok then
            return "UNKNOWN", "majority read failed: " .. tostring(ver)
        end
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
    }, { handle = ctx.handle, allow_quarantined_intent_abort = true })
    if state ~= "CONFIRMED" then
        return state, detail
    end
    local copy = copy_critical(critical)
    copy[M.INTENT_FIELD] = nil
    copy[M.OPS_FIELD] = copy[M.OPS_FIELD] or {}
    copy[M.OPS_FIELD][intent.op_id] = op_doc
    dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, copy, ctx.handle)
    -- 隔离态取消意图之后，内存里的普通字段仍可能带着 apply 的痕迹，不能回 NORMAL
    -- 继续服务。标作废，让 unload 直接丢弃，下一次请求从库重读就是干净状态。
    -- 只有**原本就隔离**的条目才需要标：正常态取消意图后内存仍然可信。
    -- 标记失败必须报 UNKNOWN 让任务重试——否则库里意图已清、内存意图还在，
    -- scan_intents 不再按库建任务，这个实体就永远出不去了
    local state_now = dbmgr.state_of(ctx.dbname, ctx.dbcoll, ctx.unique_id)
    if state_now == "CRITICAL_QUARANTINED" then
        local marked = dbmgr.mark_discarded(ctx.dbname, ctx.dbcoll, ctx.unique_id, ctx.handle)
        if not marked then
            return "UNKNOWN", "mark_discarded failed"
        end
    end
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
-- 归档（热 _critical_ops_v1 -> 冷 op_ledger）
-- ---------------------------------------------------------------------------
--
-- 顺序是硬约束：**先多数派 upsert 到冷账本，确认后才 CAS 删除热字段**。
-- 反过来会留下"热里没有、冷里也没有"的窗口，那个操作记录就永久消失了。
--
-- 必须在该角色 owner 的实体队列内调用：删除热字段是一次 `_version` CAS，
-- 绕过 owner 会和业务请求抢同一个版本。

-- 扫描口径：热账本里有超过保留期的条目
function M.archive_query(now, retention)
    return { [M.OPS_OLDEST_FIELD] = { ["$lte"] = (now or os.time()) - (retention or M.ARCHIVE_RETENTION) } }
end

function M.archive_ops(ctx_or_entity, deps, opts)
    opts = opts or {}
    local ctx = ctx_or_entity.dbname and ctx_or_entity or coords_of(ctx_or_entity)
    if not ctx then
        return nil, "invalid context"
    end
    local ledger = deps and deps.ledger
    if type(ledger) ~= "table" then
        return nil, "ledger collection is required"
    end
    local now = opts.now or os.time()
    local retention = opts.retention or M.ARCHIVE_RETENTION
    local limit = opts.limit or M.ARCHIVE_LIMIT

    local critical = critical_of(ctx)
    if not critical then
        return nil, "document not loaded"
    end
    local ops = critical[M.OPS_FIELD] or {}

    local victims = {}
    for op_id, op in pairs(ops) do
        if
            type(op) == "table"
            and M.ARCHIVE_SETTLED[op.status]
            and math.type(op.at) == "integer"
            and op.at <= now - retention
        then
            victims[#victims + 1] = { op_id = op_id, op = op }
        end
    end
    if #victims == 0 then
        return { archived = 0 }
    end
    table.sort(victims, function(a, b)
        return a.op.at < b.op.at
    end)
    while #victims > limit do
        victims[#victims] = nil
    end

    local moved = {}
    for _, v in ipairs(victims) do
        -- 驱动抛异常时不能向上冒泡：热条目还没删，异常传到维护服务只会被
        -- 吞成一轮静默失败。转成与 "ledger unknown" 一样的结构化结果，
        -- 保证"两边都没有"的情况永远不会发生。
        local called, state = pcall(ledger.critical_find_and_modify, ledger, {
            query = { rid = ctx.rid, op_id = v.op_id },
            update = {
                -- 身份字段只在插入时写；状态类字段必须可更新：
                -- 同一个 op_id 可能先以 ABORTED 归档，之后被重放成 COMMITTED 再归档一次。
                -- 只写 $setOnInsert 会让冷账本永久停在第一次的状态，query 从此报"未执行"，
                -- 调用方据此重放 → 二次入账
                ["$setOnInsert"] = {
                    rid = ctx.rid,
                    op_id = v.op_id,
                },
                ["$set"] = {
                    status = v.op.status,
                    op_type = v.op.op_type,
                    param_hash = v.op.param_hash,
                    source_namespace = v.op.source_namespace,
                    source_id = v.op.source_id,
                    response = v.op.response,
                    at = v.op.at,
                    archived_at = now,
                },
            },
            upsert = true,
            new = true,
        })
        if not called then
            m_archive:inc(1, { result = "raised" })
            -- archived 必须报 0：这批 op 只是写进了冷账本，热账本一条都还没删。
            -- 报 #moved 会让维护服务把"没归档"计成"已归档"，指标虚高且掩盖积压。
            -- 冷账本写用 $setOnInsert，重试幂等，所以下一轮会重新走一遍
            return { archived = 0, written = #moved, pending = #victims, retry = true },
                "ledger write raised: " .. tostring(state)
        end
        if state ~= "CONFIRMED" then
            -- 冷账本没确认就绝不删热条目：宁可两边都留一份，也不能两边都没有
            m_archive:inc(1, { result = tostring(state):lower() })
            return { archived = 0, written = #moved, pending = #victims, retry = true },
                "ledger " .. tostring(state):lower()
        end
        moved[#moved + 1] = v.op_id
    end

    local unset = {}
    for _, op_id in ipairs(moved) do
        unset[M.OPS_FIELD .. "." .. op_id] = true
    end
    -- 重算最老时间：剩下的条目可能都比保留期新
    local moved_set = {}
    for _, op_id in ipairs(moved) do
        moved_set[op_id] = true
    end
    local remaining_oldest
    for op_id, op in pairs(ops) do
        if not moved_set[op_id] and type(op) == "table" and math.type(op.at) == "integer" then
            if not remaining_oldest or op.at < remaining_oldest then
                remaining_oldest = op.at
            end
        end
    end
    local update = { ["$unset"] = unset }
    if remaining_oldest then
        update["$set"] = { [M.OPS_OLDEST_FIELD] = remaining_oldest }
    else
        unset[M.OPS_OLDEST_FIELD] = true
    end

    local state, detail = dbmgr.critical_update(
        ctx.dbname,
        ctx.dbcoll,
        ctx.key,
        ctx.unique_id,
        ctx.doc._version,
        update,
        { handle = ctx.handle, metadata_only = true }
    )
    if state ~= "CONFIRMED" then
        -- 热条目还在、冷账本多一份副本：重复归档是幂等的（$setOnInsert）
        m_archive:inc(1, { result = tostring(state):lower() })
        return { archived = 0, retry = true }, state
    end

    local copy = copy_critical(critical)
    copy[M.OPS_FIELD] = copy[M.OPS_FIELD] or {}
    for _, op_id in ipairs(moved) do
        copy[M.OPS_FIELD][op_id] = nil
    end
    copy[M.OPS_OLDEST_FIELD] = remaining_oldest
    dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, copy, ctx.handle)
    m_archive:inc(1, { result = "ok" })
    log.info(
        "critical ops archived",
        "rid",
        tostring(ctx.rid),
        "moved",
        #moved,
        "remaining_oldest",
        tostring(remaining_oldest),
        "version",
        tostring(detail and detail.version)
    )
    return { archived = #moved, remaining = remaining_oldest }
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
        {
            colls.role,
            {
                { [M.OPS_OLDEST_FIELD] = 1 },
                name = "critical_ops_oldest",
                partialFilterExpression = { [M.OPS_OLDEST_FIELD] = { ["$exists"] = true } },
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
