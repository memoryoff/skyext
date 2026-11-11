local skynet = require "skynet"
local socket = require "skynet.socket"
local netpack = require "skynet.netpack"
local event_channel_api = require "skyext.event_channel_api"
local sproto_host = require "skyext.sproto_host"
local config = require "skyext.config"
local log = require "skyext.log"
local errcode = require "skyext.errcode"
local crypto = require "crypto"
local fingerprint = require "skyext.fingerprint"

local M = {}

-- 请求被连接模块拒绝（entity 未绑定/已解绑/租约失效）时回给客户端的错误码
M.errcode_rejected = errcode.ENTITY_NOT_FOUND
-- 处理过程抛错或没有产出回包时回给客户端的错误码
M.errcode_internal = errcode.ENTITY_LOAD_FAILED
-- response 里用于承载错误码的字段名，按顺序取第一个协议里存在的
M.reject_fields = { "errcode", "code" }

-- 内部缓存处置。只走 dispatch 内部返回值，不改变 wire 包：
--   CACHEABLE  正常业务响应，可进 L1 resp_cache（旧 handler 的默认行为）
--   NO_CACHE   纯读预检拒绝、环境 UNKNOWN 等瞬时结果，任何返回包都不写 resp_cache
M.CACHEABLE = "cacheable"
M.NO_CACHE = "no_cache"

-- CriticalDecision 的私有哨兵。业务 handler 返回普通 table 时不可能撞上这个 metatable，
-- 因此不会与真正的响应表混淆；也不导出给 sproto/RPC，客户端无法伪造
local DECISION_MT = {}

function M.decision(response, cache_policy)
    cache_policy = cache_policy or M.CACHEABLE
    if cache_policy ~= M.CACHEABLE and cache_policy ~= M.NO_CACHE then
        error("invalid cache_policy: " .. tostring(cache_policy), 2)
    end
    return setmetatable({ response = response, cache_policy = cache_policy }, DECISION_MT)
end

function M.is_decision(value)
    return type(value) == "table" and getmetatable(value) == DECISION_MT
end

local g_sproto_loader_service
local g_schema
local g_sproto_info
local g_host
local g_send_request
local g_sessions = {}
local REQUEST_CMD = {}
local GET_OBJ_CB = {}
local WITH_REQUEST_CB = {}
local MIDDLEWARE_CBS = {}
local REJECT_CLIENT_CB = {}
local g_reject_field = {}
local g_has_response = {}

local function register_request_func(request_name, func)
    if REQUEST_CMD[request_name] then
        error("Request command " .. request_name .. " already registered")
    end
    REQUEST_CMD[request_name] = func
end

-- mod_name 是协议的文件名
-- module 是连接管理模块
-- 一个连接管理模块需要提供 get_obj 接口用于获取连接对象
-- 同时也可以提供 middleware_cbs 表，用于注册中间件，主要用于做协议拦截
-- obj 就是一个连接对象，由连接管理模块的 get_obj 接口提供
-- 可选的 with_request(fd, f, req_id, request_name, request_digest) 用于把协议处理放进连接自己的串行
-- 队列，约定返回 true, ...（f 已执行）或 false, reason, code（请求被拒绝，f 未执行）。
-- req_id 是客户端带的 request id，连接模块可以拿它做上行幂等缓存；request_name 让它
-- 能发现同一个 id 换了协议（客户端重置了计数器）
-- 可选的 reject_client(fd, reason) 在错误码无法回给客户端时断开连接
function M.register_module(mod_name, module, cmds)
    for k, v in pairs(cmds or {}) do
        if type(v) == "function" then
            local request_name = mod_name .. "." .. k
            register_request_func(request_name, v)

            GET_OBJ_CB[request_name] = module.get_obj
            WITH_REQUEST_CB[request_name] = module.with_request
            MIDDLEWARE_CBS[request_name] = module.middleware_cbs
            REJECT_CLIENT_CB[request_name] = module.reject_client
        end
    end
end

-- 查协议的 response 里是否有可以承载错误码的字段
-- 没有 response（或者协议不存在）时返回 nil
local function response_errcode_field(request_name)
    local cached = g_reject_field[request_name]
    if cached ~= nil then
        return cached or nil
    end
    local field = false
    local ok, defaults = pcall(g_schema.default, g_schema, request_name, "RESPONSE")
    if not ok then
        log.warn("query response type failed", "request_name", request_name, "err", defaults)
    elseif type(defaults) == "table" then
        for _, name in ipairs(M.reject_fields) do
            if defaults[name] ~= nil then
                field = name
                break
            end
        end
    end
    g_reject_field[request_name] = field
    return field or nil
end

-- 协议是否声明了 response。注意 sproto 的 dispatch 即使没有 response 也会给一个
-- gen_response 闭包（只编码包头），所以不能用 response_cb ~= nil 判断
local function request_has_response(request_name)
    local cached = g_has_response[request_name]
    if cached ~= nil then
        return cached
    end
    local ok, defaults = pcall(g_schema.default, g_schema, request_name, "RESPONSE")
    local has = ok and type(defaults) == "table"
    g_has_response[request_name] = has
    return has
end

local function disconnect_client(fd, request_name, reason)
    local reject_client = REJECT_CLIENT_CB[request_name]
    if not reject_client then
        log.error(
            "cannot answer or disconnect a waiting client",
            "request_name",
            request_name,
            "fd",
            fd,
            "reason",
            reason
        )
        return
    end
    local ok, err = pcall(reject_client, fd, reason)
    if not ok then
        log.error("disconnect client failed", "request_name", request_name, "fd", fd, "err", err)
    end
end

-- 请求没有产出回包时的统一出口，返回要发给客户端的错误回包（可能为 nil）
-- 1. 客户端没带 session，不会等回包：只记日志
-- 2. response 里有错误码字段：回错误码，连接保留
-- 3. 回不了错误码（没有 response/没有错误码字段/编码失败）：断开连接，
--    让客户端立刻失败，而不是静默等到超时
local function reject_request(fd, request_name, reason, code, response_cb)
    log.warn("client request rejected", "request_name", request_name, "fd", fd, "reason", reason, "errcode", code)
    if response_cb == nil then
        return nil
    end
    local field = response_errcode_field(request_name)
    if field then
        local ok, pack = pcall(response_cb, { [field] = code })
        if ok and pack then
            return pack
        end
        log.error("encode reject response failed", "request_name", request_name, "fd", fd, "err", pack)
    end
    disconnect_client(fd, request_name, reason)
    return nil
end

-- request 消息处理接口:
-- 第 1 个参数是协议数据里的 request ,协议处理接口用 : 实现的时候，刚好 self 就是 request
-- 第 2 个参数是 fd
-- 第 3 个参数是 obj 对象
local function dispatch_request_unlocked(fd, request_name, request, response_cb)
    local f = assert(REQUEST_CMD[request_name])
    request = request or {}
    local get_obj = GET_OBJ_CB[request_name]
    log.debug("dispatch_request", "request_name", request_name, "fd", fd, "get_obj", get_obj, "request", request)
    local obj = nil
    if get_obj then
        obj = get_obj(fd)
    end

    local middleware_cbs = MIDDLEWARE_CBS[request_name]
    for _, cb in ipairs(middleware_cbs or {}) do
        local ok, ret, err = pcall(cb, request_name, request, fd, obj)
        if not ok then
            log.warn("middleware callback error", "request_name", request_name, "fd", fd, "err", ret)
            return nil, "middleware error: " .. tostring(ret), M.errcode_internal
        else
            if ret == nil then
                log.warn("middleware callback reject the request", "request_name", request_name, "fd", fd, "err", err)
                -- 中间件可以用数字形式的第二个返回值指定回给客户端的错误码
                local code = type(err) == "number" and err or M.errcode_rejected
                return nil, "middleware rejected: " .. tostring(err), code
            end
        end
    end

    local r = f(request, fd, obj)
    local cache_policy
    if M.is_decision(r) then
        cache_policy = r.cache_policy
        r = r.response
        if r == nil then
            if request_has_response(request_name) then
                -- 有 response 的协议却拿不到响应表，是 handler 的编程错误；不能编码一个
                -- 空包让客户端看起来像成功
                return nil, "critical decision produced no response", M.errcode_internal, cache_policy
            end
            -- 单向协议：不写任何包。raw_dispatch 看到 (nil, nil) 不会走拒绝路径
            return nil, nil, nil, cache_policy
        end
    end
    if response_cb == nil then
        if r ~= nil then
            log.error("request function should not return a value", "request_name", request_name, "fd", fd)
        end
        return nil, nil, nil, cache_policy
    end
    -- cache_policy 走独立的第 4 个返回值，绝不能占用 reason/code：raw_dispatch 把
    -- (nil, reason) 当成拒绝请求，NO_CACHE 的单向协议会被误判成拒绝并可能踢线
    return response_cb(r), nil, nil, cache_policy
end

-- 返回 pack 或者 nil, reason, code
local function dispatch_request(fd, request_name, request, response_cb, req_id)
    local with_request = WITH_REQUEST_CB[request_name]
    if not with_request then
        return dispatch_request_unlocked(fd, request_name, request, response_cb)
    end
    -- 摘要必须在 handler 执行前算：handler 可能原地改请求表，执行后再算就对不上
    -- 客户端重传的原始参数了。req_id 为 nil 的单向协议不写缓存，也不需要摘要
    local digest
    if req_id ~= nil then
        local err
        digest, err = fingerprint.compute(request_name, request or {}, crypto.hmac_sha256)
        if not digest then
            -- fail-closed：算不出摘要就不能保证幂等，拒绝执行而不是退化成"不比对"
            log.warn("request fingerprint failed", "request_name", request_name, "fd", fd, "err", err)
            return nil, "request fingerprint failed", M.errcode_rejected
        end
    end
    local ok, a, b, c, cache_policy = with_request(fd, function()
        return dispatch_request_unlocked(fd, request_name, request, response_cb)
    end, req_id, request_name, digest)
    if ok == true then
        -- f 已执行：a, b, c 就是它的 pack, reason, code；cache_policy 只用于 L1 决策
        return a, b, c, cache_policy
    end
    if ok ~= false then
        -- 兼容只返回单个回包的旧版连接模块
        return ok
    end
    -- 被拒绝：a 是原因，b 是连接模块指定的错误码（可选）
    return nil, tostring(a or "request rejected"), b or M.errcode_rejected
end

-- 回包、推送怎么送到客户端。默认直接写本进程的 socket：登录服务、robot 这类直接持有
-- 连接的服务就是这样。实体 agent 里的连接在 gate 上，由 skyext.entity.session 换成
-- "发给会话所在的 gate"，conn 也从 fd 变成会话键。
-- 第三个参数是回包对应的协议名（主动推送时为 nil），会话层靠它把传输层握手的回包
-- 排除在下行计数之外
local function socket_sender(fd, pack)
    local data, sz = netpack.pack(pack)
    socket.write(fd, data, sz)
end

local g_sender = socket_sender

function M.set_sender(sender)
    g_sender = sender or socket_sender
end

local function send_package(conn, pack, request_name)
    g_sender(conn, pack, request_name)
end

local function wakeup_call(pending, response)
    local co = pending.co
    if not co then
        return false
    end
    pending.co = nil
    pending.response = response
    skynet.wakeup(pending)
    return true
end

function M.raw_dispatch(fd, type, request_name, request, response_cb, req_id)
    log.debug("raw_dispatch", "fd", fd, "type", type, "request_name", request_name)
    if type == "REQUEST" then
        local ok, result, reason, code =
            xpcall(dispatch_request, debug.traceback, fd, request_name, request, response_cb, req_id)
        if not ok then
            log.error("dispatch request error", "request_name", request_name, "result", result)
            result, reason, code = nil, "internal error", M.errcode_internal
        end
        -- 没有产出回包时，只要客户端在等 session 就必须回错误码或断开连接。
        -- 注意 sproto 对没有 response 的协议也会给一个只编码包头的闭包，
        -- 所以"客户端在等"必须看协议是否声明了 response，而不是 response_cb ~= nil：
        -- NO_CACHE 的单向协议返回 (nil, nil) 是正常终态，不能走拒绝路径
        if result == nil and (reason ~= nil or (response_cb ~= nil and request_has_response(request_name))) then
            result = reject_request(
                fd,
                request_name,
                reason or "request produced no response",
                code or M.errcode_internal,
                response_cb
            )
        end
        if result then
            send_package(fd, result, request_name)
            log.debug("request dispatched successfully", "request_name", request_name, "fd", fd)
        end
    else
        local sess = request_name
        local pending = g_sessions[sess]
        if pending then
            return wakeup_call(pending, request)
        end
    end
end

-- 处理一个上行包（gate 转发过来的原始字节）。conn 是连接标识：fd 或会话键
function M.dispatch_message(conn, data)
    local type, request_name, request, response_cb, req_id = g_host:dispatch(data)
    return M.raw_dispatch(conn, type, request_name, request, response_cb, req_id)
end

-- 下行推送：服务端主动发给客户端的协议，没有回包
function M.notify(conn, name, param)
    send_package(conn, g_send_request(name, param))
end

-- 只编码不发送。会话层要先计数、入重放缓冲，再决定写不写网关——离线时它手上根本没有
-- 连接标识，走不了 notify
function M.encode_notify(name, param)
    return g_send_request(name, param)
end

function M.call(fd, name, param, session, timeout)
    send_package(fd, g_send_request(name, param, session))

    local pending = {
        name = name,
        co = coroutine.running(),
        response = nil,
    }
    g_sessions[session] = pending

    -- 默认超时时间
    if not timeout then
        timeout = config.get_number("sproto_timeout") or 10
    end
    skynet.sleep(timeout * 100, pending)
    g_sessions[session] = nil

    if pending.co then
        log.error("call timeout", "name", name, "fd", fd, "session", session)
        return nil
    end

    return pending.response
end

function M.get_sproto_info()
    return g_sproto_info
end

function M.get_sproto_host()
    return g_host
end

local function get_sproto_schema()
    local sproto_schema_path = config.get("sproto_schema_path")
    local sproto_index = config.get_number("sproto_index") or 1
    local ok, info = skynet.call(g_sproto_loader_service, "lua", "load_proto", sproto_schema_path, sproto_index)
    if not ok then
        error(info)
    end

    local sprotoloader = require("sprotoloader")
    local ret = sprotoloader.load(sproto_index)
    return ret, info or {}
end

local function reload_sproto()
    g_schema, g_sproto_info = get_sproto_schema()
    g_reject_field = {}
    g_has_response = {}
    g_host = sproto_host.new(g_schema, "base.package")
    g_send_request = g_host:attach()
end

skynet.init(function()
    g_sproto_loader_service = skynet.uniqueservice("sproto_loader")

    reload_sproto()
    local sproto_schema_path = config.get("sproto_schema_path")
    event_channel_api.subscribe(g_sproto_loader_service, sproto_schema_path, reload_sproto)
end)

return M
