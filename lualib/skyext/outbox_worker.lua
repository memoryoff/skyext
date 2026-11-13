-- Outbox 调度器（P13）。
--
-- 分工：
--   * 本模块只负责**找到待投递的角色**并把短任务交给实际持锁的 owner；
--   * 真正的投递、状态 CAS、计数维护在 `skyext.outbox`；
--   * 资产效果永远由 `skyext.critical` 的提交内核决定。
--
-- 为什么不能自己写角色文档：Outbox 的 `PENDING -> ENQUEUED` 是一次 `_version` CAS，
-- 而角色文档的写入必须和玩家请求走**同一条实体队列**。独立 worker 绕过 owner 直接写，
-- 就会和业务请求抢同一个 `_version`，把"版本冲突"变成线上随机失败。
--
-- 扫描依据是索引字段 `_critical_outbox_pending_count`。没有这个索引，扫描退化成
-- 全表扫描，几千个角色就能把 Mongo 打满——所以 `ensure_indexes` 是启用门禁。
local critical = require "skyext.critical"
local critical_fields = require "skyext.critical_fields"
local log = require "skyext.log"
local metrics = require "skyext.metrics"
local outbox = require "skyext.outbox"

local M = {}

-- 字段名从契约模块取，不从 outbox / critical 取：这两个都会被测试桩替换，
-- 取到 nil 会在构造查询时炸成 "table index is nil"，而不是给出可读的错误
M.FIELD = critical_fields.OUTBOX_PENDING
-- 终态清理标记。只按 pending>0 扫的话，"回执丢了、计数归零"的角色永远不再被扫，
-- 它们的终态事件只能等容量腾挪——而那正是要避免的路径
M.CLEANUP_FIELD = critical_fields.OUTBOX_CLEANUP
M.INDEX_NAME = "critical_outbox_pending"
M.CLEANUP_INDEX_NAME = "critical_outbox_cleanup"
M.DEFAULT_SCAN = 64
M.DEFAULT_BATCH = 16
M.DEFAULT_INTERVAL = 5
-- 一轮里最多为多少个"不在内存"的角色加载实体。加载是有代价的（抢锁、读库、
-- 可能触发 handoff），不设上限时一次扫描就能把整批离线角色全捞起来
M.DEFAULT_MAX_LOADS = 8

local m_scan = metrics.counter("skyext_outbox_scan_total", "Outbox scan rounds", { "result" })
local m_pump = metrics.counter("skyext_outbox_pump_total", "Outbox pump outcomes", { "result" })
local m_age = metrics.histogram(
    "skyext_outbox_pending_age_seconds",
    "Age of the oldest pending outbox event per pumped entity",
    { "type" }
)
local m_scan_size = metrics.gauge("skyext_outbox_scan_candidates", "Roles found by the last scan round", { "type" })
local m_scan_pending = metrics.gauge(
    "skyext_outbox_pending_scanned",
    "Indexed PENDING events across roles in the last scan page",
    { "type" }
)

-- 索引门禁：`_critical_outbox_pending_count > 0` 是偏索引，只为待发角色建条目。
-- 清理标记单独一条偏索引：它只在"有终态事件待清理"时存在，条目数远小于角色总数
function M.index_specs(colls)
    return {
        {
            colls.role,
            {
                { [M.FIELD] = 1 },
                name = M.INDEX_NAME,
                partialFilterExpression = { [M.FIELD] = { ["$gt"] = 0 } },
            },
        },
        {
            colls.role,
            {
                { [M.CLEANUP_FIELD] = 1 },
                name = M.CLEANUP_INDEX_NAME,
                partialFilterExpression = { [M.CLEANUP_FIELD] = { ["$exists"] = true } },
            },
        },
    }
end

-- 返回 true 或 nil, err。建不起来时调用方必须禁止启用 Outbox 调度
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
        -- 驱动把 runCommand 的原始回复直接返回：失败是 { ok = 0, errmsg = ... }
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

-- 扫描待处理角色。skip 用于轮转，避免"永远只处理最前面那一批"：
-- 前面的角色一直投不出去时，后面的角色会饿死
-- 返回 [{ rid, pending, cleanup_due }], next_skip 或 nil, err
--
-- 两个条件取并集：
--   * pending > 0        还有待发事件
--   * cleanup_at <= now  有到期的终态事件（回执丢失后计数已归零的角色靠这条才被扫到）
function M.scan(role_coll, opts)
    opts = opts or {}
    if type(role_coll) ~= "table" then
        return nil, "role collection is required"
    end
    local key = opts.key or "rid"
    local limit = opts.limit or M.DEFAULT_SCAN
    local skip = opts.skip or 0
    local now = opts.now or os.time()
    local called, docs, err = pcall(role_coll.find_many, role_coll, {
        ["$or"] = {
            { [M.FIELD] = { ["$gt"] = 0 } },
            { [M.CLEANUP_FIELD] = { ["$lte"] = now } },
        },
    }, {
        projection = { [key] = 1, [M.FIELD] = 1, [M.CLEANUP_FIELD] = 1, _id = 0 },
        -- 按主键排序保证轮转分页稳定；不排序时 Mongo 的返回顺序在数据变动后会漂移
        sort = { { [key] = 1 } },
        skip = skip,
        limit = limit,
    })
    if not called then
        return nil, "scan failed: " .. tostring(docs)
    end
    if type(docs) ~= "table" then
        return nil, tostring(err or "scan failed")
    end
    local list = {}
    for _, doc in ipairs(docs) do
        if type(doc) == "table" and doc[key] ~= nil then
            local due = doc[M.CLEANUP_FIELD]
            list[#list + 1] = {
                rid = doc[key],
                pending = doc[M.FIELD] or 0,
                cleanup_due = math.type(due) == "integer" and due <= now,
            }
        end
    end
    -- 这一页没满说明已经到末尾，下一轮从头开始
    local next_skip = skip + #list
    if #docs < limit then
        next_skip = 0
    end
    return list, next_skip
end

-- 默认投递：走现有可靠消息接口。msg_id 由可靠消息模块分配，event_id 才是业务去重键。
--
-- 返回值语义（pump 依赖它区分"暂时送不出去"和"永远送不出去"）：
--   true                   已确认入队
--   delivery.retryable(...) 环境故障（Mongo 抖动、连接池耗尽、写关注失败）
--   其它                    永久失败，计入毒事件阈值
--
-- 这里必须把落库异常翻成 retryable：`reliable_msg.save` 在 Mongo 抖动时抛错，
-- 如果让它冒成 pcall 失败，pump 会把"环境抖动 5 次（约 25 秒）"当成毒事件，
-- 把一条**源端资产已经扣掉**的事件标成 FAILED，而业务从未执行。
function M.default_deliver(envelope)
    local router = require "skyext.entity.router"
    local delivery = require "skyext.entity.delivery"
    local called, msg_id =
        pcall(router.reliable_send, envelope.target_type, envelope.target_id, "__apply_outbox_event", { envelope })
    if not called then
        return delivery.retryable("reliable_send raised: " .. tostring(msg_id))
    end
    if msg_id == nil then
        return delivery.retryable("reliable_send returned no msg_id")
    end
    return true
end

-- 在实体队列内执行：由 entity_agent 的 `outbox_pump` 命令调用。
-- 这里拿到的是**已经持锁的**实体，所以 CAS 的 fence 条件一定成立
function M.pump_entity(entity, opts)
    opts = opts or {}
    local ctx, cerr = critical.coords_of(entity)
    if not ctx then
        return nil, cerr
    end
    local source = opts.source or { type = entity.type_name, id = entity.id }
    local stats, err = outbox.pump(ctx, opts.deliver or M.default_deliver, {
        limit = opts.limit or M.DEFAULT_BATCH,
        now = opts.now,
        source = source,
        cas_retry = opts.cas_retry,
    })
    if not stats then
        return nil, err
    end
    stats.type = entity.type_name
    m_age:observe(stats.oldest_age or 0, { type = entity.type_name })
    return stats
end

local function merge_stats(total, stats)
    for _, field in ipairs({ "enqueued", "failed", "unknown", "already", "batches", "cleaned", "retryable" }) do
        total[field] = (total[field] or 0) + (stats[field] or 0)
    end
    total.pending = (total.pending or 0) + (stats.pending or 0)
end

-- 跑一轮：扫描 -> 逐个交给 owner。
--
-- deps:
--   role_coll            角色集合
--   pump(rid, limit)     只对已加载实体投递，返回 ok, stats|reason
--   pump_loaded(rid,limit) 可选：会为离线角色加载实体（受 max_loads 限制）
--   cursor               轮转游标，由本函数维护
--   now                  时间注入
function M.run_once(deps, opts)
    opts = opts or {}
    if type(deps) ~= "table" or type(deps.pump) ~= "function" then
        return nil, "deps.pump is required"
    end
    local batch = opts.limit or M.DEFAULT_BATCH
    local max_loads = opts.max_loads or M.DEFAULT_MAX_LOADS
    local list, next_skip = M.scan(deps.role_coll, {
        key = opts.key or deps.key,
        limit = opts.scan_limit or M.DEFAULT_SCAN,
        skip = deps.cursor or 0,
        now = opts.now or os.time(),
    })
    if not list then
        m_scan:inc(1, { result = "error" })
        return nil, next_skip
    end
    deps.cursor = next_skip
    m_scan:inc(1, { result = "ok" })
    m_scan_size:set(#list, { type = opts.type_name or "role" })

    local stats = {
        scanned = #list,
        scan_pending = 0,
        pumped = 0,
        enqueued = 0,
        failed = 0,
        unknown = 0,
        already = 0,
        batches = 0,
        pending = 0,
        skipped = 0,
        loads = 0,
        cleaned = 0,
        retryable = 0,
    }
    for _, entry in ipairs(list) do
        local pending = entry.pending or 0
        if math.type(pending) == "integer" and pending > 0 then
            stats.scan_pending = stats.scan_pending + pending
        end
    end
    m_scan_pending:set(stats.scan_pending, { type = opts.type_name or "role" })
    for _, entry in ipairs(list) do
        if (entry.pending or 0) <= 0 and not entry.cleanup_due then
            -- 索引字段是陈旧的（事件已被消费但计数没来得及更新）：不加载、不投递
            stats.skipped = stats.skipped + 1
        else
            local ok, result = deps.pump(entry.rid, batch)
            if not ok and deps.pump_loaded and stats.loads < max_loads then
                -- 实体不在内存里：受控加载后再投一次，让离线角色的积压也能排空
                stats.loads = stats.loads + 1
                ok, result = deps.pump_loaded(entry.rid, batch)
            end
            if ok and type(result) == "table" then
                stats.pumped = stats.pumped + 1
                merge_stats(stats, result)
                m_pump:inc(1, { result = "ok" })
            else
                stats.skipped = stats.skipped + 1
                m_pump:inc(1, { result = "skipped" })
                log.debug("outbox pump skipped", "rid", tostring(entry.rid), "reason", tostring(result))
            end
        end
    end
    return stats
end

-- 常驻循环。`stop` 由调用方通过返回值控制：返回 false 时退出
function M.loop(deps, opts)
    opts = opts or {}
    local interval = opts.interval or M.DEFAULT_INTERVAL
    local sleep = deps.sleep
    if type(sleep) ~= "function" then
        return nil, "deps.sleep is required"
    end
    while not deps.stopped do
        local stats, err = M.run_once(deps, opts)
        if not stats then
            log.error("outbox scan failed", "err", tostring(err))
            m_scan:inc(1, { result = "error" })
        elseif stats.unknown > 0 then
            -- 有未决状态：本轮已经停下，下一轮重新读文档再判断
            log.warn("outbox round had unknown status", "count", stats.unknown)
        end
        sleep(interval)
    end
    return true
end

return M
