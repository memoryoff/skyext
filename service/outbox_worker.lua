-- Outbox 调度服务（P13）。
--
-- 单节点起一份即可，但多节点同时起也安全：状态 CAS 带 fence 与 `status=PENDING`
-- 条件，重复投递只会产生重复的可靠消息，业务效果由接收方的 `service_op_id` 去重。
--
-- 启动顺序上的硬要求：**先确认索引建起来**。没有 `_critical_outbox_pending_count`
-- 的偏索引，每轮扫描都是全表扫描，角色表一大就把 Mongo 打满。
--
-- 配置（节点配置表 `outbox_worker`，全部可选）：
--   type_name   要调度的实体类型，默认 "role"
--   interval    扫描间隔秒数，默认 5
--   scan_limit  单轮扫描的角色数，默认 64
--   batch       单个角色单次投递的事件数，默认 16
--   max_loads   单轮最多为多少个离线角色加载实体，默认 8
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local log = require "skyext.log"
local mongo_conn = require "skyext.mongo_conn"
local outbox_worker = require "skyext.outbox_worker"
local router = require "skyext.entity.router"
local types = require "skyext.entity.types"

local CMD = {}

local g_deps
local g_opts
local g_stopped = false
local g_stats = { rounds = 0, enqueued = 0, failed = 0, unknown = 0, skipped = 0 }

local function settings()
    local conf = config.get_table("outbox_worker") or {}
    return {
        type_name = conf.type_name or "role",
        interval = conf.interval or outbox_worker.DEFAULT_INTERVAL,
        scan_limit = conf.scan_limit or outbox_worker.DEFAULT_SCAN,
        limit = conf.batch or outbox_worker.DEFAULT_BATCH,
        max_loads = conf.max_loads or outbox_worker.DEFAULT_MAX_LOADS,
    }
end

-- 只对已加载实体投递；实体不在内存时返回 false，由调度器决定是否受控加载。
-- router.call_loaded 的返回值是 (true, stats) 或 (false, NOT_LOADED)，pcall 会
-- 在前面多插一个 true，这里必须按三个返回值取，否则会把 stats 当成"已加载"标志
local function pump_loaded_only(type_name)
    return function(rid, limit)
        local called, ok, result = pcall(router.call_loaded, type_name, rid, "outbox_pump", limit)
        if not called then
            return false, ok
        end
        if ok ~= true or type(result) ~= "table" then
            return false, result
        end
        return true, result
    end
end

local function pump_with_load(type_name)
    return function(rid, limit)
        local called, ok, result = pcall(router.call, type_name, rid, "outbox_pump", limit)
        if not called then
            return false, ok
        end
        if ok ~= true or type(result) ~= "table" then
            return false, result
        end
        return true, result
    end
end

local function build_deps(opts)
    local tc = types.get(opts.type_name)
    if tc.persistent == false then
        return nil, "ephemeral entity type has no outbox"
    end
    if type(tc.db_name) ~= "string" or type(tc.db_coll) ~= "string" then
        return nil, "entity type has no db coordinates"
    end
    return {
        type_name = opts.type_name,
        role_coll = mongo_conn.get_collection(tc.db_name, tc.db_coll),
        key = tc.id_field or "rid",
        -- keyset 游标由 run_once 维护：上一页最后一个 rid，首轮 nil 表示从队头开始
        cursor = nil,
        pump = pump_loaded_only(opts.type_name),
        pump_loaded = pump_with_load(opts.type_name),
        sleep = function(sec)
            skynet.sleep(math.max(1, math.floor(sec * 100)))
        end,
    }
end

local function accumulate(stats)
    if type(stats) ~= "table" then
        return
    end
    g_stats.rounds = g_stats.rounds + 1
    g_stats.enqueued = g_stats.enqueued + (stats.enqueued or 0)
    g_stats.failed = g_stats.failed + (stats.failed or 0)
    g_stats.unknown = g_stats.unknown + (stats.unknown or 0)
    g_stats.skipped = g_stats.skipped + (stats.skipped or 0)
end

local function run_loop()
    while not g_stopped do
        local ok, stats, err = pcall(outbox_worker.run_once, g_deps, g_opts)
        if not ok then
            log.error("outbox round raised", "err", stats)
        elseif not stats then
            log.error("outbox round failed", "err", tostring(err))
        else
            accumulate(stats)
        end
        skynet.sleep(math.max(1, math.floor(g_opts.interval * 100)))
    end
    log.info("outbox worker stopped")
end

-- 手动跑一轮（运维排查用），返回本轮统计
function CMD.run_once()
    if not g_deps then
        return false, "not started"
    end
    local ok, stats = pcall(outbox_worker.run_once, g_deps, g_opts)
    if not ok then
        return false, stats
    end
    accumulate(stats)
    return true, stats
end

function CMD.stats()
    return g_stats
end

function CMD.stop()
    g_stopped = true
    return true
end

function CMD.start(conf)
    if g_deps then
        return true, "already started"
    end
    g_opts = settings()
    for k, v in pairs(conf or {}) do
        g_opts[k] = v
    end

    local tc = types.get(g_opts.type_name)
    local colls = { role = mongo_conn.get_collection(tc.db_name, tc.db_coll) }
    local indexed, ierr = outbox_worker.ensure_indexes(colls)
    if not indexed then
        -- 索引门禁：宁可不启动调度，也不要用全表扫描拖垮数据库
        log.error("outbox worker not started, index gate failed", "err", tostring(ierr))
        return false, ierr
    end

    local deps, derr = build_deps(g_opts)
    if not deps then
        log.error("outbox worker not started", "err", derr)
        return false, derr
    end
    g_deps = deps
    g_stopped = false
    skynet.fork(run_loop)
    log.info(
        "outbox worker started",
        "type",
        g_opts.type_name,
        "interval",
        g_opts.interval,
        "scan_limit",
        g_opts.scan_limit
    )
    return true
end

skynet.start(function()
    cmd_api.dispatch(CMD)
end)
