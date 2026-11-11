-- 登录服务：处理还没绑定到实体的会话。网关把未绑定会话的包交给这里，
-- 鉴权通过后经 router.bind_session 把会话绑到角色实体上，之后的包由网关直接转给实体。
-- role 节点（同进程部署）和独立的 gate 节点共用这个服务，gate_tcp 和 gate_ws 也共用，
-- 所以每条连接要记住自己是从哪个网关来的（CMD.open 的 gate_service 参数）。
local sproto_api = require "skyext.sproto_api"
local cmd_api = require "skyext.cmd_api"
local skynet = require "skynet"
local client = require "client"
local login_request = require "login_request"
local log = require "skyext.log"

log.config {
    name = "login",
}

local CMD = {}

function CMD.open(conn_id, addr, gate_service)
    client.new({ conn_id = conn_id, addr = addr, gate = assert(gate_service, "gate must identify itself") })
    -- 网关在 WS 握手回调里同步等这个确认；没有返回值会被当成注册失败并断开连接。
    -- 重复 open 是允许的：网关超时重试、ACK 丢失都会再发一次，client.new 做幂等处理
    return true
end

function CMD.client_msg(conn_id, data)
    sproto_api.dispatch_message(conn_id, data)
end

function CMD.disconnect(conn_id)
    client.closed(conn_id)
end

skynet.start(function()
    sproto_api.set_sender(client.sender)
    sproto_api.register_module("login", client, login_request)
    cmd_api.dispatch(CMD)
end)
