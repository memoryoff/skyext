-- P00 接口基座的跨模块验收：连接身份、请求指纹、经济授权三条链在同一进程内串起来。
-- 这里不启动 skynet，只验证纯 Lua 合同之间的衔接，真实的 sproto/Mongo/crypto 行为
-- 仍由 P00-A/B/C 探针和后续集成测试覆盖。
local t = require "skytest"
local canonical = require "skyext.canonical_lua"
local connection_id = require "skyext.connection_id"
local fingerprint = require "skyext.fingerprint"
local grant = require "skyext.grant"

local BOOT = "0123456789abcdef0123456789abcdef"
local GRANT_ID = "fedcba9876543210fedcba9876543210"

local function fake_hash(domain, input)
    local h = 0
    for i = 1, #domain do
        h = (h * 131 + domain:byte(i)) % 4294967291
    end
    for i = 1, #input do
        h = (h * 131 + input:byte(i)) % 4294967291
    end
    return string.pack(">I4", h) .. string.rep("\0", 28)
end

local function fake_hmac(key_id, input)
    local h = 0
    for i = 1, #input do
        h = (h * 131 + input:byte(i)) % 1000000007
    end
    return string.format("mac:%s:%d", key_id, h)
end

local function grant_fields(over)
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

t.describe("p00 connection identity chain", function()
    t.it("keeps the same fd on different gateways apart", function()
        local a = connection_id.new("gate1", ".gate_ws", BOOT, 9)
        local b = connection_id.new("gate2", ".gate_ws", BOOT, 9)
        local c = connection_id.new("gate1", ".gate_tcp", BOOT, 9)
        t.expect(connection_id.equal(a, a)).to.equal(true)
        t.expect(connection_id.equal(a, b)).to.equal(false)
        t.expect(connection_id.equal(a, c)).to.equal(false)
        t.expect(connection_id.validate(a)).to.equal(true)
        t.expect(connection_id.parse(a).local_seq).to.equal(9)
    end)
end)

t.describe("p00 request fingerprint chain", function()
    t.it("answers a retransmission from the cached digest", function()
        local request = { item_id = 7, count = 1 }
        local digest = fingerprint.compute("shop.buy", request, fake_hash)
        local entry = fingerprint.entry_from_digest(digest, "shop.buy", "PACK")

        t.expect(fingerprint.matches(entry, "shop.buy", { count = 1, item_id = 7 }, fake_hash))
            .to.equal(true)
        t.expect(fingerprint.matches(entry, "shop.buy", { item_id = 7, count = 2 }, fake_hash))
            .to.equal(false)
    end)

    t.it("distinguishes a changed parameter from a stale entry", function()
        local entry = fingerprint.new_entry("shop.buy", { item_id = 7 }, "PACK", fake_hash)

        local ok, _, kind = fingerprint.matches(entry, "shop.buy", { item_id = 8 }, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.MISMATCH)

        ok, _, kind = fingerprint.matches(entry, "bag.use", { item_id = 7 }, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.PROTOCOL_MISMATCH)
    end)
end)

t.describe("p00 economic grant chain", function()
    t.it("derives a canonical op_id and verifies the signed grant", function()
        local op_id = grant.op_id(GRANT_ID, 10)
        t.expect(op_id).to.equal(GRANT_ID .. "_000a")
        t.expect(grant.parse_op_id(op_id)).to.equal({ grant_id = GRANT_ID, seq = 10 })

        local mac = grant.sign(grant_fields(), fake_hmac)
        local full = grant_fields({ mac = mac })
        t.expect(grant.verify(full, mac, fake_hmac)).to.equal(true)
        t.expect(grant.verify(grant_fields({ rid = 2002, mac = mac }), mac, fake_hmac)).to.equal(false)
    end)

    t.it("never accepts an out-of-range seq", function()
        t.expect(grant.op_id(GRANT_ID, grant.MAX_SEQ)).to.equal(GRANT_ID .. "_ffff")
        t.expect(grant.op_id(GRANT_ID, grant.MAX_SEQ + 1)).to.be_nil()
    end)
end)

t.describe("p00 domain separation", function()
    t.it("uses different domains for fingerprints and grants", function()
        local fp_input
        fingerprint.compute("shop.buy", {}, function(_, input)
            fp_input = input
            return string.rep("\0", 32)
        end)
        local grant_input = grant.canonical_fields(grant_fields())

        t.expect(fingerprint.DOMAIN).to_not.equal(grant.SIGNING_DOMAIN)
        t.expect(fp_input:sub(1, 2)).to.equal("F1")
        t.expect(grant_input:sub(1, 2)).to.equal("G1")
    end)

    t.it("does not accept a grant-domain digest as a fingerprint", function()
        local grant_input = grant.canonical_fields(grant_fields())
        local fake_digest = grant_input:sub(1, fingerprint.HASH_BYTES)
        local e = fingerprint.entry_from_digest(fake_digest, "shop.buy", "PACK")
        local ok, _, kind = fingerprint.matches(e, "shop.buy", {}, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.MISMATCH)
    end)

    t.it("keeps pack a string so cache eviction can read its length", function()
        local e = fingerprint.new_entry("shop.buy", {}, "PACK", fake_hash)
        t.expect(type(e.pack)).to.equal("string")
        t.expect(#e.pack).to.equal(4)
    end)
end)

t.describe("p00 frozen constants", function()
    t.it("pins the constants the contracts depend on", function()
        t.expect(connection_id.MAX_CID_LEN).to.equal(438)
        t.expect(connection_id.MAX_SEQ).to.equal(9007199254740991)
        t.expect(grant.MAX_SEQ).to.equal(65535)
        t.expect(canonical.ENCODING_DOMAIN).to.equal("F1")
        t.expect(grant.SIGNING_DOMAIN).to.equal("G1")
        t.expect(fingerprint.VERSION).to.equal(1)
        t.expect(fingerprint.HASH_BYTES).to.equal(32)
    end)
end)
