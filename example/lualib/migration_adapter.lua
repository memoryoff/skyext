-- 计划内 Role 迁移的示例适配器（P15）。
--
-- 框架只提供原语：实体枚举 / 冻结 / 释放（entitymgr）、快照导出与安装（entity_agent）、
-- 网关屏障与重指向（gate_owner）。哪些节点参与、目标怎么选、失败怎么提示客户端，
-- 是部署形态决定的，所以由游戏层实现，通过 `migration.adapter = "migration_adapter"`
-- 交给 migration_coordinator 的启动门禁校验。
--
-- 六阶段的实际动作（与 docs/design/migration_v1.md 一一对应）：
--
--   quiesce  源实体冻结：停止执行上行、停止追加下行、取消空闲卸载计时器
--   freeze   网关屏障：旧 owner_epoch 的上行与下行都丢弃
--   export   源端导出 SessionSnapshotV2（含 out_buf 原字节与 L1 幂等缓存）
--   transfer 源端落库 + 释放锁（不踢客户端），快照送到目标进程暂存
--   handoff  目标抢锁（Fence 认领）并安装快照
--   activate 目标把连接接过来并重放未确认下行；网关把会话指向新 owner
--
-- 目标节点必须显式寻址（cluster.call + agent 注册名）。**不能用 router.call**：
-- 它按 HRW 选节点，而迁移期间实体还在源节点上，路由会把它转回源端。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local cluster_discovery = require "skyext.cluster_discovery"
local config = require "skyext.config"
local connection_id = require "skyext.connection_id"
local log = require "skyext.log"
local types = require "skyext.entity.types"

local M = {}

local g_type
local g_self_node

local function self_node()
    if not g_self_node then
        g_self_node = assert(config.get("cluster_node_name"), "cluster_node_name is not configured")
    end
    return g_self_node
end

local function agent_service(entity_id)
    return types.format_agent_service_name(g_type, types.calc_agent_index(g_type, entity_id))
end

-- 本节点与远端统一入口：同节点直接调，跨节点走 cluster。返回值和被调服务一致
local function call_agent(node, entity_id, cmd, ...)
    local service = agent_service(entity_id)
    if node == self_node() then
        return skynet.call(service, "lua", cmd, ...)
    end
    return cluster.call(node, service, cmd, ...)
end

local function call_gate(conn_id, cmd, ...)
    local parsed, err = connection_id.parse(conn_id)
    if not parsed then
        return nil, "invalid conn_id: " .. tostring(err)
    end
    local args = table.pack(...)
    if parsed.gate_node == self_node() then
        return skynet.call(parsed.gate_service, "lua", cmd, table.unpack(args, 1, args.n))
    end
    return cluster.call(parsed.gate_node, parsed.gate_service, cmd, table.unpack(args, 1, args.n))
end

function M.init(conf)
    conf = conf or {}
    g_type = assert(conf.type_name, "migration.type_name is required")
    g_self_node = nil
    log.info("migration adapter ready", "type", g_type, "node", self_node())
end

-- 只枚举"能无感移交"的实体：有连接、持久化、没有正在进行的迁移/卸载。
-- 没有连接的实体迁移过去也没有意义，留给普通卸载 + 客户端重新登录
function M.list_entities()
    local mgr = skynet.localname(".entity_agentmgr:" .. g_type)
    if not mgr then
        return nil, "entity_agentmgr(" .. g_type .. ") is not running on this node"
    end
    local list = skynet.call(mgr, "lua", "migration_list")
    local out = {}
    local skipped = 0
    for _, entity in ipairs(list or {}) do
        if entity.conn_id and entity.persistent and not entity.busy then
            out[#out + 1] = entity
        else
            skipped = skipped + 1
        end
    end
    log.info("migration candidates", "type", g_type, "ready", #out, "skipped", skipped)
    return out
end

-- 目标节点：先看 HRW 指向谁；指回自己（成员视图还没更新）就从服务发现里另选一个。
-- 停服期间本节点仍然注册着，所以后一种情况是常态而不是异常
local function pick_target(entity)
    local node = types.calc_node(g_type, entity.id)
    if node and node ~= self_node() then
        return node
    end
    local ok, state = pcall(cluster_discovery.state, "entity:" .. g_type)
    if not ok or type(state) ~= "table" then
        return nil, "cluster discovery unavailable"
    end
    for _, candidate in ipairs(state.nodes or {}) do
        if candidate ~= self_node() then
            return candidate
        end
    end
    return nil, "no other node serves " .. g_type
end

function M.quiesce(entity)
    local ok, reason = call_agent(self_node(), entity.id, "migration_quiesce", entity.id)
    if not ok then
        return nil, tostring(reason)
    end
    entity._quiesced = true
    return true
end

function M.freeze(entity, barrier_id)
    if not entity.owner_epoch then
        return nil, "entity has no owner epoch"
    end
    local info, err = call_gate(entity.conn_id, "freeze_owner", entity.conn_id, entity.owner_epoch, barrier_id)
    if not info then
        return nil, tostring(err)
    end
    return true
end

function M.export(entity, barrier_id)
    -- 目标 epoch 必须严格前进：网关用严格大于来拒绝旧 owner 的迟到下行
    local target_epoch = (entity.owner_epoch or 1) + 1
    -- session_export 是 CMD 命令，第一参数必须是 entity_id（与其余 migration_* 一致）。
    -- 少了它会把 barrier_id 当成实体 ID，命令存在也拿不到快照。
    local ok, snapshot, err = call_agent(self_node(), entity.id, "session_export", entity.id, barrier_id, target_epoch)
    if not ok then
        return nil, tostring(snapshot)
    end
    if type(snapshot) ~= "table" then
        -- entity_call 把 handler 的 nil, err 原样透传在第二、三个返回值上
        return nil, tostring(err or "no snapshot")
    end
    return snapshot
end

-- TRANSFER：先把源端的锁交出来，再把快照送到目标暂存。
-- 顺序不能反：目标在 handoff 里要抢这把锁，源端不放它永远抢不到
function M.transfer(entity, snapshot)
    local released, rerr = call_agent(self_node(), entity.id, "migration_release", entity.id)
    if not released then
        return nil, "release failed: " .. tostring(rerr)
    end
    entity._released = true

    local target, terr = pick_target(entity)
    if not target then
        -- 锁已经放了，但快照送不出去：只能让客户端重登。这个日志是运维定位的锚点
        log.error("migration has no target after release", "id", tostring(entity.id), "err", tostring(terr))
        return nil, terr
    end
    local staged, serr = call_agent(target, entity.id, "migration_stage", entity.id, snapshot)
    if not staged then
        log.error("migration snapshot was not accepted", "id", tostring(entity.id), "target", target, "err", serr)
        return nil, "stage failed: " .. tostring(serr)
    end
    entity._target = target
    return true
end

function M.handoff(entity)
    if not entity._target then
        return nil, "no target was chosen"
    end
    local ok, reason = call_agent(entity._target, entity.id, "migration_commit", entity.id)
    if not ok then
        return nil, tostring(reason)
    end
    return true
end

function M.activate(entity)
    if not entity._target then
        return nil, "no target was chosen"
    end
    local ok, reason = call_agent(entity._target, entity.id, "session_attach", entity.id, entity.conn_id)
    if not ok then
        return nil, tostring(reason)
    end
    return true
end

-- 降级：还没释放锁的实体撤销冻结，留在本节点继续服务；
-- 已经释放的实体只能让客户端重登——而且要**主动踢**。源端已经没有 owner 了，
-- 网关还会把上行转给一个不存在的服务；不踢的话客户端会对着空气重试到空闲超时。
function M.fallback(entity, reason)
    if entity._quiesced and not entity._released then
        local ok, revoked, err = pcall(call_agent, self_node(), entity.id, "migration_unquiesce", entity.id, reason)
        if not ok then
            log.error("migration unquiesce raised", "id", tostring(entity.id), "err", tostring(revoked))
        elseif not revoked then
            log.error("migration unquiesce refused", "id", tostring(entity.id), "err", tostring(err))
        end
    elseif entity._released and entity.conn_id then
        -- 网关的 kick 不返回结果：调用没抛错就算发出去了，不能拿返回值判断连接是否还在
        local called, raised = pcall(call_gate, entity.conn_id, "kick", entity.conn_id)
        if not called then
            log.error(
                "migration fallback could not kick the client",
                "id",
                tostring(entity.id),
                "err",
                tostring(raised)
            )
        end
    end
    log.warn(
        "entity migration fell back to reconnect",
        "id",
        tostring(entity.id),
        "reason",
        tostring(reason),
        "released",
        entity._released == true
    )
end

return M
