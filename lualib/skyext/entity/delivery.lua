-- 可靠消息投递结果分类与接收侧可观测性。
--
-- 旧 handler 的返回值（nil/true/false/普通 table）一律维持"没有抛异常就是成功"，
-- 不能因为返回 false 就把消息当成环境故障——否则历史消息会永远不 ACK。
-- 新关键 handler 要表达"环境暂态、稍后重投"时必须显式返回本模块的私有标记：
--
--   return delivery.retryable("mongo unavailable")
--
-- entitymgr._deliver_one 只识别这个标记：不 dbmgr.save、不 mark_delivered、
-- 不计 attempts、不进 DLQ，保留 pending 等后续重投。
--
-- 接收侧指标（B6 原先只有发送侧 skyext_outbox_pending）：
--   skyext_reliable_msg_pending{type}                 本 VM 观察到的 pending 条数
--   skyext_reliable_msg_retryable_total{type}         环境故障转换次数
--   skyext_reliable_msg_retry_escalated_total{type}   同一 msg_id 连续 N 次后升级人工
local config = require "skyext.config"
local log = require "skyext.log"
local metrics = require "skyext.metrics"

local M = {}

local RETRYABLE_MT = {}

-- 默认连续多少次环境故障后升级人工。进程重启会清零，这是"同进程连续"的语义，
-- 与 DLQ 的持久 attempts 是两件事：环境故障永远不记毒
M.DEFAULT_ESCALATE_AFTER = 10

local retryable_total = metrics.counter(
    "skyext_reliable_msg_retryable_total",
    "reliable message handlers that returned a retryable environment fault",
    { "type" }
)
local escalated_total = metrics.counter(
    "skyext_reliable_msg_retry_escalated_total",
    "reliable messages that kept failing with environment faults and need manual review",
    { "type" }
)
local pending_gauge =
    metrics.gauge("skyext_reliable_msg_pending", "pending reliable messages observed by this VM", { "type" })

local g_retry_counts = {} -- msg_id -> 连续环境故障次数
local g_pending = {} -- type -> entity_id -> pending 条数

local function escalate_after()
    local n = config.get_number("reliable_msg_retry_escalate")
    if math.type(n) ~= "integer" or n < 1 then
        return M.DEFAULT_ESCALATE_AFTER
    end
    return n
end

function M.retryable(reason)
    return setmetatable({ reason = reason or "retryable environment fault" }, RETRYABLE_MT)
end

function M.is_retryable(value)
    return type(value) == "table" and getmetatable(value) == RETRYABLE_MT
end

-- 记录一次环境故障。返回当前连续次数；达到阈值时返回 true 表示本次已升级
function M.note_retryable(type_name, entity_id, msg_id, reason)
    retryable_total:inc(1, { type = type_name })
    local count = (g_retry_counts[msg_id] or 0) + 1
    g_retry_counts[msg_id] = count
    if count < escalate_after() then
        return false, count
    end
    -- 到阈值后清零，避免每条消息每次重投都刷一行 error；但计数器保留"已升级"的事实
    g_retry_counts[msg_id] = 0
    escalated_total:inc(1, { type = type_name })
    log.error(
        "reliable message keeps returning retryable environment faults, escalating to manual review",
        "type",
        type_name,
        "id",
        entity_id,
        "msg_id",
        msg_id,
        "consecutive",
        count,
        "err",
        reason
    )
    return true, count
end

function M.clear(msg_id)
    g_retry_counts[msg_id] = nil
end

-- 每次读取 pending 页时更新本 VM 的观察值。实体卸载后调用 forget 清掉，
-- 否则 gauge 会永久保留一个已经不在本节点处理的实体
function M.observe_pending(type_name, entity_id, count)
    local per_type = g_pending[type_name]
    if not per_type then
        per_type = {}
        g_pending[type_name] = per_type
    end
    per_type[entity_id] = count > 0 and count or nil
    local sum = 0
    for _, value in pairs(per_type) do
        sum = sum + value
    end
    pending_gauge:set(sum, { type = type_name })
end

function M.forget(type_name, entity_id)
    local per_type = g_pending[type_name]
    if not per_type then
        return
    end
    per_type[entity_id] = nil
    local sum = 0
    for _, value in pairs(per_type) do
        sum = sum + value
    end
    pending_gauge:set(sum, { type = type_name })
end

-- 仅供测试：清空进程内状态（指标本身由 metrics._reset 处理）
function M._reset()
    g_retry_counts = {}
    g_pending = {}
end

return M
