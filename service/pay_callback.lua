-- 支付回调服务（P09）：HTTP 入口 + 对账 worker。
--
-- 它只做三件事：验签、落单、把发奖交给实体。资产效果永远由 `critical` 的提交内核
-- 在实体进程内完成——这里不碰角色文档。
--
-- 配置（节点配置表 `pay_callback`）：
--   host / port / agent_count   监听参数
--   orders = { db = , coll = }  订单集合
--   role_type                   发奖的实体类型，默认 "role"
--   reconcile_interval          对账间隔秒数，默认 30
--   providers = {
--     [name] = { module = "<lua 模块>", ack_before_grant = false }
--   }
--   模块需返回 { verify(req, body) -> true|nil,err, parse(req, body) -> order|nil,err }
local skynet = require "skynet"
local charge_order = require "skyext.charge_order"
local charge_reconcile = require "skyext.charge_reconcile"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local gm_api = require "skyext.gm_api"
local http_server = require "skyext.http_server"
local log = require "skyext.log"
local mongo_conn = require "skyext.mongo_conn"
local router = require "skyext.entity.router"

local CMD = {}
local GM_CMD = {}

local g_conf
local g_orders
local g_running = false
local g_scan_cursors = {}

local function settings()
    local conf = config.get_table("pay_callback") or {}
    local orders = conf.orders or {}
    return {
        host = conf.host or "0.0.0.0",
        port = conf.port or 8090,
        agent_count = conf.agent_count or 4,
        db = orders.db or "game",
        coll = orders.coll or "charge_order",
        role_type = conf.role_type or "role",
        reconcile_interval = conf.reconcile_interval or 30,
        providers = conf.providers or {},
    }
end

local function load_providers(specs)
    local providers = {}
    for name, spec in pairs(specs) do
        local module_name = spec.module
        if type(module_name) ~= "string" or #module_name == 0 then
            return nil, "provider " .. tostring(name) .. " has no module"
        end
        local ok, mod = pcall(require, module_name)
        if not ok or type(mod) ~= "table" then
            return nil, "provider module failed to load: " .. module_name .. ": " .. tostring(mod)
        end
        if type(mod.verify) ~= "function" or type(mod.parse) ~= "function" then
            return nil, "provider module must expose verify and parse: " .. module_name
        end
        providers[name] = {
            verify = mod.verify,
            parse = mod.parse,
            ack_before_grant = spec.ack_before_grant == true,
        }
    end
    return providers
end

-- 发奖：经 router 到实体进程，capability 在那边签发。
-- `router.call` 返回 (true, decision) 或 (false, reason)，pcall 会再插一个 true，
-- 所以必须按三个返回值取——只取两个会把 `true` 当成 decision
local function grant(order)
    local called, ok, result = pcall(router.call, g_conf.role_type, order.rid, "charge_grant", order)
    if not called then
        log.error("charge grant call failed", "order", tostring(order.order_id), "err", tostring(ok))
        return nil, ok
    end
    if ok ~= true then
        return nil, result
    end
    return result
end

-- 对账时的证明查询：角色文档里该 op 的真实状态
local function query_op(rid, op_id)
    local called, ok, result = pcall(router.call, g_conf.role_type, rid, "critical_status", op_id)
    if not called then
        return nil, ok
    end
    if ok ~= true or type(result) ~= "table" then
        return nil, result or "no status"
    end
    return result
end

local function reconcile_loop()
    while g_running do
        local ok, stats, err = pcall(charge_reconcile.run_once, {
            orders_coll = g_orders,
            query_op = query_op,
            grant = grant,
            scan_cursors = g_scan_cursors,
        }, { grace = 60 })
        if not ok then
            log.error("charge reconcile raised", "err", tostring(stats))
        elseif not stats then
            log.error("charge reconcile failed", "err", tostring(err))
        elseif stats.reconciled + stats.granted + stats.rejected > 0 then
            log.info(
                "charge reconcile round",
                "scanned",
                stats.scanned,
                "reconciled",
                stats.reconciled,
                "granted",
                stats.granted,
                "rejected",
                stats.rejected
            )
        end
        skynet.sleep(math.max(1, math.floor(g_conf.reconcile_interval * 100)))
    end
    log.info("charge reconcile stopped")
end

function CMD.start(conf)
    if g_running then
        return true, "already started"
    end
    g_conf = settings()
    for k, v in pairs(conf or {}) do
        g_conf[k] = v
    end

    g_orders = mongo_conn.get_collection(g_conf.db, g_conf.coll)

    -- 写通道门禁：没有多数派写入，落单/推进/ACK 都是 w:1，切主回滚会让
    -- "渠道已 ACK、订单行消失"变成永久丢单。缺通道必须在启动时拦下，不能降级运行。
    -- 这里只证明接口存在，真正的健康还要靠下一步的探针
    local writable, werr = charge_order.check_write_channel(g_orders)
    if not writable then
        log.error("pay callback not started, majority write gate failed", "err", tostring(werr))
        return false, werr
    end

    -- 真实多数派探针：接口存在不等于这条连接能完成 majority 写。
    -- 探针做一次真实写入 + 多数派读回 + 清理，任一步未确认都不启动
    local probed, probe_ok, probe_err = pcall(g_orders.critical_probe, g_orders)
    if not probed then
        log.error("pay callback not started, majority probe raised", "err", tostring(probe_ok))
        return false, "majority probe raised: " .. tostring(probe_ok)
    end
    if probe_ok ~= true then
        log.error("pay callback not started, majority probe failed", "err", tostring(probe_err))
        return false, "majority probe failed: " .. tostring(probe_err or "unconfirmed")
    end

    -- 索引门禁：没有 (provider, order_id) 唯一索引，重复回调会落出两条订单，
    -- 发奖就可能执行两次。索引建不起来时**不启动**服务
    local indexed, ierr = charge_order.ensure_indexes(g_orders)
    if not indexed then
        log.error("pay callback not started, order index gate failed", "err", tostring(ierr))
        return false, ierr
    end
    local reconcile_indexed, rerr = charge_reconcile.ensure_indexes({ orders = g_orders })
    if not reconcile_indexed then
        log.error("pay callback not started, reconcile index gate failed", "err", tostring(rerr))
        return false, rerr
    end

    local providers, perr = load_providers(g_conf.providers)
    if not providers then
        log.error("pay callback not started", "err", perr)
        return false, perr
    end
    local provider_count = 0
    for _ in pairs(providers) do
        provider_count = provider_count + 1
    end

    local server = http_server.new("pay_callback")
    server:start({ host = g_conf.host, port = g_conf.port, agent_count = g_conf.agent_count })
    -- 路由模块在每个 agent 进程里自己构造依赖，这里只给模块名
    server:register_router("skyext.pay_callback_router")

    g_running = true
    g_scan_cursors = {}
    skynet.fork(reconcile_loop)
    log.info("pay callback started", "port", g_conf.port, "providers", provider_count)
    return true
end

function CMD.stop()
    g_running = false
    return true
end

-- 手动跑一轮对账，返回统计
function CMD.reconcile_once()
    return charge_reconcile.run_once({
        orders_coll = g_orders,
        query_op = query_op,
        grant = grant,
        scan_cursors = g_scan_cursors,
    }, {})
end

-- 人工阻断是终态：对账扫描显式排除、webhook 只 ACK。核对/补偿完成后必须有
-- 一个运行中的入口把订单放回自动对账，否则只能 debug inject 或直连库改文档。
GM_CMD.pay_unblock = {
    desc = "解除订单的人工阻断，重新纳入自动对账（需先完成人工核对/补偿）",
    params = {
        provider = "渠道名（必填）",
        order_id = "渠道订单号（必填）",
    },
    handler = function(params)
        if not g_orders then
            return false, "pay callback is not started"
        end
        if type(params) ~= "table" then
            return false, "params must be a table"
        end
        local provider, order_id = params.provider, params.order_id
        if type(provider) ~= "string" or provider == "" or type(order_id) ~= "string" or order_id == "" then
            return false, "provider and order_id are required"
        end
        -- 多数派读：主节点上看得见的阻断单不一定可靠，解封必须基于已确认的状态
        local order, ferr = g_orders:critical_find({ provider = provider, order_id = order_id })
        if type(order) ~= "table" then
            return false,
                "blocked order not found or not majority-visible: " .. tostring(ferr or provider .. "/" .. order_id)
        end
        if not order.reconcile_blocked_at then
            return false, "order is not blocked"
        end
        local unblocked, uerr = charge_order.unblock_reconcile(g_orders, order, os.time())
        if type(unblocked) ~= "table" then
            return false, tostring(uerr)
        end
        log.warn(
            "charge order manually unblocked",
            "provider",
            provider,
            "order_id",
            order_id,
            "status",
            tostring(order.status)
        )
        return true, { provider = provider, order_id = order_id, status = order.status }
    end,
}

GM_CMD.pay_blocked = {
    desc = "列出处于人工阻断的订单（按 reconcile_blocked_at 复合 Keyset 翻页）",
    params = {
        limit = "返回条数，默认 50，最大 200",
        cursor_blocked_at = "上一页最后一条的 reconcile_blocked_at（可选）",
        cursor_block_version = "上一页最后一条的 reconcile_block_version（可选，默认 0）",
        cursor_provider = "上一页最后一条的 provider（可选）",
        cursor_order_id = "上一页最后一条的 order_id（可选）",
        cursor_updated_at = "旧游标字段，仅用于兼容已有调用方",
    },
    handler = function(params)
        if not g_orders then
            return false, "pay callback is not started"
        end
        params = type(params) == "table" and params or {}
        local opts = { limit = params.limit }
        if params.cursor_blocked_at ~= nil then
            local blocked_at = tonumber(params.cursor_blocked_at)
            if not blocked_at or blocked_at ~= math.floor(blocked_at) then
                return false, "cursor_blocked_at must be an integer"
            end
            local version = params.cursor_block_version
            if version == nil then
                version = 0
            else
                version = tonumber(version)
                if not version or version ~= math.floor(version) or version < 0 then
                    return false, "cursor_block_version must be a non-negative integer"
                end
            end
            opts.cursor = {
                blocked_at = math.tointeger(blocked_at),
                block_version = math.tointeger(version),
                provider = params.cursor_provider,
                order_id = params.cursor_order_id,
            }
        elseif params.cursor_updated_at ~= nil then
            local updated_at = tonumber(params.cursor_updated_at)
            if not updated_at or updated_at ~= math.floor(updated_at) then
                return false, "cursor_updated_at must be an integer"
            end
            opts.cursor = {
                updated_at = math.tointeger(updated_at),
                provider = params.cursor_provider,
                order_id = params.cursor_order_id,
            }
        end
        local list, next_cursor, lerr = charge_order.list_blocked(g_orders, opts)
        if type(list) ~= "table" then
            return false, tostring(lerr)
        end
        return true, { orders = list, next_cursor = next_cursor }
    end,
}

skynet.start(function()
    cmd_api.dispatch(CMD)
    -- 注册失败不该拖垮服务：没有 GM 只是少了运维入口，回调与对账照常跑
    local ok, err = pcall(gm_api.register, GM_CMD)
    if not ok then
        log.warn("pay callback GM registration failed", "err", tostring(err))
    end
end)
