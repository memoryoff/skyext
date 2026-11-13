local skynet = require "skynet"
local config = require "skyext.config"
local critical_config = require "skyext.critical_config"
local log = require "skyext.log"
local node_shutdown_api = require "skyext.node_shutdown_api"

local M = {}

-- 关键经济链路的可选服务（P08/P09/P13/P15）。
-- 默认**不启动**：它们依赖 Mongo 索引门禁、实体类型的 critical_ledger/critical_jobs
-- 配置，以及支付渠道密钥。配置表存在且 enabled = true 才起，避免"没配好就静默跑起来"。
-- start 里会跑 ensure_indexes；失败必须让节点启动失败，不能降级成全表扫描的调度器。
--
-- 这些服务全都通过实体路由干活，因此**必须在 launcher_entities 之后**启动：
-- Outbox Worker 和 Critical Maintenance 一起来就扫 Mongo，支付回调一起来就开 HTTP 端口，
-- 实体系统还没 READY 时它们只会拿到"找不到 owner"，第一轮全部空转。
-- required / non_empty 只用于启动自检：启用却没配关键字段，比"没启用"更难排查，
-- 必须在节点起来的那一刻就说清楚，而不是等停服迁移或支付回调才发现。
M.OPTIONAL_SERVICES = {
    { config_key = "outbox_worker", service = "outbox_worker", required = { "type_name" } },
    { config_key = "critical_maintenance", service = "critical_maintenance", required = { "type_name" } },
    { config_key = "pay_callback", service = "pay_callback", required = { "role_type" }, non_empty = { "providers" } },
    {
        config_key = "migration",
        service = "migration_coordinator",
        required = { "type_name", "adapter" },
    },
}

-- 结构化启动自检：哪些开了、哪些没开、开了但缺什么、跨服务依赖有没有断。只读，不改配置。
function M.self_check()
    local report = { enabled = {}, disabled = {}, problems = {} }
    for _, spec in ipairs(M.OPTIONAL_SERVICES) do
        local conf = config.get_table(spec.config_key)
        if type(conf) == "table" and conf.enabled == true then
            report.enabled[#report.enabled + 1] = spec.config_key
            for _, field in ipairs(spec.required or {}) do
                local value = conf[field]
                if value == nil or value == "" then
                    report.problems[#report.problems + 1] =
                        string.format("%s is enabled without %s", spec.config_key, field)
                end
            end
            for _, field in ipairs(spec.non_empty or {}) do
                local value = conf[field]
                if type(value) ~= "table" or next(value) == nil then
                    report.problems[#report.problems + 1] =
                        string.format("%s is enabled but %s is empty", spec.config_key, field)
                end
            end
        else
            report.disabled[#report.disabled + 1] = spec.config_key
        end
    end

    -- 跨服务依赖（D-16）：支付回调与 outbox 都靠 critical_maintenance 归档冷账本、
    -- 补建恢复任务。它没开时热账本会撞上 MAX_OPS，新关键操作被拒、UNKNOWN 不恢复。
    local maintenance = config.get_table("critical_maintenance")
    local maintenance_on = type(maintenance) == "table" and maintenance.enabled == true
    if not maintenance_on then
        for _, key in ipairs({ "pay_callback", "outbox_worker" }) do
            local conf = config.get_table(key)
            if type(conf) == "table" and conf.enabled == true then
                report.problems[#report.problems + 1] =
                    string.format("%s is enabled but critical_maintenance is not enabled", key)
            end
        end
    end

    -- 维护服务启用时，对应实体类型必须真的配了冷账本/恢复任务集合。缺了它
    -- service/critical_maintenance.lua 会 fail-fast，自检里先把话说清楚：
    -- 绝不允许回退到默认集合名、启动成功却空转。
    if maintenance_on then
        local type_name = maintenance.type_name or "role"
        local entity_types = config.get_table("entity_types")
        local tc = type(entity_types) == "table" and entity_types[type_name] or nil
        for _, key in ipairs({ "critical_ledger", "critical_jobs" }) do
            local spec = type(tc) == "table" and tc[key] or nil
            if not critical_config.validate_collection_spec(spec) then
                report.problems[#report.problems + 1] = string.format(
                    "critical_maintenance is enabled but entity type %s has no valid %s config (db/coll required)",
                    tostring(type_name),
                    key
                )
            end
        end
    end
    return report
end

-- 自检有 problem 就阻断启动：只打日志等于没拦，缺了关键账本配置的维护服务会
-- "启动成功但空转"，等热账本撞上 MAX_OPS、新关键操作被拒才发现。
local function assert_self_check()
    local report = M.self_check()
    log.info(
        "optional services self-check",
        "enabled",
        table.concat(report.enabled, ","),
        "disabled",
        table.concat(report.disabled, ",")
    )
    for _, problem in ipairs(report.problems) do
        log.error("optional service config problem", "detail", problem)
    end
    if #report.problems > 0 then
        error("optional services self-check failed: " .. table.concat(report.problems, "; "), 0)
    end
    return report
end

function M.launch_optional_services()
    for _, spec in ipairs(M.OPTIONAL_SERVICES) do
        local conf = config.get_table(spec.config_key)
        if type(conf) == "table" and conf.enabled == true then
            local addr = skynet.newservice(spec.service)
            local ok, err = skynet.call(addr, "lua", "start", conf)
            if not ok then
                log.error("optional service failed to start", "service", spec.service, "err", tostring(err))
                error("optional service " .. spec.service .. " failed to start: " .. tostring(err))
            end
            log.info("optional service started", "service", spec.service)
        end
    end
end

-- 启动本节点的实体系统。返回即表示每个类型都已 READY：agentmgr 的 start 会创建全部
-- agent、注册服务发现，最后才返回。再问一次 is_ready 是为了拦住"start 返回了但没就绪"
-- 的实现（比如未来把 start 改成异步），别让调用方以为实体已经能接请求。
--
-- 顺序契约（role 节点）：launcher_node -> launcher_entities -> launch_optional_services -> launcher_gate
-- 依赖实体的后台服务不能先于实体系统启动，客户端入口更不能。
function M.launcher_entities(type_names)
    local started = {}
    for _, type_name in ipairs(type_names or {}) do
        local mgr = skynet.newservice("entity_agentmgr", type_name)
        -- agentmgr 的 start 失败是抛异常（skynet.call 直接上抛），不是返回 false。
        -- 用 pcall 统一两种形态，否则 "failed to start" 分支是永远走不到的死代码，
        -- 异常会以没有实体类型名的原始错误冒出来。
        local called, result, reason = pcall(skynet.call, mgr, "lua", "start")
        if not called or result ~= true then
            local detail = not called and tostring(result) or tostring(reason or result)
            error("entity system " .. tostring(type_name) .. " failed to start: " .. detail, 0)
        end
        local ready = skynet.call(mgr, "lua", "is_ready")
        if ready ~= true then
            error("entity system " .. tostring(type_name) .. " is not ready after start")
        end
        started[#started + 1] = mgr
        log.info("entity system ready", "type", type_name)
    end
    return started
end

-- 基础设施：metrics、GM、热更、停服编排、区服目录与 Mongo 索引门禁。
-- 这里**不启动**依赖实体的可选服务，也不开放客户端入口。
function M.launcher_node()
    log.info("launcher_node begin")
    -- metrics 先起：业务服务首次声明指标时就会去找 .metrics，晚一步它们得走重试
    skynet.newservice("metrics")
    skynet.newservice("gm")
    skynet.newservice("hotfix")
    -- 停服编排：GM 命令 shutdown 停止接入、卸载实体落库后退出进程
    node_shutdown_api.start()
    -- 区服目录：首次启动时把 realm_seed 写进 etcd，之后各服务查询时直接用
    skynet.uniqueservice("realm")

    -- 创建 mongodb 索引
    local mongo_index = skynet.newservice("mongo_index")
    local all_ok = skynet.call(mongo_index, "lua", "create_indexes")
    assert(all_ok, "auto create indexes failed")
    skynet.kill(mongo_index)
    log.info("auto create indexes success")
    -- 索引门禁之后再自检：配置问题跟着"节点已就绪"进启动日志，并且直接拦下启动
    assert_self_check()
end

-- 客户端接入：网关管连接，login 处理还没绑定的会话。
-- 原生客户端走 gate_tcp，浏览器和小程序走 gate_ws，两个网关共用同一个 login
-- （它持有 realm 订阅和 JWT 状态，复制一份不划算）。
-- role 节点（同进程部署）和独立的 gate 节点都调这个；必须在本节点的实体就绪之后再调，
-- 端口一打开就会有玩家进来
function M.launcher_gate()
    local host = config.get("gate_host") or "0.0.0.0"
    local maxclient = config.get_number("maxclient") or 1024
    local login = skynet.newservice("login")
    -- 下发给客户端的地址。监听地址通常是 0.0.0.0，对客户端没有意义
    local public_host = config.get("gate_public_host")
        or assert(config.get("cluster_host"), "cluster_host is not configured")
    local gate_info = {}

    local port = assert(config.get_number("gate_port"), "gate_port is not configured")
    local gate = skynet.newservice("gate_tcp")
    skynet.call(gate, "lua", "open", {
        address = host,
        port = port,
        maxclient = maxclient,
        nodelay = true,
        login = login,
    })
    gate_info.tcp_addr = public_host .. ":" .. port
    log.info("tcp gate listening", "port", port)

    -- WS 网关是可选的：不配 ws_port 就只开裸 TCP
    local ws_port = config.get_number("ws_port")
    if ws_port then
        local protocol = config.get("ws_protocol") or "ws"
        local ws_gate = skynet.newservice("gate_ws")
        skynet.call(ws_gate, "lua", "open", {
            address = host,
            port = ws_port,
            maxclient = maxclient,
            protocol = protocol,
            certfile = config.get("ws_certfile"),
            keyfile = config.get("ws_keyfile"),
            login = login,
        })
        -- 前面挂了 TLS 终止时客户端连的是域名和 443，和本节点的监听口没有关系，
        -- 这时整条 URL 由 ws_public_url 给
        gate_info.ws_url = config.get("ws_public_url") or (protocol .. "://" .. public_host .. ":" .. ws_port)
        log.info("ws gate listening", "port", ws_port)
    end

    -- 上报接入地址，客户端通过 realm 的网关列表找到这里
    gate_info.weight = config.get_number("gate_weight") or 1
    skynet.call(skynet.uniqueservice("realm"), "lua", "register_gate", gate_info)
end

return M
