-- 配置层的契约：节点只写要覆盖的字段，common.app.lua 必须补齐其余默认值。
-- 用 `x = x or {...}` 整表替换时，运维写 migration = { enabled = true } 会把
-- adapter / type_name / concurrency 全丢掉，CMD.start 直接拒绝、节点起不来。
local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/etc/nodes/common.app.lua")

local function load_conf(preset)
    local env = setmetatable({}, { __index = _G })
    for k, v in pairs(preset or {}) do
        env[k] = v
    end
    assert(loadfile(source, "t", env))()
    return env
end

t.describe("common.app 可选服务默认值合并", function()
    t.it("keeps migration defaults when a node only enables it", function()
        local conf = load_conf({ migration = { enabled = true } })
        t.expect(conf.migration.enabled).to.equal(true)
        t.expect(conf.migration.adapter).to.equal("migration_adapter")
        t.expect(conf.migration.type_name).to.equal("role")
        t.expect(conf.migration.concurrency).to.equal(4)
    end)

    t.it("lets a node override individual fields without losing the others", function()
        local conf = load_conf({ migration = { enabled = true, concurrency = 8 } })
        t.expect(conf.migration.concurrency).to.equal(8)
        t.expect(conf.migration.adapter).to.equal("migration_adapter")
    end)

    t.it("keeps every optional service disabled by default", function()
        local conf = load_conf()
        t.expect(conf.migration.enabled).to.equal(false)
        t.expect(conf.outbox_worker.enabled).to.equal(false)
        t.expect(conf.critical_maintenance.enabled).to.equal(false)
        t.expect(conf.pay_callback.enabled).to.equal(false)
        t.expect(conf.outbox_worker.interval).to.equal(5)
        t.expect(conf.pay_callback.port).to.equal(8090)
    end)

    t.it("merges other services field by field too", function()
        local conf = load_conf({ outbox_worker = { enabled = true, interval = 1 } })
        t.expect(conf.outbox_worker.enabled).to.equal(true)
        t.expect(conf.outbox_worker.interval).to.equal(1)
        t.expect(conf.outbox_worker.type_name).to.equal("role")
        t.expect(conf.outbox_worker.batch).to.equal(16)
    end)

    -- 嵌套表也要合并，不能整表替换。运维写 pay_callback = { orders = { db = "role2" } }
    -- 若整表替换，coll 就没了，服务会静默回退到默认集合名——订单写进另一个集合，
    -- 这类错配在支付链路上很难事后发现
    t.it("merges nested tables instead of replacing them", function()
        local conf = load_conf({ pay_callback = { enabled = true, orders = { db = "role2" } } })
        t.expect(conf.pay_callback.enabled).to.equal(true)
        t.expect(conf.pay_callback.orders.db).to.equal("role2")
        -- 默认的 coll 必须还在，否则订单会落到别的集合
        t.expect(conf.pay_callback.orders.coll).to.equal("charge_order")
        -- 同层其它默认值也不能丢
        t.expect(conf.pay_callback.port).to.equal(8090)
        t.expect(conf.pay_callback.role_type).to.equal("role")
    end)

    -- 默认值不能被多个节点共享引用：一个节点改了嵌套字段，另一个节点会跟着变
    t.it("does not share nested default tables between loads", function()
        local a = load_conf({ pay_callback = { enabled = true, orders = { db = "role2" } } })
        local b = load_conf()
        t.expect(b.pay_callback.orders.db).to.equal("role")
        a.pay_callback.orders.db = "mutated"
        t.expect(b.pay_callback.orders.db).to.equal("role")
    end)
end)
