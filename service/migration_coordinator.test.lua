-- 迁移协调器必须真的注册停服钩子，并且在没注入适配器时明确退化为普通卸载，
-- 而不是让运维以为"开了无感迁移"。
local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/migration_coordinator.lua")

local function harness(opts)
    opts = opts or {}
    local h = { hooks = {}, run_calls = {}, errors = {} }
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
        ["skyext.migration"] = {
            run = function(deps, run_opts)
                h.run_calls[#h.run_calls + 1] = { deps = deps, opts = run_opts }
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
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.service = assert(loadfile(source, "t", env))()
    if not opts.skip_start then
        assert(h.start_fn)()
    end
    return h
end

t.describe("migration_coordinator", function()
    t.it("registers the migrate phase on the shutdown orchestrator", function()
        local h = harness()
        t.expect(h.hooks).to.equal({ { phase = "migrate", cmd = "run", addr = 99 } })
        t.expect(h.CMD.run ~= nil).to.equal(true)
    end)

    t.it("degrades to an empty entity list when no adapter is injected", function()
        local h = harness()
        local ok, stats = h.CMD.run({})
        t.expect(ok).to.equal(true)
        t.expect(stats.total).to.equal(1)
        t.expect(type(h.run_calls[1].deps.list_entities)).to.equal("function")
        t.expect(#h.run_calls[1].deps.list_entities()).to.equal(0)
    end)

    t.it("passes every adapter stage through to migration.run", function()
        local h = harness()
        local calls = {}
        local function stage(name)
            return function(entity)
                calls[#calls + 1] = name
                return true
            end
        end
        assert(h.CMD.set_adapter({
            list_entities = function()
                return { { id = 7 } }
            end,
            quiesce = stage("quiesce"),
            freeze = stage("freeze"),
            export = stage("export"),
            transfer = stage("transfer"),
            handoff = stage("handoff"),
            activate = stage("activate"),
            fallback = stage("fallback"),
        }))
        local ok = h.CMD.run({ barrier_id = "b1" })
        t.expect(ok).to.equal(true)
        local deps = h.run_calls[1].deps
        for _, name in ipairs({ "quiesce", "freeze", "export", "transfer", "handoff", "activate", "fallback" }) do
            t.expect(deps[name]("e")).to.equal(true)
        end
        t.expect(calls).to.equal({ "quiesce", "freeze", "export", "transfer", "handoff", "activate", "fallback" })
        t.expect(h.run_calls[1].opts.barrier_id).to.equal("b1")
    end)

    t.it("reports failure instead of claiming a successful migration", function()
        local h = harness({ run_result = { n = 2, nil, "boom" } })
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

    t.it("logs when the shutdown hook cannot be registered", function()
        local h = harness({ hook_fails = true })
        t.expect(#h.hooks).to.equal(0)
        t.expect(#h.errors > 0).to.equal(true)
    end)
end)
