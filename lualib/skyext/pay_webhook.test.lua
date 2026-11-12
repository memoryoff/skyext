local t = require "skytest"
local crypto = require "crypto"

local pay_webhook = require "skyext.pay_webhook"
local charge_order = require "skyext.charge_order"

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
        if type(v) == "table" then
            if v["$lte"] ~= nil then
                if doc[k] == nil or doc[k] > v["$lte"] then
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

-- 订单集合的最小替身：按 (provider, order_id) 匹配，支持 upsert 与状态 CAS
local function fake_orders()
    local store = { docs = {} }
    local coll = { fail = nil }

    local function find(query)
        for _, doc in pairs(store.docs) do
            if matches(doc, query) then
                return doc
            end
        end
        return nil
    end

    function coll:find_and_modify(opts)
        if coll.fail then
            return { ok = 0, errmsg = coll.fail }
        end
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

local function fake_req(path, body)
    return {
        path = path,
        read_json = function()
            if body == nil then
                return nil, "bad json"
            end
            return body
        end,
    }
end

local function provider(over)
    local p = {
        verify = function()
            return true
        end,
        parse = function(_, body)
            return {
                order_id = body.order_id,
                amount = body.amount,
                currency = body.currency,
                rid = body.rid,
            }
        end,
    }
    for k, v in pairs(over or {}) do
        p[k] = v
    end
    return p
end

local function harness(over)
    local h = {
        orders = fake_orders(),
        granted = {},
        scheduled = 0,
        decision = { status = "COMMITTED" },
    }
    local deps = {
        providers = { wechat = provider(over and over.provider) },
        orders_coll = h.orders,
        hash_fn = HASH,
        now = 1700000000,
        -- 实体侧只回 decision：订单状态由回调层推进（实体进程不持有订单集合）
        grant = function(order)
            h.granted[#h.granted + 1] = order
            return h.decision
        end,
        schedule_grant = function()
            h.scheduled = h.scheduled + 1
        end,
    }
    for k, v in pairs(over or {}) do
        if k ~= "provider" and k ~= "no_grant" then
            deps[k] = v
        end
    end
    if over and over.no_grant then
        deps.grant = nil
    end
    h.webhook = assert(pay_webhook.new(deps))
    h.body = { order_id = "o-1", amount = 100, currency = "CNY", rid = 7 }
    return h
end

t.describe("pay_webhook 入口校验", function()
    t.it("rejects an unknown provider", function()
        local h = harness()
        local out = h.webhook:handle(fake_req("/pay/alipay/callback", h.body))
        t.expect(out.status).to.equal(404)
        t.expect(out.body.code).to.equal("unknown_provider")
    end)

    t.it("rejects an unreadable body", function()
        local h = harness()
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", nil))
        t.expect(out.status).to.equal(400)
    end)

    -- 验签失败不能留下任何痕迹
    t.it("rejects a bad signature before persisting anything", function()
        local h = harness({
            provider = {
                verify = function()
                    return nil, "bad mac"
                end,
            },
        })
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(401)
        t.expect(#h.orders.store.docs).to.equal(0)
        t.expect(#h.granted).to.equal(0)
    end)

    t.it("rejects an unparsable payload", function()
        local h = harness({
            provider = {
                parse = function()
                    return nil, "missing amount"
                end,
            },
        })
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(400)
        t.expect(#h.orders.store.docs).to.equal(0)
    end)

    t.it("takes the provider from the query for a single callback path", function()
        local h = harness()
        local req = fake_req("/pay/callback", h.body)
        req.parse_query = function()
            return { provider = "wechat" }
        end
        local out = h.webhook:handle(req)
        t.expect(out.status).to.equal(200)
    end)
end)

t.describe("pay_webhook 落单与发奖", function()
    t.it("records the order, grants, and acks", function()
        local h = harness()
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(200)
        t.expect(out.body.status).to.equal("GRANTED")
        t.expect(#h.granted).to.equal(1)
        t.expect(h.granted[1].amount).to.equal(100)

        local order = h.orders.store.docs[1]
        t.expect(order.status).to.equal("GRANTED")
        t.expect(order.granted_at).to.equal(1700000000)
        t.expect(order.ack_result).to.equal("ACCEPTED")
        -- service_op_id 在第一次持久化时确定
        t.expect(#order.service_op_id).to.equal(68)
    end)

    -- UNKNOWN 不能回 500：订单已经落库，对账会收尾；让渠道重推只会制造重复回调
    t.it("acks an unknown grant and leaves the order in GRANTING", function()
        local h = harness()
        h.decision = { status = "UNKNOWN", reason = "write concern timeout" }
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(200)
        t.expect(out.body.status).to.equal("GRANTING")
        t.expect(h.orders.store.docs[1].status).to.equal("GRANTING")
        t.expect(h.orders.store.docs[1].ack_result).to.equal("ACCEPTED")
    end)

    -- INTERNAL_ERROR 是 validate 抛错（零写入）：不是契约失败，不能让渠道无限重推
    t.it("acks an internal validation error and leaves reconciliation to close it", function()
        local h = harness()
        h.decision = { status = "INTERNAL_ERROR", reason = "validate raised" }
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(200)
        t.expect(out.body.status).to.equal("GRANTING")
        t.expect(h.orders.store.docs[1].status).to.equal("GRANTING")
        t.expect(h.orders.store.docs[1].ack_result).to.equal("ACCEPTED")
    end)

    t.it("acks a business rejection and keeps it visible for compensation", function()
        local h = harness()
        h.decision = { status = "BUSINESS_REJECTED", reason = "role banned" }
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(200)
        t.expect(out.body.status).to.equal("REJECTED")
        t.expect(h.orders.store.docs[1].ack_result).to.equal("ACCEPTED")
        -- 钱收了、东西没给：留在 GRANTING 并记原因，等人工补偿
        t.expect(h.orders.store.docs[1].status).to.equal("GRANTING")
        t.expect(h.orders.store.docs[1].last_error).to.equal("role banned")
    end)

    t.it("asks the channel to retry when storage fails", function()
        local h = harness()
        h.orders.fail = "mongo down"
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(500)
        t.expect(out.body.code).to.equal("storage_unavailable")
        t.expect(#h.granted).to.equal(0)
    end)

    -- 同单号换金额：伪造或串单，必须拒绝而不是"以最新一次为准"
    t.it("rejects a duplicate order with different terms", function()
        local h = harness()
        assert(h.webhook:handle(fake_req("/pay/wechat/callback", h.body)))
        local forged = { order_id = "o-1", amount = 1, currency = "CNY", rid = 7 }
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", forged))
        t.expect(out.status).to.equal(409)
        t.expect(h.orders.store.docs[1].amount).to.equal(100)
    end)

    -- 渠道允许先 ACK：发奖排后台，订单状态保持 VERIFIED_RECEIVED
    t.it("acks before granting when the provider allows it", function()
        local h = harness({ provider = { ack_before_grant = true } })
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(200)
        t.expect(out.body.result).to.equal("accepted")
        t.expect(#h.granted).to.equal(0)
        t.expect(h.scheduled).to.equal(1)
        t.expect(h.orders.store.docs[1].ack_result).to.equal("ACCEPTED")
        -- 必须先进 GRANTING：否则后台发奖失败后对账扫不到这张单
        t.expect(h.orders.store.docs[1].status).to.equal("GRANTING")
    end)

    t.it("refuses to ack when no grant channel is configured", function()
        local h = harness({ no_grant = true })
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(500)
        t.expect(out.body.code).to.equal("grant_unavailable")
    end)

    t.it("returns 500 when the grant channel raises", function()
        local h = harness({
            grant = function()
                error("entity not found")
            end,
        })
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(500)
        t.expect(out.body.code).to.equal("grant_failed")
    end)
end)

t.describe("pay_webhook 配置校验", function()
    t.it("requires providers and a collection", function()
        t.expect(pay_webhook.new({})).to.be_nil()
        t.expect(pay_webhook.new({ providers = {} })).to.be_nil()
    end)
end)

t.describe("charge_order 对账入口", function()
    t.it("marks a granted order reconciled with proof", function()
        local orders = fake_orders()
        local order = assert(charge_order.record(orders, {
            provider = "wechat",
            order_id = "o-1",
            amount = 100,
            currency = "CNY",
            rid = 7,
            hash_fn = HASH,
            now = 1,
        }))
        assert(charge_order.transition(orders, "wechat", "o-1", "VERIFIED_RECEIVED", "GRANTED", nil, 2))

        local updated = assert(charge_order.mark_reconciled(orders, order, { op_id = order.service_op_id }, 3))
        t.expect(updated.status).to.equal("RECONCILED")
        t.expect(updated.reconciled_at).to.equal(3)
        t.expect(updated.reconcile_proof.op_id).to.equal(order.service_op_id)
    end)

    t.it("refuses to reconcile an order that is not granted", function()
        local orders = fake_orders()
        local order = assert(charge_order.record(orders, {
            provider = "wechat",
            order_id = "o-2",
            amount = 100,
            currency = "CNY",
            rid = 7,
            hash_fn = HASH,
            now = 1,
        }))
        local updated, err = charge_order.mark_reconciled(orders, order, { op_id = "srv_x" }, 3)
        t.expect(updated).to.be_nil()
        t.expect(err).to.equal("state mismatch")
    end)
end)

t.describe("pay_webhook 契约类失败", function()
    -- cap 绑定错误/同 op 换参数不是业务拒绝：不 ACK，回 5xx 让渠道重推并留日志
    t.it("returns 500 and keeps the order in GRANTING", function()
        local h = harness()
        h.decision = { status = "INTERNAL_AUTH_DENIED", reason = "capability_binding_mismatch" }
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(500)
        t.expect(out.body.code).to.equal("grant_rejected")
        t.expect(h.orders.store.docs[1].status).to.equal("GRANTING")
        t.expect(h.orders.store.docs[1].ack_result).to.be_nil()
    end)

    -- 重复回调（同单号同条款）不能重复发奖：实体侧靠 service_op_id 去重
    t.it("treats a repeat callback as the same order", function()
        local h = harness()
        assert(h.webhook:handle(fake_req("/pay/wechat/callback", h.body)))
        local out = h.webhook:handle(fake_req("/pay/wechat/callback", h.body))
        t.expect(out.status).to.equal(200)
        t.expect(#h.orders.store.docs).to.equal(1)
        t.expect(h.orders.store.docs[1].service_op_id).to.equal(h.granted[1].service_op_id)
    end)
end)
