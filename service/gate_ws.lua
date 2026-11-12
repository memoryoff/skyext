-- WebSocket 网关：浏览器和小程序连接的落点。对外接口和 service/gate_tcp.lua 完全一致
-- （bind / push / kick / count，上行发 client_msg 和 session_closed），
-- 差别只在传输层，所以实体侧不需要知道客户端走的是哪一种。
--
-- **为什么不能和 gate_tcp 同一个服务**：snax.gateserver 注册 PTYPE_SOCKET 用的是
-- netpack.filter，而 http.websocket 依赖的 skynet.socket 也注册 PTYPE_SOCKET，
-- skynet.register_protocol 开头就 assert 没人占过。同一个服务里二选一，必须分开。
-- 分开也更合适：裸 TCP 那边的长度前缀是 C 层解的，原生客户端要的就是这个加速，
-- 不该为了省一个端口把它换成 Lua 手工解析。
--
-- **连接身份**：每条连接在 accept 时生成 ConnectionIdentity v1（`conn_id`），它带着
-- gate 节点、gate 服务名、boot_id 与进程内序号。登录、实体、会话层只认 conn_id；
-- 裸 fd 只在网关内部用来读写 socket——fd 会跨网关重复，关闭后还会被复用。
--
-- 连接生命周期（P02）：
--   RESERVED → HANDSHAKING → REGISTERING → ACTIVE → CLOSING → CLOSED
-- 配额在 accept 回调里**无 yield** 地预占，失败立即 close_fd；fork 之后才做 WS 握手。
-- 握手成功后 `handler.handshake` 同步向登录服务做一次**可确认**的 open（带超时），
-- 确认之前 websocket.accept 还没进入读帧循环，所以不存在"未 ACTIVE 就丢帧"的窗口。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local connection_id = require "skyext.connection_id"
local gate_owner = require "skyext.gate_owner"
local node_shutdown_api = require "skyext.node_shutdown_api"
local log = require "skyext.log"
local metrics = require "skyext.metrics"

-- 注册名。登录服务同时服务于两个网关，必须知道一条未绑定连接是从哪个网关来的，
-- 否则踢人会踢错进程。
local GATE_NAME = ".gate_ws"

local STATE = {
    RESERVED = "RESERVED",
    HANDSHAKING = "HANDSHAKING",
    REGISTERING = "REGISTERING",
    ACTIVE = "ACTIVE",
    CLOSING = "CLOSING",
    CLOSED = "CLOSED",
}

local g_login
local g_listen_fd
local g_maxclient
local g_count = 0
local g_sessions = {} -- conn_id -> session
local g_by_fd = {} -- fd -> conn_id
local g_boot_id
local g_seq = 0
local g_handshake_timeout_ms = 5000
-- 迟到旧 epoch 的下行/绑定计数：迁移期间应当有少量，持续增长说明有 owner 没换 epoch
local g_stale_pushes = 0
local g_stale_binds = 0
-- 迁移屏障期间被丢弃的上行数：屏障窗口应该很短，持续增长说明会话卡在 FROZEN
local g_frozen_upstreams = 0
local m_stale_pushes = metrics.counter(
    "skyext_gate_stale_pushes_total",
    "Downlink packets dropped because of a stale owner epoch",
    { "gate" }
)
local m_stale_binds =
    metrics.counter("skyext_gate_stale_binds_total", "Owner bind RPCs rejected because of a stale epoch", { "gate" })
local m_frozen_upstreams = metrics.counter(
    "skyext_gate_frozen_upstreams_total",
    "Upstream packets dropped while the session is frozen",
    { "gate" }
)
local m_connections = metrics.gauge("skyext_gate_connections", "Live connections on this gate", { "gate" })
local m_handshake_inflight = metrics.gauge(
    "skyext_ws_handshake_inflight",
    "WS connections waiting for the synchronous login registration",
    { "gate" }
)

-- 握手 inflight：从 handshake 回调进入直到注册确认/失败/连接关闭。
-- 计数挂在 session 上，close_session 与 handshake 都可能收尾，用标志防重复减
local g_handshake_inflight = 0
local function begin_handshake(session)
    session.handshake_counted = true
    g_handshake_inflight = g_handshake_inflight + 1
    m_handshake_inflight:set(g_handshake_inflight, { gate = "ws" })
end

local function end_handshake(session)
    if not session or not session.handshake_counted then
        return
    end
    session.handshake_counted = false
    g_handshake_inflight = math.max(0, g_handshake_inflight - 1)
    m_handshake_inflight:set(g_handshake_inflight, { gate = "ws" })
end

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

local close_session

-- 配额预占。**不许 yield**：这个函数跑在 socket 分发协程里，阻塞它就收不到新 accept。
local function reserve(fd, addr)
    if g_count >= g_maxclient then
        return nil
    end
    -- fd 被复用：旧连接可能还有残留会话（关闭消息还没跑完），先结算掉再挂新的，
    -- 否则旧会话永远不会被关闭，g_count 也会漏减
    local stale = g_by_fd[fd]
    if stale then
        close_session(stale, "fd reused")
    end
    g_seq = g_seq + 1
    local conn_id, err = connection_id.new(self_node(), GATE_NAME, g_boot_id, g_seq)
    if not conn_id then
        log.error("cannot generate a connection id", "fd", fd, "err", err)
        return nil
    end
    local session = {
        conn_id = conn_id,
        fd = fd,
        addr = addr,
        state = STATE.RESERVED,
        token = g_seq,
    }
    g_sessions[conn_id] = session
    g_by_fd[fd] = conn_id
    g_count = g_count + 1
    m_connections:set(g_count, { gate = "ws" })
    return session
end

-- 幂等关闭：handler.close / handler.error / 注册失败 / serve 收尾 / 停服都会走到这里。
-- 只有第一次调用会通知对端（登录服务或 owner），之后都是 no-op。
close_session = function(conn_id, reason)
    local session = g_sessions[conn_id]
    if not session then
        return false
    end
    g_sessions[conn_id] = nil
    if g_by_fd[session.fd] == conn_id then
        g_by_fd[session.fd] = nil
    end
    -- 等待注册确认期间连接被关：inflight 必须在这里归零
    end_handshake(session)
    session.state = STATE.CLOSED
    g_count = g_count - 1
    m_connections:set(g_count, { gate = "ws" })
    if session.owner_node then
        send_owner(session, "session_closed", self_node(), conn_id)
    else
        skynet.send(g_login, "lua", "disconnect", conn_id)
    end
    if reason then
        log.info("ws session closed", "conn", conn_id, "reason", reason)
    end
    return true
end

-- 同步 RPC + 受控超时。用 fork 跑真正的 skynet.call，超时只唤醒等待方，
-- 迟到的结果由 on_late_ack 补偿（登录端可能已经登记了这条连接）。
local function call_with_timeout(addr, timeout_ms, on_late_ack, ...)
    local co = coroutine.running()
    -- 内层函数不是 vararg，必须先把参数收下来
    local args = table.pack(...)
    local done, timed_out, call_ok, result = false, false, nil, nil
    skynet.fork(function()
        local pok, pret = pcall(skynet.call, addr, "lua", table.unpack(args, 1, args.n))
        if done then
            if pok and on_late_ack then
                on_late_ack()
            end
            return
        end
        done, call_ok, result = true, pok, pret
        skynet.wakeup(co)
    end)
    -- skynet.timeout 的单位是 1/100 秒；配置用毫秒更直观
    local centiseconds = math.max(1, timeout_ms // 10)
    skynet.timeout(centiseconds, function()
        if done then
            return
        end
        done, timed_out = true, true
        skynet.wakeup(co)
    end)
    skynet.wait(co)
    if timed_out then
        return nil, "timeout"
    end
    if not call_ok then
        return nil, result
    end
    return result
end

-- websocket.accept 的回调，第一个参数都是 fd
local handler = {}

-- 握手成功、进入读帧循环之前调用。这里同步等登录服务确认，确认前不会读任何客户端帧：
-- 客户端在这段时间发的字节留在 socket 缓冲里，由 TCP 窗口做天然背压。
function handler.handshake(conn_id, fd)
    local session = g_sessions[conn_id]
    if not session or session.state ~= STATE.RESERVED then
        return
    end
    session.state = STATE.HANDSHAKING
    session.state = STATE.REGISTERING
    begin_handshake(session)

    local ok, err = call_with_timeout(g_login, g_handshake_timeout_ms, function()
        -- 迟到的成功：登录端可能已经为这个 conn_id 建了客户端记录，补一次 disconnect。
        -- conn_id 在 boot 内不复用，所以不存在 fd 复用误踢的问题
        if not g_sessions[conn_id] then
            skynet.send(g_login, "lua", "disconnect", conn_id)
        end
    end, "open", conn_id, session.addr, GATE_NAME)

    if g_sessions[conn_id] ~= session then
        -- 等待期间连接已经断开，close_session 已经通知过登录端并归零 inflight
        end_handshake(session)
        return
    end
    -- 必须拿到明确的 true 才算注册成功：nil / false 都可能是登录端拒绝或没有实现确认
    if ok ~= true then
        log.warn("ws registration failed", "conn", conn_id, "err", err or tostring(ok))
        session.state = STATE.CLOSING
        pcall(websocket.close, fd, 1011, "register failed")
        close_session(conn_id, "register failed")
        end_handshake(session)
        return
    end
    end_handshake(session)
    session.state = STATE.ACTIVE
    log.info("ws session active", "conn", conn_id, "addr", session.addr)
end

local function forward(session, msg)
    if not gate_owner.upstream_allowed(session) then
        -- 迁移屏障期间的上行直接丢弃：这个 owner 已经把会话交出去了，
        -- 再转给它就是让它在一个无权落库的实体上执行业务
        g_frozen_upstreams = g_frozen_upstreams + 1
        m_frozen_upstreams:inc(1, { gate = "ws" })
        return
    end
    if session.owner_node then
        send_owner(session, "client_msg", self_node(), session.conn_id, msg)
    else
        skynet.send(g_login, "lua", "client_msg", session.conn_id, msg)
    end
end

function handler.message(conn_id, fd, msg, msg_type)
    local session = g_sessions[conn_id]
    if not session then
        return
    end
    -- 协议是二进制 sproto。文本帧多半是接错了端口或者客户端用了 JSON，直接断开比
    -- 让它在后面某个解码器里炸掉清楚
    if msg_type ~= "binary" then
        log.warn("ws client sent a non-binary frame", "conn", conn_id, "type", msg_type)
        websocket.close(fd, 1003, "binary only")
        return
    end
    -- 读帧循环只在 handshake 返回之后才开始；走到这里还不是 ACTIVE 说明状态机被绕过了，
    -- 宁可断开也不能把包转给尚未确认的登录/实体
    if session.state ~= STATE.ACTIVE then
        log.warn("ws frame before registration completed", "conn", conn_id, "state", session.state)
        websocket.close(fd, 1011, "not active")
        return
    end
    forward(session, msg)
end

function handler.close(conn_id)
    close_session(conn_id, "closed")
end

function handler.error(conn_id, fd, err)
    log.warn("ws session error", "conn", conn_id, "fd", fd, "err", err)
    close_session(conn_id, "error")
end

-- 这个回调拿到的第一个参数是 ws 对象而不是 fd（websocket.lua 的历史遗留）
function handler.warning(ws, size)
    log.warn("ws send buffer is piling up", "fd", ws.id, "size", size)
end

-- 每条连接的 handler 固化自己的 conn_id。**不能按 fd 反查**：关闭消息和下一次
-- accept 是两条独立消息，新连接可能已经复用 fd 并把 g_by_fd 指向新 conn_id，
-- 旧协程恢复后按 fd 查就会关掉别人的连接、还把自己的会话漏在表里。
local function make_handler(conn_id, fd)
    return {
        handshake = function()
            handler.handshake(conn_id, fd)
        end,
        message = function(_, msg, msg_type)
            handler.message(conn_id, fd, msg, msg_type)
        end,
        close = function()
            handler.close(conn_id)
        end,
        error = function(_, err)
            handler.error(conn_id, fd, err)
        end,
        warning = handler.warning,
    }
end

local function serve(fd, addr, protocol, conn_id)
    local ok, err = pcall(websocket.accept, fd, make_handler(conn_id, fd), protocol, addr)
    if not ok then
        -- 握手阶段就失败了（不是 WS 请求、TLS 握手不过）。这时 handler.close 不会被调用
        log.warn("ws handshake failed", "conn", conn_id, "fd", fd, "addr", addr, "err", err)
    end
    close_session(conn_id, "serve exit")
end

local CMD = {}

function CMD.open(conf)
    g_login = assert(conf.login, "gate_ws needs conf.login")
    g_maxclient = conf.maxclient or 1024
    g_handshake_timeout_ms = conf.handshake_timeout_ms or 5000
    -- 没有可信随机数就没有连接身份。拒绝启动，而不是退化成可预测的序号
    local boot, boot_err = connection_id.new_boot_id()
    if not boot then
        error("gate_ws cannot generate connection ids: " .. tostring(boot_err))
    end
    g_boot_id = boot
    local protocol = conf.protocol or "ws"
    assert(protocol == "ws" or protocol == "wss", "ws_protocol must be ws or wss")
    if protocol == "wss" then
        -- TLS 握手在 ltls 里做，没开的话第一个 wss 连接才会炸，太晚了
        -- bootstrap 比的也是字符串 "true"
        assert(skynet.getenv("enablessl") == "true", "wss needs enablessl = true in the node config")
        -- websocket.lua 只认 skynet env 里的证书路径，没有别的入口。env 里已经有值
        -- （直接写在节点配置里）时以它为准：skynet.setenv 不允许覆盖已存在的键
        if not skynet.getenv("certfile") then
            skynet.setenv("certfile", assert(conf.certfile, "wss needs ws_certfile"))
        end
        if not skynet.getenv("keyfile") then
            skynet.setenv("keyfile", assert(conf.keyfile, "wss needs ws_keyfile"))
        end
    end

    local address = conf.address or "0.0.0.0"
    g_listen_fd = socket.listen(address, conf.port)
    socket.start(g_listen_fd, function(fd, addr)
        -- 预占必须在这个回调里完成：fork 之后再计数，突发连接会一起通过上限检查
        local session = reserve(fd, addr)
        if not session then
            log.warn("ws gate is full or cannot identify the connection, dropping it", "addr", addr)
            socket.close_fd(fd)
            return
        end
        -- 这个回调跑在 socket 消息的分发协程里，阻塞它就收不到后续的 accept
        skynet.fork(serve, fd, addr, protocol, session.conn_id)
    end)
    log.info("ws gate listening", "address", address, "port", conf.port, "protocol", protocol)
end

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
        log.warn("ws bind rejected", "conn", conn_id, "epoch", owner_epoch, "err", err)
        g_stale_binds = g_stale_binds + 1
        m_stale_binds:inc(1, { gate = "ws" })
        return false
    end
    return true
end

-- 发给客户端一个已经编码好的包（回包或推送）。WS 帧自带边界，不加长度头。
-- 屏障之后或 epoch 不匹配的包直接丢弃：那可能是上一个 owner 的迟到写
function CMD.push(conn_id, pack, owner_epoch)
    local session = g_sessions[conn_id]
    if not session then
        return
    end
    local allowed = gate_owner.push_allowed(session, owner_epoch)
    if not allowed then
        g_stale_pushes = g_stale_pushes + 1
        m_stale_pushes:inc(1, { gate = "ws" })
        return
    end
    session.pushed = (session.pushed or 0) + 1
    -- 写可能撞上连接正在关闭：这条连接的协程会走正常的断开流程，这里不能连累调用方
    local ok, err = pcall(websocket.write, session.fd, pack, "binary")
    if not ok then
        log.warn("ws push failed", "conn", conn_id, "err", err)
    end
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
        log.warn("ws resume_owner rejected", "conn", conn_id, "epoch", new_epoch, "err", err)
        return false
    end
    return true
end

-- 断开连接。断开回调照常走：未绑定的通知登录服务，已绑定的通知 owner
function CMD.kick(conn_id)
    local session = g_sessions[conn_id]
    if session then
        websocket.close(session.fd, 1000, "kicked")
    end
end

function CMD.count()
    return g_count
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
    return { stale_pushes = g_stale_pushes, stale_binds = g_stale_binds, frozen_upstreams = g_frozen_upstreams }
end

-- 只读观测：测试与排障用，不参与转发逻辑
function CMD.state(conn_id)
    local session = g_sessions[conn_id]
    return session and session.state or STATE.CLOSED
end

-- 只读观测：fd 当前对应的 conn_id（测试需要，生产调用方不应依赖 fd）
function CMD.conn_id(fd)
    return g_by_fd[fd]
end

-- 停服第一步：关掉监听端口，不再接新连接。已经建立的连接继续服务到实体卸载
function CMD.close()
    if g_listen_fd then
        socket.close(g_listen_fd)
        g_listen_fd = nil
        log.info("ws gate stopped accepting")
    end
end

skynet.start(function()
    cmd_api.dispatch(CMD)
    -- 实体侧按这个名字找本节点的网关（跨节点时 cluster.send(node, ".gate_ws", ...)）
    skynet.register(GATE_NAME)
    skynet.fork(function()
        node_shutdown_api.add_hook("stop_accepting", "close")
    end)
end)
