-- 请求指纹：规范化编码 + 摘要，供会话层比对 req_id 的参数摘要。
--
-- 本模块不持有密钥：hash_fn(domain, framed_bytes) -> digest 由调用方注入。
-- 生产直接把 crypto.hmac_sha256 当 hash_fn 传入（key 第一、msg 第二、32 字节二进制），
-- 或写成 function(domain, input) return crypto.hmac_sha256(domain, input) end。
-- **禁止预绑定第一个参数**：那样 domain 会占住形参、真实输入被丢掉，摘要与请求无关。
-- 固定域串是非保密的用途分离键，HMAC 在这里只作抗碰撞摘要，不用于授权验签。
--
-- 纯 Lua、无 IO、无 yield；失败一律 fail-closed，不降级成"不比对指纹"。
-- 契约见 docs/design/request_fingerprint_v1.md。
local canonical = require "skyext.canonical_lua"

local M = {}

M.VERSION = 1
M.DOMAIN = "skyext:fingerprint:v1"
M.HASH_BYTES = 32

-- 编码域 F1 与指纹版本 1 必须一致；只改一边会让旧缓存被静默当成新格式
assert(
    canonical.ENCODING_DOMAIN == "F" .. tostring(M.VERSION),
    "encoding domain and fingerprint version disagree"
)

-- matches 的第三返回值。调用方据此映射错误码，不要比较 reason 文案：
--   STALE_VERSION / INVALID_HASH -> REQUEST_EXPIRED
--   PROTOCOL_MISMATCH / MISMATCH -> REQUEST_CONFLICT
--   INTERNAL                     -> 整体失败（不返回业务错误码）
M.KIND = {
    STALE_VERSION = "stale_version",
    PROTOCOL_MISMATCH = "protocol_mismatch",
    INVALID_HASH = "invalid_hash",
    MISMATCH = "mismatch",
    INTERNAL = "internal",
}

local function resolve_equal(equal_fn)
    if equal_fn ~= nil and type(equal_fn) ~= "function" then
        return nil, "equal_fn must be a function"
    end
    if equal_fn then
        return equal_fn
    end
    -- 默认 == 仅供测试；生产必须传 crypto.const_equals
    return function(a, b)
        return a == b
    end
end

function M.compute(protocol_name, request, hash_fn)
    if type(hash_fn) ~= "function" then
        return nil, "hash_fn is required"
    end
    local input, err = canonical.encode_request(protocol_name, request)
    if not input then
        return nil, err
    end
    local ok, digest = pcall(hash_fn, M.DOMAIN, input)
    if not ok then
        -- 不回显错误内容：注入实现可能把密钥或本地路径带进错误信息
        return nil, "hash failed"
    end
    if type(digest) ~= "string" or #digest ~= M.HASH_BYTES then
        return nil, "invalid digest"
    end
    return digest
end

-- 先算摘要、执行完拿到 pack 之后再组装条目；避免对 handler 可能改过的表二次编码。
function M.entry_from_digest(digest, protocol_name, pack)
    if type(digest) ~= "string" or #digest ~= M.HASH_BYTES then
        return nil, "invalid digest"
    end
    if
        type(protocol_name) ~= "string"
        or #protocol_name == 0
        or #protocol_name > canonical.MAX_PROTOCOL_LEN
        or not protocol_name:match("^[A-Za-z0-9%._%-]+$")
    then
        return nil, "invalid protocol name"
    end
    if type(pack) ~= "string" then
        return nil, "pack must be a string"
    end
    return {
        fingerprint_version = M.VERSION,
        name = protocol_name,
        hash = digest,
        pack = pack,
    }
end

-- 只用于测试/只读协议。上行请求应先 compute、执行完拿到 pack 再用 entry_from_digest
-- 组装，否则 handler 改过入参后算出的摘要与重传请求对不上。
function M.new_entry(protocol_name, request, pack, hash_fn)
    local digest, err = M.compute(protocol_name, request, hash_fn)
    if not digest then
        return nil, err
    end
    return M.entry_from_digest(digest, protocol_name, pack)
end

-- 返回 true 或 false, reason, kind。条目不可用时直接判失败，调用方按 REQUEST_EXPIRED 处理，
-- 不能猜测重放。matches 为 true 只说明参数相同，不说明业务已提交。
function M.matches(entry, protocol_name, request, hash_fn, equal_fn)
    if type(entry) ~= "table" then
        return false, "invalid entry", M.KIND.STALE_VERSION
    end
    if entry.fingerprint_version ~= M.VERSION then
        return false, "stale fingerprint version", M.KIND.STALE_VERSION
    end
    -- 条目不可用优先于语义冲突：缺 hash 的旧条目要按 EXPIRED 处理，
    -- 不能被同 req_id 换协议掩盖成 CONFLICT
    if type(entry.hash) ~= "string" or #entry.hash ~= M.HASH_BYTES then
        return false, "invalid cached hash", M.KIND.INVALID_HASH
    end
    if entry.name ~= protocol_name then
        return false, "protocol mismatch", M.KIND.PROTOCOL_MISMATCH
    end

    local eq, eq_err = resolve_equal(equal_fn)
    if not eq then
        return false, eq_err, M.KIND.INTERNAL
    end
    local digest, err = M.compute(protocol_name, request, hash_fn)
    if not digest then
        return false, err, M.KIND.INTERNAL
    end
    local ok, same = pcall(eq, digest, entry.hash)
    if not ok then
        return false, "equal_fn failed", M.KIND.INTERNAL
    end
    if same == true then
        return true
    end
    if same == false then
        return false, "fingerprint mismatch", M.KIND.MISMATCH
    end
    -- truthy 非布尔说明比较函数本身有问题，按内部故障处理，不能伪装成客户端冲突
    return false, "equal_fn returned a non-boolean", M.KIND.INTERNAL
end

return M
