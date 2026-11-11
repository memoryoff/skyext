local t = require "skytest"
local connection_id = require "skyext.connection_id"

local BOOT = "0123456789abcdef0123456789abcdef"
local function fake_random(fill)
    return function()
        return string.rep(string.char(fill), 16)
    end
end

t.describe("connection_id.new_boot_id", function()
    t.it("returns a 32-char lowercase hex string", function()
        local id = connection_id.new_boot_id(fake_random(0xAB))
        t.expect(id).to.be_type("string")
        t.expect(#id).to.equal(32)
        t.expect(id:match("^[0-9a-f]+$")).to_not.be_nil()
        t.expect(id).to.equal(string.rep("ab", 16))
    end)

    t.it("derives the id from the injected random source", function()
        t.expect(connection_id.new_boot_id(fake_random(0x01))).to_not.equal(
            connection_id.new_boot_id(fake_random(0x02))
        )
    end)

    t.it("rejects a short random buffer", function()
        local id, err = connection_id.new_boot_id(function()
            return "short"
        end)
        t.expect(id).to.be_nil()
        t.expect(err).to.be_type("string")
    end)

    t.it("rejects a non-string random buffer", function()
        local id, err = connection_id.new_boot_id(function()
            return 123
        end)
        t.expect(id).to.be_nil()
        t.expect(err).to.be_type("string")
    end)

    t.it("turns a throwing random source into nil, err without leaking content", function()
        local id, err = connection_id.new_boot_id(function()
            error("SECRET_BYTES_SHOULD_NOT_LEAK", 0)
        end)
        t.expect(id).to.be_nil()
        t.expect(err).to.be_type("string")
        t.expect(err).to.contain("rng")
        t.expect(err:find("SECRET_BYTES_SHOULD_NOT_LEAK", 1, true)).to.be_nil()
        t.expect(err:find("connection_id.test.lua", 1, true)).to.be_nil()
        t.expect(err).to.equal("rng failed")
    end)

    t.it("reports rng unavailability distinctly when crypto is missing", function()
        local saved_preload, saved_loaded = package.preload["crypto"], package.loaded["crypto"]
        package.loaded["crypto"] = nil
        package.preload["crypto"] = function()
            error("crypto is not built", 0)
        end
        local id, err = connection_id.new_boot_id()
        package.loaded["crypto"] = saved_loaded
        package.preload["crypto"] = saved_preload
        t.expect(id).to.be_nil()
        t.expect(err).to.equal("rng unavailable")
    end)

    t.it("accepts a valid default-path-shaped injected source", function()
        local id, err = connection_id.new_boot_id(function(n)
            return string.rep("\255", n)
        end)
        t.expect(err).to.be_nil()
        t.expect(id).to.equal(string.rep("ff", 16))
    end)
end)

t.describe("connection_id.new / parse", function()
    t.it("round-trips a normal identity", function()
        local cid, err = connection_id.new("role1", ".gate_ws", BOOT, 7)
        t.expect(err).to.be_nil()
        t.expect(cid).to.equal("v1|role1|.gate_ws|" .. BOOT .. "|7")

        local parsed = connection_id.parse(cid)
        t.expect(parsed).to.equal({
            version = "v1",
            gate_node = "role1",
            gate_service = ".gate_ws",
            boot_id = BOOT,
            local_seq = 7,
        })
        t.expect(math.type(parsed.local_seq)).to.equal("integer")
    end)

    t.it("encodes separator, percent, space, control and utf-8 bytes", function()
        local cid = connection_id.new("gate|1", ".gate%ws x\n中文", BOOT, 1)
        t.expect(cid:find("|", 1, true)).to_not.be_nil()
        t.expect(cid:find("%7C", 1, true)).to_not.be_nil()
        t.expect(cid:find("%25", 1, true)).to_not.be_nil()
        t.expect(cid:find("%20", 1, true)).to_not.be_nil()
        t.expect(cid:find("%0A", 1, true)).to_not.be_nil()

        local parsed = connection_id.parse(cid)
        t.expect(parsed.gate_node).to.equal("gate|1")
        t.expect(parsed.gate_service).to.equal(".gate%ws x\n中文")
    end)

    t.it("keeps the same input canonical across calls", function()
        local a = connection_id.new("g|1", ".gate_ws", BOOT, 9)
        local b = connection_id.new("g|1", ".gate_ws", BOOT, 9)
        t.expect(a).to.equal(b)
        t.expect(connection_id.parse(a)).to.equal(connection_id.parse(b))
    end)

    t.it("produces different ids for each distinguishing field", function()
        local base = connection_id.new("role1", ".gate_ws", BOOT, 1)
        t.expect(connection_id.new("role2", ".gate_ws", BOOT, 1)).to_not.equal(base)
        t.expect(connection_id.new("role1", ".gate_tcp", BOOT, 1)).to_not.equal(base)
        t.expect(connection_id.new("role1", ".gate_ws", string.rep("f", 32), 1)).to_not.equal(base)
        t.expect(connection_id.new("role1", ".gate_ws", BOOT, 2)).to_not.equal(base)
    end)

    t.it("accepts the largest sequence number", function()
        local cid, err = connection_id.new("role1", ".gate_ws", BOOT, connection_id.MAX_SEQ)
        t.expect(err).to.be_nil()
        t.expect(connection_id.parse(cid).local_seq).to.equal(connection_id.MAX_SEQ)
    end)
end)

t.describe("connection_id.new argument validation", function()
    local function rejected(node, service, boot, seq)
        local cid, err = connection_id.new(node, service, boot, seq)
        t.expect(cid).to.be_nil()
        t.expect(err).to.be_type("string")
    end

    t.it("rejects empty, non-string or overlong node and service", function()
        rejected("", ".gate_ws", BOOT, 1)
        rejected(nil, ".gate_ws", BOOT, 1)
        rejected(42, ".gate_ws", BOOT, 1)
        rejected(string.rep("a", 65), ".gate_ws", BOOT, 1)
        rejected("role1", "", BOOT, 1)
        rejected("role1", nil, BOOT, 1)
        rejected("role1", string.rep("b", 65), BOOT, 1)
    end)

    t.it("rejects malformed boot_id", function()
        rejected("role1", ".gate_ws", "short", 1)
        rejected("role1", ".gate_ws", string.rep("A", 32), 1)
        rejected("role1", ".gate_ws", string.rep("g", 32), 1)
        rejected("role1", ".gate_ws", BOOT .. "00", 1)
        rejected("role1", ".gate_ws", nil, 1)
        rejected("role1", ".gate_ws", 12345, 1)
    end)

    t.it("rejects zero, negative, fractional, string and overflowing seq", function()
        rejected("role1", ".gate_ws", BOOT, 0)
        rejected("role1", ".gate_ws", BOOT, -1)
        rejected("role1", ".gate_ws", BOOT, 1.5)
        rejected("role1", ".gate_ws", BOOT, 7.0)
        rejected("role1", ".gate_ws", BOOT, "1")
        rejected("role1", ".gate_ws", BOOT, nil)
        rejected("role1", ".gate_ws", BOOT, connection_id.MAX_SEQ + 1)
    end)

    t.it("keeps the real worst case (both fields fully escaped) within MAX_CID_LEN", function()
        local worst = string.rep("\1", 64)
        local cid, err = connection_id.new(worst, worst, BOOT, connection_id.MAX_SEQ)
        t.expect(err).to.be_nil()
        t.expect(#cid).to.be_lte(connection_id.MAX_CID_LEN)
        t.expect(#cid).to.equal(connection_id.MAX_CID_LEN)

        local parsed = connection_id.parse(cid)
        t.expect(parsed.gate_node).to.equal(worst)
        t.expect(parsed.gate_service).to.equal(worst)
        t.expect(parsed.local_seq).to.equal(connection_id.MAX_SEQ)
        -- 反向闭环：解析结果重新生成必须得到同一串
        t.expect(connection_id.new(parsed.gate_node, parsed.gate_service, parsed.boot_id, parsed.local_seq))
            .to.equal(cid)
    end)

    t.it("round-trips NUL and high bytes", function()
        local node = "a\0b\255c"
        local cid, err = connection_id.new(node, ".gate_ws", BOOT, 1)
        t.expect(err).to.be_nil()
        t.expect(cid:find("%00", 1, true)).to_not.be_nil()
        t.expect(cid:find("%FF", 1, true)).to_not.be_nil()
        t.expect(connection_id.parse(cid).gate_node).to.equal(node)
    end)
end)

t.describe("connection_id.parse", function()
    local function bad(cid)
        local parsed, err = connection_id.parse(cid)
        t.expect(parsed).to.be_nil()
        t.expect(err).to.be_type("string")
    end

    t.it("rejects missing and extra fields", function()
        bad("v1|role1|.gate_ws|" .. BOOT)
        bad("v1|role1|.gate_ws|" .. BOOT .. "|1|extra")
        bad("|role1|.gate_ws|" .. BOOT .. "|1")
    end)

    t.it("rejects unknown or wrongly cased versions", function()
        bad("v2|role1|.gate_ws|" .. BOOT .. "|1")
        bad("V1|role1|.gate_ws|" .. BOOT .. "|1")
    end)

    t.it("rejects malformed boot_id and seq", function()
        bad("v1|role1|.gate_ws|" .. string.rep("A", 32) .. "|1")
        bad("v1|role1|.gate_ws|" .. BOOT .. "|01")
        bad("v1|role1|.gate_ws|" .. BOOT .. "|0")
        bad("v1|role1|.gate_ws|" .. BOOT .. "|abc")
        bad("v1|role1|.gate_ws|" .. BOOT .. "|-1")
        bad("v1|role1|.gate_ws|" .. BOOT .. "|" .. tostring(connection_id.MAX_SEQ + 1))
    end)

    t.it("rejects invalid and non-canonical percent escapes", function()
        bad("v1|role%|x|.gate_ws|" .. BOOT .. "|1")
        bad("v1|role%2|.gate_ws|" .. BOOT .. "|1")
        bad("v1|role%2g|.gate_ws|" .. BOOT .. "|1")
        bad("v1|role%7c|.gate_ws|" .. BOOT .. "|1")
        bad("v1|%41|.gate_ws|" .. BOOT .. "|1")
        bad("v1|role1|%2Egate_ws|" .. BOOT .. "|1")
    end)

    t.it("rejects non-string and overlong input", function()
        bad(nil)
        bad(123)
        bad("v1|" .. string.rep("a", 500) .. "|.gate_ws|" .. BOOT .. "|1")
    end)

    t.it("rejects decoded fields that are empty or overlong", function()
        bad("v1||.gate_ws|" .. BOOT .. "|1")
        bad("v1|role1||" .. BOOT .. "|1")
        bad("v1|" .. string.rep("a", 65) .. "|.gate_ws|" .. BOOT .. "|1")
        bad("v1|role1|" .. string.rep("b", 65) .. "|" .. BOOT .. "|1")
    end)

    t.it("rejects unescaped literals, incomplete escapes and overflowing seq", function()
        bad("v1|role 1|.gate_ws|" .. BOOT .. "|1")
        bad("v1|role%|.gate_ws|" .. BOOT .. "|1")
        bad("v1|role%2G|.gate_ws|" .. BOOT .. "|1")
        bad("v1|role1|.gate_ws|" .. BOOT .. "|00")
        bad("v1|role1|.gate_ws|" .. BOOT .. "|007")
        bad("v1|role1|.gate_ws|" .. BOOT .. "|" .. string.rep("9", 100))
    end)
end)

t.describe("connection_id.validate / equal", function()
    t.it("validates canonical identities", function()
        local cid = connection_id.new("gate1", ".gate_ws", BOOT, 3)
        t.expect(connection_id.validate(cid)).to.equal(true)
        t.expect(connection_id.validate("v1|%41|.gate_ws|" .. BOOT .. "|3")).to.equal(false)
        t.expect(connection_id.validate(nil)).to.equal(false)
    end)

    t.it("compares identities without normalizing", function()
        local a = connection_id.new("gate1", ".gate_ws", BOOT, 3)
        local b = connection_id.new("gate1", ".gate_ws", BOOT, 3)
        local c = connection_id.new("gate1", ".gate_ws", BOOT, 4)
        t.expect(connection_id.equal(a, b)).to.equal(true)
        t.expect(connection_id.equal(a, c)).to.equal(false)
        t.expect(connection_id.equal(a, "not-a-cid")).to.equal(false)
        t.expect(connection_id.equal(nil, nil)).to.equal(false)
        t.expect(connection_id.equal("bad", "bad")).to.equal(false)
    end)
end)
