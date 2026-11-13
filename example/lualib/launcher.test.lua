-- 关键链路调度器必须由配置显式开启：索引门禁、实体类型配置、支付密钥都还没配好时
-- 静默启动，只会得到一个全表扫描或永远拒绝回调的"看起来在跑"的服务。
local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/lualib/launcher.lua")

local function harness(opts)
    opts = opts or {}
    local h = { services = {}, calls = {}, killed = {}, errors = {}, conf = opts.conf or {} }
    local noop = function() end

    local imports = {
        skynet = {
            newservice = function(name)
                h.services[#h.services + 1] = name
                return ":" .. name
            end,
            uniqueservice = function(name)
                return ":" .. name
            end,
            call = function(addr, proto, cmd, ...)
                h.calls[#h.calls + 1] = { addr = addr, cmd = cmd, args = table.pack(...) }
                if cmd == "create_indexes" then
                    return opts.index_ok ~= false
                end
                if cmd == "start" then
                    if opts.start_raises then
                        error(opts.start_raises, 0)
                    end
                    return opts.start_ok ~= false, opts.start_err
                end
                if cmd == "is_ready" then
                    return opts.ready ~= false
                end
                return true
            end,
            kill = function(addr)
                h.killed[#h.killed + 1] = addr
            end,
            send = noop,
        },
        ["skyext.config"] = {
            get = function(k)
                return h.conf[k]
            end,
            get_number = function(k)
                return h.conf[k]
            end,
            get_table = function(k)
                return h.conf[k]
            end,
        },
        ["skyext.log"] = {
            info = noop,
            warn = noop,
            error = function(...)
                h.errors[#h.errors + 1] = table.pack(...)
            end,
        },
        ["skyext.node_shutdown_api"] = {
            start = function()
                h.shutdown_started = true
                return ":node_shutdown"
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.launcher = assert(loadfile(source, "t", env))()
    return h
end

local function started_optional(h)
    local out = {}
    for _, call in ipairs(h.calls) do
        if call.cmd == "start" then
            out[#out + 1] = call.addr
        end
    end
    return out
end

-- 有效的关键账本/恢复任务集合配置，供启用 critical_maintenance 的用例复用
local function entity_types_with_ledger()
    return {
        role = {
            critical_ledger = { db = "role", coll = "op_ledger" },
            critical_jobs = { db = "role", coll = "critical_reconcile_jobs" },
        },
    }
end

-- 启用却没配关键字段，比"没启用"更难排查：必须在启动那一刻就拦下来，
-- 而不是等服务静默空转、热账本撞上 MAX_OPS 才发现
t.describe("launcher 启动自检", function()
    t.it("keeps the four optional services off by default with zero problems and starts the node", function()
        local h = harness({
            conf = {
                entity_types = entity_types_with_ledger(),
                outbox_worker = { enabled = false },
                critical_maintenance = { enabled = false },
                pay_callback = { enabled = false },
                migration = { enabled = false },
            },
        })
        local report = h.launcher.self_check()
        t.expect(#report.enabled).to.equal(0)
        t.expect(#report.disabled).to.equal(4)
        t.expect(#report.problems).to.equal(0)
        -- 默认配置不能被自检误伤，节点照常起得来
        h.launcher.launcher_node()
        t.expect(#h.errors).to.equal(0)
    end)

    t.it("flags an enabled migration that is missing type_name and adapter", function()
        local h = harness({ conf = { migration = { enabled = true } } })
        local report = h.launcher.self_check()
        t.expect(report.enabled[1]).to.equal("migration")
        t.expect(#report.problems).to.equal(2)
        t.expect(report.problems[1]).to.match("type_name")
        t.expect(report.problems[2]).to.match("adapter")
    end)

    t.it("flags a payment callback enabled without any provider", function()
        local h = harness({ conf = { pay_callback = { enabled = true, role_type = "role", providers = {} } } })
        local report = h.launcher.self_check()
        -- 没配 providers，且它依赖的 critical_maintenance 也没启用
        t.expect(#report.problems).to.equal(3)
        t.expect(report.problems[1]).to.match("providers")
        t.expect(report.problems[2]).to.match("critical_maintenance is not enabled")
        t.expect(report.problems[3]).to.match("role_type role is not configured")
    end)

    t.it("flags a payment callback role_type that is not a persistent configured entity", function()
        local h = harness({
            conf = {
                pay_callback = { enabled = true, role_type = "missing", providers = { "mock" } },
                critical_maintenance = { enabled = true, type_name = "role" },
                entity_types = { role = {} },
            },
        })
        local report = h.launcher.self_check()
        t.expect(#report.problems).to.equal(3)
        t.expect(report.problems[1]).to.match("critical_ledger")
        t.expect(report.problems[2]).to.match("critical_jobs")
        t.expect(report.problems[3]).to.match("missing")
    end)

    t.it("flags critical_maintenance enabled without critical_ledger/critical_jobs", function()
        local h = harness({
            conf = {
                critical_maintenance = { enabled = true, type_name = "role" },
                entity_types = { role = {} },
            },
        })
        local report = h.launcher.self_check()
        t.expect(#report.problems).to.equal(2)
        t.expect(report.problems[1]).to.match("critical_ledger")
        t.expect(report.problems[2]).to.match("critical_jobs")
        -- 错误信息要写明是哪个实体类型
        t.expect(report.problems[1]).to.match("role")
    end)

    t.it("rejects ledger/jobs specs that are not tables or lack db/coll", function()
        local h = harness({
            conf = {
                critical_maintenance = { enabled = true, type_name = "role" },
                entity_types = {
                    role = {
                        critical_ledger = { db = "role" }, -- 缺 coll
                        critical_jobs = "critical_reconcile_jobs", -- 不是表
                    },
                },
            },
        })
        local report = h.launcher.self_check()
        t.expect(#report.problems).to.equal(2)
        t.expect(report.problems[1]).to.match("critical_ledger")
        t.expect(report.problems[2]).to.match("critical_jobs")
    end)

    t.it("flags pay_callback/outbox_worker enabled while critical_maintenance is off", function()
        local h = harness({
            conf = {
                pay_callback = { enabled = true, role_type = "role", providers = { "mock" } },
                outbox_worker = { enabled = true, type_name = "role" },
            },
        })
        local report = h.launcher.self_check()
        t.expect(#report.problems).to.equal(3)
        t.expect(report.problems[1]).to.match("pay_callback is enabled but critical_maintenance is not enabled")
        t.expect(report.problems[2]).to.match("outbox_worker is enabled but critical_maintenance is not enabled")
        t.expect(report.problems[3]).to.match("role_type role is not configured")
    end)

    t.it("does not flag the dependency when critical_maintenance is enabled and configured", function()
        local h = harness({
            conf = {
                entity_types = entity_types_with_ledger(),
                critical_maintenance = { enabled = true, type_name = "role" },
                pay_callback = { enabled = true, role_type = "role", providers = { "mock" } },
                outbox_worker = { enabled = true, type_name = "role" },
            },
        })
        t.expect(#h.launcher.self_check().problems).to.equal(0)
    end)

    t.it("blocks node startup when critical_maintenance is enabled but misconfigured", function()
        local h = harness({
            conf = {
                critical_maintenance = { enabled = true, type_name = "role" },
                entity_types = { role = {} },
            },
        })
        t.expect(#h.launcher.self_check().problems > 0).to.equal(true)
        t.expect(function()
            h.launcher.launcher_node()
        end).to
            .throw("optional services self")
        -- 阻断前每个 problem 都进了启动日志
        t.expect(#h.errors > 0).to.equal(true)
    end)

    t.it("blocks node startup when a critical business runs without maintenance", function()
        local h = harness({
            conf = { pay_callback = { enabled = true, role_type = "role", providers = { "mock" } } },
        })
        t.expect(function()
            h.launcher.launcher_node()
        end).to
            .throw("critical_maintenance is not enabled")
    end)
end)

t.describe("launcher 可选服务接线", function()
    t.it("starts nothing optional without an explicit enable", function()
        local h = harness({ conf = { outbox_worker = { interval = 1 }, pay_callback = { port = 8090 } } })
        h.launcher.launcher_node()
        h.launcher.launch_optional_services()
        t.expect(h.services).to.equal({ "metrics", "gm", "hotfix", "mongo_index" })
        t.expect(started_optional(h)).to.equal({})
        t.expect(h.shutdown_started).to.equal(true)
    end)

    t.it("starts exactly the enabled services, after the base services and index gate", function()
        local h = harness({
            conf = {
                entity_types = entity_types_with_ledger(),
                outbox_worker = { enabled = true, type_name = "role", interval = 5 },
                pay_callback = { enabled = false },
                critical_maintenance = { enabled = true, type_name = "role" },
            },
        })
        h.launcher.launcher_node()
        h.launcher.launch_optional_services()
        t.expect(h.services).to.equal({
            "metrics",
            "gm",
            "hotfix",
            "mongo_index",
            "outbox_worker",
            "critical_maintenance",
        })
        t.expect(started_optional(h)).to.equal({ ":outbox_worker", ":critical_maintenance" })
        -- 配置表原样交给服务自己的 settings/门禁，不能在 launcher 里丢字段
        t.expect(h.calls[#h.calls - 1].args[1].interval).to.equal(5)
    end)

    -- P0-03：依赖实体路由的后台服务不能先于实体系统启动，否则第一轮全部扫不到 owner
    t.it("keeps the optional services out of launcher_node", function()
        local h = harness({
            conf = {
                entity_types = entity_types_with_ledger(),
                outbox_worker = { enabled = true, type_name = "role" },
                critical_maintenance = { enabled = true, type_name = "role" },
                pay_callback = { enabled = true, role_type = "role", providers = { "mock" } },
                migration = { enabled = true, type_name = "role", adapter = "game.migration_adapter" },
            },
        })
        h.launcher.launcher_node()
        t.expect(h.services).to.equal({ "metrics", "gm", "hotfix", "mongo_index" })
        t.expect(started_optional(h)).to.equal({})
    end)

    t.it("brings up every entity type and waits for readiness before returning", function()
        local h = harness({ conf = { gate_port = 9001 } })
        h.launcher.launcher_entities({ "role", "rank" })
        t.expect(h.services).to.equal({ "entity_agentmgr", "entity_agentmgr" })
        local cmds = {}
        for _, call in ipairs(h.calls) do
            cmds[#cmds + 1] = call.cmd
        end
        t.expect(cmds).to.equal({ "start", "is_ready", "start", "is_ready" })
    end)

    -- agentmgr 的 start 失败是抛异常，旧的 `if not ok` 分支永远走不到
    t.it("wraps an agentmgr start exception with the entity type", function()
        local h = harness({ start_raises = "agentmgr boom" })
        t.expect(function()
            h.launcher.launcher_entities({ "role" })
        end).to
            .throw("entity system role failed to start: agentmgr boom")
    end)

    t.it("reports a start that returns false with its reason", function()
        local h = harness({ start_ok = false, start_err = "not started" })
        t.expect(function()
            h.launcher.launcher_entities({ "rank" })
        end).to
            .throw("entity system rank failed to start: not started")
    end)

    t.it("refuses to report an entity system that is not ready", function()
        local h = harness({ ready = false })
        t.expect(function()
            h.launcher.launcher_entities({ "role" })
        end).to
            .throw("entity system role is not ready after start")
    end)

    t.it("refuses to bring the node up when an enabled service fails its index gate", function()
        local h = harness({
            conf = { outbox_worker = { enabled = true } },
            start_ok = false,
            start_err = "index gate failed",
        })
        t.expect(function()
            h.launcher.launch_optional_services()
        end).to
            .throw("index gate failed")
        t.expect(#h.errors > 0).to.equal(true)
    end)

    t.it("can be started on its own without going through launcher_node", function()
        local h = harness({ conf = { migration = { enabled = true } } })
        h.launcher.launch_optional_services()
        t.expect(h.services).to.equal({ "migration_coordinator" })
        t.expect(started_optional(h)).to.equal({ ":migration_coordinator" })
    end)
end)
