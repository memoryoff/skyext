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
local critical_config = require "skyext.critical_config"
local critical_maintenance = require "skyext.critical_maintenance"
local critical_reconciler = require "skyext.critical_reconciler"
local gm_api = require "skyext.gm_api"
local log = require "skyext.log"
local mongo_conn = require "skyext.mongo_conn"
local router = require "skyext.entity.router"
local types = require "skyext.entity.types"

local CMD = {}
local GM_CMD = {}

local g_deps
local g_opts
local g_running = false
local g_stats = { rounds = 0, archived = 0, intents = 0, failed = 0 }

-- 恢复任务执行器：任务表只做调度，证明与资产事实在 owner 实体里
local g_reconcile_deps
local g_reconcile_opts
local g_reconcile_stats =
    { rounds = 0, claimed = 0, committed = 0, not_committed = 0, retry = 0, conflict = 0, failed = 0 }

local function settings()
    local conf = config.get_table("critical_maintenance") or {}
    return {
        type_name = conf.type_name or "role",
        interval = conf.interval or critical_maintenance.DEFAULT_INTERVAL,
        scan_limit = conf.scan_limit or critical_maintenance.DEFAULT_SCAN,
        archive_limit = conf.archive_limit or critical.ARCHIVE_LIMIT,
        retention = conf.retention or critical.ARCHIVE_RETENTION,
        reconcile_scan = conf.reconcile_scan or critical_reconciler.DEFAULT_SCAN,
        reconcile_lease = conf.reconcile_lease or critical_reconciler.DEFAULT_LEASE,
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

        local rok, rstats, rerr = pcall(critical_reconciler.run_once, g_reconcile_deps, g_reconcile_opts)
        if not rok then
            log.error("critical reconciler raised", "err", tostring(rstats))
        elseif not rstats then
            log.error("critical reconciler failed", "err", tostring(rerr))
        else
            g_reconcile_stats.rounds = g_reconcile_stats.rounds + 1
            for _, k in ipairs({ "claimed", "committed", "not_committed", "retry", "conflict", "failed" }) do
                g_reconcile_stats[k] = g_reconcile_stats[k] + (rstats[k] or 0)
            end
            if rstats.claimed > 0 then
                log.info(
                    "critical reconcile round",
                    "claimed",
                    rstats.claimed,
                    "retry",
                    rstats.retry,
                    "failed",
                    rstats.failed
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
    local valid, verr = critical_maintenance.validate_opts(g_opts)
    if not valid then
        log.error("critical maintenance not started, invalid config", "err", verr)
        return false, verr
    end

    local tc = types.get(g_opts.type_name)
    -- 冷账本与恢复任务集合必须显式配置。缺配置时 entity_agent 是 fail-closed
    -- （归档/建任务返回 nil、查证返回 UNKNOWN），维护服务若回退到默认集合名就会
    -- "启动成功但空转"：热账本撞上 MAX_OPS 后新关键操作被拒、UNKNOWN 永不恢复。
    -- 这里 fail-fast，让 launcher 把节点启动拦下来，绝不静默降级。
    local ledger_spec = tc.critical_ledger
    local jobs_spec = tc.critical_jobs
    local config_ok, config_err = critical_config.validate_entity_config(tc)
    local invalid = not config_ok and config_err or nil
    if invalid then
        local msg = string.format("entity type %s has invalid critical config: %s", tostring(g_opts.type_name), invalid)
        log.error("critical maintenance not started", "err", msg)
        return false, msg
    end

    local role = mongo_conn.get_collection(tc.db_name, tc.db_coll)
    local ledger = mongo_conn.get_collection(ledger_spec.db, ledger_spec.coll)
    local jobs = mongo_conn.get_collection(jobs_spec.db, jobs_spec.coll)
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
    -- 两组扫描各自的轮转游标：归档游标按“跳过的候选数”推进，意图游标按 rid
    -- keyset 推进；都放在 deps 上，跨 run_once 调用保留
    g_deps.intent_cursor = nil

    -- 恢复任务执行器：抢占走 claim_job 的 (job_version, lease_until) CAS；
    -- 证明必须经 owner 实体队列（critical_resolve_intent），那里已完成 Fence 认领。
    -- 任务表只负责调度，资产事实永远取角色文档
    g_reconcile_deps = {
        jobs_coll = jobs,
        -- keyset 游标由 run_once 维护：(rid, op_id)，首轮为 nil 表示从头扫
        scan_cursor = nil,
        claim = function(rid, op_id, owner, lease_until, version)
            return critical.claim_job(jobs, rid, op_id, owner, lease_until, {
                job_version = version,
                now = os.time(),
            })
        end,
        resolve = function(rid, op_id)
            local ok, result = call_owner(g_opts.type_name, rid, "critical_resolve_intent", op_id)
            if not ok or type(result) ~= "table" then
                return { status = "UNKNOWN", reason = tostring(result) }
            end
            if result.discard == true then
                -- 意图已确认取消（或已提交），但内存可能带着 apply 的痕迹。
                -- 卸载实体让下一次请求从库重读——不这么做，被污染的副本会继续服务
                -- 到 idle 超时，而且隔离态下普通回存是停的。
                -- 必须走裸命令：entity_call 解析不到 unload_entity，且会重入 gate
                local called, unloaded, uerr = pcall(router.unload_entity, g_opts.type_name, rid)
                if not called then
                    log.warn(
                        "critical resolve could not unload the entity",
                        "rid",
                        tostring(rid),
                        "err",
                        tostring(unloaded)
                    )
                elseif unloaded ~= true then
                    log.warn("critical resolve unload was refused", "rid", tostring(rid), "err", tostring(uerr))
                end
                if not called or unloaded ~= true then
                    return { status = "UNKNOWN", reason = "unload failed: " .. tostring(called and uerr or unloaded) }
                end
            end
            return result
        end,
        finish = function(rid, op_id, version, state)
            return critical.finish_job(jobs, rid, op_id, version, state, { now = os.time() })
        end,
    }
    g_reconcile_opts = {
        owner = "critical_maintenance:" .. skynet.self(),
        scan_limit = g_opts.reconcile_scan,
        lease = g_opts.reconcile_lease,
    }

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

-- 手动推进一轮恢复任务，供运维与集成测试使用；不提供强制完成/清除隔离
function CMD.reconcile_once()
    if not g_reconcile_deps then
        return false, "not started"
    end
    return pcall(critical_reconciler.run_once, g_reconcile_deps, g_reconcile_opts)
end

function CMD.stats()
    local out = {}
    for k, v in pairs(g_stats) do
        out[k] = v
    end
    out.reconcile = g_reconcile_stats
    return out
end

function CMD.stop()
    g_running = false
    return true
end

-- 多数派探针的运维入口。探针本身在 mongo_conn（那里才持有连接），这里只负责
-- 把"哪个实体类型的库"翻译成集合，并把失败原因原样带回。
--
-- 为什么需要这个入口：`critical_probe` 是真探针（真写 + 多数派读回 + 清理），
-- 但在接上 GM 之前没有任何调用点，运维只能靠手册里的代码片段，等于没接。
GM_CMD.critical_probe = {
    desc = "跑一次多数派探针：真实 w:majority+j 写入 -> 多数派读回 -> 清理",
    params = {
        type_name = "实体类型（可选，默认 critical_maintenance.type_name）",
    },
    handler = function(params)
        local type_name = (type(params) == "table" and params.type_name) or settings().type_name
        local called, tc = pcall(types.get, type_name)
        if not called then
            return false, tostring(tc)
        end
        if type(tc.db_name) ~= "string" or type(tc.db_coll) ~= "string" then
            return false, "entity type has no db coordinates: " .. tostring(type_name)
        end
        local coll_called, coll = pcall(mongo_conn.get_collection, tc.db_name, tc.db_coll)
        if not coll_called then
            return false, tostring(coll)
        end
        return critical_maintenance.probe({
            collection = coll,
            type_name = type_name,
            collection_name = tc.db_name .. "." .. tc.db_coll,
        })
    end,
}

skynet.start(function()
    cmd_api.dispatch(CMD)
    -- 注册失败不该拖垮服务：没有 GM 只是少了运维入口，账本维护本身照常跑
    local ok, err = pcall(gm_api.register, GM_CMD)
    if not ok then
        log.warn("critical maintenance GM registration failed", "err", tostring(err))
    end
end)
