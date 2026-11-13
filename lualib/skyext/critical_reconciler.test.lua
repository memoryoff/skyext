local t = require "skytest"
local reconciler = require "skyext.critical_reconciler"
local critical = require "skyext.critical"

local S = critical.JOB_STATE

local function harness(over)
    over = over or {}
    local h = {
        jobs = over.jobs or {
            { rid = 7, op_id = "srv_" .. string.rep("a", 64), job_version = 3, state = S.PENDING },
        },
        finished = {},
        resolved = {},
        queries = {},
        claim_ok = over.claim_ok ~= false,
        claim_result = over.claim_result,
        finish_ok = over.finish_ok ~= false,
        proof = over.proof or { status = "COMMITTED" },
    }
    h.deps = {
        jobs_coll = {
            find_many = function(_, query, opts)
                h.queries[#h.queries + 1] = { query = query, opts = opts }
                return h.jobs
            end,
        },
        claim = function(rid, op_id, owner, lease_until, version)
            h.claimed = { rid = rid, op_id = op_id, owner = owner, lease_until = lease_until, version = version }
            if not h.claim_ok then
                return false, "already claimed"
            end
            return true, h.claim_result or { job_version = version + 1 }
        end,
        resolve = function(rid, op_id)
            h.resolved[#h.resolved + 1] = { rid = rid, op_id = op_id }
            return h.proof
        end,
        finish = function(rid, op_id, version, state)
            h.finished[#h.finished + 1] = { rid = rid, op_id = op_id, version = version, state = state }
            return h.finish_ok
        end,
    }
    return h
end

local function run(h, over)
    local opts = { now = 1000, owner = "coordinator-1" }
    for k, v in pairs(over or {}) do
        opts[k] = v
    end
    return reconciler.run_once(h.deps, opts)
end

t.describe("critical_reconciler 状态机", function()
    t.it("completes a job whose asset effect was already committed", function()
        local h = harness()
        local stats = assert(run(h))
        t.expect(stats.claimed).to.equal(1)
        t.expect(stats.committed).to.equal(1)
        t.expect(h.finished[1].state).to.equal(S.COMPLETED_COMMITTED)
        -- 抢占后 job_version 已经 +1，终态 CAS 必须用新版本
        t.expect(h.finished[1].version).to.equal(4)
        -- 扫描口径：本轮看到的 due 任务按状态计数，供指标暴露
        t.expect(stats.due[S.PENDING]).to.equal(1)
    end)

    t.it("counts due jobs by state for the scan gauge", function()
        local h = harness({
            jobs = {
                { rid = 1, op_id = "srv_" .. string.rep("a", 64), job_version = 1, state = S.PENDING },
                { rid = 2, op_id = "srv_" .. string.rep("b", 64), job_version = 1, state = S.RETRY_WAIT },
                { rid = 3, op_id = "srv_" .. string.rep("c", 64), job_version = 1, state = S.PENDING },
            },
        })
        local stats = assert(run(h))
        t.expect(stats.due[S.PENDING]).to.equal(2)
        t.expect(stats.due[S.RETRY_WAIT]).to.equal(1)
    end)

    t.it("completes as NOT_COMMITTED only after a proof says so", function()
        local h = harness({ proof = { status = "NOT_COMMITTED" } })
        local stats = assert(run(h))
        t.expect(stats.not_committed).to.equal(1)
        t.expect(h.finished[1].state).to.equal(S.COMPLETED_NOT_COMMITTED)
    end)

    t.it("keeps the job retryable when the proof is UNKNOWN", function()
        local h = harness({ proof = { status = "UNKNOWN" } })
        local stats = assert(run(h))
        t.expect(stats.retry).to.equal(1)
        t.expect(h.finished[1].state).to.equal(S.RETRY_WAIT)
        t.expect(#h.resolved).to.equal(1)
    end)

    t.it("treats a claim conflict as a reread, never as a resolution", function()
        local h = harness({ claim_ok = false })
        local stats = assert(run(h))
        t.expect(stats.conflict).to.equal(1)
        t.expect(#h.resolved).to.equal(0)
        t.expect(#h.finished).to.equal(0)
    end)

    t.it("leaves the job claimable when the terminal write fails", function()
        local h = harness({ finish_ok = false })
        local stats = assert(run(h))
        t.expect(stats.failed).to.equal(1)
        t.expect(h.finished[1].state).to.equal(S.COMPLETED_COMMITTED)
    end)

    t.it("scans only due, non-terminal states with a bounded page", function()
        local h = harness()
        assert(run(h, { scan_limit = 7 }))
        local q = h.queries[1]
        t.expect(q.opts.limit).to.equal(7)
        t.expect(q.query.state["$in"]).to.equal({ S.PENDING, S.CLAIMING_FENCE, S.RETRY_WAIT })
        -- 租约条件必须在 $or 里保留；cursor 走 $and，避免两个 $or 互相顶掉
        local lease = q.query["$and"][1]["$or"]
        t.expect(lease[1].lease_until["$lte"]).to.equal(1000)
        t.expect(lease[2].lease_until["$exists"]).to.equal(false)
    end)

    -- claim 会改 lease_until 与 updated_at，两者都在查询与排序里：skip 分页的页边界
    -- 因此随集合收缩漂移。游标必须落在不可变的任务主键上
    t.it("pages by an immutable (rid, op_id) keyset instead of an offset", function()
        local h = harness()
        assert(run(h, { scan_limit = 2 }))
        local q = h.queries[1]
        t.expect(q.opts.skip).to.be_nil()
        t.expect(q.opts.sort).to.equal({ { rid = 1 }, { op_id = 1 } })
    end)

    t.it("reports a zero due count for every scannable state each round", function()
        local h = harness({
            jobs = { { rid = 1, op_id = "srv_" .. string.rep("a", 64), job_version = 1, state = S.RETRY_WAIT } },
        })
        local stats = assert(run(h))
        -- 上一轮见过的 PENDING 归零后必须显式写 0，否则 gauge 会永远停在旧值
        t.expect(stats.due[S.PENDING]).to.equal(0)
        t.expect(stats.due[S.CLAIMING_FENCE]).to.equal(0)
        t.expect(stats.due[S.RETRY_WAIT]).to.equal(1)
    end)

    t.it("fails closed on missing deps or owner", function()
        local h = harness()
        t.expect(reconciler.run_once({}, { owner = "x" })).to.be_nil()
        t.expect(reconciler.run_once(h.deps, { now = 1000 })).to.be_nil()
        t.expect(#h.resolved).to.equal(0)
    end)
end)

-- ---------------------------------------------------------------------------
-- 真实语义的假任务表：按 query 过滤、按 sort 排序、按 limit 取页；claim 会把
-- lease_until 推到未来，任务因此立刻退出待处理集合（和生产里的 claim_job 一致）
-- ---------------------------------------------------------------------------
local function match_cond(doc, key, cond)
    if type(cond) ~= "table" then
        return doc[key] == cond
    end
    local value = doc[key]
    if cond["$lte"] ~= nil then
        return value ~= nil and value <= cond["$lte"]
    end
    if cond["$gt"] ~= nil then
        return value ~= nil and value > cond["$gt"]
    end
    if cond["$exists"] == false then
        return value == nil
    end
    if cond["$in"] then
        for _, candidate in ipairs(cond["$in"]) do
            if value == candidate then
                return true
            end
        end
        return false
    end
    error("unsupported query operator")
end

local function matches(doc, query)
    for key, cond in pairs(query) do
        if key == "$and" then
            for _, sub in ipairs(cond) do
                if not matches(doc, sub) then
                    return false
                end
            end
        elseif key == "$or" then
            local hit = false
            for _, sub in ipairs(cond) do
                if matches(doc, sub) then
                    hit = true
                    break
                end
            end
            if not hit then
                return false
            end
        elseif not match_cond(doc, key, cond) then
            return false
        end
    end
    return true
end

local function sort_docs(docs, sort)
    table.sort(docs, function(a, b)
        for _, spec in ipairs(sort) do
            for field, dir in pairs(spec) do
                local x, y = a[field], b[field]
                if x ~= y then
                    if dir == 1 then
                        return x < y
                    end
                    return x > y
                end
            end
        end
        return false
    end)
    return docs
end

local function scheduled_jobs(count)
    local jobs = {}
    for i = 1, count do
        jobs[i] = {
            rid = i,
            op_id = "srv_" .. string.format("%064d", i),
            job_version = 1,
            state = S.PENDING,
            updated_at = 1000 + i,
        }
    end
    return jobs
end

t.describe("critical_reconciler 分页与集合漂移", function()
    t.it("claims every due job exactly once when each claim empties the scanned set", function()
        local jobs = scheduled_jobs(240)
        local claimed = {}
        local queries = {}
        local coll = {
            find_many = function(_, query, opts)
                queries[#queries + 1] = { query = query, opts = opts }
                local hits = {}
                for _, job in ipairs(jobs) do
                    if matches(job, query) then
                        hits[#hits + 1] = job
                    end
                end
                sort_docs(hits, opts.sort)
                local page = {}
                for i = 1, math.min(#hits, opts.limit) do
                    page[i] = hits[i]
                end
                return page
            end,
        }
        local deps = {
            jobs_coll = coll,
            claim = function(rid, op_id)
                for _, job in ipairs(jobs) do
                    if job.rid == rid and job.op_id == op_id then
                        claimed[#claimed + 1] = op_id
                        -- 生产里的 claim_job 会改这三个字段，任务随即离开待处理集合
                        job.state = S.CLAIMING_FENCE
                        job.lease_until = 1000 + 30
                        job.updated_at = 1000
                        return true, { job_version = job.job_version + 1 }
                    end
                end
                return false, "gone"
            end,
            resolve = function()
                return { status = "COMMITTED" }
            end,
            finish = function()
                return true
            end,
        }
        local rounds = 0
        local scanned_total = 0
        while true do
            local stats = assert(reconciler.run_once(deps, { now = 1000, owner = "coord-1", scan_limit = 16 }))
            rounds = rounds + 1
            scanned_total = scanned_total + stats.claimed + stats.conflict
            if stats.claimed == 0 and stats.conflict == 0 then
                break
            end
            assert(rounds < 60, "分页没有收敛：offset 漂移")
        end
        -- 240 条、每页 16：keyset 正好 15 页取完，第 16 轮空扫退出
        t.expect(rounds).to.equal(16)
        t.expect(#claimed).to.equal(240)
        t.expect(scanned_total).to.equal(240)
        local seen = {}
        for _, op_id in ipairs(claimed) do
            assert(not seen[op_id], "同一个任务被认领了两次: " .. op_id)
            seen[op_id] = true
        end
    end)

    t.it("resets the keyset cursor once the last page is short", function()
        local deps = {
            jobs_coll = {
                find_many = function()
                    return {}
                end,
            },
            claim = function()
                return false, "none"
            end,
            resolve = function()
                return { status = "UNKNOWN" }
            end,
            finish = function()
                return true
            end,
        }
        assert(reconciler.run_once(deps, { now = 1000, owner = "coord-1" }))
        t.expect(deps.scan_cursor).to.be_nil()
    end)

    t.it("keeps the keyset cursor pointing at the last job of a full page", function()
        local jobs = scheduled_jobs(3)
        local queries = {}
        local deps = {
            jobs_coll = {
                find_many = function(_, query, opts)
                    queries[#queries + 1] = query
                    local hits = {}
                    for _, job in ipairs(jobs) do
                        if matches(job, query) then
                            hits[#hits + 1] = job
                        end
                    end
                    sort_docs(hits, opts.sort)
                    local page = {}
                    for i = 1, math.min(#hits, opts.limit) do
                        page[i] = hits[i]
                    end
                    return page
                end,
            },
            claim = function()
                return true, { job_version = 2 }
            end,
            resolve = function()
                return { status = "COMMITTED" }
            end,
            finish = function()
                return true
            end,
        }
        assert(reconciler.run_once(deps, { now = 1000, owner = "coord-1", scan_limit = 2 }))
        t.expect(deps.scan_cursor.rid).to.equal(2)
        t.expect(deps.scan_cursor.op_id).to.equal(jobs[2].op_id)
        assert(reconciler.run_once(deps, { now = 1000, owner = "coord-1", scan_limit = 2 }))
        -- 第二页带 keyset 条件：按 (rid, op_id) 严格大于上一页末尾
        local cursor_or = queries[2]["$and"][2]["$or"]
        t.expect(cursor_or[1].rid["$gt"]).to.equal(2)
        t.expect(cursor_or[2].rid).to.equal(2)
        t.expect(cursor_or[2].op_id["$gt"]).to.equal(jobs[2].op_id)
    end)
end)
