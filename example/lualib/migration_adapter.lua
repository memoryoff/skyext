-- 计划内 Role 迁移的示例适配器（P15）。
--
-- 框架只提供原语：实体枚举 / 冻结 / 释放（entitymgr）、快照导出与安装（entity_agent）、
-- 网关屏障与重指向（gate_owner）。哪些节点参与、目标怎么选、失败怎么提示客户端，
-- 是部署形态决定的，所以由游戏层实现，通过 `migration.adapter = "migration_adapter"`
-- 交给 migration_coordinator 的启动门禁校验。
--
-- 六阶段的实际动作（与 docs/design/migration_v1.md 一一对应）：
--
--   quiesce  源实体冻结：停止执行上行、停止追加下行、取消空闲卸载计时器
--   freeze   网关屏障：旧 owner_epoch 的上行与下行都丢弃
--   export   源端导出 SessionSnapshotV2（含 out_buf 原字节与 L1 幂等缓存）
--   transfer 源端落库 + 释放锁（不踢客户端），快照送到目标进程暂存
--   handoff  目标抢锁（Fence 认领）并安装快照
--   activate 目标把连接接过来并重放未确认下行；网关把会话指向新 owner
--
-- 目标节点必须显式寻址（cluster.call + agent 注册名）。**不能用 router.call**：
-- 它按 HRW 选节点，而迁移期间实体还在源节点上，路由会把它转回源端。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local cluster_discovery = require "skyext.cluster_discovery"
local config = require "skyext.config"
local connection_id = require "skyext.connection_id"
local log = require "skyext.log"
local types = require "skyext.entity.types"

local M = {}

local g_type
local g_self_node

-- 取消兜底（P1-03）：停服超时后协调器只置一个 is_cancelled 标志，卡在跨节点
-- cluster.call 里的阶段协程收不到它，进程 abort 后也没人给网关解屏障。
-- 这里登记"已冻结但还没 activate"的实体，cancel 时主动踢掉客户端重连，
-- 让网关会话连同 frozen_epoch 一起销毁；并阻止取消后继续发新的阶段 RPC。
local g_inflight = {}
local g_aborted = false

-- 新一轮开始时由协调器调用，清掉上一轮取消留下的状态
function M.begin_round()
    g_inflight = {}
    g_aborted = false
end

local function self_node()
    if not g_self_node then
        g_self_node = assert(config.get("cluster_node_name"), "cluster_node_name is not configured")
    end
    return g_self_node
end

local function agent_service(entity_id)
    return types.format_agent_service_name(g_type, types.calc_agent_index(g_type, entity_id))
end

-- 本节点与远端统一入口：同节点直接调，跨节点走 cluster。返回值和被调服务一致
local function call_agent_raw(node, entity_id, cmd, ...)
    local service = agent_service(entity_id)
    if node == self_node() then
        return skynet.call(service, "lua", cmd, ...)
    end
    return cluster.call(node, service, cmd, ...)
end

local function call_agent(node, entity_id, cmd, ...)
    if g_aborted then
        return nil, "migration aborted"
    end
    return call_agent_raw(node, entity_id, cmd, ...)
end

local function call_gate(conn_id, cmd, ...)
    -- kick 是取消兜底本身用的，必须放行；其余阶段命令在取消后一律不再发出
    if g_aborted and cmd ~= "kick" then
        return nil, "migration aborted"
    end
    local parsed, err = connection_id.parse(conn_id)
    if not parsed then
        return nil, "invalid conn_id: " .. tostring(err)
    end
    local args = table.pack(...)
    if parsed.gate_node == self_node() then
        return skynet.call(parsed.gate_service, "lua", cmd, table.unpack(args, 1, args.n))
    end
    return cluster.call(parsed.gate_node, parsed.gate_service, cmd, table.unpack(args, 1, args.n))
end

function M.init(conf)
    conf = conf or {}
    g_type = assert(conf.type_name, "migration.type_name is required")
    g_self_node = nil
    M.begin_round()
    log.info("migration adapter ready", "type", g_type, "node", self_node())
end

-- 只枚举"能无感移交"的实体：有连接、持久化、没有正在进行的迁移/卸载。
-- 没有连接的实体迁移过去也没有意义，留给普通卸载 + 客户端重新登录
function M.list_entities()
    local mgr = skynet.localname(".entity_agentmgr:" .. g_type)
    if not mgr then
        return nil, "entity_agentmgr(" .. g_type .. ") is not running on this node"
    end
    local list = skynet.call(mgr, "lua", "migration_list")
    local out = {}
    local skipped = 0
    for _, entity in ipairs(list or {}) do
        if entity.conn_id and entity.persistent and not entity.busy and not entity.unresumable then
            out[#out + 1] = entity
        else
            skipped = skipped + 1
        end
    end
    log.info("migration candidates", "type", g_type, "ready", #out, "skipped", skipped)
    return out
end

-- 目标节点：先看 HRW 指向谁；指回自己（成员视图还没更新）就从服务发现里另选一个。
-- 停服期间本节点仍然注册着，所以后一种情况是常态而不是异常
local function pick_target(entity)
    local node = types.calc_node(g_type, entity.id)
    if node and node ~= self_node() then
        return node
    end
    local ok, state = pcall(cluster_discovery.state, "entity:" .. g_type)
    if not ok or type(state) ~= "table" then
        return nil, "cluster discovery unavailable"
    end
    for _, candidate in ipairs(state.nodes or {}) do
        if candidate ~= self_node() then
            return candidate
        end
    end
    return nil, "no other node serves " .. g_type
end

function M.quiesce(entity)
    local ok, reason = call_agent(self_node(), entity.id, "migration_quiesce", entity.id)
    if not ok then
        return nil, tostring(reason)
    end
    entity._quiesced = true
    return true
end

function M.freeze(entity, barrier_id)
    if not entity.owner_epoch then
        return nil, "entity has no owner epoch"
    end
    local info, err = call_gate(entity.conn_id, "freeze_owner", entity.conn_id, entity.owner_epoch, barrier_id)
    if not info then
        return nil, tostring(err)
    end
    -- 屏障已经建立：从这里到 activate 之间无论失败还是取消，都必须有人解屏障
    g_inflight[entity.id] = { id = entity.id, conn_id = entity.conn_id, barrier_id = barrier_id }
    entity._barrier = barrier_id
    return true
end

function M.export(entity, barrier_id)
    -- 目标 epoch 必须严格前进：网关用严格大于来拒绝旧 owner 的迟到下行
    local target_epoch = (entity.owner_epoch or 1) + 1
    -- session_export 是 CMD 命令，第一参数必须是 entity_id（与其余 migration_* 一致）。
    -- 少了它会把 barrier_id 当成实体 ID，命令存在也拿不到快照。
    local ok, snapshot, err = call_agent(self_node(), entity.id, "session_export", entity.id, barrier_id, target_epoch)
    if not ok then
        return nil, tostring(snapshot)
    end
    if type(snapshot) ~= "table" then
        -- entity_call 把 handler 的 nil, err 原样透传在第二、三个返回值上
        return nil, tostring(err or "no snapshot")
    end
    return snapshot
end

-- TRANSFER：先把源端的锁交出来，再把快照送到目标暂存。
-- 顺序不能反：目标在 handoff 里要抢这把锁，源端不放它永远抢不到
function M.transfer(entity, snapshot)
    local released, rerr = call_agent(self_node(), entity.id, "migration_release", entity.id)
    if not released then
        return nil, "release failed: " .. tostring(rerr)
    end
    entity._released = true

    local target, terr = pick_target(entity)
    if not target then
        -- 锁已经放了，但快照送不出去：只能让客户端重登。这个日志是运维定位的锚点
        log.error("migration has no target after release", "id", tostring(entity.id), "err", tostring(terr))
        return nil, terr
    end
    local staged, serr = call_agent(target, entity.id, "migration_stage", entity.id, snapshot)
    if not staged then
        log.error("migration snapshot was not accepted", "id", tostring(entity.id), "target", target, "err", serr)
        return nil, "stage failed: " .. tostring(serr)
    end
    entity._target = target
    -- 记下这一轮的 barrier：handoff 必须带着它去 commit，目标端才能区分
    -- "这一轮的 commit" 和 "上一轮留下的取消标记"
    entity._barrier = snapshot and snapshot.barrier_id or entity._barrier
    -- 记下目标：取消时要通知它拒绝同一 barrier 的迟到 commit
    local info = g_inflight[entity.id]
    if info then
        info.target = target
    end
    return true
end

function M.handoff(entity)
    if not entity._target then
        return nil, "no target was chosen"
    end
    -- 带上 barrier：不传的话目标端只能用暂存快照自带的那个来猜轮次，
    -- 一旦同时存在"上一轮的取消标记"就分不清该拒还是该接
    local ok, reason = call_agent(entity._target, entity.id, "migration_commit", entity.id, entity._barrier)
    if not ok then
        return nil, tostring(reason)
    end
    return true
end

function M.activate(entity)
    if not entity._target then
        return nil, "no target was chosen"
    end
    local ok, reason = call_agent(entity._target, entity.id, "session_attach", entity.id, entity.conn_id)
    if not ok then
        return nil, tostring(reason)
    end
    -- 新 owner 已经让网关 resume_owner，屏障自然解除，取消时不需要再踢这个客户端
    g_inflight[entity.id] = nil
    return true
end

-- 降级：还没导出快照的实体撤销冻结，留在本节点继续服务；
-- 已经导出/已经释放的实体只能让客户端重登——而且要**主动踢**。源端已经没有
-- 可服务的实体了，网关还会把上行转过来；不踢的话客户端对着空气重试到空闲超时。
--
-- 更关键的是网关屏障：freeze 成功会登记 g_inflight 并打上 entity._barrier，而
-- entitymgr 的 unquiesce 只清实体的 migrating 标记，**从不让网关 resume_owner**。
-- 所以只要本轮没走到成功的 activate（新 owner 解屏障），unquiesce 再成功也解不掉
-- 网关的 frozen_epoch，上/下行仍会被双向丢弃（gate_owner.push_allowed /
-- upstream_allowed）。此时解屏障的唯一手段就是踢客户端，让网关会话连同
-- frozen_epoch 一起销毁。不要改用 resume_owner：它需要严格更大的新 epoch，而实体
-- 此刻仍留在旧 owner 的本节点上，会造出状态不一致。
function M.fallback(entity, reason)
    -- 解冻是否真的成功。失败有两种：已导出（unquiesce 明确拒绝）、RPC 抛错，
    -- 两种情况网关的 frozen_epoch 都还在（C-07：unquiesce 被拒必踢）
    local unfrozen = false
    if entity._quiesced and not entity._released then
        local ok, revoked, err = pcall(call_agent, self_node(), entity.id, "migration_unquiesce", entity.id, reason)
        if not ok then
            log.error("migration unquiesce raised", "id", tostring(entity.id), "err", tostring(revoked))
        elseif not revoked then
            log.error("migration unquiesce refused", "id", tostring(entity.id), "err", tostring(err))
        else
            unfrozen = true
        end
    end

    -- 网关屏障是否还挂着：freeze 成功会登记并打 _barrier，activate 成功（新 owner
    -- 已 resume_owner）才会清掉 g_inflight。登记还在 == 本轮没走到成功的 activate，
    -- 屏障没有解除过。原先首行无条件清 g_inflight，解不掉的屏障连 abort 兜底都够不着。
    local barrier_pending = entity._barrier ~= nil and g_inflight[entity.id] ~= nil

    -- 未确认语义：已释放必踢、unquiesce 失败/被拒必踢、屏障未解除必踢。
    -- 没建立过屏障（例如 quiesce 阶段就失败）且 unquiesce 成功时，实体只是撤销冻结、
    -- 留在本节点继续服务，不该踢。
    -- 原先只看 _released 与 not unfrozen：export 失败、unquiesce 成功时两条都不成立，
    -- 于是既不解冻网关也不踢，客户端两个方向被静默丢弃。
    local released = entity._released == true
    local unquiesce_refused = entity._quiesced == true and not unfrozen
    local need_kick = released or unquiesce_refused or barrier_pending

    -- 踢人原因单独记，运维一眼能分清"源端已释放"与"网关屏障没解除"两类
    local kick_reason
    if released then
        kick_reason = "released"
    elseif unquiesce_refused then
        kick_reason = "unquiesce_refused"
    elseif barrier_pending then
        kick_reason = "barrier_pending"
    else
        kick_reason = "none"
    end

    local kicked = false
    if need_kick and entity.conn_id then
        -- pcall 三个返回值：抛错、以及网关返回假（被拒）都算没踢成，登记要保留
        local called, kick_ok, kick_err = pcall(call_gate, entity.conn_id, "kick", entity.conn_id)
        if not called then
            log.error(
                "migration fallback could not kick the client",
                "id",
                tostring(entity.id),
                "err",
                tostring(kick_ok)
            )
        elseif not kick_ok then
            log.error("migration fallback kick was rejected", "id", tostring(entity.id), "err", tostring(kick_err))
        else
            kicked = true
        end
    end

    -- 源端已经导出快照或释放过锁时，即使踢掉客户端也不能让旧实体继续被绑定：
    -- 重连的 bind 会命中同一个 self.entities 条目，而 client_msg 看到 migrating=true
    -- 后把所有上行丢掉。强制走正常 unload（落库 + 释放锁 + 重试）把内存条目清掉，
    -- 下一次重连才会从库重新加载一个干净实体。
    local cannot_resume = released or unquiesce_refused
    local abandoned = false
    if cannot_resume then
        local called, ok, err = pcall(call_agent_raw, self_node(), entity.id, "unload_entity", entity.id)
        if not called then
            log.error(
                "migration fallback could not abandon the source entity",
                "id",
                tostring(entity.id),
                "err",
                tostring(ok)
            )
        elseif not ok then
            log.error(
                "migration fallback source entity is still unloading",
                "id",
                tostring(entity.id),
                "err",
                tostring(err)
            )
        else
            abandoned = true
        end
    end

    -- 只有确认无需踢、或踢成功，屏障才算处理完，才能摘掉登记；
    -- 踢失败/被拒时保留 g_inflight，让后续 M.abort() 的兜底还能重试踢人。
    if not need_kick or kicked then
        g_inflight[entity.id] = nil
    end

    log.warn(
        "entity migration fell back to reconnect",
        "id",
        tostring(entity.id),
        "reason",
        tostring(reason),
        "kick_reason",
        kick_reason,
        "released",
        released,
        "unfrozen",
        unfrozen,
        "need_kick",
        need_kick,
        "kicked",
        kicked,
        "cannot_resume",
        cannot_resume,
        "abandoned",
        abandoned
    )
end

-- 停服截止：协调器的 cancel 只置标志，卡在无超时 cluster.call 里的协程不会返回，
-- 进程随后 abort，网关的 frozen_epoch 可能永远没人清。这里做**兜底**：
-- 把仍处在屏障期的客户端踢下线，网关会话销毁即等于解屏障；并禁止后续阶段
-- 再发 RPC（kick 除外）。这是"让失败可恢复"，不是"取消长 RPC"——后者仍需要
-- 给跨节点调用加 deadline，见 docs/review-2026-11-12-defect-register.md R-01。
function M.abort(reason)
    -- 顺序是硬约束：**先踢客户端，再通知目标端**。
    --
    -- 反过来（先通知目标）有个致命后果：通知走的是无超时的 cluster.call，
    -- 而目标不可达恰恰是这次取消的常见原因。一旦它阻塞，后面的踢人循环
    -- 根本不会执行，网关的 frozen_epoch 就永久留着——玩家连接卡死，
    -- 正是"取消兜底"要避免的那个最坏结果。
    -- 踢人只依赖网关服务，先做才能保证最坏情况下玩家至少能重连。
    g_aborted = true

    local kicked, kick_failed = 0, 0
    for id, info in pairs(g_inflight) do
        if info.conn_id then
            local called, ok, err = pcall(call_gate, info.conn_id, "kick", info.conn_id)
            if called and ok then
                kicked = kicked + 1
                -- 已经踢掉：不必再重试。留着 target 继续走下一步
                info.conn_id = nil
            else
                kick_failed = kick_failed + 1
                log.error(
                    "migration abort could not kick the client",
                    "id",
                    tostring(id),
                    "err",
                    tostring(called and err or ok)
                )
            end
        end
    end

    -- 再通知目标端拒绝同一 barrier 的迟到 commit/attach。
    -- 用 raw 调用：g_aborted 已经置位，普通 call_agent 会直接拒绝，
    -- 而这条通知恰恰必须在取消之后才发得出去
    local notified, notify_failed = 0, 0
    for id, info in pairs(g_inflight) do
        if info.target then
            local called, ok, err = pcall(call_agent_raw, info.target, id, "migration_abort", id, info.barrier_id)
            if called and ok then
                notified = notified + 1
                info.target = nil
            else
                notify_failed = notify_failed + 1
                log.error(
                    "migration abort could not reach the target",
                    "id",
                    tostring(id),
                    "target",
                    tostring(info.target),
                    "err",
                    tostring(called and err or ok)
                )
            end
        end
    end

    -- 只清掉处理完的条目：踢失败的留着，下次 abort（或下一轮 begin_round）还能重试。
    -- 之前无条件清掉，失败的连接就再也没有第二次机会
    for id, info in pairs(g_inflight) do
        if not info.conn_id and not info.target then
            g_inflight[id] = nil
        end
    end

    log.warn(
        "migration aborted, gateway barriers released by reconnect",
        "reason",
        tostring(reason),
        "kicked",
        kicked,
        "kick_failed",
        kick_failed,
        "notified",
        notified,
        "notify_failed",
        notify_failed
    )
    return {
        kicked = kicked,
        failed = kick_failed,
        notified = notified,
        notify_failed = notify_failed,
        pending = (function()
            local n = 0
            for _ in pairs(g_inflight) do
                n = n + 1
            end
            return n
        end)(),
    }
end

return M
