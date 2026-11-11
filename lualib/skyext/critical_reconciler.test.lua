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
        t.expect(q.query["$or"][1].lease_until["$lte"]).to.equal(1000)
    end)

    t.it("fails closed on missing deps or owner", function()
        local h = harness()
        t.expect(reconciler.run_once({}, { owner = "x" })).to.be_nil()
        t.expect(reconciler.run_once(h.deps, { now = 1000 })).to.be_nil()
        t.expect(#h.resolved).to.equal(0)
    end)
end)
