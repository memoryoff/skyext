-- 服务器内部连接标识。跨网关、跨节点的 fd 会重复，关闭后还会被复用，所以登录、
-- 实体、RPC 全链路不能用裸 fd 作身份；网关生成 conn_id，其他服务只解析和比较。
--
-- 纯 Lua、无 IO、无 yield、无全局可变状态，可在 accept 回调和实体队列内安全调用。
-- 契约见 docs/design/connection_identity_v1.md。
local M = {}

M.VERSION = "v1"
M.MAX_NODE_LEN = 64
M.MAX_SERVICE_LEN = 64
M.BOOT_ID_BYTES = 16
M.BOOT_ID_HEX_LEN = 32
-- 保守上界，避免日志/指标/运维工具用双精度解析时丢精度
M.MAX_SEQ = 9007199254740991
-- 最坏情况：v1(2) + 4 个分隔符 + 两个 64 字节字段全部转义(2*192)
-- + boot_id(32) + seq 最多 16 位 = 438
M.MAX_CID_LEN = 438

local function is_safe_byte(b)
    return (b >= 48 and b <= 57)
        or (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122)
        or b == 46 -- .
        or b == 95 -- _
        or b == 45 -- -
end

local function encode_component(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if is_safe_byte(b) then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = string.format("%%%02X", b)
        end
    end
    return table.concat(out)
end

local function decode_component(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "%" then
            if i + 2 > n then
                return nil, "incomplete percent escape"
            end
            local hi, lo = s:sub(i + 1, i + 1), s:sub(i + 2, i + 2)
            if not hi:match("^[0-9A-F]$") or not lo:match("^[0-9A-F]$") then
                return nil, "invalid percent escape"
            end
            out[#out + 1] = string.char(tonumber(hi, 16) * 16 + tonumber(lo, 16))
            i = i + 3
        else
            if not is_safe_byte(c:byte()) then
                return nil, "unescaped byte outside the safe set"
            end
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- 解码后重新编码必须等于原串：这一条同时拒绝小写 hex、多余转义和非规范写法，
-- 保证 conn_id 可以直接当表键比较。
local function decode_canonical(s)
    local decoded, err = decode_component(s)
    if not decoded then
        return nil, err
    end
    if encode_component(decoded) ~= s then
        return nil, "non-canonical percent encoding"
    end
    return decoded
end

local function check_component(value, max_len, label)
    if type(value) ~= "string" then
        return nil, label .. " must be a string"
    end
    if #value == 0 then
        return nil, label .. " must not be empty"
    end
    if #value > max_len then
        return nil, label .. " is too long"
    end
    return value
end

local function check_boot_id(boot_id)
    if type(boot_id) ~= "string" or #boot_id ~= M.BOOT_ID_HEX_LEN then
        return nil, "invalid boot_id"
    end
    if not boot_id:match("^[0-9a-f]+$") then
        return nil, "invalid boot_id"
    end
    return boot_id
end

local function check_seq(seq)
    if math.type(seq) ~= "integer" or seq < 1 or seq > M.MAX_SEQ then
        return nil, "local_seq out of range"
    end
    return seq
end

local function parse_seq(text)
    if not text:match("^[0-9]+$") then
        return nil, "invalid local_seq"
    end
    if #text > 1 and text:sub(1, 1) == "0" then
        return nil, "non-canonical local_seq"
    end
    local n = tonumber(text)
    if math.type(n) ~= "integer" or n < 1 or n > M.MAX_SEQ then
        return nil, "local_seq out of range"
    end
    return n
end

local RNG_UNAVAILABLE = "rng unavailable"

-- crypto 是编译进 luaclib 的白名单 C 模块（与 entity/session.lua 的用法一致）。
-- 用 pcall 包住是因为它可能没被构建：缺模块时要拒绝启动，而不是把异常抛给调用方。
local function default_random_bytes(n)
    local ok, crypto = pcall(require, "crypto")
    if not ok or type(crypto) ~= "table" or type(crypto.random_bytes) ~= "function" then
        error(RNG_UNAVAILABLE, 0)
    end
    return crypto.random_bytes(n)
end

-- 生成进程级 boot_id。random_bytes 可注入以便测试；随机源失败必须让网关拒绝启动，
-- 不允许用时间、PID 或固定值兜底。
function M.new_boot_id(random_bytes)
    local rng = random_bytes
    if rng == nil then
        rng = default_random_bytes
    end
    if type(rng) ~= "function" then
        return nil, "rng must be a function"
    end
    local ok, bytes = pcall(rng, M.BOOT_ID_BYTES)
    if not ok then
        -- 不回显错误内容：注入的随机源可能把随机字节或本地路径带进错误信息
        if bytes == RNG_UNAVAILABLE then
            return nil, RNG_UNAVAILABLE
        end
        return nil, "rng failed"
    end
    if type(bytes) ~= "string" or #bytes ~= M.BOOT_ID_BYTES then
        return nil, "invalid rng output"
    end
    local out = {}
    for i = 1, #bytes do
        out[i] = string.format("%02x", bytes:byte(i))
    end
    return table.concat(out)
end

function M.new(gate_node, gate_service, boot_id, local_seq)
    local ok, err = check_component(gate_node, M.MAX_NODE_LEN, "gate_node")
    if not ok then
        return nil, err
    end
    ok, err = check_component(gate_service, M.MAX_SERVICE_LEN, "gate_service")
    if not ok then
        return nil, err
    end
    ok, err = check_boot_id(boot_id)
    if not ok then
        return nil, err
    end
    ok, err = check_seq(local_seq)
    if not ok then
        return nil, err
    end

    local cid = table.concat({
        M.VERSION,
        encode_component(gate_node),
        encode_component(gate_service),
        boot_id,
        tostring(local_seq),
    }, "|")
    if #cid > M.MAX_CID_LEN then
        return nil, "conn_id is too long"
    end
    return cid
end

function M.parse(cid)
    if type(cid) ~= "string" or #cid > M.MAX_CID_LEN then
        return nil, "invalid conn_id"
    end
    -- 五个字段都不含分隔符，多一个或少一个 '|' 都无法匹配
    local version, enc_node, enc_service, boot_id, seq_text = cid:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    if not version then
        return nil, "invalid conn_id format"
    end
    if version ~= M.VERSION then
        return nil, "unsupported conn_id version"
    end

    local gate_node, err = decode_canonical(enc_node)
    if not gate_node then
        return nil, err
    end
    local gate_service
    gate_service, err = decode_canonical(enc_service)
    if not gate_service then
        return nil, err
    end
    local ok
    ok, err = check_component(gate_node, M.MAX_NODE_LEN, "gate_node")
    if not ok then
        return nil, err
    end
    ok, err = check_component(gate_service, M.MAX_SERVICE_LEN, "gate_service")
    if not ok then
        return nil, err
    end
    ok, err = check_boot_id(boot_id)
    if not ok then
        return nil, err
    end
    local local_seq
    local_seq, err = parse_seq(seq_text)
    if not local_seq then
        return nil, err
    end

    return {
        version = version,
        gate_node = gate_node,
        gate_service = gate_service,
        boot_id = boot_id,
        local_seq = local_seq,
    }
end

function M.validate(cid)
    local parsed, err = M.parse(cid)
    if not parsed then
        return false, err
    end
    return true
end

function M.equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    if not M.validate(a) or not M.validate(b) then
        return false
    end
    return a == b
end

return M
