local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/critical_maintenance.lua")

local function harness(type_config)
    local h = { type_config = type_config, collections = 0, registered = false }
    local noop = function() end
    local imports = {
        skynet = {
            start = function(fn)
                h.start_fn = fn
            end,
            self = function()
                return 1
            end,
            sleep = noop,
            fork = noop,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(cmd)
                h.CMD = cmd
            end,
        },
        ["skyext.config"] = {
            get_table = function()
                return { enabled = true, type_name = "role" }
            end,
        },
        ["skyext.critical"] = {
            ARCHIVE_RETENTION = 7 * 24 * 3600,
            ARCHIVE_LIMIT = 64,
            ensure_indexes = function()
                error("invalid config must fail before the index gate")
            end,
        },
        ["skyext.critical_maintenance"] = {
            DEFAULT_INTERVAL = 60,
            DEFAULT_SCAN = 32,
        },
        ["skyext.critical_reconciler"] = {
            DEFAULT_SCAN = 16,
            DEFAULT_LEASE = 30,
        },
        ["skyext.gm_api"] = {
            register = function()
                h.registered = true
            end,
        },
        ["skyext.log"] = {
            info = noop,
            warn = noop,
            error = noop,
        },
        ["skyext.metrics"] = {
            counter = function()
                return { inc = noop }
            end,
        },
        ["skyext.mongo_conn"] = {
            get_collection = function()
                h.collections = h.collections + 1
                return {}
            end,
        },
        ["skyext.entity.router"] = {},
        ["skyext.entity.types"] = {
            get = function()
                return h.type_config
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.service = assert(loadfile(source, "t", env))()
    assert(h.start_fn)()
    return h
end

t.describe("critical maintenance startup gate", function()
    t.it("rejects missing ledger/jobs before opening collections or indexes", function()
        local h = harness({ db_name = "role", db_coll = "role" })
        local ok, err = h.CMD.start({})
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("critical_ledger")
        t.expect(h.collections).to.equal(0)
    end)

    t.it("rejects ledger/jobs collection reuse", function()
        local same = { db = "role", coll = "critical" }
        local h = harness({
            db_name = "role",
            db_coll = "role",
            critical_ledger = same,
            critical_jobs = same,
        })
        local ok, err = h.CMD.start({})
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("different collections")
        t.expect(h.collections).to.equal(0)
    end)
end)
