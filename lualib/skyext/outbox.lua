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

local m_enqueued =
    metrics.counter("skyext_outbox_enqueued_total", "Outbox events whose reliable message was confirmed", { "op_type" })
local m_pending = metrics.gauge("skyext_outbox_pending", "Outbox events still PENDING in this VM", { "type" })
local m_unknown = metrics.counter(
    "skyext_outbox_status_unknown_total",
    "Outbox status CAS whose result could not be confirmed",
    { "op_type" }
)

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

-- 生成一条待持久化的 Outbox 记录。param_hash 由调用方传入（通常复用 critical 的摘要），
-- 这样接收方能校验"同一 event_id 换了参数"。
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
    if type(opts.param_hash) ~= "string" or #opts.param_hash ~= 64 then
        return nil, "param_hash must be 64 hex characters"
    end
    return {
        event_id = event_id,
        target_type = opts.target_type,
        target_id = opts.target_id,
        op_type = opts.op_type,
        param_hash = opts.param_hash,
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
-- 返回 { enqueued, failed, unknown, batches }
function M.pump(ctx, deliver, opts)
    opts = opts or {}
    if type(deliver) ~= "function" then
        return nil, "deliver must be a function"
    end
    local limit = opts.limit or M.DEFAULT_LIMIT
    local stats = { enqueued = 0, failed = 0, unknown = 0, batches = 0 }
    local source = opts.source or {}

    local critical_table = dbmgr.cached_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id)
    if not critical_table then
        return nil, "document not loaded"
    end
    local events = M.pending_events(critical_table, limit)
    if #events == 0 then
        m_pending:set(0, { type = ctx.dbcoll })
        return stats
    end
    m_pending:set(M.count_pending(critical_table), { type = ctx.dbcoll })

    for _, event in ipairs(events) do
        local envelope, eerr = M.envelope(event, source)
        if not envelope then
            log.error("outbox envelope build failed", "event", tostring(event.event_id), "err", eerr)
            stats.failed = stats.failed + 1
        else
            local ok, deliver_err = pcall(deliver, envelope)
            if not ok or deliver_err ~= true then
                -- 投递未确认：保持 PENDING，允许底层 msg_id 重复，业务靠 event_id 去重
                stats.failed = stats.failed + 1
                if not ok then
                    log.warn("outbox deliver raised", "event", event.event_id, "err", deliver_err)
                end
            else
                -- 可靠消息已确认：同一次 CAS 把状态推到 ENQUEUED 并把计数减一
                local next_table = assert(M.transition(critical_table, event.event_id, M.STATUS.ENQUEUED, opts.now))
                local state, detail = dbmgr.critical_update(
                    ctx.dbname,
                    ctx.dbcoll,
                    ctx.key,
                    ctx.unique_id,
                    ctx.doc._version,
                    {
                        ["$set"] = {
                            [M.FIELD .. "." .. event.event_id] = next_table[M.FIELD][event.event_id],
                            [M.PENDING_COUNT_FIELD] = next_table[M.PENDING_COUNT_FIELD],
                        },
                    },
                    {
                        handle = ctx.handle,
                        -- 只有"该事件仍是 PENDING"时才允许推进：另一个 worker 已经推过就
                        -- 不再减第二次计数
                        extra_query = { [M.FIELD .. "." .. event.event_id .. ".status"] = M.STATUS.PENDING },
                    }
                )
                if state == "CONFIRMED" then
                    critical_table = next_table
                    dbmgr.set_critical(ctx.dbname, ctx.dbcoll, ctx.unique_id, critical_table, ctx.handle)
                    stats.enqueued = stats.enqueued + 1
                    m_enqueued:inc(1, { op_type = event.op_type })
                elseif state == "REJECTED" then
                    -- CAS 未命中：多半是另一个 worker 已经推进过。读后像确认即可，
                    -- 这不是"资产已执行但 ACK 丢失"的 UNKNOWN
                    stats.failed = stats.failed + 1
                    log.info("outbox status cas missed", "event", event.event_id, "detail", tostring(detail))
                else
                    stats.unknown = stats.unknown + 1
                    m_unknown:inc(1, { op_type = event.op_type })
                    log.error("outbox status unknown", "event", event.event_id, "detail", tostring(detail))
                    -- 状态未决：不再继续处理后面的事件，避免在不确定的文档上叠加写入
                    return stats
                end
            end
        end
        stats.batches = stats.batches + 1
    end
    m_pending:set(M.count_pending(critical_table), { type = ctx.dbcoll })
    return stats
end

return M
