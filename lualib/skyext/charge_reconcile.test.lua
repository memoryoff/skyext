local t = require "skytest"
local crypto = require "crypto"

local charge_order = require "skyext.charge_order"
local charge_reconcile = require "skyext.charge_reconcile"

local HASH = crypto.hmac_sha256

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
            local hit = false
            for _, candidate in ipairs(v) do
                if matches(doc, candidate) then
                    hit = true
                    break
                end
            end
            if not hit then
                return false
            end
        elseif type(v) == "table" then
            if v["$lte"] ~= nil then
                if doc[k] == nil or doc[k] > v["$lte"] then
                    return false
                end
            elseif v["$gt"] ~= nil then
                if doc[k] == nil or doc[k] <= v["$gt"] then
                    return false
                end
            elseif v["$in"] then
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
            elseif v["$exists"] == false then
                if doc[k] ~= nil then
                    return false
                end
            else
                error("unsupported query operator")
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
                doc[k] = copy(v)
            end
        elseif op == "$unset" then
            for k in pairs(fields) do
                doc[k] = nil
            end
        elseif op ~= "$setOnInsert" then
            error("unsupported update operator: " .. tostring(op))
        end
    end
end

local function fake_orders()
    local store = { docs = {} }
    local coll = {}

    local function find(query)
        for _, doc in pairs(store.docs) do
            if matches(doc, query) then
                return doc
            end
        end
        return nil
    end

    function coll:find_and_modify(opts)
        local doc = find(opts.query)
        if doc then
            apply(doc, opts.update)
            return { ok = 1, value = copy(doc), lastErrorObject = { updatedExisting = true } }
        end
        if not opts.upsert then
            return { ok = 1, value = nil }
        end
        doc = {}
        for k, v in pairs(opts.query) do
            if type(v) ~= "table" then
                doc[k] = v
            end
        end
        apply(doc, { ["$set"] = opts.update["$setOnInsert"] })
        apply(doc, opts.update)
        store.docs[#store.docs + 1] = doc
        return { ok = 1, value = copy(doc), lastErrorObject = { updatedExisting = false } }
    end

    function coll:find_many(query, opts)
        local out = {}
        for _, doc in pairs(store.docs) do
            if matches(doc, query) then
                out[#out + 1] = copy(doc)
            end
        end
        table.sort(out, function(a, b)
            for _, field in ipairs(opts and opts.sort or {}) do
                local key, direction = next(field)
                local av, bv = a[key], b[key]
                if av ~= bv then
                    if direction == -1 then
                        return av > bv
                    end
                    return av < bv
                end
            end
            return false
        end)
        local limit = (opts and opts.limit) or #out
        local page = {}
        for i = 1, math.min(#out, limit) do
            page[#page + 1] = out[i]
        end
        return page
    end

    function coll:find_one(query)
        local doc = find(query)
        return doc and copy(doc) or nil
    end

    function coll:create_index()
        return true
    end

    coll.store = store
    return coll
end

local function make_order(orders, over)
    local opts = {
        provider = "wechat",
        order_id = "o-1",
        amount = 100,
        currency = "CNY",
        rid = 7,
        hash_fn = HASH,
        now = 1,
    }
    for k, v in pairs(over or {}) do
        opts[k] = v
    end
    return assert(charge_order.record(orders, opts))
end

local function deps_for(orders, proof, over)
    -- `local d = { grant = function() d.x ... }` 里的 d 是全局：Lua 的局部变量在
    -- 声明语句之后才进作用域。必须分两步赋值
    local d = { orders_coll = orders, grants = 0 }
    d.query_op = function()
        return proof
    end
    d.grant = function()
        d.grants = d.grants + 1
        return { status = "COMMITTED" }
    end
    for k, v in pairs(over or {}) do
        d[k] = v
    end
    return d
end

t.describe("charge_reconcile 扫描", function()
    t.it("queries by status and a grace window", function()
        local orders = fake_orders()
        make_order(orders)
        local seen
        orders.find_many = function(_, query, opts)
            seen = { query = query, opts = opts }
            return {}
        end
        assert(charge_reconcile.scan_orders(orders, {
            status = "GRANTING",
            now = 1000,
            grace = 60,
            limit = 5,
            cursor = { updated_at = 900, provider = "wechat", order_id = "o-0" },
        }))
        t.expect(seen.query.status).to.equal("GRANTING")
        -- 宽限期：别抢刚进 GRANTING、发奖还在飞的单子
        t.expect(seen.query.updated_at["$lte"]).to.equal(940)
        t.expect(seen.opts.limit).to.equal(5)
        -- keyset 只扫上一页末尾之后的订单，避免 skip 在集合收缩时漂移
        t.expect(seen.query["$or"][1].updated_at["$gt"]).to.equal(900)
        t.expect(seen.query["$or"][2].provider["$gt"]).to.equal("wechat")
        t.expect(seen.query["$or"][3].order_id["$gt"]).to.equal("o-0")
        -- 稳定排序才能让 keyset 游标续扫
        t.expect(seen.opts.sort[1].updated_at).to.equal(1)
        t.expect(seen.opts.sort[2].provider).to.equal(1)
        t.expect(seen.opts.sort[3].order_id).to.equal(1)
    end)

    t.it("reports a scan error", function()
        local ok, err = charge_reconcile.scan_orders({
            find_many = function()
                error("mongo down")
            end,
        })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("mongo down")
    end)
end)

t.describe("charge_reconcile 对账", function()
    t.it("normalizes a legacy string rid before querying the owner", function()
        local queried
        local orders = fake_orders()
        local order = {
            provider = "wechat",
            order_id = "legacy",
            rid = "7",
            service_op_id = "srv_" .. string.rep("a", 64),
            status = "GRANTING",
        }
        orders.store.docs[1] = copy(order)
        local outcome = charge_reconcile.reconcile_order(orders, order, {
            query_op = function(rid)
                queried = rid
                return { status = "COMMITTED", version = 2 }
            end,
        }, { now = 10 })
        t.expect(outcome).to.equal(charge_reconcile.OUTCOME.GRANTED)
        t.expect(queried).to.equal(7)
    end)

    t.it("moves a stuck GRANTING order to GRANTED on proof", function()
        local orders = fake_orders()
        make_order(orders)
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTING", nil, 2))

        -- 对账读到的是**当前**订单状态（真实路径来自 scan）
        local order = assert(orders:find_one({ provider = "wechat", order_id = "o-1" }))
        local deps = deps_for(orders, { status = "COMMITTED", version = 4 })
        local outcome, proof = charge_reconcile.reconcile_order(orders, order, deps, { now = 10 })
        t.expect(outcome).to.equal("GRANTED")
        t.expect(proof.op_id).to.equal(order.service_op_id)
        t.expect(orders.store.docs[1].status).to.equal("GRANTED")
    end)

    t.it("reconciles a GRANTED order that never got its proof", function()
        local orders = fake_orders()
        make_order(orders)
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTED", nil, 2))

        local order = assert(orders:find_one({ provider = "wechat", order_id = "o-1" }))
        local deps = deps_for(orders, { status = "COMMITTED" })
        local outcome = charge_reconcile.reconcile_order(orders, order, deps, { now = 10 })
        t.expect(outcome).to.equal("RECONCILED")
        t.expect(orders.store.docs[1].status).to.equal("RECONCILED")
        t.expect(orders.store.docs[1].reconcile_proof.checked_at).to.equal(10)
    end)

    -- 落单后进程在 transition 到 GRANTING 前崩溃，但角色文档里其实已经 COMMITTED：
    -- 这是持久化事实，可以从 VERIFIED_RECEIVED 安全补到 GRANTED 并结案。
    t.it("closes a VERIFIED_RECEIVED order whose grant is already committed", function()
        local orders = fake_orders()
        local order = make_order(orders)
        local deps = deps_for(orders, { status = "COMMITTED", version = 9 })
        local outcome, proof = charge_reconcile.reconcile_order(orders, order, deps, { now = 10 })
        t.expect(outcome).to.equal("RECONCILED")
        t.expect(proof.version).to.equal(9)
        t.expect(orders.store.docs[1].status).to.equal("RECONCILED")
        -- 已有 COMMITTED 证明时只推进订单状态，不再调用一次发奖
        t.expect(deps.grants).to.equal(0)
    end)

    -- 状态推进必须依赖 CAS；本地读到的旧状态不能覆盖别的路径已经推进的结果
    t.it("does not claim success when the reconcile transition misses", function()
        local orders = fake_orders()
        local order = make_order(orders)
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTED", nil, 2))
        local stale = copy(order)
        local deps = deps_for(orders, { status = "COMMITTED" })
        local outcome = charge_reconcile.reconcile_order(orders, stale, deps, { now = 10 })
        t.expect(outcome).to.equal("PENDING")
        t.expect(orders.store.docs[1].status).to.equal("GRANTED")
    end)

    -- 发奖从未开始：重投一次，仍然是同一个 service_op_id
    t.it("re-grants when the operation never started", function()
        local orders = fake_orders()
        make_order(orders)
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTING", nil, 2))

        local order = assert(orders:find_one({ provider = "wechat", order_id = "o-1" }))
        local deps = deps_for(orders, { status = "NOT_STARTED" })
        local outcome = charge_reconcile.reconcile_order(orders, order, deps, { now = 10 })
        t.expect(deps.grants).to.equal(1)
        t.expect(outcome).to.equal("GRANTED")
        t.expect(orders.store.docs[1].status).to.equal("GRANTED")
    end)

    -- 查询失败不等于"没发"：绝不能因此把订单标成未发奖
    t.it("stays undecided when the proof cannot be read", function()
        local orders = fake_orders()
        local order = make_order(orders)
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTING", nil, 2))

        local deps = deps_for(orders, nil, {
            query_op = function()
                return nil, "entity not found"
            end,
        })
        local outcome = charge_reconcile.reconcile_order(orders, order, deps, { now = 10 })
        t.expect(outcome).to.equal("UNKNOWN")
        t.expect(orders.store.docs[1].status).to.equal("GRANTING")
    end)

    -- 收了钱但业务拒绝发货：要人工补偿，worker 不能悄悄结案
    t.it("does not close a business-rejected grant", function()
        local orders = fake_orders()
        local order = make_order(orders)
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTING", nil, 2))

        local deps = deps_for(orders, { status = "BUSINESS_REJECTED" })
        local outcome = charge_reconcile.reconcile_order(orders, order, deps, { now = 10 })
        t.expect(outcome).to.equal("BUSINESS_REJECTED")
        t.expect(orders.store.docs[1].status).to.equal("GRANTING")
        -- 转人工之后不再自动扫，避免它每轮占掉一个扫描名额
        t.expect(orders.store.docs[1].reconcile_blocked_at).to.equal(10)
    end)

    -- 重投发奖仍然被预检拒绝：这条 op 永远不会在角色文档里留下记录，若只记 RETRY，
    -- 对账会每一轮都自动重投一次，等于把"人工补偿单"变成无限自动重试
    t.it("blocks a rejected regrant instead of retrying it forever", function()
        local orders = fake_orders()
        local order = make_order(orders)
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTING", nil, 2))

        local grants = 0
        local deps = deps_for(orders, { status = "NOT_STARTED" })
        deps.grant = function()
            grants = grants + 1
            return { status = "PRECHECK_REJECTED", reason = "mail module is not loaded" }
        end
        local outcome = charge_reconcile.reconcile_order(orders, order, deps, { now = 10 })
        t.expect(grants).to.equal(1)
        t.expect(outcome).to.equal("BUSINESS_REJECTED")
        t.expect(orders.store.docs[1].status).to.equal("GRANTING")
        t.expect(orders.store.docs[1].reconcile_blocked_at).to.equal(10)
        t.expect(orders.store.docs[1].last_error).to.equal("mail module is not loaded")
    end)

    t.it("stops regranting the rejected order on later rounds", function()
        local orders = fake_orders()
        make_order(orders)
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTING", nil, 2))

        local grants = 0
        local deps = deps_for(orders, { status = "NOT_STARTED" })
        deps.grant = function()
            grants = grants + 1
            return { status = "PRECHECK_REJECTED", reason = "mail module is not loaded" }
        end

        local first = assert(charge_reconcile.run_once(deps, { now = 1000, grace = 60 }))
        t.expect(first.rejected).to.equal(1)
        t.expect(grants).to.equal(1)

        -- 第二轮：订单已被阻断，不再进入扫描集合，发奖函数一次都不该再被调用
        local second = assert(charge_reconcile.run_once(deps, { now = 1060, grace = 60 }))
        t.expect(second.scanned).to.equal(0)
        t.expect(grants).to.equal(1)
    end)

    t.it("leaves an in-progress grant for the next round", function()
        local orders = fake_orders()
        local order = make_order(orders)
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTING", nil, 2))

        local deps = deps_for(orders, { status = "IN_PROGRESS" })
        local outcome = charge_reconcile.reconcile_order(orders, order, deps, { now = 10 })
        t.expect(outcome).to.equal("PENDING")
        t.expect(orders.store.docs[1].status).to.equal("GRANTING")
    end)
end)

t.describe("charge_reconcile 单轮", function()
    t.it("reconciles both GRANTED and GRANTING orders", function()
        local orders = fake_orders()
        make_order(orders, { order_id = "o-1" })
        make_order(orders, { order_id = "o-2" })
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTED", nil, 2))
        assert(charge_order.transition(orders, "wechat", "o-2", "VERIFIED_RECEIVED", "GRANTING", nil, 2))

        local deps = deps_for(orders, { status = "COMMITTED" })
        local stats = assert(charge_reconcile.run_once(deps, { now = 1000, grace = 0 }))
        t.expect(stats.scanned).to.equal(2)
        t.expect(stats.reconciled).to.equal(1)
        t.expect(stats.granted).to.equal(1)
    end)

    t.it("requires a proof query", function()
        t.expect(charge_reconcile.run_once({ orders_coll = fake_orders() })).to.be_nil()
    end)

    t.it("propagates a scan failure", function()
        local orders = fake_orders()
        orders.find_many = function()
            error("mongo down")
        end
        local ok, err = charge_reconcile.run_once({ orders_coll = orders, query_op = function() end }, {})
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("mongo down")
    end)

    -- 每页都被毒单填满时，游标必须向后翻；否则同一批最早的单永远占满结果集
    t.it("rotates the scan cursor past a full page of stuck orders", function()
        local orders = fake_orders()
        for i = 1, 3 do
            assert(charge_order.record(orders, {
                provider = "wechat",
                order_id = "poison-" .. i,
                rid = 7,
                amount = 100,
                currency = "CNY",
                hash_fn = HASH,
                now = 1,
            }))
            assert(charge_order.transition(orders, "wechat", "poison-" .. i, "VERIFIED_RECEIVED", "GRANTING", nil, 1))
        end

        local deps = deps_for(orders, { status = "IN_PROGRESS" })
        deps.scan_cursors = {}
        local first = assert(charge_reconcile.run_once(deps, { now = 1000, grace = 0, limit = 2 }))
        t.expect(first.scanned).to.equal(2)
        -- 三张单 updated_at 相同，游标必须用 provider/order_id 决胜
        t.expect(deps.scan_cursors.GRANTING.updated_at).to.equal(1)
        t.expect(deps.scan_cursors.GRANTING.provider).to.equal("wechat")
        t.expect(deps.scan_cursors.GRANTING.order_id).to.equal("poison-2")

        local second = assert(charge_reconcile.run_once(deps, { now = 1000, grace = 0, limit = 2 }))
        t.expect(second.scanned).to.equal(1)
        t.expect(deps.scan_cursors.GRANTING).to.be_nil()
    end)
end)

t.describe("charge_reconcile 索引门禁", function()
    t.it("fails when the index cannot be built", function()
        local ok, err = charge_reconcile.ensure_indexes({
            orders = {
                create_index = function()
                    return { ok = 0, errmsg = "unauthorized" }
                end,
            },
        })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("unauthorized")
    end)

    t.it("accepts a confirmed build", function()
        local seen
        local coll = {
            create_index = function(_, keys)
                seen = keys
                return true
            end,
        }
        t.expect(charge_reconcile.ensure_indexes({ orders = coll })).to.equal(true)
        t.expect(seen.name).to.equal("status_updated_at_order")
        t.expect(seen[1].status).to.equal(1)
        t.expect(seen[2].updated_at).to.equal(1)
        t.expect(seen[3].provider).to.equal(1)
        t.expect(seen[4].order_id).to.equal(1)
    end)
end)

t.describe("charge_reconcile 卡在 VERIFIED_RECEIVED 的单", function()
    -- 落单成功、进程在 transition 到 GRANTING 之前崩掉：这张单没有任何后续状态，
    -- 只按 GRANTED/GRANTING 扫就永远看不到它 —— 钱收了、奖不发、也没人知道
    t.it("scans and re-grants an order stuck in VERIFIED_RECEIVED", function()
        local orders = fake_orders()
        local order = make_order(orders, { now = 1 })
        t.expect(order.status).to.equal(charge_order.STATUS.VERIFIED_RECEIVED)
        -- 落单必须写 updated_at，否则 updated_at <= now - grace 永远不匹配
        t.expect(order.updated_at).to.equal(1)

        local deps = deps_for(orders, { status = "NOT_STARTED" })
        local stats = assert(charge_reconcile.run_once(deps, { now = 1000, grace = 30 }))
        t.expect(stats.scanned).to.equal(1)
        t.expect(deps.grants).to.equal(1)
    end)

    -- 宽限期仍然生效：刚落单、回调还在飞的单子不能被对账抢走
    t.it("leaves a fresh VERIFIED_RECEIVED order alone", function()
        local orders = fake_orders()
        make_order(orders, { now = 1000 })
        local deps = deps_for(orders, { status = "NOT_STARTED" })
        local stats = assert(charge_reconcile.run_once(deps, { now = 1000, grace = 30 }))
        t.expect(stats.scanned).to.equal(0)
        t.expect(deps.grants).to.equal(0)
    end)
end)
