-- 计划内迁移协调器（P15）：只负责在停服时驱动 migration.run，并注册停服钩子。
--
-- 为什么阶段实现要由适配器注入：实体枚举、网关屏障、快照传输都跨越部署边界
-- （哪些节点参与、哪台网关存活、屏障怎么确认），框架替它猜一套只会得到一个
-- "看起来迁移成功、实际丢了包"的实现。没注入适配器时本服务返回空实体列表，
-- 停服流程退化为普通卸载 —— 安全，但明确不是无感迁移。
--
-- 适配器契约见 lualib/skyext/migration.lua 的 deps：
--   list_entities() -> { { id, conn_id, owner_epoch, critical_unknown, busy }, ... }
--   quiesce / freeze / export / transfer / handoff / activate(entity) -> true | false, reason
--   fallback(entity, reason)
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local log = require "skyext.log"
local migration = require "skyext.migration"
local node_shutdown_api = require "skyext.node_shutdown_api"

local CMD = {}

local g_adapter

local DEP_NAMES = {
    "list_entities",
    "quiesce",
    "freeze",
    "export",
    "transfer",
    "handoff",
    "activate",
    "fallback",
}

-- 由节点启动流程或游戏层在停服前注入。只接受函数字段，缺项由 migration.run 报错
function CMD.set_adapter(adapter)
    if adapter ~= nil and type(adapter) ~= "table" then
        return false, "adapter must be a table"
    end
    g_adapter = adapter
    return true
end

local function default_adapter()
    -- 空列表：没有实体需要迁移，停服继续走 unload。绝不假装完成了一次无感迁移
    return {
        list_entities = function()
            return {}
        end,
    }
end

-- 停服钩子会以 CMD 命令的形式调用这里（node_shutdown 的 migrate 阶段）
function CMD.run(opts)
    local adapter = g_adapter or default_adapter()
    local deps = {}
    for _, name in ipairs(DEP_NAMES) do
        deps[name] = adapter[name]
    end
    local ok, stats, err = pcall(migration.run, deps, opts or {})
    if not ok then
        log.error("migration coordinator raised", "err", tostring(stats))
        return false, stats
    end
    if not stats then
        log.error("migration coordinator failed", "err", tostring(err))
        return false, err
    end
    return true, stats
end

function CMD.stats()
    return g_adapter ~= nil
end

skynet.start(function()
    cmd_api.dispatch(CMD)
    -- 注册失败不能吞：否则停服时不会跑迁移，运维以为开了
    local ok, err = pcall(node_shutdown_api.add_hook, "migrate", "run")
    if not ok then
        log.error("migration coordinator failed to register the migrate hook", "err", tostring(err))
    end
end)
