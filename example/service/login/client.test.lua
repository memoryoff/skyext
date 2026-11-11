-- 登录端的 open 必须幂等：网关的注册 RPC 有超时重试，ACK 丢失时也会重发。
-- 旧实现用 assert 拒绝重复 fd，一条重复 open 就能把登录服务打挂。
local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/service/login/client.lua")

-- 网关生成的连接标识；登录端只把它当键，不解析内容
local CID = "v1|gate1|.gate_ws|" .. string.rep("a", 32) .. "|9"

local function harness()
    local h = { sent = {}, timers = {}, cancelled = 0 }
    local noop = function() end

    local function new_timer(name, sec, fn)
        local timer = { name = name, sec = sec, fn = fn }
        function timer:cancel()
            self.cancelled = true
            h.cancelled = h.cancelled + 1
        end
        h.timers[#h.timers + 1] = timer
        return timer
    end

    local imports = {
        skynet = {
            send = function(addr, proto, cmd, ...)
                t.expect(proto).to.equal("lua")
                h.sent[#h.sent + 1] = { addr, cmd, ... }
            end,
        },
        ["skyext.timer"] = { timeout = new_timer },
        ["skyext.config"] = {
            get_number = function(key)
                t.expect(key).to.equal("login_timeout_sec")
                return 60
            end,
        },
        ["skyext.log"] = { info = noop, warn = noop, error = noop, debug = noop },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.client = assert(loadfile(source, "t", env))()
    return h
end

t.describe("login client registration", function()
    t.it("treats a duplicate open as the same connection", function()
        local h = harness()
        local first = h.client.new({ conn_id = CID, addr = "a", gate = ".gate_ws" })
        t.expect(#h.timers).to.equal(1)

        local second = h.client.new({ conn_id = CID, addr = "b", gate = ".gate_tcp" })
        t.expect(second).to.equal(first)
        t.expect(first.addr).to.equal("b")
        t.expect(first.gate).to.equal(".gate_tcp")
        -- 不能给同一个 fd 挂第二个登录超时定时器
        t.expect(#h.timers).to.equal(1)
    end)

    t.it("routes login responses back to the gate that opened the connection", function()
        local h = harness()
        h.client.new({ conn_id = CID, addr = "a", gate = ".gate_ws" })
        h.client.sender(CID, "PACK")
        t.expect(h.sent).to.equal({ { ".gate_ws", "push", CID, "PACK" } })
    end)

    t.it("cancels the login timeout when the connection is unbound", function()
        local h = harness()
        h.client.new({ conn_id = CID, addr = "a", gate = ".gate_ws" })
        h.client.unbind(CID)
        t.expect(h.cancelled).to.equal(1)
        t.expect(h.client.get_obj(CID)).to.be_nil()
    end)

    t.it("kicks a client that never finishes logging in", function()
        local h = harness()
        h.client.new({ conn_id = CID, addr = "a", gate = ".gate_ws" })
        h.timers[1].fn()
        t.expect(h.sent).to.equal({ { ".gate_ws", "kick", CID } })
    end)

    t.it("does not kick after the client has already gone", function()
        local h = harness()
        h.client.new({ conn_id = CID, addr = "a", gate = ".gate_ws" })
        h.client.closed(CID)
        h.timers[1].fn()
        t.expect(h.sent).to.equal({})
    end)

    -- 迟到的 open 在 disconnect 之后到达：new 会重新建记录，网关随后会补发 disconnect，
    -- 这里只证明登录端两条路径都不抛错
    t.it("tolerates open and disconnect arriving in either order", function()
        local h = harness()
        h.client.closed(CID)
        local conf = h.client.new({ conn_id = CID, addr = "a", gate = ".gate_ws" })
        t.expect(conf).to.exist()
        h.client.closed(CID)
        t.expect(h.client.get_obj(CID)).to.be_nil()
    end)
end)
