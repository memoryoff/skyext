-- 关键账本维护服务（P17）：归档热操作记录 + 补建恢复任务。
--
-- 它只做调度：找到需要维护的角色，把短任务交给实际持锁的 owner。
-- 真正的搬运/建任务在 `critical.archive_ops` 与 `critical.reconcile` 里，
-- 且必须在实体队列内执行。
--
-- 配置（节点配置表 `critical_maintenance`）：
--   type_name       实体类型，默认 "role"
--   interval        扫描间隔秒数，默认 60
--   scan_limit      单轮扫描的角色数，默认 32
--   archive_limit   单角色单次搬运的条目数，默认 64
--   retention       保留期秒数，默认 7 天
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local critical = require "skyext.critical"
local critical_maintenance = require "skyext.critical_maintenance"
local log = require "skyext.log"
local mongo_conn = require "skyext.mongo_conn"
local router = require "skyext.entity.router"
local types = require "skyext.entity.types"

local CMD = {}

local g_deps
local g_opts
local g_running = false
local g_stats = { rounds = 0, archived = 0, intents = 0, failed = 0 }

local function settings()
    local conf = config.get_table("critical_maintenance") or {}
    return {
        type_name = conf.type_name or "role",
        interval = conf.interval or critical_maintenance.DEFAULT_INTERVAL,
        scan_limit = conf.scan_limit or critical_maintenance.DEFAULT_SCAN,
        archive_limit = conf.archive_limit or critical.ARCHIVE_LIMIT,
        retention = conf.retention or critical.ARCHIVE_RETENTION,
    }
end

local function call_owner(type_name, rid, cmd, ...)
    local called, ok, result = pcall(router.call, type_name, rid, cmd, ...)
    if not called then
        return false, ok
    end
    if ok ~= true then
        return false, result
    end
    return true, result
end

local function build_deps(opts)
    local tc = types.get(opts.type_name)
    if tc.persistent == false then
        return nil, "ephemeral entity type has no critical ledger"
    end
    if type(tc.db_name) ~= "string" or type(tc.db_coll) ~= "string" then
        return nil, "entity type has no db coordinates"
    end
    return {
        role_coll = mongo_conn.get_collection(tc.db_name, tc.db_coll),
        key = tc.id_field or "rid",
        archive = function(rid, limit)
            return call_owner(opts.type_name, rid, "critical_archive", limit)
        end,
        ensure_job = function(rid, op_id)
            return call_owner(opts.type_name, rid, "critical_ensure_job", op_id)
        end,
    }
end

local function run_loop()
    while g_running do
        local ok, stats, err = pcall(critical_maintenance.run_once, g_deps, g_opts)
        if not ok then
            log.error("critical maintenance raised", "err", tostring(stats))
        elseif not stats then
            log.error("critical maintenance failed", "err", tostring(err))
        else
            g_stats.rounds = g_stats.rounds + 1
            g_stats.archived = g_stats.archived + (stats.archived or 0)
            g_stats.intents = g_stats.intents + (stats.intents or 0)
            g_stats.failed = g_stats.failed + (stats.failed or 0)
            if stats.archived > 0 or stats.intents > 0 or stats.failed > 0 then
                log.info(
                    "critical maintenance round",
                    "archived",
                    stats.archived,
                    "intents",
                    stats.intents,
                    "failed",
                    stats.failed
                )
            end
        end
        skynet.sleep(math.max(1, math.floor(g_opts.interval * 100)))
    end
    log.info("critical maintenance stopped")
end

function CMD.start(conf)
    if g_running then
        return true, "already started"
    end
    g_opts = settings()
    for k, v in pairs(conf or {}) do
        g_opts[k] = v
    end

    local tc = types.get(g_opts.type_name)
    local role = mongo_conn.get_collection(tc.db_name, tc.db_coll)
    local ledger = mongo_conn.get_collection(
        (tc.critical_ledger or {}).db or tc.db_name,
        (tc.critical_ledger or {}).coll or "op_ledger"
    )
    local jobs = mongo_conn.get_collection(
        (tc.critical_jobs or {}).db or tc.db_name,
        (tc.critical_jobs or {}).coll or "critical_reconcile_jobs"
    )
    local indexed, ierr = critical.ensure_indexes({ role = role, ledger = ledger, jobs = jobs })
    if not indexed then
        log.error("critical maintenance not started, index gate failed", "err", tostring(ierr))
        return false, ierr
    end

    local deps, derr = build_deps(g_opts)
    if not deps then
        log.error("critical maintenance not started", "err", derr)
        return false, derr
    end
    g_deps = deps
    g_running = true
    skynet.fork(run_loop)
    log.info(
        "critical maintenance started",
        "type",
        g_opts.type_name,
        "interval",
        g_opts.interval,
        "retention",
        g_opts.retention
    )
    return true
end

function CMD.run_once()
    if not g_deps then
        return false, "not started"
    end
    return pcall(critical_maintenance.run_once, g_deps, g_opts)
end

function CMD.stats()
    return g_stats
end

function CMD.stop()
    g_running = false
    return true
end

skynet.start(function()
    cmd_api.dispatch(CMD)
end)
