-- 支付回调的 HTTP 路由模块（P09）。
--
-- `http_server` 的路由表是"方法 -> 精确路径 -> handler"，不支持通配，
-- 所以这里按配置给每个渠道注册一条 `/pay/<provider>/callback`；
-- 渠道只允许一个固定地址时再注册 `/pay/callback?provider=<name>`。
--
-- 本模块运行在 HTTP agent 进程里：依赖（订单集合、发奖通道）在这里惰性构造，
-- 不依赖启动服务的进程。
local config = require "skyext.config"
local log = require "skyext.log"
local mongo_conn = require "skyext.mongo_conn"
local pay_webhook = require "skyext.pay_webhook"
local router = require "skyext.entity.router"
local skynet = require "skynet"

local g_webhook

local function grant_via_router(conf, order)
    -- router.call 返回 (true, decision) 或 (false, reason)，pcall 多插一个 true
    local called, ok, result = pcall(router.call, conf.role_type or "role", order.rid, "charge_grant", order)
    if not called then
        log.error("charge grant call failed", "order", tostring(order.order_id), "err", tostring(ok))
        return nil, ok
    end
    if ok ~= true then
        return nil, result
    end
    return result
end

local function schedule_grant(conf, order)
    -- ack_before_grant 的回调已经先 ACK；这里异步跑一次发奖，失败仍由对账兜底。
    -- 不能把 router.call 放回 HTTP 请求协程里阻塞响应。
    local called, err = pcall(skynet.fork, function()
        local decision, gerr = grant_via_router(conf, order)
        if not decision then
            log.error(
                "scheduled pay grant failed; reconciliation will retry",
                "order",
                tostring(order.order_id),
                "err",
                tostring(gerr)
            )
        end
    end)
    if not called then
        return nil, err
    end
    return true
end

local function build()
    local conf = config.get_table("pay_callback") or {}
    local orders = conf.orders or {}
    local providers = {}
    for name, spec in pairs(conf.providers or {}) do
        local ok, mod = pcall(require, spec.module)
        if not ok or type(mod) ~= "table" then
            error("pay provider module failed to load: " .. tostring(spec.module) .. ": " .. tostring(mod))
        end
        providers[name] = {
            verify = assert(mod.verify, "provider " .. name .. " has no verify"),
            parse = assert(mod.parse, "provider " .. name .. " has no parse"),
            ack_before_grant = spec.ack_before_grant == true,
        }
    end
    local webhook, err = pay_webhook.new({
        providers = providers,
        orders_coll = mongo_conn.get_collection(orders.db or "game", orders.coll or "charge_order"),
        hash_fn = require("crypto").hmac_sha256,
        grant = function(order)
            return grant_via_router(conf, order)
        end,
        schedule_grant = function(order)
            return schedule_grant(conf, order)
        end,
    })
    if not webhook then
        error(err, 0)
    end
    return webhook
end

local function handler(req, res)
    if not g_webhook then
        g_webhook = build()
    end
    local out = g_webhook:handle(req)
    local ok, body = pcall(require("cjson.safe").encode, out.body or {})
    res.write(out.status, ok and body or "{}", { ["content-type"] = "application/json" })
end

local paths = {}
local conf = config.get_table("pay_callback") or {}
for name in pairs(conf.providers or {}) do
    paths["/pay/" .. name .. "/callback"] = handler
end
-- 固定回调地址的渠道：provider 走 query
paths["/pay/callback"] = handler

return { POST = paths }
