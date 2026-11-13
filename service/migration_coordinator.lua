-- 计划内迁移协调器（P15）：只负责在停服时驱动 migration.run，并注册停服钩子。
--
-- 为什么阶段实现要由适配器注入：实体枚举、网关屏障、快照传输都跨越部署边界
-- （哪些节点参与、哪台网关存活、屏障怎么确认），框架替它猜一套只会得到一个
-- "看起来迁移成功、实际丢了包"的实现。
--
-- 但"注入"不等于"允许空跑"：运维把 migration.enabled 打开，就必须得到一次真的迁移。
-- 因此 CMD.start 会校验适配器（模块名或 set_adapter 注入）与全部必需阶段，
-- 缺一项就拒绝启动、让节点启动失败 —— 而不是在停服那一刻才发现没有适配器，
-- 把全员掉线伪装成"迁移已完成"。
--
-- 适配器契约见 lualib/skyext/migration.lua 的 deps：
--   list_entities() -> { { id, conn_id, owner_epoch, critical_unknown, busy }, ... }
--   quiesce / freeze / export / transfer / handoff / activate(entity, barrier_id) -> true | nil, reason
--   fallback(entity, reason)  失败/取消/不可续接时的安全出口；缺了会留下冻结客户端
--   probe(entity) -> bool     可选，BUSY 实体的限时等待
--   init(conf)                可选，拿到本服务的配置表
--   begin_round()             可选，新一轮开始时清掉上一次取消的状态
--   abort(reason)             可选，取消时清理还在屏障期的客户端（R-01 兜底）
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local log = require "skyext.log"
local metrics = require "skyext.metrics"
local migration = require "skyext.migration"
local node_shutdown_api = require "skyext.node_shutdown_api"

local m_cancel = metrics.counter("skyext_migration_cancelled_total", "Migration rounds cancelled at shutdown", {
    "reason",
})
local m_abort = metrics.counter("skyext_migration_abort_clients_total", "Clients released by a migration abort", {
    "result",
})

local CMD = {}

local g_adapter
local g_conf
local g_started = false
-- 停服截止时间到达后由 node_shutdown 置位：迁移在每个阶段边界检查它
local g_cancelled = false
-- 最后一次取消的兜底清理结果，供 CMD.stats 观测
local g_abort_stats
-- 取消清理可能 yield（Adapter.abort 内部有并发 RPC）；重复 cancel 不能并发跑两遍
local g_abort_in_progress = false
-- 运行锁：同一时刻只允许一轮迁移
local g_run_active = false

-- 正常阶段和失败出口一个都不能少：缺任何一项都会得到"宣称迁移成功、会话没送到"
-- 或"迁移失败但客户端仍停在冻结态"的假象
local REQUIRED_DEPS = {
    "list_entities",
    "quiesce",
    "freeze",
    "export",
    "transfer",
    "handoff",
    "activate",
    "fallback",
}

-- 可选阶段：probe 只影响 BUSY 实体的等待策略
local OPTIONAL_DEPS = {
    "probe",
}

local function missing_deps(adapter)
    local missing = {}
    for _, name in ipairs(REQUIRED_DEPS) do
        if type(adapter[name]) ~= "function" then
            missing[#missing + 1] = name
        end
    end
    return missing
end

-- 同进程注入（测试、以及把协调器和游戏层放在一个服务里的部署）。
-- 跨服务调用传不了函数，正式接线走 conf.adapter 模块名。
function CMD.set_adapter(adapter)
    if adapter ~= nil and type(adapter) ~= "table" then
        return false, "adapter must be a table"
    end
    g_adapter = adapter
    return true
end

-- 启动。返回 false 时 launcher 会让节点启动失败：配置了迁移却没有可用的适配器，
-- 唯一安全的做法是立刻告诉运维，而不是等到停服时静默退化成"全员重登"。
function CMD.start(conf)
    if g_started then
        return true
    end
    if type(conf) ~= "table" then
        return false, "migration config must be a table"
    end
    if conf.enabled ~= true then
        return false, "migration is not enabled"
    end

    local adapter = g_adapter
    if not adapter then
        local module_name = conf.adapter
        if type(module_name) ~= "string" or module_name == "" then
            return false, "migration.adapter (module name) is required when migration is enabled"
        end
        local loaded_ok, loaded = pcall(require, module_name)
        if not loaded_ok then
            return false, "cannot load migration adapter '" .. module_name .. "': " .. tostring(loaded)
        end
        adapter = loaded
    end
    if type(adapter) ~= "table" then
        return false, "migration adapter must be a table"
    end
    local missing = missing_deps(adapter)
    if #missing > 0 then
        return false, "migration adapter is missing: " .. table.concat(missing, ", ")
    end
    if type(adapter.init) == "function" then
        local init_ok, init_err = pcall(adapter.init, conf)
        if not init_ok then
            return false, "migration adapter init failed: " .. tostring(init_err)
        end
    end

    -- 注册失败不能吞：否则停服时不会跑迁移，运维以为开了
    local hook_ok, hook_err = pcall(node_shutdown_api.add_hook, "migrate", "run", "stats")
    if not hook_ok then
        return false, "cannot register the migrate shutdown hook: " .. tostring(hook_err)
    end

    g_adapter = adapter
    g_conf = conf
    g_started = true
    log.info(
        "migration coordinator ready",
        "type",
        tostring(conf.type_name or "?"),
        "adapter",
        tostring(conf.adapter or "<injected>")
    )
    return true
end

-- 停服钩子会以 CMD 命令的形式调用这里（node_shutdown 的 migrate 阶段）。
-- 没 start 过就明确失败：空实体列表会让停服流程"成功"地什么都不做。
local function run_round(opts)
    g_cancelled = false
    g_abort_stats = nil
    -- 上一轮可能被取消过：适配器内部的 aborted 状态必须在这里复位，
    -- 否则新一轮的所有阶段 RPC 都会被当成"已取消"直接拒绝。
    -- begin_round 返回上一轮没清理掉的屏障数：它只重试清理、绝不清空登记。
    if type(g_adapter.begin_round) == "function" then
        local ok, pending = pcall(g_adapter.begin_round)
        if not ok then
            return false, "migration adapter begin_round failed: " .. tostring(pending)
        end
        if type(pending) == "number" and pending > 0 then
            log.error("migration starts with unresolved barriers from the previous round", "pending", pending)
        end
    end
    local deps = {}
    for _, name in ipairs(REQUIRED_DEPS) do
        deps[name] = g_adapter[name]
    end
    for _, name in ipairs(OPTIONAL_DEPS) do
        deps[name] = g_adapter[name]
    end
    local run_opts = {}
    for k, v in pairs(opts or {}) do
        run_opts[k] = v
    end
    -- 取消令牌：node_shutdown 超时后调 CMD.cancel，迁移在下一个阶段边界停下。
    -- 只停止等待是不够的——迁移协程会和卸载并行跑，源实体被卸掉之后还在写
    run_opts.is_cancelled = function()
        return g_cancelled
    end
    -- 并发：每个实体自己抢锁、自己的 conn 屏障，互不依赖。停服预算只有 timeout/2，
    -- 串行迁几百个在线角色必然超时
    run_opts.concurrency = (g_conf and g_conf.concurrency) or 1
    run_opts.parallel = function(tasks)
        local pending = #tasks
        if pending == 0 then
            return
        end
        local waiter = {}
        for _, task in ipairs(tasks) do
            skynet.fork(function()
                local ok, err = pcall(task)
                if not ok then
                    log.error("migration worker raised", "err", tostring(err))
                end
                pending = pending - 1
                if pending == 0 then
                    skynet.wakeup(waiter)
                end
            end)
        end
        if pending > 0 then
            skynet.wait(waiter)
        end
    end
    local ok, stats, err = pcall(migration.run, deps, run_opts)
    if not ok then
        log.error("migration coordinator raised", "err", tostring(stats))
        return false, stats
    end
    if not stats then
        log.error("migration coordinator failed", "err", tostring(err))
        return false, err
    end
    if g_cancelled then
        log.warn("migration round ended by cancellation", "ready", stats.ready, "cancelled", stats.cancelled)
    end
    return true, stats
end

-- 运行锁：两次 CMD.run 并发会把 g_cancelled 复位成 false，并让两轮
-- begin_round 互相清状态。停服钩子只该跑一轮，重复调用必须显式拒绝
function CMD.run(opts)
    if not g_started or not g_adapter then
        log.error("migration coordinator is not started")
        return false, "migration coordinator is not started"
    end
    if g_run_active then
        return false, "migration round is already running"
    end
    g_run_active = true
    local called, ok, stats = pcall(run_round, opts)
    g_run_active = false
    if not called then
        log.error("migration coordinator raised", "err", tostring(ok))
        return false, ok
    end
    return ok, stats
end

-- 停服截止时间到达：让正在跑的迁移在阶段边界停下，并做网关屏障兜底。
-- 只置标志是不够的：卡在无超时 cluster.call 里的阶段协程收不到它，进程 abort
-- 之后网关的 frozen_epoch 永远没人清，客户端上下行会被一直丢弃。
local function current_abort_pending()
    if g_adapter and type(g_adapter.pending_count) == "function" then
        local called, n = pcall(g_adapter.pending_count)
        if called and type(n) == "number" then
            return n
        end
    end
    if g_abort_stats and type(g_abort_stats.pending) == "number" then
        return g_abort_stats.pending
    end
    return 0
end

function CMD.cancel(reason)
    -- 第一次 cancel 置位并清理；后续 cancel 只有在仍有未解决屏障时才重试。
    -- 已清理完成时必须幂等返回，不能重复踢同一批连接。
    local first = not g_cancelled
    if first then
        g_cancelled = true
        m_cancel:inc(1, { reason = "shutdown_deadline" })
    end
    if g_abort_in_progress then
        return true
    end
    if not first and current_abort_pending() == 0 then
        return true
    end
    if g_adapter and type(g_adapter.abort) == "function" then
        g_abort_in_progress = true
        local called, stats = pcall(g_adapter.abort, reason)
        g_abort_in_progress = false
        if not called then
            log.error("migration abort failed", "err", tostring(stats))
            m_abort:inc(1, { result = "raised" })
        else
            g_abort_stats = stats
            m_abort:inc(stats.kicked or 0, { result = "kicked" })
            m_abort:inc(stats.failed or 0, { result = "failed" })
        end
    end
    log.warn("migration cancelled", "reason", tostring(reason), "pending", current_abort_pending())
    return true
end

-- 只读观测：没就绪时 installed = false，抓取端据此判断"迁移到底开没开"
function CMD.stats()
    return {
        installed = g_started,
        type_name = g_conf and g_conf.type_name or nil,
        adapter = g_conf and g_conf.adapter or nil,
        cancelled = g_cancelled,
        run_active = g_run_active,
        abort_in_progress = g_abort_in_progress,
        abort_pending = current_abort_pending(),
        abort = g_abort_stats,
    }
end

skynet.start(function()
    cmd_api.dispatch(CMD)
end)
