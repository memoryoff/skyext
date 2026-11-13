-- 角色文档里的关键写入保留字段：在 `orm.decode` **之前**从原始 BSON 后像里提取。
--
-- 为什么必须在 decode 之前：`orm.decode` 会调用 `align` 原地删掉 schema 里没有的字段，
-- 并把它们记进 `dropped`。关键字段既不能进 ORM 的 dirty/save 路径，也不能被当作
-- "旧版本残留字段"静默丢弃——丢了就等于丢了未决意图和已提交操作账本。
--
-- 这里的输出分三份：
--   clean     可以交给 `orm.decode` 的表（关键字段已移除，其余字段原样共享引用）
--   critical  深拷贝出来的关键元数据，交给 dbmgr 的 `cache.critical` 独立管理
--   unknown   形如 `_critical_*` 但不在白名单里的字段。**出现即拒绝加载为可写实体**，
--             否则新版本写入的元数据会被旧代码当成垃圾删掉
--
-- 纯 Lua、无 IO、无 yield；任何结构/大小/类型不合规一律 fail-closed。
local M = {}

M.INTENT = "_critical_intent_v1"
M.OPS = "_critical_ops_v1"
M.OUTBOX = "_critical_outbox_v1"
-- 待发事件的**可索引标志**。它必须和白名单里的结构字段一起提取，否则会命中
-- "unknown critical field" 分支，让写了 Outbox 的角色直接加载失败
M.OUTBOX_PENDING = "_critical_outbox_pending_count"
-- 热账本里最老一条操作的 `at`：归档扫描的索引字段。
-- 没有它，归档只能全表扫描，或者根本不扫
M.OPS_OLDEST = "_critical_ops_oldest_at"
-- 因果序号水位：与事件同一次 CAS 分配，保证同秒事件能排出确定顺序。
-- 和 OUTBOX_PENDING 同理，漏进白名单就是"写过 Outbox 的角色加载失败"，
-- 所以任何新增的 `_critical_*` 写入点都必须同步登记到这里
M.OUTBOX_SEQ = "_critical_outbox_seq"
-- 终态清理时刻：有终态事件、且到了可以删的时间点。worker 靠它找到
-- "回执丢了、pending_count 已归零"的角色——只按 pending>0 扫的话，
-- 这些角色的终态事件永远没人清，只能等容量腾挪
M.OUTBOX_CLEANUP = "_critical_outbox_cleanup_at"

M.FIELDS = {
    M.INTENT,
    M.OPS,
    M.OUTBOX,
    M.OUTBOX_PENDING,
    M.OPS_OLDEST,
    M.OUTBOX_SEQ,
    M.OUTBOX_CLEANUP,
}

-- Outbox 的保留期口径也放在这里：`critical` 与 `outbox` 必须用同一个数字，
-- 而且两边都会被测试桩替换，只有这个模块是"永远真实"的契约来源。
-- 曾经 outbox 自己写一份字面量、critical 写另一份，容量腾挪路径就悄悄把
-- DELIVERED 变成了 0 秒即删。
M.OUTBOX_DELIVERED_RETENTION = 7 * 24 * 3600
M.OUTBOX_ENQUEUED_RETENTION = 7 * 24 * 3600
-- FAILED（投递彻底失败）的最小保留期：与终态保留期一致。
-- 它是"资产已扣、可靠消息从未落库"的唯一记录，容量压力下既不能沿用
-- delivered_retention=0 的口径，也不该只留 1 小时就抹掉——7 天是人工发现
-- 并补偿所需的窗口。过了窗口仍允许腾，否则一批陈年 FAILED 会把角色锁死。
M.OUTBOX_FAILED_MIN_RETENTION = 7 * 24 * 3600

local WHITELIST = {}
for _, name in ipairs(M.FIELDS) do
    WHITELIST[name] = true
end

M.MAX_DEPTH = 16
M.MAX_NODES = 4096
M.MAX_BYTES = 512 * 1024
M.MAX_KEY_LEN = 128

-- 参数摘要是 HMAC-SHA256 的**十六进制字符串**：32 字节摘要 -> 64 个小写 hex 字符。
-- fingerprint.HASH_BYTES = 32 是字节数，不是字符数。这个值必须与
-- skyext.critical.param_hash_of 的输出严格一致：两边各写一个字面量曾经让任何
-- 残留 PREPARED 的角色文档在 dbmgr.load 时被当成损坏数据拒绝，恢复闭环直接瘫痪。
M.PARAM_HASH_HEX_LEN = 64

local function is_param_hash(value)
    return type(value) == "string" and #value == M.PARAM_HASH_HEX_LEN and value:match("^[0-9a-f]+$") ~= nil
end

M.is_param_hash = is_param_hash

local function is_safe_key(k)
    if type(k) ~= "string" then
        return false
    end
    if #k == 0 or #k > M.MAX_KEY_LEN then
        return false
    end
    if k:sub(1, 1) == "$" then
        return false
    end
    if k:find(".", 1, true) or k:find("\0", 1, true) then
        return false
    end
    return true
end

M.is_safe_key = is_safe_key

local function deep_copy(value, st, depth)
    if depth > M.MAX_DEPTH then
        return nil, "depth limit exceeded"
    end
    st.nodes = st.nodes + 1
    if st.nodes > M.MAX_NODES then
        return nil, "node limit exceeded"
    end

    local tv = type(value)
    if tv == "string" then
        st.bytes = st.bytes + #value
        if st.bytes > M.MAX_BYTES then
            return nil, "size limit exceeded"
        end
        return value
    end
    if tv == "number" or tv == "boolean" then
        return value
    end
    if tv ~= "table" then
        -- BSON 的 ObjectId/int64 等 userdata 不接受：关键元数据只允许自描述的普通值，
        -- 否则跨版本、跨驱动的编码差异会变成不可比对的账本
        return nil, "unsupported type: " .. tv
    end
    if getmetatable(value) ~= nil then
        return nil, "table with metatable is not supported"
    end
    if st.seen[value] then
        return nil, "cycle detected"
    end
    st.seen[value] = true

    local out = {}
    for k, v in pairs(value) do
        local kt = type(k)
        if kt == "string" then
            if not is_safe_key(k) then
                st.seen[value] = nil
                return nil, "unsafe key: " .. k
            end
        elseif kt ~= "number" then
            st.seen[value] = nil
            return nil, "unsupported key type: " .. kt
        end
        local ck, kerr = deep_copy(k, st, depth + 1)
        if ck == nil then
            st.seen[value] = nil
            return nil, kerr
        end
        local cv, verr = deep_copy(v, st, depth + 1)
        if cv == nil then
            st.seen[value] = nil
            return nil, verr
        end
        out[ck] = cv
    end

    st.seen[value] = nil
    return out
end

-- 深拷贝并限制深度/节点/字节数；错误信息只说明类别，不回显业务数据。
-- 传入 st 时多个字段共享同一份预算：三个保留字段合计不能超过单文档上限。
function M.deep_copy(value, st)
    return deep_copy(value, st or { nodes = 0, bytes = 0, seen = {} }, 1)
end

local function check_entry_table(name, value)
    if type(value) ~= "table" then
        return nil, name .. " must be a table"
    end
    for k, v in pairs(value) do
        if not is_safe_key(k) then
            return nil, name .. " has an unsafe key"
        end
        if type(v) ~= "table" then
            return nil, name .. " entry must be a table"
        end
        if type(v.status) ~= "string" then
            return nil, name .. " entry is missing status"
        end
        -- 热账本条目带了摘要就必须和意图用同一种格式，否则"同 op 换参数"的比对
        -- 会拿两种长度的字符串恒不相等，静默变成 OP_CONFLICT 或漏检
        if name == M.OPS and v.param_hash ~= nil and not is_param_hash(v.param_hash) then
            return nil, name .. " has an invalid param_hash"
        end
    end
    return true
end

local function validate_intent(value)
    if type(value) ~= "table" then
        return nil, M.INTENT .. " must be a table"
    end
    if type(value.op_id) ~= "string" or not is_safe_key(value.op_id) then
        return nil, M.INTENT .. " has an invalid op_id"
    end
    if type(value.op_type) ~= "string" or #value.op_type == 0 then
        return nil, M.INTENT .. " has an invalid op_type"
    end
    if not is_param_hash(value.param_hash) then
        return nil, M.INTENT .. " has an invalid param_hash"
    end
    if value.owner_fence ~= nil and type(value.owner_fence) ~= "string" and type(value.owner_fence) ~= "number" then
        return nil, M.INTENT .. " has an invalid owner_fence"
    end
    if value.state ~= "PREPARED" then
        return nil, M.INTENT .. " has an unknown state"
    end
    return true
end

-- 从 BSON 解码后的原始文档里提取保留字段。
-- 返回 clean, critical 或 nil, err, unknown。输入表不被修改。
function M.extract(raw)
    if type(raw) ~= "table" then
        return nil, "document must be a table"
    end

    local clean = {}
    local critical = {}
    local unknown = {}
    -- 三个字段共享同一份预算，避免各自 512 KiB 把单文档上限放大成 1.5 MiB
    local budget = { nodes = 0, bytes = 0, seen = {} }

    for k, v in pairs(raw) do
        if type(k) == "string" and k:sub(1, #"_critical_") == "_critical_" then
            if not WHITELIST[k] then
                unknown[#unknown + 1] = k
            else
                local copy, err = deep_copy(v, budget, 1)
                if copy == nil then
                    return nil, k .. ": " .. err
                end
                critical[k] = copy
            end
        else
            clean[k] = v
        end
    end

    if #unknown > 0 then
        table.sort(unknown)
        -- 未知关键字段可能是更新版本写入的：既不能交给 ORM 删掉，也不能猜测语义
        return nil, "unknown critical field: " .. unknown[1], unknown
    end

    if critical[M.INTENT] ~= nil then
        local ok, err = validate_intent(critical[M.INTENT])
        if not ok then
            return nil, err
        end
    end
    if critical[M.OPS] ~= nil then
        local ok, err = check_entry_table(M.OPS, critical[M.OPS])
        if not ok then
            return nil, err
        end
    end
    if critical[M.OUTBOX] ~= nil then
        local ok, err = check_entry_table(M.OUTBOX, critical[M.OUTBOX])
        if not ok then
            return nil, err
        end
    end
    if critical[M.OPS_OLDEST] ~= nil then
        local oldest = critical[M.OPS_OLDEST]
        if math.type(oldest) ~= "integer" or oldest < 0 then
            return nil, M.OPS_OLDEST .. " must be a non-negative integer"
        end
    end
    if critical[M.OUTBOX_PENDING] ~= nil then
        local pending = critical[M.OUTBOX_PENDING]
        -- 只接受非负整数：写成浮点或字符串会让索引查询与计数减法都失真
        if math.type(pending) ~= "integer" or pending < 0 then
            return nil, M.OUTBOX_PENDING .. " must be a non-negative integer"
        end
    end
    if critical[M.OUTBOX_SEQ] ~= nil then
        local seq = critical[M.OUTBOX_SEQ]
        -- 序号水位必须是单调递增的整数：浮点会让 `seq_base + 1` 产生小数，
        -- 而后续事件排序会因此失去全序
        if math.type(seq) ~= "integer" or seq < 0 then
            return nil, M.OUTBOX_SEQ .. " must be a non-negative integer"
        end
    end
    if critical[M.OUTBOX_CLEANUP] ~= nil then
        local due = critical[M.OUTBOX_CLEANUP]
        -- 必须是非负整数：它直接进 Mongo 的 `$lte` 查询，浮点或字符串会让
        -- 索引匹配不到，清理又退回"永远没人扫"
        if math.type(due) ~= "integer" or due < 0 then
            return nil, M.OUTBOX_CLEANUP .. " must be a non-negative integer"
        end
    end

    return clean, critical
end

-- 供断言/日志使用的稳定字段名列表，不返回内容
function M.names(critical)
    local names = {}
    for _, name in ipairs(M.FIELDS) do
        if critical and critical[name] ~= nil then
            names[#names + 1] = name
        end
    end
    return names
end

return M
