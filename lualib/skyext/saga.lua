-- 双向交易 Saga 协调者（P13）。
--
-- 定位：协调者只负责**持久化状态机 + 驱动步骤**，资产效果仍由 `skyext.critical`
-- 的提交内核决定。协调者自己从不写角色文档。
--
-- 状态机：
--   CREATED --reserve--> RESERVED --commit--> COMMITTED
--                          |                    |
--                          +--compensate--------+--> COMPENSATING --compensated--> COMPENSATED
--   CREATED --业务拒绝--> FAILED
--
-- 消息语义：每一步都带**稳定** `event_id` 与由它字节级映射出的 `service_op_id`。
-- 可靠消息是 At-Least-Once，不谎称 Exactly-Once；重复投递靠接收方的
-- `service_op_id` 去重。`seq` 不是并发全序，`msg_id` 也不能当因果顺序用。
--
-- 崩溃恢复：`run` 每次只做"读文档 -> 执行当前状态对应的那一步 -> CAS 推进状态"，
-- 状态在步骤**之后**用 CAS 落库。进程在两步之间崩溃时，下一轮会重跑同一步，
-- 而重跑是幂等的（同一个 `service_op_id`）。
local canonical = require "skyext.canonical_lua"
local log = require "skyext.log"
local metrics = require "skyext.metrics"

local M = {}

M.STATE = {
    CREATED = "CREATED",
    RESERVED = "RESERVED",
    COMMITTED = "COMMITTED",
    COMPENSATING = "COMPENSATING",
    COMPENSATED = "COMPENSATED",
    FAILED = "FAILED",
}

M.TERMINAL = {
    [M.STATE.COMMITTED] = true,
    [M.STATE.COMPENSATED] = true,
    [M.STATE.FAILED] = true,
}

M.DOMAIN = "skyext:saga:v1"
M.EVENT_PREFIX = "evt_"
M.SAGA_PREFIX = "sag_"
M.HEX64 = 64
M.DEFAULT_SCAN = 32
-- 可被协调者认领的状态：终态不再需要处理
M.CLAIMABLE = {
    [M.STATE.CREATED] = true,
    [M.STATE.RESERVED] = true,
    [M.STATE.COMPENSATING] = true,
}

-- 显式迁移表。只判断"源状态可认领"是不够的：那样 CREATED 能直接跳到
-- COMPENSATED，跳过整个补偿过程还宣称交易已冲正
M.TRANSITIONS = {
    [M.STATE.CREATED] = { [M.STATE.RESERVED] = true, [M.STATE.FAILED] = true },
    [M.STATE.RESERVED] = {
        [M.STATE.COMMITTED] = true,
        [M.STATE.COMPENSATING] = true,
        [M.STATE.FAILED] = true,
    },
    [M.STATE.COMMITTED] = { [M.STATE.COMPENSATING] = true },
    [M.STATE.COMPENSATING] = { [M.STATE.COMPENSATED] = true },
}

local m_state = metrics.counter("skyext_saga_state_total", "Saga transitions by target state", { "state" })
local m_unknown = metrics.counter("skyext_saga_step_unknown_total", "Saga steps whose outcome is unknown", { "step" })

local function hex(bytes)
    return (bytes:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

local function digest(domain, body, hash_fn)
    local ok, out = pcall(hash_fn, domain, body)
    if not ok then
        return nil, "hash failed"
    end
    if type(out) ~= "string" or #out ~= 32 then
        return nil, "invalid digest"
    end
    return hex(out)
end

-- `sag_<64hex>`：同一个业务键在任何节点、任何时间都算出同一个 ID，
-- 因此"创建"天然幂等，不需要先查再插
function M.new_id(kind, business_key, hash_fn)
    if type(kind) ~= "string" or #kind == 0 then
        return nil, "kind is required"
    end
    if type(business_key) ~= "string" or #business_key == 0 then
        return nil, "business_key is required"
    end
    if type(hash_fn) ~= "function" then
        return nil, "hash_fn is required"
    end
    local body, err = canonical.encode({ kind = kind, key = business_key })
    if not body then
        return nil, err
    end
    local h, herr = digest(M.DOMAIN, body, hash_fn)
    if not h then
        return nil, herr
    end
    return M.SAGA_PREFIX .. h
end

-- 步骤键：`event_id` 由 (kind, key, step) 确定性推导，重试不变。
-- 这也是 Saga 不能"临时生成 event_id"的原因：换了就失去去重能力。
function M.step_keys(kind, business_key, step, hash_fn)
    if type(step) ~= "string" or #step == 0 then
        return nil, "step is required"
    end
    if type(hash_fn) ~= "function" then
        return nil, "hash_fn is required"
    end
    local body, err = canonical.encode({ kind = kind, key = business_key, step = step })
    if not body then
        return nil, err
    end
    local h, herr = digest(M.DOMAIN .. ":step", body, hash_fn)
    if not h then
        return nil, herr
    end
    local event_id = M.EVENT_PREFIX .. h
    -- 与 critical 的映射保持同一条规则：字节级一一对应，不重新哈希
    return { event_id = event_id, service_op_id = "srv_" .. h, step = step }
end

-- 步骤信封：复用 Outbox 的接收方与去重路径，Saga 不需要第二套投递协议
function M.envelope(saga, step_keys, target_type, target_id, op_type, payload, param_hash)
    return {
        version = 1,
        event_id = step_keys.event_id,
        source_type = "saga",
        source_id = saga.saga_id,
        target_type = target_type,
        target_id = target_id,
        op_type = op_type,
        payload = payload,
        param_hash = param_hash,
    }
end

-- 幂等创建。返回 doc, created（created 只在这次真的插入时为 true）
function M.create(coll, opts)
    if type(coll) ~= "table" then
        return nil, "saga collection is required"
    end
    if type(opts) ~= "table" or type(opts.saga_id) ~= "string" then
        return nil, "saga_id is required"
    end
    if type(opts.kind) ~= "string" or #opts.kind == 0 then
        return nil, "kind is required"
    end
    local now = opts.now or os.time()
    -- 创建走多数派写：w=1 已确认、随后资产预留提交、再崩溃，会留下"钱冻了、Saga 记录没了"
    -- 的孤儿预留。重复创建由 `saga_id` 唯一索引兜底，冲突时回读即可
    local state, ret = coll:critical_find_and_modify({
        query = { saga_id = opts.saga_id },
        update = {
            ["$setOnInsert"] = {
                saga_id = opts.saga_id,
                kind = opts.kind,
                business_key = opts.business_key,
                state = M.STATE.CREATED,
                version = 0,
                attempt = 0,
                steps = opts.steps or {},
                created_at = now,
            },
        },
        upsert = true,
        new = true,
    })
    if state ~= "CONFIRMED" then
        return nil, "saga create " .. tostring(state):lower()
    end
    local doc = type(ret) == "table" and ret.value or nil
    if type(doc) ~= "table" then
        -- upsert 命中已有文档但没回后像：回读一次
        doc = coll:find_one({ saga_id = opts.saga_id })
    end
    if type(doc) ~= "table" then
        return nil, "saga not readable"
    end
    local leo = type(ret) == "table" and type(ret.lastErrorObject) == "table" and ret.lastErrorObject or nil
    local created
    if leo and leo.updatedExisting ~= nil then
        created = leo.updatedExisting == false
    end
    return doc, created
end

function M.status(coll, saga_id)
    local doc = coll:find_one({ saga_id = saga_id })
    if type(doc) ~= "table" then
        return nil, "not found"
    end
    return doc
end

-- 原子认领：状态可认领 + 版本匹配 + 租约已过期。
-- 只按"租约过期"匹配是不够的：终态文档没有 lease_until，会被反复抢走
function M.claim(coll, saga_id, owner, lease_until, opts)
    opts = opts or {}
    if type(owner) ~= "string" or #owner == 0 then
        return false, "owner is required"
    end
    if math.type(lease_until) ~= "integer" then
        return false, "lease_until must be an integer"
    end
    local now = opts.now or os.time()
    local query = {
        saga_id = saga_id,
        state = { ["$in"] = { M.STATE.CREATED, M.STATE.RESERVED, M.STATE.COMPENSATING } },
        ["$or"] = {
            { lease_until = { ["$lte"] = now } },
            { lease_until = { ["$exists"] = false } },
        },
    }
    if math.type(opts.version) == "integer" then
        query.version = opts.version
    end
    local state, ret = coll:critical_find_and_modify({
        query = query,
        update = {
            ["$set"] = { owner = owner, lease_until = lease_until, updated_at = now },
            ["$inc"] = { version = 1, attempt = 1 },
        },
        new = true,
    })
    if state ~= "CONFIRMED" then
        return false, state
    end
    local doc = type(ret) == "table" and ret.value or nil
    if type(doc) ~= "table" then
        return false, "already claimed"
    end
    return true, doc
end

-- 状态推进：`from` 与 `version` 必须同时匹配，否则返回 "state mismatch"。
-- 不用"以最新状态为准"：那会让补偿把已提交的交易推回 COMPENSATING
function M.transition(coll, saga_id, from, to, extra, opts)
    opts = opts or {}
    local allowed = M.TRANSITIONS[from]
    if not allowed or not allowed[to] then
        return nil, "illegal transition from " .. tostring(from) .. " to " .. tostring(to)
    end
    local set = { state = to, updated_at = opts.now or os.time() }
    for k, v in pairs(extra or {}) do
        set[k] = v
    end
    local query = { saga_id = saga_id, state = from }
    if math.type(opts.version) == "integer" then
        query.version = opts.version
    end
    -- 带上 owner：失租的协调者不能靠"状态没变"抢到迁移，否则新旧 owner 会同时
    -- 执行两个不同步骤（一个 commit、一个 compensate），两侧都动过账
    if opts.owner ~= nil then
        query.owner = opts.owner
    end
    local state, ret = coll:critical_find_and_modify({
        query = query,
        update = { ["$set"] = set, ["$inc"] = { version = 1 } },
        new = true,
    })
    if state ~= "CONFIRMED" then
        return nil, state == "UNKNOWN" and "unknown" or "state mismatch"
    end
    local doc = type(ret) == "table" and ret.value or nil
    if type(doc) ~= "table" then
        return nil, "state mismatch"
    end
    m_state:inc(1, { state = to })
    return doc
end

function M.release(coll, saga_id, opts)
    opts = opts or {}
    local state = coll:critical_find_and_modify({
        query = { saga_id = saga_id },
        update = {
            ["$unset"] = { owner = true, lease_until = true },
            ["$set"] = { updated_at = opts.now or os.time() },
        },
        new = true,
    })
    return state == "CONFIRMED"
end

-- 步骤返回值归一化。未识别的结果一律按未决处理：把未知当成功会让补偿丢失，
-- 当失败会重复补偿
local function step_outcome(fn, doc, name)
    if type(fn) ~= "function" then
        return "PENDING"
    end
    local ok, outcome = pcall(fn, doc)
    if not ok then
        log.error("saga step raised", "step", name, "saga", tostring(doc.saga_id), "err", tostring(outcome))
        return "UNKNOWN"
    end
    if outcome == "COMMITTED" or outcome == "REJECTED" or outcome == "PENDING" then
        return outcome
    end
    m_unknown:inc(1, { step = name })
    return "UNKNOWN"
end

-- 驱动一次。deps 提供三个步骤实现，每个返回：
--   "COMMITTED"    这一步已持久确认
--   "REJECTED"     业务明确拒绝（可以走补偿）
--   "UNKNOWN"      结果未决：保持状态不变，等下一轮
--   "PENDING"      还没有结论（例如消息已投递、接收方尚未 ACK）
--
-- 返回 state, detail；state 是本次调用结束后的持久状态
function M.run(coll, saga_id, deps, opts)
    opts = opts or {}
    if type(deps) ~= "table" then
        return nil, "deps are required"
    end
    local doc, err = M.status(coll, saga_id)
    if not doc then
        return nil, err
    end
    -- 协调者必须先 claim。没有租约就执行步骤，会和接管者并发跑同一步
    if opts.owner ~= nil then
        if doc.owner ~= opts.owner then
            return nil, "not owner"
        end
        local now = opts.now or os.time()
        if math.type(doc.lease_until) ~= "integer" or doc.lease_until <= now then
            return nil, "lease expired"
        end
    end
    local state = doc.state
    if M.TERMINAL[state] then
        return state, "terminal"
    end

    if state == M.STATE.CREATED then
        local outcome = step_outcome(deps.reserve, doc, "reserve")
        if outcome == "COMMITTED" then
            local next_doc, terr = M.transition(coll, saga_id, state, M.STATE.RESERVED, nil, {
                version = doc.version,
                owner = opts.owner,
                now = opts.now,
            })
            if not next_doc then
                return state, terr
            end
            return M.STATE.RESERVED, "reserved"
        end
        if outcome == "REJECTED" then
            local next_doc, terr = M.transition(
                coll,
                saga_id,
                state,
                M.STATE.FAILED,
                { last_error = "reserve rejected" },
                {
                    version = doc.version,
                    owner = opts.owner,
                    now = opts.now,
                }
            )
            if not next_doc then
                return state, terr
            end
            return M.STATE.FAILED, "reserve rejected"
        end
        return state, outcome
    end

    if state == M.STATE.RESERVED then
        local outcome = step_outcome(deps.commit, doc, "commit")
        if outcome == "COMMITTED" then
            local next_doc, terr = M.transition(coll, saga_id, state, M.STATE.COMMITTED, nil, {
                version = doc.version,
                owner = opts.owner,
                now = opts.now,
            })
            if not next_doc then
                return state, terr
            end
            return M.STATE.COMMITTED, "committed"
        end
        if outcome == "REJECTED" then
            -- 补偿是**新的操作**，不是把提交回滚成没发生
            local next_doc, terr = M.transition(
                coll,
                saga_id,
                state,
                M.STATE.COMPENSATING,
                { last_error = "commit rejected" },
                { version = doc.version, owner = opts.owner, now = opts.now }
            )
            if not next_doc then
                return state, terr
            end
            return M.STATE.COMPENSATING, "compensating"
        end
        return state, outcome
    end

    -- COMPENSATING
    --
    -- 补偿是**至少一次**：ACK 丢失与补偿失败在协调者看来无法区分，所以同一轮
    -- COMPENSATING 会被反复驱动，`compensate` 可能被执行多次。
    -- 状态机保证的是"只离开 COMPENSATING 一次"，**不是**"补偿 handler 只跑一次"。
    -- 因此业务补偿必须幂等：用 saga_id（或 saga_id + step）做去重键，
    -- 重复调用要返回 COMMITTED 而不是再退一次钱。
    local outcome = step_outcome(deps.compensate, doc, "compensate")
    if outcome == "COMMITTED" then
        local next_doc, terr = M.transition(coll, saga_id, state, M.STATE.COMPENSATED, nil, {
            version = doc.version,
            now = opts.now,
            -- 与其它四个转移同一条不变量：失租的协调者不能靠"状态没变"抢到迁移
            owner = opts.owner,
        })
        if not next_doc then
            return state, terr
        end
        return M.STATE.COMPENSATED, "compensated"
    end
    -- 补偿失败保持 COMPENSATING：资产要么守恒，要么留在明确可恢复的冻结状态，
    -- 不能因为补偿报错就宣称交易结束
    return state, outcome
end

-- 已提交交易的手工补偿入口。
-- 补偿是**新的操作**，不是"把提交回滚成没发生"：所以必须显式调用、必须带原因，
-- 并且只允许从 COMMITTED 进入。`run` 把 COMMITTED 当终态，不会自动补偿
function M.compensate(coll, saga_id, opts)
    opts = opts or {}
    if type(opts.reason) ~= "string" or #opts.reason == 0 then
        return nil, "reason is required"
    end
    local doc, err = M.status(coll, saga_id)
    if not doc then
        return nil, err
    end
    if doc.state ~= M.STATE.COMMITTED then
        return nil, "not committed"
    end
    return M.transition(coll, saga_id, M.STATE.COMMITTED, M.STATE.COMPENSATING, {
        last_error = opts.reason,
        compensate_reason = opts.reason,
    }, { version = doc.version, owner = opts.owner, now = opts.now })
end

-- 扫描到期可认领的 Saga。协调者进程用它找活干：
--   * 只取可认领状态，终态永远不进结果集；
--   * 只取租约已过期（或从未被认领）的文档，正在被别的协调者处理的不会被抢；
--   * 按 updated_at 升序，最久没动过的先处理，避免老交易饿死。
-- 命中 `state_lease` 索引；没有索引时这里是全表扫描，所以 `ensure_indexes` 是门禁。
function M.scan_due(coll, opts)
    opts = opts or {}
    if type(coll) ~= "table" then
        return nil, "saga collection is required"
    end
    local now = opts.now or os.time()
    local called, docs, err = pcall(coll.find_many, coll, {
        state = { ["$in"] = { M.STATE.CREATED, M.STATE.RESERVED, M.STATE.COMPENSATING } },
        ["$or"] = {
            { lease_until = { ["$lte"] = now } },
            { lease_until = { ["$exists"] = false } },
        },
    }, {
        projection = { saga_id = 1, state = 1, version = 1, attempt = 1, _id = 0 },
        sort = { { updated_at = 1 } },
        limit = opts.limit or M.DEFAULT_SCAN,
    })
    if not called then
        return nil, "scan failed: " .. tostring(docs)
    end
    if type(docs) ~= "table" then
        return nil, tostring(err or "scan failed")
    end
    return docs
end

function M.index_specs(colls)
    return {
        { colls.saga, { { saga_id = 1 }, name = "saga_id", unique = true } },
        { colls.saga, { { state = 1 }, { lease_until = 1 }, name = "state_lease" } },
    }
end

function M.ensure_indexes(colls)
    for _, spec in ipairs(M.index_specs(colls)) do
        local coll, keys = spec[1], spec[2]
        if not coll then
            return nil, "missing collection for index " .. tostring(keys.name)
        end
        local called, ok, err = pcall(coll.create_index, coll, keys)
        if not called then
            return nil, "create_index raised: " .. tostring(ok)
        end
        if type(ok) == "table" then
            if ok.ok ~= 1 then
                return nil, "create_index failed: " .. tostring(ok.errmsg or keys.name)
            end
        elseif ok ~= true then
            return nil, "create_index failed: " .. tostring(err or keys.name)
        end
    end
    return true
end

return M
