local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/gate_ws.lua")

local SELF_NODE = "gate1"
local LOGIN = 42
local LISTEN_FD = 100

local function harness(opts)
    opts = opts or {}
    local h = {
        sent = {},
        writes = {},
        closes = {},
        env = opts.env or {},
        conn_co = {},
        calls = {},
        timers = {},
    }
    local noop = function() end

    local function record(target, cmd, ...)
        h.sent[#h.sent + 1] = { target, cmd, ... }
    end

    local fake_skynet = setmetatable({
        start = function(fn)
            h.boot = fn
        end,
        register = function(name)
            h.registered = name
        end,
        getenv = function(key)
            return h.env[key]
        end,
        setenv = function(key, value)
            t.expect(h.env[key]).to.be_nil()
            h.env[key] = value
        end,
        send = function(addr, proto, cmd, ...)
            t.expect(proto).to.equal("lua")
            record(addr, cmd, ...)
        end,
        -- 登录 open 走可确认 RPC。默认立即成功；h.call_block 时挂起，
        -- 由测试决定是超时先到还是迟到成功先到
        call = function(addr, proto, cmd, ...)
            t.expect(proto).to.equal("lua")
            h.calls[#h.calls + 1] = { addr, cmd, ... }
            if h.call_error then
                error(h.call_error)
            end
            if h.call_block then
                h.call_co = coroutine.running()
                skynet.wait()
            end
            if h.call_result == nil then
                return true
            end
            return h.call_result
        end,
        timeout = function(cs, fn)
            h.timers[#h.timers + 1] = { cs = cs, fn = fn }
            return #h.timers
        end,
    }, { __index = skynet })

    local fake_cluster = {
        send = function(node, addr, cmd, ...)
            if h.cluster_error then
                error(h.cluster_error)
            end
            record(node .. "!" .. addr, cmd, ...)
        end,
    }

    local fake_socket = {
        listen = function(host, port)
            h.listen = { host = host, port = port }
            return LISTEN_FD
        end,
        start = function(id, cb)
            t.expect(id).to.equal(LISTEN_FD)
            h.accept_cb = cb
        end,
        close = function(id)
            h.listen_closed = id
        end,
        close_fd = function(id)
            h.dropped = id
        end,
    }

    -- websocket.accept 阻塞到连接关闭，这里用协程挂起模拟；握手成功后调用 handshake，
    -- 与 http.websocket 的 resolve_accept 顺序一致（101 响应之后、读帧循环之前）
    local fake_websocket = {
        accept = function(fd, handler, protocol, addr)
            h.handler = handler
            h.accepted = { fd = fd, protocol = protocol, addr = addr }
            if h.accept_fail then
                return false, "handshake failed"
            end
            h.conn_co[fd] = coroutine.running()
            if handler.handshake then
                handler.handshake(fd)
            end
            skynet.wait()
            return true
        end,
        write = function(fd, data, fmt)
            if h.write_error then
                error(h.write_error)
            end
            h.writes[#h.writes + 1] = { fd = fd, data = data, fmt = fmt }
        end,
        close = function(fd, code, reason)
            h.closes[#h.closes + 1] = { fd = fd, code = code, reason = reason }
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skynet.cluster"] = fake_cluster,
        ["skynet.socket"] = fake_socket,
        ["http.websocket"] = fake_websocket,
        ["skyext.cmd_api"] = {
            dispatch = function(commands)
                h.CMD = commands
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("cluster_node_name")
                return SELF_NODE
            end,
        },
        ["skyext.node_shutdown_api"] = {
            add_hook = function(phase, cmd)
                h.hook = { phase = phase, cmd = cmd }
            end,
        },
        ["skyext.log"] = { info = noop, warn = noop, error = noop, debug = noop },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    h.boot()
    -- 停服钩子是在 skynet.fork 里注册的，让它跑起来
    skynet.sleep(0)

    function h.tick(n)
        for _ = 1, n or 3 do
            skynet.sleep(0)
        end
    end

    -- 接一条连接：跑 accept 回调，等连接协程走完握手/注册
    function h.connect(fd, addr)
        h.accept_cb(fd, addr or "127.0.0.1:1234")
        h.tick()
    end

    -- 连接真的断了：唤醒连接协程，让它跑完 serve 的收尾
    function h.disconnect(fd)
        local co = h.conn_co[fd]
        h.conn_co[fd] = nil
        if co then
            skynet.wakeup(co)
        end
        h.tick()
    end

    -- 注册超时：跑 timeout 回调
    function h.fire_timeout()
        local timer = h.timers[#h.timers]
        t.expect(timer).to.exist()
        timer.fn()
        h.tick()
    end

    -- 迟到的 open 响应：唤醒被超时放弃的 RPC
    function h.resolve_call(value)
        h.call_result = value
        local co = h.call_co
        h.call_co = nil
        t.expect(co).to.exist()
        skynet.wakeup(co)
        h.tick()
    end

    if not opts.no_open then
        h.CMD.open({
            address = "0.0.0.0",
            port = 7053,
            login = LOGIN,
            maxclient = opts.maxclient,
            protocol = opts.protocol,
            certfile = opts.certfile,
            keyfile = opts.keyfile,
            handshake_timeout_ms = opts.handshake_timeout_ms,
        })
    end
    return h
end

t.describe("gate_ws startup", function()
    t.it("listens and registers the name the entity side routes packages to", function()
        local h = harness()
        t.expect(h.listen).to.equal({ host = "0.0.0.0", port = 7053 })
        t.expect(h.registered).to.equal(".gate_ws")
        t.expect(h.hook).to.equal({ phase = "stop_accepting", cmd = "close" })
    end)

    t.it("refuses to start without a login service or with an unknown protocol", function()
        local h = harness({ no_open = true })
        t.expect(function()
            h.CMD.open({ port = 7053 })
        end).to
            .throw("conf.login")
        t.expect(function()
            h.CMD.open({ port = 7053, login = LOGIN, protocol = "http" })
        end).to
            .throw("ws_protocol")
    end)

    -- 没开 enablessl 时 TLS 握手要到第一个 wss 连接进来才炸，那时候端口已经对外了
    t.it("rejects wss at startup when TLS is not enabled, instead of on the first connection", function()
        local h = harness({ no_open = true })
        t.expect(function()
            h.CMD.open({ port = 7053, login = LOGIN, protocol = "wss" })
        end).to
            .throw("enablessl")
    end)

    -- skynet 的 env 里全是字符串，配成别的值等于没开
    t.it("rejects wss when enablessl is set to anything other than the string true", function()
        local h = harness({ no_open = true, env = { enablessl = "false" } })
        t.expect(function()
            h.CMD.open({ port = 7053, login = LOGIN, protocol = "wss" })
        end).to
            .throw("enablessl")
    end)

    t.it("publishes the certificate paths where websocket.lua looks for them", function()
        local h = harness({
            no_open = true,
            env = { enablessl = "true" },
        })
        h.CMD.open({
            port = 7053,
            login = LOGIN,
            protocol = "wss",
            certfile = "cert.pem",
            keyfile = "key.pem",
        })
        t.expect(h.env.certfile).to.equal("cert.pem")
        t.expect(h.env.keyfile).to.equal("key.pem")
    end)

    -- skynet.setenv 不允许覆盖已存在的键，直接写节点配置的部署会在这里炸
    t.it("leaves certificate paths that the node config already set", function()
        local h = harness({
            no_open = true,
            env = { enablessl = "true", certfile = "from-node.pem", keyfile = "from-node-key.pem" },
        })
        h.CMD.open({ port = 7053, login = LOGIN, protocol = "wss" })
        t.expect(h.env.certfile).to.equal("from-node.pem")
    end)

    t.it("stops accepting without touching the connections already in flight", function()
        local h = harness()
        h.connect(9)
        h.CMD.close()
        t.expect(h.listen_closed).to.equal(LISTEN_FD)
        t.expect(h.CMD.count()).to.equal(1)
        t.expect(h.closes).to.equal({})
        -- 幂等：停服编排可能重复触发
        h.CMD.close()
    end)
end)

t.describe("gate_ws registration lifecycle", function()
    t.it("reserves the slot before forking so a burst cannot overshoot maxclient", function()
        local h = harness({ maxclient = 1 })
        -- 两次 accept 回调都不让出：第二次必须在预占阶段就被拒绝
        h.accept_cb(9, "a")
        h.accept_cb(10, "b")
        t.expect(h.dropped).to.equal(10)
        t.expect(h.CMD.count()).to.equal(1)
        h.tick()
    end)

    t.it("confirms registration with the login service before reading frames", function()
        local h = harness()
        h.connect(9, "1.2.3.4:5678")
        t.expect(h.calls).to.equal({ { LOGIN, "open", 9, "1.2.3.4:5678", ".gate_ws" } })
        t.expect(h.CMD.state(9)).to.equal("ACTIVE")
        t.expect(h.CMD.count()).to.equal(1)
        -- 5000ms 必须换成 skynet.timeout 的 1/100 秒单位
        t.expect(h.timers[1].cs).to.equal(500)
    end)

    t.it("drops a new connection once it is full rather than degrade everyone", function()
        local h = harness({ maxclient = 1 })
        h.connect(9)
        h.connect(10)
        t.expect(h.dropped).to.equal(10)
        t.expect(h.CMD.count()).to.equal(1)
    end)

    t.it("closes the socket and tells login when registration times out", function()
        local h = harness({ handshake_timeout_ms = 50 })
        h.call_block = true
        h.connect(9)
        t.expect(h.CMD.state(9)).to.equal("REGISTERING")
        t.expect(h.CMD.count()).to.equal(1)
        -- 超时前不通知登录端，避免它先建记录又收不到后续
        t.expect(h.sent).to.equal({})

        h.fire_timeout()
        t.expect(h.CMD.state(9)).to.equal("CLOSED")
        t.expect(h.CMD.count()).to.equal(0)
        t.expect(h.closes[1]).to.equal({ fd = 9, code = 1011, reason = "register failed" })
        t.expect(h.sent).to.equal({ { LOGIN, "disconnect", 9 } })
    end)

    t.it("compensates a late ACK after the timeout already closed the connection", function()
        local h = harness({ handshake_timeout_ms = 50 })
        h.call_block = true
        h.connect(9)
        h.fire_timeout()
        t.expect(h.sent).to.equal({ { LOGIN, "disconnect", 9 } })

        -- 登录端其实已经登记成功，只是响应来晚了：必须补一次 disconnect
        h.resolve_call(true)
        t.expect(h.sent).to.equal({ { LOGIN, "disconnect", 9 }, { LOGIN, "disconnect", 9 } })
    end)

    t.it("does not compensate into an fd that has already been reused", function()
        local h = harness({ handshake_timeout_ms = 50 })
        h.call_block = true
        h.connect(9)
        h.fire_timeout()

        -- fd 复用：新连接已经 ACTIVE，迟到的旧 ACK 不能再按 fd 踢人
        h.call_block = false
        h.connect(9)
        t.expect(h.CMD.state(9)).to.equal("ACTIVE")
        local before = #h.sent
        h.resolve_call(true)
        t.expect(#h.sent).to.equal(before)
    end)

    t.it("treats an explicit false acknowledgement as a failed registration", function()
        local h = harness()
        h.call_result = false
        h.connect(9)
        t.expect(h.CMD.state(9)).to.equal("CLOSED")
        t.expect(h.CMD.count()).to.equal(0)
        t.expect(h.closes[1].code).to.equal(1011)
    end)

    t.it("closes the connection when login reports an error instead of leaving it half-open", function()
        local h = harness()
        h.call_error = "login is down"
        h.connect(9)
        t.expect(h.CMD.state(9)).to.equal("CLOSED")
        t.expect(h.CMD.count()).to.equal(0)
        t.expect(h.closes[1].code).to.equal(1011)
    end)

    t.it("refuses a frame that arrives before the session is ACTIVE", function()
        local h = harness({ handshake_timeout_ms = 50 })
        h.call_block = true
        h.connect(9)
        h.handler.message(9, "BYTES", "binary")
        t.expect(h.sent).to.equal({})
        t.expect(h.closes[1].code).to.equal(1011)
    end)

    t.it("cleans up a connection whose handshake never completed", function()
        local h = harness()
        h.accept_fail = true
        h.connect(9)
        t.expect(h.CMD.count()).to.equal(0)
        -- 没握成手的连接也要让登录服务知道，否则它的 fd 表会漏
        t.expect(h.sent).to.equal({ { LOGIN, "disconnect", 9 } })
    end)

    t.it("frees the slot when the connection closes", function()
        local h = harness()
        h.connect(9)
        h.handler.close(9)
        t.expect(h.sent).to.equal({ { LOGIN, "disconnect", 9 } })
        t.expect(h.CMD.count()).to.equal(0)
        -- serve 收尾时不能再报一次
        h.disconnect(9)
        t.expect(#h.sent).to.equal(1)
    end)
end)

t.describe("gate_ws forwarding", function()
    local function connected(opts)
        local h = harness(opts)
        h.connect(9)
        h.sent = {}
        h.calls = {}
        return h
    end

    t.it("sends an unbound client's packages to the login service", function()
        local h = connected()
        h.handler.message(9, "BYTES", "binary")
        t.expect(h.sent).to.equal({ { LOGIN, "client_msg", 9, "BYTES" } })
    end)

    t.it("forwards a bound client's packages straight to the owning entity agent", function()
        local h = connected()
        t.expect(h.CMD.bind(9, SELF_NODE, ".entity_agent:role:1")).to.equal(true)
        h.handler.message(9, "BYTES", "binary")
        t.expect(h.sent).to.equal({ { ".entity_agent:role:1", "client_msg", SELF_NODE, 9, "BYTES" } })
    end)

    t.it("forwards to an owner on another node over cluster", function()
        local h = connected()
        h.CMD.bind(9, "rolenode1", ".entity_agent:role:1")
        h.handler.message(9, "BYTES", "binary")
        t.expect(h.sent).to.equal({ { "rolenode1!.entity_agent:role:1", "client_msg", SELF_NODE, 9, "BYTES" } })
    end)

    -- 实体节点挂了不能把网关也带下去：这个包丢了，客户端超时后会重连
    t.it("survives an unreachable owner node", function()
        local h = connected()
        h.CMD.bind(9, "rolenode1", ".entity_agent:role:1")
        h.cluster_error = "node down"
        h.handler.message(9, "BYTES", "binary")
        t.expect(h.sent).to.equal({})
    end)

    t.it("tells the owner, not the login service, when a bound connection drops", function()
        local h = connected()
        h.CMD.bind(9, "rolenode1", ".entity_agent:role:1")
        h.handler.close(9)
        t.expect(h.sent).to.equal({ { "rolenode1!.entity_agent:role:1", "session_closed", SELF_NODE, 9 } })
    end)

    t.it("reports a socket error the same way as a clean close", function()
        local h = connected()
        h.handler.error(9, "reset by peer")
        t.expect(h.sent).to.equal({ { LOGIN, "disconnect", 9 } })
        t.expect(h.CMD.count()).to.equal(0)
    end)

    -- 协议是二进制 sproto。文本帧多半是接错了端口或者客户端发了 JSON，早断早清楚
    t.it("closes a connection that sends text frames", function()
        local h = connected()
        h.handler.message(9, '{"cmd":"login"}', "text")
        t.expect(h.sent).to.equal({})
        t.expect(h.closes[1].fd).to.equal(9)
        t.expect(h.closes[1].code).to.equal(1003)
    end)

    t.it("refuses to bind a connection that is already gone", function()
        local h = connected()
        t.expect(h.CMD.bind(99, SELF_NODE, ".entity_agent:role:1")).to.equal(false)
    end)
end)

t.describe("gate_ws downstream", function()
    t.it("writes a binary frame without a length prefix, the WS frame has its own", function()
        local h = harness()
        h.connect(9)
        h.CMD.push(9, "PACK")
        t.expect(h.writes).to.equal({ { fd = 9, data = "PACK", fmt = "binary" } })
    end)

    t.it("drops a package for a connection it does not know", function()
        local h = harness()
        h.CMD.push(9, "PACK")
        t.expect(h.writes).to.equal({})
    end)

    -- 写可能撞上连接正在关闭，这条连接自己会走断开流程，不能连累推送的实体
    t.it("does not propagate a write error to the caller", function()
        local h = harness()
        h.connect(9)
        h.write_error = "socket closed"
        h.CMD.push(9, "PACK")
        t.expect(h.writes).to.equal({})
    end)

    -- kick 只关 socket，解绑交给断开回调，这样 on_unbind_client 照常执行
    t.it("kick closes the socket and leaves the unbind to the disconnect callback", function()
        local h = harness()
        h.connect(9)
        h.sent = {}
        h.CMD.kick(9)
        t.expect(h.closes[1].fd).to.equal(9)
        t.expect(h.sent).to.equal({})
        t.expect(h.CMD.count()).to.equal(1)

        h.handler.close(9)
        t.expect(h.sent).to.equal({ { LOGIN, "disconnect", 9 } })
    end)

    t.it("ignores a kick for a connection that is already gone", function()
        local h = harness()
        h.CMD.kick(9)
        t.expect(h.closes).to.equal({})
    end)
end)
