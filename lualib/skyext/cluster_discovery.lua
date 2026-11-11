local skynet = require "skynet"
local queue = require "skynet.queue"
local event_channel_api = require "skyext.event_channel_api"
local log = require "skyext.log"

local M = {}

local g_cluster_discovery_service

-- 注册服务
function M.register(services)
    assert(g_cluster_discovery_service, "cluster_discovery service not initialized")
    skynet.send(g_cluster_discovery_service, "lua", "register", services)
end

-- 注销服务
function M.unregister(services)
    assert(g_cluster_discovery_service, "cluster_discovery service not initialized")
    skynet.send(g_cluster_discovery_service, "lua", "unregister", services)
end

-- 停服时调用：撤销租约，节点和服务立即从 etcd 消失。返回是否撤销成功
function M.shutdown()
    assert(g_cluster_discovery_service, "cluster_discovery service not initialized")
    return skynet.call(g_cluster_discovery_service, "lua", "shutdown")
end

-- 发现结果的可信状态。空列表有两种完全不同的含义：
--   UNCONFIRMED      还没有成功查过 etcd，空表不代表"没有节点"
--   EMPTY_CONFIRMED  etcd 明确答复没有这个服务的节点
--   VERIFIED         有节点，且这份列表是最近一次确认过的
-- 调用方（例如按节点列表决定是否接管资源）必须看状态，不能只看 #nodes == 0。
local STATE = {
    UNCONFIRMED = "UNCONFIRMED",
    EMPTY_CONFIRMED = "EMPTY_CONFIRMED",
    VERIFIED = "VERIFIED",
}
M.STATE = STATE

local g_services_cache = {} -- service -> service_obj
local service_mt = {}
service_mt.__index = service_mt

local function get_service_obj(service)
    local obj = g_services_cache[service]
    if not obj then
        obj = setmetatable({
            service = service,
            lock = queue(),
        }, service_mt)
        g_services_cache[service] = obj
        log.info("cluster_discovery create service object", "service", service)
    end
    obj:ensure_init()
    return obj
end

function service_mt:ensure_init()
    if not self.inited then
        self.lock(self.init, self)
    end
end

function service_mt:init()
    if self.inited then
        return
    end

    local nodes, state, verified_at = skynet.call(g_cluster_discovery_service, "lua", "query_service", self.service)
    if state == STATE.UNCONFIRMED then
        -- 服务端首次查询没成功：保留 UNCONFIRMED，不能把空表当成"确认没有节点"
        self.nodes = {}
        self.state = STATE.UNCONFIRMED
        self.last_verified_at = nil
        self.inited = false
        return false
    end
    self.nodes = nodes
    self.last_verified_at = verified_at or os.time()
    self.state = (#nodes > 0) and STATE.VERIFIED or STATE.EMPTY_CONFIRMED
    self.inited = true
    log.info("cluster_discovery service init", "service", self.service, "nodes", self.nodes)
end

function service_mt:update(nodes)
    self.nodes = nodes
    self.last_verified_at = os.time()
    self.state = (#nodes > 0) and STATE.VERIFIED or STATE.EMPTY_CONFIRMED
end

-- 阻塞版本：必要时先完成首次查询。返回的 state 一定是确认过的
function M.state(service)
    local service_obj = get_service_obj(service)
    return {
        state = service_obj.state,
        nodes = service_obj.nodes,
        last_verified_at = service_obj.last_verified_at,
    }
end

-- 非阻塞版本：不触发首次查询。还没查过时明确返回 UNCONFIRMED，
-- 调用方不能把 nodes={} 当成"确认没有节点"
function M.peek(service)
    local service_obj = g_services_cache[service]
    if not service_obj or not service_obj.inited or not service_obj.state then
        return {
            state = STATE.UNCONFIRMED,
            nodes = {},
            last_verified_at = nil,
        }
    end
    return {
        state = service_obj.state,
        nodes = service_obj.nodes,
        last_verified_at = service_obj.last_verified_at,
    }
end

-- 随机一个节点
function M.random(service)
    local service_obj = get_service_obj(service)
    local nodes = service_obj.nodes
    if #nodes == 0 then
        return nil
    end
    local node = nodes[math.random(#nodes)]
    return node
end

-- 所有节点
function M.nodes(service)
    local service_obj = get_service_obj(service)
    return service_obj.nodes
end

-- 订阅服务变更
local function on_service_change(service, nodes)
    log.info("on_service_change", "service", service, "nodes", nodes)

    local service_obj = g_services_cache[service]
    if not service_obj then
        return
    end
    service_obj:update(nodes)
end

skynet.init(function()
    g_cluster_discovery_service = skynet.uniqueservice("cluster_discovery")
    event_channel_api.subscribe(g_cluster_discovery_service, "service_change", on_service_change)
end)

return M
