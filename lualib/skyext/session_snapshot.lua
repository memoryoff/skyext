-- 会话快照 v1（P15）：把 Role 的会话状态编码成可跨节点移交的字节串。
--
-- 迁移的硬约束：`session_epoch`、`sent`、`acked`、`out_buf` 必须**原样**过去，
-- 否则客户端按 `(session_epoch, seq)` 去重就会错位。因此快照不做任何"重新编码"：
-- `out_buf` 里已经是完整的 DownlinkV2 字节，直接搬运。
--
-- 格式（小端，v2）：
--   "SKXS" | version u8 | mode u8 | flags u8 | epoch[32] ascii
--   | sent u64 | acked u64
--   | nonce_len u16 | nonce
--   | out_count u32 | (seq u64 | len u32 | bytes)*
--   | resp_count u32 | (req_id u32 | name_len u16 | name | fp_ver u8 | hash[32] | len u32 | pack)*
--   | min_cached_req_id u32 | checksum u32
--
-- v2 相对 v1 只加了两处：flags（保真 `unresumable`）与每条 L1 条目的
-- `fingerprint_version + 32 字节摘要`。少了摘要，迁移后重传的在途请求无法证明
-- "参数相同"，`matches_digest` 会判 INVALID_HASH，非幂等操作就会被重新执行一遍。
-- 版本不匹配一律拒绝（fail-closed 降级重登）：快照只在一次迁移里活着，
-- 猜一个不认识的老格式，比让客户端重登危险得多。
--
-- 校验失败一律拒绝迁移：宁可让客户端重连重新登录，也不能带着断掉的 `out_buf`
-- 宣称"无感迁移"——那会把缺口变成客户端的永久失同步。
local M = {}

M.MAGIC = "SKXS"
M.VERSION = 2
M.EPOCH_HEX_LEN = 32
M.MAX_NONCE = 64
M.MAX_OUT_PACKETS = 4096
M.MAX_OUT_BYTES = 8 * 1024 * 1024
M.MAX_RESP_ENTRIES = 4096
M.MAX_NAME = 128

M.MODE = { LEGACY = 0, V2 = 1 }

M.FLAG = { UNRESUMABLE = 1 }

M.ERR = {
    BAD_MAGIC = "bad_magic",
    BAD_VERSION = "bad_version",
    BAD_MODE = "bad_mode",
    BAD_EPOCH = "bad_epoch",
    BAD_COUNTERS = "bad_counters",
    GAP = "out_buf_gap",
    TRUNCATED = "truncated",
    CHECKSUM = "checksum_mismatch",
    TOO_LARGE = "snapshot_too_large",
}

-- FNV-1a 32 位。只用于发现截断/错位，不承担防篡改：快照走的是内部可信通道
local function checksum(bytes)
    local h = 2166136261
    for i = 1, #bytes do
        h = h ~ bytes:byte(i)
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return h
end
M.checksum = checksum

local function is_hex32(value)
    return type(value) == "string" and #value == M.EPOCH_HEX_LEN and value:match("^[0-9a-f]+$") ~= nil
end

-- 编码。io 只需要这几个字段，便于从 session_io 直接取，也便于测试构造
function M.encode(io_)
    if type(io_) ~= "table" then
        return nil, "session io is required"
    end
    if not is_hex32(io_.session_epoch) then
        return nil, M.ERR.BAD_EPOCH
    end
    local mode = io_.session_mode
    if mode ~= M.MODE.LEGACY and mode ~= M.MODE.V2 then
        return nil, M.ERR.BAD_MODE
    end
    local sent, acked = io_.sent or 0, io_.acked or 0
    if math.type(sent) ~= "integer" or math.type(acked) ~= "integer" or sent < 0 or acked < 0 or acked > sent then
        return nil, M.ERR.BAD_COUNTERS
    end
    local nonce = io_.nonce or ""
    if type(nonce) ~= "string" or #nonce > M.MAX_NONCE then
        return nil, "invalid nonce"
    end

    -- out_buf 必须严格覆盖 (acked, sent]，缺一个就是断链
    local out_parts = {}
    local out_bytes = 0
    for seq = acked + 1, sent do
        local pack = io_.out_buf and io_.out_buf[seq]
        if type(pack) ~= "string" then
            return nil, M.ERR.GAP
        end
        out_bytes = out_bytes + #pack
        if out_bytes > M.MAX_OUT_BYTES then
            return nil, M.ERR.TOO_LARGE
        end
        out_parts[#out_parts + 1] = string.pack("<I8I4", seq, #pack) .. pack
    end
    local out_count = sent - acked
    if out_count > M.MAX_OUT_PACKETS then
        return nil, M.ERR.TOO_LARGE
    end

    local resp_parts = {}
    local resp_count = 0
    for req_id, entry in pairs(io_.resp_cache or {}) do
        if type(entry) == "table" and type(entry.pack) == "string" and type(entry.name) == "string" then
            if #entry.name > M.MAX_NAME then
                return nil, M.ERR.TOO_LARGE
            end
            -- 摘要缺失说明这条缓存本来就不该存在（`cache_response` 拒绝无摘要写入）。
            -- 迁移时丢掉它比留一条无法证明参数相同的条目更安全
            local hash = entry.hash
            local fp_version = entry.fingerprint_version
            if type(hash) ~= "string" or #hash ~= 32 or math.type(fp_version) ~= "integer" then
                return nil, "resp cache entry has no fingerprint"
            end
            resp_parts[#resp_parts + 1] = string.pack("<I4I2", req_id, #entry.name)
                .. entry.name
                .. string.pack("<B", fp_version)
                .. hash
                .. string.pack("<I4", #entry.pack)
                .. entry.pack
            resp_count = resp_count + 1
            if resp_count > M.MAX_RESP_ENTRIES then
                return nil, M.ERR.TOO_LARGE
            end
        end
    end

    local flags = 0
    if io_.unresumable then
        flags = flags | M.FLAG.UNRESUMABLE
    end
    local body = string.pack("<c4BBBI8I8", M.MAGIC, M.VERSION, mode, flags, sent, acked)
        .. io_.session_epoch
        .. string.pack("<I2", #nonce)
        .. nonce
        .. string.pack("<I4", out_count)
        .. table.concat(out_parts)
        .. string.pack("<I4", resp_count)
        .. table.concat(resp_parts)
        .. string.pack("<I4", io_.min_cached_req_id or 0)
    return body .. string.pack("<I4", checksum(body))
end

local function read(buf, pos, fmt)
    local size = string.packsize(fmt)
    if pos + size - 1 > #buf then
        return nil, nil, M.ERR.TRUNCATED
    end
    return string.unpack(fmt, buf, pos)
end

-- 解码 + 校验。任何不一致都返回 nil, err，调用方必须退化成重连
function M.decode(bytes)
    if type(bytes) ~= "string" then
        return nil, "snapshot must be a string"
    end
    if #bytes < #M.MAGIC + 1 + 1 + M.EPOCH_HEX_LEN + 4 then
        return nil, M.ERR.TRUNCATED
    end
    -- 先验校验和：截断/错位的快照不必再逐字段解析
    if #bytes < 5 then
        return nil, M.ERR.TRUNCATED
    end
    local body = bytes:sub(1, #bytes - 4)
    local want = string.unpack("<I4", bytes, #bytes - 3)
    if checksum(body) ~= want then
        return nil, M.ERR.CHECKSUM
    end

    local pos = 1
    local magic, version, mode
    magic, version, mode, pos = string.unpack("<c4BB", body, pos)
    if magic ~= M.MAGIC then
        return nil, M.ERR.BAD_MAGIC
    end
    if version ~= M.VERSION then
        return nil, M.ERR.BAD_VERSION
    end
    if mode ~= M.MODE.LEGACY and mode ~= M.MODE.V2 then
        return nil, M.ERR.BAD_MODE
    end
    local flags
    flags, pos = string.unpack("<B", body, pos)
    local sent, acked
    sent, acked, pos = string.unpack("<I8I8", body, pos)
    if acked > sent then
        return nil, M.ERR.BAD_COUNTERS
    end

    local epoch
    if pos + M.EPOCH_HEX_LEN - 1 > #body then
        return nil, M.ERR.TRUNCATED
    end
    epoch = body:sub(pos, pos + M.EPOCH_HEX_LEN - 1)
    pos = pos + M.EPOCH_HEX_LEN
    if not is_hex32(epoch) then
        return nil, M.ERR.BAD_EPOCH
    end

    local nonce_len
    nonce_len, pos = read(body, pos, "<I2")
    if not nonce_len or nonce_len > M.MAX_NONCE then
        return nil, M.ERR.TRUNCATED
    end
    if pos + nonce_len - 1 > #body then
        return nil, M.ERR.TRUNCATED
    end
    local nonce = body:sub(pos, pos + nonce_len - 1)
    pos = pos + nonce_len

    local out_count
    out_count, pos = read(body, pos, "<I4")
    if not out_count then
        return nil, M.ERR.TRUNCATED
    end
    if out_count > M.MAX_OUT_PACKETS or out_count ~= sent - acked then
        return nil, M.ERR.GAP
    end

    local out_buf = {}
    local total = 0
    local expect_seq = acked + 1
    for _ = 1, out_count do
        local seq, len
        seq, len, pos = read(body, pos, "<I8I4")
        if not seq then
            return nil, M.ERR.TRUNCATED
        end
        if seq ~= expect_seq then
            return nil, M.ERR.GAP
        end
        expect_seq = expect_seq + 1
        if len > M.MAX_OUT_BYTES or pos + len - 1 > #body then
            return nil, M.ERR.TRUNCATED
        end
        total = total + len
        if total > M.MAX_OUT_BYTES then
            return nil, M.ERR.TOO_LARGE
        end
        out_buf[seq] = body:sub(pos, pos + len - 1)
        pos = pos + len
    end

    local resp_count
    resp_count, pos = read(body, pos, "<I4")
    if not resp_count then
        return nil, M.ERR.TRUNCATED
    end
    if resp_count > M.MAX_RESP_ENTRIES then
        return nil, M.ERR.TOO_LARGE
    end

    local resp_cache = {}
    for _ = 1, resp_count do
        local req_id, name_len
        req_id, name_len, pos = read(body, pos, "<I4I2")
        if not req_id then
            return nil, M.ERR.TRUNCATED
        end
        if name_len > M.MAX_NAME or pos + name_len - 1 > #body then
            return nil, M.ERR.TRUNCATED
        end
        local name = body:sub(pos, pos + name_len - 1)
        pos = pos + name_len
        local fp_version
        fp_version, pos = read(body, pos, "<B")
        if not fp_version then
            return nil, M.ERR.TRUNCATED
        end
        if pos + 31 > #body then
            return nil, M.ERR.TRUNCATED
        end
        local hash = body:sub(pos, pos + 31)
        pos = pos + 32
        local len
        len, pos = read(body, pos, "<I4")
        if not len or pos + len - 1 > #body then
            return nil, M.ERR.TRUNCATED
        end
        resp_cache[req_id] = {
            name = name,
            pack = body:sub(pos, pos + len - 1),
            fingerprint_version = fp_version,
            hash = hash,
        }
        pos = pos + len
    end

    local min_cached
    min_cached, pos = read(body, pos, "<I4")
    if not min_cached then
        return nil, M.ERR.TRUNCATED
    end
    if pos - 1 ~= #body then
        -- 尾部还有多余字节：格式与版本对不上，不能猜
        return nil, M.ERR.TRUNCATED
    end

    return {
        version = version,
        session_epoch = epoch,
        session_mode = mode,
        sent = sent,
        acked = acked,
        nonce = nonce,
        out_buf = out_buf,
        resp_cache = resp_cache,
        min_cached_req_id = min_cached,
        unresumable = (flags & M.FLAG.UNRESUMABLE) ~= 0,
    }
end

-- 把快照装回一个 session_io。只接受与当前会话一致的 epoch：
-- 装错会话比迁移失败严重得多
function M.restore(snapshot, expected_epoch, opts)
    if type(snapshot) ~= "table" then
        return nil, "invalid snapshot"
    end
    if expected_epoch ~= nil and snapshot.session_epoch ~= expected_epoch then
        return nil, "session epoch mismatch"
    end
    if snapshot.acked > snapshot.sent then
        return nil, M.ERR.BAD_COUNTERS
    end
    local io_ = {
        session_epoch = snapshot.session_epoch,
        session_mode = snapshot.session_mode,
        nonce = snapshot.nonce,
        sent = snapshot.sent,
        acked = snapshot.acked,
        out_buf = {},
        out_bytes = 0,
        resp_cache = {},
        resp_order = { head = 1, tail = 0 },
        resp_bytes = 0,
        min_cached_req_id = snapshot.min_cached_req_id or 0,
        -- last_seen 用 skynet 的厘秒时钟（session.lua 的 sweep_idle 也用它）。
        -- 写成 os.time() 会让新 owner 的空闲回收永远不触发
        last_seen = (opts and opts.now) or os.time(),
        -- 源已经丢弃重放缓冲时，目标也不能假装可续接：客户端存在永久缺口，
        -- 必须让它走完整重登，而不是静默失同步
        unresumable = snapshot.unresumable == true,
        replaying = false,
        -- 迁移是一次所有权切换：网关据此拒绝旧 owner 的迟到下行
        owner_epoch = (opts and opts.owner_epoch) or 1,
    }
    for seq = snapshot.acked + 1, snapshot.sent do
        local pack = snapshot.out_buf[seq]
        if type(pack) ~= "string" then
            return nil, M.ERR.GAP
        end
        io_.out_buf[seq] = pack
        io_.out_bytes = io_.out_bytes + #pack
        if io_.out_bytes > M.MAX_OUT_BYTES then
            return nil, M.ERR.TOO_LARGE
        end
    end
    -- L1 缓存必须连摘要一起搬：没有摘要，重传的在途请求无法证明参数相同，
    -- matches_digest 会判 INVALID_HASH，非幂等操作就被重新执行一遍
    local ids = {}
    for req_id, entry in pairs(snapshot.resp_cache or {}) do
        io_.resp_cache[req_id] = {
            name = entry.name,
            pack = entry.pack,
            fingerprint_version = entry.fingerprint_version,
            hash = entry.hash,
        }
        io_.resp_bytes = io_.resp_bytes + #entry.pack
        ids[#ids + 1] = req_id
    end
    -- 淘汰队列必须重建：空队列会让这些条目永不淘汰，count/bytes 上限对它们失效
    table.sort(ids)
    for i, req_id in ipairs(ids) do
        io_.resp_order[i] = req_id
    end
    io_.resp_order.tail = #ids
    return io_
end

return M
