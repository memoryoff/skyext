local t = require "skytest"
local downlink = require "skyext.downlink"

local EPOCH = string.rep("ab", 16)

t.describe("downlink v2 envelope", function()
    t.it("round-trips epoch, seq and the original payload bytes", function()
        local payload = "PACK\0\1\2binary"
        local pack = assert(downlink.encode(EPOCH, 101, payload))
        local decoded = assert(downlink.decode(pack))
        t.expect(decoded.version).to.equal(2)
        t.expect(decoded.session_epoch).to.equal(EPOCH)
        t.expect(decoded.seq).to.equal(101)
        t.expect(decoded.payload).to.equal(payload)
        t.expect(#pack).to.equal(downlink.HEADER_BYTES + #payload)
    end)

    t.it("keeps the largest safe sequence and an empty payload", function()
        local pack = assert(downlink.encode(EPOCH, 9007199254740991, ""))
        local decoded = assert(downlink.decode(pack))
        t.expect(decoded.seq).to.equal(9007199254740991)
        t.expect(decoded.payload).to.equal("")
    end)

    t.it("rejects an epoch that is not 32 lowercase hex", function()
        t.expect(downlink.encode(string.rep("A", 32), 1, "")).to.be_nil()
        t.expect(downlink.encode(string.rep("g", 32), 1, "")).to.be_nil()
        t.expect(downlink.encode("short", 1, "")).to.be_nil()
    end)

    t.it("rejects negative or non-integer sequences", function()
        t.expect(downlink.encode(EPOCH, -1, "")).to.be_nil()
        t.expect(downlink.encode(EPOCH, 1.5, "")).to.be_nil()
    end)

    t.it("rejects truncated, bad magic and wrong version packets", function()
        local pack = assert(downlink.encode(EPOCH, 1, "x"))
        t.expect(downlink.decode(pack:sub(1, downlink.HEADER_BYTES - 1))).to.be_nil()

        local bad_magic = "XXXX" .. pack:sub(5)
        t.expect(downlink.decode(bad_magic)).to.be_nil()

        local bad_version = pack:sub(1, 4) .. string.char(3) .. pack:sub(6)
        t.expect(downlink.decode(bad_version)).to.be_nil()

        local bad_epoch = pack:sub(1, 5) .. string.rep("z", 32) .. pack:sub(38)
        t.expect(downlink.decode(bad_epoch)).to.be_nil()
    end)

    t.it("builds the epoch from exactly 16 random bytes", function()
        local epoch = assert(downlink.epoch_from_bytes(string.rep("\255", 16)))
        t.expect(epoch).to.equal(string.rep("ff", 16))
        t.expect(downlink.epoch_from_bytes(string.rep("\0", 15))).to.be_nil()
        t.expect(downlink.epoch_from_bytes(nil)).to.be_nil()
    end)
end)
