-- Transactional Outbox（P13）。
--
-- 根本约束：`router.reliable_send` 每次都会分配新的 `msg_id`，所以"重试同一事件"
-- **不会**自动去重底层队列消息。这里不修改队列主键，改用**消息信封**：
--
--   A 的角色文档在**一次 CAS** 里同时持久化：资产扣减、消费记录、
--   `_critical_outbox_v1[event_id] = {status="PENDING", ...}`
--
--   投递时带 `event_id`（重试不变），接收方用 `service_op_id_from_event(event_id)`
--   得到稳定业务键，经 `critical.execute_internal` 保证至多一次业务效果。
--
-- 状态机：
--   PENDING --(可靠消息已确认入队)--> ENQUEUED --(接收方 ACK)--> DELIVERED
--   任何一步失败都可退回 PENDING 重试；ENQUEUED 只表示"入队已确认"，
--   **不等于 B 已入账**。
--
-- 与 `critical` 的分工：本模块只负责事件记录、信封、状态 CAS 与批处理调度；
-- 资产效果永远由 `critical` 的提交内核决定。
local critical = require "skyext.critical"
-- 字段名从**白名单模块**取，不从 critical 取：白名单是这些名字唯一的定义处，
-- 而 critical 会被测试桩替换。曾经因为 outbox 自己写了一份字面量、
-- critical 也写了一份，导致新字段漏登记白名单，写过 Outbox 的角色加载即失败
local critical_fields = require "skyext.critical_fields"
local delivery = require "skyext.entity.delivery"
local dbmgr = require "skyext.dbmgr"
local log = require "skyext.log"
local metrics = require "skyext.metrics"

local M = {}

M.STATUS = {
    PENDING = "PENDING",
    ENQUEUED = "ENQUEUED",
    DELIVERED = "DELIVERED",
    FAILED = "FAILED",
}

M.FIELD = critical_fields.OUTBOX
-- 与 critical 共用同一份字段名，不另写字面量：两处各写一份曾导致
-- "写进去了但加载时被判 unknown critical field"
M.PENDING_COUNT_FIELD = critical_fields.OUTBOX_PENDING
-- 终态清理时刻。没有它，worker 只按 pending_count>0 扫，
-- 回执丢失（事件停在 ENQUEUED、计数已归零）的角色永远不再被扫，
-- 终态事件只能等容量腾挪——那正是它该解决的问题
M.CLEANUP_FIELD = critical_fields.OUTBOX_CLEANUP
M.ENVELOPE_VERSION = 1
M.DEFAULT_LIMIT = 16
-- 状态 CAS 的读后像重试次数。CAS 未命中是版本/条件冲突，不是 UNKNOWN，
-- 但也不能无限重试：有界退让后保持 PENDING，交给下一轮扫描
M.CAS_RETRY = 2
-- 已投递事件的保留期：DELIVERED 只用于审计，过期就能删。
-- 容量不足时不等保留期，直接腾（见 critical.commit_core）
-- 与 critical 共用同一份口径（定义在 critical_fields）：不要在这里另写一个数字
M.DELIVERED_RETENTION = critical_fields.OUTBOX_DELIVERED_RETENTION
-- 停在 ENQUEUED 多久算"送不到了"。可靠消息已经把消息持久化，
-- 源端副本只用于观测；接收方长期不上线时，不能让这份副本把关键字段占满
M.ENQUEUED_RETENTION = critical_fields.OUTBOX_ENQUEUED_RETENTION

local m_enqueued =
    metrics.counter("skyext_outbox_enqueued_total", "Outbox events whose reliable message was confirmed", { "op_type" })
-- 毒事件被隔离的次数：持续增长说明有事件永远投不出去，需要人工看 failed_reason
local m_failed = metrics.counter(
    "skyext_outbox_quarantined_total",
    "Outbox events quarantined as FAILED after repeated delivery failures",
    { "op_type" }
)
local m_unknown = metrics.counter(
    "skyext_outbox_status_unknown_total",
    "Outbox status CAS whose result could not be confirmed",
    { "op_type" }
)
local m_cas_retry = metrics.counter(
    "skyext_outbox_cas_retry_total",
    "Outbox status CAS retried after a version/condition conflict",
    { "op_type" }
)
local m_acked = metrics.counter("skyext_outbox_acked_total", "Outbox events acknowledged by the receiver", { "result" })
local m_delivered_age = metrics.histogram(
    "skyext_outbox_delivered_seconds",
    "Seconds from outbox event creation to receiver ack",
    { "op_type" }
)
local m_evicted =
    metrics.counter("skyext_outbox_evicted_total", "Outbox events removed from the source document", { "reason" })

local function hex(bytes)
    return (bytes:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

local RNG_UNAVAILABLE = "rng unavailable"

-- 事件 ID 必须由可信来源**一次**生成，并与源角色的 Outbox 记录一起持久化。
-- 重试时重新随机生成会让去重彻底失效。
function M.new_event_id(random_bytes)
    local rng = random_bytes
    if not rng then
        local ok, crypto = pcall(require, "crypto")
        if not ok or type(crypto) ~= "table" or type(crypto.random_bytes) ~= "function" then
            return nil, RNG_UNAVAILABLE
        end
        rng = crypto.random_bytes
    end
    local called, bytes = pcall(rng, 32)
    if not called then
        return nil, "rng failed"
    end
    if type(bytes) ~= "string" or #bytes ~= 32 then
        return nil, "invalid rng output"
    end
    return critical.EVENT_PREFIX .. hex(bytes)
end

-- 生成一条待持久化的 Outbox 记录。
--
-- `param_hash` 必须是**接收方**要重算的那份摘要（`op_type + payload`），
-- 不是源操作参数的摘要：接收方校验不通过会按永久无效 ACK，事件静默消失。
-- 传 `hash_fn` 时这里直接算；同时传了 `param_hash` 就校验两者一致。
function M.event(opts)
    if type(opts) ~= "table" then
        return nil, "opts must be a table"
    end
    local event_id = opts.event_id
    if type(event_id) ~= "string" then
        return nil, "event_id is required"
    end
    local _, err = critical.service_op_id_from_event(event_id)
    if err then
        return nil, err
    end
    if type(opts.target_type) ~= "string" or #opts.target_type == 0 then
        return nil, "target_type is required"
    end
    if opts.target_id == nil then
        return nil, "target_id is required"
    end
    if type(opts.op_type) ~= "string" or #opts.op_type == 0 then
        return nil, "op_type is required"
    end
    local param_hash = opts.param_hash
    if type(opts.hash_fn) == "function" then
        local computed, herr = critical.param_hash_of(opts.op_type, opts.payload or {}, opts.hash_fn)
        if not computed then
            return nil, "param hash failed: " .. tostring(herr)
        end
        if param_hash ~= nil and param_hash ~= computed then
            return nil, "param_hash does not match the payload"
        end
        param_hash = computed
    end
    if not critical_fields.is_param_hash(param_hash) then
        return nil, "param_hash must be 64 hex characters"
    end
    return {
        event_id = event_id,
        target_type = opts.target_type,
        target_id = opts.target_id,
        op_type = opts.op_type,
        param_hash = param_hash,
        payload = opts.payload,
        status = M.STATUS.PENDING,
        attempt = 0,
        created_at = opts.now,
    }
end

-- 投递用的信封。msg_id 仍由可靠消息模块分配；event_id 才是业务去重键
function M.envelope(event, source)
    if type(event) ~= "table" or type(event.event_id) ~= "string" then
        return nil, "invalid event"
    end
    return {
        version = M.ENVELOPE_VERSION,
        event_id = event.event_id,
        source_type = source and source.type,
        source_id = source and source.id,
        target_type = event.target_type,
        target_id = event.target_id,
        op_type = event.op_type,
        payload = event.payload,
        param_hash = event.param_hash,
    }
end

-- 实体 ID 的比较：BSON 往返后数字/字符串会互换（int64 在部分驱动里变成字符串），
-- 用裸 `~=` 会让一个完全合法的信封被判成"错投"并永久 ACK 掉
local function id_key(value)
    local tv = type(value)
    if tv == "number" then
        if value % 1 == 0 then
            return string.format("%d", value)
        end
        return tostring(value)
    end
    if tv == "string" then
        local int = value:match("^%-?%d+$") and math.tointeger(tonumber(value))
        if int then
            return string.format("%d", int)
        end
        return value
    end
    return tostring(value)
end
M.id_key = id_key

-- 接收方校验：信封必须自洽，且 event_id 能映射出稳定的业务键。
-- 不校验"来源是否可信"——那是 capability 的职责
function M.validate_envelope(envelope)
    if type(envelope) ~= "table" then
        return nil, "envelope must be a table"
    end
    if envelope.version ~= M.ENVELOPE_VERSION then
        return nil, "unsupported envelope version"
    end
    local _, err = critical.service_op_id_from_event(envelope.event_id)
    if err then
        return nil, err
    end
    if type(envelope.target_type) ~= "string" or #envelope.target_type == 0 then
        return nil, "invalid target_type"
    end
    if envelope.target_id == nil then
        return nil, "invalid target_id"
    end
    if type(envelope.op_type) ~= "string" or #envelope.op_type == 0 then
        return nil, "invalid op_type"
    end
    if not critical_fields.is_param_hash(envelope.param_hash) then
        return nil, "invalid param_hash"
    end
    if type(envelope.source_type) ~= "string" or #envelope.source_type == 0 then
        return nil, "invalid source_type"
    end
    if envelope.source_id == nil then
        return nil, "invalid source_id"
    end
    return true
end

-- 接收方的业务键：字节级一一映射，不依赖 HMAC/进程/时间
function M.service_op_id(envelope)
    if type(envelope) ~= "table" then
        return nil, "invalid envelope"
    end
    return critical.service_op_id_from_event(envelope.event_id)
end

local function outbox_of(critical_table)
    return critical_table and critical_table[M.FIELD] or nil
end

-- 取一批待投递事件。按 created_at 排序，保证先入先出（同一角色的事件有先后依赖）
function M.pending_events(critical_table, limit)
    limit = limit or M.DEFAULT_LIMIT
    local out = {}
    local outbox = outbox_of(critical_table)
    if not outbox then
        return out
    end
    for _, event in pairs(outbox) do
        if type(event) == "table" and event.status == M.STATUS.PENDING then
            out[#out + 1] = event
        end
    end
    table.sort(out, function(a, b)
        -- 持久化因果序号优先：同一秒创建的事件只靠 created_at 排不出确定顺序，
        -- 而可靠消息的 msg_id 只保证唯一、不保证因果顺序。
        --
        -- 比较器必须是**全序**。曾经写成"两边都有 seq 才比 seq，否则退回
        -- created_at"，在滚动升级期（新旧节点写的事件混在同一份 outbox 里）
        -- 会成环：A 无 seq 比 B 早、B 的 seq 比 C 小、C 的时间又比 A 早，
        -- table.sort 拿到非传递比较器会给出任意顺序，可能把后发生的事件先投出去。
        -- 这里改成单一键：(是否有 seq, seq 或 created_at, event_id)。
        -- 无 seq 的事件只可能是升级前写入的，所以排在所有有 seq 的事件之前
        local sa, sb = a.causal_seq, b.causal_seq
        local ra = math.type(sa) == "integer" and 1 or 0
        local rb = math.type(sb) == "integer" and 1 or 0
        if ra ~= rb then
            return ra < rb
        end
        local ka = ra == 1 and sa or (a.created_at or 0)
        local kb = rb == 1 and sb or (b.created_at or 0)
        if ka ~= kb then
            return ka < kb
        end
        return tostring(a.event_id) < tostring(b.event_id)
    end)
    while #out > limit do
        out[#out] = nil
    end
    return out
end

function M.count_pending(critical_table)
    local n = 0
    for _, event in pairs(outbox_of(critical_table) or {}) do
        if type(event) == "table" and event.status == M.STATUS.PENDING then
            n = n + 1
        end
    end
    return n
end

-- 最老待发事件的年龄（秒）。积压年龄比计数更能说明问题：计数受批大小影响，
-- 年龄只受"到底多久没投出去"影响
function M.oldest_age(critical_table, now)
    now = now or os.time()
    local oldest
    for _, event in pairs(outbox_of(critical_table) or {}) do
        if type(event) == "table" and event.status == M.STATUS.PENDING then
            local created = event.created_at
            if math.type(created) == "integer" and (not oldest or created < oldest) then
                oldest = created
            end
        end
    end
    if not oldest then
        return 0
    end
    return math.max(0, now - oldest)
end

-- 某状态的事件多久之后可以被清理
function M.retention_for(status)
    if status == M.STATUS.ENQUEUED then
        return M.ENQUEUED_RETENTION
    end
    -- DELIVERED / FAILED 都按投递保留期
    return M.DELIVERED_RETENTION
end

-- 下一次可以清理的时刻：所有终态事件里最早到期的那个。没有终态事件返回 nil。
-- 清理完必须用它重算，否则标记要么永久过期（每轮空扫）要么永久缺席（不再被扫）
function M.next_cleanup_at(outbox_table)
    local best
    for _, event in pairs(outbox_table or {}) do
        if type(event) == "table" and event.status ~= M.STATUS.PENDING then
            local base = event.updated_at or event.created_at
            if math.type(base) == "integer" then
                local due = base + M.retention_for(event.status)
                if not best or due < best then
                    best = due
                end
            end
        end
    end
    return best
end

-- 把清理标记推进到"不晚于 due"。取最小值：一条老事件到期了不能被一条新事件
-- 把标记推后，否则老事件要等到新事件到期才被清
function M.bump_cleanup_at(copy, status, now)
    if status == M.STATUS.PENDING then
        return copy
    end
    local due = now + M.retention_for(status)
    local cur = copy[M.CLEANUP_FIELD]
    if math.type(cur) ~= "integer" or due < cur then
        copy[M.CLEANUP_FIELD] = due
    end
    return copy
end

-- 纯函数：返回把某个事件推进到新状态后的 critical 副本，以及新的 pending 计数。
-- 不改调用方传进来的表
function M.transition(critical_table, event_id, status, now)
    local copy = {}
    for k, v in pairs(critical_table or {}) do
        if type(v) == "table" then
            local sub = {}
            for k2, v2 in pairs(v) do
                sub[k2] = v2
            end
            copy[k] = sub
        else
            copy[k] = v
        end
    end
    local outbox = copy[M.FIELD] or {}
    local event = outbox[event_id]
    if type(event) ~= "table" then
        return nil, "unknown event"
    end
    local updated = {}
    for k, v in pairs(event) do
        updated[k] = v
    end
    local was_pending = updated.status == M.STATUS.PENDING
    updated.status = status
    updated.updated_at = now
    if status == M.STATUS.ENQUEUED then
        updated.attempt = (updated.attempt or 0) + 1
    end
    outbox[event_id] = updated
    copy[M.FIELD] = outbox
    -- pending_count 只在"离开 PENDING"时减一次；重复调用不会减第二次
    if was_pending and status ~= M.STATUS.PENDING then
        copy[M.PENDING_COUNT_FIELD] = math.max(0, (copy[M.PENDING_COUNT_FIELD] or 0) - 1)
    end
    -- 离开 PENDING 就要留下清理标记，否则计数归零后这个角色再也不会被 worker 扫到
    return M.bump_cleanup_at(copy, status, now)
end

-- 把一批 PENDING 事件推进到 ENQUEUED。
--
-- 顺序是硬约束：**先投递、后 CAS**。先 CAS 再投递的话，进程在两步之间崩溃就会
-- 留下一个"已入队但从未发出"的事件，而 PENDING 计数已经减掉，恢复扫描再也找不到它。
--
-- deliver(envelope) 返回 true 表示可靠消息已确认入队；它可以 yield。
-- 返回 { enqueued, failed, unknown, already, batches, pending, oldest_age }
--
-- `nMatched=0` 是**版本/条件冲突**，不是"资产已执行但 ACK 丢失"：重新读当前文档后
-- 同一条事件连续投递失败多少次后判为毒事件。
--
-- 这里有一个**显式的取舍**，两个阶段的行为不同，不要混为一谈：
--
--   1. 未到阈值：`break`。同角色事件有先后依赖，队首没投出去时后面的事件
--      不能抢跑——宁可等，也不让接收方看到后发生的事件先到。
--   2. 到达阈值：隔离（标 FAILED）后 `continue`。此时这条事件已经判定"短期
--      不会成功"，继续挡着就等于让该角色**所有**后续事件永久饿死。
--      这里**主动放弃保序**，用可用性换掉严格顺序。
--
-- 代价是接收方可能乱序收到同一角色的事件。所以接收侧必须：用 `service_op_id`
-- 去重、对参数做业务自校验（不满足前置条件就拒绝而不是硬执行）。
-- 这个取舍记录在 docs/review-2026-11-12-defect-register.md §5。
M.MAX_DELIVER_ATTEMPTS = 5

local function copy_critical(critical_table)
    local copy = {}
    for k, v in pairs(critical_table or {}) do
        if type(v) == "table" then
            local sub = {}
            for k2, v2 in pairs(v) do
                sub[k2] = v2
            end
            copy[k] = sub
        else
            copy[k] = v
        end
    end
    return copy
end

-- 把一条毒事件标成 FAILED（终态，进 DLQ 语义），并让出队列。
-- 失败原因写进事件本身，人工排查不用去翻日志。
function M._quarantine_event(ctx, event, critical_table, now, attempts, reason, max_retry)
    for _ = 1, max_retry + 1 do
        local next_table = copy_critical(critical_table)
        local ev = next_table[M.FIELD] and next_table[M.FIELD][event.event_id]
        if type(ev) ~= "table" then
            return nil
        end
        if ev.status ~= M.STATUS.PENDING then
            -- 别的 worker 已经推进过：按当前文档继续，不再重复处理
            return next_table
        end
        -- copy_critical 只复制一层，`ev` 仍是缓存里的同一张表。直接改它会让
        -- CAS 被拒之后内存缓存显示 FAILED、库里仍是 PENDING，事件在内存里消失
        -- 而 pending_count 没减，worker 就会永远空扫。所以先拷再改
        local updated = {}
        for k2, v2 in pairs(ev) do
            updated[k2] = v2
        end
        ev = updated
        -- 必须写回 next_table：pump 会用返回的这张表 set_critical，
        -- 只改局部变量会让缓存与库里都停在 PENDING，而 quarantined 计数已经 +1
        next_table[M.FIELD][event.event_id] = ev
        ev.status = M.STATUS.FAILED
        ev.updated_at = now
        ev.deliver_attempts = attempts
        ev.failed_at = now
        ev.failed_reason = tostring(reason):sub(1, 200)
        next_table[M.PENDING_COUNT_FIELD] = math.max(0, (next_table[M.PENDING_COUNT_FIELD] or 0) - 1)
        -- FAILED 也是终态：同一次写入落下清理标记，否则计数归零后没人再扫这个角色
        M.bump_cleanup_at(next_table, M.STATUS.FAILED, now)
        local state = dbmgr.critical_update(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, ctx.doc._version, {
            ["$set"] = {
                [M.FIELD .. "." .. event.event_id] = ev,
                [M.PENDING_COUNT_FIELD] = next_table[M.PENDING_COUNT_FIELD],
                [M.CLEANUP_FIELD] = next_table[M.CLEANUP_FIELD],
            },
        }, {
            handle = ctx.handle,
            metadata_only = true,
            extra_query = { [M.FIELD .. "." .. event.event_id .. ".status"] = M.STATUS.PENDING },
        })
        if state == "CONFIRMED" then
            dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, next_table, ctx.handle)
            m_failed:inc(1, { op_type = event.op_type or "unknown" })
            return next_table
        end
        if state == "UNKNOWN" then
            dbmgr.refresh_critical(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, { handle = ctx.handle })
            return nil
        end
        local fresh = dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
        if not fresh then
            return nil
        end
        critical_table = fresh
    end
    return nil
end

-- 未到上限：只记一次尝试次数，事件保持 PENDING，本轮停止（保序）。
-- field 默认 deliver_attempts；状态 CAS 失败用独立的 cas_attempts 计数，
-- 不能和"投递失败"混在一个阈值里——那会把已投出去的消息误标成毒事件
function M._note_deliver_attempt(ctx, event, critical_table, now, attempts, max_retry, field)
    field = field or "deliver_attempts"
    for _ = 1, max_retry + 1 do
        local state = dbmgr.critical_update(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, ctx.doc._version, {
            ["$set"] = {
                [M.FIELD .. "." .. event.event_id .. "." .. field] = attempts,
                [M.FIELD .. "." .. event.event_id .. ".last_attempt_at"] = now,
            },
        }, {
            handle = ctx.handle,
            metadata_only = true,
            extra_query = { [M.FIELD .. "." .. event.event_id .. ".status"] = M.STATUS.PENDING },
        })
        if state == "CONFIRMED" then
            local next_table = copy_critical(critical_table)
            local ev = next_table[M.FIELD] and next_table[M.FIELD][event.event_id]
            if type(ev) == "table" then
                ev[field] = attempts
                ev.last_attempt_at = now
            end
            dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, next_table, ctx.handle)
            return next_table
        end
        if state == "UNKNOWN" then
            dbmgr.refresh_critical(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, { handle = ctx.handle })
            return nil
        end
        local fresh = dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
        if not fresh then
            return nil
        end
        critical_table = fresh
    end
    return nil
end

-- 有界重试。重读后事件已被别的 worker 推进时不再重投、也不再减第二次计数。
function M.pump(ctx, deliver, opts)
    opts = opts or {}
    if type(deliver) ~= "function" then
        return nil, "deliver must be a function"
    end
    local limit = opts.limit or M.DEFAULT_LIMIT
    local max_retry = opts.cas_retry or M.CAS_RETRY
    local stats = {
        enqueued = 0,
        failed = 0,
        unknown = 0,
        already = 0,
        batches = 0,
        quarantined = 0,
        retryable = 0,
    }
    local source = opts.source or {}
    -- 生产链路（entity_agent.outbox_pump -> pump_entity -> 这里）只传 limit，
    -- 没有 now。缺省必须自己取墙钟：transition/bump_cleanup_at 会做 now + retention，
    -- nil 会直接抛错，事件永远停在 PENDING、每轮重复投一条可靠消息。
    local now = opts.now or os.time()

    local critical_table = dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
    if not critical_table then
        return nil, "document not loaded"
    end
    local events = M.pending_events(critical_table, limit)
    if #events == 0 then
        stats.pending = 0
        stats.oldest_age = 0
        return M._finish_pump(ctx, now, stats)
    end

    for _, event in ipairs(events) do
        local envelope, eerr = M.envelope(event, source)
        if not envelope then
            log.error("outbox envelope build failed", "event", tostring(event.event_id), "err", eerr)
            stats.failed = stats.failed + 1
            -- 形状不对的事件后面的事件不能抢跑：同角色事件有先后依赖
            break
        else
            local ok, deliver_err = pcall(deliver, envelope)
            -- 环境故障与毒事件必须分开：
            --   * retryable：Mongo 抖动、连接池耗尽、写关注失败。这条事件**还没试过
            --     真正投出去**，源端资产却已经扣了。计入毒事件阈值会在抖动 5 次
            --     （约 25 秒）后把它标 FAILED —— 业务永不执行、资产静默丢失。
            --     所以不计数、只停止本轮，等环境恢复
            --   * 抛异常 / 返回 false / 返回其它：投递器明确表示这条送不出去，
            --     或者投递器自己有 bug。计入阈值，到点隔离，避免整条队列饿死
            if ok and delivery.is_retryable(deliver_err) then
                stats.retryable = stats.retryable + 1
                log.warn(
                    "outbox delivery hit an environment fault, will retry without counting it as poison",
                    "event",
                    event.event_id,
                    "err",
                    tostring(deliver_err.reason)
                )
                -- 保序：环境故障时后面的事件也不能抢跑，否则接收方会先看到后发生的事件
                break
            end
            if not ok or deliver_err ~= true then
                stats.failed = stats.failed + 1
                local attempts = (event.deliver_attempts or 0) + 1
                if not ok then
                    log.warn("outbox deliver raised", "event", event.event_id, "err", deliver_err)
                end
                if attempts >= (opts.max_deliver_attempts or M.MAX_DELIVER_ATTEMPTS) then
                    -- 毒事件：标 FAILED 后**继续**投后面的事件。
                    -- 这与阈值内的 `break` 是两个阶段的不同取舍，见 M.MAX_DELIVER_ATTEMPTS 的注释：
                    -- 阈值内保序，达到阈值后用可用性换掉严格顺序
                    local quarantined =
                        M._quarantine_event(ctx, event, critical_table, now, attempts, deliver_err, max_retry)
                    if not quarantined then
                        -- 连"标记失败"都写不进去：保持 PENDING，本轮停止
                        break
                    end
                    critical_table = quarantined
                    stats.quarantined = stats.quarantined + 1
                    log.error(
                        "outbox event quarantined after repeated delivery failures",
                        "event",
                        event.event_id,
                        "attempts",
                        attempts,
                        "err",
                        tostring(deliver_err)
                    )
                else
                    -- 未到上限：记录尝试次数并停止本轮，保持同角色事件的顺序
                    local noted = M._note_deliver_attempt(ctx, event, critical_table, now, attempts, max_retry)
                    if noted then
                        critical_table = noted
                    end
                    break
                end
            else
                local advanced, state = M._advance(ctx, event, critical_table, now, max_retry, stats)
                if state == "CONFIRMED" then
                    critical_table = advanced
                    stats.enqueued = stats.enqueued + 1
                    m_enqueued:inc(1, { op_type = event.op_type })
                elseif state == "ALREADY" then
                    critical_table = advanced or critical_table
                    stats.already = stats.already + 1
                elseif state == "UNKNOWN" then
                    -- 状态未决：不再继续处理后面的事件，避免在不确定的文档上叠加写入
                    return stats
                else
                    -- BLOCKED（租约/归属/多数派不可用）是环境问题，不计数，本轮停止
                    if state == "REJECTED" then
                        -- 重试用尽多半是内存版本落后：_advance 的重试读的是同一份缓存，
                        -- 永远看不到别人推进的结果。先多数派读对齐，再看事件是否还在
                        -- PENDING：已被推进就不计数（别人做完了）；仍是 PENDING 才记一次
                        -- 尝试，到阈值标 FAILED。不记的话事件永远 PENDING、每 5 秒重投
                        -- 一条可靠消息，毒事件阈值对它完全失效
                        local refreshed = dbmgr.refresh_critical(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, {
                            handle = ctx.handle,
                        })
                        if not refreshed then
                            -- 多数派读失败是环境故障：不计数（A-09 的教训），
                            -- 但要留痕，否则这类"永远 PENDING"完全不可诊断
                            log.warn("outbox status CAS retry could not refresh the document", "event", event.event_id)
                        end
                        if refreshed then
                            local fresh = dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
                            local current = fresh and fresh[M.FIELD] and fresh[M.FIELD][event.event_id]
                            if type(current) == "table" and current.status == M.STATUS.PENDING then
                                local attempts = (current.cas_attempts or 0) + 1
                                -- **不标 FAILED**：消息已经进可靠队列，接收方可能已经执行。
                                -- 标"毒事件"会让源端永远不再重投，一旦消息丢了就是永久丢业务。
                                -- 这里只记独立计数 + 限流日志，交给告警介入
                                if attempts == 1 or attempts % 10 == 0 then
                                    log.error(
                                        "outbox status CAS keeps missing",
                                        "event",
                                        event.event_id,
                                        "attempts",
                                        attempts
                                    )
                                end
                                local noted =
                                    M._note_deliver_attempt(ctx, event, fresh, now, attempts, max_retry, "cas_attempts")
                                if noted then
                                    critical_table = noted
                                end
                            end
                        end
                    end
                    break
                end
            end
        end
        stats.batches = stats.batches + 1
    end
    stats.pending = M.count_pending(critical_table)
    stats.oldest_age = M.oldest_age(critical_table, now)
    return M._finish_pump(ctx, now, stats)
end

-- 一轮收尾：清掉到期终态事件。
--
-- 这里**不再做进程级节流**。原先用 `g_last_cleanup_at` 每 60 秒只允许一次清理，
-- 但它对"回执丢失"的角色永远不可达：那些角色的 pending_count 已经归零，
-- worker 根本不会扫到它们；就算扫到，一个进程级的窗口也会让第二个角色被跳过。
-- 真正的节流由数据本身承担：`cleanup` 只删已过保留期的事件，没过期时
-- 只是一次内存遍历，不做任何 Mongo 写入。
function M._finish_pump(ctx, now, stats)
    local cleaned, cerr = M.cleanup(ctx, { now = now })
    if cleaned then
        stats.cleaned = cleaned
    elseif cerr then
        log.warn("outbox cleanup skipped", "err", tostring(cerr))
    end
    return stats
end

-- 已被别人推进的事件：用库里最新的副本继续（不改状态、不减计数）
-- 只有这两种 detail 才是 §6.2.4 的"版本/条件冲突"，可以读后像重试。
-- 其余 REJECTED（lease expired / owner changed / 隔离 / 多数派不可用 / not cached）
-- 都是环境或归属问题：重试只会每轮重复投一条可靠消息，把队列越堆越大
local CAS_MISS = {
    ["cas mismatch"] = true,
    ["version mismatch"] = true,
}

-- PENDING -> ENQUEUED 的状态 CAS，带"读后像 + 有界重试"。
-- 返回新的 critical 副本，或 nil, 终态原因（"REJECTED"/"UNKNOWN"/"BLOCKED"）
function M._advance(ctx, event, critical_table, now, max_retry, stats)
    for _ = 1, max_retry + 1 do
        local next_table, terr = M.transition(critical_table, event.event_id, M.STATUS.ENQUEUED, now)
        if not next_table then
            -- 表里已经没有这条事件（被清理或参数不符）：不是环境故障
            stats.failed = stats.failed + 1
            log.warn("outbox event vanished before status cas", "event", tostring(event.event_id), "err", terr)
            return nil, "REJECTED"
        end
        local state, detail = dbmgr.critical_update(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, ctx.doc._version, {
            ["$set"] = {
                [M.FIELD .. "." .. event.event_id] = next_table[M.FIELD][event.event_id],
                [M.PENDING_COUNT_FIELD] = next_table[M.PENDING_COUNT_FIELD],
                -- 清理标记必须与状态同一次写入：分开写会出现"状态已终态但没人清"
                -- 或者"标记已设但状态还没终态"两种半完成状态
                [M.CLEANUP_FIELD] = next_table[M.CLEANUP_FIELD],
            },
        }, {
            handle = ctx.handle,
            -- 这只是元数据状态，不是资产提交：UNKNOWN 不能把玩家资产隔离掉
            metadata_only = true,
            -- 只有"该事件仍是 PENDING"时才允许推进：另一个 worker 已经推过就
            -- 不再减第二次计数
            extra_query = { [M.FIELD .. "." .. event.event_id .. ".status"] = M.STATUS.PENDING },
        })
        if state == "CONFIRMED" then
            dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, next_table, ctx.handle)
            return next_table, "CONFIRMED"
        end
        if state == "UNKNOWN" then
            stats.unknown = stats.unknown + 1
            m_unknown:inc(1, { op_type = event.op_type })
            log.error("outbox status unknown", "event", event.event_id, "detail", tostring(detail))
            -- 写入可能已经生效：用多数派读把内存版本对齐，否则下一轮 CAS 永远打不中
            local refreshed, rerr = dbmgr.refresh_critical(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, {
                handle = ctx.handle,
            })
            if not refreshed then
                log.error("outbox refresh after unknown failed", "event", event.event_id, "err", tostring(rerr))
            end
            return nil, "UNKNOWN"
        end
        if not CAS_MISS[detail] then
            stats.failed = stats.failed + 1
            log.error("outbox status cas blocked", "event", event.event_id, "detail", tostring(detail))
            return nil, "BLOCKED"
        end
        -- CAS 未命中：先看是不是"别人已经推进过"，是就结束，不重复投递也不重复减计数
        local fresh = dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
        if not fresh then
            stats.failed = stats.failed + 1
            log.warn("outbox status cas missed and document unreadable", "event", event.event_id)
            return nil, "REJECTED"
        end
        local current = fresh[M.FIELD] and fresh[M.FIELD][event.event_id]
        if type(current) ~= "table" or current.status ~= M.STATUS.PENDING then
            log.info("outbox event already advanced by another writer", "event", event.event_id)
            return fresh, "ALREADY"
        end
        critical_table = fresh
        m_cas_retry:inc(1, { op_type = event.op_type })
        log.info("outbox status cas retry", "event", event.event_id, "detail", tostring(detail))
    end
    -- 有界重试用尽：保持 PENDING 等下一轮，不能宣称完成
    stats.failed = stats.failed + 1
    log.warn("outbox status cas retries exhausted", "event", event.event_id)
    return nil, "REJECTED"
end

-- ---------------------------------------------------------------------------
-- 投递闭环：接收方回执 -> DELIVERED -> 清理
--
-- 没有这一段时 `_critical_outbox_v1` 只增不减，撞上 MAX_OUTBOX 之后该角色的
-- 关键操作会被永久拒绝（CAPACITY_EXCEEDED）。
-- ---------------------------------------------------------------------------

-- 可清理的事件，最老的在前。
--   DELIVERED  终态，随时可删（`delivered_retention` 只是给审计留的时间）
--   ENQUEUED   超过保留期说明接收方长期没上线；可靠消息已经持久化，源端副本删掉
--              不影响业务效果（去重键由 event_id 派生，接收方照样只执行一次）
--   PENDING    永不删：它还没投出去
function M.evictable(critical_table, now, opts)
    opts = opts or {}
    -- 定期清理按保留期来；容量压力下由 critical.evictable_outbox_events 传 0
    local delivered_retention = opts.delivered_retention or M.DELIVERED_RETENTION
    local enqueued_retention = opts.enqueued_retention or M.ENQUEUED_RETENTION
    local outbox = outbox_of(critical_table)
    if not outbox then
        return {}
    end
    local list = {}
    for event_id, event in pairs(outbox) do
        if type(event) == "table" then
            local age = now - (event.updated_at or event.created_at or now)
            local evict
            if event.status == M.STATUS.DELIVERED then
                evict = age >= delivered_retention
            elseif event.status == M.STATUS.ENQUEUED then
                evict = age >= enqueued_retention
            elseif event.status == M.STATUS.FAILED then
                -- 投递彻底失败：可靠消息从未落库，这条记录是"资产已扣但业务未生效"
                -- 的唯一证据。定期清理按与终态相同的 7 天保留期删，删除时单独打
                -- error + failed_lost 指标；容量压力下的下限由
                -- critical.OUTBOX_FAILED_MIN_RETENTION 管（同为 7 天）
                evict = age >= delivered_retention
            end
            if evict then
                list[#list + 1] = { event_id = event_id, status = event.status, age = age }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.age ~= b.age then
            return a.age > b.age
        end
        return a.event_id < b.event_id
    end)
    return list
end

-- event_id 必须是规范形式（evt_ + 64 位小写 hex）。可靠消息投递时会在参数末尾
-- 追加一个数字 msg_id，旧实现把畸形值直接交给 mark_delivered，只会得到
-- "event_id is required" 并转成无限重投；现在在边界就明确拒绝。
function M.is_valid_event_id(event_id)
    if type(event_id) ~= "string" then
        return false
    end
    local _, verr = critical.service_op_id_from_event(event_id)
    return verr == nil
end

-- 接收方回执：把事件推进到 DELIVERED（终态），可重复调用。
--
-- 允许 PENDING -> DELIVERED：可靠消息先落库、投递可能比本端的状态 CAS 还快，
-- 这时回执先到，`transition` 会在离开 PENDING 时恰好把 pending_count 减一次。
function M.mark_delivered(ctx, event_id, opts)
    opts = opts or {}
    if type(event_id) ~= "string" then
        return nil, "event_id is required"
    end
    if not M.is_valid_event_id(event_id) then
        return nil, "invalid event_id"
    end
    local now = opts.now or os.time()
    for _ = 1, M.CAS_RETRY + 1 do
        local critical_table = dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
        if not critical_table then
            return nil, "document not loaded"
        end
        local event = (critical_table[M.FIELD] or {})[event_id]
        if type(event) ~= "table" then
            -- 回执晚到：事件已经被清理。终态早已确定，没有副作用
            m_acked:inc(1, { result = "gone" })
            return false, "unknown event"
        end
        -- 回执必须来自事件声明的接收方。错投到别的实体的回执不能把别人的
        -- 未投出事件直接标成 DELIVERED（源端资产已在同一次 CAS 扣除）。
        local expect = opts.expect_target
        if type(expect) == "table" and expect.target_type ~= nil then
            if
                M.id_key(event.target_type) ~= M.id_key(expect.target_type)
                or M.id_key(event.target_id) ~= M.id_key(expect.target_id)
            then
                return nil, "ack receiver mismatch"
            end
        end
        if event.status == M.STATUS.DELIVERED then
            m_acked:inc(1, { result = "already" })
            return true
        end
        local next_table = M.transition(critical_table, event_id, M.STATUS.DELIVERED, now)
        if not next_table then
            return false, "unknown event"
        end
        local state, detail = dbmgr.critical_update(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, ctx.doc._version, {
            ["$set"] = {
                [M.FIELD .. "." .. event_id] = next_table[M.FIELD][event_id],
                [M.PENDING_COUNT_FIELD] = next_table[M.PENDING_COUNT_FIELD],
                -- 与状态同一次写入：回执到达是这个角色最后一次被写，
                -- 漏掉标记的话它的终态事件就再也没人清了
                [M.CLEANUP_FIELD] = next_table[M.CLEANUP_FIELD],
            },
        }, {
            handle = ctx.handle,
            -- 元数据状态，不是资产提交：UNKNOWN 不能把玩家资产隔离掉
            metadata_only = true,
            extra_query = { [M.FIELD .. "." .. event_id .. ".status"] = event.status },
        })
        if state == "CONFIRMED" then
            dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, next_table, ctx.handle)
            m_acked:inc(1, { result = "confirmed" })
            if math.type(event.created_at) == "integer" and math.type(now) == "integer" then
                m_delivered_age:observe(math.max(0, now - event.created_at), { op_type = event.op_type or "unknown" })
            end
            return true
        end
        if state == "UNKNOWN" then
            -- 写入可能已经生效：回执本身幂等，让可靠消息重投即可
            local refreshed, rerr =
                dbmgr.refresh_critical(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, { handle = ctx.handle })
            if not refreshed then
                log.error("outbox ack refresh failed", "event", event_id, "err", tostring(rerr))
            end
            return nil, "UNKNOWN"
        end
        if not CAS_MISS[detail] then
            log.error("outbox ack blocked", "event", event_id, "detail", tostring(detail))
            return nil, "BLOCKED"
        end
        m_cas_retry:inc(1, { op_type = event.op_type or "unknown" })
    end
    return nil, "CAS retries exhausted"
end

-- 删掉过期事件。返回删除数量；没东西可删时返回 0（不写库）。
-- 一次 CAS 删一批：逐条删会把 `_version` 推进多次，和业务提交抢版本
function M.cleanup(ctx, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local critical_table = dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
    if not critical_table then
        return nil, "document not loaded"
    end
    local victims = M.evictable(critical_table, now, opts)
    if #victims == 0 then
        return 0
    end
    local unset = {}
    local next_field = {}
    for event_id, event in pairs(critical_table[M.FIELD] or {}) do
        next_field[event_id] = event
    end
    for _, victim in ipairs(victims) do
        unset[M.FIELD .. "." .. victim.event_id] = true
        next_field[victim.event_id] = nil
    end
    -- 清理完必须重算标记：还有终态事件就指向下一批到期时刻，
    -- 一条不剩就删掉标记（否则这个角色会被 worker 每轮空扫）
    local update = { ["$unset"] = unset }
    local next_due = M.next_cleanup_at(next_field)
    if next_due then
        update["$set"] = { [M.CLEANUP_FIELD] = next_due }
    else
        unset[M.CLEANUP_FIELD] = true
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
        if state == "UNKNOWN" then
            dbmgr.refresh_critical(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, { handle = ctx.handle })
            return nil, "UNKNOWN"
        end
        return nil, tostring(detail)
    end
    local next_table = {}
    for k, v in pairs(critical_table) do
        next_table[k] = v
    end
    next_table[M.FIELD] = next_field
    next_table[M.CLEANUP_FIELD] = next_due
    dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, next_table, ctx.handle)
    for _, victim in ipairs(victims) do
        if victim.status == M.STATUS.FAILED then
            -- FAILED 是"资产已扣、可靠消息从未落库"的唯一记录。容量腾挪路径已经
            -- 为它单独打 error + failed_lost 指标，定期清理不能静默抹掉、更不能
            -- 把它算进 enqueued_expired 里假装只是一条过期消息
            m_evicted:inc(1, { reason = "failed_lost" })
            log.error(
                "cleaning up a FAILED outbox event; this is the last record of a deducted asset",
                "event",
                tostring(victim.event_id),
                "age",
                tostring(victim.age)
            )
        else
            m_evicted:inc(1, {
                reason = victim.status == M.STATUS.DELIVERED and "delivered" or "enqueued_expired",
            })
        end
    end
    log.info("outbox events cleaned up", "count", #victims)
    return #victims
end

-- ---------------------------------------------------------------------------
-- 接收方（P13）
-- ---------------------------------------------------------------------------
--
-- 游戏层的 `__apply_outbox_event` 只需要一行：`return receiver:handle(entity, envelope)`。
--
-- 为什么要在框架里做：接收方必须完成三件容易漏掉的事——校验信封自洽、把
-- `event_id` 映射成稳定的 `service_op_id`、以及在 `entity_agent` 进程内签发
-- capability（cap 不能跨进程传）。漏掉任何一件，`execute_internal` 都会拒绝，
-- 而游戏层看到的是"消息永远投不进去"。

local RECEIVER_MT = {}
RECEIVER_MT.__index = RECEIVER_MT

-- opts.namespace 默认 "outbox"；opts.op_types 限定该接收方能处理哪些操作
-- opts.ledger 冷账本集合：**必须给**。热账本 7 天后归档，没有冷账本就无法证明
-- 同一个 service_op_id 执行过，重投就是二次入账
function M.new_receiver(opts)
    opts = opts or {}
    -- 来源命名空间固定为 outbox：调用方不能自报一个受信任来源名，否则
    -- `_critical_ops_v1` 里的 source_namespace 绑定就失去意义
    local namespace = "outbox"
    if opts.namespace ~= nil and opts.namespace ~= namespace then
        return nil, "receiver namespace must be outbox"
    end
    if type(opts.op_types) ~= "table" or #opts.op_types == 0 then
        return nil, "op_types must be a non-empty list"
    end
    -- 冷账本是"至多一次"的另一半：热条目 7 天后归档，没有它就证明不了
    -- 同一个 service_op_id 执行过。缺了必须在构造期报错，不能推迟到第一条消息——
    -- 那时事件已经发出，只能靠 retryable 卡住，运维看不到根因
    if opts.ledger == nil then
        return nil, "ledger is required for an outbox receiver"
    end
    local capability = require "skyext.capability"
    local issuer, err = capability.new_issuer(namespace, opts.op_types)
    if not issuer then
        return nil, err
    end
    return setmetatable({
        issuer = issuer,
        hash_fn = opts.hash_fn,
        namespace = namespace,
        ledger = opts.ledger,
    }, RECEIVER_MT)
end

-- 永久无效事件绝不能 ACK：源端资产已在同一次 CAS 扣除，接收端什么都不会执行，
-- ACK 之后既没有业务效果、也没有可补偿的记录。抛错让 `_deliver_one` 计 attempts，
-- 最终转入**已有的**可靠消息死信（entity_msg status=2），由 GM dlq_list/replay/
-- discard 人工处理。死信原因里带上定位与补偿所需的全部身份字段。
local function permanently_invalid(envelope, reason, detail)
    envelope = type(envelope) == "table" and envelope or {}
    error(
        "outbox event permanently invalid: "
            .. tostring(reason)
            .. " event="
            .. tostring(envelope.event_id)
            .. " source="
            .. tostring(envelope.source_type)
            .. ":"
            .. tostring(envelope.source_id)
            .. " target="
            .. tostring(envelope.target_type)
            .. ":"
            .. tostring(envelope.target_id)
            .. " param_hash="
            .. tostring(envelope.param_hash)
            .. (detail ~= nil and (" detail=" .. tostring(detail)) or ""),
        0
    )
end

-- 返回 handler 应当原样返回的值：
--   * 永久无效（信封/目标/参数摘要不符）：抛错进现有死信，见 permanently_invalid
--   * 部署/环境暂态（冷账本、hash_fn 缺失）：delivery.retryable，修好配置后重投即可
--   * UNKNOWN / 环境暂态：delivery.retryable，让 `_deliver_one` 保留 pending
--   * 其他：返回 critical 的 decision
function RECEIVER_MT:handle(entity, envelope, handlers, opts)
    opts = opts or {}
    local delivery = require "skyext.entity.delivery"
    local ok, verr = M.validate_envelope(envelope)
    if not ok then
        log.error("reject outbox envelope", "err", verr, "id", tostring(entity and entity.id))
        permanently_invalid(envelope, "invalid envelope", verr)
    end
    -- 冷账本缺失是部署错误，不是"这条事件有问题"。放行等于承认"热账本没有 =
    -- 从没执行过"，热条目 7 天归档后同一条事件重投就会二次入账。宁可卡住等修配置
    if not self.ledger then
        log.error("outbox receiver has no ledger", "event", tostring(envelope.event_id))
        return delivery.retryable("receiver ledger is not configured")
    end
    if envelope.target_type ~= entity.type_name or id_key(envelope.target_id) ~= id_key(entity.id) then
        -- 错投：不是本实体的事件，绝不能在本实体上执行
        log.error(
            "outbox envelope target mismatch",
            "want_type",
            tostring(envelope.target_type),
            "want_id",
            tostring(envelope.target_id),
            "got_type",
            tostring(entity.type_name),
            "got_id",
            tostring(entity.id)
        )
        permanently_invalid(
            envelope,
            "envelope target mismatch",
            "got=" .. tostring(entity.type_name) .. ":" .. tostring(entity.id)
        )
    end

    local now = opts.now or os.time()
    local hash_fn = opts.hash_fn or self.hash_fn
    if type(hash_fn) ~= "function" then
        -- 摘要函数没注入就无法校验"同一事件换了参数"，属于部署错误：
        -- 修好配置后同一事件重投就能成功，不能当毒消息进死信
        log.error("outbox receiver has no hash_fn")
        return delivery.retryable("outbox receiver has no hash_fn")
    end
    local param_hash, herr = critical.param_hash_of(envelope.op_type, envelope.payload or {}, hash_fn)
    if not param_hash then
        log.error("outbox payload hash failed", "err", tostring(herr))
        permanently_invalid(envelope, "payload hash failed", herr)
    end
    if param_hash ~= envelope.param_hash then
        -- 发送方记录与本次载荷不一致：伪造或版本错配，重试永远不会成功
        log.error("outbox param hash mismatch", "event", tostring(envelope.event_id))
        permanently_invalid(envelope, "param hash mismatch", "computed=" .. tostring(param_hash))
    end

    local service_op_id, operr = M.service_op_id(envelope)
    if not service_op_id then
        log.error("outbox service op id failed", "err", tostring(operr))
        permanently_invalid(envelope, "service op id failed", operr)
    end
    local source_id = tostring(envelope.source_type) .. ":" .. tostring(envelope.source_id)
    local capability = require "skyext.capability"
    local cap, cerr = capability.issue(self.issuer, {
        rid = entity.rid or entity.id,
        service_op_id = service_op_id,
        op_type = envelope.op_type,
        payload_hash = param_hash,
        source_id = source_id,
        now = now,
    })
    if not cap then
        log.error("outbox capability issue failed", "err", tostring(cerr))
        return delivery.retryable(cerr)
    end

    local result =
        critical.execute_internal(entity, service_op_id, envelope.op_type, envelope.payload or {}, handlers, {
            capability = cap,
            hash_fn = hash_fn,
            source_namespace = self.namespace,
            source_id = source_id,
            -- 热账本归档后，去重只能靠冷账本。不传就等于"热账本没有 = 从没执行过"，
            -- 7 天后同一条事件重投会把业务效果再执行一遍
            ledger = self.ledger,
            now = now,
        })
    local status = result.status
    if status == critical.STATUS.COMMITTED or status == critical.STATUS.BUSINESS_REJECTED then
        -- 只有**持久化终态**才能回执：这两种结果都写进了 _critical_ops_v1，
        -- 重放同一个 service_op_id 会拿到相同结论。没有回执时源角色的
        -- `_critical_outbox_v1` 只增不减，最终会撞上容量上限。
        -- PRECHECK_REJECTED 不在此列：它是 PREPARE 之前的纯读拒绝，什么都没写。
        self:ack_source(envelope, entity)
        return result
    end
    if
        status == critical.STATUS.UNKNOWN
        or status == critical.STATUS.IN_PROGRESS
        or status == critical.STATUS.CAPACITY_EXCEEDED
        or status == critical.STATUS.INTERNAL_ERROR
    then
        -- 未决、暂态容量不足，或 validate 自身抛错（PREPARE 之前零写入）。
        -- 后者不能算契约失败：它是环境/代码故障，修好后同一事件重投就能成功，
        -- critical.query 也只会回 NOT_STARTED。delivery.retryable 保留 pending，
        -- 连续达到阈值时由 note_retryable 升级人工，这就是"受控重试"。
        -- 绝不能 ACK——ACK 之后业务永不执行、也不再重投
        return delivery.retryable(result.reason)
    end
    if status == critical.STATUS.PRECHECK_REJECTED then
        -- 纯读预检不通过：没写 PREPARE、没有 service_op_id，可能随实体状态变化。
        -- 旧实现把它当终态 ACK，源端资产已在同一次 CAS 扣除，事件却被标成
        -- DELIVERED 删除且永不重投。改为抛错让可靠消息计 attempts 进死信，
        -- 人工可见并可补偿（与 pay_webhook 的业务拒绝口径一致）。
        error("outbox event precheck rejected: " .. tostring(result.reason), 0)
    end
    -- 契约/鉴权类失败（同 op 换参数、cap 不符）：不是环境暂态，也不该静默 ACK。
    -- 抛出去让可靠消息按失败次数进死信队列，人工可见
    error("outbox event rejected: " .. tostring(status) .. " (" .. tostring(result.reason) .. ")", 0)
end

-- 回执：走可靠消息发给源实体，源端在 outbox_ack 里把事件推进到 DELIVERED。
--
-- 为什么不用"源端轮询接收方"：那要么让源端加载离线角色（抢锁、读库），要么在
-- 实体队列里跨实体调用，两个角色互相等就成了死锁。可靠消息天然持久化，
-- 源角色离线时随下次加载投递。
--
-- 回执失败只记日志：业务终态已经落库，源端事件会停在 ENQUEUED，
-- 由容量腾挪与保留期清理兜底，不影响这次业务结果。
function RECEIVER_MT:ack_source(envelope, entity)
    local source_type = envelope.source_type
    local source_id = envelope.source_id
    if type(source_type) ~= "string" or source_type == "" or source_id == nil then
        -- 旧信封没有来源信息：无法回执，只能靠保留期清理
        return false
    end
    local called, ok = pcall(function()
        local router = require "skyext.entity.router"
        -- args 必须是**数组**：entitymgr._deliver_one 用 table.unpack(msg.args)
        -- 展开参数，末尾再追加 msg.msg_id。传 map 会展开成 0 个参数，handler
        -- 只拿到一个 snowflake 数字，mark_delivered 必然拒绝，回执永远到不了
        -- DELIVERED（对照 outbox_worker.default_deliver 的 { envelope } 写法）。
        return router.reliable_send(source_type, source_id, "outbox_ack", {
            {
                event_id = envelope.event_id,
                -- 带上接收方坐标：源端据此校验回执没有错投到别的事件上
                receiver_type = entity and entity.type_name or nil,
                receiver_id = entity and entity.id or nil,
            },
        }, {
            -- 回执必须可靠送达（重投仍要再发，ACK 可能丢），但不需要为了唤醒
            -- 一条回执去加载离线的源角色；在线实体照样立即处理
            lazy = true,
        })
    end)
    if not called or not ok then
        log.warn(
            "outbox ack could not be queued",
            "event",
            tostring(envelope.event_id),
            "source",
            tostring(source_type) .. ":" .. tostring(source_id),
            "err",
            tostring(ok)
        )
        return false
    end
    return true
end

return M
