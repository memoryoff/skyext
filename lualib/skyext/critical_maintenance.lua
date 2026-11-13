-- 关键账本的维护扫描（P17 / P08 恢复扫描）。
--
-- 两件事：
--   1. **归档**：把超过保留期的已结算操作从角色文档搬到 `op_ledger`，
--      否则 `_critical_ops_v1` 会一直涨到撞上 512 KiB 的关键字段预算；
--   2. **补建恢复任务**：扫出还挂着 `_critical_intent_v1.state = PREPARED` 的角色，
--      确保 `critical_reconcile_jobs` 里有对应任务。角色文档仍是资产事实，
--      任务表只负责"别让它被忘掉"。
--
-- 两条扫描都走索引（`critical_ops_oldest` / `critical_intent_state`）。没有索引时
-- 每轮都是全表扫描，所以 `ensure_indexes` 是启用门禁。
--
-- 与 `critical` 的分工：本模块只负责"找到谁需要维护"，真正的搬运与 CAS 在
-- `critical.archive_ops` 里，并且必须经 owner 的实体队列执行。
local critical = require "skyext.critical"
local log = require "skyext.log"
local metrics = require "skyext.metrics"

local M = {}

M.DEFAULT_SCAN = 32
M.DEFAULT_INTERVAL = 60

local m_archive = metrics.counter("skyext_critical_maintenance_total", "Maintenance rounds by task", { "task" })
local m_candidates =
    metrics.gauge("skyext_critical_maintenance_candidates", "Candidates found by the last maintenance scan", { "task" })
-- 归档滞后：最老候选**超过保留期之后**又等了多久。候选本身必然已超保留期，
-- 直接记 now - oldest 会恒定 >= retention 并在 0 与 7 天间跳变。
-- 减去保留期后正常归档约等于 0，只有吞吐跟不上才持续上涨。
local m_archive_lag = metrics.gauge(
    "skyext_critical_archive_lag_seconds",
    "Extra delay past the retention window for the oldest op waiting to be archived",
    { "task" }
)
-- PREPARED 意图挂了多久：这是恢复任务队列年龄的直接观测值。
-- 只靠任务表逐条查看不到趋势，堆积只能靠日志猜。
local m_prepared_age = metrics.histogram(
    "skyext_critical_prepared_seconds",
    "Age of a PREPARED intent observed by maintenance",
    { "task" }
)

-- 归档滞后 = 超过保留期之后又等了多久。候选必然已经超期，所以不能直接用
-- now - oldest（那会恒 >= retention，指标在 0 与 7 天之间跳变）。
-- 抽成纯函数便于断言口径，正常归档约等于 0，吞吐跟不上才持续上涨。
function M.archive_lag(oldest, now, retention)
    return math.max(0, now - oldest - retention)
end

-- 归档候选：热账本最老条目已经超过保留期
function M.scan_archive(role_coll, opts)
    opts = opts or {}
    if type(role_coll) ~= "table" then
        return nil, "role collection is required"
    end
    local key = opts.key or "rid"
    local called, docs, err = pcall(role_coll.find_many, role_coll, critical.archive_query(opts.now, opts.retention), {
        projection = { [key] = 1, [critical.OPS_OLDEST_FIELD] = 1, _id = 0 },
        limit = opts.limit or M.DEFAULT_SCAN,
        -- 轮转：卡住的文档不会离开候选集，不 skip 的话它会永远占住前 N 个名额，
        -- 后面的角色一个都排不进来
        skip = opts.skip or 0,
    })
    if not called then
        return nil, "scan failed: " .. tostring(docs)
    end
    if type(docs) ~= "table" then
        return nil, tostring(err or "scan failed")
    end
    local list = {}
    for _, doc in ipairs(docs) do
        if type(doc) == "table" and doc[key] ~= nil then
            list[#list + 1] = { rid = doc[key], oldest = doc[critical.OPS_OLDEST_FIELD] }
        end
    end
    return list
end

-- 未决意图候选：PREPARED 但可能没有对应任务
function M.scan_intents(role_coll, opts)
    opts = opts or {}
    if type(role_coll) ~= "table" then
        return nil, "role collection is required"
    end
    local key = opts.key or "rid"
    local called, docs, err = pcall(role_coll.find_many, role_coll, {
        [critical.INTENT_FIELD .. ".state"] = "PREPARED",
    }, {
        projection = {
            [key] = 1,
            [critical.INTENT_FIELD .. ".op_id"] = 1,
            [critical.INTENT_FIELD .. ".prepared_at"] = 1,
            _id = 0,
        },
        limit = opts.limit or M.DEFAULT_SCAN,
    })
    if not called then
        return nil, "scan failed: " .. tostring(docs)
    end
    if type(docs) ~= "table" then
        return nil, tostring(err or "scan failed")
    end
    local list = {}
    for _, doc in ipairs(docs) do
        local intent = type(doc) == "table" and doc[critical.INTENT_FIELD] or nil
        if type(intent) == "table" and type(intent.op_id) == "string" then
            list[#list + 1] = { rid = doc[key], op_id = intent.op_id, prepared_at = intent.prepared_at }
        end
    end
    return list
end

-- 跑一轮。
--
-- deps:
--   role_coll                    角色集合
--   archive(rid, limit)          经 owner 队列执行归档，返回 ok, stats|reason
--   ensure_job(rid, op_id)       确保恢复任务存在，返回 ok, job|reason
--   now / retention / limit
function M.run_once(deps, opts)
    opts = opts or {}
    if type(deps) ~= "table" or type(deps.role_coll) ~= "table" then
        return nil, "deps.role_coll is required"
    end
    local stats = { archived = 0, intents = 0, skipped = 0, failed = 0 }

    -- 归档候选的轮转游标：卡住的文档（加载失败、节点不可达）不会离开候选集，
    -- 每轮都从 0 开始扫的话，≥limit 个卡住文档就能让后面的角色永远排不进来，
    -- 最终撞上 MAX_OPS 后该角色所有关键操作被拒。满页就翻页，不满页回到开头
    local archive_skip = deps.archive_cursor or 0
    local candidates, aerr = M.scan_archive(deps.role_coll, {
        now = opts.now,
        retention = opts.retention,
        limit = opts.limit,
        key = opts.key,
        skip = archive_skip,
    })
    if not candidates then
        return nil, aerr
    end
    if #candidates >= (opts.limit or M.DEFAULT_SCAN) then
        deps.archive_cursor = archive_skip + #candidates
    else
        deps.archive_cursor = 0
    end
    m_candidates:set(#candidates, { task = "archive" })
    -- 滞后用扫描结果里的 oldest 算：不用等归档跑完就能看出积压
    local oldest = nil
    for _, entry in ipairs(candidates) do
        if math.type(entry.oldest) == "integer" and (oldest == nil or entry.oldest < oldest) then
            oldest = entry.oldest
        end
    end
    if oldest then
        local now = opts.now or os.time()
        -- 扫描只挑"已超过保留期"的候选，now - oldest 恒 >= retention；
        -- 直接拿它当滞后会让指标在 0 与 >=7 天之间跳变。减去保留期后，
        -- 正常归档约等于 0，只有吞吐跟不上（超期后还在等）才持续上涨。
        local retention = opts.retention or critical.ARCHIVE_RETENTION
        m_archive_lag:set(M.archive_lag(oldest, now, retention), { task = "archive" })
    else
        m_archive_lag:set(0, { task = "archive" })
    end
    for _, entry in ipairs(candidates) do
        if type(deps.archive) ~= "function" then
            stats.skipped = stats.skipped + 1
        else
            -- deps 的契约是 (ok, stats|reason)；pcall 会在前面多插一个 true，
            -- 只取两个返回值会把 `true` 当成 stats
            local called, ok, result = pcall(deps.archive, entry.rid, opts.limit)
            if not called then
                stats.failed = stats.failed + 1
                log.error("critical archive raised", "rid", tostring(entry.rid), "err", tostring(ok))
            elseif ok == true and type(result) == "table" then
                stats.archived = stats.archived + (result.archived or 0)
            else
                stats.skipped = stats.skipped + 1
            end
        end
    end
    m_archive:inc(1, { task = "archive" })

    local intents, ierr = M.scan_intents(deps.role_coll, opts)
    if not intents then
        return nil, ierr
    end
    m_candidates:set(#intents, { task = "intent" })
    local intent_now = opts.now or os.time()
    for _, entry in ipairs(intents) do
        if math.type(entry.prepared_at) == "integer" then
            m_prepared_age:observe(math.max(0, intent_now - entry.prepared_at), { task = "intent" })
        end
        if type(deps.ensure_job) ~= "function" then
            stats.skipped = stats.skipped + 1
        else
            local called, ok = pcall(deps.ensure_job, entry.rid, entry.op_id)
            if not called then
                stats.failed = stats.failed + 1
                log.error(
                    "critical intent job ensure raised",
                    "rid",
                    tostring(entry.rid),
                    "op_id",
                    tostring(entry.op_id),
                    "err",
                    tostring(ok)
                )
            elseif ok == true then
                stats.intents = stats.intents + 1
            else
                stats.skipped = stats.skipped + 1
            end
        end
    end
    m_archive:inc(1, { task = "intent" })
    return stats
end

function M.ensure_indexes(colls)
    -- 复用 critical 的索引口径：同一份定义，避免两处漂移
    return critical.ensure_indexes(colls)
end

-- 多数派探针的调度入口：把"取集合 → 调探针 → 归一结果"收在一处，
-- 服务层只做 GM 接线。
--
-- 探针本身在 `service/mongo_conn.lua`（只有那里持有连接），它会真写一条
-- `w:majority, j:true` 的记录、多数派读回、再清理；这里不重复实现语义，
-- 只负责把失败翻译成可读原因，让运维知道是"连不上"还是"多数派不成立"。
function M.probe(deps)
    if type(deps) ~= "table" or type(deps.collection) ~= "table" then
        return false, "deps.collection is required"
    end
    local coll = deps.collection
    if type(coll.critical_probe) ~= "function" then
        return false, "collection has no critical_probe"
    end
    local called, ok, err = pcall(coll.critical_probe, coll)
    if not called then
        return false, "probe raised: " .. tostring(ok)
    end
    if ok ~= true then
        return false, tostring(err or "probe failed")
    end
    return true, { type_name = deps.type_name, collection = deps.collection_name }
end

return M
