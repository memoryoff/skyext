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
            for k, v in pairs(opts.update["$inc"] or {}) do
                existing[k] = (existing[k] or 0) + v
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
        t.expect(order.rid).to.equal(7)
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
        local blocked = assert(h.charge.block_reconcile(h.orders, order, "manual review", 60))
        t.expect(h.orders.store["wechat:ORDER-1"].reconcile_blocked_at).to.equal(60)
        t.expect(h.orders.store["wechat:ORDER-1"].reconcile_block_version).to.equal(1)

        local cleared = assert(h.charge.unblock_reconcile(h.orders, blocked, 70))
        t.expect(cleared.reconcile_blocked_at).to.be_nil()
        t.expect(cleared.reconcile_unblocked_at).to.equal(70)
        t.expect(cleared.last_error).to.equal("manual review")
    end)

    -- 资金安全核心：GM 读到版本 A 之后订单被重新阻断成版本 B，旧解封必须失败。
    t.it("refuses to unblock a version that was superseded by a concurrent block", function()
        local h = harness()
        local order = assert(h.record())
        local version_a = assert(h.charge.block_reconcile(h.orders, order, "first", 60))
        local stale = {
            provider = version_a.provider,
            order_id = version_a.order_id,
            reconcile_blocked_at = version_a.reconcile_blocked_at,
            reconcile_block_version = version_a.reconcile_block_version,
        }
        -- 模拟另一个请求重新阻断，版本前进到 B
        assert(h.charge.block_reconcile(h.orders, version_a, "second", 61))
        local cleared, err = h.charge.unblock_reconcile(h.orders, stale, 70)
        t.expect(cleared).to.be_nil()
        t.expect(err).to.equal("CAS_CONFLICT")
        -- 新阻断必须保持有效
        t.expect(h.orders.store["wechat:ORDER-1"].reconcile_blocked_at).to.equal(61)
        t.expect(h.orders.store["wechat:ORDER-1"].reconcile_block_version).to.equal(2)
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

    t.it("does not let an automatic grant clear a manual reconciliation block", function()
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
        -- 阻断标记只能由人工显式解除（unblock_reconcile），自动发奖不得顺手清掉
        t.expect(h.orders.store["wechat:ORDER-1"].reconcile_blocked_at).to.equal(100)
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

    -- 写入可能已经在主节点生效、只是多数派确认丢了。普通 find_one 能看到它，
    -- 但那不是"可靠落单"：切主回滚后订单会消失，而渠道已经收到 200
    t.it("never confirms an unconfirmed write through a plain read", function()
        local h = harness()
        h.orders.critical_find_and_modify = function(self, opts)
            self:find_and_modify(opts)
            return "UNKNOWN", "write concern timeout"
        end
        local order, err = h.record()
        t.expect(order).to.be_nil()
        t.expect(err).to.equal("UNKNOWN")
        -- 文档确实已经能被普通读看到，正是这条"看得见但没确认"的路径
        t.expect(h.orders:find_one({ provider = "wechat", order_id = "ORDER-1" })).to.exist()

        -- 渠道重推时会重新走多数派通道，命中已有订单即视为幂等成功
        h.orders.critical_find_and_modify = function(self, opts)
            return "CONFIRMED", self:find_and_modify(opts)
        end
        local again, created = h.record()
        t.expect(again).to.exist()
        t.expect(created).to.equal(false)
    end)

    -- 缺多数派通道时所有状态推进都会退化成 w:1。支付模块必须在启动时 fail-fast
    t.it("refuses to start without a majority write channel", function()
        local h = harness()
        local ok, err = h.charge.check_write_channel(h.orders)
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("critical_find_and_modify")
        h.orders.critical_find_and_modify = function()
            return "CONFIRMED", {}
        end
        -- 写入通道有了，但重复订单的回读仍然没有多数派读通道
        ok, err = h.charge.check_write_channel(h.orders)
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("critical_find")
        h.orders.critical_find = function()
            return nil
        end
        t.expect(h.charge.check_write_channel(h.orders)).to.equal(true)
    end)
end)

-- P1-01：重复订单的回读必须是多数派读。
-- 普通 find_one 会读到主节点上尚未多数派确认的写入，随后切主回滚就是
-- "渠道 ACK 成功、订单凭证消失"。回读看不到时只能按 UNKNOWN 让渠道重推。
t.describe("charge_order 重复订单的多数派回读", function()
    local EXISTING = {
        provider = "wechat",
        order_id = "ORDER-1",
        rid = 7,
        amount = 600,
        currency = "CNY",
        action = "grant",
        service_op_id = "srv_x",
        status = "VERIFIED_RECEIVED",
    }

    t.it("treats a duplicate key as idempotent only when the majority read sees it", function()
        local h = harness()
        local reads = 0
        h.orders.critical_find_and_modify = function()
            -- 生产形状：mongo_conn 非 CONFIRMED 时只回 errmsg 字符串
            return "REJECTED", "E11000 duplicate key error collection: skyext.charge_order index: provider_order_id"
        end
        h.orders.critical_find = function()
            reads = reads + 1
            return EXISTING
        end
        local order, created = h.record()
        t.expect(reads).to.equal(1)
        t.expect(type(order)).to.equal("table")
        t.expect(created).to.equal(false)
        t.expect(order.rid).to.equal(7)
    end)

    -- 主节点上看得见、但多数派读看不见：写入可能还没被多数派确认，切主会回滚
    t.it("returns UNKNOWN when the duplicate is not visible to a majority read", function()
        local h = harness()
        h.orders.store["wechat:ORDER-1"] = {
            provider = "wechat",
            order_id = "ORDER-1",
            rid = 7,
            amount = 600,
            currency = "CNY",
            action = "grant",
        }
        h.orders.critical_find_and_modify = function()
            return "REJECTED", "E11000 duplicate key error collection: skyext.charge_order"
        end
        h.orders.critical_find = function()
            return nil
        end
        local order, err = h.record()
        t.expect(order).to.be_nil()
        t.expect(err).to.equal("UNKNOWN")
        -- 普通读明明看得到这条记录，也不能拿它当凭据
        t.expect(h.orders:find_one({ provider = "wechat", order_id = "ORDER-1" })).to.exist()
    end)

    t.it("returns UNKNOWN when the majority read fails without throwing", function()
        local h = harness()
        h.orders.critical_find_and_modify = function()
            return "REJECTED", "E11000 duplicate key error collection: skyext.charge_order"
        end
        -- 真实 critical_find 读失败是 2 元组 (nil, err)，不抛 Lua 错
        h.orders.critical_find = function()
            return nil, "majority read timeout"
        end
        local order, err = h.record()
        t.expect(order).to.be_nil()
        t.expect(err).to.equal("UNKNOWN")
    end)

    -- 传输层异常（驱动抛错）同样只能算未决，不能把订单当已存在
    t.it("returns UNKNOWN when the majority read raises", function()
        local h = harness()
        h.orders.critical_find_and_modify = function()
            return "REJECTED", "E11000 duplicate key error collection: skyext.charge_order"
        end
        h.orders.critical_find = function()
            error("connection reset")
        end
        local order, err = h.record()
        t.expect(order).to.be_nil()
        t.expect(err).to.equal("UNKNOWN")
    end)

    -- 非重复键的 REJECTED 是明确失败：不能回读，更不能把旧订单当成功返回
    t.it("does not treat a non-duplicate rejection as an idempotent hit", function()
        local h = harness()
        local reads = 0
        h.orders.store["wechat:ORDER-1"] = {
            provider = "wechat",
            order_id = "ORDER-1",
            rid = 7,
            amount = 600,
            currency = "CNY",
            action = "grant",
        }
        h.orders.critical_find_and_modify = function()
            return "REJECTED", { code = 13, errmsg = "not authorized" }
        end
        h.orders.critical_find = function()
            reads = reads + 1
            return h.orders.store["wechat:ORDER-1"]
        end
        local order, err = h.record()
        t.expect(order).to.be_nil()
        t.expect(err).to.match("not authorized")
        t.expect(reads).to.equal(0)
    end)
end)

local h_charge = require "skyext.charge_order"

-- P2-1：阻断单退出自动对账后，运维需要一个稳定翻页的清单
t.describe("charge_order 阻断单清单", function()
    local function coll(rows, err)
        local seen
        return {
            find_many = function(_, query, opts)
                seen = { query = query, opts = opts }
                if err then
                    return nil, err
                end
                return rows
            end,
        }, function()
            return seen
        end
    end

    t.it("returns a stable next cursor when the page is full", function()
        local rows = {}
        for i = 1, 3 do
            rows[i] = {
                provider = "wechat",
                order_id = "o-" .. i,
                updated_at = i,
                reconcile_blocked_at = i,
                reconcile_block_version = i,
                status = "GRANTING",
            }
        end
        local orders, seen = coll(rows)
        local list, cursor, err = h_charge.list_blocked(orders, { limit = 3 })
        t.expect(err).to.be_nil()
        t.expect(#list).to.equal(3)
        t.expect(cursor.blocked_at).to.equal(3)
        t.expect(cursor.block_version).to.equal(3)
        t.expect(cursor.provider).to.equal("wechat")
        t.expect(cursor.order_id).to.equal("o-3")
        t.expect(seen().query.reconcile_blocked_at["$exists"]).to.equal(true)
        t.expect(seen().opts.sort[1].reconcile_blocked_at).to.equal(1)
        t.expect(seen().opts.sort[2].reconcile_block_version).to.equal(1)
    end)

    t.it("supports the legacy updated_at cursor for existing GM callers", function()
        local rows = {}
        for i = 1, 3 do
            rows[i] = {
                provider = "wechat",
                order_id = "o-" .. i,
                updated_at = i,
                reconcile_blocked_at = i,
                reconcile_block_version = i,
            }
        end
        local orders, seen = coll(rows)
        local _, cursor, err = h_charge.list_blocked(orders, {
            limit = 3,
            cursor = { updated_at = 10, provider = "wechat", order_id = "o-2" },
        })
        t.expect(err).to.be_nil()
        t.expect(cursor.updated_at).to.equal(3)
        t.expect(seen().opts.sort[1].updated_at).to.equal(1)
    end)

    t.it("rejects an incomplete keyset cursor", function()
        local orders = coll({})
        local list, _, err = h_charge.list_blocked(orders, {
            cursor = { updated_at = 10, provider = "wechat" },
        })
        t.expect(list).to.be_nil()
        t.expect(err).to.equal("cursor.provider and cursor.order_id are required")
    end)

    t.it("clamps the page size and fails closed on a read error", function()
        local orders, seen = coll({}, "timeout")
        local list, cursor, err = h_charge.list_blocked(orders, { limit = 1000 })
        t.expect(list).to.be_nil()
        t.expect(cursor).to.be_nil()
        t.expect(err).to.match("timeout")
        t.expect(seen().opts.limit).to.equal(200)
    end)
end)
