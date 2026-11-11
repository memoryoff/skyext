-- DownlinkV2 的 wire 信封。Role 编码、Gateway 原样转发（不解码），客户端按
-- (session_epoch, seq) 去重。契约见 docs/design/session_downlink_v2.md。
--
-- 布局（固定 45 字节头 + 原始 sproto 包）：
--
--   magic           4 字节  "SKX2"
--   version         1 字节  2
--   session_epoch  32 字节 小写 hex（16 字节随机数的可读编码，JS 不会截断）
--   seq             8 字节 大端无符号，等于 Role 的 session_io.sent
--   payload        剩余     sproto 编码的原始下行包，不重新编码
--
-- 为什么不用 sproto 包一层：网关不解码是硬约束，sproto 需要 schema 才能解；
-- 固定头让网关只做字节转发，客户端也不必先解 envelope 再解业务包。
-- 为什么 epoch 用 ASCII hex 而不是二进制：跨语言（Lua/TS）比较和日志都简单，
-- 32 字节开销对下行包可以忽略。
local M = {}

M.VERSION = 2
M.MAGIC = "SKX2"
M.EPOCH_HEX_BYTES = 32
M.HEADER_BYTES = 4 + 1 + M.EPOCH_HEX_BYTES + 8

-- 32 位小写 hex，长度固定。生成端与校验端必须用同一个判定
local function is_epoch(epoch)
    return type(epoch) == "string" and #epoch == M.EPOCH_HEX_BYTES and epoch:match("^[0-9a-f]+$") ~= nil
end

M.is_epoch = is_epoch

-- 16 字节随机数 -> 32 位小写 hex。随机源由调用方注入（生产是 crypto.random_bytes）
function M.epoch_from_bytes(bytes)
    if type(bytes) ~= "string" or #bytes ~= 16 then
        return nil, "epoch needs 16 random bytes"
    end
    local out = {}
    for i = 1, #bytes do
        out[i] = string.format("%02x", bytes:byte(i))
    end
    return table.concat(out)
end

function M.encode(epoch, seq, payload)
    if not is_epoch(epoch) then
        return nil, "invalid session_epoch"
    end
    if math.type(seq) ~= "integer" or seq < 0 then
        return nil, "seq must be a non-negative integer"
    end
    if type(payload) ~= "string" then
        return nil, "payload must be a string"
    end
    return M.MAGIC .. string.char(M.VERSION) .. epoch .. string.pack(">I8", seq) .. payload
end

-- 服务端不调用它；给 SDK、测试和排查工具用。返回 nil, err 而不是抛错，
-- 因为客户端收到脏包时要能安全地丢掉而不是让收包协程死掉
function M.decode(pack)
    if type(pack) ~= "string" or #pack < M.HEADER_BYTES then
        return nil, "packet too short"
    end
    if pack:sub(1, 4) ~= M.MAGIC then
        return nil, "bad magic"
    end
    local version = pack:byte(5)
    if version ~= M.VERSION then
        return nil, "unsupported version"
    end
    local epoch = pack:sub(6, 5 + M.EPOCH_HEX_BYTES)
    if not is_epoch(epoch) then
        return nil, "invalid session_epoch"
    end
    local seq = string.unpack(">I8", pack, 6 + M.EPOCH_HEX_BYTES)
    if seq < 0 then
        return nil, "invalid seq"
    end
    return {
        version = version,
        session_epoch = epoch,
        seq = seq,
        payload = pack:sub(M.HEADER_BYTES + 1),
    }
end

return M
