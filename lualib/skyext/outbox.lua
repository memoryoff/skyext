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

M.FIELD = critical.OUTBOX_FIELD
M.PENDING_COUNT_FIELD = "_critical_outbox_pending_count"
M.ENVELOPE_VERSION = 1
M.DEFAULT_LIMIT = 16
-- 状态 CAS 的读后像重试次数。CAS 未命中是版本/条件冲突，不是 UNKNOWN，
-- 但也不能无限重试：有界退让后保持 PENDING，交给下一轮扫描
M.CAS_RETRY = 2
-- 已投递事件的保留期：DELIVERED 只用于审计，过期就能删。
-- 容量不足时不等保留期，直接腾（见 critical.commit_core）
-- 与 critical 的容量腾挪共用同一份口径：不要在这里另写一个数字
M.DELIVERED_RETENTION = critical.OUTBOX_DELIVERED_RETENTION
-- 停在 ENQUEUED 多久算"送不到了"。可靠消息已经把消息持久化，
-- 源端副本只用于观测；接收方长期不上线时，不能让这份副本把关键字段占满
M.ENQUEUED_RETENTION = 7 * 24 * 3600

local m_enqueued =
    metrics.counter("skyext_outbox_enqueued_total", "Outbox events whose reliable message was confirmed", { "op_type" })
-- 毒事件被隔离的次数：持续增长说明有事件永远投不出去，需要人工看 failed_reason
local m_failed = metrics.counter(
    "skyext_outbox_quarantined_total",
    "Outbox events quarantined as FAILED after repeated delivery failures",
    { "op_type" }
)
local m_pending = metrics.gauge("skyext_outbox_pending", "Outbox events still PENDING in this VM", { "type" })
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
    if type(param_hash) ~= "string" or #param_hash ~= 64 then
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
    if type(envelope.param_hash) ~= "string" or #envelope.param_hash ~= 64 then
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
        -- 而可靠消息的 msg_id 只保证唯一、不保证因果顺序
        local sa, sb = a.causal_seq, b.causal_seq
        if math.type(sa) == "integer" and math.type(sb) == "integer" and sa ~= sb then
            return sa < sb
        end
        local ta, tb = a.created_at or 0, b.created_at or 0
        if ta ~= tb then
            return ta < tb
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
    return copy
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
-- 不设上限的话，一条永远送不出去的事件会让该角色之后的**所有**事件都投不出去：
-- pump 遇到失败就 break 保序，队首事件永远不动，后面的事件全部饿死。
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
        ev.status = M.STATUS.FAILED
        ev.updated_at = now
        ev.deliver_attempts = attempts
        ev.failed_at = now
        ev.failed_reason = tostring(reason):sub(1, 200)
        next_table[M.PENDING_COUNT_FIELD] = math.max(0, (next_table[M.PENDING_COUNT_FIELD] or 0) - 1)
        local state = dbmgr.critical_update(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, ctx.doc._version, {
            ["$set"] = {
                [M.FIELD .. "." .. event.event_id] = ev,
                [M.PENDING_COUNT_FIELD] = next_table[M.PENDING_COUNT_FIELD],
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

-- 未到上限：只记一次尝试次数，事件保持 PENDING，本轮停止（保序）
function M._note_deliver_attempt(ctx, event, critical_table, now, attempts, max_retry)
    for _ = 1, max_retry + 1 do
        local state = dbmgr.critical_update(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, ctx.doc._version, {
            ["$set"] = {
                [M.FIELD .. "." .. event.event_id .. ".deliver_attempts"] = attempts,
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
                ev.deliver_attempts = attempts
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
    local stats = { enqueued = 0, failed = 0, unknown = 0, already = 0, batches = 0, quarantined = 0 }
    local source = opts.source or {}
    local now = opts.now

    local critical_table = dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
    if not critical_table then
        return nil, "document not loaded"
    end
    local events = M.pending_events(critical_table, limit)
    if #events == 0 then
        m_pending:set(0, { type = ctx.dbcoll })
        stats.pending = 0
        stats.oldest_age = 0
        return M._finish_pump(ctx, now, stats)
    end
    m_pending:set(M.count_pending(critical_table), { type = ctx.dbcoll })

    for _, event in ipairs(events) do
        local envelope, eerr = M.envelope(event, source)
        if not envelope then
            log.error("outbox envelope build failed", "event", tostring(event.event_id), "err", eerr)
            stats.failed = stats.failed + 1
            -- 形状不对的事件后面的事件不能抢跑：同角色事件有先后依赖
            break
        else
            local ok, deliver_err = pcall(deliver, envelope)
            if not ok or deliver_err ~= true then
                stats.failed = stats.failed + 1
                local attempts = (event.deliver_attempts or 0) + 1
                if not ok then
                    log.warn("outbox deliver raised", "event", event.event_id, "err", deliver_err)
                end
                if attempts >= (opts.max_deliver_attempts or M.MAX_DELIVER_ATTEMPTS) then
                    -- 毒事件：标 FAILED 后继续。不隔离的话，队首一条永远送不出去的事件
                    -- 会让该角色之后的所有事件都饿死（pump 失败即 break 保序）
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
                    -- BLOCKED（租约/归属/多数派不可用）或重试用尽：保持顺序，本轮停止
                    break
                end
            end
        end
        stats.batches = stats.batches + 1
    end
    stats.pending = M.count_pending(critical_table)
    stats.oldest_age = M.oldest_age(critical_table, now)
    m_pending:set(stats.pending, { type = ctx.dbcoll })
    return M._finish_pump(ctx, now, stats)
end

-- 定期清理的节流窗口（秒）。活跃角色每轮都清一次会把 Mongo 打得很碎，
-- 但只在 pending == 0 时清又会让"一直有积压"的角色永远攒着终态记录。
M.CLEANUP_INTERVAL = 60
local g_last_cleanup_at = 0

-- 仅供测试：清掉进程内的清理节流
function M._reset_cleanup()
    g_last_cleanup_at = 0
end

-- 一轮收尾：没有待发事件时立即清；仍有积压时按 CLEANUP_INTERVAL 定期清。
-- 静默角色没有 pump，仍靠容量腾挪兜底。
-- 清理失败不影响本轮投递结果，下一轮再试
function M._finish_pump(ctx, now, stats)
    local clock = now or os.time()
    local due = stats.pending == 0 or (clock - g_last_cleanup_at >= M.CLEANUP_INTERVAL)
    if due then
        local cleaned, cerr = M.cleanup(ctx, { now = now })
        if cleaned then
            stats.cleaned = cleaned
            g_last_cleanup_at = clock
        elseif cerr then
            log.warn("outbox cleanup skipped", "err", tostring(cerr))
        end
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
                -- 已进死信的事件：源端副本只用于审计。不腾会被 512 上限永久占位，
                -- 把真正待发的事件挤掉（当前没有写入点，属于防御）
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
    local state, detail = dbmgr.critical_update(ctx.dbname, ctx.dbcoll, ctx.key, ctx.unique_id, ctx.doc._version, {
        ["$unset"] = unset,
    }, {
        handle = ctx.handle,
        metadata_only = true,
    })
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
    dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, next_table, ctx.handle)
    for _, victim in ipairs(victims) do
        m_evicted:inc(1, { reason = victim.status == M.STATUS.DELIVERED and "delivered" or "enqueued_expired" })
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
    local capability = require "skyext.capability"
    local issuer, err = capability.new_issuer(namespace, opts.op_types)
    if not issuer then
        return nil, err
    end
    return setmetatable({ issuer = issuer, hash_fn = opts.hash_fn, namespace = namespace }, RECEIVER_MT)
end

-- 返回 handler 应当原样返回的值：
--   * 永久无效（信封/目标/参数摘要不符）：返回 nil 并记错误——ACK 掉，不要进 DLQ 循环
--   * UNKNOWN / 环境暂态：返回 delivery.retryable，让 `_deliver_one` 保留 pending
--   * 其他：返回 critical 的 decision（旧合同下"没抛异常就是成功"）
function RECEIVER_MT:handle(entity, envelope, handlers, opts)
    opts = opts or {}
    local delivery = require "skyext.entity.delivery"
    local ok, verr = M.validate_envelope(envelope)
    if not ok then
        log.error("reject outbox envelope", "err", verr, "id", tostring(entity and entity.id))
        return nil, verr
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
        return nil, "envelope target mismatch"
    end

    local now = opts.now or os.time()
    local hash_fn = opts.hash_fn or self.hash_fn
    if type(hash_fn) ~= "function" then
        -- 摘要函数没注入就无法校验"同一事件换了参数"，属于部署错误
        log.error("outbox receiver has no hash_fn")
        return nil, "hash_fn is required"
    end
    local param_hash, herr = critical.param_hash_of(envelope.op_type, envelope.payload or {}, hash_fn)
    if not param_hash then
        log.error("outbox payload hash failed", "err", tostring(herr))
        return nil, "payload hash failed"
    end
    if param_hash ~= envelope.param_hash then
        -- 发送方记录与本次载荷不一致：伪造或版本错配，重试永远不会成功
        log.error("outbox param hash mismatch", "event", tostring(envelope.event_id))
        return nil, "param hash mismatch"
    end

    local service_op_id, operr = M.service_op_id(envelope)
    if not service_op_id then
        log.error("outbox service op id failed", "err", tostring(operr))
        return nil, operr
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
