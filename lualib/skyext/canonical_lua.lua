-- 把已解码的 Lua 请求表编码成确定性字节流，供会话层比对 req_id 的参数摘要。
--
-- 为什么不用 Sproto schema 反射：core.default 能给出字段名、标量粗类型和 array 标记，
-- 但拿不到字段 tag 顺序、map 的 key 类型、map 与 struct 的区分。这里改为对解码后的表
-- 做类型化递归编码：不依赖 tag，不因 schema 演进改变已有指纹，也不改 skynet/ 与
-- 3rd/sprotodump。
--
-- 纯 Lua、无 IO、无 yield；失败一律 fail-closed，不降级成"不比对指纹"。
-- 契约见 docs/design/request_fingerprint_v1.md。
local M = {}

-- 编码域前缀，参与指纹输入，与 fingerprint_version 一起构成摘要域
M.ENCODING_DOMAIN = "F1"
M.MAX_DEPTH = 32
-- 节点计数：表本身、每个键、每个值各计 1，因此 16384 等价于最多 8191 对键值。
-- 上限在收集键的阶段增量判断，避免宽表先排序再拒绝。
M.MAX_NODES = 16384
M.MAX_BYTES = 256 * 1024
M.MAX_PROTOCOL_LEN = 128

-- 键的类型序：boolean < number < string
local function type_rank(v)
    local tv = type(v)
    if tv == "boolean" then
        return 0
    end
    if tv == "number" then
        return 1
    end
    if tv == "string" then
        return 2
    end
    return nil
end

-- 不变量：Lua 表里不存在相等的两个键（2.0 与 2 归一为同一个键），且 int/float 的
-- '<' 在 Lua 5.4+ 是精确比较，所以这是一个严格全序，table.sort 的不稳定性无从触发。
local function key_less(a, b)
    if a.rank ~= b.rank then
        return a.rank < b.rank
    end
    if a.rank == 0 then
        -- boolean 不能用 '<' 比较
        return a.value == false and b.value == true
    end
    return a.value < b.value
end

local function emit_raw(st, s)
    st.len = st.len + #s
    if st.len > M.MAX_BYTES then
        return nil, "output exceeds bytes limit"
    end
    st.out[#st.out + 1] = s
    return true
end

-- 长度前缀帧。先按长度判断上限，再分段追加，避免对大的 payload 先做一次
-- "#payload .. ':' .. payload" 的整串拷贝。
local function emit_framed(st, tag, payload)
    local digits = tostring(#payload)
    st.len = st.len + #tag + #digits + 1 + #payload
    if st.len > M.MAX_BYTES then
        return nil, "output exceeds bytes limit"
    end
    st.out[#st.out + 1] = tag
    st.out[#st.out + 1] = digits
    st.out[#st.out + 1] = ":"
    st.out[#st.out + 1] = payload
    return true
end

local encode_value

local function encode_table(v, st, depth)
    if getmetatable(v) ~= nil then
        return nil, "table with metatable is not supported"
    end
    if depth > M.MAX_DEPTH then
        return nil, "depth limit exceeded"
    end
    if st.path[v] then
        return nil, "cycle detected"
    end
    st.path[v] = true

    local keys = {}
    for k in pairs(v) do
        local rank = type_rank(k)
        if rank == nil then
            st.path[v] = nil
            return nil, "unsupported key type: " .. type(k)
        end
        keys[#keys + 1] = { value = k, rank = rank }
        -- 每对键值还要 2 个节点；表本身已由调用方计入 st.nodes。
        -- 在这里判而不是编码时判，宽表不会先排完序再被拒绝。
        if st.nodes + 2 * #keys > M.MAX_NODES then
            st.path[v] = nil
            return nil, "node limit exceeded"
        end
    end
    table.sort(keys, key_less)

    -- count 是"项数 + 冒号"，本身就是可解析的分隔，不再套长度帧
    local ok, err = emit_raw(st, "T" .. #keys .. ":")
    if not ok then
        st.path[v] = nil
        return nil, err
    end
    for _, entry in ipairs(keys) do
        local k = entry.value
        ok, err = encode_value(k, st, depth + 1)
        if ok then
            ok, err = encode_value(v[k], st, depth + 1)
        end
        if not ok then
            st.path[v] = nil
            return nil, err
        end
    end

    st.path[v] = nil
    return true
end

encode_value = function(v, st, depth)
    st.nodes = st.nodes + 1
    if st.nodes > M.MAX_NODES then
        return nil, "node limit exceeded"
    end

    local tv = type(v)
    if tv == "nil" then
        -- 只有顶层会走到这里：table 的值不可能是 nil（pairs 不返回）
        return emit_raw(st, "N")
    elseif tv == "boolean" then
        return emit_raw(st, v and "B1" or "B0")
    elseif tv == "number" then
        if math.type(v) == "integer" then
            return emit_framed(st, "I", tostring(v))
        end
        if v ~= v or v == math.huge or v == -math.huge then
            return nil, "non-finite number"
        end
        local as_int = math.tointeger(v)
        if as_int ~= nil then
            -- 2.0 与 2、-0.0 与 0 归一，避免同一语义出现两个指纹
            return emit_framed(st, "I", tostring(as_int))
        end
        return emit_raw(st, "F" .. string.pack(">d", v))
    elseif tv == "string" then
        return emit_framed(st, "S", v)
    elseif tv == "table" then
        return encode_table(v, st, depth)
    end
    return nil, "unsupported type: " .. tv
end

function M.encode(value)
    local st = { out = {}, len = 0, nodes = 0, path = {} }
    local ok, err = encode_value(value, st, 1)
    if not ok then
        return nil, err
    end
    return table.concat(st.out)
end

-- 指纹输入 = 编码域 + 协议名帧 + 请求编码。协议名参与摘要域，避免不同协议
-- 恰好解出同形状的表时被判成同一个请求。
function M.encode_request(protocol_name, value)
    if type(protocol_name) ~= "string" then
        return nil, "protocol name must be a string"
    end
    if #protocol_name == 0 then
        return nil, "protocol name must not be empty"
    end
    if #protocol_name > M.MAX_PROTOCOL_LEN then
        return nil, "protocol name is too long"
    end
    -- 协议名来自 proto.name（字母、数字、点、下划线、连字符）；出现别的字节一定是上游拼错了
    if not protocol_name:match("^[%w%._%-]+$") then
        return nil, "protocol name has invalid characters"
    end

    local body, err = M.encode(value)
    if not body then
        return nil, err
    end
    local out = M.ENCODING_DOMAIN .. #protocol_name .. ":" .. protocol_name .. body
    if #out > M.MAX_BYTES then
        return nil, "output exceeds bytes limit"
    end
    return out
end

return M
