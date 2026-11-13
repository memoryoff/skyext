local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local SOURCE =
    fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/pay_callback_router.lua")

local function harness()
    local h = { forks = 0, calls = {}, written = {} }
    local conf = {
        role_type = "role",
        orders = { db = "role", coll = "charge_order" },
        providers = { wechat = { module = "fake.provider", ack_before_grant = true } },
    }
    local imports = {
        ["skyext.config"] = {
            get_table = function(key)
                t.expect(key).to.equal("pay_callback")
                return conf
            end,
        },
        ["skyext.log"] = {
            debug = function() end,
            info = function() end,
            warn = function() end,
            error = function() end,
        },
        ["skyext.mongo_conn"] = {
            get_collection = function(db, coll)
                h.collection = { db = db, coll = coll }
                return h.collection
            end,
        },
        ["skyext.pay_webhook"] = {
            new = function(deps)
                h.deps = deps
                return {
                    handle = function()
                        return { status = 200, body = { result = "accepted" } }
                    end,
                }
            end,
        },
        ["skyext.entity.router"] = {
            call = function(type_name, rid, cmd, order)
                h.calls[#h.calls + 1] = { type_name = type_name, rid = rid, cmd = cmd, order = order }
                return true, { status = "COMMITTED" }
            end,
        },
        skynet = {
            fork = function(fn)
                h.forks = h.forks + 1
                fn()
            end,
        },
        ["fake.provider"] = {
            verify = function()
                return true
            end,
            parse = function()
                return {}
            end,
        },
        ["cjson.safe"] = {
            encode = function()
                return "{}"
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.routes = assert(loadfile(SOURCE, "t", env))()
    return h
end

t.describe("pay callback router 后台发奖", function()
    t.it("wires ack_before_grant to a non-blocking scheduled grant", function()
        local h = harness()
        local handler = h.routes.POST["/pay/wechat/callback"]
        t.expect(handler).to.be_type("function")
        handler({}, {
            write = function(_, status, body)
                h.written[#h.written + 1] = { status = status, body = body }
            end,
        })

        t.expect(h.deps.providers.wechat.ack_before_grant).to.equal(true)
        t.expect(h.deps.schedule_grant).to.be_type("function")
        local ok = h.deps.schedule_grant({ rid = 7, order_id = "o-1" })
        t.expect(ok).to.equal(true)
        t.expect(h.forks).to.equal(1)
        t.expect(h.calls[1].type_name).to.equal("role")
        t.expect(h.calls[1].rid).to.equal(7)
        t.expect(h.calls[1].cmd).to.equal("charge_grant")
    end)
end)
