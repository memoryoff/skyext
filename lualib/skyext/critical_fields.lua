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

M.FIELDS = { M.INTENT, M.OPS, M.OUTBOX, M.OUTBOX_PENDING }

local WHITELIST = {}
for _, name in ipairs(M.FIELDS) do
    WHITELIST[name] = true
end

M.MAX_DEPTH = 16
M.MAX_NODES = 4096
M.MAX_BYTES = 512 * 1024
M.MAX_KEY_LEN = 128

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
    if type(value.param_hash) ~= "string" or #value.param_hash ~= 32 then
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
    if critical[M.OUTBOX_PENDING] ~= nil then
        local pending = critical[M.OUTBOX_PENDING]
        -- 只接受非负整数：写成浮点或字符串会让索引查询与计数减法都失真
        if math.type(pending) ~= "integer" or pending < 0 then
            return nil, M.OUTBOX_PENDING .. " must be a non-negative integer"
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
