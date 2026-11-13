-- 迁移协调器必须真的注册停服钩子，并且在适配器不完整时**拒绝启动**：
-- 配置了 migration.enabled 却没有可用适配器，唯一安全的结果是节点起不来，
-- 而不是停服时拿一个空实体列表宣称"迁移完成"。
local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/migration_coordinator.lua")

local function stage_adapter()
    local function stage()
        return function()
            return true
        end
    end
    return {
        list_entities = function()
            return { { id = 7 } }
        end,
        quiesce = stage(),
        freeze = stage(),
        export = stage(),
        transfer = stage(),
        handoff = stage(),
        activate = stage(),
        fallback = stage(),
    }
end

local function harness(opts)
    opts = opts or {}
    local h = { hooks = {}, run_calls = {}, errors = {}, inits = {} }
    local noop = function() end

    local imports = {
        skynet = {
            start = function(fn)
                h.start_fn = fn
            end,
            self = function()
                return 99
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(cmd)
                h.CMD = cmd
            end,
        },
        ["skyext.log"] = {
            info = noop,
            warn = noop,
            error = function(...)
                h.errors[#h.errors + 1] = table.pack(...)
            end,
        },
        ["skyext.metrics"] = {
            counter = function()
                return { inc = noop }
            end,
        },
        ["skyext.migration"] = {
            run = function(deps, run_opts)
                h.run_calls[#h.run_calls + 1] = { deps = deps, opts = run_opts }
                if opts.on_run then
                    opts.on_run(h, deps, run_opts)
                end
                if opts.run_result ~= nil then
                    return table.unpack(opts.run_result, 1, opts.run_result.n or #opts.run_result)
                end
                return { total = 1, ready = 1 }
            end,
        },
        ["skyext.node_shutdown_api"] = {
            add_hook = function(phase, cmd)
                if opts.hook_fails then
                    error("node_shutdown is not running")
                end
                h.hooks[#h.hooks + 1] = { phase = phase, cmd = cmd, addr = 99 }
                return true
            end,
        },
    }
    local modules = opts.modules or {}
    local env = setmetatable({
        require = function(name)
            if modules[name] ~= nil then
                if type(modules[name]) == "string" then
                    error(modules[name])
                end
                return modules[name]
            end
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.service = assert(loadfile(source, "t", env))()
    assert(h.start_fn)()
    return h
end

local function enabled_conf(extra)
    local conf = { enabled = true, type_name = "role" }
    for k, v in pairs(extra or {}) do
        conf[k] = v
    end
    return conf
end

t.describe("migration_coordinator 启动门禁", function()
    t.it("does not register the shutdown hook before start succeeds", function()
        local h = harness()
        t.expect(#h.hooks).to.equal(0)
        t.expect(h.CMD.start ~= nil).to.equal(true)
    end)

    t.it("refuses to start when migration is enabled without an adapter module", function()
        local h = harness()
        local ok, err = h.CMD.start(enabled_conf())
        t.expect(ok).to.equal(false)
        t.expect(err:find("migration.adapter", 1, true) ~= nil).to.equal(true)
        t.expect(#h.hooks).to.equal(0)
        t.expect(h.CMD.stats().installed).to.equal(false)
    end)

    t.it("refuses to start when the adapter module cannot be loaded", function()
        local h = harness({ modules = { ["game.migration_adapter"] = "module not found" } })
        local ok, err = h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" }))
        t.expect(ok).to.equal(false)
        t.expect(err:find("cannot load migration adapter", 1, true) ~= nil).to.equal(true)
    end)

    t.it("refuses to start when a required stage is missing", function()
        local adapter = stage_adapter()
        adapter.handoff = nil
        local h = harness({ modules = { ["game.migration_adapter"] = adapter } })
        local ok, err = h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" }))
        t.expect(ok).to.equal(false)
        t.expect(err:find("handoff", 1, true) ~= nil).to.equal(true)
        t.expect(#h.hooks).to.equal(0)
    end)

    t.it("refuses to start without the failure fallback", function()
        local adapter = stage_adapter()
        adapter.fallback = nil
        local h = harness({ modules = { ["game.migration_adapter"] = adapter } })
        local ok, err = h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" }))
        t.expect(ok).to.equal(false)
        t.expect(err:find("fallback", 1, true) ~= nil).to.equal(true)
        t.expect(#h.hooks).to.equal(0)
    end)

    t.it("refuses to start when the hook cannot be registered", function()
        local h = harness({
            hook_fails = true,
            modules = { ["game.migration_adapter"] = stage_adapter() },
        })
        local ok, err = h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" }))
        t.expect(ok).to.equal(false)
        t.expect(err:find("migrate shutdown hook", 1, true) ~= nil).to.equal(true)
        t.expect(h.CMD.stats().installed).to.equal(false)
    end)

    t.it("refuses a config that does not enable migration", function()
        local h = harness({ modules = { ["game.migration_adapter"] = stage_adapter() } })
        local ok, err = h.CMD.start({ enabled = false, adapter = "game.migration_adapter" })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("migration is not enabled")
    end)
end)

t.describe("migration_coordinator 运行", function()
    t.it("registers the migrate hook and reports readiness on start", function()
        local adapter = stage_adapter()
        local h = harness({ modules = { ["game.migration_adapter"] = adapter } })
        local ok, err = h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" }))
        t.expect(err).to.be_nil()
        t.expect(ok).to.equal(true)
        t.expect(h.hooks).to.equal({ { phase = "migrate", cmd = "run", addr = 99 } })
        local stats = h.CMD.stats()
        t.expect(stats.installed).to.equal(true)
        t.expect(stats.type_name).to.equal("role")
    end)

    t.it("calls adapter.init with the service config", function()
        local adapter = stage_adapter()
        adapter.init = function(conf)
            adapter.init_conf = conf
        end
        local h = harness({ modules = { ["game.migration_adapter"] = adapter } })
        assert(h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" })))
        t.expect(adapter.init_conf.type_name).to.equal("role")
    end)

    t.it("accepts an injected adapter table and passes every stage through", function()
        local h = harness()
        local calls = {}
        local function stage(name)
            return function()
                calls[#calls + 1] = name
                return true
            end
        end
        local adapter = stage_adapter()
        for _, name in ipairs({ "quiesce", "freeze", "export", "transfer", "handoff", "activate" }) do
            adapter[name] = stage(name)
        end
        adapter.fallback = stage("fallback")
        adapter.probe = function()
            return true
        end
        assert(h.CMD.set_adapter(adapter))
        assert(h.CMD.start(enabled_conf()))

        local ok = h.CMD.run({ barrier_id = "b1" })
        t.expect(ok).to.equal(true)
        local deps = h.run_calls[1].deps
        for _, name in ipairs({ "quiesce", "freeze", "export", "transfer", "handoff", "activate", "fallback" }) do
            t.expect(deps[name]("e")).to.equal(true)
        end
        -- BUSY 的限时等待依赖 probe，漏传会让所有忙碌实体直接降级
        t.expect(deps.probe("e")).to.equal(true)
        t.expect(h.run_calls[1].opts.barrier_id).to.equal("b1")
        t.expect(#calls).to.equal(7)
    end)

    t.it("fails closed when run is called before start", function()
        local h = harness()
        local ok, err = h.CMD.run({})
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("migration coordinator is not started")
        t.expect(#h.run_calls).to.equal(0)
        t.expect(#h.errors > 0).to.equal(true)
    end)

    t.it("reports failure instead of claiming a successful migration", function()
        local h = harness({
            run_result = { n = 2, nil, "boom" },
            modules = { ["game.migration_adapter"] = stage_adapter() },
        })
        assert(h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" })))
        local ok, err = h.CMD.run({})
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("boom")
        t.expect(#h.errors > 0).to.equal(true)
    end)

    t.it("rejects a non-table adapter", function()
        local h = harness()
        local ok, err = h.CMD.set_adapter("adapter")
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("adapter must be a table")
    end)

    -- 两个迁移轮次并发会互相复位 g_cancelled / begin_round 状态，必须显式拒绝
    t.it("refuses a second run while a round is still running", function()
        local second
        local h = harness({
            modules = { ["game.migration_adapter"] = stage_adapter() },
            on_run = function(handle)
                second = { handle.CMD.run({ nested = true }) }
            end,
        })
        assert(h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" })))
        local ok, stats = h.CMD.run({})
        t.expect(ok).to.equal(true)
        t.expect(type(stats)).to.equal("table")
        t.expect(second[1]).to.equal(false)
        t.expect(second[2]).to.equal("migration round is already running")
        t.expect(#h.run_calls).to.equal(1)
    end)
end)

-- 停服截止时间到达后，node_shutdown 会给本服务发 cancel；令牌必须真的传到
-- 正在跑的那一轮里，否则迁移协程会和卸载并行
t.describe("migration_coordinator 取消", function()
    t.it("exposes a cancellation token to the running round", function()
        local h = harness({ modules = { ["game.migration_adapter"] = stage_adapter() } })
        assert(h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" })))
        assert(h.CMD.run({}))

        local opts = h.run_calls[1].opts
        t.expect(opts.is_cancelled()).to.equal(false)

        assert(h.CMD.cancel("shutdown deadline"))
        t.expect(opts.is_cancelled()).to.equal(true)
        t.expect(h.CMD.stats().cancelled).to.equal(true)
    end)

    -- 上一轮的取消不能把下一轮直接掐死
    t.it("starts the next round uncancelled", function()
        local h = harness({ modules = { ["game.migration_adapter"] = stage_adapter() } })
        assert(h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" })))
        assert(h.CMD.run({}))
        assert(h.CMD.cancel("deadline"))

        assert(h.CMD.run({}))
        t.expect(h.run_calls[2].opts.is_cancelled()).to.equal(false)
        t.expect(h.CMD.stats().cancelled).to.equal(false)
    end)

    -- 只置标志救不了卡在长 RPC 里的实体：取消时必须让适配器解掉网关屏障
    t.it("runs the adapter abort cleanup and exposes it in stats", function()
        local adapter = stage_adapter()
        local aborts, rounds = {}, 0
        adapter.abort = function(reason)
            aborts[#aborts + 1] = reason
            return { kicked = 2, failed = 0 }
        end
        adapter.begin_round = function()
            rounds = rounds + 1
        end
        local h = harness({ modules = { ["game.migration_adapter"] = adapter } })
        assert(h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" })))
        assert(h.CMD.run({}))
        t.expect(rounds).to.equal(1)
        assert(h.CMD.cancel("shutdown deadline"))
        t.expect(#aborts).to.equal(1)
        t.expect(h.CMD.stats().abort.kicked).to.equal(2)
        -- 重复 cancel 幂等，不能踢两遍
        assert(h.CMD.cancel("shutdown deadline"))
        t.expect(#aborts).to.equal(1)
    end)

    t.it("keeps running when the adapter has no abort hook", function()
        local h = harness({ modules = { ["game.migration_adapter"] = stage_adapter() } })
        assert(h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" })))
        assert(h.CMD.cancel("shutdown deadline"))
        t.expect(h.CMD.stats().cancelled).to.equal(true)
        t.expect(h.CMD.stats().abort).to.be_nil()
    end)

    t.it("retries abort while unresolved barriers remain", function()
        local adapter = stage_adapter()
        local pending = 1
        local aborts = 0
        adapter.pending_count = function()
            return pending
        end
        adapter.abort = function()
            aborts = aborts + 1
            if aborts > 1 then
                pending = 0
            end
            return { kicked = 1, failed = 0, pending = pending }
        end
        local h = harness({ modules = { ["game.migration_adapter"] = adapter } })
        assert(h.CMD.start(enabled_conf({ adapter = "game.migration_adapter" })))
        assert(h.CMD.run({}))
        assert(h.CMD.cancel("deadline"))
        t.expect(aborts).to.equal(1)
        t.expect(h.CMD.stats().abort_pending).to.equal(1)
        -- 还有未解决屏障：第二次 cancel 必须重试 abort
        assert(h.CMD.cancel("deadline"))
        t.expect(aborts).to.equal(2)
        t.expect(h.CMD.stats().abort_pending).to.equal(0)
        -- 清理完成后再 cancel 不重复 abort
        assert(h.CMD.cancel("deadline"))
        t.expect(aborts).to.equal(2)
    end)
end)
