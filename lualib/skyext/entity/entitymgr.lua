local skynet = require "skynet"
local dbmgr = require "skyext.dbmgr"
local delivery = require "skyext.entity.delivery"
local distributed_lock = require "skyext.distributed_lock"
local timer = require "skyext.timer"
local log = require "skyext.log"
local config = require "skyext.config"
local queue = require "skynet.queue"

local M = {}
M.__index = M

-- with_loaded_entity 在实体没加载（或已失效）时返回的原因，f 没有执行。
-- 转发方据此判断可以安全地换个地方重试
M.NOT_LOADED = "entity not loaded or lease expired"

-- reliable_msg 会连上 mongo，加载期 require 会把尚未配置好的连接固化下来，
-- 因此推迟到首次投递时再取
local g_reliable_msg
local function reliable_msg()
    if not g_reliable_msg then
        g_reliable_msg = require "skyext.entity.reliable_msg"
    end
    return g_reliable_msg
end

-- 卸载失败后的重试间隔（秒），可按实体类型用 unload_retry_delay 覆盖
local UNLOAD_RETRY_DELAY = 5
-- 退避上限，避免数据库/etcd 长时间故障时持续重试刷日志
local UNLOAD_RETRY_MAX_DELAY = 300
-- 失租后把脏数据接回来的尝试次数上限。退避累计远超租约 TTL 仍然拿不到锁，
-- 说明实体已经被别的节点接管，对方正基于库里的数据在工作，这份内存改动
-- 再接回去就是拿旧状态覆盖新状态，只能丢。
local DIRTY_RECOVERY_MAX_ATTEMPTS = 8
-- 停服时同时在卸载的实体数。每个卸载都要写一次库、删一次锁，串行做几千个实体会很久
local SHUTDOWN_CONCURRENCY = 16

function M.new(type_name, type_config, handler, data_modules, module_order)
    local self = setmetatable({
        type_name = type_name,
        type_config = type_config,
        handler = handler,
        data_modules = data_modules or {},
        -- 配置里的声明顺序。on_load 按它跑，on_unload 必须按逆序跑，
        -- 否则 B 依赖 A 的初始化、卸载时 A 先被拆掉，B 的 on_unload 就会读到空状态
        module_order = module_order or {},
        entities = {},
        gates = {},
        -- 临时实体的实例代际：同一个 ID 卸载后重新创建会拿到新的 generation，
        -- 旧实例上迟到的消息/定时器回调可以据此丢弃
        generation = 0,
    }, M)
    return self
end

-- 有声明顺序就按声明顺序；没有（老调用方/测试）就按名字排序，
-- 至少保证同一进程内每次一致，不能退化成 pairs 的随机顺序
function M:_module_names()
    local names, seen = {}, {}
    -- 先按声明顺序；order 里的重复名只算一次
    for _, name in ipairs(self.module_order or {}) do
        if self.data_modules[name] and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    -- order 没列到的模块不能静默丢掉：按名字排序补在后面，保证一定会被初始化/卸载
    local rest = {}
    for name in pairs(self.data_modules) do
        if not seen[name] then
            rest[#rest + 1] = name
        end
    end
    table.sort(rest)
    for _, name in ipairs(rest) do
        names[#names + 1] = name
    end
    return names
end

local function make_lock_key(type_name, entity_id)
    return string.format("entity/%s/%s", type_name, tostring(entity_id))
end

local function make_lock_value()
    return config.get("cluster_node_name") or "unknown"
end

function M:_init_modules(entity)
    if not next(self.data_modules) then
        return
    end
    if entity.data.modules == nil then
        entity.data.modules = {}
    end
    entity.modules = {}
    -- on_load 已经跑完的模块；初始化中途失败时只有这些模块需要补 on_unload
    entity.loaded_modules = {}
    for _, name in ipairs(self:_module_names()) do
        local mod = self.data_modules[name]
        if entity.data.modules[name] == nil then
            entity.data.modules[name] = {}
        end
        entity.modules[name] = mod.new(entity, entity.data.modules[name])
    end
end

function M:_call_modules_on_load(entity)
    if not entity.modules then
        return true
    end
    for _, name in ipairs(self:_module_names()) do
        local mod_inst = entity.modules[name]
        if mod_inst.on_load then
            local ok, err = xpcall(mod_inst.on_load, debug.traceback, mod_inst)
            if not ok then
                log.error("module on_load failed", "type", self.type_name, "id", entity.id, "module", name, "err", err)
                return false, err
            end
        end
        -- 记下已经加载完成的模块：初始化在中途失败时，这些模块的 on_unload 仍然要跑
        entity.loaded_modules[name] = true
    end
    return true
end

-- only_loaded: 只卸载 on_load 已经跑完的模块。初始化中途失败时必须这样，
-- 否则 on_load 没跑过的模块会被 on_unload 拆一遍不存在的状态
function M:_call_modules_on_unload(entity, only_loaded)
    if not entity.modules then
        return true
    end
    -- 卸载失败会重试，已经完成的模块不能再跑一次 on_unload
    local done = entity.unloaded_modules
    if not done then
        done = {}
        entity.unloaded_modules = done
    end
    local loaded = entity.loaded_modules
    local names = self:_module_names()
    -- 逆序卸载：后初始化的模块先拆
    for i = #names, 1, -1 do
        local name = names[i]
        local mod_inst = entity.modules[name]
        local need_unload = mod_inst.on_unload ~= nil and not done[name]
        if need_unload and only_loaded then
            need_unload = loaded ~= nil and loaded[name] == true
        end
        if need_unload then
            local ok, err = xpcall(mod_inst.on_unload, debug.traceback, mod_inst)
            if not ok then
                log.error(
                    "module on_unload failed",
                    "type",
                    self.type_name,
                    "id",
                    entity.id,
                    "module",
                    name,
                    "err",
                    err
                )
                return false, err
            end
            done[name] = true
        end
    end
    return true
end

-- 投递一条消息。返回 ok, reason, message_fault。
-- message_fault 为 true 表示错在消息本身（没有对应 handler、handler 抛错），
-- 重投多少次结果都一样，要计入毒消息次数；为 false 表示环境问题
-- （租约失效、落库失败、ack 写库失败），换个时间重投就能成功，不计数。
-- 实体是否仍然可写。临时实体不持有 etcd 锁，`is_valid(nil)` 恒为 false，
-- 直接用它会把这个实体当成"租约过期"：每个请求执行完就被标 invalid、踢客户端、卸载。
local function entity_lease_ok(entity)
    if entity.persistent == false then
        return true
    end
    return distributed_lock.is_valid(entity.handle)
end

function M:_deliver_one(entity, msg)
    -- 优先用 handler.resolve（框架命令 + 业务 handler 的统一解析）：
    -- Outbox 回执 outbox_ack 是框架命令，只查 handler.handlers 会让它永远
    -- "no handler" 并进死信队列
    local handler_func
    if type(self.handler.resolve) == "function" then
        local resolved, fn = pcall(self.handler.resolve, msg.cmd)
        handler_func = resolved and fn or nil
    else
        handler_func = self.handler.handlers and self.handler.handlers[msg.cmd]
    end
    if not handler_func then
        return false, string.format("no handler for command %s", tostring(msg.cmd)), true
    end
    local args = table.pack(table.unpack(msg.args or {}))
    args.n = args.n + 1
    args[args.n] = msg.msg_id
    local ok, result = xpcall(handler_func, debug.traceback, entity, table.unpack(args, 1, args.n))
    if not ok then
        -- 抛异常仍是"消息本身/处理逻辑有问题"：计 attempts，到上限进 DLQ。
        -- 新关键 handler 若遇到环境暂态，必须在边界内转换成 delivery.retryable，
        -- 不能指望框架把所有 xpcall 抛错都当环境故障——那会让代码 bug 永远卡在 pending
        return false, result, true
    end
    if delivery.is_retryable(result) then
        -- 环境故障：不 save、不 mark_delivered、不计 attempts、不进 DLQ
        return false, result.reason, false, true
    end
    if entity.invalid or not entity_lease_ok(entity) then
        return false, "lease expired during handler", false
    end
    local tc = self.type_config
    if not dbmgr.save(tc.db_name, tc.db_coll, tc.id_field, entity.id) then
        return false, "entity persistence failed", false
    end
    if entity.invalid or not entity_lease_ok(entity) then
        return false, "lease expired during persistence", false
    end
    local acked, reason = reliable_msg().mark_delivered(msg.msg_id)
    if not acked and reason ~= "already_delivered" then
        return false, reason, false
    end
    return true
end

-- 累计一条消息的投递失败次数，到上限则移入死信队列。
-- 返回 true 表示消息已被隔离，调用方可以跳过它继续处理后面的消息；
-- 返回 false 表示它还留在队列头部，整批投递必须停下来重试。
function M:_quarantine(entity, msg, reason)
    local rmsg = reliable_msg()
    local attempts, record_err = rmsg.record_failure(msg.msg_id, reason)
    if not attempts then
        -- 次数记不上就不能判死：宁可继续重投，也不能凭未知次数把消息误隔离
        log.error(
            "reliable message attempt count failed",
            "type",
            self.type_name,
            "id",
            entity.id,
            "msg_id",
            msg.msg_id,
            "err",
            record_err
        )
        return false
    end
    local max_attempts = rmsg.max_attempts()
    if attempts < max_attempts then
        log.error(
            "reliable message delivery failed",
            "type",
            self.type_name,
            "id",
            entity.id,
            "cmd",
            msg.cmd,
            "msg_id",
            msg.msg_id,
            "attempts",
            attempts,
            "max_attempts",
            max_attempts,
            "err",
            reason
        )
        return false
    end
    if not rmsg.mark_dead(msg.msg_id, reason) then
        return false
    end
    log.error(
        "reliable message moved to dead letter queue",
        "type",
        self.type_name,
        "id",
        entity.id,
        "cmd",
        msg.cmd,
        "msg_id",
        msg.msg_id,
        "attempts",
        attempts,
        "err",
        reason
    )
    return true
end

function M:_deliver_pending_msgs(entity)
    local rmsg = reliable_msg()
    local msgs = rmsg.load_pending(self.type_name, entity.id, { max_count = rmsg.DEFAULT_PAGE_SIZE })
    delivery.observe_pending(self.type_name, entity.id, #msgs)
    local quarantined = 0
    local delivered = 0
    for _, msg in ipairs(msgs) do
        if entity.invalid or not entity_lease_ok(entity) then
            return false, "lease expired"
        end
        local ok, reason, message_fault, retryable = self:_deliver_one(entity, msg)
        if ok then
            delivered = delivered + 1
            delivery.clear(msg.msg_id)
        elseif retryable then
            -- 保留 pending，等实体队列的后续重投。这里只做转换计数与连续次数升级，
            -- 绝不累计 attempts / 进 DLQ：Mongo 暂不可用不是毒消息
            delivery.note_retryable(self.type_name, entity.id, msg.msg_id, reason)
            delivery.observe_pending(self.type_name, entity.id, #msgs - delivered)
            return false, reason
        elseif not message_fault then
            log.error(
                "reliable message delivery deferred",
                "type",
                self.type_name,
                "id",
                entity.id,
                "msg_id",
                msg.msg_id,
                "err",
                reason
            )
            delivery.observe_pending(self.type_name, entity.id, #msgs - delivered)
            return false, reason
        else
            -- 毒消息没达到上限时仍然卡在队首：消息之间可能有先后依赖，
            -- 不能为了让队列往前走就跳过一条还可能成功的消息
            if not self:_quarantine(entity, msg, reason) then
                delivery.observe_pending(self.type_name, entity.id, #msgs - delivered)
                return false, reason
            end
            quarantined = quarantined + 1
        end
    end
    delivery.observe_pending(self.type_name, entity.id, #msgs - delivered - quarantined)
    if quarantined > 0 or #msgs == rmsg.DEFAULT_PAGE_SIZE then
        -- 隔离掉毒消息后被它挡住的消息已经可以投递了，立刻再跑一轮
        skynet.fork(function()
            self:deliver_pending(entity.id)
        end)
    end
    return true
end

-- 实体对象上的方法，handler 和数据模块里用 entity:every(...) 这样调用
local entity_methods = {}
local entity_mt = { __index = entity_methods }

-- 重复定时器：每隔 sec 秒在实体的串行队列里执行一次 fn(entity)。
-- 同名定时器会替换旧的；实体卸载、失租后自动停止；不会延长实体寿命（不重置闲置卸载计时）
function entity_methods:every(name, sec, fn)
    self.entity_mgr:_arm_timer(self, name, sec, fn, true)
end

-- 一次性定时器，语义同 every
function entity_methods:after(name, sec, fn)
    self.entity_mgr:_arm_timer(self, name, sec, fn, false)
end

function entity_methods:cancel_timer(name)
    self.entity_mgr:_cancel_timer(self, name)
end

function M:_cancel_timer(entity, name)
    local slot = entity.timers[name]
    if not slot then
        return
    end
    entity.timers[name] = nil
    if slot.obj then
        slot.obj:cancel()
    end
end

function M:_cancel_all_timers(entity)
    for name in pairs(entity.timers) do
        self:_cancel_timer(entity, name)
    end
end

function M:_arm_timer(entity, name, sec, fn, repeating)
    assert(type(name) == "string", "entity timer needs a name")
    assert(type(sec) == "number" and sec > 0, "entity timer interval must be positive")
    self:_cancel_timer(entity, name)
    local slot = {}
    entity.timers[name] = slot
    local label = string.format("entity_timer:%s:%s:%s", self.type_name, tostring(entity.id), name)
    local function fire()
        slot.obj = nil
        if entity.timers[name] ~= slot then
            return
        end
        -- 走 with_loaded_entity：和请求、消息投递一样串行，并且实体没了或失租就不执行
        local ok, ran = pcall(self.with_loaded_entity, self, entity.id, function(active)
            if active == entity then
                fn(active)
            end
        end)
        if not ok then
            log.error("entity timer failed", "type", self.type_name, "id", entity.id, "timer", name, "err", ran)
        end
        if entity.timers[name] ~= slot then
            -- 回调里取消或换掉了这个定时器
            return
        end
        if (ok and not ran) or not repeating then
            entity.timers[name] = nil
            return
        end
        slot.obj = timer.timeout(label, sec, fire)
    end
    slot.obj = timer.timeout(label, sec, fire)
end

function M:_start_unload_timer(entity)
    if self.type_config.resident then
        -- 常驻实体（全局单例之类）不因闲置卸载，只在停服、失租时离开内存
        return
    end
    local delay = self.type_config.unload_delay or 600
    if entity.unload_timer then
        entity.unload_timer:cancel()
    end
    entity.unload_timer = timer.timeout("entity_unload:" .. tostring(entity.id), delay, function()
        entity.unload_timer = nil
        self:unload(entity.id)
    end)
end

function M:_cancel_unload_timer(entity)
    if entity.unload_timer then
        entity.unload_timer:cancel()
        entity.unload_timer = nil
    end
end

function M:_cancel_unload_retry(entity)
    if entity.unload_retry then
        entity.unload_retry:cancel()
        entity.unload_retry = nil
    end
end

-- 卸载中途失败时安排重试：实体已经处于半卸载状态，必须由重试把它彻底卸载掉，
-- 否则 unloading 会永久挂住，实体既不服务请求也不释放锁。
function M:_schedule_unload_retry(entity)
    if entity.unload_retry or self.entities[entity.id] ~= entity then
        return
    end
    local base = self.type_config.unload_retry_delay or UNLOAD_RETRY_DELAY
    local attempts = (entity.unload_retries or 0) + 1
    entity.unload_retries = attempts
    local delay = math.min(base * (1 << math.min(attempts - 1, 6)), UNLOAD_RETRY_MAX_DELAY)
    entity.unload_retry = timer.timeout("entity_unload_retry:" .. tostring(entity.id), delay, function()
        entity.unload_retry = nil
        if not self:unload(entity.id) then
            log.warn("entity unload retry failed", "type", self.type_name, "id", entity.id)
        end
    end)
end

-- 实体不再能服务请求时断开客户端，避免客户端继续向半卸载/失效的实体发请求
function M:_kick_client(entity, reason)
    local current = entity.session
    if not current then
        return
    end
    skynet.fork(function()
        local session = require "skyext.entity.session"
        local ok, err = pcall(session.unbind_kick, current.key, entity)
        if not ok then
            log.error(
                "failed to disconnect entity",
                "type",
                self.type_name,
                "id",
                entity.id,
                "reason",
                reason,
                "err",
                err
            )
        end
    end)
end

function M:_forget_entity(entity)
    self:_cancel_all_timers(entity)
    self:_cancel_unload_timer(entity)
    self:_cancel_delivery_retry(entity)
    self:_cancel_unload_retry(entity)
    delivery.forget(self.type_name, entity.id)
    if self.entities[entity.id] == entity then
        self.entities[entity.id] = nil
    end
end

function M:_cancel_delivery_retry(entity)
    if entity.delivery_retry then
        entity.delivery_retry:cancel()
        entity.delivery_retry = nil
    end
end

function M:_schedule_delivery_retry(entity)
    if entity.delivery_retry or entity.invalid or entity.unloading or not entity_lease_ok(entity) then
        return
    end
    entity.delivery_retry = timer.timeout("reliable_retry:" .. tostring(entity.id), 5, function()
        entity.delivery_retry = nil
        local ok, err = self:deliver_pending(entity.id)
        if not ok then
            log.warn("reliable delivery retry failed", "id", entity.id, "err", err)
        end
    end)
end

function M:_with_gate(entity_id, f)
    local gate = self.gates[entity_id]
    if not gate then
        gate = { run = queue(), users = 0 }
        self.gates[entity_id] = gate
    end
    gate.users = gate.users + 1
    local result = table.pack(pcall(gate.run, f))
    gate.users = gate.users - 1
    if gate.users == 0 then
        self.gates[entity_id] = nil
    end
    if not result[1] then
        error(result[2], 0)
    end
    return table.unpack(result, 2, result.n)
end

function M:_on_lock_expired(entity_id, handle)
    local entity = self.entities[entity_id]
    if not entity or entity.handle ~= handle or entity.invalid then
        return
    end
    entity.invalid = true
    self:_cancel_all_timers(entity)
    self:_cancel_unload_timer(entity)
    self:_cancel_delivery_retry(entity)
    self:_cancel_unload_retry(entity)
    self:_kick_client(entity, "lease lost")
    log.error("entity quarantined after lease loss", "type", self.type_name, "id", entity_id)
    skynet.fork(function()
        self:unload(entity_id)
    end)
end

-- 临时实体的默认数据是深拷贝：同一份 type_config.default 会被多个实例共用，
-- 共享引用会让一个实例的改动出现在另一个实例里
local function deep_copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = deep_copy(v)
    end
    return out
end

-- 临时实体（type_config.persistent = false）：
--   * 不占 etcd 锁、不读写 Mongo、没有可靠消息队列；
--   * 模块初始化/卸载顺序与持久实体完全一致；
--   * 节点崩溃即丢状态，玩法层负责重建或结束活动。
-- 每次创建都会推进 generation：旧实例上迟到的消息或定时器回调可以据此丢弃，
-- 否则同一个 ID 重建后会被上一局的残留事件打到。
function M:_create_ephemeral(entity_id)
    if self.closing then
        return false, "node shutting down"
    end
    self.generation = self.generation + 1
    local entity = setmetatable({
        type_name = self.type_name,
        id = entity_id,
        data = deep_copy(self.type_config.default) or {},
        entity_mgr = self,
        handle = nil,
        persistent = false,
        generation = self.generation,
        timers = {},
    }, entity_mt)
    self.entities[entity_id] = entity

    local initialized, init_err = xpcall(function()
        self:_init_modules(entity)
        local hooks_ok, hook_err = self:_call_modules_on_load(entity)
        assert(hooks_ok, hook_err)
        if self.handler.on_load then
            self.handler.on_load(entity)
        end
    end, debug.traceback)
    if not initialized then
        log.error("ephemeral entity initialization failed", "type", self.type_name, "id", entity_id, "err", init_err)
        entity.init_failed = true
        self:_unload_entity(entity)
        return false, init_err
    end

    self:_start_unload_timer(entity)
    log.info("ephemeral entity loaded", "type", self.type_name, "id", entity_id, "generation", entity.generation)
    return true, entity
end

-- 临时实体的实例代际；不在内存里返回 nil
function M:generation_of(entity_id)
    local entity = self.entities[entity_id]
    return entity and entity.generation or nil
end

function M:_ensure_loaded(entity_id)
    local entity = self.entities[entity_id]
    if entity then
        -- 临时实体不持有 etcd 锁，lease 判定对它不成立
        if entity.persistent ~= false and (entity.invalid or not distributed_lock.is_valid(entity.handle)) then
            self:_on_lock_expired(entity_id, entity.handle)
            return false, "entity lease expired"
        end
        if entity.unloading then
            return false, "entity unloading"
        end
        self:touch(entity_id)
        return true, entity
    end

    if self.closing then
        return false, "node shutting down"
    end

    local tc = self.type_config
    if tc.persistent == false then
        return self:_create_ephemeral(entity_id)
    end

    local lock_key = make_lock_key(self.type_name, entity_id)
    local ok, handle, owner = distributed_lock.try_lock(lock_key, make_lock_value(), function(expired)
        self:_on_lock_expired(entity_id, expired)
    end)
    if not ok then
        return false, handle, owner
    end

    local loaded, data, err =
        pcall(dbmgr.load, tc.db_name, tc.db_coll, tc.id_field, entity_id, handle, { create = tc.auto_create == true })
    if not loaded or not data or not distributed_lock.is_valid(handle) then
        local reason
        if not loaded then
            reason = data
        elseif not data then
            reason = err or "entity load failed"
        else
            -- 数据读上来了但租约没了：dbmgr 里的缓存必须回收，否则定时保存会带着失效租约重试
            reason = "lease expired during load"
            if not dbmgr.discard_clean(tc.db_name, tc.db_coll, entity_id, handle) then
                log.error("loaded entity cache retained after lease loss", "type", self.type_name, "id", entity_id)
            end
        end
        if distributed_lock.is_valid(handle) then
            distributed_lock.unlock(lock_key, handle)
        end
        if reason == "not found" then
            -- 类型没开 auto_create，ID 对应的文档不存在：多半是调用方传错了 ID
            log.warn("entity not found", "type", self.type_name, "id", entity_id)
            return false, reason
        end
        log.error("entity load failed", "type", self.type_name, "id", entity_id, "err", reason)
        return false, reason
    end

    entity = setmetatable({
        type_name = self.type_name,
        id = entity_id,
        data = data,
        entity_mgr = self,
        handle = handle,
        timers = {},
    }, entity_mt)
    self.entities[entity_id] = entity

    local initialized, init_err = xpcall(function()
        self:_init_modules(entity)
        local hooks_ok, hook_err = self:_call_modules_on_load(entity)
        assert(hooks_ok, hook_err)
        if self.handler.on_load then
            self.handler.on_load(entity)
        end
    end, debug.traceback)
    if not initialized or not distributed_lock.is_valid(handle) then
        local reason = init_err or "lease expired during initialization"
        log.error("entity initialization failed", "type", self.type_name, "id", entity_id, "err", reason)
        -- handler.on_load 没有跑完，对应的 handler.on_unload 不能执行；
        -- 但 on_load 已经成功的数据模块必须补跑 on_unload（见 _call_modules_on_unload）。
        -- 其余交给统一的卸载流程：租约还在就落库后解锁，租约没了就只丢弃干净缓存，
        -- 失败则保持 unloading 并重试
        entity.init_failed = true
        if not self:_unload_entity(entity) then
            log.error("entity retained after failed initialization", "type", self.type_name, "id", entity_id)
        end
        return false, reason
    end

    self:_start_unload_timer(entity)
    skynet.fork(function()
        local delivered, deliver_err = self:deliver_pending(entity_id)
        if not delivered then
            log.warn("pending reliable messages retained", "id", entity_id, "err", deliver_err)
        end
    end)
    log.info("entity loaded", "type", self.type_name, "id", entity_id, "fence", handle.fence)
    return true, entity
end

function M:ensure_loaded(entity_id)
    return self:_with_gate(entity_id, function()
        return self:_ensure_loaded(entity_id)
    end)
end

function M:try_ensure_loaded(entity_id)
    return self:ensure_loaded(entity_id)
end

function M:with_entity(entity_id, f)
    return self:_with_gate(entity_id, function()
        -- 第三个返回值是锁的当前持有节点：路由随集群成员搬家后，调用方要靠它
        -- 找到上一个 owner 去要实体
        local ok, entity, owner = self:_ensure_loaded(entity_id)
        if not ok then
            return false, entity, owner
        end
        local result = table.pack(pcall(f, entity))
        if entity.invalid or not entity_lease_ok(entity) then
            self:_on_lock_expired(entity_id, entity.handle)
            return false, "entity lease expired during handler"
        end
        if not result[1] then
            error(result[2], 0)
        end
        return true, table.unpack(result, 2, result.n)
    end)
end

function M:with_loaded_entity(entity_id, f)
    return self:_with_gate(entity_id, function()
        local entity = self:get(entity_id)
        if not entity then
            return false, M.NOT_LOADED
        end
        local result = table.pack(pcall(f, entity))
        if not entity_lease_ok(entity) then
            self:_on_lock_expired(entity_id, entity.handle)
            return false, "entity lease expired during handler"
        end
        if not result[1] then
            error(result[2], 0)
        end
        return true, table.unpack(result, 2, result.n)
    end)
end

-- 实体不存在（类型没开 auto_create、库里也没有这份文档）时，发给它的 pending 消息
-- 永远投不出去，又不会过期（TTL 索引只清已投递的）。整批移进死信队列，
-- 文档后来补上了还能用 dlq_replay 重放。调用方必须已经持有该实体的 gate
function M:_dead_letter_missing(entity_id)
    local rmsg = reliable_msg()
    local moved = 0
    while true do
        local msgs = rmsg.load_pending(self.type_name, entity_id, { max_count = rmsg.DEFAULT_PAGE_SIZE })
        for _, msg in ipairs(msgs) do
            local ok, err = rmsg.mark_dead(msg.msg_id, "entity not found")
            if not ok and err ~= "not_pending" then
                log.error("dead-letter for missing entity failed", "type", self.type_name, "id", entity_id, "err", err)
                return moved
            end
            moved = moved + 1
        end
        if #msgs < rmsg.DEFAULT_PAGE_SIZE then
            break
        end
    end
    if moved > 0 then
        log.error(
            "reliable messages for a missing entity moved to dead letter queue",
            "type",
            self.type_name,
            "id",
            entity_id,
            "count",
            moved
        )
    end
    return moved
end

-- 投递实体的 pending 可靠消息。返回 true，或 false, reason, owner：
-- 锁在别的节点手里时 reason 为 "lock held"，owner 是持锁节点，调用方可以把唤醒转给它。
-- opts.loaded_only 为真时只投给本地已加载的实体，不会为了投递去加载
function M:deliver_pending(entity_id, opts)
    -- 临时实体没有持久化消息队列：既不该为它去加载实体，也没有 pending 可投。
    -- 返回 false 而不是 true：调用方（router.reliable_send 的唤醒路径）会据此知道
    -- 消息并没有被处理，而不是以为已经投递成功、任由它永远留在 PENDING
    if self.type_config.persistent == false then
        return false, "ephemeral entity has no reliable queue"
    end
    local run = (opts and opts.loaded_only) and self.with_loaded_entity or self.with_entity
    local result = table.pack(pcall(run, self, entity_id, function(entity)
        return self:_deliver_pending_msgs(entity)
    end))
    local err, owner
    if not result[1] then
        err = result[2]
    elseif not result[2] then
        err, owner = result[3], result[4]
    elseif not result[3] then
        err = result[4]
    else
        local entity = self.entities[entity_id]
        if entity then
            self:_cancel_delivery_retry(entity)
        end
        return true
    end
    if err == "not found" then
        local ok, dead_err = pcall(self._with_gate, self, entity_id, function()
            -- 排队期间文档可能已经补上、实体已经加载，这时消息照常投递，不能移走
            if not self.entities[entity_id] then
                self:_dead_letter_missing(entity_id)
            end
        end)
        if not ok then
            log.error("dead-letter for missing entity failed", "type", self.type_name, "id", entity_id, "err", dead_err)
        end
        return false, err
    end
    local entity = self.entities[entity_id]
    if entity then
        self:_schedule_delivery_retry(entity)
    end
    return false, err, owner
end

-- 卸载中途失败：钩子可能已经拆掉了部分状态，实体必须继续拒绝请求，
-- 同时断开客户端并安排重试，直到卸载真正完成
function M:_abort_unload(entity, reason)
    self:_kick_client(entity, reason)
    self:_schedule_unload_retry(entity)
end

-- 失租时内存里还有没落库的改动。先把条目从回存轮上摘掉止血，再重新抢一次锁，
-- 拿到新 fence 之后由 dbmgr 判断这份改动还能不能接回去（见 dbmgr.recover）。
--
-- 不管走哪条路，实体最终都必须离开内存。以前这里一发现缓存是脏的就直接返回 false，
-- 实体会永远留在 entities 里：它不服务任何请求，却让后续 ensure_loaded 恒定失败，
-- 同时还挂在回存轮上每一轮刷一条写入被拒的日志，只能靠重启进程清掉。
function M:_recover_dirty(entity)
    local entity_id = entity.id
    local tc = self.type_config
    dbmgr.quarantine(tc.db_name, tc.db_coll, entity_id, entity.handle)

    local attempts = (entity.recovery_attempts or 0) + 1
    entity.recovery_attempts = attempts

    local function give_up(reason, detail)
        log.error(
            "dirty entity changes discarded",
            "type",
            self.type_name,
            "id",
            entity_id,
            "attempts",
            attempts,
            "reason",
            reason,
            "detail",
            detail
        )
        dbmgr.discard(tc.db_name, tc.db_coll, entity_id, entity.handle)
        self:_forget_entity(entity)
        return true
    end

    local lock_key = make_lock_key(self.type_name, entity_id)
    local locked, handle = distributed_lock.try_lock(lock_key, make_lock_value(), function(expired)
        self:_on_lock_expired(entity_id, expired)
    end)
    if not locked then
        if attempts >= DIRTY_RECOVERY_MAX_ATTEMPTS then
            return give_up("lock unreachable", handle)
        end
        log.warn("dirty entity recovery deferred", "type", self.type_name, "id", entity_id, "err", handle)
        self:_abort_unload(entity, "recovery lock unavailable")
        return false
    end

    local recovered, reason, detail =
        dbmgr.recover(tc.db_name, tc.db_coll, tc.id_field, entity_id, entity.handle, handle)
    if recovered then
        -- 改动已经在新租约下落库，dbmgr 缓存也清掉了，只剩释放这把新锁
        entity.handle = handle
        entity.invalid = nil
        entity.persisted = true
        log.info("dirty entity recovered", "type", self.type_name, "id", entity_id, "fence", handle.fence)
        return self:_release_lock(entity)
    end

    distributed_lock.unlock(lock_key, handle)
    if reason == "superseded" then
        -- 版本号对不上的细节 dbmgr 已经记过，这里只负责把实体清出内存
        log.error("dirty entity discarded after takeover", "type", self.type_name, "id", entity_id)
        self:_forget_entity(entity)
        return true
    end
    if reason == "cache replaced" then
        -- 缓存已经不归这个实体了，没有东西需要恢复
        self:_forget_entity(entity)
        return true
    end
    if attempts >= DIRTY_RECOVERY_MAX_ATTEMPTS then
        return give_up(reason, detail)
    end
    log.warn(
        "dirty entity recovery failed",
        "type",
        self.type_name,
        "id",
        entity_id,
        "reason",
        reason,
        "detail",
        detail
    )
    self:_abort_unload(entity, "recovery failed")
    return false
end

-- 数据已经落库、dbmgr 缓存也已清掉，只剩释放锁。失败时必须保留实体（handle 不能丢），
-- 否则没有人能再去释放这把锁。
--
-- `detach`（或实体上已标记的 release_detach）：计划内迁移。解除实体与连接的绑定，
-- 但**不断开客户端**——连接要继续为迁移后的新 owner 服务，踢了就变成一次掉线。
function M:_release_lock(entity, opts)
    local entity_id = entity.id
    local detach = (opts and opts.detach) or entity.release_detach
    if detach then
        self:_detach_session(entity)
    else
        self:_kick_client(entity, "entity unloaded")
    end
    if not distributed_lock.is_valid(entity.handle) then
        -- 租约已经失效，key 会随租约被 etcd 回收，这里再持有实体没有意义，
        -- 数据此前已在有效租约下落库，直接丢掉内存对象是安全的
        log.error("entity persisted but lease was lost before release", "type", self.type_name, "id", entity_id)
        self:_forget_entity(entity)
        return true
    end
    if not distributed_lock.unlock(make_lock_key(self.type_name, entity_id), entity.handle) then
        log.error("entity persisted but lock release was not confirmed", "type", self.type_name, "id", entity_id)
        self:_schedule_unload_retry(entity)
        return false
    end
    self:_forget_entity(entity)
    log.info("entity unloaded", "type", self.type_name, "id", entity_id)
    return true
end

-- 只解除实体侧的绑定，不通知网关断开连接：会话快照已经交给目标节点，
-- 这条连接接下来由目标节点接管
function M:_detach_session(entity)
    local conn = entity.session
    if not conn then
        return
    end
    local ok, err = pcall(function()
        require("skyext.entity.session").unbind(conn.key)
    end)
    if not ok then
        log.error(
            "failed to detach a session for migration",
            "type",
            self.type_name,
            "id",
            tostring(entity.id),
            "err",
            tostring(err)
        )
    end
end

-- 卸载实体本体，调用者必须已经持有该实体的 gate
function M:_unload_entity(entity)
    local entity_id = entity.id
    local tc = self.type_config
    self:_cancel_all_timers(entity)
    self:_cancel_unload_timer(entity)
    self:_cancel_delivery_retry(entity)
    self:_cancel_unload_retry(entity)
    entity.unloading = true

    if entity.persistent == false then
        -- 临时实体没有库、没有锁：钩子跑完直接丢。持久实体的落库/释放锁分支对它不成立
        if not entity.unload_hooks_run then
            local init_failed = entity.init_failed
            local hooks_ok, hooks_err = xpcall(function()
                if not init_failed and self.handler.on_unload and not entity.handler_unloaded then
                    self.handler.on_unload(entity)
                    entity.handler_unloaded = true
                end
                local modules_ok, module_err = self:_call_modules_on_unload(entity, init_failed)
                assert(modules_ok, module_err)
            end, debug.traceback)
            if not hooks_ok then
                log.error("ephemeral unload hook failed", "type", self.type_name, "id", entity_id, "err", hooks_err)
                self:_abort_unload(entity, "unload hook failed")
                return false
            end
            entity.unload_hooks_run = true
        end
        -- 持久路径在 _release_lock 里踢；临时实体没有那一步，必须自己踢，
        -- 否则会话会挂在已经销毁的实体上，后续下行全部落空
        self:_kick_client(entity, "ephemeral entity unloaded")
        self:_forget_entity(entity)
        log.info("ephemeral entity unloaded", "type", self.type_name, "id", entity_id)
        return true
    end

    if entity.persisted then
        -- 上一次卸载已经落库，只需要补上释放锁这一步，不能重复跑钩子和落库
        return self:_release_lock(entity)
    end

    if entity.invalid or not entity_lease_ok(entity) then
        entity.invalid = true
        self:_kick_client(entity, "lease lost")
        -- 干净的缓存直接丢掉就行，库里已经是最新的
        if dbmgr.discard_clean(tc.db_name, tc.db_coll, entity_id, entity.handle) then
            self:_forget_entity(entity)
            return true
        end
        return self:_recover_dirty(entity)
    end

    if not entity.unload_hooks_run then
        local init_failed = entity.init_failed
        local hooks_ok, hooks_err = xpcall(function()
            if not init_failed and self.handler.on_unload and not entity.handler_unloaded then
                self.handler.on_unload(entity)
                entity.handler_unloaded = true
            end
            local modules_ok, module_err = self:_call_modules_on_unload(entity, init_failed)
            assert(modules_ok, module_err)
        end, debug.traceback)
        if not hooks_ok then
            log.error("entity unload hook failed", "type", self.type_name, "id", entity_id, "err", hooks_err)
            self:_abort_unload(entity, "unload hook failed")
            return false
        end
        entity.unload_hooks_run = true
    end

    if not dbmgr.unload(tc.db_name, tc.db_coll, tc.id_field, entity_id) then
        log.error("entity save failed on unload", "type", self.type_name, "id", entity_id)
        self:_abort_unload(entity, "persistence failed")
        return false
    end
    entity.persisted = true
    return self:_release_lock(entity)
end

function M:unload(entity_id)
    return self:_with_gate(entity_id, function()
        local entity = self.entities[entity_id]
        if not entity then
            return true
        end
        return self:_unload_entity(entity)
    end)
end

function M:count()
    local n = 0
    for _ in pairs(self.entities) do
        n = n + 1
    end
    return n
end

-- ---------------------------------------------------------------------------
-- 计划内迁移（P15）：枚举 / 冻结 / 释放
--
-- 这三步只做"实体侧"的动作，跨节点的事（目标选择、快照传输、网关重指向）由游戏层
-- 的迁移适配器负责。契约见 docs/design/migration_v1.md。
-- ---------------------------------------------------------------------------

-- 关键操作未决的实体禁止无感移交：它可能有一个 PREPARE 过、COMMIT 结果未知的意图，
-- 换 owner 之前必须走多数派 Fence 恢复。字段名只在 critical 里定义一次
local g_intent_field
local function intent_field()
    if not g_intent_field then
        g_intent_field = require("skyext.critical").INTENT_FIELD
    end
    return g_intent_field
end

-- 枚举本进程已加载的实体，以及迁移分流需要的状态。只读、不 yield、不改任何字段。
-- `busy` 只表示"已经在迁移或正在卸载"：普通在途请求由 QUIESCING 阶段靠实体队列排空，
-- 不需要在这里猜，猜错只会让本该成功的迁移降级。
function M:list_loaded()
    local list = {}
    for id, entity in pairs(self.entities) do
        local io_ = entity.session_io
        local conn = entity.session
        list[#list + 1] = {
            id = id,
            conn_id = conn and conn.key or nil,
            owner_epoch = io_ and io_.owner_epoch or nil,
            session_epoch = io_ and io_.session_epoch or nil,
            unresumable = io_ and io_.unresumable == true or false,
            critical_unknown = self:_has_pending_intent(entity),
            busy = entity.migrating == true or entity.unloading == true,
            persistent = entity.persistent ~= false,
        }
    end
    table.sort(list, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)
    return list
end

function M:_has_pending_intent(entity)
    local tc = self.type_config
    if not tc or not tc.db_name or not tc.db_coll then
        return false
    end
    local critical = dbmgr.cached_critical(tc.db_name, tc.db_coll, entity.id)
    return critical ~= nil and critical[intent_field()] ~= nil
end

-- 冻结：停止这个实体的上行执行与下行追加，准备导出快照。
-- 必须在实体队列里执行——排在它前面的请求先跑完（队列排空），排在它后面的上行
-- 由 entity_agent 在入口处丢弃，不会落到一个已经交出所有权的实体上。
function M:quiesce(entity_id)
    return self:_with_gate(entity_id, function()
        local entity = self.entities[entity_id]
        if not entity then
            return false, "not loaded"
        end
        if entity.unloading then
            return false, "unloading"
        end
        if entity.migrating then
            -- 重复冻结是幂等的：适配器重试不该被自己上一次的调用挡住
            return true
        end
        if entity.persistent == false then
            return false, "ephemeral"
        end
        if not entity.session_io then
            return false, "no session"
        end
        if not entity_lease_ok(entity) then
            return false, "lease lost"
        end
        entity.migrating = true
        -- 这里**不**冻结下行：QUIESCING 到 TRANSFER 之间业务推送（定时器、邮件）还会
        -- 产生下行，它们必须能进 out_buf 才会被快照带走。真正的冻结点是 session_export
        -- ——它在编码前把 io_.migrating 置上，之后追加的包才会让目标的 sent 落后
        -- 迁移期间不能让空闲计时器把实体卸掉：那会在快照送出后释放锁
        self:_cancel_unload_timer(entity)
        log.info("entity quiesced for migration", "type", self.type_name, "id", entity_id)
        return true
    end)
end

-- 撤销冻结（迁移失败、实体留在本节点继续服务）。快照一旦送出就不能撤销：
-- 放开源端只会让 sent/out_buf 领先目标，客户端 ACK 越界后整个会话只能重登
function M:unquiesce(entity_id, reason)
    return self:_with_gate(entity_id, function()
        local entity = self.entities[entity_id]
        if not entity or not entity.migrating then
            return true
        end
        -- 已经落库或正在卸载的实体不能"解冻后继续服务"：数据在库里、dbmgr 缓存已清，
        -- 继续接请求只会在下一次回存时报 not cached。释放失败（锁没解开）就走这条路径，
        -- 它已经安排了卸载重试，正确结果是继续卸载而不是回到服务状态
        if entity.persisted or entity.unloading then
            return false, "entity is being unloaded"
        end
        if entity.migration_exported then
            return false, "snapshot already exported"
        end
        entity.migrating = nil
        if entity.session_io then
            -- 正常情况下 io_.migrating 由 session_export 置上；走到这里说明还没导出，
            -- 清一次是防御（例如上一次迁移中途失败留下的标记）
            entity.session_io.migrating = nil
        end
        if not entity.session then
            -- 断线中的实体靠 unload_delay 计时器回收，撤销冻结要把这个窗口还回去
            self:_start_unload_timer(entity)
        end
        log.info("entity migration aborted", "type", self.type_name, "id", entity_id, "reason", tostring(reason))
        return true
    end)
end

-- 释放：落库、释放锁、解除实体与连接的绑定，但**不踢客户端、不销毁会话**。
-- 没有导出过快照就拒绝：那会把客户端留在一条没有 owner 的连接上，比直接卸载更糟。
-- 失败时保留实体并安排重试（和普通卸载一致），重试会带着 release_detach 继续。
function M:release_for_migration(entity_id)
    return self:_with_gate(entity_id, function()
        local entity = self.entities[entity_id]
        if not entity then
            return false, "not loaded"
        end
        if not entity.migrating then
            return false, "not quiesced"
        end
        if not entity.migration_exported then
            return false, "snapshot not exported"
        end
        entity.release_detach = true
        if entity.persisted then
            return self:_release_lock(entity, { detach = true })
        end
        return self:_unload_entity(entity)
    end)
end

-- 停服：从此不再加载新实体，并把已加载的实体全部卸载（落库、释放锁、断开客户端）。
-- 可以重复调用，卸载失败的实体留给下一次。返回还留在内存里的实体数
function M:unload_all()
    self.closing = true
    local ids = {}
    for id in pairs(self.entities) do
        ids[#ids + 1] = id
    end
    local next_index = 0
    local running = 0
    local waiter = {}
    local function worker()
        while true do
            next_index = next_index + 1
            local id = ids[next_index]
            if not id then
                break
            end
            local ok, err = pcall(self.unload, self, id)
            if not ok then
                log.error("entity unload failed during shutdown", "type", self.type_name, "id", id, "err", err)
            end
        end
        running = running - 1
        if running == 0 then
            skynet.wakeup(waiter)
        end
    end
    local workers = math.min(SHUTDOWN_CONCURRENCY, #ids)
    if workers > 0 then
        running = workers
        for _ = 1, workers do
            skynet.fork(worker)
        end
        skynet.wait(waiter)
    end
    return self:count()
end

function M:touch(entity_id)
    local entity = self.entities[entity_id]
    if entity and not entity.invalid and not entity.unloading and entity_lease_ok(entity) and not entity.session then
        self:_start_unload_timer(entity)
    end
end

function M:get(entity_id)
    local entity = self.entities[entity_id]
    if entity and not entity.invalid and not entity.unloading and entity_lease_ok(entity) then
        return entity
    end
end

return M
