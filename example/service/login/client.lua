local skynet = require "skynet"
local timer = require "skyext.timer"
local config = require "skyext.config"
local log = require "skyext.log"

local M = {}

-- 已连接但还没绑定到实体的客户端，conn_id -> { conn_id, addr, gate }。
-- gate 是来源网关的注册名（.gate_tcp / .gate_ws）：两个网关共用一个登录服务，
-- 踢人必须踢回原来那个网关。
-- 登录服务只负责握手；登录成功后会话移交给实体，客户端从这里移除（见 M.unbind）。
local g_clients = {}

-- conn_id -> 来源网关的注册名。比 g_clients 活得久：登录成功时 g_clients 里的记录当场就删了，
-- 但那次登录的响应还没发出去，发它还要用网关
local g_gates = {}

-- 已关闭 conn_id 的短期墓碑。断开与"open 晚于 disconnect"是真实存在的竞态：
-- 没有墓碑，迟到的 open 会给一条已经关闭的连接重建登录态，留下孤儿会话。
-- 只用墙钟秒 + 容量上限，惰性清理，不额外起定时器
local g_tombstones = {} -- conn_id -> 过期时间（os.time 秒）
local g_tombstone_order = {}
local TOMBSTONE_TTL = 60
local TOMBSTONE_MAX = 4096

local function is_tombstoned(conn_id, now)
    local expire_at = g_tombstones[conn_id]
    if expire_at == nil then
        return false
    end
    if expire_at <= now then
        g_tombstones[conn_id] = nil
        return false
    end
    return true
end

local function add_tombstone(conn_id, now)
    if g_tombstones[conn_id] ~= nil then
        g_tombstones[conn_id] = now + TOMBSTONE_TTL
        return
    end
    g_tombstones[conn_id] = now + TOMBSTONE_TTL
    g_tombstone_order[#g_tombstone_order + 1] = conn_id
    -- 容量硬上限：突发断线洪峰不能让墓碑无限增长
    while #g_tombstone_order > TOMBSTONE_MAX do
        local oldest = table.remove(g_tombstone_order, 1)
        g_tombstones[oldest] = nil
    end
end

function M.new(conf)
    local conn_id = conf.conn_id
    -- 网关的 open 是"可确认 RPC"：超时后它可能重试，ACK 丢失时也可能重发。
    -- 同一个 fd 的重复 open 必须当成同一条连接，而不是 assert 把登录服务打挂
    local existing = g_clients[conn_id]
    if existing then
        existing.addr = conf.addr
        existing.gate = conf.gate
        g_gates[conn_id] = conf.gate
        log.warn("duplicate open for a tracked client", "conn", conn_id)
        return existing
    end
    if is_tombstoned(conn_id, os.time()) then
        -- 连接已经关闭，任何迟到的 open 都不能把它复活
        log.warn("refuse a late open for a closed connection", "conn", conn_id)
        return nil
    end
    g_clients[conn_id] = conf
    g_gates[conn_id] = conf.gate
    log.info("new client created", "conn", conn_id, "addr", conf.addr)
    -- 超时仍未完成登录就踢掉，避免半开连接长期占用 gate
    local login_timeout_sec = config.get_number("login_timeout_sec") or 60
    conf.login_timer = timer.timeout("login_timeout", login_timeout_sec, function()
        if not g_clients[conn_id] then
            return
        end
        log.error("client login timeout", "conn", conn_id)
        skynet.send(conf.gate, "lua", "kick", conn_id)
    end)
    return g_clients[conn_id]
end

-- 登录成功（会话已移交实体）或连接断开后，停止跟踪该客户端
function M.unbind(conn_id)
    local conf = g_clients[conn_id]
    if conf and conf.login_timer then
        conf.login_timer:cancel()
        conf.login_timer = nil
    end
    g_clients[conn_id] = nil
    log.info("login client unbound", "conn", conn_id)
end

-- 连接断了。和 M.unbind 的区别：unbind 只表示"不再是待登录客户端"（登录成功也会调），
-- 这个表示 fd 已经没了
function M.closed(conn_id)
    g_gates[conn_id] = nil
    add_tombstone(conn_id, os.time())
    M.unbind(conn_id)
end

-- 登录阶段的回包一律经网关发出。裸 TCP 和 WebSocket 的帧格式不一样，登录服务不知道
-- 也不该知道某条连接是哪一种——网关知道。直接往 socket 里写 netpack 包的老做法在
-- WS 连接上发的是乱码，客户端只会一直等到超时
function M.sender(conn_id, pack)
    local gate = g_gates[conn_id]
    if not gate then
        log.warn("dropping a response for a connection the login service no longer knows", "conn", conn_id)
        return
    end
    if not g_clients[conn_id] then
        -- 这条连接已经移交给实体了，这是登录服务在它上面发的最后一个包
        g_gates[conn_id] = nil
    end
    skynet.send(gate, "lua", "push", conn_id, pack)
end

-- sproto_api 把返回值作为 obj 透传给协议 handler
function M.get_obj(conn_id)
    return g_clients[conn_id]
end

return M
