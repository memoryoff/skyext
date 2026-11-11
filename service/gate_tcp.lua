-- 裸 TCP 网关：原生客户端连接的落点，只管连接，不持有玩法状态。
-- 浏览器和小程序走 service/gate_ws.lua，两者对外接口一致，差别只在传输层。
--
-- 每条连接在 accept 时生成 ConnectionIdentity v1（`conn_id`），会话表以它为主键：
--   * 还没绑定：包交给登录服务（conf.login），由它完成鉴权并把会话绑到实体上；
--   * 绑定之后：包原样转发给实体所在的节点（同节点 skynet.send，跨节点 cluster.send），
--     不解码协议，协议热更不用动网关。同一个会话固定发往一个 owner，消息天然保序。
-- 实体侧通过 bind / push / kick 操作会话（见 skyext.entity.session）。
-- 裸 fd 只在网关内部读写 socket：fd 会跨网关重复，关闭后还会被复用，不能当全局身份。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local gateserver = require "snax.gateserver"
local netpack = require "skynet.netpack"
local socketdriver = require "skynet.socketdriver"
local config = require "skyext.config"
local connection_id = require "skyext.connection_id"
local gate_owner = require "skyext.gate_owner"
local node_shutdown_api = require "skyext.node_shutdown_api"
local log = require "skyext.log"

-- 注册名。登录服务同时服务于两个网关，必须知道一条未绑定连接是从哪个网关来的，
-- 否则踢人会踢错进程。
local GATE_NAME = ".gate_tcp"

local g_login
local g_sessions = {} -- conn_id -> session
local g_by_fd = {} -- fd -> conn_id
local g_boot_id
local g_seq = 0
-- 迟到旧 epoch 的下行/绑定计数：迁移期间应当有少量，持续增长说明有 owner 没换 epoch
local g_stale_pushes = 0
local g_stale_binds = 0

local g_self_node
local function self_node()
    if not g_self_node then
        g_self_node = assert(config.get("cluster_node_name"), "cluster_node_name is not configured")
    end
    return g_self_node
end

local function send_owner(session, cmd, ...)
    if session.owner_node == self_node() then
        skynet.send(session.owner_service, "lua", cmd, ...)
        return
    end
    -- 目标节点不可达时 cluster.send 会抛错：这个包丢了，客户端超时后会重试或重连，
    -- 不能让整个网关跟着出错
    local ok, err = pcall(cluster.send, session.owner_node, session.owner_service, cmd, ...)
    if not ok then
        log.warn("session forward failed", "conn", session.conn_id, "owner", session.owner_node, "cmd", cmd, "err", err)
    end
end

local handler = { embed = true }

function handler.open(_, conf)
    g_login = assert(conf.login, "gate_tcp needs conf.login")
    -- 没有可信随机数就没有连接身份。拒绝启动，而不是退化成可预测的序号
    local boot, boot_err = connection_id.new_boot_id()
    if not boot then
        error("gate_tcp cannot generate connection ids: " .. tostring(boot_err))
    end
    g_boot_id = boot
    log.info("tcp gate listening", "address", conf.address, "port", conf.port)
end

function handler.connect(fd, addr)
    g_seq = g_seq + 1
    local conn_id, err = connection_id.new(self_node(), GATE_NAME, g_boot_id, g_seq)
    if not conn_id then
        -- 生成不出身份就不能让这条连接进入系统：直接关掉，别让它带着空身份往下走
        log.error("cannot generate a connection id", "fd", fd, "err", err)
        gateserver.closeclient(fd)
        return
    end
    g_sessions[conn_id] = { conn_id = conn_id, fd = fd, addr = addr }
    g_by_fd[fd] = conn_id
    gateserver.openclient(fd)
    skynet.send(g_login, "lua", "open", conn_id, addr, GATE_NAME)
end

function handler.message(fd, msg, sz)
    -- netpack.tostring 复制一份并释放原始缓冲
    local data = netpack.tostring(msg, sz)
    local conn_id = g_by_fd[fd]
    local session = conn_id and g_sessions[conn_id]
    if not session then
        return
    end
    if session.owner_node then
        send_owner(session, "client_msg", self_node(), conn_id, data)
    else
        skynet.send(g_login, "lua", "client_msg", conn_id, data)
    end
end

local function close_session(conn_id)
    local session = g_sessions[conn_id]
    if not session then
        return
    end
    g_sessions[conn_id] = nil
    if g_by_fd[session.fd] == conn_id then
        g_by_fd[session.fd] = nil
    end
    if session.owner_node then
        send_owner(session, "session_closed", self_node(), conn_id)
    else
        skynet.send(g_login, "lua", "disconnect", conn_id)
    end
end

function handler.disconnect(fd)
    local conn_id = g_by_fd[fd]
    if conn_id then
        close_session(conn_id)
    end
end

function handler.error(fd, msg)
    log.warn("session socket error", "fd", fd, "msg", msg)
    local conn_id = g_by_fd[fd]
    if conn_id then
        close_session(conn_id)
    end
end

function handler.warning(fd, size)
    log.warn("session send buffer is piling up", "fd", fd, "size", size)
end

local CMD = {}

-- 会话绑定到实体：之后的包原样转发给 owner。会话已经断开时返回 false。
-- owner_epoch 是网关内部的所有权代际，旧 epoch 的绑定一律拒绝
function CMD.bind(conn_id, owner_node, owner_service, owner_epoch)
    local session = g_sessions[conn_id]
    if not session then
        return false
    end
    if owner_epoch == nil then
        session.owner_node, session.owner_service = owner_node, owner_service
        return true
    end
    local ok, err = gate_owner.bind(session, owner_epoch, owner_node, owner_service)
    if not ok then
        log.warn("tcp bind rejected", "conn", conn_id, "epoch", owner_epoch, "err", err)
        g_stale_binds = g_stale_binds + 1
        return false
    end
    return true
end

-- 发给客户端一个已经编码好的包（回包或推送）。
-- 屏障之后或 epoch 不匹配的包直接丢弃：那可能是上一个 owner 的迟到写
function CMD.push(conn_id, pack, owner_epoch)
    local session = g_sessions[conn_id]
    if not session then
        return
    end
    local allowed = gate_owner.push_allowed(session, owner_epoch)
    if not allowed then
        g_stale_pushes = g_stale_pushes + 1
        return
    end
    session.pushed = (session.pushed or 0) + 1
    local data, sz = netpack.pack(pack)
    socketdriver.send(session.fd, data, sz)
end

-- 迁移屏障：从这一刻起丢弃 epoch <= owner_epoch 的下行，返回已写出的包数
function CMD.freeze_owner(conn_id, owner_epoch, barrier_id)
    local session = g_sessions[conn_id]
    if not session then
        return nil, "no session"
    end
    local ok, info = gate_owner.freeze(session, owner_epoch, barrier_id)
    if not ok then
        return nil, info
    end
    return info
end

-- 解除屏障并把所有权交给新 epoch
function CMD.resume_owner(conn_id, new_epoch, owner_node, owner_service)
    local session = g_sessions[conn_id]
    if not session then
        return false
    end
    local ok, err = gate_owner.resume(session, new_epoch, owner_node, owner_service)
    if not ok then
        log.warn("tcp resume_owner rejected", "conn", conn_id, "epoch", new_epoch, "err", err)
        return false
    end
    return true
end

-- 断开连接。断开回调照常走：未绑定的通知登录服务，已绑定的通知 owner
function CMD.kick(conn_id)
    local session = g_sessions[conn_id]
    if session then
        gateserver.closeclient(session.fd)
    end
end

function CMD.count()
    local n = 0
    for _ in pairs(g_sessions) do
        n = n + 1
    end
    return n
end

-- 只读观测：owner_epoch 与屏障状态
function CMD.owner_state(conn_id)
    local session = g_sessions[conn_id]
    if not session then
        return nil
    end
    return gate_owner.state(session)
end

-- 只读观测：迟到包/绑定的累计次数
function CMD.stats()
    return { stale_pushes = g_stale_pushes, stale_binds = g_stale_binds }
end

-- 只读观测：fd 当前对应的 conn_id（测试需要，生产调用方不应依赖 fd）
function CMD.conn_id(fd)
    return g_by_fd[fd]
end

function handler.command(cmd, _, ...)
    local f = CMD[cmd]
    if not f then
        error(string.format("unknown gate_tcp command: %s", tostring(cmd)))
    end
    return f(...)
end

skynet.start(function()
    gateserver.start(handler)
    -- 实体侧按这个名字找本节点的网关（跨节点时 cluster.send(node, ".gate_tcp", ...)）
    skynet.register(GATE_NAME)
    -- 停服第一步：关掉监听端口，不再接新连接（gateserver 内置的 close）
    skynet.fork(function()
        node_shutdown_api.add_hook("stop_accepting", "close")
    end)
end)
