local t = require "skytest"
local snapshot = require "skyext.session_snapshot"

local EPOCH = string.rep("a", 32)

local function session_io(over)
    local io_ = {
        session_epoch = EPOCH,
        session_mode = snapshot.MODE.V2,
        nonce = "nonce-1",
        sent = 3,
        acked = 1,
        out_buf = { [2] = "PACK-2", [3] = "PACK-3" },
        resp_cache = {
            [7] = { name = "shop.buy", pack = "RESP-7" },
        },
        min_cached_req_id = 5,
    }
    for k, v in pairs(over or {}) do
        io_[k] = v
    end
    return io_
end

t.describe("session_snapshot 编码", function()
    t.it("round-trips a v2 session without changing any counter", function()
        local io_ = session_io()
        local bytes = assert(snapshot.encode(io_))
        local decoded = assert(snapshot.decode(bytes))
        t.expect(decoded.session_epoch).to.equal(EPOCH)
        t.expect(decoded.session_mode).to.equal(snapshot.MODE.V2)
        t.expect(decoded.sent).to.equal(3)
        t.expect(decoded.acked).to.equal(1)
        t.expect(decoded.nonce).to.equal("nonce-1")
        -- out_buf 原样搬运，不重编码
        t.expect(decoded.out_buf[2]).to.equal("PACK-2")
        t.expect(decoded.out_buf[3]).to.equal("PACK-3")
        t.expect(decoded.resp_cache[7].name).to.equal("shop.buy")
        t.expect(decoded.resp_cache[7].pack).to.equal("RESP-7")
        t.expect(decoded.min_cached_req_id).to.equal(5)
    end)

    t.it("handles an empty replay buffer", function()
        local io_ = session_io({ sent = 0, acked = 0, out_buf = {}, resp_cache = {} })
        local decoded = assert(snapshot.decode(assert(snapshot.encode(io_))))
        t.expect(decoded.sent).to.equal(0)
        t.expect(decoded.acked).to.equal(0)
        t.expect(next(decoded.out_buf)).to.be_nil()
        t.expect(next(decoded.resp_cache)).to.be_nil()
    end)

    t.it("keeps legacy sessions in legacy mode", function()
        local io_ = session_io({ session_mode = snapshot.MODE.LEGACY })
        local decoded = assert(snapshot.decode(assert(snapshot.encode(io_))))
        t.expect(decoded.session_mode).to.equal(snapshot.MODE.LEGACY)
    end)

    -- 缺一个包就是断链：宁可拒绝迁移，也不能让客户端永久失同步
    t.it("refuses to encode a replay buffer with a gap", function()
        local io_ = session_io({ out_buf = { [2] = "PACK-2" } })
        local bytes, err = snapshot.encode(io_)
        t.expect(bytes).to.be_nil()
        t.expect(err).to.equal(snapshot.ERR.GAP)
    end)

    t.it("refuses inconsistent counters, modes and epochs", function()
        t.expect(snapshot.encode(session_io({ acked = 9 }))).to.be_nil()
        t.expect(snapshot.encode(session_io({ session_mode = 7 }))).to.be_nil()
        t.expect(snapshot.encode(session_io({ session_epoch = "short" }))).to.be_nil()
        t.expect(snapshot.encode(session_io({ session_epoch = string.rep("A", 32) }))).to.be_nil()
        t.expect(snapshot.encode(session_io({ sent = 1.5 }))).to.be_nil()
        t.expect(snapshot.encode(nil)).to.be_nil()
    end)
end)

t.describe("session_snapshot 校验", function()
    t.it("detects a truncated snapshot", function()
        local bytes = assert(snapshot.encode(session_io()))
        local _, err = snapshot.decode(bytes:sub(1, #bytes - 10))
        t.expect(err).to.equal(snapshot.ERR.CHECKSUM)
        t.expect(snapshot.decode(bytes:sub(1, 3))).to.be_nil()
    end)

    t.it("detects a corrupted payload", function()
        local bytes = assert(snapshot.encode(session_io()))
        local pos = #bytes // 2
        local flipped = bytes:sub(1, pos - 1) .. string.char(bytes:byte(pos) ~ 0xFF) .. bytes:sub(pos + 1)
        local _, err = snapshot.decode(flipped)
        t.expect(err).to.equal(snapshot.ERR.CHECKSUM)
    end)

    t.it("rejects a snapshot with a different magic or version", function()
        local bytes = assert(snapshot.encode(session_io()))
        local body = bytes:sub(1, #bytes - 4)
        local replaced = "XXXX" .. body:sub(5) .. string.pack("<I4", snapshot.checksum("XXXX" .. body:sub(5)))
        local _, err = snapshot.decode(replaced)
        t.expect(err).to.equal(snapshot.ERR.BAD_MAGIC)

        local v2 = body:sub(1, 4) .. string.char(2) .. body:sub(6)
        local _, verr = snapshot.decode(v2 .. string.pack("<I4", snapshot.checksum(v2)))
        t.expect(verr).to.equal(snapshot.ERR.BAD_VERSION)
    end)

    t.it("rejects a non-string snapshot", function()
        t.expect(snapshot.decode(nil)).to.be_nil()
        t.expect(snapshot.decode({})).to.be_nil()
    end)
end)

t.describe("session_snapshot 恢复", function()
    t.it("restores a session io that continues the same numbering", function()
        local io_ = assert(snapshot.restore(assert(snapshot.decode(assert(snapshot.encode(session_io())))), EPOCH, {
            now = 100,
            owner_epoch = 4,
        }))
        t.expect(io_.sent).to.equal(3)
        t.expect(io_.acked).to.equal(1)
        t.expect(io_.out_buf[3]).to.equal("PACK-3")
        -- 迁移只推进 owner_epoch，wire 上的 session_epoch 不变
        t.expect(io_.owner_epoch).to.equal(4)
        t.expect(io_.session_epoch).to.equal(EPOCH)
        t.expect(io_.replaying).to.equal(false)
        t.expect(io_.out_bytes).to.equal(#"PACK-2" + #"PACK-3")
    end)

    -- 装错会话比迁移失败严重得多
    t.it("refuses to restore into a different logical session", function()
        local snap = assert(snapshot.decode(assert(snapshot.encode(session_io()))))
        local ok, err = snapshot.restore(snap, string.rep("b", 32))
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("session epoch mismatch")
    end)

    t.it("refuses a snapshot whose replay buffer is incomplete", function()
        local snap = assert(snapshot.decode(assert(snapshot.encode(session_io()))))
        snap.out_buf[3] = nil
        local ok, err = snapshot.restore(snap, EPOCH)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal(snapshot.ERR.GAP)
    end)
end)
