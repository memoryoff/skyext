-- 持久化恢复任务的执行器（P08 §4.4.1）。
--
-- 职责边界：任务表只负责调度与观察，**资产事实始终取角色文档的 _critical_* 与
-- 新 owner 的 Majority Fence 认领结果**。本模块不直接改资产，不提供 force / 强解，
-- 任何一步不能证明时只把任务留在 RETRY_WAIT，等下一轮重新证明。
--
-- 之前 `reconcile/claim_job/finish_job/abort_intent` 只有单测在调，没有生产驱动；
-- 这个模块把状态机 PENDING -> CLAIMING_FENCE -> READING/RESOLVING -> COMPLETED_*
-- 真正跑起来，由 service/critical_maintenance 定时调用。
local critical = require "skyext.critical"
local log = require "skyext.log"
local metrics = require "skyext.metrics"

local M = {}

M.DEFAULT_SCAN = 16
M.DEFAULT_LEASE = 30

local m_outcome = metrics.counter("skyext_critical_reconciler_total", "Reconcile job outcomes", { "outcome" })
-- 扫描口径：任务表本身只能逐条查，MANUAL_REVIEW / RETRY_WAIT 堆积没有趋势可看。
-- 每轮按状态把本轮看到的 due 任务数暴露出去，压测和告警都靠它。
local m_due =
    metrics.gauge("skyext_critical_reconcile_due_jobs", "Due reconcile jobs observed by the last scan", { "state" })

local STATES = critical.JOB_STATE
local DUE_STATES = { STATES.PENDING, STATES.CLAIMING_FENCE, STATES.RETRY_WAIT }

-- 游标只能落在扫描期间不变的字段上。任务主键 (rid, op_id) 在 claim 前后都不变，
-- 而 updated_at / lease_until 会被 claim 改掉——拿它们做游标或排序键，页边界会随
-- 集合收缩漂移，后面的任务被反复跳过（只是延后，不会永久丢单，但恢复时间不可预测）。
local function normalize_cursor(value)
    if type(value) ~= "table" then
        return nil
    end
    if math.type(value.rid) ~= "integer" or type(value.op_id) ~= "string" then
        return nil
    end
    return { rid = value.rid, op_id = value.op_id }
end

local function scan_query(now, cursor)
    local query = {
        state = { ["$in"] = DUE_STATES },
        -- 租约条件必须单独成组：cursor 也是 $or（复合键），两个 $or 平铺会互相覆盖
        ["$and"] = {
            {
                ["$or"] = {
                    { lease_until = { ["$lte"] = now } },
                    { lease_until = { ["$exists"] = false } },
                },
            },
        },
    }
    if cursor then
        query["$and"][2] = {
            ["$or"] = {
                { rid = { ["$gt"] = cursor.rid } },
                { rid = cursor.rid, op_id = { ["$gt"] = cursor.op_id } },
            },
        }
    end
    return query
end

-- deps:
--   jobs_coll                      任务集合（find_many）
--   claim(rid, op_id, owner, lease_until, job_version) -> true, job | false, reason
--   resolve(rid, op_id)            -> { status = COMMITTED | NOT_COMMITTED | UNKNOWN }
--                                    必须经实际持锁 owner 的实体队列与 Fence 屏障
--   finish(rid, op_id, job_version, state_name) -> true | false, reason
-- opts: now / owner / scan_limit / lease / cursor
function M.run_once(deps, opts)
    opts = opts or {}
    if type(deps) ~= "table" or type(deps.jobs_coll) ~= "table" then
        return nil, "deps.jobs_coll is required"
    end
    for _, name in ipairs({ "claim", "resolve", "finish" }) do
        if type(deps[name]) ~= "function" then
            return nil, "deps." .. name .. " is required"
        end
    end
    if type(opts.owner) ~= "string" or opts.owner == "" then
        return nil, "opts.owner is required"
    end
    local now = opts.now or os.time()
    local lease = opts.lease or M.DEFAULT_LEASE
    local cursor = normalize_cursor(opts.cursor) or normalize_cursor(deps.scan_cursor)
    local stats = {
        claimed = 0,
        committed = 0,
        not_committed = 0,
        retry = 0,
        conflict = 0,
        failed = 0,
        due = {},
    }
    for _, state in ipairs(DUE_STATES) do
        stats.due[state] = 0
    end

    -- 只扫租约到期的可认领任务；索引是 {state:1, lease_until:1}
    local scan_limit = opts.scan_limit or M.DEFAULT_SCAN
    local called, jobs, err = pcall(deps.jobs_coll.find_many, deps.jobs_coll, scan_query(now, cursor), {
        limit = scan_limit,
        -- 主键排序：不可变、唯一，keyset 续扫不会因为 claim 改字段而重排
        sort = { { rid = 1 }, { op_id = 1 } },
        projection = { _id = 0 },
    })
    if not called then
        return nil, "reconcile scan failed: " .. tostring(jobs)
    end
    if type(jobs) ~= "table" then
        return nil, tostring(err or "reconcile scan failed")
    end
    local next_cursor
    if #jobs >= scan_limit and #jobs > 0 then
        local last = jobs[#jobs]
        next_cursor = normalize_cursor(last)
    end
    -- 页没满说明本轮已经扫到末尾：下一轮从头开始，避免游标永久停在尾部
    deps.scan_cursor = next_cursor

    for _, job in ipairs(jobs) do
        if type(job) == "table" and type(job.state) == "string" then
            stats.due[job.state] = (stats.due[job.state] or 0) + 1
        end
        if type(job) ~= "table" or job.rid == nil or type(job.op_id) ~= "string" then
            stats.failed = stats.failed + 1
        else
            local ok, claimed = deps.claim(job.rid, job.op_id, opts.owner, now + lease, job.job_version)
            if not ok then
                -- 已被别的协调者抢走或版本冲突：重读即可，不是错误
                stats.conflict = stats.conflict + 1
                m_outcome:inc(1, { outcome = "conflict" })
            else
                stats.claimed = stats.claimed + 1
                local version = (type(claimed) == "table" and claimed.job_version) or job.job_version
                local resolved, proof = pcall(deps.resolve, job.rid, job.op_id)
                local outcome = (resolved and type(proof) == "table" and proof.status) or "UNKNOWN"
                local final_state
                if outcome == "COMMITTED" then
                    final_state = STATES.COMPLETED_COMMITTED
                    stats.committed = stats.committed + 1
                elseif outcome == "NOT_COMMITTED" then
                    final_state = STATES.COMPLETED_NOT_COMMITTED
                    stats.not_committed = stats.not_committed + 1
                else
                    -- 证明不了就保持可重入：绝不把"没读到"当成"没执行过"
                    final_state = STATES.RETRY_WAIT
                    stats.retry = stats.retry + 1
                    log.warn(
                        "reconcile proof unavailable, keeping the job retryable",
                        "rid",
                        tostring(job.rid),
                        "op_id",
                        tostring(job.op_id)
                    )
                end
                m_outcome:inc(1, { outcome = outcome:lower() })
                local written = deps.finish(job.rid, job.op_id, version, final_state)
                if not written then
                    -- 终态没写进去就保留任务；下一轮重新抢占并重新证明，不会跳过
                    stats.failed = stats.failed + 1
                    log.error(
                        "reconcile finish failed, job stays claimable",
                        "rid",
                        tostring(job.rid),
                        "op_id",
                        tostring(job.op_id)
                    )
                end
            end
        end
    end
    -- 每个可扫状态每轮都要写：只写本轮见到的状态，归零的 gauge 会永远停在旧值
    for _, state in ipairs(DUE_STATES) do
        m_due:set(stats.due[state] or 0, { state = state })
    end
    return stats
end

return M
