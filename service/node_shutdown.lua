-- 节点停服编排。顺序：
--   1. stop_accepting 钩子：关掉对外入口（gate、HTTP 端口），不再放新请求进来
--   2. migrate 钩子：计划内迁移（P15）。游戏层在这里调 `skyext.migration`，
--      把在线玩家的会话搬到别的节点，避免整节点重启变成全员掉线。
--      不注册就跳过，退化成第 3 步的"卸载 + 重登"
--   3. 卸载本节点所有实体类型的全部实体：落库、释放锁、踢下在线玩家
--   4. release 钩子：实体都落库之后释放其余资源（snowflake 归还机器号之类）
--   5. 停掉服务注册，再撤销节点级 etcd 租约：节点键、服务键、残留的实体锁一并消失，
--      别的节点立刻看到本节点下线，不用等 TTL 过期
--   6. 让 logger 写完缓冲，退出进程
-- 第 3 步有实体卸不掉时停在这里、进程不退出：那些实体还有没落库的改动，退出就丢了。
-- 排查后可以再发一次 shutdown。游戏层用 skyext.node_shutdown_api 挂钩子。
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local gm_api = require "skyext.gm_api"
local cluster_discovery = require "skyext.cluster_discovery"
local node_lease = require "skyext.node_lease"
local log = require "skyext.log"

local DEFAULT_TIMEOUT = 60

local g_hooks = {
    stop_accepting = {},
    migrate = {},
    release = {},
}
local g_running = false
-- 迁移钩子超时且 Abort 仍有未解决屏障时：进程必须活着，下一次 shutdown 只重试
-- cancel/status，不能重新启动一轮正常迁移。
local g_migration_cleanup_pending = false

local function run_hooks(phase)
    for _, hook in ipairs(g_hooks[phase]) do
        local ok, err = pcall(skynet.call, hook.addr, "lua", hook.cmd)
        if not ok then
            log.warn("shutdown hook failed", "phase", phase, "addr", hook.addr, "cmd", hook.cmd, "err", err)
        end
    end
end

local function cancel_hooks(phase, reason)
    for _, hook in ipairs(g_hooks[phase]) do
        local cancelled, cerr = pcall(skynet.send, hook.addr, "lua", "cancel", reason)
        if not cancelled then
            log.warn("shutdown hook cancel failed", "phase", phase, "addr", hook.addr, "err", cerr)
        end
    end
end

-- 只把实现 status_cmd 的钩子纳入完成判断。老钩子没有状态查询协议，
-- 继续沿用原来的"超时后卸载"降级，不能因为无法查询就永久卡住。
local function migration_pending()
    for _, hook in ipairs(g_hooks.migrate) do
        if hook.status_cmd then
            local ok, status = pcall(skynet.call, hook.addr, "lua", hook.status_cmd)
            if not ok then
                log.error("shutdown migration status failed", "addr", hook.addr, "err", tostring(status))
                return true
            end
            if type(status) == "table" then
                if type(status.abort_pending) == "number" and status.abort_pending > 0 then
                    return true
                end
                if status.abort_in_progress == true or status.run_active == true then
                    return true
                end
            else
                -- 有状态查询协议但没拿到状态表：无法证明清理完成，按未完成处理。
                log.error("shutdown migration status was not a table", "addr", hook.addr, "status", tostring(status))
                return true
            end
        end
    end
    return false
end

-- 带截止时间的钩子。迁移要跨节点 RPC，卡住的话停服会永久停在卸载之前，
-- 而 g_running 已置位、再发一次 shutdown 只会得到 "already shutting down"。
-- 超时后先给每个钩子发 cancel 让它在阶段边界停下，再继续卸载：
-- 只停止等待是不够的，迁移协程会和卸载并行跑，源实体被卸掉之后还在写。
-- migrate 阶段的钩子必须实现 cancel（migration_coordinator 实现了）。
-- 返回 true 表示至少一个钩子超时。
local function run_hooks_with_deadline(phase, timeout_sec)
    local hooks = g_hooks[phase]
    if #hooks == 0 then
        return false
    end
    local pending = #hooks
    for _, hook in ipairs(hooks) do
        skynet.fork(function()
            local ok, err = pcall(skynet.call, hook.addr, "lua", hook.cmd)
            if not ok then
                log.warn("shutdown hook failed", "phase", phase, "addr", hook.addr, "cmd", hook.cmd, "err", err)
            end
            pending = pending - 1
        end)
    end
    local waited = 0
    while pending > 0 and waited < timeout_sec * 100 do
        skynet.sleep(100)
        waited = waited + 100
    end
    if pending > 0 then
        log.error("shutdown hook timed out", "phase", phase, "pending", pending, "timeout", timeout_sec)
        cancel_hooks(phase, "shutdown deadline")
        -- cancel 是单向消息。给协调器一小段宽限，让它把「踢掉屏障期客户端」
        -- 的兜底清理跑完；否则进程紧接着 abort，cancel 可能根本没被处理。
        pcall(skynet.sleep, 10)
        return true
    end
    return false
end

-- 本节点上起了的 entity_agentmgr：按实体类型配置逐个查本地名字，没在本节点起的类型跳过
local function entity_managers()
    local ok, all = pcall(function()
        return require("skyext.entity.types").all()
    end)
    if not ok then
        return {}
    end
    local list = {}
    for type_name in pairs(all) do
        local addr = skynet.localname(".entity_agentmgr:" .. type_name)
        if addr then
            list[#list + 1] = { type_name = type_name, addr = addr }
        end
    end
    return list
end

-- 各实体类型并行卸载，返回还没卸掉的实体总数
local function unload_entities(timeout_sec)
    local managers = entity_managers()
    local remaining = 0
    local pending = #managers
    local waiter = {}
    for _, mgr in ipairs(managers) do
        skynet.fork(function()
            local ok, count = pcall(skynet.call, mgr.addr, "lua", "shutdown", timeout_sec)
            if not ok then
                log.error("entity shutdown failed", "type", mgr.type_name, "err", count)
                -- 不知道还剩多少，至少算一个，免得误以为已经卸干净
                count = 1
            end
            remaining = remaining + count
            pending = pending - 1
            if pending == 0 then
                skynet.wakeup(waiter)
            end
        end)
    end
    if pending > 0 then
        skynet.wait(waiter)
    end
    return remaining
end

local function shutdown(timeout_sec)
    log.info("node shutdown begin", "timeout", timeout_sec)
    run_hooks("stop_accepting")
    -- 计划内迁移：必须在卸载之前。迁移不成功时实体照常卸载，玩家重登即可，
    -- 不能因为迁移失败就把进程留在半死不活的状态。超时用整个停服预算的一半，
    -- 剩下的时间要留给卸载。
    local migration_timed_out
    if g_migration_cleanup_pending then
        -- 上一次停服已经超时并发出过 cancel；重试只清理 Abort，不重新开一轮迁移。
        cancel_hooks("migrate", "shutdown retry")
        pcall(skynet.sleep, 10)
        migration_timed_out = true
    else
        migration_timed_out = run_hooks_with_deadline("migrate", math.max(1, math.floor(timeout_sec / 2)))
    end
    if migration_timed_out and migration_pending() then
        -- Abort 还没完成，或迁移协程仍在跑：此时卸载会让实体在迁移写入之后被删。
        -- 保留进程，让运维可以再次 shutdown 重试；g_running 复位以接受重试。
        g_migration_cleanup_pending = true
        log.error("node shutdown incomplete, migration abort still pending")
        g_running = false
        return
    end
    g_migration_cleanup_pending = false
    local remaining = unload_entities(timeout_sec)
    if remaining ~= 0 then
        log.error("node shutdown incomplete, process kept alive", "remaining", remaining)
        g_running = false
        return
    end
    run_hooks("release")
    -- 先停注册再撤租约：反过来的话，撤销之后心跳还会再跑一拍，用新租约把节点键写回去
    local stopped, stop_err = pcall(cluster_discovery.shutdown)
    if not stopped then
        log.warn("cluster discovery shutdown failed", "err", stop_err)
    end
    local revoked, revoke_err = pcall(node_lease.shutdown)
    if not revoked then
        log.warn("node lease revoke failed", "err", revoke_err)
    end
    log.info("node shutdown complete, exiting")
    pcall(skynet.call, ".logger", "lua", "close")
    skynet.abort()
end

local CMD = {}

-- 停服时回调 addr 服务的 cmd 命令。同一个 (phase, addr, cmd) 只记一次，按注册顺序执行。
-- status_cmd 可选：migrate 超时后用来确认 Abort 是否真的完成。
function CMD.add_hook(phase, addr, cmd, status_cmd)
    local hooks = assert(g_hooks[phase], "unknown shutdown phase: " .. tostring(phase))
    assert(type(cmd) == "string" and cmd ~= "", "shutdown hook needs a command")
    if status_cmd ~= nil then
        assert(type(status_cmd) == "string" and status_cmd ~= "", "shutdown status command must be a string")
    end
    for _, hook in ipairs(hooks) do
        if hook.addr == addr and hook.cmd == cmd then
            return true
        end
    end
    hooks[#hooks + 1] = { addr = addr, cmd = cmd, status_cmd = status_cmd }
    return true
end

-- 开始停服。卸载可能要几十秒，这里立刻返回，进度看日志
function CMD.shutdown(timeout_sec)
    if g_running then
        return false, "already shutting down"
    end
    g_running = true
    skynet.fork(shutdown, tonumber(timeout_sec) or DEFAULT_TIMEOUT)
    return true, "shutdown started"
end

local GM_CMD = {
    shutdown = {
        desc = "停服：停止接入、卸载全部实体落库后退出进程",
        params = { timeout = "等实体卸载的秒数，默认 60" },
        handler = function(params)
            return CMD.shutdown(params.timeout)
        end,
    },
}

skynet.start(function()
    cmd_api.dispatch(CMD)
    gm_api.register(GM_CMD)
end)
