-- 支付回调处理（P09）。
--
-- 回调**独立于客户端授权**：它没有 Grant，只有渠道签名。处理顺序是固定的：
--
--   验签 -> 解析商品/金额/币种/账号 -> 落单(唯一索引) -> ACK -> 发奖
--
-- 三条硬约束：
--   * ACK 状态与业务状态分开存：渠道允许"确认已可靠接收"后异步发奖，
--     不能一概要求先 GRANTED 再 ACK，否则渠道会一直重推；
--   * 发奖结果 UNKNOWN 时照样 ACK：订单已经持久化，对账 worker 会按
--     `service_op_id` 收尾。回 500 让渠道重推只会制造更多重复回调；
--   * 验签失败/串单绝不 ACK，也不能落单。
--
-- 本模块是纯逻辑，不碰 skynet：`handle` 返回 `{ status, body }`，
-- 由 `service/pay_callback.lua` 写到 HTTP 响应里。
local charge_order = require "skyext.charge_order"
local log = require "skyext.log"
local metrics = require "skyext.metrics"

local M = {}

local m_requests = metrics.counter("skyext_pay_callback_total", "Payment callbacks by result", { "result" })
local m_grant = metrics.counter("skyext_pay_grant_total", "Payment grant outcomes", { "status" })

local function reject(status, code, extra)
    local body = { code = code }
    for k, v in pairs(extra or {}) do
        body[k] = v
    end
    return { status = status, body = body }
end

local Webhook = {}
Webhook.__index = Webhook

-- deps:
--   providers[name] = {
--     verify(req, body) -> true | nil, err
--     parse(req, body)  -> { order_id, amount, currency, rid, action } | nil, err
--     ack_before_grant  -> boolean（渠道允许先 ACK 后发奖时为真）
--   }
--   orders_coll   订单集合
--   grant(order)  -> critical decision（由调用方经 router.call 到实体执行）
--   schedule_grant(order)  可选：先 ACK 时把发奖排到后台
--   provider_of(req)       可选：默认从路径 /pay/<provider> 取
--   now
function M.new(deps)
    if type(deps) ~= "table" then
        return nil, "deps are required"
    end
    if type(deps.providers) ~= "table" then
        return nil, "providers are required"
    end
    if type(deps.orders_coll) ~= "table" then
        return nil, "orders collection is required"
    end
    return setmetatable({
        providers = deps.providers,
        orders_coll = deps.orders_coll,
        grant_fn = deps.grant,
        schedule_grant = deps.schedule_grant,
        provider_of = deps.provider_of,
        hash_fn = deps.hash_fn,
        now = deps.now,
    }, Webhook)
end

function Webhook:provider_name(req)
    if type(self.provider_of) == "function" then
        return self.provider_of(req)
    end
    if type(req) ~= "table" then
        return nil
    end
    local path = req.path
    if type(path) == "string" then
        -- /pay/<provider>/callback 或 /pay/<provider>
        local name = path:match("^/pay/([%w_%-]+)")
        if name and name ~= "callback" then
            return name
        end
        -- 渠道只允许一个固定回调地址时，provider 走 query
        if path == "/pay/callback" and type(req.parse_query) == "function" then
            local ok, query = pcall(req.parse_query)
            if ok and type(query) == "table" then
                return query.provider
            end
        end
    end
    return nil
end

function Webhook:handle(req)
    if type(req) ~= "table" or type(req.read_json) ~= "function" then
        return reject(400, "bad_request")
    end
    local name = self:provider_name(req)
    if not name then
        m_requests:inc(1, { result = "unknown_provider" })
        return reject(404, "unknown_provider")
    end
    local provider = self.providers[name]
    if type(provider) ~= "table" then
        m_requests:inc(1, { result = "unknown_provider" })
        return reject(404, "unknown_provider")
    end

    local body, berr = req.read_json()
    if type(body) ~= "table" then
        log.debug("pay callback body rejected", "provider", name, "err", tostring(berr))
        m_requests:inc(1, { result = "bad_body" })
        return reject(400, "bad_body")
    end

    -- 验签在任何持久化之前：未通过验签的请求不能留下任何痕迹
    local verified, verr = provider.verify(req, body)
    if not verified then
        log.warn("pay callback signature rejected", "provider", name, "err", tostring(verr))
        m_requests:inc(1, { result = "bad_signature" })
        return reject(401, "bad_signature")
    end

    local fields, perr = provider.parse(req, body)
    if type(fields) ~= "table" then
        log.warn("pay callback payload rejected", "provider", name, "err", tostring(perr))
        m_requests:inc(1, { result = "bad_payload" })
        return reject(400, "bad_payload")
    end

    -- 金额必须是整数最小单位：渠道常把 "0.01" 传成浮点，交给落单会被当成
    -- 存储故障回 500，把"参数不对"误判成"Mongo 挂了"
    if math.type(fields.amount) ~= "integer" or fields.amount <= 0 then
        log.warn("pay callback amount is not a positive integer", "provider", name)
        m_requests:inc(1, { result = "bad_payload" })
        return reject(400, "bad_payload")
    end

    local now = self.now or os.time()
    local order, created = charge_order.record(self.orders_coll, {
        provider = name,
        order_id = fields.order_id,
        amount = fields.amount,
        currency = fields.currency,
        rid = fields.rid,
        action = fields.action,
        hash_fn = fields.hash_fn or self.hash_fn,
        now = now,
    })
    if not order then
        if created == "order conflict" then
            -- 同一单号换了金额/币种/账号：伪造或串单，必须人工看
            log.error("pay callback order conflict", "provider", name, "order_id", tostring(fields.order_id))
            m_requests:inc(1, { result = "conflict" })
            return reject(409, "order_conflict")
        end
        -- 存储不可用：让渠道重推，不要谎称已接收
        log.error("pay callback order persist failed", "provider", name, "err", tostring(created))
        m_requests:inc(1, { result = "storage" })
        return reject(500, "storage_unavailable")
    end

    -- 发奖前先推进到 GRANTING。订单状态的权威在订单集合（回调层持有），
    -- 不在实体进程；不先落这一步，发奖中途崩溃的单子对账永远扫不到
    local marked = charge_order.transition(
        self.orders_coll,
        name,
        order.order_id,
        charge_order.STATUS.VERIFIED_RECEIVED,
        charge_order.STATUS.GRANTING,
        nil,
        now
    )
    if marked then
        order = marked
    elseif order.status == charge_order.STATUS.VERIFIED_RECEIVED then
        log.error("pay callback state transition failed", "order", tostring(order.order_id))
        m_requests:inc(1, { result = "storage" })
        return reject(500, "state_transition_failed")
    end

    -- 渠道允许先 ACK：订单已可靠落库并进入 GRANTING，发奖交给后台与对账。
    -- 即使 schedule_grant 失败，对账也会按 GRANTING 把单子捞起来
    if provider.ack_before_grant then
        self:ack(name, order, now)
        if type(self.schedule_grant) == "function" then
            local ok, serr = pcall(self.schedule_grant, order)
            if not ok then
                log.error("pay grant scheduling failed", "order", tostring(order.order_id), "err", tostring(serr))
            end
        end
        m_requests:inc(1, { result = "accepted" })
        return { status = 200, body = { result = "accepted", status = charge_order.STATUS.GRANTING } }
    end

    if type(self.grant_fn) ~= "function" then
        -- 没有发奖通道：已经落单，不能 ACK 成"已处理"
        log.error("pay callback has no grant channel", "provider", name)
        m_requests:inc(1, { result = "storage" })
        return reject(500, "grant_unavailable")
    end

    local called, decision = pcall(self.grant_fn, order)
    if not called then
        log.error("pay grant raised", "order", tostring(order.order_id), "err", tostring(decision))
        m_requests:inc(1, { result = "grant_error" })
        return reject(500, "grant_failed")
    end
    if type(decision) ~= "table" then
        log.error("pay grant returned no decision", "order", tostring(order.order_id))
        m_requests:inc(1, { result = "grant_error" })
        return reject(500, "grant_failed")
    end

    local status = decision.status
    m_grant:inc(1, { status = tostring(status) })

    if status == "COMMITTED" or decision.duplicate then
        local moved = charge_order.transition(
            self.orders_coll,
            name,
            order.order_id,
            charge_order.STATUS.GRANTING,
            charge_order.STATUS.GRANTED,
            { granted_at = now },
            now,
            { reconcile_blocked_at = true }
        )
        if not moved and order.status == charge_order.STATUS.GRANTED then
            -- 已 GRANTED 的重复回调不会再触发状态迁移，但仍应解除此前的人工阻断
            charge_order.unblock_reconcile(self.orders_coll, order, now)
        end
        self:ack(name, order, now)
        m_requests:inc(1, { result = "granted" })
        return { status = 200, body = { result = "accepted", status = charge_order.STATUS.GRANTED } }
    end

    if status == "CAPACITY_EXCEEDED" then
        -- 容量超限不是"结果未决"：当前发奖没有开始，订单留在 GRANTING 等
        -- critical_maintenance 腾出账本空间。必须让渠道重推，不能 ACK 后把
        -- 唯一的重试入口交给一个可能根本未启用的维护服务。
        charge_order.note_error(self.orders_coll, order, tostring(decision.reason or status), now)
        log.error("pay grant capacity exceeded, asking channel to retry", "order", tostring(order.order_id))
        m_requests:inc(1, { result = "capacity_exceeded" })
        return reject(503, "capacity_exceeded", { retryable = true })
    end

    if status == "UNKNOWN" or status == "IN_PROGRESS" or status == "INTERNAL_ERROR" then
        -- 结果未决/暂态：订单留在 GRANTING，ACK 之后由对账 worker 收尾。
        -- INTERNAL_ERROR 是 validate 自身抛错，PREPARE 之前零写入，
        -- critical.query 只会回 NOT_STARTED；它不是契约失败，回 500 让渠道
        -- 反复重推同一个服务端 bug 只会制造重复回调，拿不到额外信息。
        -- 对账侧会重投 grant，重投仍失败时按 RETRY 留待下一轮。
        self:ack(name, order, now)
        m_requests:inc(1, { result = "unknown" })
        return { status = 200, body = { result = "accepted", status = charge_order.STATUS.GRANTING } }
    end

    if status == "BUSINESS_REJECTED" or status == "PRECHECK_REJECTED" then
        -- 钱收了、东西没给：留 GRANTING 并记原因，等人工补偿。
        -- 渠道侧仍然 ACK，避免它无限重推同一笔
        charge_order.note_error(self.orders_coll, order, tostring(decision.reason or status), now)
        self:ack(name, order, now)
        log.error(
            "pay grant rejected by business rules, manual compensation required",
            "order",
            tostring(order.order_id),
            "status",
            tostring(status)
        )
        m_requests:inc(1, { result = "business_rejected" })
        return { status = 200, body = { result = "accepted", status = "REJECTED" } }
    end

    -- 鉴权/契约类失败（cap 绑定错误、同 op 换参数）：不是业务拒绝，也不是暂态。
    -- 不 ACK、回 5xx 让渠道重推，同时留下错误日志等人看
    charge_order.note_error(self.orders_coll, order, "grant rejected: " .. tostring(status), now)
    log.error("pay grant rejected by contract", "order", tostring(order.order_id), "status", tostring(status))
    m_requests:inc(1, { result = "grant_error" })
    return reject(500, "grant_rejected")
end

-- ACK 写失败不能当成功：渠道看到 200 就不会再推，而我们没有 ack 记录
function Webhook:ack(name, order, now)
    local updated, err = charge_order.ack(self.orders_coll, name, order.order_id, charge_order.ACK.ACCEPTED, now)
    if not updated then
        log.error("pay callback ack not persisted", "order", tostring(order.order_id), "err", tostring(err))
    end
    return updated ~= nil
end

-- HTTP 适配器：把纯逻辑接到 http_server 的 (req, res) 上
function M.router(deps)
    local webhook, err = M.new(deps)
    if not webhook then
        error(err, 0)
    end
    return function(req, res)
        local out = webhook:handle(req)
        local header = { ["content-type"] = "application/json" }
        res.write(out.status, require("cjson.safe").encode(out.body or {}), header)
    end
end

return M
