local t = require "skytest"

local saga = require "skyext.saga"

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = copy(v)
    end
    return out
end

local function matches(doc, query)
    for k, v in pairs(query) do
        if k == "$or" then
            local any = false
            for _, sub in ipairs(v) do
                if matches(doc, sub) then
                    any = true
                    break
                end
            end
            if not any then
                return false
            end
        elseif type(v) == "table" then
            if v["$in"] then
                local hit = false
                for _, candidate in ipairs(v["$in"]) do
                    if doc[k] == candidate then
                        hit = true
                        break
                    end
                end
                if not hit then
                    return false
                end
            elseif v["$lte"] ~= nil then
                if doc[k] == nil or doc[k] > v["$lte"] then
                    return false
                end
            elseif v["$exists"] == false then
                if doc[k] ~= nil then
                    return false
                end
            else
                error("unsupported query operator: " .. tostring(next(v)))
            end
        elseif doc[k] ~= v then
            return false
        end
    end
    return true
end

local function apply(doc, update)
    for op, fields in pairs(update or {}) do
        if op == "$set" then
            for k, v in pairs(fields) do
                doc[k] = v
            end
        elseif op == "$unset" then
            for k in pairs(fields) do
                doc[k] = nil
            end
        elseif op == "$inc" then
            for k, v in pairs(fields) do
                doc[k] = (doc[k] or 0) + v
            end
        elseif op ~= "$setOnInsert" then
            -- $setOnInsert 在插入路径已经应用过，更新路径直接忽略
            error("unsupported update operator: " .. tostring(op))
        end
    end
end

local function fake_coll()
    local store = { docs = {}, calls = 0 }
    local coll = {}

    function coll:find_one(query)
        local doc = store.docs[query.saga_id]
        return doc and copy(doc) or nil
    end

    function coll:find_and_modify(opts)
        store.calls = store.calls + 1
        local doc = store.docs[opts.query.saga_id]
        local existed = doc ~= nil
        if not doc then
            if not opts.upsert then
                return { ok = 1, value = nil }
            end
            doc = {}
            apply(doc, { ["$set"] = opts.update["$setOnInsert"] })
            store.docs[opts.query.saga_id] = doc
        end
        apply(doc, opts.update)
        return { ok = 1, value = copy(doc), lastErrorObject = { updatedExisting = existed } }
    end

    function coll:critical_find_and_modify(opts)
        store.calls = store.calls + 1
        local doc = store.docs[opts.query.saga_id]
        if not doc then
            if not opts.upsert then
                return "CONFIRMED", { value = nil }
            end
            doc = {}
            apply(doc, { ["$set"] = opts.update["$setOnInsert"] })
            store.docs[opts.query.saga_id] = doc
            apply(doc, opts.update)
            return "CONFIRMED", { value = copy(doc), lastErrorObject = { updatedExisting = false } }
        end
        if not matches(doc, opts.query) then
            return "CONFIRMED", { value = nil }
        end
        apply(doc, opts.update)
        return "CONFIRMED", { value = copy(doc), lastErrorObject = { updatedExisting = true } }
    end

    function coll:create_index()
        return true
    end

    function coll:find_many(query, opts)
        local out = {}
        for _, doc in pairs(store.docs) do
            if matches(doc, query) then
                out[#out + 1] = copy(doc)
            end
        end
        table.sort(out, function(a, b)
            return (a.updated_at or 0) < (b.updated_at or 0)
        end)
        local limit = (opts and opts.limit) or #out
        while #out > limit do
            out[#out] = nil
        end
        return out
    end

    return coll, store
end

local HASH = function(domain, body)
    -- 稳定且对输入敏感：FNV-1a 展开成 32 字节
    local h = 2166136261
    for i = 1, #domain do
        h = (h ~ domain:byte(i)) * 16777619
        h = h & 0xFFFFFFFF
    end
    for i = 1, #body do
        h = (h ~ body:byte(i)) * 16777619
        h = h & 0xFFFFFFFF
    end
    local out = {}
    for i = 0, 31 do
        out[i + 1] = string.char((h >> ((i % 4) * 8)) & 0xFF)
    end
    return table.concat(out)
end

t.describe("saga 键推导", function()
    t.it("derives a deterministic saga id", function()
        local a = assert(saga.new_id("trade", "order-1", HASH))
        local b = assert(saga.new_id("trade", "order-1", HASH))
        t.expect(a).to.equal(b)
        t.expect(#a).to.equal(68)
        t.expect(a:sub(1, 4)).to.equal("sag_")
        t.expect(saga.new_id("trade", "order-2", HASH)).to_not.equal(a)
        t.expect(saga.new_id("other", "order-1", HASH)).to_not.equal(a)
    end)

    t.it("requires a hash function", function()
        t.expect(saga.new_id("trade", "order-1")).to.be_nil()
        t.expect(saga.new_id("", "order-1", HASH)).to.be_nil()
        t.expect(saga.new_id("trade", "", HASH)).to.be_nil()
    end)

    -- 步骤键必须字节级稳定：重试换了 event_id 就去重失效
    t.it("derives stable step keys", function()
        local a = assert(saga.step_keys("trade", "order-1", "reserve", HASH))
        local b = assert(saga.step_keys("trade", "order-1", "reserve", HASH))
        t.expect(a.event_id).to.equal(b.event_id)
        t.expect(#a.event_id).to.equal(68)
        t.expect(a.event_id:sub(1, 4)).to.equal("evt_")
        t.expect(a.service_op_id).to.equal("srv_" .. a.event_id:sub(5))
        t.expect(saga.step_keys("trade", "order-1", "commit", HASH).event_id).to_not.equal(a.event_id)
        t.expect(saga.step_keys("trade", "order-1", "", HASH)).to.be_nil()
    end)

    t.it("builds an envelope the outbox receiver accepts", function()
        local keys = assert(saga.step_keys("trade", "order-1", "reserve", HASH))
        local env = saga.envelope({ saga_id = "sag_x" }, keys, "role", 7, "gold.reserve", { gold = 10 }, "h")
        t.expect(env.version).to.equal(1)
        t.expect(env.source_type).to.equal("saga")
        t.expect(env.source_id).to.equal("sag_x")
        t.expect(env.event_id).to.equal(keys.event_id)
        t.expect(env.op_type).to.equal("gold.reserve")
    end)
end)

t.describe("saga 创建与认领", function()
    t.it("creates once and keeps the existing state", function()
        local coll, store = fake_coll()
        local doc, created = assert(saga.create(coll, { saga_id = "sag_1", kind = "trade", business_key = "o1" }))
        t.expect(created).to.equal(true)
        t.expect(doc.state).to.equal("CREATED")
        t.expect(doc.version).to.equal(0)

        assert(saga.transition(coll, "sag_1", "CREATED", "RESERVED", nil, { version = 0 }))
        local again, created_again = assert(saga.create(coll, { saga_id = "sag_1", kind = "trade" }))
        t.expect(created_again).to.equal(false)
        -- 重复创建不能把状态打回 CREATED
        t.expect(again.state).to.equal("RESERVED")
        t.expect(store.docs["sag_1"].version).to.equal(1)
    end)

    t.it("claims only claimable states", function()
        local coll = fake_coll()
        assert(saga.create(coll, { saga_id = "sag_1", kind = "trade" }))
        local ok = saga.claim(coll, "sag_1", "node-a", 1000, { now = 10 })
        t.expect(ok).to.equal(true)

        -- 租约还没过期：另一个协调者抢不走
        local stolen = saga.claim(coll, "sag_1", "node-b", 2000, { now = 20 })
        t.expect(stolen).to.equal(false)

        -- 租约过期后可以接管
        local taken = saga.claim(coll, "sag_1", "node-b", 3000, { now = 1001 })
        t.expect(taken).to.equal(true)

        -- 终态不再可认领
        assert(saga.transition(coll, "sag_1", "CREATED", "FAILED", nil, { version = 2 }))
        t.expect(saga.claim(coll, "sag_1", "node-c", 4000, { now = 9999 })).to.equal(false)
    end)

    t.it("refuses an illegal transition", function()
        local coll = fake_coll()
        assert(saga.create(coll, { saga_id = "sag_1", kind = "trade" }))
        local doc, err = saga.transition(coll, "sag_1", "CREATED", "COMPENSATED")
        t.expect(doc).to.be_nil()
        t.expect(err).to.match("illegal transition")
    end)

    -- 版本不匹配时不能推进：否则补偿会把已提交的交易推回 COMPENSATING
    t.it("requires the version to match", function()
        local coll = fake_coll()
        assert(saga.create(coll, { saga_id = "sag_1", kind = "trade" }))
        local doc, err = saga.transition(coll, "sag_1", "CREATED", "RESERVED", nil, { version = 99 })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("state mismatch")
    end)
end)

t.describe("saga 驱动", function()
    local function new_saga()
        local coll = fake_coll()
        assert(saga.create(coll, { saga_id = "sag_1", kind = "trade", business_key = "o1" }))
        return coll
    end

    t.it("moves CREATED to RESERVED when the reserve step commits", function()
        local coll = new_saga()
        local state = assert(saga.run(coll, "sag_1", {
            reserve = function()
                return "COMMITTED"
            end,
        }))
        t.expect(state).to.equal("RESERVED")
        t.expect(coll:find_one({ saga_id = "sag_1" }).state).to.equal("RESERVED")
    end)

    t.it("moves CREATED to FAILED when the reserve step is rejected", function()
        local coll = new_saga()
        local state = assert(saga.run(coll, "sag_1", {
            reserve = function()
                return "REJECTED"
            end,
        }))
        t.expect(state).to.equal("FAILED")
    end)

    t.it("keeps CREATED when the reserve step is unknown", function()
        local coll = new_saga()
        local state = assert(saga.run(coll, "sag_1", {
            reserve = function()
                return "UNKNOWN"
            end,
        }))
        t.expect(state).to.equal("CREATED")
        t.expect(coll:find_one({ saga_id = "sag_1" }).state).to.equal("CREATED")
    end)

    t.it("walks RESERVED to COMMITTED", function()
        local coll = new_saga()
        assert(saga.transition(coll, "sag_1", "CREATED", "RESERVED", nil, { version = 0 }))
        local state = assert(saga.run(coll, "sag_1", {
            commit = function()
                return "COMMITTED"
            end,
        }))
        t.expect(state).to.equal("COMMITTED")
        -- 终态再驱动是空操作
        local again = assert(saga.run(coll, "sag_1", {}))
        t.expect(again).to.equal("COMMITTED")
    end)

    t.it("enters compensation when the commit step is rejected", function()
        local coll = new_saga()
        assert(saga.transition(coll, "sag_1", "CREATED", "RESERVED", nil, { version = 0 }))
        local state = assert(saga.run(coll, "sag_1", {
            commit = function()
                return "REJECTED"
            end,
        }))
        t.expect(state).to.equal("COMPENSATING")
    end)

    t.it("finishes COMPENSATING only after the compensation commits", function()
        local coll = new_saga()
        assert(saga.transition(coll, "sag_1", "CREATED", "RESERVED", nil, { version = 0 }))
        assert(saga.transition(coll, "sag_1", "RESERVED", "COMPENSATING", nil, { version = 1 }))

        local state = assert(saga.run(coll, "sag_1", {
            compensate = function()
                return "UNKNOWN"
            end,
        }))
        -- 补偿结果未决：保持 COMPENSATING，资产还在可恢复的冻结状态
        t.expect(state).to.equal("COMPENSATING")

        state = assert(saga.run(coll, "sag_1", {
            compensate = function()
                return "COMMITTED"
            end,
        }))
        t.expect(state).to.equal("COMPENSATED")
    end)

    -- 步骤抛错不能当成成功，也不能当成业务拒绝
    t.it("treats a raising step as unknown", function()
        local coll = new_saga()
        local state = assert(saga.run(coll, "sag_1", {
            reserve = function()
                error("mongo down")
            end,
        }))
        t.expect(state).to.equal("CREATED")
    end)

    t.it("treats an unrecognized step result as unknown", function()
        local coll = new_saga()
        local state = assert(saga.run(coll, "sag_1", {
            reserve = function()
                return "ok"
            end,
        }))
        t.expect(state).to.equal("CREATED")
    end)

    t.it("reports a missing saga", function()
        local coll = fake_coll()
        local state, err = saga.run(coll, "sag_missing", {})
        t.expect(state).to.be_nil()
        t.expect(err).to.equal("not found")
    end)

    -- 失租的协调者不能继续执行步骤：否则它和新 owner 会并发跑不同的步骤
    t.it("refuses to run without holding the lease", function()
        local coll = fake_coll()
        assert(saga.create(coll, { saga_id = "sag_1", kind = "trade" }))
        assert(saga.claim(coll, "sag_1", "node-a", 1000, { now = 10 }))

        local ran = 0
        local state, err = saga.run(coll, "sag_1", {
            reserve = function()
                ran = ran + 1
                return "COMMITTED"
            end,
        }, { owner = "node-b", now = 20 })
        t.expect(state).to.be_nil()
        t.expect(err).to.equal("not owner")
        t.expect(ran).to.equal(0)

        local expired, eerr = saga.run(coll, "sag_1", {
            reserve = function()
                ran = ran + 1
                return "COMMITTED"
            end,
        }, { owner = "node-a", now = 5000 })
        t.expect(expired).to.be_nil()
        t.expect(eerr).to.equal("lease expired")
        t.expect(ran).to.equal(0)

        local ok = assert(saga.run(coll, "sag_1", {
            reserve = function()
                ran = ran + 1
                return "COMMITTED"
            end,
        }, { owner = "node-a", now = 500 }))
        t.expect(ok).to.equal("RESERVED")
        t.expect(ran).to.equal(1)
    end)
end)

t.describe("saga 手工补偿", function()
    -- 补偿是新操作，不是把提交回滚成没发生：必须显式调用并带原因
    t.it("requires a committed saga and a reason", function()
        local coll = fake_coll()
        assert(saga.create(coll, { saga_id = "sag_1", kind = "trade" }))
        local doc, err = saga.compensate(coll, "sag_1", { reason = "chargeback" })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("not committed")

        assert(saga.transition(coll, "sag_1", "CREATED", "RESERVED", nil, { version = 0 }))
        assert(saga.transition(coll, "sag_1", "RESERVED", "COMMITTED", nil, { version = 1 }))

        local missing, merr = saga.compensate(coll, "sag_1", {})
        t.expect(missing).to.be_nil()
        t.expect(merr).to.equal("reason is required")

        local started = assert(saga.compensate(coll, "sag_1", { reason = "chargeback", now = 10 }))
        t.expect(started.state).to.equal("COMPENSATING")
        t.expect(started.compensate_reason).to.equal("chargeback")
    end)
end)

t.describe("saga 到期扫描", function()
    t.it("returns only claimable sagas whose lease expired", function()
        local coll = fake_coll()
        assert(saga.create(coll, { saga_id = "sag_free", kind = "trade", now = 1 }))
        assert(saga.create(coll, { saga_id = "sag_busy", kind = "trade", now = 2 }))
        assert(saga.create(coll, { saga_id = "sag_done", kind = "trade", now = 3 }))
        assert(saga.claim(coll, "sag_busy", "node-a", 1000, { now = 10 }))
        assert(saga.transition(coll, "sag_done", "CREATED", "FAILED", nil, { version = 0 }))

        local due = assert(saga.scan_due(coll, { now = 20 }))
        local ids = {}
        for _, doc in ipairs(due) do
            ids[doc.saga_id] = true
        end
        t.expect(ids["sag_free"]).to.equal(true)
        -- 租约未过期：不能抢别人正在处理的
        t.expect(ids["sag_busy"]).to.be_nil()
        -- 终态永不进结果集
        t.expect(ids["sag_done"]).to.be_nil()

        local after = assert(saga.scan_due(coll, { now = 1001 }))
        local busy_found = false
        for _, doc in ipairs(after) do
            if doc.saga_id == "sag_busy" then
                busy_found = true
            end
        end
        t.expect(busy_found).to.equal(true)
    end)

    t.it("reports a scan error instead of an empty list", function()
        local ok, err = saga.scan_due({
            find_many = function()
                error("mongo down")
            end,
        })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("mongo down")
    end)
end)

t.describe("saga 索引门禁", function()
    t.it("fails when the unique index cannot be built", function()
        local ok, err = saga.ensure_indexes({
            saga = {
                create_index = function()
                    return { ok = 0, errmsg = "duplicate key" }
                end,
            },
        })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("duplicate key")
    end)

    t.it("accepts a confirmed build", function()
        local names = {}
        local coll = {
            create_index = function(_, keys)
                names[#names + 1] = keys.name
                return true
            end,
        }
        t.expect(saga.ensure_indexes({ saga = coll })).to.equal(true)
        t.expect(names[1]).to.equal("saga_id")
        t.expect(names[2]).to.equal("state_lease")
    end)
end)

-- R-10：复杂业务验证。协调者只驱动状态机，资产效果由步骤幂等保证；
-- 用可观测账本模拟双角色交易，断言重复投递 / 崩溃接管 / 补偿 ACK 丢失下
-- 同一业务操作最多一次经济效果。
t.describe("saga 复杂交易", function()
    local function new_trade()
        local coll = fake_coll()
        assert(saga.create(coll, { saga_id = "sag_trade", kind = "trade", business_key = "o1" }))
        return coll
    end

    t.it("moves value between two roles exactly once across retries", function()
        local coll = new_trade()
        local ledger = { a = 100, b = 0 }
        local applied = {}
        local function apply_once(key, fn)
            if applied[key] then
                return "COMMITTED"
            end
            fn()
            applied[key] = true
            return "COMMITTED"
        end
        local deps = {
            reserve = function(doc)
                return apply_once("reserve:" .. doc.saga_id, function()
                    ledger.a = ledger.a - 30
                end)
            end,
            commit = function(doc)
                return apply_once("commit:" .. doc.saga_id, function()
                    ledger.b = ledger.b + 30
                end)
            end,
        }

        assert(saga.run(coll, "sag_trade", deps))
        -- 重复驱动（可靠消息重投）：同一步再跑一次，账本不能变
        assert(saga.run(coll, "sag_trade", deps))
        t.expect(ledger.a).to.equal(70)
        t.expect(ledger.b).to.equal(30)
        t.expect(coll:find_one({ saga_id = "sag_trade" }).state).to.equal("COMMITTED")

        -- 终态再驱动不再执行任何步骤
        assert(saga.run(coll, "sag_trade", deps))
        t.expect(ledger.a).to.equal(70)
        t.expect(ledger.b).to.equal(30)
    end)

    -- 补偿是**至少一次**，不是恰好一次：ACK 丢失与补偿失败在协调者看来无法区分，
    -- 所以 handler 会被再次调用（refunds 从 1 变 2）。状态机保证的是
    -- "只离开 COMPENSATING 一次"，因此业务补偿必须幂等。
    -- 标题曾经写成 "compensates only once" 却断言 refunds==2，把两件事混成了一件
    t.it("retries compensation after a lost ack and leaves COMPENSATING only once", function()
        local coll = new_trade()
        local refunds = 0
        local deps = {
            reserve = function()
                return "COMMITTED"
            end,
            commit = function()
                return "REJECTED"
            end,
            compensate = function()
                refunds = refunds + 1
                -- 第一次补偿结果未决（ACK 丢失），第二次才确认
                return refunds == 1 and "UNKNOWN" or "COMMITTED"
            end,
        }

        assert(saga.run(coll, "sag_trade", deps)) -- CREATED -> RESERVED
        assert(saga.run(coll, "sag_trade", deps)) -- RESERVED -> COMPENSATING
        -- 第一次补偿结果未决（ACK 丢失）：状态必须停在 COMPENSATING
        assert(saga.run(coll, "sag_trade", deps))
        t.expect(coll:find_one({ saga_id = "sag_trade" }).state).to.equal("COMPENSATING")
        t.expect(refunds).to.equal(1)

        -- 重跑同一步：补偿确认后才进入 COMPENSATED
        assert(saga.run(coll, "sag_trade", deps))
        t.expect(coll:find_one({ saga_id = "sag_trade" }).state).to.equal("COMPENSATED")
        -- 至少一次：handler 被调了两次，所以它必须自带幂等
        t.expect(refunds).to.equal(2)

        -- 终态不再重复补偿：这是状态机提供的唯一保证
        assert(saga.run(coll, "sag_trade", deps))
        t.expect(refunds).to.equal(2)
    end)

    t.it("lets a new coordinator finish after the previous one crashed", function()
        local coll = new_trade()
        -- 第一个协调者认领后崩溃：什么都没推进
        local claimed = assert(saga.claim(coll, "sag_trade", "coord-a", 1000, { now = 100 }))
        t.expect(claimed).to.equal(true)
        t.expect(coll:find_one({ saga_id = "sag_trade" }).owner).to.equal("coord-a")

        -- 租约到期，第二个协调者接管并完成同一步
        local reclaimed = assert(saga.claim(coll, "sag_trade", "coord-b", 2000, { now = 1500 }))
        t.expect(reclaimed).to.equal(true)
        local state = assert(saga.run(coll, "sag_trade", {
            reserve = function()
                return "COMMITTED"
            end,
        }, { owner = "coord-b", now = 1500 }))
        t.expect(state).to.equal("RESERVED")
    end)

    t.it("refuses a second manual compensation for an already committed trade", function()
        local coll = new_trade()
        local deps = {
            reserve = function()
                return "COMMITTED"
            end,
            commit = function()
                return "COMMITTED"
            end,
        }
        assert(saga.run(coll, "sag_trade", deps))
        assert(saga.run(coll, "sag_trade", deps))
        t.expect(coll:find_one({ saga_id = "sag_trade" }).state).to.equal("COMMITTED")

        assert(saga.compensate(coll, "sag_trade", { reason = "chargeback" }))
        t.expect(coll:find_one({ saga_id = "sag_trade" }).state).to.equal("COMPENSATING")

        local again, err = saga.compensate(coll, "sag_trade", { reason = "chargeback" })
        t.expect(again).to.be_nil()
        t.expect(err).to.equal("not committed")
    end)
end)
