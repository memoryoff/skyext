-- 频道订阅目录与广播（P16）。
--
-- 设计边界（与 P14/P15 的分工）：
--   * 频道状态**在 Role 进程内**，不由网关持有。广播最终走
--     `session.push` / `record_and_send`，因此仍然由 Role 计数、写重放缓冲；
--     网关直接计数广播会在迁移时把 seq 撕成两半。
--   * 本模块只做目录 + 鉴权 + 背压，不碰网络。投递函数由调用方注入，
--     这样它能跑在实体队列里，也能在测试里换成纯函数。
--
-- 背压策略：
--   * 单次广播按 `batch_size` 分批，避免一次 fanout 长时间占住实体队列；
--   * 投递失败（离线、会话已换、发送队列满）只计 `skipped`，不重试——
--     频道消息是**可丢**的，重试只会把慢消费者拖成雪崩；
--   * 连续 `max_consecutive_failures` 次失败把成员标记为 `slow`，后续广播直接跳过，
--     等它下一次成功 join/心跳再恢复。这是"保护大多数"而不是"保证每个都收到"。
local metrics = require "skyext.metrics"

local M = {}

-- 频道规模与丢弃量：广播是可丢的，但"丢了多少"必须看得见
local m_members = metrics.gauge("skyext_channel_members", "Channel members in this VM", { "channel" })
local m_skipped = metrics.counter(
    "skyext_channel_broadcast_skipped_total",
    "Channel broadcasts skipped by reason",
    { "channel", "reason" }
)

M.DEFAULT_MAX_MEMBERS = 10000
M.DEFAULT_BATCH_SIZE = 256
M.DEFAULT_MAX_FAILURES = 3

local channel_mt = {}
channel_mt.__index = channel_mt

-- opts:
--   name          频道名（必填，非空字符串）
--   max_members   成员上限，默认 10000
--   batch_size    单批投递数量，默认 256
--   max_failures  连续失败多少次标记 slow，默认 3
--   authorize     function(rid, name) -> true | false, reason；nil 表示不鉴权
function M.new(opts)
    if type(opts) ~= "table" then
        return nil, "opts must be a table"
    end
    local name = opts.name
    if type(name) ~= "string" or #name == 0 or #name > 128 then
        return nil, "invalid channel name"
    end
    local max_members = opts.max_members or M.DEFAULT_MAX_MEMBERS
    local batch_size = opts.batch_size or M.DEFAULT_BATCH_SIZE
    local max_failures = opts.max_failures or M.DEFAULT_MAX_FAILURES
    for label, value in pairs({ max_members = max_members, batch_size = batch_size, max_failures = max_failures }) do
        if math.type(value) ~= "integer" or value < 1 then
            return nil, label .. " must be a positive integer"
        end
    end

    return setmetatable({
        name = name,
        max_members = max_members,
        batch_size = batch_size,
        max_failures = max_failures,
        authorize = opts.authorize,
        members = {}, -- rid -> { failures = n, slow = bool, since = ts }
        order = {}, -- 稳定遍历顺序，避免每次广播的成员顺序随机
        count = 0,
    }, channel_mt)
end

function channel_mt:size()
    return self.count
end

function channel_mt:has(rid)
    return self.members[rid] ~= nil
end

-- 订阅。已订阅是幂等成功，并且会清掉 slow 标记（成员主动回来就算恢复）
function channel_mt:join(rid, now)
    if rid == nil then
        return nil, "rid is required"
    end
    if self.authorize then
        local ok, reason = self.authorize(rid, self.name)
        if ok ~= true then
            return nil, reason or "not authorized"
        end
    end
    local member = self.members[rid]
    if member then
        member.failures = 0
        member.slow = false
        return true
    end
    if self.count >= self.max_members then
        return nil, "channel is full"
    end
    self.members[rid] = { failures = 0, slow = false, since = now }
    self.order[#self.order + 1] = rid
    self.count = self.count + 1
    m_members:set(self.count, { channel = self.name })
    return true
end

-- 退订。不在频道里返回 false，调用方可以据此判断是否需要做清理
function channel_mt:leave(rid)
    if not self.members[rid] then
        return false
    end
    self.members[rid] = nil
    for i = #self.order, 1, -1 do
        if self.order[i] == rid then
            table.remove(self.order, i)
            break
        end
    end
    self.count = self.count - 1
    m_members:set(self.count, { channel = self.name })
    return true
end

-- 广播。deliver(rid, payload) 返回 true 表示投递成功。
-- 返回 { delivered, skipped, slow_skipped, batches }；payload 由调用方决定，
-- 通常是已编码好的包，这样一次广播只编码一次。
function channel_mt:broadcast(payload, deliver)
    if type(deliver) ~= "function" then
        return nil, "deliver must be a function"
    end
    local stats = { delivered = 0, skipped = 0, slow_skipped = 0, batches = 0 }
    local batch = 0
    -- 先快照成员：投递过程中可能有人 join/leave，直接遍历 self.order 会跳过元素
    local targets = {}
    for i = 1, #self.order do
        targets[i] = self.order[i]
    end

    for _, rid in ipairs(targets) do
        local member = self.members[rid]
        if member then
            if member.slow then
                stats.slow_skipped = stats.slow_skipped + 1
                m_skipped:inc(1, { channel = self.name, reason = "slow" })
            else
                local ok, err = pcall(deliver, rid, payload)
                if ok and err == true then
                    stats.delivered = stats.delivered + 1
                    member.failures = 0
                else
                    stats.skipped = stats.skipped + 1
                    m_skipped:inc(1, { channel = self.name, reason = "deliver_failed" })
                    member.failures = member.failures + 1
                    if member.failures >= self.max_failures then
                        member.slow = true
                    end
                end
            end
            batch = batch + 1
            if batch >= self.batch_size then
                stats.batches = stats.batches + 1
                batch = 0
            end
        end
    end
    if batch > 0 then
        stats.batches = stats.batches + 1
    end
    return stats
end

-- 只读观测
function channel_mt:stats()
    local slow = 0
    for _, member in pairs(self.members) do
        if member.slow then
            slow = slow + 1
        end
    end
    return { name = self.name, members = self.count, slow = slow, max_members = self.max_members }
end

-- 频道目录。同一进程内按名字索引；跨节点广播由调用方经 router 扇出，
-- 本模块不持有跨节点成员表（那会变成第二个一致性问题）
local g_directory = {}

function M.get(name)
    return g_directory[name]
end

function M.get_or_create(opts)
    local name = opts and opts.name
    if type(name) ~= "string" or #name == 0 then
        return nil, "invalid channel name"
    end
    local existing = g_directory[name]
    if existing then
        return existing
    end
    local channel, err = M.new(opts)
    if not channel then
        return nil, err
    end
    g_directory[name] = channel
    return channel
end

function M.remove(name)
    local channel = g_directory[name]
    if not channel then
        return false
    end
    g_directory[name] = nil
    return true
end

-- 测试用：清空目录
function M.reset()
    g_directory = {}
end

function M.list()
    local names = {}
    for name in pairs(g_directory) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

return M
