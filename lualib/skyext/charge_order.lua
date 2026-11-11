-- 支付订单与发奖（P09）。
--
-- 支付回调**独立于客户端授权**：它没有 Grant，只能用 `critical.execute_internal`
-- 走同一个提交内核。本模块负责订单落单、状态机与稳定的 `service_op_id`；
-- 资产效果仍然由 `critical` 决定。
--
-- 关键约束：
--   * `(provider, order_id)` 唯一索引：重复回调只能创建一条订单；
--   * `service_op_id` 在订单**第一次持久化时**确定并保存，重试不得重新计算——
--     密钥轮换后重新算会得到不同的键，去重立刻失效；
--   * HTTP ACK 状态（`webhook_ack_at` / `ack_result`）与业务状态分开保存：
--     渠道协议允许"确认已可靠接收"后异步发奖，不能一概要求先 GRANTED 再 ACK；
--   * `GRANTED` 只能在角色文档原子提交确认后转换，不能凭"调用成功"就标；
--   * 退款/拒付是**新的补偿操作**，不删原流水。
local canonical = require "skyext.canonical_lua"
local critical = require "skyext.critical"
local log = require "skyext.log"
local metrics = require "skyext.metrics"

local M = {}

M.STATUS = {
    VERIFIED_RECEIVED = "VERIFIED_RECEIVED",
    GRANTING = "GRANTING",
    GRANTED = "GRANTED",
    RECONCILED = "RECONCILED",
    -- 补偿（退款/拒付）走独立的操作，不修改原订单的业务终态
    COMPENSATING = "COMPENSATING",
    COMPENSATED = "COMPENSATED",
}

M.DOMAIN = "skyext:charge_order:v1"
M.ACK = {
    ACCEPTED = "ACCEPTED",
    REJECTED = "REJECTED",
}

local m_orders = metrics.counter("skyext_charge_orders_total", "Charge orders by status", { "status" })
local m_unknown = metrics.counter(
    "skyext_charge_grant_unknown_total",
    "Charge grants whose outcome could not be confirmed",
    { "provider" }
)

local function hex(bytes)
    return (bytes:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

local function check_text(value, name, max_len)
    if type(value) ~= "string" or #value == 0 or #value > (max_len or 128) then
        return nil, name .. " must be a non-empty string"
    end
    return value
end

-- 稳定操作键：同一 (provider, order_id, action) 在任何进程、任何时间都得到同一个键。
-- 用 hash_fn 而不是随机数——但**结果必须持久化**，之后只读不重算。
function M.service_op_id(provider, order_id, action, hash_fn)
    local p, err = check_text(provider, "provider")
    if not p then
        return nil, err
    end
    local o
    o, err = check_text(order_id, "order_id")
    if not o then
        return nil, err
    end
    local a
    a, err = check_text(action or "grant", "action")
    if not a then
        return nil, err
    end
    if type(hash_fn) ~= "function" then
        return nil, "hash_fn is required"
    end
    local body, berr = canonical.encode({ provider = p, order_id = o, action = a })
    if not body then
        return nil, berr
    end
    local ok, digest = pcall(hash_fn, M.DOMAIN, body)
    if not ok then
        return nil, "hash failed"
    end
    if type(digest) ~= "string" or #digest ~= 32 then
        return nil, "invalid digest"
    end
    return "srv_" .. hex(digest)
end

-- 回调验签后落单。返回 order, created；重复回调返回已有订单且 created=false。
-- 订单号与金额/币种/账号任一不一致都拒绝——那是伪造或串单，不能"以最新一次为准"。
function M.record(orders_coll, opts)
    if type(orders_coll) ~= "table" then
        return nil, "orders collection is required"
    end
    if type(opts) ~= "table" then
        return nil, "opts must be a table"
    end
    local provider, err = check_text(opts.provider, "provider", 32)
    if not provider then
        return nil, err
    end
    local order_id
    order_id, err = check_text(opts.order_id, "order_id", 128)
    if not order_id then
        return nil, err
    end
    if math.type(opts.amount) ~= "integer" or opts.amount <= 0 then
        return nil, "amount must be a positive integer"
    end
    local currency
    currency, err = check_text(opts.currency, "currency", 8)
    if not currency then
        return nil, err
    end
    if opts.rid == nil then
        return nil, "rid is required"
    end
    local service_op_id
    service_op_id, err = M.service_op_id(provider, order_id, opts.action, opts.hash_fn)
    if not service_op_id then
        return nil, err
    end

    local now = opts.now or os.time()
    local ret, ferr = orders_coll:find_and_modify({
        query = { provider = provider, order_id = order_id },
        update = {
            ["$setOnInsert"] = {
                provider = provider,
                order_id = order_id,
                rid = opts.rid,
                amount = opts.amount,
                currency = currency,
                action = opts.action or "grant",
                -- 第一次持久化时确定，之后只读不重算
                service_op_id = service_op_id,
                status = M.STATUS.VERIFIED_RECEIVED,
                created_at = now,
            },
        },
        upsert = true,
        new = true,
    })
    if type(ret) ~= "table" or ret.ok ~= 1 then
        -- 并发重复回调可能撞唯一索引（E11000）。这不是存储故障：回读一次，
        -- 是同一笔就按已有订单处理，否则才算冲突
        local existing = orders_coll:find_one({ provider = provider, order_id = order_id })
        if type(existing) == "table" then
            if existing.amount ~= opts.amount or existing.currency ~= currency or existing.rid ~= opts.rid then
                return nil, "order conflict"
            end
            return existing, false
        end
        return nil, (type(ret) == "table" and ret.errmsg) or ferr or "order upsert failed"
    end
    local order = ret.value
    if type(order) ~= "table" then
        -- upsert 命中已有文档但没回后像：回读一次
        order = orders_coll:find_one({ provider = provider, order_id = order_id })
    end
    if type(order) ~= "table" then
        return nil, "order not readable"
    end

    -- 用驱动给的 updatedExisting 判断是否新建。没有这个字段时返回 nil 而不是猜：
    -- 用"创建时间等于本次 now"兜底，同一秒内的重复回调会误报 created=true
    local leo = type(ret.lastErrorObject) == "table" and ret.lastErrorObject or nil
    local created
    if leo and leo.updatedExisting ~= nil then
        created = leo.updatedExisting == false
    end
    -- 重复回调必须与首次回调完全一致：金额/币种/账号任一不同都是串单或伪造
    if order.amount ~= opts.amount or order.currency ~= currency or order.rid ~= opts.rid then
        log.error(
            "charge order conflict",
            "provider",
            provider,
            "order_id",
            order_id,
            "expected_amount",
            order.amount,
            "got_amount",
            opts.amount
        )
        return nil, "order conflict"
    end
    m_orders:inc(1, { status = order.status })
    return order, created
end

-- 状态推进：只在 from 状态上做 CAS，避免重复回调把 GRANTED 退回 GRANTING
function M.transition(orders_coll, provider, order_id, from, to, extra, now)
    local set = { status = to, updated_at = now or os.time() }
    for k, v in pairs(extra or {}) do
        set[k] = v
    end
    local ret, err = orders_coll:find_and_modify({
        query = { provider = provider, order_id = order_id, status = from },
        update = { ["$set"] = set },
        new = true,
    })
    if type(ret) ~= "table" or ret.ok ~= 1 then
        return nil, (type(ret) == "table" and ret.errmsg) or err or "transition failed"
    end
    if type(ret.value) ~= "table" then
        -- 状态已经不是 from：并发回调或重复投递，读后像由调用方决定怎么处理
        return nil, "state mismatch"
    end
    m_orders:inc(1, { status = to })
    return ret.value
end

-- HTTP ACK 与业务状态分开保存：渠道允许"确认已接收"后异步发奖
function M.ack(orders_coll, provider, order_id, result, now)
    if result ~= M.ACK.ACCEPTED and result ~= M.ACK.REJECTED then
        return nil, "invalid ack result"
    end
    local ret, err = orders_coll:find_and_modify({
        query = { provider = provider, order_id = order_id },
        update = { ["$set"] = { webhook_ack_at = now or os.time(), ack_result = result } },
        new = true,
    })
    if type(ret) ~= "table" or ret.ok ~= 1 then
        return nil, (type(ret) == "table" and ret.errmsg) or err or "ack failed"
    end
    return type(ret.value) == "table" and ret.value or nil
end

-- 发奖参数：**唯一**一份构造。签发 capability 时要算摘要，执行时要算同一条摘要，
-- 两边各写一份就会因为字段顺序/缺省值不同而永远对不上
function M.grant_params(order)
    return {
        amount = order.amount,
        currency = order.currency,
        provider = order.provider,
        order_id = order.order_id,
    }
end

-- 发奖操作类型。订单里持久化的 action 是权威，默认 "grant"
function M.grant_op_type(order)
    return order.action or "grant"
end

-- 发奖来源标识：与 capability 绑定、与 `_critical_ops_v1` 落库归属一致
function M.source_id(order)
    return tostring(order.provider) .. ":" .. tostring(order.order_id)
end

-- 发奖：调用方已经验签并落单，这里只负责走关键提交内核并推进订单状态。
--
-- 返回值直接透传 critical 的 decision。只有 COMMITTED 才把订单推进到 GRANTED；
-- UNKNOWN 保持 GRANTING 并等待按 service_op_id 对账——**不能重试成"没发"**。
function M.grant(entity, order, handlers, opts)
    opts = opts or {}
    if type(order) ~= "table" then
        return nil, "order is required"
    end
    if order.status ~= M.STATUS.VERIFIED_RECEIVED and order.status ~= M.STATUS.GRANTING then
        -- 已经 GRANTED 的订单不能重复发奖；状态由对账推进
        return { status = order.status, duplicate = true }
    end

    local result = critical.execute_internal(
        entity,
        order.service_op_id,
        M.grant_op_type(order),
        M.grant_params(order),
        handlers,
        {
            capability = opts.capability,
            hash_fn = opts.hash_fn,
            source_namespace = "charge_order",
            source_id = M.source_id(order),
            now = opts.now,
        }
    )

    if result.status == critical.STATUS.COMMITTED then
        if opts.orders_coll then
            -- from 必须取订单当前状态：grant 允许从 VERIFIED_RECEIVED 直接进来
            -- （回调同步发奖），写死 GRANTING 会让 CAS 不命中、订单永远停在原状态
            M.transition(
                opts.orders_coll,
                order.provider,
                order.order_id,
                order.status,
                M.STATUS.GRANTED,
                { granted_at = opts.now or os.time() },
                opts.now
            )
        end
    elseif result.status == critical.STATUS.UNKNOWN then
        m_unknown:inc(1, { provider = order.provider })
        -- 保持 GRANTING：结果未决，不能宣称已发奖，也不能退回待发奖
        if opts.orders_coll then
            M.transition(
                opts.orders_coll,
                order.provider,
                order.order_id,
                M.STATUS.VERIFIED_RECEIVED,
                M.STATUS.GRANTING,
                { last_error = result.reason },
                opts.now
            )
        end
    end
    return result
end

-- 索引门禁：没有 (provider, order_id) 唯一索引，重复回调会创建出两条订单，
-- 发奖就可能执行两次。索引建不起来时调用方必须禁止启用支付模块
function M.ensure_indexes(orders_coll)
    if type(orders_coll) ~= "table" then
        return nil, "orders collection is required"
    end
    local called, ok, err = pcall(orders_coll.create_index, orders_coll, {
        { provider = 1 },
        { order_id = 1 },
        name = "provider_order_id",
        unique = true,
    })
    if not called then
        return nil, "create_index raised: " .. tostring(ok)
    end
    if type(ok) == "table" then
        if ok.ok ~= 1 then
            return nil, "create_index failed: " .. tostring(ok.errmsg)
        end
        return true
    end
    if ok ~= true then
        return nil, "create_index failed: " .. tostring(err)
    end
    return true
end

-- 退款/拒付是新的补偿操作：用独立的 service_op_id，不删原流水
function M.compensation_op_id(order, hash_fn)
    if type(order) ~= "table" then
        return nil, "order is required"
    end
    return M.service_op_id(order.provider, order.order_id, "compensate", hash_fn)
end

-- 只记错误、不改状态。业务拒绝或契约失败时订单要留在 GRANTING 等人工处理，
-- 用 transition 会把它推到一个不存在于状态机的状态
function M.note_error(orders_coll, order, err, now)
    if type(order) ~= "table" then
        return nil, "order is required"
    end
    local ret, ferr = orders_coll:find_and_modify({
        query = { provider = order.provider, order_id = order.order_id },
        update = { ["$set"] = { last_error = tostring(err), last_error_at = now or os.time() } },
        new = true,
    })
    if type(ret) ~= "table" or ret.ok ~= 1 then
        return nil, (type(ret) == "table" and ret.errmsg) or ferr or "note_error failed"
    end
    return type(ret.value) == "table" and ret.value or nil
end

-- 停止自动对账并把订单交给人工（业务拒绝、串单等）。状态不动，只打标记：
-- 把它推进到一个不存在的状态会让后续退款/补偿逻辑无从判断原始业务结果
function M.block_reconcile(orders_coll, order, reason, now)
    if type(order) ~= "table" then
        return nil, "order is required"
    end
    local ret, ferr = orders_coll:find_and_modify({
        query = { provider = order.provider, order_id = order.order_id },
        update = {
            ["$set"] = {
                reconcile_blocked_at = now or os.time(),
                last_error = tostring(reason),
            },
        },
        new = true,
    })
    if type(ret) ~= "table" or ret.ok ~= 1 then
        return nil, (type(ret) == "table" and ret.errmsg) or ferr or "block_reconcile failed"
    end
    return type(ret.value) == "table" and ret.value or nil
end

-- 对账：GRANTED -> RECONCILED。
--
-- 只有拿到"角色文档里该 op 已 COMMITTED"的持久化证明才允许推进；凭"调用成功过"
-- 就标 RECONCILED 等于把一次可能没落库的发奖当成已结案。
-- `proof` 会原样存进订单，事后能回答"凭什么认为发完了"。
function M.mark_reconciled(orders_coll, order, proof, now)
    if type(order) ~= "table" then
        return nil, "order is required"
    end
    if type(proof) ~= "table" then
        return nil, "proof is required"
    end
    local ret, err = orders_coll:find_and_modify({
        query = {
            provider = order.provider,
            order_id = order.order_id,
            status = M.STATUS.GRANTED,
        },
        update = {
            ["$set"] = {
                status = M.STATUS.RECONCILED,
                reconciled_at = now or os.time(),
                reconcile_proof = proof,
            },
        },
        new = true,
    })
    if type(ret) ~= "table" or ret.ok ~= 1 then
        return nil, (type(ret) == "table" and ret.errmsg) or err or "reconcile transition failed"
    end
    if type(ret.value) ~= "table" then
        -- 状态已经不是 GRANTED：并发对账或订单被补偿过
        return nil, "state mismatch"
    end
    m_orders:inc(1, { status = M.STATUS.RECONCILED })
    return ret.value
end

return M
