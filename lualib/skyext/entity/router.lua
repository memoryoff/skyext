local skynet = require "skynet"
local cluster = require "skynet.cluster"
local config = require "skyext.config"
local types = require "skyext.entity.types"

local M = {}

local g_self_node = nil

local function self_node()
    if not g_self_node then
        g_self_node = config.get("cluster_node_name")
    end
    return g_self_node
end

local function get_target(type_name, entity_id)
    local node = types.calc_node(type_name, entity_id)
    local idx = types.calc_agent_index(type_name, entity_id)
    local service_name = types.format_agent_service_name(type_name, idx)
    return node, service_name
end

-- 返回 true, handler 的返回值...，或 false, reason（实体不可用，handler 没有执行）。
-- handler 抛错、目标节点不可达时照常抛错
function M.call(type_name, entity_id, cmd, ...)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        return skynet.call(service_name, "lua", "entity_call", entity_id, cmd, ...)
    else
        return cluster.call(node, service_name, "entity_call", entity_id, cmd, ...)
    end
end

-- 只对**已经在内存里**的实体执行，绝不触发加载。
-- 用于广播、状态查询这类"实体不在就跳过"的路径：触发加载会让一个非关键调用
-- 抢锁、读库、甚至把别的节点上的实体 handoff 过来，代价和风险都不对等。
function M.call_loaded(type_name, entity_id, cmd, ...)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        return skynet.call(service_name, "lua", "entity_call_loaded", entity_id, cmd, ...)
    else
        return cluster.call(node, service_name, "entity_call_loaded", entity_id, cmd, ...)
    end
end

function M.send(type_name, entity_id, cmd, ...)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        skynet.send(service_name, "lua", "entity_send", entity_id, cmd, ...)
    else
        cluster.send(node, service_name, "entity_send", entity_id, cmd, ...)
    end
end

-- 只对已经在内存里的实体发消息；实体不在就丢弃，不加载。
-- 和 M.send 一样是单向投递：不等 handler 返回，也不能从实体 handler 里对同一实体
-- 调用后等待自己（call_loaded 才有返回值，也只用于不会重入的调用方）
function M.send_loaded(type_name, entity_id, cmd, ...)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        skynet.send(service_name, "lua", "entity_send_loaded", entity_id, cmd, ...)
    else
        cluster.send(node, service_name, "entity_send_loaded", entity_id, cmd, ...)
    end
end

-- 唤醒目标实体去读取自己的 pending 消息。
-- 返回是否成功投出唤醒；失败不代表消息丢了——消息已经落库，
-- 实体下次加载或重试定时器会补上。
function M.poke_reliable(type_name, entity_id)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        return (pcall(skynet.send, service_name, "lua", "__deliver_reliable", entity_id))
    end
    return (pcall(cluster.send, node, service_name, "__deliver_reliable", entity_id))
end

-- 把网关上的会话（conn_id）绑到实体上，登录服务调用。实体加载在哪个节点由实体系统
-- 决定，网关和实体不必在同一个节点。conn_id 里已经带着 gate_node/gate_service，
-- 不再单独传裸 fd：fd 跨网关会重复，关闭后还会被复用。
-- session_mode 是客户端协商的下行模式（0=LEGACY/1=V2），随 bind 一起交给实体进程，
-- 由 session_io 终身持有。返回错误码、续接凭据、session_epoch、模式
function M.bind_session(type_name, entity_id, conn_id, session_mode)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        return skynet.call(service_name, "lua", "bind_session", entity_id, conn_id, session_mode)
    end
    return cluster.call(node, service_name, "bind_session", entity_id, conn_id, session_mode)
end

-- 断线后把一条新连接接回原来的会话。**只作用于已经在内存里的实体**：续接不验 token、
-- 不查库，要是它能触发实体加载，拿一串 rid 就能让集群把任意玩家的实体从库里捞起来、
-- 抢锁、甚至触发 handoff，是现成的放大攻击面。
-- session_mode/session_epoch 是客户端声明的一致性证据，实体侧不匹配就拒绝续接。
-- 返回错误码、轮换后的新凭据、服务端已发出的包数、session_epoch、模式
function M.resume_session(type_name, entity_id, conn_id, nonce, recv, session_mode, session_epoch)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        return skynet.call(
            service_name,
            "lua",
            "resume_session",
            entity_id,
            conn_id,
            nonce,
            recv,
            session_mode,
            session_epoch
        )
    end
    return cluster.call(
        node,
        service_name,
        "resume_session",
        entity_id,
        conn_id,
        nonce,
        recv,
        session_mode,
        session_epoch
    )
end

-- 作用域实体的便捷入口：value 是作用域取值（game 名、zone 名、"global"），
-- 实体 ID 由 types.scoped_id 算出
function M.scoped_call(type_name, value, cmd, ...)
    return M.call(type_name, types.scoped_id(type_name, value), cmd, ...)
end

function M.scoped_send(type_name, value, cmd, ...)
    return M.send(type_name, types.scoped_id(type_name, value), cmd, ...)
end

function M.reliable_send(type_name, entity_id, cmd, args)
    local reliable_msg = require "skyext.entity.reliable_msg"
    local msg_id = reliable_msg.save(type_name, entity_id, cmd, args)

    if not M.poke_reliable(type_name, entity_id) then
        local log = require "skyext.log"
        log.warn(
            "reliable_send immediate delivery failed, will retry on load",
            "type",
            type_name,
            "id",
            entity_id,
            "cmd",
            cmd,
            "msg_id",
            msg_id
        )
    end
    return msg_id
end

return M
