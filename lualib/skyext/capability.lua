-- 内部经济操作的进程内 capability。
--
-- 目的：`critical.execute_internal` 不能靠调用者自报的 `source="payment"` 字符串鉴权。
-- 只有受信任的分发边界（entity_agent 内的可靠消息投递、支付适配层、Saga 步骤执行器）
-- 能持有一个 issuer，并在完成持久化来源核验后签发 cap；`execute_internal` 只认
-- 这个进程内对象身份。
--
-- 边界说明（必须写进使用文档）：同一 Skynet VM 里能执行任意恶意 Lua 代码的攻击者
-- 不是本模块的防御对象。cap 是"可信调用链证明"，不是进程内安全沙箱。
--
-- 三个签发点都必须在 entity_agent 进程内：
--   1. 可靠消息 `_deliver_one`：从持久化 entity_msg/Outbox 记录核验后签发；
--   2. 支付回调：HTTP 服务只验签并落 charge_order，然后 router.call 到 entity_agent，
--      由 entity_agent 读持久化订单记录后签发；cap 不能跨进程传；
--   3. Saga：协调者只经可靠消息投递步骤，由 entity_agent 读持久化步骤记录后签发。
--
-- 关键约束：
--   * cap 是**空表 + 私有 metatable**，字段全在私有注册表里；复制/序列化/重设
--     metatable 都拿不到同一身份，`verify` 一律拒绝。
--   * 当前 cap 存在 **per-coroutine** 上下文里，不是模块级变量：实体队列虽然串行，
--     其它协程并发调用 `execute_internal` 时模块级 current_cap 会串号。
--   * 单次分发：`consume` 校验后立即吊销；异步延后必须重新核验来源并重新签发。
local M = {}

M.ERR = {
    INVALID = "invalid_capability",
    REVOKED = "revoked_capability",
    EXPIRED = "expired_capability",
    BINDING_MISMATCH = "capability_binding_mismatch",
    ISSUER = "untrusted_issuer",
}

local CAP_MT = {}
local ISSUER_MT = {}

-- 弱键：cap 被业务代码丢弃后注册表不阻止回收，也不会留下可枚举的伪造入口
local CAPS = setmetatable({}, { __mode = "k" })
local ISSUERS = setmetatable({}, { __mode = "k" })
-- coroutine -> cap；同样弱键，协程结束自动消失
local CONTEXT = setmetatable({}, { __mode = "k" })

local DEFAULT_TTL = 30

-- 只有这三条受信任分发链（加支付适配层）能持有 issuer。命名空间本身不是鉴权材料，
-- 但把可签发来源收口到固定集合，可以挡住"随便造一个 issuer 再自签 cap"的路径。
-- 同 VM 内可任意执行 Lua 的攻击者不是本模块的防御边界（见文件头注释）。
local ALLOWED_NAMESPACES = {
    outbox = true,
    charge_order = true,
    payment = true,
    saga = true,
}

function M.is_allowed_namespace(namespace)
    return type(namespace) == "string" and ALLOWED_NAMESPACES[namespace] == true
end

local function check_text(value, name)
    if type(value) ~= "string" or #value == 0 or #value > 256 then
        return nil, name .. " must be a non-empty string"
    end
    return value
end

-- 只给受信任模块调用。issuer 本身也不暴露字段，防止被复制后重新注册
function M.new_issuer(namespace, allowed_op_types)
    local ns, err = check_text(namespace, "namespace")
    if not ns then
        return nil, err
    end
    if not M.is_allowed_namespace(ns) then
        return nil, "namespace is not a trusted dispatch entry"
    end
    -- 空白名单原本等价于"放行任意 op_type"，等于把业务白名单交给了签发调用方。
    -- 到这里必须给出至少一个明确允许的操作类型
    if type(allowed_op_types) ~= "table" or #allowed_op_types == 0 then
        return nil, "allowed_op_types must be a non-empty list"
    end
    local issuer = setmetatable({}, ISSUER_MT)
    local ops = {}
    for _, op in ipairs(allowed_op_types) do
        local v = check_text(op, "op_type")
        if not v then
            return nil, "invalid allowed op_type"
        end
        ops[v] = true
    end
    if next(ops) == nil then
        return nil, "allowed_op_types must be a non-empty list"
    end
    ISSUERS[issuer] = { namespace = ns, op_types = ops }
    return issuer
end

local function issuer_record(issuer)
    if type(issuer) ~= "table" or getmetatable(issuer) ~= ISSUER_MT then
        return nil
    end
    return ISSUERS[issuer]
end

-- fields:
--   rid, service_op_id, op_type, payload_hash, source_id 必填
--   ttl（秒，默认 30）、now（测试注入，默认 os.time）
-- 返回不透明 cap；调用方**不能**读取 cap.rid 之类字段——那正是可伪造的入口
function M.issue(issuer, fields)
    local irec = issuer_record(issuer)
    if not irec then
        return nil, M.ERR.ISSUER
    end
    if type(fields) ~= "table" then
        return nil, "fields must be a table"
    end
    if fields.rid == nil then
        return nil, "rid is required"
    end
    local op_type, err = check_text(fields.op_type, "op_type")
    if not op_type then
        return nil, err
    end
    -- 双保险：即便 issuer 记录被绕过构造，空白名单也不再表示"全部允许"
    if next(irec.op_types) == nil or not irec.op_types[op_type] then
        return nil, "op_type is not allowed for this issuer"
    end
    local service_op_id, serr = check_text(fields.service_op_id, "service_op_id")
    if not service_op_id then
        return nil, serr
    end
    local payload_hash, herr = check_text(fields.payload_hash, "payload_hash")
    if not payload_hash then
        return nil, herr
    end
    local source_id, src_err = check_text(fields.source_id, "source_id")
    if not source_id then
        return nil, src_err
    end
    local now = fields.now or os.time()
    local ttl = fields.ttl or DEFAULT_TTL
    if math.type(ttl) ~= "integer" or ttl <= 0 then
        return nil, "ttl must be a positive integer"
    end

    local cap = setmetatable({}, CAP_MT)
    CAPS[cap] = {
        rid = fields.rid,
        namespace = irec.namespace,
        source_id = source_id,
        service_op_id = service_op_id,
        op_type = op_type,
        payload_hash = payload_hash,
        issued_at = now,
        expires_at = now + ttl,
        revoked = false,
    }
    return cap
end

-- expected 里的字段全部参与比对；缺省字段不比对。
-- 返回 true 或 false, reason；reason 取 M.ERR
function M.verify(cap, expected, now)
    if type(cap) ~= "table" or getmetatable(cap) ~= CAP_MT then
        return false, M.ERR.INVALID
    end
    local rec = CAPS[cap]
    if not rec then
        return false, M.ERR.INVALID
    end
    if rec.revoked then
        return false, M.ERR.REVOKED
    end
    now = now or os.time()
    if now >= rec.expires_at then
        return false, M.ERR.EXPIRED
    end
    expected = expected or {}
    if expected.rid ~= nil and expected.rid ~= rec.rid then
        return false, M.ERR.BINDING_MISMATCH
    end
    if expected.service_op_id ~= nil and expected.service_op_id ~= rec.service_op_id then
        return false, M.ERR.BINDING_MISMATCH
    end
    if expected.op_type ~= nil and expected.op_type ~= rec.op_type then
        return false, M.ERR.BINDING_MISMATCH
    end
    if expected.payload_hash ~= nil and expected.payload_hash ~= rec.payload_hash then
        return false, M.ERR.BINDING_MISMATCH
    end
    if expected.source_id ~= nil and expected.source_id ~= rec.source_id then
        return false, M.ERR.BINDING_MISMATCH
    end
    if expected.namespace ~= nil and expected.namespace ~= rec.namespace then
        return false, M.ERR.BINDING_MISMATCH
    end
    return true
end

-- 校验后立即吊销：一次分发只能进一次 PREPARE。重试要重新核验来源并重新签发
function M.consume(cap, expected, now)
    local ok, err = M.verify(cap, expected, now)
    if not ok then
        return false, err
    end
    CAPS[cap].revoked = true
    return true
end

function M.revoke(cap)
    if type(cap) == "table" and getmetatable(cap) == CAP_MT and CAPS[cap] then
        CAPS[cap].revoked = true
        return true
    end
    return false
end

function M.is_cap(cap)
    return type(cap) == "table" and getmetatable(cap) == CAP_MT and CAPS[cap] ~= nil
end

-- 供提交内核核对签发来源。只认注册表里的真实 cap，伪造 table 一律返回 nil
function M.namespace_of(cap)
    if not M.is_cap(cap) then
        return nil
    end
    return CAPS[cap].namespace
end

-- 当前协程的受控调用上下文。**不要**改成模块级 current_cap：
-- 实体队列串行只保证队列内不并发，别的协程仍可能同时调用 execute_internal
function M.run_with(cap, fn, ...)
    if not M.is_cap(cap) then
        return nil, M.ERR.INVALID
    end
    local co = coroutine.running()
    local previous = CONTEXT[co]
    CONTEXT[co] = cap
    local results = table.pack(pcall(fn, ...))
    CONTEXT[co] = previous
    if not results[1] then
        error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
end

function M.current()
    local co = coroutine.running()
    return co and CONTEXT[co] or nil
end

return M
