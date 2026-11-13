local t = require "skytest"
local crypto = require "crypto"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/charge_order.lua")
local HASH = crypto.hmac_sha256

-- 订单集合的行为模型：只实现 find_and_modify / find_one 的等值语义
local function fake_orders()
    local store = {}
    local orders = { store = store, calls = {} }

    local function match(doc, query)
        for k, v in pairs(query) do
            if doc[k] ~= v then
                return false
            end
        end
        return true
    end

    function orders:find_one(query)
        for _, doc in pairs(self.store) do
            if match(doc, query) then
                return doc
            end
        end
        return nil
    end

    function orders:find_and_modify(opts)
        self.calls[#self.calls + 1] = opts
        local existing = self:find_one(opts.query)
        if existing then
            for k, v in pairs(opts.update["$set"] or {}) do
                existing[k] = v
            end
            for k in pairs(opts.update["$unset"] or {}) do
                existing[k] = nil
            end
            return { ok = 1, value = existing, lastErrorObject = { n = 1, updatedExisting = true } }
        end
        if not opts.upsert then
            return { ok = 1, value = "\0", lastErrorObject = { n = 0, updatedExisting = false } }
        end
        local doc = {}
        for k, v in pairs(opts.query) do
            doc[k] = v
        end
        for k, v in pairs(opts.update["$setOnInsert"] or {}) do
            doc[k] = v
        end
        for k, v in pairs(opts.update["$set"] or {}) do
            doc[k] = v
        end
        self.store[doc.provider .. ":" .. doc.order_id] = doc
        return { ok = 1, value = doc, lastErrorObject = { n = 1, updatedExisting = false } }
    end
    return orders
end

local function harness()
    local h = { now = 1700000000 }
    h.orders = fake_orders()
    local env = setmetatable({
        require = function(name)
            if name == "skyext.log" then
                return { debug = function() end, info = function() end, warn = function() end, error = function() end }
            end
            return require(name)
        end,
    }, { __index = _G })
    h.charge = assert(loadfile(source, "t", env))()

    function h.record(over)
        local opts = {
            provider = "wechat",
            order_id = "ORDER-1",
            rid = 7,
            amount = 600,
            currency = "CNY",
            action = "grant",
            hash_fn = HASH,
            now = h.now,
        }
        for k, v in pairs(over or {}) do
            opts[k] = v
        end
        return h.charge.record(h.orders, opts)
    end
    return h
end

t.describe("charge_order 落单", function()
    t.it("creates one order and returns the existing one for a repeated callback", function()
        local h = harness()
        local first, created = h.record()
        t.expect(created).to.equal(true)
        t.expect(first.status).to.equal(h.charge.STATUS.VERIFIED_RECEIVED)
        t.expect(first.service_op_id:sub(1, 4)).to.equal("srv_")
        t.expect(#first.service_op_id).to.equal(68)

        local second, again = h.record()
        t.expect(again).to.equal(false)
        t.expect(second.service_op_id).to.equal(first.service_op_id)
        -- 只有一条订单
        local n = 0
        for _ in pairs(h.orders.store) do
            n = n + 1
        end
        t.expect(n).to.equal(1)
    end)

    t.it("keeps the service op id stable across calls and processes", function()
        local h = harness()
        local first = assert(h.record())
        -- 另起一份模块实例（等价于另一个进程）也必须算出同一个键
        local other = harness()
        local second = assert(other.record())
        t.expect(second.service_op_id).to.equal(first.service_op_id)
        t.expect(h.charge.service_op_id("wechat", "ORDER-1", "grant", HASH)).to.equal(first.service_op_id)
    end)

    t.it("uses a different op id for a compensation", function()
        local h = harness()
        local order = assert(h.record())
        local comp = assert(h.charge.compensation_op_id(order, HASH))
        t.expect(comp ~= order.service_op_id).to.equal(true)
        t.expect(comp:sub(1, 4)).to.equal("srv_")
    end)

    -- JSON 渠道把商户参数按字符串回传极常见（"7" 而不是 7）。不归一就落库，
    -- 实体路由（calc_node）会在发奖时抛错，订单永远卡在 GRANTING
    t.it("normalizes a string or float rid before it reaches entity routing", function()
        local h = harness()
        local order = assert(h.record({ rid = "7" }))
        t.expect(math.type(order.rid)).to.equal("integer")
        t.expect(order.rid).to.equal(7)

        local h2 = harness()
        local order2 = assert(h2.record({ rid = 7.0 }))
        t.expect(math.type(order2.rid)).to.equal("integer")
        t.expect(order2.rid).to.equal(7)
    end)

    t.it("rejects a rid that is not a positive integer", function()
        local h = harness()
        t.expect(h.record({ rid = "abc" })).to.be_nil()
        t.expect(h.record({ rid = 0 })).to.be_nil()
        t.expect(h.record({ rid = -3 })).to.be_nil()
        t.expect(h.record({ rid = {} })).to.be_nil()
        -- tonumber 会收 "0x10"(16)、"7e2"(700)、" 7 "；这些不是纯十进制账号
        t.expect(h.record({ rid = "0x10" })).to.be_nil()
        t.expect(h.record({ rid = "7e2" })).to.be_nil()
        t.expect(h.record({ rid = " 7 " })).to.be_nil()
        -- float 超过 2^53 不能当账号（解析时可能已丢精度，只能靠量级拦）
        t.expect(h.record({ rid = 1e100 })).to.be_nil()
    end)

    -- 修复前字符串 rid 被原样落库：读侧不归一会把"重复回调"误判成
    -- order conflict（409），历史订单既不能被回调救也不能被对账救
    t.it("treats a legacy string rid in storage as the same account", function()
        local h = harness()
        h.orders.store["wechat:ORDER-1"] = {
            provider = "wechat",
            order_id = "ORDER-1",
            rid = "7",
            amount = 600,
            currency = "CNY",
            action = "grant",
            service_op_id = "srv_x",
            status = h.charge.STATUS.VERIFIED_RECEIVED,
        }
        local order, created = h.record()
        t.expect(order ~= nil).to.equal(true)
        t.expect(created).to.equal(false)
        t.expect(order.rid).to.equal("7")
    end)

    -- 重复回调金额/币种/账号不一致：是串单或伪造，不能"以最新一次为准"
    t.it("refuses a repeated callback with different amount, currency or account", function()
        local h = harness()
        assert(h.record())
        t.expect(h.record({ amount = 1 })).to.be_nil()
        t.expect(h.record({ currency = "USD" })).to.be_nil()
        t.expect(h.record({ rid = 8 })).to.be_nil()
    end)

    -- unique index 仍是 (provider, order_id)。不同 action 不能静默复用一个发奖单：
    -- 那会把退款/拒付回调吞成重复发奖，渠道收到 200 后也不会再推。
    t.it("refuses a repeated callback with a different action", function()
        local h = harness()
        local first = assert(h.record())
        local existing, err = h.record({ action = "compensate" })
        t.expect(existing).to.be_nil()
        t.expect(err).to.equal("order conflict")
        t.expect(h.orders.store["wechat:ORDER-1"].service_op_id).to.equal(first.service_op_id)
        t.expect(h.orders.store["wechat:ORDER-1"].action).to.equal("grant")
    end)

    t.it("rejects malformed callbacks before touching the collection", function()
        local h = harness()
        t.expect(h.record({ provider = "" })).to.be_nil()
        t.expect(h.record({ order_id = "" })).to.be_nil()
        t.expect(h.record({ amount = 0 })).to.be_nil()
        t.expect(h.record({ amount = 1.5 })).to.be_nil()
        t.expect(h.record({ currency = "" })).to.be_nil()
        local no_rid = {
            provider = "wechat",
            order_id = "ORDER-3",
            amount = 600,
            currency = "CNY",
            hash_fn = HASH,
            now = h.now,
        }
        t.expect(h.charge.record(h.orders, no_rid)).to.be_nil()
        -- nil 不会出现在表构造里，必须显式构造一份缺 hash_fn 的参数
        local no_hash = {
            provider = "wechat",
            order_id = "ORDER-2",
            rid = 7,
            amount = 600,
            currency = "CNY",
            now = h.now,
        }
        t.expect(h.charge.record(h.orders, no_hash)).to.be_nil()
        t.expect(#h.orders.calls).to.equal(0)
    end)
end)

t.describe("charge_order 状态机", function()
    t.it("advances only from the expected state", function()
        local h = harness()
        assert(h.record())
        local order =
            assert(h.charge.transition(h.orders, "wechat", "ORDER-1", "VERIFIED_RECEIVED", "GRANTING", nil, 100))
        t.expect(order.status).to.equal("GRANTING")

        -- 重复的"开始发奖"不能把状态推回去，也不能再成功一次
        t.expect(h.charge.transition(h.orders, "wechat", "ORDER-1", "VERIFIED_RECEIVED", "GRANTING", nil, 101)).to
            .be_nil()

        local granted =
            assert(h.charge.transition(h.orders, "wechat", "ORDER-1", "GRANTING", "GRANTED", { granted_at = 102 }, 102))
        t.expect(granted.status).to.equal("GRANTED")
        t.expect(granted.granted_at).to.equal(102)
    end)

    -- HTTP ACK 与业务状态分开保存：渠道允许"确认已接收"后异步发奖
    t.it("records the webhook ack independently of the business status", function()
        local h = harness()
        assert(h.record())
        local order = assert(h.charge.ack(h.orders, "wechat", "ORDER-1", h.charge.ACK.ACCEPTED, 50))
        t.expect(order.ack_result).to.equal("ACCEPTED")
        t.expect(order.webhook_ack_at).to.equal(50)
        -- 业务状态没有因此前进
        t.expect(order.status).to.equal("VERIFIED_RECEIVED")
        t.expect(h.charge.ack(h.orders, "wechat", "ORDER-1", "MAYBE", 51)).to.be_nil()
    end)

    t.it("can clear a reconciliation block after manual review", function()
        local h = harness()
        local order = assert(h.record())
        assert(h.charge.block_reconcile(h.orders, order, "manual review", 60))
        t.expect(h.orders.store["wechat:ORDER-1"].reconcile_blocked_at).to.equal(60)

        local cleared = assert(h.charge.unblock_reconcile(h.orders, order, 70))
        t.expect(cleared.reconcile_blocked_at).to.be_nil()
        t.expect(cleared.reconcile_unblocked_at).to.equal(70)
        t.expect(cleared.last_error).to.equal("manual review")
    end)
end)

t.describe("charge_order 发奖", function()
    local function harness_with_critical(decision)
        local h = harness()
        local calls = {}
        local env = setmetatable({
            require = function(name)
                if name == "skyext.critical" then
                    return {
                        STATUS = {
                            COMMITTED = "COMMITTED",
                            UNKNOWN = "UNKNOWN",
                            BUSINESS_REJECTED = "BUSINESS_REJECTED",
                        },
                        execute_internal = function(entity, op_id, op_type, params, handlers, opts)
                            calls[#calls + 1] =
                                { entity = entity, op_id = op_id, op_type = op_type, params = params, opts = opts }
                            return decision
                        end,
                    }
                end
                if name == "skyext.log" then
                    return {
                        debug = function() end,
                        info = function() end,
                        warn = function() end,
                        error = function() end,
                    }
                end
                return require(name)
            end,
        }, { __index = _G })
        h.charge = assert(loadfile(source, "t", env))()
        h.calls = calls
        return h
    end

    -- 回调可以直接从 VERIFIED_RECEIVED 发奖，不必先手动推到 GRANTING
    t.it("marks the order granted from the state it is actually in", function()
        local h = harness_with_critical({ status = "COMMITTED" })
        local order = assert(h.record())
        local result = h.charge.grant({ rid = 7 }, order, {}, {
            capability = {},
            hash_fn = HASH,
            orders_coll = h.orders,
            now = 110,
        })
        t.expect(result.status).to.equal("COMMITTED")
        t.expect(h.orders.store["wechat:ORDER-1"].status).to.equal("GRANTED")
    end)

    t.it("marks the order granted only after the critical commit is confirmed", function()
        local h = harness_with_critical({ status = "COMMITTED" })
        local order = assert(h.record())
        assert(h.charge.transition(h.orders, "wechat", "ORDER-1", "VERIFIED_RECEIVED", "GRANTING", nil, 100))

        local result = h.charge.grant({ rid = 7 }, order, {}, {
            capability = {},
            hash_fn = HASH,
            orders_coll = h.orders,
            now = 110,
        })
        t.expect(result.status).to.equal("COMMITTED")
        t.expect(h.calls[1].op_id).to.equal(order.service_op_id)
        t.expect(h.calls[1].opts.source_namespace).to.equal("charge_order")
        t.expect(h.calls[1].opts.source_id).to.equal("wechat:ORDER-1")
        t.expect(h.orders.store["wechat:ORDER-1"].status).to.equal("GRANTED")
    end)

    t.it("clears a stale reconciliation block when a grant finally succeeds", function()
        local h = harness_with_critical({ status = "COMMITTED" })
        local order = assert(h.record())
        assert(h.charge.block_reconcile(h.orders, order, "manual review", 100))
        local result = h.charge.grant({ rid = 7 }, order, {}, {
            capability = {},
            hash_fn = HASH,
            orders_coll = h.orders,
            now = 110,
        })
        t.expect(result.status).to.equal("COMMITTED")
        t.expect(h.orders.store["wechat:ORDER-1"].status).to.equal("GRANTED")
        t.expect(h.orders.store["wechat:ORDER-1"].reconcile_blocked_at).to.be_nil()
    end)

    -- UNKNOWN 不能重试成"没发"，也不能宣称已发：保持 GRANTING 等对账
    t.it("keeps the order in GRANTING when the grant outcome is unknown", function()
        local h = harness_with_critical({ status = "UNKNOWN", reason = "write concern timeout" })
        local order = assert(h.record())
        local result = h.charge.grant({ rid = 7 }, order, {}, {
            capability = {},
            hash_fn = HASH,
            orders_coll = h.orders,
            now = 110,
        })
        t.expect(result.status).to.equal("UNKNOWN")
        t.expect(h.orders.store["wechat:ORDER-1"].status).to.equal("GRANTING")
    end)

    t.it("refuses to grant an order that is already granted", function()
        local h = harness_with_critical({ status = "COMMITTED" })
        local order = assert(h.record())
        order.status = "GRANTED"
        local result = h.charge.grant({ rid = 7 }, order, {}, { capability = {}, hash_fn = HASH, now = 110 })
        t.expect(result.duplicate).to.equal(true)
        t.expect(#h.calls).to.equal(0)
    end)
end)

t.describe("charge_order 索引门禁", function()
    t.it("creates a unique (provider, order_id) index", function()
        local h = harness()
        local seen
        function h.orders:create_index(keys)
            seen = keys
            return { ok = 1 }
        end
        t.expect(h.charge.ensure_indexes(h.orders)).to.equal(true)
        t.expect(seen.unique).to.equal(true)
        t.expect(seen.name).to.equal("provider_order_id")
        t.expect(seen[1].provider).to.equal(1)
        t.expect(seen[2].order_id).to.equal(1)
    end)

    -- 驱动把 runCommand 的原始回复返回：ok=0 是失败，不能当成功放行
    t.it("refuses to enable the payment module when the index cannot be created", function()
        local h = harness()
        function h.orders:create_index()
            return { ok = 0, errmsg = "not authorized" }
        end
        local ok, err = h.charge.ensure_indexes(h.orders)
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("not authorized")

        function h.orders:create_index()
            error("network down")
        end
        ok, err = h.charge.ensure_indexes(h.orders)
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("raised")
    end)
end)

-- 订单是资金凭证：切主回滚会让"渠道已 ACK、订单行消失"变成永久丢单。
-- 集合支持多数派通道时必须走它，并且 UNKNOWN 不能当成功。
t.describe("charge_order 多数派写入", function()
    t.it("uses the majority channel when the collection offers it", function()
        local h = harness()
        local used = 0
        h.orders.critical_find_and_modify = function(self, opts)
            used = used + 1
            return "CONFIRMED", self:find_and_modify(opts)
        end
        local order = assert(h.record())
        t.expect(used).to.equal(1)
        t.expect(order.status).to.equal(h.charge.STATUS.VERIFIED_RECEIVED)
    end)

    t.it("fails the write when the majority channel cannot confirm it", function()
        local h = harness()
        h.orders.critical_find_and_modify = function()
            return "UNKNOWN", "write concern timeout"
        end
        local order, err = h.record()
        t.expect(order).to.be_nil()
        t.expect(err).to.equal("UNKNOWN")
        -- 没有落单成功就不能往下走：否则发奖会建立在一张可能不存在的订单上
        t.expect(next(h.orders.store)).to.be_nil()
    end)
end)
