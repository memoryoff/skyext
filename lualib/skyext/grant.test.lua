local t = require "skytest"
local grant = require "skyext.grant"

local GRANT_ID = "0123456789abcdef0123456789abcdef"

local function fields(over)
    local f = {
        version = 1,
        rid = 1001,
        grant_id = GRANT_ID,
        issued_at = 1700000000,
        expires_at = 1700086400,
        max_seq = 256,
        key_id = "k1",
    }
    for k, v in pairs(over or {}) do
        f[k] = v
    end
    return f
end

-- 测试替身必须依赖输入内容，否则"改字段但长度不变"会假通过
local function fake_hmac(key_id, input)
    local h = 0
    for i = 1, #input do
        h = (h * 31 + input:byte(i)) % 1000000007
    end
    return string.format("mac:%s:%d", key_id, h)
end

t.describe("grant.new_grant_id", function()
    t.it("returns 32 lowercase hex characters", function()
        local id = grant.new_grant_id(function()
            return string.rep("\171", 16)
        end)
        t.expect(id).to.equal(string.rep("ab", 16))
    end)

    t.it("rejects a short, non-string or throwing source without leaking", function()
        local id, err = grant.new_grant_id(function()
            return "short"
        end)
        t.expect(id).to.be_nil()
        t.expect(err).to.be_type("string")

        t.expect(grant.new_grant_id(function()
            return 42
        end)).to.be_nil()

        local id2, err2 = grant.new_grant_id(function()
            error("SECRET_GRANT_BYTES", 0)
        end)
        t.expect(id2).to.be_nil()
        t.expect(err2).to.equal("rng failed")
    end)

    t.it("reports rng unavailability when crypto is missing", function()
        local saved_preload, saved_loaded = package.preload["crypto"], package.loaded["crypto"]
        package.loaded["crypto"] = nil
        package.preload["crypto"] = function()
            error("crypto is not built", 0)
        end
        local id, err = grant.new_grant_id()
        package.loaded["crypto"] = saved_loaded
        package.preload["crypto"] = saved_preload
        t.expect(id).to.be_nil()
        t.expect(err).to.equal("rng unavailable")
    end)
end)

t.describe("grant.four_digit_hex", function()
    t.it("formats 1..65535 as four lowercase hex digits", function()
        t.expect(grant.four_digit_hex(1)).to.equal("0001")
        t.expect(grant.four_digit_hex(10)).to.equal("000a")
        t.expect(grant.four_digit_hex(0xFFFF)).to.equal("ffff")
    end)

    t.it("rejects out-of-range and non-integer seq", function()
        t.expect(grant.four_digit_hex(0)).to.be_nil()
        t.expect(grant.four_digit_hex(-1)).to.be_nil()
        t.expect(grant.four_digit_hex(grant.MAX_SEQ + 1)).to.be_nil()
        t.expect(grant.four_digit_hex(1.5)).to.be_nil()
        t.expect(grant.four_digit_hex(7.0)).to.be_nil()
        t.expect(grant.four_digit_hex("1")).to.be_nil()
        t.expect(grant.four_digit_hex(nil)).to.be_nil()
        t.expect(grant.four_digit_hex(math.maxinteger)).to.be_nil()
        t.expect(grant.four_digit_hex(math.mininteger)).to.be_nil()
    end)
end)

t.describe("grant.op_id", function()
    t.it("joins grant_id and the four digit seq", function()
        t.expect(grant.op_id(GRANT_ID, 10)).to.equal(GRANT_ID .. "_000a")
        t.expect(grant.op_id(GRANT_ID, 1)).to.equal(GRANT_ID .. "_0001")
        local top = grant.op_id(GRANT_ID, grant.MAX_SEQ)
        t.expect(top).to.equal(GRANT_ID .. "_ffff")
        t.expect(#top).to.equal(37)
    end)

    t.it("rejects invalid grant_id or seq", function()
        t.expect(grant.op_id(string.rep("A", 32), 1)).to.be_nil()
        t.expect(grant.op_id(string.rep("a", 31), 1)).to.be_nil()
        t.expect(grant.op_id(GRANT_ID, 0)).to.be_nil()
        t.expect(grant.op_id(GRANT_ID, grant.MAX_SEQ + 1)).to.be_nil()
    end)
end)

t.describe("grant.parse_op_id", function()
    t.it("round-trips a canonical op_id", function()
        local id = grant.op_id(GRANT_ID, 0x00AB)
        t.expect(grant.parse_op_id(id)).to.equal({ grant_id = GRANT_ID, seq = 0x00AB })
        local top = grant.op_id(GRANT_ID, grant.MAX_SEQ)
        t.expect(grant.parse_op_id(top).seq).to.equal(grant.MAX_SEQ)
    end)

    t.it("rejects non-canonical and malformed ids", function()
        local function bad(v)
            local parsed, err = grant.parse_op_id(v)
            t.expect(parsed).to.be_nil()
            t.expect(err).to.be_type("string")
        end

        bad(GRANT_ID .. "_000A") -- 大写
        bad(GRANT_ID .. "_0000") -- seq 0
        bad(GRANT_ID .. "_00001") -- 5 位
        bad(GRANT_ID .. "_1") -- 1 位
        bad(GRANT_ID) -- 无分隔
        bad(GRANT_ID .. "_000a_extra")
        bad("$" .. GRANT_ID .. "_000a")
        bad(GRANT_ID .. "._000a")
        bad(nil)
        bad(123)
    end)

    t.it("rejects an id with NUL or dot", function()
        t.expect(grant.parse_op_id(GRANT_ID .. "_000a\0")).to.be_nil()
        t.expect(grant.parse_op_id(GRANT_ID .. "_00.0")).to.be_nil()
    end)
end)

t.describe("grant.validate_grant_id", function()
    t.it("accepts canonical ids and rejects everything else", function()
        t.expect(grant.validate_grant_id(GRANT_ID)).to.equal(true)
        t.expect(grant.validate_grant_id(string.rep("A", 32))).to.equal(false)
        t.expect(grant.validate_grant_id(string.rep("a", 33))).to.equal(false)
        t.expect(grant.validate_grant_id(nil)).to.equal(false)
    end)
end)

t.describe("grant.canonical_fields", function()
    t.it("returns bytes for a complete field set", function()
        local a = grant.canonical_fields(fields())
        t.expect(a).to.be_type("string")
        t.expect(#a).to.be_gt(0)
    end)

    t.it("produces the same bytes for reordered fields", function()
        local a = grant.canonical_fields(fields())
        local b = grant.canonical_fields({
            key_id = "k1",
            max_seq = 256,
            expires_at = 1700086400,
            issued_at = 1700000000,
            grant_id = GRANT_ID,
            rid = 1001,
            version = 1,
        })
        t.expect(a).to.equal(b)
    end)

    t.it("changes bytes when any field changes", function()
        local base = grant.canonical_fields(fields())
        t.expect(grant.canonical_fields(fields({ rid = 1002 }))).to_not.equal(base)
        t.expect(grant.canonical_fields(fields({ max_seq = 255 }))).to_not.equal(base)
        t.expect(grant.canonical_fields(fields({ key_id = "k2" }))).to_not.equal(base)
        t.expect(grant.canonical_fields(fields({ expires_at = 1700086401 }))).to_not.equal(base)
    end)

    t.it("normalizes an integral float version", function()
        t.expect(grant.canonical_fields(fields({ version = 1.0 }))).to.equal(grant.canonical_fields(fields()))
    end)

    t.it("rejects missing or mistyped fields", function()
        t.expect(grant.canonical_fields(fields({ version = 2 }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ version = 1.5 }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ rid = 0 }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ rid = "1001" }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ grant_id = string.rep("A", 32) }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ issued_at = 1.5 }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ expires_at = 1700000000 }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ expires_at = 1699999999 }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ max_seq = 0 }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ max_seq = 65536 }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ key_id = "" }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ key_id = "bad key" }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ key_id = string.rep("k", 65) }))).to.be_nil()
        t.expect(grant.canonical_fields(fields({ extra = true }))).to.be_nil()
    end)

    t.it("accepts a full grant table that includes mac", function()
        local with_mac = fields({ mac = "anything" })
        t.expect(grant.canonical_fields(with_mac)).to.equal(grant.canonical_fields(fields()))
        local signed = grant.sign(with_mac, fake_hmac)
        t.expect(grant.verify(with_mac, signed, fake_hmac)).to.equal(true)
    end)

    t.it("normalizes integral floats for every numeric field", function()
        local base = grant.canonical_fields(fields())
        t.expect(grant.canonical_fields(fields({ rid = 1001.0 }))).to.equal(base)
        t.expect(grant.canonical_fields(fields({ issued_at = 1700000000.0 }))).to.equal(base)
        t.expect(grant.canonical_fields(fields({ max_seq = 256.0 }))).to.equal(base)
    end)

    t.it("rejects metatables and injected fields", function()
        local injected = setmetatable({}, { __index = fields() })
        t.expect(grant.canonical_fields(injected)).to.be_nil()
        t.expect(grant.canonical_fields(setmetatable(fields(), { __metatable = false }))).to.be_nil()
        t.expect(grant.canonical_fields(setmetatable(fields(), {}))).to.be_nil()
    end)

    t.it("rejects negative issued_at and keeps field errors bounded", function()
        t.expect(grant.canonical_fields(fields({ issued_at = -1 }))).to.be_nil()
        local out, err = grant.canonical_fields(fields({ [string.rep("k", 1000)] = true }))
        t.expect(out).to.be_nil()
        t.expect(#err).to.be_lt(200)
        t.expect(grant.canonical_fields(fields({ [1] = true }))).to.be_nil()
    end)
end)

t.describe("grant.sign / verify", function()
    t.it("signs canonical fields with the injected hmac", function()
        local mac = grant.sign(fields(), fake_hmac)
        t.expect(mac).to.equal(fake_hmac("k1", grant.canonical_fields(fields())))
    end)

    t.it("requires an hmac function", function()
        local mac, err = grant.sign(fields(), nil)
        t.expect(mac).to.be_nil()
        t.expect(err).to.contain("hmac")
    end)

    t.it("does not leak hmac errors", function()
        local mac, err = grant.sign(fields(), function()
            error("SECRET_KEY_MATERIAL", 0)
        end)
        t.expect(mac).to.be_nil()
        t.expect(err).to.equal("hmac failed")
    end)

    t.it("rejects an empty mac from hmac_fn", function()
        t.expect(grant.sign(fields(), function()
            return ""
        end)).to.be_nil()
    end)

    t.it("verifies a matching mac and rejects a tampered one", function()
        local mac = grant.sign(fields(), fake_hmac)
        t.expect(grant.verify(fields(), mac, fake_hmac)).to.equal(true)
        t.expect(grant.verify(fields({ rid = 1002 }), mac, fake_hmac)).to.equal(false)
        t.expect(grant.verify(fields(), "wrong", fake_hmac)).to.equal(false)
        t.expect(grant.verify(fields(), "", fake_hmac)).to.equal(false)
    end)

    t.it("uses the injected comparison for equality", function()
        local mac = grant.sign(fields(), fake_hmac)
        local called = false
        local ok = grant.verify(fields(), mac, fake_hmac, function(a, b)
            called = true
            return a == b
        end)
        t.expect(ok).to.equal(true)
        t.expect(called).to.equal(true)
    end)

    t.it("rejects a tampered field for every signed field", function()
        local mac = grant.sign(fields(), fake_hmac)
        local tampered = {
            { rid = 1002 },
            { grant_id = string.rep("f", 32) },
            { issued_at = 1700000001 },
            { expires_at = 1700086401 },
            { max_seq = 255 },
            { key_id = "k2" },
        }
        for _, over in ipairs(tampered) do
            t.expect(grant.verify(fields(over), mac, fake_hmac)).to.equal(false)
        end
    end)

    t.it("rejects a non-string or missing mac from hmac_fn", function()
        t.expect(grant.sign(fields(), function()
            return 42
        end)).to.be_nil()
        t.expect(grant.sign(fields(), function()
            return true
        end)).to.be_nil()
        t.expect(grant.sign(fields(), function()
            return nil
        end)).to.be_nil()
        t.expect(grant.sign(fields(), function()
            return "a", "b"
        end)).to.equal("a")
    end)

    t.it("guards the equality function", function()
        local mac = grant.sign(fields(), fake_hmac)
        t.expect(grant.verify(fields(), mac, fake_hmac, "eq")).to.equal(false)
        t.expect(grant.verify(fields(), mac, fake_hmac, function()
            error("boom", 0)
        end)).to.equal(false)
        t.expect(grant.verify(fields(), mac, fake_hmac, function()
            return "yes"
        end)).to.equal(false)
    end)

    t.it("reports a missing hmac function through verify", function()
        local ok, err = grant.verify(fields(), "mac", nil)
        t.expect(ok).to.equal(false)
        t.expect(err).to.contain("hmac")
    end)
end)
