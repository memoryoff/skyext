-- WebSocket 网关：浏览器和小程序连接的落点。对外接口和 service/gate_tcp.lua 完全一致
-- （open / bind / push / kick / count，上行发 client_msg 和 session_closed），
-- 差别只在传输层，所以实体侧不需要知道客户端走的是哪一种。
--
-- **为什么不能和 gate_tcp 同一个服务**：snax.gateserver 注册 PTYPE_SOCKET 用的是
-- netpack.filter，而 http.websocket 依赖的 skynet.socket 也注册 PTYPE_SOCKET，
-- skynet.register_protocol 开头就 assert 没人占过。同一个服务里二选一，必须分开。
-- 分开也更合适：裸 TCP 那边的长度前缀是 C 层解的，原生客户端要的就是这个加速，
-- 不该为了省一个端口把它换成 Lua 手工解析。
--
-- **为什么是单个服务而不是 watchdog + agent 池**：实体给客户端发包时按 gate_service
-- 这个注册名直接找到网关（见 skyext.entity.session），单服务意味着下行一跳到位。
-- 拆成池子就得在 watchdog 上多转一次，而下行是热路径。WS 帧解析确实落在 Lua 里，
-- 单服务有吞吐上限，横向扩的单位是节点——这和 gate_tcp 的扩容方式一致。
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
local node_shutdown_api = require "skyext.node_shutdown_api"
local log = require "skyext.log"

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
local g_sessions = {}
local g_token = 0
local g_handshake_timeout_ms = 5000

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
        log.warn("session forward failed", "fd", session.fd, "owner", session.owner_node, "cmd", cmd, "err", err)
    end
end

-- 配额预占。**不许 yield**：这个函数跑在 socket 分发协程里，阻塞它就收不到新 accept。
local function reserve(fd, addr)
    if g_count >= g_maxclient then
        return nil
    end
    g_token = g_token + 1
    local session = {
        fd = fd,
        addr = addr,
        state = STATE.RESERVED,
        token = g_token,
    }
    g_sessions[fd] = session
    g_count = g_count + 1
    return session
end

-- 幂等关闭：handler.close / handler.error / 注册失败 / serve 收尾 / 停服都会走到这里。
-- 只有第一次调用会通知对端（登录服务或 owner），之后都是 no-op。
local function close_session(fd, reason)
    local session = g_sessions[fd]
    if not session then
        return false
    end
    g_sessions[fd] = nil
    session.state = STATE.CLOSED
    g_count = g_count - 1
    if session.owner_node then
        send_owner(session, "session_closed", self_node(), fd)
    else
        skynet.send(g_login, "lua", "disconnect", fd)
    end
    if reason then
        log.info("ws session closed", "fd", fd, "reason", reason)
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
function handler.handshake(fd)
    local session = g_sessions[fd]
    if not session or session.state ~= STATE.RESERVED then
        return
    end
    session.state = STATE.HANDSHAKING
    session.state = STATE.REGISTERING

    local token = session.token
    local ok, err = call_with_timeout(g_login, g_handshake_timeout_ms, function()
        -- 迟到的成功：登录端可能已经为这个 fd 建了客户端记录，补一次 disconnect。
        -- fd 已经被新连接复用时不能按 fd 补偿，否则会把新连接踢掉
        local current = g_sessions[fd]
        if not current then
            skynet.send(g_login, "lua", "disconnect", fd)
        elseif current.token ~= token then
            log.warn("late registration ack for a reused fd", "fd", fd)
        end
    end, "open", fd, session.addr, GATE_NAME)

    if g_sessions[fd] ~= session then
        -- 等待期间连接已经断开，close_session 已经通知过登录端
        return
    end
    -- 必须拿到明确的 true 才算注册成功：nil / false 都可能是登录端拒绝或没有实现确认
    if ok ~= true then
        log.warn("ws registration failed", "fd", fd, "err", err or tostring(ok))
        session.state = STATE.CLOSING
        pcall(websocket.close, fd, 1011, "register failed")
        close_session(fd, "register failed")
        return
    end
    session.state = STATE.ACTIVE
    log.info("ws session active", "fd", fd, "addr", session.addr)
end

local function forward(session, msg)
    if session.owner_node then
        send_owner(session, "client_msg", self_node(), session.fd, msg)
    else
        skynet.send(g_login, "lua", "client_msg", session.fd, msg)
    end
end

function handler.message(fd, msg, msg_type)
    local session = g_sessions[fd]
    if not session then
        return
    end
    -- 协议是二进制 sproto。文本帧多半是接错了端口或者客户端用了 JSON，直接断开比
    -- 让它在后面某个解码器里炸掉清楚
    if msg_type ~= "binary" then
        log.warn("ws client sent a non-binary frame", "fd", fd, "type", msg_type)
        websocket.close(fd, 1003, "binary only")
        return
    end
    -- 读帧循环只在 handshake 返回之后才开始；走到这里还不是 ACTIVE 说明状态机被绕过了，
    -- 宁可断开也不能把包转给尚未确认的登录/实体
    if session.state ~= STATE.ACTIVE then
        log.warn("ws frame before registration completed", "fd", fd, "state", session.state)
        websocket.close(fd, 1011, "not active")
        return
    end
    forward(session, msg)
end

function handler.close(fd)
    close_session(fd, "closed")
end

function handler.error(fd, err)
    log.warn("ws session error", "fd", fd, "err", err)
    close_session(fd, "error")
end

-- 这个回调拿到的第一个参数是 ws 对象而不是 fd（websocket.lua 的历史遗留）
function handler.warning(ws, size)
    log.warn("ws send buffer is piling up", "fd", ws.id, "size", size)
end

local function serve(fd, addr, protocol)
    local ok, err = pcall(websocket.accept, fd, handler, protocol, addr)
    if not ok then
        -- 握手阶段就失败了（不是 WS 请求、TLS 握手不过）。这时 handler.close 不会被调用
        log.warn("ws handshake failed", "fd", fd, "addr", addr, "err", err)
    end
    close_session(fd, "serve exit")
end

local CMD = {}

function CMD.open(conf)
    g_login = assert(conf.login, "gate_ws needs conf.login")
    g_maxclient = conf.maxclient or 1024
    g_handshake_timeout_ms = conf.handshake_timeout_ms or 5000
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
            log.warn("ws gate is full, dropping a new connection", "addr", addr, "maxclient", g_maxclient)
            socket.close_fd(fd)
            return
        end
        -- 这个回调跑在 socket 消息的分发协程里，阻塞它就收不到后续的 accept
        skynet.fork(serve, fd, addr, protocol)
    end)
    log.info("ws gate listening", "address", address, "port", conf.port, "protocol", protocol)
end

-- 会话绑定到实体：之后的包原样转发给 owner。会话已经断开时返回 false
function CMD.bind(fd, owner_node, owner_service)
    local session = g_sessions[fd]
    if not session then
        return false
    end
    session.owner_node, session.owner_service = owner_node, owner_service
    return true
end

-- 发给客户端一个已经编码好的包（回包或推送）。WS 帧自带边界，不加长度头
function CMD.push(fd, pack)
    if not g_sessions[fd] then
        return
    end
    -- 写可能撞上连接正在关闭：这条连接的协程会走正常的断开流程，这里不能连累调用方
    local ok, err = pcall(websocket.write, fd, pack, "binary")
    if not ok then
        log.warn("ws push failed", "fd", fd, "err", err)
    end
end

-- 断开连接。断开回调照常走：未绑定的通知登录服务，已绑定的通知 owner
function CMD.kick(fd)
    if g_sessions[fd] then
        websocket.close(fd, 1000, "kicked")
    end
end

function CMD.count()
    return g_count
end

-- 只读观测：测试与排障用，不参与转发逻辑
function CMD.state(fd)
    local session = g_sessions[fd]
    return session and session.state or STATE.CLOSED
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
