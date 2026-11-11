-- 关键经济操作的授权批次与稳定操作键。
--
-- 客户端不自签：grant 只能由服务端签发，mac 用 key_id 指向的对称密钥计算。
-- 本模块不持有密钥，签名/验签由调用方注入 hmac_fn（见 docs/design/critical_grant_v1.md）。
--
-- 验签只证明"服务端签发、字段未被篡改"：expires_at、seq <= max_seq、rid 与会话一致，
-- 都必须由调用方校验。签名不等于"该操作已消费"，去重必须落库。
--
-- 纯 Lua、无 IO、无 yield；op_id 可直接作为 Mongo 字段名与去重键。
local canonical = require "skyext.canonical_lua"

local M = {}

M.VERSION = 1
-- seq 固定 4 位 hex，所以上限是 0xFFFF。不是截断器：越界必须拒绝，否则不同 seq 会碰撞。
M.MAX_SEQ = 0xFFFF
M.GRANT_ID_HEX_LEN = 32
M.MAX_KEY_ID_LEN = 64
-- 签名域前缀：与请求指纹的 F1 分开，避免同一密钥签不同用途的数据时可以互换
M.SIGNING_DOMAIN = "G1"

-- 允许出现的键。mac 是信封字段：可以出现在整表里，但不参与签名域，
-- 否则从 wire 解出的完整 grant 会因为多了 mac 而被拒。
local FIELD_NAMES = {
    version = true,
    rid = true,
    grant_id = true,
    issued_at = true,
    expires_at = true,
    max_seq = true,
    key_id = true,
    mac = true,
}

local RNG_UNAVAILABLE = "rng unavailable"

-- crypto 是编译进 luaclib 的白名单 C 模块；缺构建时拒绝启动，不抛给调用方。
-- 与 connection_id.lua 的同名逻辑保持同步（两者语义不同，没有合并成一个 helper）。
local function default_random_bytes(n)
    local ok, crypto = pcall(require, "crypto")
    if not ok or type(crypto) ~= "table" or type(crypto.random_bytes) ~= "function" then
        error(RNG_UNAVAILABLE, 0)
    end
    return crypto.random_bytes(n)
end

function M.new_grant_id(random_bytes)
    local rng = random_bytes or default_random_bytes
    if type(rng) ~= "function" then
        return nil, "rng must be a function"
    end
    local ok, bytes = pcall(rng, 16)
    if not ok then
        -- 不回显错误内容：注入的随机源可能把随机字节或本地路径带进错误信息
        if bytes == RNG_UNAVAILABLE then
            return nil, RNG_UNAVAILABLE
        end
        return nil, "rng failed"
    end
    if type(bytes) ~= "string" or #bytes ~= 16 then
        return nil, "invalid rng output"
    end
    local out = {}
    for i = 1, #bytes do
        out[i] = string.format("%02x", bytes:byte(i))
    end
    return table.concat(out)
end

function M.validate_grant_id(grant_id)
    if type(grant_id) ~= "string" or #grant_id ~= M.GRANT_ID_HEX_LEN then
        return false, "invalid grant_id"
    end
    if not grant_id:match("^[0-9a-f]+$") then
        return false, "invalid grant_id"
    end
    return true
end

function M.four_digit_hex(seq)
    if math.type(seq) ~= "integer" or seq < 1 or seq > M.MAX_SEQ then
        return nil, "seq out of range"
    end
    return string.format("%04x", seq)
end

function M.op_id(grant_id, seq)
    local ok, err = M.validate_grant_id(grant_id)
    if not ok then
        return nil, err
    end
    local hex
    hex, err = M.four_digit_hex(seq)
    if not hex then
        return nil, err
    end
    return grant_id .. "_" .. hex
end

-- 只接受规范形式，不做归一化：op_id 要能直接当表键比较。
function M.parse_op_id(op_id)
    if type(op_id) ~= "string" then
        return nil, "invalid op_id"
    end
    local grant_id, hex = op_id:match("^([0-9a-f]+)_([0-9a-f]+)$")
    if not grant_id then
        return nil, "invalid op_id format"
    end
    local ok, err = M.validate_grant_id(grant_id)
    if not ok then
        return nil, err
    end
    if #hex ~= 4 then
        return nil, "invalid seq length"
    end
    local seq = tonumber(hex, 16)
    if not seq or seq < 1 then
        return nil, "invalid seq"
    end
    -- 防御性断言：4 位小写 hex 与 %04x(1..65535) 一一对应，正常不可达
    if M.four_digit_hex(seq) ~= hex then
        return nil, "non-canonical seq"
    end
    return { grant_id = grant_id, seq = seq }
end

-- string 不能走 math.tointeger（它会把 "1001" 转成数字），先卡类型再归一整数浮点
local function as_int(v)
    if type(v) ~= "number" then
        return nil
    end
    return math.tointeger(v)
end

-- 校验字段并输出签名输入。字段顺序与插入顺序不影响结果，整数值浮点统一归一为 integer。
-- mac 可以出现在入参里，但永远不参与签名域。
function M.canonical_fields(fields)
    if type(fields) ~= "table" then
        return nil, "fields must be a table"
    end
    if getmetatable(fields) ~= nil then
        return nil, "fields must be a plain table"
    end
    for k in pairs(fields) do
        if not FIELD_NAMES[k] then
            -- 不回显调用方数据：字段名可能很长、含控制字符，甚至不是字符串
            if type(k) == "string" and #k <= 32 then
                return nil, "unexpected field: " .. string.format("%q", k)
            end
            return nil, "unexpected field"
        end
    end

    if fields.version ~= M.VERSION then
        return nil, "unsupported grant version"
    end
    local rid = as_int(fields.rid)
    if not rid or rid < 1 then
        return nil, "invalid rid"
    end
    local ok, err = M.validate_grant_id(fields.grant_id)
    if not ok then
        return nil, err
    end
    local issued_at = as_int(fields.issued_at)
    if not issued_at or issued_at < 0 then
        return nil, "invalid issued_at"
    end
    local expires_at = as_int(fields.expires_at)
    if not expires_at or expires_at <= issued_at then
        return nil, "invalid expires_at"
    end
    local max_seq = as_int(fields.max_seq)
    if not max_seq or max_seq < 1 or max_seq > M.MAX_SEQ then
        return nil, "invalid max_seq"
    end
    if
        type(fields.key_id) ~= "string"
        or #fields.key_id == 0
        or #fields.key_id > M.MAX_KEY_ID_LEN
        or not fields.key_id:match("^[A-Za-z0-9%._%-]+$")
    then
        return nil, "invalid key_id"
    end

    -- 重新组装：归一 version 与整数浮点，且始终不含 mac
    local body, body_err = canonical.encode({
        version = M.VERSION,
        rid = rid,
        grant_id = fields.grant_id,
        issued_at = issued_at,
        expires_at = expires_at,
        max_seq = max_seq,
        key_id = fields.key_id,
    })
    if not body then
        return nil, body_err
    end
    return M.SIGNING_DOMAIN .. body
end

-- hmac_fn(key_id, canonical_bytes) -> mac；密钥由调用方的密钥设施按 key_id 选择。
function M.sign(fields, hmac_fn)
    if type(hmac_fn) ~= "function" then
        return nil, "hmac_fn is required"
    end
    local input, err = M.canonical_fields(fields)
    if not input then
        return nil, err
    end
    local ok, mac = pcall(hmac_fn, fields.key_id, input)
    if not ok then
        return nil, "hmac failed"
    end
    if type(mac) ~= "string" or #mac == 0 then
        return nil, "invalid mac"
    end
    return mac
end

-- equal_fn 生产必须传 crypto.const_equals；默认的 == 仅供测试。
-- 这里做类型检查、pcall 和严格布尔判断，避免漏传时静默降级成非常量时间比较，
-- 也避免错误的 equal_fn 把 truthy 值当成匹配。
function M.verify(fields, mac, hmac_fn, equal_fn)
    if type(mac) ~= "string" or #mac == 0 then
        return false, "invalid mac"
    end
    if equal_fn ~= nil and type(equal_fn) ~= "function" then
        return false, "equal_fn must be a function"
    end
    local expected, err = M.sign(fields, hmac_fn)
    if not expected then
        return false, err
    end
    local eq = equal_fn or function(a, b)
        return a == b
    end
    local ok, same = pcall(eq, expected, mac)
    if not ok then
        return false, "equal_fn failed"
    end
    if same ~= true then
        return false, "mac mismatch"
    end
    return true
end

return M
