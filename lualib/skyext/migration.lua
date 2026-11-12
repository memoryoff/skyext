-- 计划内 Role 迁移编排（P15）。
--
-- 六个阶段，每个实体独立分流；节点退出时**不能**因为一个玩家的关键操作未决就永久卡住。
--
--   DRAINING      节点不再接受新实体加载/新绑定，现有实体继续服务
--   QUIESCING     Role 停止所有会改实体或发下行的入口，等实体队列排空
--   GATE_BARRIER  以 conn_id + owner_epoch 确认网关已切断旧 owner 的新下行
--   TRANSFER      导出 SessionSnapshotV1（含 out_buf 原字节 + L1 resp_cache）并送达目标
--   OWNER_HANDOFF 目标经多数派 Fence 认领后安装会话，session_epoch 保持不变
--   REPLAYING     新 owner 用新 owner_epoch 重放原样已编码包，等客户端连续 ACK
--
-- 失败分流（文档 §7.3）：
--   READY            正常迁移
--   BUSY             限时等待，超时按 FALLBACK 处理
--   CRITICAL_UNKNOWN 禁止无感移交：转 B2 安全恢复，客户端可以重连但不能绕过 Fence
--   FALLBACK         明确提示断线续接或重新登录
--
-- 本模块只做编排：每个阶段的真实动作由 deps 注入（它们要碰网关、实体队列、集群）。
-- 这样状态机、超时与分流可以被完整测试，而不用起真集群。
local log = require "skyext.log"
local metrics = require "skyext.metrics"

local M = {}

M.PHASE = {
    DRAINING = "DRAINING",
    QUIESCING = "QUIESCING",
    GATE_BARRIER = "GATE_BARRIER",
    TRANSFER = "TRANSFER",
    OWNER_HANDOFF = "OWNER_HANDOFF",
    REPLAYING = "REPLAYING",
    ACTIVE = "ACTIVE",
}

M.STATUS = {
    READY = "READY",
    BUSY = "BUSY",
    CRITICAL_UNKNOWN = "CRITICAL_UNKNOWN",
    FALLBACK = "FALLBACK",
}

M.DEFAULT_BARRIER_TIMEOUT = 5
M.DEFAULT_BUSY_ATTEMPTS = 20

local m_phase = metrics.histogram("skyext_migration_phase_seconds", "Time spent in a migration phase", { "phase" })
local m_status = metrics.counter("skyext_migration_entities_total", "Migrated entities by outcome", { "status" })
local m_fallback = metrics.counter(
    "skyext_migration_fallback_total",
    "Entities that could not be migrated without a reconnect",
    { "reason" }
)

local function now_of(opts)
    return (opts and opts.now) or os.time()
end

-- 阶段耗时要算真实等待时间，不能用 os.clock()（那是 CPU 时间，跨网络的阶段恒 ≈0）。
-- 允许注入，避免这个模块依赖 skynet
local function clock()
    if type(M.clock) == "function" then
        return M.clock()
    end
    return os.time()
end

-- 指标标签只取阶段名，完整错误串进日志
local function reason_code(reason)
    local text = tostring(reason or "unknown")
    return text:match("^([%w_]+)") or "unknown"
end

local function fail(status, detail)
    return status, detail
end

-- 取消令牌：停服编排在截止时间到达后置位，迁移必须在阶段边界停下来。
-- 不检查的话，超时后迁移协程还在跑，而卸载已经并行开始——源实体被卸掉之后
-- 迁移还在写，或者目标刚装好源端又清了一次
local function cancelled(opts)
    if type(opts) == "table" and type(opts.is_cancelled) == "function" then
        return opts.is_cancelled() == true
    end
    return false
end
M.cancelled = cancelled

-- 单个实体走完六阶段。返回 M.STATUS.*，以及失败原因。
--
-- deps 里的每个函数返回 true 表示这一步已确认；返回 nil, reason 表示这一步失败。
-- 任何一步失败都按 FALLBACK 处理：**不能**宣称"无感迁移成功"再把客户端留在
-- 一个没有下行入口的会话上。
function M.migrate_entity(deps, entity, opts)
    opts = opts or {}
    if type(deps) ~= "table" or type(entity) ~= "table" then
        return fail(M.STATUS.FALLBACK, "invalid arguments")
    end
    local barrier_id = opts.barrier_id or ("mig_" .. tostring(entity.id))
    -- 缺依赖一律 fail-closed：把"没配 export"当成成功，会得到一个宣称迁移完成、
    -- 但快照从未送达的会话
    local function step(phase, fn)
        if cancelled(opts) then
            return nil, "cancelled before " .. phase
        end
        if type(fn) ~= "function" then
            return nil, phase .. " is not configured"
        end
        local started = clock()
        local ok, result, err = pcall(fn, entity, barrier_id)
        m_phase:observe(clock() - started, { phase = phase })
        if not ok then
            return nil, tostring(result)
        end
        -- 步骤返回 `router.call` 的结果：成功是 `true, payload`，失败是 `false, reason`。
        -- 这里只认"非 nil 非 false"，否则 `session_import` 返回的 payload 会被当成失败
        if result == nil or result == false then
            return nil, tostring(err or phase .. " failed")
        end
        return true
    end

    -- QUIESCING：实体队列排空后，队列里已经没有会改状态或发下行的入口
    local ok, err = step(M.PHASE.QUIESCING, deps.quiesce)
    if not ok then
        return fail(M.STATUS.FALLBACK, "quiesce: " .. tostring(err))
    end

    -- GATE_BARRIER：网关确认旧 owner_epoch 的新下行入口已切断
    ok, err = step(M.PHASE.GATE_BARRIER, deps.freeze)
    if not ok then
        return fail(M.STATUS.FALLBACK, "barrier: " .. tostring(err))
    end

    -- TRANSFER：导出快照并送达目标。快照含二进制 hash/nonce/pack，只能走可信通道
    if cancelled(opts) then
        return fail(M.STATUS.FALLBACK, "cancelled before export")
    end
    if type(deps.export) ~= "function" then
        return fail(M.STATUS.FALLBACK, "export is not configured")
    end
    -- pcall 多插一个 true：只取两个返回值会把 `true` 当成快照
    local exported_ok, snapshot, eerr = pcall(deps.export, entity, barrier_id)
    if not exported_ok or type(snapshot) ~= "table" then
        return fail(M.STATUS.FALLBACK, "export: " .. tostring(eerr or snapshot or "no snapshot"))
    end
    -- 导出之后取消最危险：源端已经冻结下行，而目标还没接住。
    -- 交给 fallback（踢客户端重连）比继续把快照送出去更安全
    if cancelled(opts) then
        return fail(M.STATUS.FALLBACK, "cancelled before transfer")
    end
    if type(deps.transfer) ~= "function" then
        return fail(M.STATUS.FALLBACK, "transfer is not configured")
    end
    local moved, merr = pcall(deps.transfer, entity, snapshot)
    if not moved or merr == nil or merr == false then
        return fail(M.STATUS.FALLBACK, "transfer: " .. tostring(merr))
    end

    -- OWNER_HANDOFF：目标认领 + 安装。到这里 session_epoch 必须还是原来那个
    ok, err = step(M.PHASE.OWNER_HANDOFF, deps.handoff)
    if not ok then
        return fail(M.STATUS.FALLBACK, "handoff: " .. tostring(err))
    end

    -- REPLAYING：重放原样已编码包并等客户端连续 ACK
    ok, err = step(M.PHASE.REPLAYING, deps.activate)
    if not ok then
        -- 回放失败也不能退回旧 owner：旧 owner 的下行入口已经被屏障切断
        return fail(M.STATUS.FALLBACK, "replay: " .. tostring(err))
    end

    return M.STATUS.READY, nil
end

-- 迁移一批实体。单个实体失败不影响其它实体；CRITICAL_UNKNOWN 只降级该玩家。
--
-- deps:
--   list_entities() -> { { id = , conn_id = , owner_epoch = , critical_unknown = bool }, ... }
--   quiesce / freeze / export / transfer / handoff / activate
--   fallback(entity, reason)   降级处理（提示断线续接或重新登录）
--   now
function M.run(deps, opts)
    opts = opts or {}
    if type(deps) ~= "table" or type(deps.list_entities) ~= "function" then
        return nil, "deps.list_entities is required"
    end
    local called, entities, lerr = pcall(deps.list_entities)
    if not called then
        return nil, "list_entities failed: " .. tostring(entities)
    end
    if type(entities) ~= "table" then
        return nil, tostring(lerr or "list_entities returned no list")
    end

    local stats = { total = #entities, ready = 0, fallback = 0, critical_unknown = 0, busy = 0, cancelled = 0 }
    local started = 0

    local function migrate_one(entity)
        local status, reason
        if entity.critical_unknown then
            -- 关键操作未决：禁止无感移交。留下持久化 PREPARED/记录后走降级路径，
            -- 单个玩家不能永久阻塞整节点退出
            status = M.STATUS.CRITICAL_UNKNOWN
            reason = "critical_unknown"
            stats.critical_unknown = stats.critical_unknown + 1
            m_fallback:inc(1, { reason = "critical_unknown" })
        else
            -- BUSY：限时等待。无限等待会让节点退出被一个玩家拖死
            if entity.busy and not M.wait_busy(deps, entity, opts) then
                status = M.STATUS.FALLBACK
                reason = "busy"
                stats.busy = stats.busy + 1
            else
                status, reason = M.migrate_entity(deps, entity, {
                    barrier_id = opts.barrier_id,
                    now = now_of(opts),
                    -- 令牌要传下去：取消发生在实体中途时，下一个阶段边界就会停
                    is_cancelled = opts.is_cancelled,
                })
            end
            if status == M.STATUS.READY then
                stats.ready = stats.ready + 1
            else
                stats.fallback = stats.fallback + 1
                -- 标签只用阶段名（"quiesce" / "handoff"），完整错误串进日志：
                -- 把错误文本当 label 会让指标基数爆炸
                m_fallback:inc(1, { reason = reason_code(reason) })
            end
        end
        m_status:inc(1, { status = status })
        if status ~= M.STATUS.READY and type(deps.fallback) == "function" then
            local ok, ferr = pcall(deps.fallback, entity, reason or status)
            if not ok then
                log.error("migration fallback failed", "id", tostring(entity.id), "err", tostring(ferr))
            end
        end
    end

    -- 并发：实体之间互不依赖（各自的实体锁、各自的 conn 屏障），停服预算又只有
    -- timeout/2，串行时几百个在线角色就会吃满。并发度由调用方给，框架不猜
    local concurrency = math.tointeger(opts.concurrency) or 1
    if concurrency > 1 and type(deps.parallel) == "function" and #entities > 1 then
        local index = 0
        local tasks = {}
        for _ = 1, math.min(concurrency, #entities) do
            tasks[#tasks + 1] = function()
                while not cancelled(opts) do
                    index = index + 1
                    local entity = entities[index]
                    if not entity then
                        return
                    end
                    started = started + 1
                    local ok, err = pcall(migrate_one, entity)
                    if not ok then
                        -- 单个实体的意外错误不能带走整批：剩下的还要继续迁
                        log.error("migration worker failed", "id", tostring(entity.id), "err", tostring(err))
                    end
                end
            end
        end
        deps.parallel(tasks)
    else
        for _, entity in ipairs(entities) do
            if cancelled(opts) then
                break
            end
            started = started + 1
            migrate_one(entity)
        end
    end

    if cancelled(opts) then
        -- 停服截止时间已到：没开始的交给卸载（客户端重连），已经开始的会自己走到 FALLBACK
        stats.cancelled = #entities - started
        log.warn("migration cancelled", "remaining", stats.cancelled, "started", started)
    end
    log.info(
        "migration round finished",
        "total",
        stats.total,
        "ready",
        stats.ready,
        "fallback",
        stats.fallback,
        "critical_unknown",
        stats.critical_unknown,
        "cancelled",
        stats.cancelled
    )
    return stats
end

-- 等待一个 BUSY 实体。限时等待后仍 BUSY 就返回 false，由调用方按 FALLBACK 处理：
-- 无限等待会让节点退出被一个玩家拖死
function M.wait_busy(deps, entity, opts)
    opts = opts or {}
    if type(deps.probe) ~= "function" then
        return false
    end
    local attempts = opts.attempts or M.DEFAULT_BUSY_ATTEMPTS
    for _ = 1, attempts do
        local ok, ready = pcall(deps.probe, entity)
        if ok and ready == true then
            return true
        end
        if type(deps.sleep) == "function" then
            deps.sleep(opts.interval or 0.1)
        end
    end
    return false
end

return M
