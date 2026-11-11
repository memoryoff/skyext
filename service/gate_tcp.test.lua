-- TCP 网关的连接身份：每条连接在 accept 时生成 conn_id，之后的 open/client_msg/
-- session_closed/bind/push/kick 全部用它。裸 fd 只在网关内部读写 socket。
local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local connection_id = require "skyext.connection_id"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/gate_tcp.lua")

local SELF_NODE = "gate1"
local LOGIN = 42

local function harness()
    local h = { sent = {}, writes = {}, closed = {}, env = {} }
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
        send = function(addr, proto, cmd, ...)
            t.expect(proto).to.equal("lua")
            record(addr, cmd, ...)
        end,
    }, { __index = skynet })

    local fake_gateserver = {
        start = function(handler)
            h.handler = handler
        end,
        openclient = function(fd)
            h.opened = fd
        end,
        closeclient = function(fd)
            h.closed[#h.closed + 1] = fd
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skynet.cluster"] = {
            send = function(node, addr, cmd, ...)
                record(node .. "!" .. addr, cmd, ...)
            end,
        },
        ["snax.gateserver"] = fake_gateserver,
        ["skynet.netpack"] = {
            tostring = function(msg)
                return msg
            end,
            pack = function(pack)
                return pack, #pack
            end,
        },
        ["skynet.socketdriver"] = {
            send = function(fd, data, sz)
                h.writes[#h.writes + 1] = { fd = fd, data = data, sz = sz }
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
    h.handler.open(nil, { login = LOGIN, address = "0.0.0.0", port = 7001 })
    skynet.sleep(0)
    -- gateserver 的 command(cmd, source, ...) 会吃掉第二个参数，测试里包一层
    h.CMD = {
        bind = function(cid, node, service)
            return h.handler.command("bind", nil, cid, node, service)
        end,
        push = function(cid, pack)
            return h.handler.command("push", nil, cid, pack)
        end,
        kick = function(cid)
            return h.handler.command("kick", nil, cid)
        end,
        count = function()
            return h.handler.command("count", nil)
        end,
        conn_id = function(fd)
            return h.handler.command("conn_id", nil, fd)
        end,
    }

    function h.connect(fd, addr)
        h.handler.connect(fd, addr or "127.0.0.1:1")
        h.last_cid = h.CMD.conn_id(fd)
    end

    return h
end

t.describe("gate_tcp connection identity", function()
    t.it("generates a conn_id per connection and opens it with that id", function()
        local h = harness()
        h.connect(9, "1.2.3.4:5678")
        local cid = h.CMD.conn_id(9)
        t.expect(connection_id.validate(cid)).to.equal(true)
        t.expect(h.sent[1]).to.equal({ LOGIN, "open", cid, "1.2.3.4:5678", ".gate_tcp" })
        t.expect(h.opened).to.equal(9)
    end)

    t.it("forwards an unbound client's bytes with the conn_id, not the fd", function()
        local h = harness()
        h.connect(9)
        local cid = h.CMD.conn_id(9)
        h.handler.message(9, "BYTES", 5)
        t.expect(h.sent[2]).to.equal({ LOGIN, "client_msg", cid, "BYTES" })
    end)

    t.it("binds and forwards to the owner by conn_id", function()
        local h = harness()
        h.connect(9)
        local cid = h.CMD.conn_id(9)
        t.expect(h.CMD.bind(cid, SELF_NODE, ".entity_agent:role:1")).to.equal(true)
        h.handler.message(9, "BYTES", 5)
        t.expect(h.sent[#h.sent]).to.equal({ ".entity_agent:role:1", "client_msg", SELF_NODE, cid, "BYTES" })
    end)

    t.it("tells the owner, not login, when a bound connection drops", function()
        local h = harness()
        h.connect(9)
        local cid = h.CMD.conn_id(9)
        h.CMD.bind(cid, SELF_NODE, ".entity_agent:role:1")
        h.handler.disconnect(9)
        t.expect(h.sent[#h.sent]).to.equal({ ".entity_agent:role:1", "session_closed", SELF_NODE, cid })
        t.expect(h.CMD.count()).to.equal(0)
    end)

    t.it("gives a reused fd a fresh conn_id and never confuses the two sessions", function()
        local h = harness()
        h.connect(9)
        local first = h.CMD.conn_id(9)
        h.handler.disconnect(9)
        h.connect(9)
        local second = h.CMD.conn_id(9)
        t.expect(second).to_not.equal(first)
        t.expect(h.CMD.count()).to.equal(1)
    end)

    t.it("pushes and kicks by conn_id while writing to the underlying fd", function()
        local h = harness()
        h.connect(9)
        local cid = h.CMD.conn_id(9)
        h.CMD.push(cid, "PACK")
        t.expect(h.writes).to.equal({ { fd = 9, data = "PACK", sz = 4 } })
        h.CMD.kick(cid)
        t.expect(h.closed).to.equal({ 9 })
        -- 已经不存在的 conn_id 不能误操作任何 socket
        h.CMD.push("v1|gate1|.gate_tcp|" .. string.rep("d", 32) .. "|1", "PACK")
        t.expect(#h.writes).to.equal(1)
    end)

    t.it("refuses to bind a conn_id it does not know", function()
        local h = harness()
        t.expect(h.CMD.bind("v1|gate1|.gate_tcp|" .. string.rep("d", 32) .. "|1", SELF_NODE, ".x")).to.equal(false)
    end)
end)
