local skynet = require "skynet"
local cluster = require "skynet.cluster"
local cmd_api = require "skyext.cmd_api"
local critical_config = require "skyext.critical_config"
local types = require "skyext.entity.types"
local entitymgr_mod = require "skyext.entity.entitymgr"
local distributed_lock = require "skyext.distributed_lock"
local log = require "skyext.log"
local errcode = require "skyext.errcode"
local config = require "skyext.config"

local type_name, agent_index = ...
agent_index = tonumber(agent_index)

local type_config = types.get(type_name)
local handler
local entitymgr
local session
local g_data_modules = {}
-- 数据模块的声明顺序（来自 conf.modules）：on_load 正序、on_unload 逆序
local g_module_order = {}

local CMD = {}

local function module_names(modules)
    local names = {}
    for i, mod in ipairs(modules) do
        names[i] = mod.name
    end
    return names
end

local g_self_node
local function self_node()
    if not g_self_node then
        g_self_node = config.get("cluster_node_name")
    end
    return g_self_node
end

local function agent_name(entity_id)
    return types.format_agent_service_name(type_name, types.calc_agent_index(type_name, entity_id))
end

-- 本服务的注册名，网关按它转发这条会话之后的上行包
local function self_service_name()
    return types.format_agent_service_name(type_name, agent_index)
end

-- 客户端重新登录时向持锁节点要回实体：对方卸载（顺带踢掉旧连接）后本地再加载。
-- 只要一次：两边成员视图短暂分歧时，无限重试会变成互相抢
local function request_handoff(entity_id, holder_node)
    if not holder_node then
        return false
    end
    local called, released = pcall(cluster.call, holder_node, agent_name(entity_id), "unload_entity", entity_id)
    if not called or not released then
        log.warn("entity handoff failed", "type", type_name, "id", entity_id, "holder", holder_node)
        return false
    end
    log.info("entity handed off", "type", type_name, "id", entity_id, "holder", holder_node)
    return true
end

-- 本地执行失败是因为锁在另一个节点手里时，返回那个节点。
-- 持锁的是本节点名，说明是上一次进程留下的租约还没过期，转给自己没有意义，只能等它过期
local function remote_holder(result)
    if result[1] or result[2] ~= "lock held" then
        return nil
    end
    local holder = result[3]
    if not holder or holder == self_node() then
        return nil
    end
    return holder
end

-- 粘性路由：路由跟着集群成员走，节点进出后实体的目标节点会变，但已经加载的实体
-- 还留在上一个节点上。这时把请求转给持锁节点执行，而不是让它卸载——卸载会把在线
-- 玩家踢下线，两边成员视图不一致时实体还会被来回搬。实体在旧节点自然卸载后，
-- 下一次加载才落到新节点。
--
-- run_local 返回 true, ... 或 false, reason, owner；forward_cmd 在持锁节点上只处理
-- 已加载的实体，没加载时回 NOT_LOADED，表示什么都没执行，可以回到本地再试一次。
-- 转发本身抛错时不能重试：分不清是没送到，还是对方的 handler 执行到一半出错了。
-- 返回打包的结果，以及转发出错时的错误
local function sticky(entity_id, run_local, forward_cmd, args)
    local result = table.pack(run_local())
    local holder = remote_holder(result)
    if not holder then
        return result
    end
    local called, forwarded = pcall(function()
        return table.pack(
            cluster.call(holder, agent_name(entity_id), forward_cmd, entity_id, table.unpack(args, 1, args.n))
        )
    end)
    if not called then
        log.warn("entity forward failed", "type", type_name, "id", entity_id, "holder", holder, "err", forwarded)
        return nil, forwarded
    end
    if forwarded[1] or forwarded[2] ~= entitymgr_mod.NOT_LOADED then
        return forwarded
    end
    -- 持锁节点已经卸掉了实体，锁多半已经空出来
    return table.pack(run_local())
end

-- 框架内部命令：由框架模块（Outbox 调度器、支付回调、对账 worker）经 `router.call`
-- 调用。它们不属于业务 handler——`router.call` 固定走 `entity_call`，
-- 只认 `handler.handlers[cmd]`，所以框架命令必须在这里注册，否则永远"unknown command"。
-- 同名时框架优先。游戏层需要扩展框架命令时，只能在 handler.framework_commands
-- 显式声明，不能把同名函数塞进 handler.handlers 绕过命令归属检查。
local FRAMEWORK = {}
-- 支付回调只暴露一个稳定的框架命令名。即使某个游戏 handler 没有注册扩展，
-- 也绝不能回退到同名的业务 handler，否则业务返回值可以伪造关键提交结果。
local RESERVED_FRAMEWORK_COMMANDS = {
    charge_grant = true,
}

local function install_framework_commands(commands)
    if commands == nil then
        return
    end
    if type(commands) ~= "table" then
        error("handler.framework_commands must be a table", 0)
    end
    for cmd, fn in pairs(commands) do
        if type(cmd) ~= "string" or not cmd:match("^[%a_][%w_]*$") then
            error("framework command name is invalid: " .. tostring(cmd), 0)
        end
        if type(fn) ~= "function" then
            error("framework command must be a function: " .. cmd, 0)
        end
        if FRAMEWORK[cmd] ~= nil then
            error("framework command conflicts with a built-in command: " .. cmd, 0)
        end
        if handler.handlers[cmd] ~= nil then
            error("framework command conflicts with a business handler: " .. cmd, 0)
        end
        FRAMEWORK[cmd] = fn
    end
end

local function handler_of(cmd)
    local framework = FRAMEWORK[cmd]
    if framework then
        return framework
    end
    if RESERVED_FRAMEWORK_COMMANDS[cmd] then
        error(string.format("reserved framework command is not registered: %s", cmd))
    end
    local handler_func = handler.handlers[cmd]
    if not handler_func then
        error(string.format("unknown entity command: %s.%s", type_name, cmd))
    end
    return handler_func
end

-- 返回 true, handler 的返回值... 或 false, reason（实体不可用，handler 没有执行）。
-- handler 抛错照常抛给调用方
function CMD.entity_call(entity_id, cmd, ...)
    local handler_func = handler_of(cmd)
    local args = table.pack(...)
    local result, forward_err = sticky(entity_id, function()
        return entitymgr:with_entity(entity_id, function(entity)
            return handler_func(entity, table.unpack(args, 1, args.n))
        end)
    end, "entity_call_loaded", table.pack(cmd, ...))
    if not result then
        error(forward_err, 0)
    end
    if not result[1] then
        return false, result[2]
    end
    return table.unpack(result, 1, result.n)
end

-- 持锁节点上执行转发过来的请求：只用已经加载的实体，绝不为它加载
function CMD.entity_call_loaded(entity_id, cmd, ...)
    local handler_func = handler_of(cmd)
    local args = table.pack(...)
    return entitymgr:with_loaded_entity(entity_id, function(entity)
        return handler_func(entity, table.unpack(args, 1, args.n))
    end)
end

-- 只对已经加载的实体发消息：不加载、不转发，实体不在就返回 false
function CMD.entity_send_loaded(entity_id, cmd, ...)
    -- 用 handler_of 而不是只查 handler.handlers：框架命令（outbox_pump 等）
    -- 不在业务 handler 里，直接查会一律"unknown entity command"
    local ok_cmd, handler_func = pcall(handler_of, cmd)
    if not ok_cmd then
        log.error("unknown entity command", "type", type_name, "cmd", cmd)
        return false
    end
    local args = table.pack(...)
    local ok = entitymgr:with_loaded_entity(entity_id, function(entity)
        handler_func(entity, table.unpack(args, 1, args.n))
    end)
    return ok == true
end

function CMD.entity_send(entity_id, cmd, ...)
    local handler_func = handler.handlers[cmd]
    if not handler_func then
        log.error("unknown entity command", "type", type_name, "cmd", cmd)
        return
    end
    local args = table.pack(...)
    local ok, result, forward_err = pcall(sticky, entity_id, function()
        return entitymgr:with_entity(entity_id, function(entity)
            handler_func(entity, table.unpack(args, 1, args.n))
        end)
    end, "entity_call_loaded", table.pack(cmd, ...))
    if not ok then
        log.error("entity_send handler failed", "type", type_name, "id", entity_id, "cmd", cmd, "err", result)
    elseif not result then
        log.error("entity_send forward failed", "type", type_name, "id", entity_id, "cmd", cmd, "err", forward_err)
    elseif not result[1] then
        log.error("entity_send failed", "type", type_name, "id", entity_id, "cmd", cmd, "err", result[2])
    end
end

function CMD.__deliver_reliable(entity_id)
    local result, forward_err = sticky(entity_id, function()
        return entitymgr:deliver_pending(entity_id)
    end, "deliver_reliable_loaded", table.pack())
    if not result or not result[1] then
        -- 消息已经落库，实体下次加载或投递重试时会补上
        log.warn(
            "reliable delivery deferred",
            "type",
            type_name,
            "id",
            entity_id,
            "err",
            result and result[2] or forward_err
        )
        return false
    end
    return true
end

function CMD.deliver_reliable_loaded(entity_id)
    return entitymgr:deliver_pending(entity_id, { loaded_only = true })
end

-- 关键账本集合来自实体类型配置（critical_ledger / critical_jobs），没配就明确拒绝：
-- 静默跳过会让维护扫描看起来在跑、实际什么都没做。
-- 定义在所有 FRAMEWORK 命令之前，避免函数体把同名局部误解析成全局
local function config_collection(spec)
    if not critical_config.validate_entity_config(type_config) then
        return nil
    end
    local valid = critical_config.validate_collection_spec(spec)
    if not valid then
        return nil
    end
    return require("skyext.mongo_conn").get_collection(spec.db, spec.coll)
end

FRAMEWORK.outbox_pump = function(entity, limit)
    local outbox_worker = require "skyext.outbox_worker"
    return outbox_worker.pump_entity(entity, { limit = limit })
end

-- 接收方回执：把源事件推进到 DELIVERED。由可靠消息投递进来（源角色离线时随下次加载）。
-- 事件已经被清理、或已经 DELIVERED，都算成功：回执是幂等的
FRAMEWORK.outbox_ack = function(entity, args)
    local outbox = require "skyext.outbox"
    local ctx, cerr = require("skyext.critical").coords_of(entity)
    if not ctx then
        return nil, cerr
    end
    local event_id = type(args) == "table" and args.event_id or args
    -- 畸形 event_id（含可靠消息末尾追加的数字 msg_id）不是环境故障：
    -- 计 attempts 进死信人工可见，不能当 retryable 无限重投
    if type(outbox.is_valid_event_id) == "function" and not outbox.is_valid_event_id(event_id) then
        error("outbox ack rejected: invalid event_id", 0)
    end
    local expect_target
    if type(args) == "table" and args.receiver_type ~= nil then
        expect_target = { target_type = args.receiver_type, target_id = args.receiver_id }
    end
    local ok, err = outbox.mark_delivered(ctx, event_id, { now = os.time(), expect_target = expect_target })
    if ok then
        return true
    end
    if err == "unknown event" then
        return true
    end
    if err == "ack receiver mismatch" then
        error("outbox ack rejected: " .. tostring(err), 0)
    end
    -- 未决/环境问题：保留 pending 等重投，不能悄悄丢掉回执
    return require("skyext.entity.delivery").retryable(err)
end

FRAMEWORK.critical_status = function(entity, op_id)
    local ledger = config_collection(type_config.critical_ledger)
    if not ledger then
        -- 热条目会被归档搬走。没有冷账本就不能回答"没执行过"，否则支付对账会把
        -- 已发奖的订单判成 NOT_STARTED，再用同一个 service_op_id 发第二次
        return { status = "UNKNOWN", reason = "critical_ledger is not configured" }
    end
    return require("skyext.critical").query(entity, op_id, {
        now = os.time(),
        ledger = ledger,
    })
end

-- 迁移（P15）：导出会话快照。调用方必须先确认网关屏障与实体队列排空，
-- 否则导出的是一个还在变的 out_buf
-- 关键账本维护：归档与"确保恢复任务存在"
FRAMEWORK.critical_archive = function(entity, limit)
    local ledger = config_collection(type_config.critical_ledger)
    if not ledger then
        return nil, "critical_ledger is not configured"
    end
    return require("skyext.critical").archive_ops(entity, { ledger = ledger }, { limit = limit })
end

FRAMEWORK.critical_ensure_job = function(entity, op_id)
    local jobs = config_collection(type_config.critical_jobs)
    if not jobs then
        return nil, "critical_jobs is not configured"
    end
    local job, err = require("skyext.critical").reconcile(jobs, entity.id, op_id, {
        now = os.time(),
        last_error = "maintenance scan",
    })
    if not job then
        return nil, err
    end
    return { task_id = job.task_id, state = job.state }
end

-- 恢复任务取证明（P08 §4.4.1 / §4.7）。
-- 只在实体已加载时被调用，此时 dbmgr.load 已完成 Majority Fence 认领，
-- 旧 owner 的迟到 CAS 已被屏障挡住；因此这里读到的持久化状态可以当事实用。
-- 返回值只有三种：COMMITTED / NOT_COMMITTED / UNKNOWN，绝不做人工强解。
FRAMEWORK.critical_resolve_intent = function(entity, op_id)
    local critical = require "skyext.critical"
    local ledger = config_collection(type_config.critical_ledger)
    if not ledger then
        -- 没有冷账本就不能排除"热条目已归档"，更不能判定未提交
        return { status = "UNKNOWN", reason = "critical_ledger is not configured" }
    end

    -- 取消未决意图：一次 CAS 写 ABORTED 终态并清 PREPARED，不产生业务效果。
    -- majority_read：内存里没有意图不等于库里没有（PREPARE 落库但 ACK 丢失时
    -- commit_core 的 UNKNOWN 分支不会 set_critical），必须按持久化事实判定
    local function abort_pending()
        local state, detail = critical.abort_intent(entity, { now = os.time(), majority_read = true })
        if state == "CONFIRMED" then
            -- 内存里的普通字段可能已被 apply 污染：让调用方卸载实体，下次从库重读
            return { status = "NOT_COMMITTED", discard = true }
        end
        if state == "REJECTED" and detail == "no pending intent" then
            -- 第一次 abort 可能已经清掉 intent，但 mark_discarded 失败；第二次
            -- 多轮查询看到 no pending intent，不能据此直接结案。隔离态仍要重试
            -- 标作废，否则实体永远没有下一次卸载机会。
            local dbmgr = require "skyext.dbmgr"
            local state_now = dbmgr.state_of(type_config.db_name, type_config.db_coll, entity.id)
            if state_now == "CRITICAL_QUARANTINED" then
                local marked, mark_err =
                    dbmgr.mark_discarded(type_config.db_name, type_config.db_coll, entity.id, entity.handle)
                if not marked then
                    return { status = "UNKNOWN", reason = "mark_discarded failed: " .. tostring(mark_err) }
                end
                return { status = "NOT_COMMITTED", discard = true }
            end
            return { status = "NOT_COMMITTED" }
        end
        return { status = "UNKNOWN", reason = tostring(detail) }
    end

    local proof = critical.query(entity, op_id, { now = os.time(), ledger = ledger, majority_read = true })
    if proof.status == "COMMITTED" or proof.status == "BUSINESS_REJECTED" then
        -- 已提交，但实体可能还停在隔离态（COMMIT 落库、ACK 丢失那条路径）。
        -- 隔离态下普通回存是停的，不卸载的话这个角色会一直零落库。
        -- 正常态不打扰：内存就是权威副本，没必要为一次查询把在线玩家踢下线
        local state = require("skyext.dbmgr").state_of(type_config.db_name, type_config.db_coll, entity.id)
        if state == "CRITICAL_QUARANTINED" then
            return { status = "COMMITTED", discard = true }
        end
        return { status = "COMMITTED" }
    end
    if proof.status == "IN_PROGRESS" then
        if proof.intent_op_id ~= op_id then
            -- 挂着的是别的操作：本任务证明不了它，保持 UNKNOWN 等它自己推进
            return { status = "UNKNOWN", reason = "another intent is pending" }
        end
        -- 挂着的就是本任务要解析的这条：COMMIT 会同时写 op 记录并清意图，
        -- 意图还在就说明没有提交过；而实体已持新 fence，旧 owner 的迟到 CAS 会被挡。
        -- 不在这里取消，query 就永远回 IN_PROGRESS，任务永远停在 RETRY_WAIT，
        -- 同角色其它关键操作也会一直被"another critical operation is in flight"挡住
        return abort_pending()
    end
    if proof.status == "UNKNOWN" then
        return { status = "UNKNOWN" }
    end
    -- 到这里的只有 NOT_STARTED / EXPIRED_NOT_EXECUTED（ABORTED 由 query 映射成 NOT_STARTED）
    return abort_pending()
end

FRAMEWORK.session_export = function(entity, barrier_id, target_owner_epoch)
    if not session then
        return nil, "no session layer"
    end
    local io_ = entity.session_io
    if not io_ then
        return nil, "no session io"
    end
    if io_.unresumable then
        return nil, "session is unresumable"
    end
    local current = io_.owner_epoch or 1
    -- 新 owner 的 epoch 必须严格前进：网关用严格大于来拒绝旧 owner 的迟到下行
    local target = math.tointeger(target_owner_epoch) or (current + 1)
    if target <= current then
        return nil, "target owner epoch must advance"
    end
    -- 冻结源：导出之后不再追加 out_buf，否则目标拿到的是一份会过期的快照
    io_.migrating = true
    local bytes, err = require("skyext.session_snapshot").encode(io_)
    if not bytes then
        io_.migrating = false
        return nil, err
    end
    -- 快照一旦送出就不能再撤销冻结：源端继续写 out_buf 会让 sent 领先目标，
    -- 客户端 ACK 越界后整个会话只能重登。unquiesce 据此拒绝
    entity.migration_exported = true
    return {
        bytes = bytes,
        session_epoch = io_.session_epoch,
        owner_epoch = target,
        -- 目标侧安装快照时必须先保留源端代际：session.attach 要求传入的
        -- owner_epoch 严格大于 io_.owner_epoch，网关 resume 才会认这次切换。
        -- 一开始就把它写成 target 会让最后一跳永远拿不到可推进的代际。
        source_owner_epoch = current,
        sent = io_.sent,
        acked = io_.acked,
        barrier_id = barrier_id,
    }
end

-- 迁移（P15）：在目标节点安装快照。`session_epoch` 必须原样保留——
-- 客户端按 (session_epoch, seq) 去重，换了 epoch 就变成一次新的登录
FRAMEWORK.session_import = function(entity, payload)
    if not session then
        return nil, "no session layer"
    end
    if type(payload) ~= "table" or type(payload.bytes) ~= "string" then
        return nil, "snapshot is required"
    end
    local snapshot_mod = require "skyext.session_snapshot"
    local snapshot, derr = snapshot_mod.decode(payload.bytes)
    if not snapshot then
        return nil, derr
    end
    -- 新 owner_epoch 必须严格前进：等于或小于当前值都意味着所有权没有真正切换
    local current = entity.session_io and entity.session_io.owner_epoch or 0
    local target = math.tointeger(payload.owner_epoch)
    if not target then
        return nil, "target owner epoch is required"
    end
    if target <= current then
        return nil, "owner epoch would go backwards"
    end
    -- 目标已经用另一条会话重新登录过：旧 out_buf 装上去会覆盖新会话，
    -- 客户端从此按错误的序号去重
    if entity.session_io and entity.session and entity.session_io.session_epoch ~= snapshot.session_epoch then
        return nil, "target already has a different live session"
    end
    -- 快照里装的是源端会话，代际也停在源端；认领动作留给 session.attach：
    -- 它必须先让网关 resume_owner(target) 成功，再把本地 epoch 推进到 target。
    local source_epoch = math.tointeger(payload.source_owner_epoch) or (target - 1)
    if source_epoch >= target then
        return nil, "source owner epoch must be older than the target"
    end
    local io_, rerr = snapshot_mod.restore(snapshot, payload.session_epoch, {
        owner_epoch = source_epoch,
        -- 与 session.lua 的空闲回收同一条时钟（厘秒），不是 os.time()
        now = skynet.now(),
    })
    if not io_ then
        return nil, rerr
    end
    entity.session_io = io_
    entity.migration_target_epoch = target
    return {
        session_epoch = io_.session_epoch,
        owner_epoch = io_.owner_epoch,
        target_owner_epoch = target,
        sent = io_.sent,
        acked = io_.acked,
    }
end

-- 迁移（P15）最后一跳：把连接接到新 owner 上并重放未确认下行。
-- 必须在 session_import 之后调用：只装 session_io 不建连接记录，目标就没有下行出口
FRAMEWORK.session_attach = function(entity, conn_id)
    if not session then
        return nil, "no session layer"
    end
    local io_ = entity.session_io
    if not io_ then
        return nil, "no session io"
    end
    -- 认领代际由 session_import 记录；直接调用（没有装过快照）时按当前值 +1。
    -- 绝不能把 io_.owner_epoch 原样传回去：attach 要求严格前进，那样必然自拒，
    -- 网关屏障也就永远没人解除。
    local target = math.tointeger(entity.migration_target_epoch) or (io_.owner_epoch + 1)
    local ok, err = session.attach(conn_id, entity, self_service_name(), target)
    if not ok then
        return nil, err
    end
    entity.migration_target_epoch = nil
    if not session.replay(entity) then
        -- 重放缓冲有缺口：attach 已经把连接踢掉，客户端会重新登录
        return nil, "replay gap"
    end
    return {
        session_epoch = io_.session_epoch,
        owner_epoch = io_.owner_epoch,
        sent = io_.sent,
        acked = io_.acked,
    }
end

-- 主动加载一个实体（常驻实体的预加载用）。返回 true，或 false, reason
function CMD.activate(entity_id)
    local ok, reason = entitymgr:ensure_loaded(entity_id)
    return ok == true, ok ~= true and reason or nil
end

function CMD.unload_entity(entity_id)
    return entitymgr:unload(entity_id)
end

-- 停服：不再加载新实体，卸载全部已加载的实体。返回还没卸掉的数量，调用方可以再调一次。
-- 卸干净之后本服务不再加锁。锁键真正从 etcd 消失是在 node_shutdown 撤销节点租约时，
-- 这里不撤——租约是节点级的，本节点别的服务还挂在上面。
function CMD.shutdown()
    local remaining = entitymgr:unload_all()
    if remaining == 0 then
        distributed_lock.shutdown()
    end
    return remaining
end

-- 把网关上的一个会话绑到实体上（玩家登录）。由登录服务经 router.bind_session 调用。
-- 实体还被别的节点持有着时向它要一次（重新登录的语义：对方卸载并踢掉旧连接）。
-- 返回错误码、续接凭据、session_epoch 和协商后的下行模式
function CMD.bind_session(entity_id, conn_id, session_mode)
    if not session then
        log.warn("bind_session without a session layer", "id", entity_id)
        return errcode.PARAM_ERROR
    end
    local parsed, perr = session.parse_conn(conn_id)
    if not parsed then
        log.warn("reject bind with an invalid conn_id", "id", entity_id, "err", perr)
        return errcode.PARAM_ERROR
    end
    local ok, reason, holder_node = entitymgr:try_ensure_loaded(entity_id)
    if not ok then
        if reason == "not found" then
            return errcode.ENTITY_NOT_FOUND
        end
        if reason ~= "lock held" or not holder_node or holder_node == self_node() then
            return errcode.LOCK_FAILED
        end
        if not request_handoff(entity_id, holder_node) then
            return errcode.IN_OTHER_NODE
        end
    end

    local key = conn_id
    local bound, result, nonce, epoch, mode = entitymgr:with_entity(entity_id, function(entity)
        if entity.migrating then
            return errcode.SESSION_CLOSED
        end
        local old = entity.session
        if old and old.key ~= key then
            session.unbind_kick(old.key, entity)
        end
        local ok_bind, new_nonce, new_epoch, new_mode = session.bind(conn_id, entity, self_service_name(), session_mode)
        if not ok_bind then
            -- 排队期间客户端已经断开
            return errcode.SESSION_CLOSED
        end
        if handler.on_bind_client then
            handler.on_bind_client(entity, key)
        end
        return errcode.OK, new_nonce, new_epoch, new_mode
    end)
    if not bound then
        log.error("bind_session failed", "type", type_name, "id", entity_id, "err", result)
        return errcode.LOCK_FAILED
    end
    return result, nonce, epoch, mode
end

-- 断线后把一条新连接接回原来的会话。和 bind_session 的区别是**绝不加载实体**：
-- 续接不验 token、不查库，能触发加载就等于开放一个无认证的接口。实体不在内存里意味着
-- 会话状态早已不存在，续接本来也必然失败，这不是额外限制。
-- 返回错误码、轮换后的新凭据、服务端已发出的包数、session_epoch、模式
function CMD.resume_session(entity_id, conn_id, nonce, recv, session_mode, session_epoch)
    if not session then
        -- 这类实体根本没启用会话层，不是"实体不存在"
        return errcode.RESUME_UNAVAILABLE
    end
    local parsed, perr = session.parse_conn(conn_id)
    if not parsed then
        log.warn("reject resume with an invalid conn_id", "id", entity_id, "err", perr)
        return errcode.PARAM_ERROR
    end
    local ok, code, new_nonce, sent, epoch, mode = entitymgr:with_loaded_entity(entity_id, function(entity)
        if entity.migrating then
            return errcode.RESUME_UNAVAILABLE
        end
        local c, n, s, e, m = session.resume(conn_id, entity, self_service_name(), nonce, recv, {
            session_mode = session_mode,
            session_epoch = session_epoch,
        })
        if c ~= errcode.OK then
            return c
        end
        -- 先重放再回调。on_resume_client 里业务多半会推一些状态，这些新包必须排在
        -- 重放的旧包后面，否则客户端的收包顺序和计数就对不上了
        session.replay(entity)
        if handler.on_resume_client then
            handler.on_resume_client(entity, entity.session.key)
        end
        return c, n, s, e, m
    end)
    if not ok then
        return errcode.ENTITY_NOT_FOUND
    end
    return code, new_nonce, sent, epoch, mode
end

-- gate 转发来的上行包
function CMD.client_msg(conn_id, data)
    if not session then
        return
    end
    if not session.parse_conn(conn_id) then
        log.warn("drop a package with an invalid conn_id")
        return
    end
    -- 迁移冻结：QUIESCING 之后到达的上行一律丢弃，既不执行也不回包。
    -- 不回包是有意的——客户端按超时重传同一个 req_id，重传落到新 owner 上会命中
    -- 随快照迁过去的幂等缓存，拿到的还是第一次执行的结果；而在协议层回一个"拒绝"
    -- 会让没有 errcode 字段的协议走断连兜底，把无感迁移变成一次掉线。
    local entity = session.get_entity(conn_id)
    if entity and entity.migrating then
        log.debug("drop upstream while the entity is migrating", "type", type_name, "id", tostring(entity.id))
        return
    end
    require("skyext.sproto_api").dispatch_message(conn_id, data)
end

-- gate 上的连接断开了
function CMD.session_closed(conn_id)
    -- 断连必须中止该连接上所有在途的主动 RPC：否则迟到的响应会按 session 编号
    -- 误删后来复用同一编号的 pending（B0-05 / T11）。这条路径是 abort_conn
    -- 唯一的生产调用点，不能只留辅助函数
    require("skyext.sproto_api").abort_conn(conn_id)
    if not session then
        return
    end
    if not session.parse_conn(conn_id) then
        log.warn("drop session_closed with an invalid conn_id")
        return
    end
    local key = conn_id
    local entity = session.get_entity(key)
    if not entity then
        return
    end
    local ok = entitymgr:with_loaded_entity(entity.id, function(active)
        if active ~= entity or session.get_entity(key) ~= active then
            return
        end
        session.unbind(key)
        if handler.on_unbind_client then
            handler.on_unbind_client(active)
        end
    end)
    if not ok and session.get_entity(key) == entity then
        session.unbind(key)
    end
end

-- ---------------------------------------------------------------------------
-- 计划内迁移（P15）：实体侧三个动作，由游戏层的迁移适配器经 router / cluster 调用，
-- 不在客户端协议里暴露。编排与失败分流见 skyext.migration。
-- ---------------------------------------------------------------------------

-- 枚举本 agent 已加载的实体（含迁移分流状态）。适配器用它决定哪些实体能无感移交
function CMD.migration_list()
    if not entitymgr then
        return {}
    end
    return entitymgr:list_loaded()
end

-- QUIESCING：冻结实体，排空队列。返回 true 表示可以继续导出快照
function CMD.migration_quiesce(entity_id)
    if not entitymgr then
        return false, "entity manager not ready"
    end
    return entitymgr:quiesce(entity_id)
end

-- 迁移失败、实体留在本节点继续服务。快照已送出的实体不允许撤销
function CMD.migration_unquiesce(entity_id, reason)
    if not entitymgr then
        return false, "entity manager not ready"
    end
    return entitymgr:unquiesce(entity_id, reason)
end

-- 落库 + 释放锁 + 解除绑定，但不断开客户端：连接要留给目标节点接管
function CMD.migration_release(entity_id)
    if not entitymgr then
        return false, "entity manager not ready"
    end
    return entitymgr:release_for_migration(entity_id)
end

-- 迁移中转：快照先落到目标进程，再由 migration_commit 在实体队列里安装。
-- 拆成两步是为了让 TRANSFER（送达）与 OWNER_HANDOFF（认领 + 安装）各自可观测、可重试；
-- 合成一步的话，安装失败就分不清是没送到还是没认领上。
local g_staged = {}
-- 已成功提交的终态，按 entity 保存最近一轮。重复 commit / RPC 重试必须幂等返回，
-- 不能因为暂存已清理而返回 no staged snapshot。
local g_committed = {}
-- 已被源端取消的迁移：entity_id -> { barrier_id, at }。
-- 源端 abort 后可能仍有 commit/attach RPC 在路上（无超时的 cluster.call），
-- 目标端必须据此拒绝接管，否则会出现「源端已放弃、目标端却完成了迁移」。
local g_aborted_barriers = {}
local STAGED_TTL = 60
-- 终态要覆盖一次跨节点 RPC 的完整重试窗口，不能和暂存快照一样只留 60 秒：
-- Commit 已成功但响应丢失时，源端稍后重试仍应幂等成功，而不是回到 no staged snapshot。
local COMMITTED_TTL = 300
local STAGED_MAX = 64
local STAGE_STAGED = "STAGED"
local STAGE_COMMITTING = "COMMITTING"

-- 测试用的时钟偏移。TTL 过期是 A-07 的核心语义（陈旧取消标记必须自己过期，
-- 不能靠"别的实体恰好来 stage"顺带清），而 os.time() 在单测里走不动，
-- 所以留一个显式的、只在测试里用的偏移入口
local g_clock_skew = 0
local function wall_now()
    return os.time() + g_clock_skew
end

function CMD._test_advance_time(seconds)
    g_clock_skew = g_clock_skew + (seconds or 0)
    return wall_now()
end

local function prune_staged(now)
    local count = 0
    for id, entry in pairs(g_staged) do
        if now - entry.at > STAGED_TTL then
            g_staged[id] = nil
        else
            count = count + 1
        end
    end
    for id, entry in pairs(g_aborted_barriers) do
        if now - entry.at > STAGED_TTL then
            g_aborted_barriers[id] = nil
        end
    end
    for id, entry in pairs(g_committed) do
        if now - entry.at > COMMITTED_TTL then
            g_committed[id] = nil
        end
    end
    return count
end

function CMD.migration_stage(entity_id, payload)
    if type(payload) ~= "table" or type(payload.bytes) ~= "string" then
        return false, "snapshot is required"
    end
    local now = wall_now()
    -- 先清过期标记，再做取消判断。
    -- 反过来的话，一个上一轮留下的取消标记会在 TTL 内把这一轮的 stage 直接拒掉，
    -- 而这个实体在目标节点上就再也迁不进来了（停服重试时正好命中）。
    -- prune 原本只在"别的实体也来 stage"时才被顺带触发，等于没触发
    local count = prune_staged(now)
    local barrier_id = payload.barrier_id
    local existing = g_staged[entity_id]
    if existing then
        if existing.state == STAGE_COMMITTING then
            return false, "migration commit in progress"
        end
        if existing.barrier_id ~= barrier_id then
            -- 旧快照还没提交，不能用新快照覆盖：否则 Abort 正在处理旧 barrier 时
            -- 新 barrier 的 payload 会被旧 Commit 误装进实体。
            return false, "previous barrier still staged"
        end
        -- 同一 barrier 的重试是幂等的，允许刷新 payload 但不改变状态。
        existing.payload = payload
        existing.at = now
        return true
    end
    local committed = g_committed[entity_id]
    if committed and committed.barrier_id == barrier_id then
        -- Commit 已经成功，只是回包丢了：再次 Stage 不应把实体重新拉回待提交状态。
        return true
    end
    if
        committed
        and committed.owner_epoch
        and tonumber(payload.owner_epoch)
        and tonumber(payload.owner_epoch) <= committed.owner_epoch
    then
        -- 新一轮已经提交过更高的 owner_epoch。旧轮次迟到的 Stage 不能再把
        -- 低代际快照放回队列，否则新一轮会被它挡住，甚至被旧 Commit 尝试安装。
        return false, "stale barrier"
    end
    -- 同一 barrier 已经被源端取消：迟到的 stage 不能重新建立暂存
    local aborted = g_aborted_barriers[entity_id]
    if aborted then
        if aborted.barrier_id == barrier_id then
            return false, "migration aborted"
        end
        -- 不同 barrier 说明是上一轮留下的标记，允许新轮次
        g_aborted_barriers[entity_id] = nil
    end
    -- 没有上限的话，一次异常就能把目标节点变成快照仓库
    if count >= STAGED_MAX then
        return false, "too many staged snapshots"
    end
    g_staged[entity_id] = {
        payload = payload,
        at = now,
        barrier_id = barrier_id,
        state = STAGE_STAGED,
    }
    return true
end

-- 源端取消：目标端收到后必须拒绝同一 barrier 的后续 commit。
-- 幂等；barrier 不匹配时不覆盖已有标记（避免旧请求取消新一轮）。
function CMD.migration_abort(entity_id, barrier_id)
    if type(barrier_id) ~= "string" or barrier_id == "" then
        return false, "barrier_id is required"
    end
    -- 顺带清过期条目：取消标记只应在"目标端可能还有迟到 RPC 在路上"的窗口内存在，
    -- 否则它会一直占着这个实体，把下一轮正常迁移挡在外面
    prune_staged(wall_now())
    local staged = g_staged[entity_id]
    if staged and staged.barrier_id ~= barrier_id then
        -- 旧轮次的取消请求：不能让它误伤当前这一轮
        return false, "barrier mismatch"
    end
    if staged and staged.state == STAGE_COMMITTING then
        -- Commit 已经越过第一次 yield，正在实体队列里等待/安装。
        -- 此时不能谎称取消成功，也不能清掉它正在使用的快照；源端必须按
        -- COMMIT_IN_PROGRESS 处理，等 Commit 的终态。
        return false, "commit in progress"
    end
    local committed = g_committed[entity_id]
    if committed and committed.barrier_id == barrier_id then
        return false, "already committed"
    end
    local current = g_aborted_barriers[entity_id]
    if current and current.barrier_id ~= barrier_id then
        return false, "barrier mismatch"
    end
    g_aborted_barriers[entity_id] = { barrier_id = barrier_id, at = wall_now() }
    if staged then
        g_staged[entity_id] = nil
    end
    log.warn("migration aborted on target", "id", tostring(entity_id), "barrier", barrier_id)
    return true
end

-- 在实体队列里执行，异常转成失败返回而不是把 RPC 打崩
local function in_entity(entity_id, fn)
    local called, ok, result, err = pcall(entitymgr.with_entity, entitymgr, entity_id, fn)
    if not called then
        return false, tostring(ok)
    end
    return ok, result, err
end

-- OWNER_HANDOFF：认领 + 安装。with_entity 里的 ensure_loaded 就是 Fence 认领——
-- 源端已经释放锁，这里抢到的是新租约（fence 严格前进）。抢不到说明别的节点已经接管。
--
-- `barrier_id` 可选，但生产路径必须传：目标端可能同时存在"上一轮的取消标记"
-- 和"这一轮的暂存快照"，只有 barrier 才能说清这次 commit 属于哪一轮。
-- 不传就退回快照自带的 barrier（兼容旧调用方）。
function CMD.migration_commit(entity_id, barrier_id)
    if not entitymgr then
        return false, "entity manager not ready"
    end
    if barrier_id ~= nil and (type(barrier_id) ~= "string" or barrier_id == "") then
        return false, "barrier_id must be a non-empty string"
    end
    -- 先清过期标记，避免陈旧的取消记录挡住这一轮
    prune_staged(wall_now())
    local staged = g_staged[entity_id]
    local staged_barrier = staged and staged.barrier_id or nil

    -- 调用方声明的轮次与暂存的轮次不一致：这是上一轮的迟到 commit。
    -- 绝不能拿新一轮的快照去安装上一轮的认领
    if barrier_id ~= nil and staged_barrier ~= nil and staged_barrier ~= barrier_id then
        return false, "barrier mismatch"
    end

    local round = barrier_id or staged_barrier
    if not staged then
        local committed = g_committed[entity_id]
        if committed and (round == nil or committed.barrier_id == round) then
            -- Commit 已经成功，RPC 响应丢失后的重试必须幂等成功。
            return true
        end
        local aborted = g_aborted_barriers[entity_id]
        if aborted and (round == nil or aborted.barrier_id == round) then
            return false, "migration aborted"
        end
        return false, "no staged snapshot"
    end

    local aborted = g_aborted_barriers[entity_id]
    if aborted and (round == nil or aborted.barrier_id == round) then
        -- 源端已经取消这一轮：即使 commit RPC 迟到，也不能接管
        if staged_barrier == aborted.barrier_id then
            g_staged[entity_id] = nil
        end
        g_aborted_barriers[entity_id] = nil
        return false, "migration aborted"
    end
    if staged.state == STAGE_COMMITTING then
        return false, "commit in progress"
    end
    if staged.state ~= STAGE_STAGED then
        return false, "no staged snapshot"
    end

    -- 第一次 yield 之前先占住 COMMITTING。这样 Abort 即使随后到达，也只能
    -- 得到 COMMIT_IN_PROGRESS，不会清掉正在被安装的快照。
    staged.state = STAGE_COMMITTING
    staged.at = wall_now()
    local imported
    local ok, result, err = in_entity(entity_id, function(entity)
        local current = g_staged[entity_id]
        if current ~= staged or current.state ~= STAGE_COMMITTING then
            return false, "migration aborted"
        end
        local late_abort = g_aborted_barriers[entity_id]
        if late_abort and (round == nil or late_abort.barrier_id == round) then
            return false, "migration aborted"
        end
        local imported_result = FRAMEWORK.session_import(entity, current.payload)
        if type(imported_result) == "table" then
            imported = imported_result
        end
        return imported_result
    end)
    if not ok then
        if type(imported) == "table" then
            -- 回调已经成功安装，只是 with_entity 外层在归还租约时失败。
            -- 不能把已经生效的导入退回去，否则重试会再装一次。
            if g_staged[entity_id] == staged then
                g_staged[entity_id] = nil
            end
            g_committed[entity_id] = {
                barrier_id = round,
                at = wall_now(),
                owner_epoch = tonumber(staged.payload.owner_epoch),
            }
            return true
        end
        -- Claim 没拿到或 with_entity 外层失败：Import 还没执行，恢复成可重试。
        if g_staged[entity_id] == staged then
            staged.state = STAGE_STAGED
        end
        return false, tostring(result)
    end
    if type(result) ~= "table" then
        if g_staged[entity_id] == staged then
            staged.state = STAGE_STAGED
        end
        return false, tostring(err or "snapshot rejected")
    end
    if g_staged[entity_id] == staged then
        g_staged[entity_id] = nil
    end
    g_committed[entity_id] = {
        barrier_id = round,
        at = wall_now(),
        owner_epoch = tonumber(staged.payload.owner_epoch),
    }
    return true
end

-- REPLAYING：把连接交给新 owner 并重放。失败时快照仍留在实体上，
-- 客户端重新登录会走 bind 重建会话，不会带着半截状态继续跑
function CMD.session_attach(entity_id, conn_id)
    if not entitymgr then
        return false, "entity manager not ready"
    end
    local ok, result, err = in_entity(entity_id, function(entity)
        return FRAMEWORK.session_attach(entity, conn_id)
    end)
    if not ok then
        return false, tostring(result)
    end
    if type(result) ~= "table" then
        return false, tostring(err or "attach failed")
    end
    return true
end

-- 源端导出会话快照，供迁移适配器跨服务调用。
-- FRAMEWORK.session_export 只能经 entity_call -> handler_of 到达；适配器如果直接
-- skynet.call(..., "session_export", ...) 会被 cmd_api 当成未知命令并让整个
-- export 阶段 FALLBACK。这里给出显式的 CMD 入口，参数形状与其余 migration_* 一致。
function CMD.session_export(entity_id, barrier_id, target_owner_epoch)
    if not entitymgr then
        return false, "entity manager not ready"
    end
    local ok, result, err = in_entity(entity_id, function(entity)
        return FRAMEWORK.session_export(entity, barrier_id, target_owner_epoch)
    end)
    if not ok then
        return false, tostring(result)
    end
    if type(result) ~= "table" then
        return false, tostring(err or "snapshot rejected")
    end
    return true, result
end

function CMD.start(conf)
    local modules_path = conf.modules_path

    -- conf.modules 是 entity_agentmgr 扫磁盘得到的，文件一定存在。
    -- 这里不能吞 require 失败：漏掉一个 request 模块，它的所有协议都不会注册，
    -- 客户端发过来的包会被 skynet 当未知协议丢掉，两端都没有日志，只剩超时。
    for _, mod in ipairs(conf.modules) do
        local mod_path = modules_path .. "." .. mod.name

        if mod.init then
            local data_mod = require(mod_path)
            if type(data_mod) == "table" and data_mod.new then
                g_data_modules[mod.name] = data_mod
                g_module_order[#g_module_order + 1] = mod.name
            end
        end

        if mod.request and type_config.client_enabled then
            local request = require(mod_path .. ".request")
            assert(type(request) == "table", mod_path .. ".request must return a table")
            local sproto_api = require "skyext.sproto_api"
            sproto_api.register_module(mod.name, session, request)
        end
    end

    handler = require("entity_handler." .. type_name)
    install_framework_commands(handler.framework_commands)
    -- 可靠消息投递也走同一套命令解析：Outbox 回执这类框架命令不在 handler.handlers 里，
    -- 只查业务表会让它们永远 "no handler" 并进死信队列
    handler.resolve = handler_of
    entitymgr = entitymgr_mod.new(type_name, type_config, handler, g_data_modules, g_module_order)

    if session then
        -- 心跳这类传输层协议也注册成 "login.*"：会话绑定之后上行包由网关直接转给实体，
        -- 登录服务再也看不到这条连接，两份同名注册在不同进程角色里，不冲突
        require("skyext.sproto_api").register_module("login", session, session.cmds)
        session.init(entitymgr)
    end

    log.info("entity_agent started", "type", type_name, "index", agent_index, "modules", module_names(conf.modules))
end

skynet.start(function()
    skynet.register(types.format_agent_service_name(type_name, agent_index))

    if type_config.client_enabled then
        session = require "skyext.entity.session"
    end

    cmd_api.dispatch(CMD)
end)
