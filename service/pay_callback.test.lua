-- pay_callback 启动门禁：支付链路的所有写都建立在"订单集合有多数派通道 + 唯一索引"
-- 之上。门禁顺序与短路必须在服务启动这一层被验证——单测覆盖 charge_order 的
-- check_write_channel 本身并不保证 CMD.start 真的在开监听之前拦下来。
local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local SOURCE = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/pay_callback.lua")

local function harness(opts)
    opts = opts or {}
    local noop = function() end
    local h = {
        order_gate_ok = opts.order_gate_ok ~= false,
        order_gate_err = opts.order_gate_err or "orders collection has no critical_find_and_modify",
        order_index_ok = opts.order_index_ok ~= false,
        reconcile_index_ok = opts.reconcile_index_ok ~= false,
        index_calls = 0,
        probe_calls = 0,
        forks = 0,
    }
    h.probe_ok = opts.probe_ok ~= false
    h.probe_err = opts.probe_err or "probe majority write not confirmed (UNKNOWN): timeout"
    h.collection = opts.collection
        or {
            _name = "charge_order",
            critical_probe = function()
                h.probe_calls = h.probe_calls + 1
                if h.probe_ok then
                    return true
                end
                return nil, h.probe_err
            end,
        }
    h.pay_conf = opts.pay_conf
        or {
            host = "127.0.0.1",
            port = 18090,
            orders = { db = "game", coll = "charge_order" },
            providers = { mock = { module = "test.pay_provider", ack_before_grant = true } },
        }

    local imports = {
        skynet = {
            start = function(fn)
                h.start_fn = fn
            end,
            self = function()
                return 1
            end,
            sleep = noop,
            fork = function()
                h.forks = h.forks + 1
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(cmd)
                h.CMD = cmd
            end,
        },
        ["skyext.config"] = {
            get_table = function()
                return h.pay_conf
            end,
        },
        ["skyext.log"] = {
            info = noop,
            warn = noop,
            error = noop,
        },
        ["skyext.mongo_conn"] = {
            get_collection = function()
                return h.collection
            end,
        },
        ["skyext.charge_order"] = {
            check_write_channel = function()
                if h.order_gate_ok then
                    return true
                end
                return nil, h.order_gate_err
            end,
            ensure_indexes = function()
                h.index_calls = h.index_calls + 1
                if h.order_index_ok then
                    return true
                end
                return nil, "duplicate key"
            end,
        },
        ["skyext.charge_reconcile"] = {
            ensure_indexes = function()
                if h.reconcile_index_ok then
                    return true
                end
                return nil, "reconcile index failed"
            end,
            run_once = function()
                return {}
            end,
        },
        ["skyext.http_server"] = {
            new = function(name)
                local server = { name = name }
                h.server = server
                function server:start(params)
                    self.params = params
                end
                function server:register_router(module_name)
                    self.router = module_name
                end
                return server
            end,
        },
        ["skyext.entity.router"] = {},
        ["test.pay_provider"] = {
            verify = function()
                return true
            end,
            parse = function()
                return { provider = "mock", order_id = "o-1", amount = 1, currency = "CNY", rid = 7 }
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.service = assert(loadfile(SOURCE, "t", env))()
    assert(h.start_fn)()
    assert(h.CMD, "cmd_api.dispatch was never called")
    return h
end

t.describe("pay_callback 启动门禁", function()
    -- 缺多数派写通道时必须先于索引门禁、先于监听失败：订单是资金凭证，
    -- 降级成 w:1 后再"启动成功"等于把丢单风险静默带进生产
    t.it("refuses to listen when the majority write gate fails", function()
        local h = harness({ order_gate_ok = false })
        local ok, err = h.CMD.start()
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("critical_find_and_modify")
        t.expect(h.index_calls).to.equal(0)
        t.expect(h.server).to.be_nil()
        t.expect(h.forks).to.equal(0)
    end)

    -- 接口存在不等于多数派可用：探针必须真的写一笔、多数派读回、再清理。
    -- 探针失败时不能开监听，也不能白建索引
    t.it("refuses to listen when the majority probe is not confirmed", function()
        local h = harness({ probe_ok = false })
        local ok, err = h.CMD.start()
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("probe majority write not confirmed")
        t.expect(h.probe_calls).to.equal(1)
        t.expect(h.index_calls).to.equal(0)
        t.expect(h.server).to.be_nil()
        t.expect(h.forks).to.equal(0)
    end)

    t.it("refuses to listen when the majority probe raises", function()
        local h = harness()
        h.collection.critical_probe = function()
            error("connection refused")
        end
        local ok, err = h.CMD.start()
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("connection refused")
        t.expect(h.server).to.be_nil()
    end)

    t.it("refuses to listen when the order index gate fails", function()
        local h = harness({ order_index_ok = false })
        local ok, err = h.CMD.start()
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("duplicate key")
        t.expect(h.server).to.be_nil()
        t.expect(h.forks).to.equal(0)
    end)

    t.it("refuses to listen when the reconcile index gate fails", function()
        local h = harness({ reconcile_index_ok = false })
        local ok, err = h.CMD.start()
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("reconcile index failed")
        t.expect(h.server).to.be_nil()
        t.expect(h.forks).to.equal(0)
    end)

    t.it("refuses to listen when a provider module cannot be loaded", function()
        local h = harness()
        h.pay_conf.providers = { broken = { module = "no.such.provider" } }
        local ok, err = h.CMD.start()
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("provider module failed to load")
        t.expect(h.server).to.be_nil()
    end)

    t.it("listens and starts the reconcile loop only after every gate passes", function()
        local h = harness()
        t.expect(h.CMD.start()).to.equal(true)
        t.expect(h.server.params.port).to.equal(18090)
        t.expect(h.server.params.host).to.equal("127.0.0.1")
        t.expect(h.server.router).to.equal("skyext.pay_callback_router")
        t.expect(h.forks).to.equal(1)
        -- 重复 start 是幂等的：不能起第二个监听或第二条对账循环
        local again, reason = h.CMD.start()
        t.expect(again).to.equal(true)
        t.expect(reason).to.equal("already started")
        t.expect(h.forks).to.equal(1)
    end)

    t.it("stop releases the started state", function()
        local h = harness()
        assert(h.CMD.start())
        t.expect(h.CMD.stop()).to.equal(true)
        t.expect(h.CMD.start()).to.equal(true)
    end)
end)
