local t = require "skytest"
local fingerprint = require "skyext.fingerprint"

-- 内容相关的假摘要：domain 与输入都混进去，固定 32 字节
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

local function entry(over)
    local e = {
        fingerprint_version = 1,
        name = "shop.buy",
        hash = fake_hash(fingerprint.DOMAIN, "seed"),
        pack = "PACK",
    }
    for k, v in pairs(over or {}) do
        e[k] = v
    end
    return e
end

t.describe("fingerprint.compute", function()
    t.it("returns a 32 byte digest deterministically", function()
        local a = fingerprint.compute("shop.buy", { item = 1 }, fake_hash)
        t.expect(a).to.be_type("string")
        t.expect(#a).to.equal(fingerprint.HASH_BYTES)
        t.expect(fingerprint.compute("shop.buy", { item = 1 }, fake_hash)).to.equal(a)
    end)

    t.it("changes when the protocol or the request changes", function()
        local base = fingerprint.compute("shop.buy", { item = 1 }, fake_hash)
        t.expect(fingerprint.compute("bag.use", { item = 1 }, fake_hash)).to_not.equal(base)
        t.expect(fingerprint.compute("shop.buy", { item = 2 }, fake_hash)).to_not.equal(base)
    end)

    t.it("changes when the domain changes", function()
        local base = fingerprint.compute("shop.buy", { item = 1 }, fake_hash)
        local saved = fingerprint.DOMAIN
        fingerprint.DOMAIN = saved .. ":alt"
        local alt = fingerprint.compute("shop.buy", { item = 1 }, fake_hash)
        fingerprint.DOMAIN = saved
        t.expect(alt).to_not.equal(base)
    end)

    t.it("is independent of table insertion order", function()
        local a = fingerprint.compute("shop.buy", { a = 1, b = 2 }, fake_hash)
        local b = fingerprint.compute("shop.buy", { b = 2, a = 1 }, fake_hash)
        t.expect(a).to.equal(b)
    end)

    t.it("passes the domain separation key to the hash function", function()
        local seen_domain, seen_input
        fingerprint.compute("shop.buy", {}, function(domain, input)
            seen_domain, seen_input = domain, input
            return string.rep("\0", 32)
        end)
        t.expect(seen_domain).to.equal(fingerprint.DOMAIN)
        t.expect(seen_input).to.be_type("string")
        t.expect(seen_input:sub(1, 2)).to.equal("F1")
    end)

    t.it("requires a hash function", function()
        local digest, err = fingerprint.compute("shop.buy", {}, nil)
        t.expect(digest).to.be_nil()
        t.expect(err).to.contain("hash")
    end)

    t.it("does not leak hash errors", function()
        local digest, err = fingerprint.compute("shop.buy", {}, function()
            error("SECRET_HMAC_KEY", 0)
        end)
        t.expect(digest).to.be_nil()
        t.expect(err).to.equal("hash failed")
    end)

    t.it("rejects a short or non-string digest", function()
        t.expect(fingerprint.compute("shop.buy", {}, function()
            return "short"
        end)).to
            .be_nil()
        t.expect(fingerprint.compute("shop.buy", {}, function()
            return 42
        end)).to
            .be_nil()
    end)

    t.it("propagates encoding errors", function()
        local digest, err = fingerprint.compute("shop.buy", 0 / 0, fake_hash)
        t.expect(digest).to.be_nil()
        t.expect(err).to.contain("non-finite")
    end)

    t.it("rejects an invalid protocol name", function()
        t.expect(fingerprint.compute("bad name", {}, fake_hash)).to.be_nil()
    end)
end)

t.describe("fingerprint entries", function()
    t.it("builds a cache entry carrying version, name, hash and pack", function()
        local e, err = fingerprint.new_entry("shop.buy", { item = 1 }, "PACK", fake_hash)
        t.expect(err).to.be_nil()
        t.expect(e.fingerprint_version).to.equal(fingerprint.VERSION)
        t.expect(e.name).to.equal("shop.buy")
        t.expect(e.pack).to.equal("PACK")
        t.expect(#e.hash).to.equal(fingerprint.HASH_BYTES)
    end)

    t.it("returns nil, err when hashing fails", function()
        t.expect(fingerprint.new_entry("shop.buy", {}, "PACK", nil)).to.be_nil()
    end)

    t.it("requires a string pack", function()
        t.expect(fingerprint.new_entry("shop.buy", {}, nil, fake_hash)).to.be_nil()
        t.expect(fingerprint.entry_from_digest(string.rep("\0", 32), "shop.buy", nil)).to.be_nil()
        t.expect(fingerprint.entry_from_digest("short", "shop.buy", "PACK")).to.be_nil()
        t.expect(fingerprint.entry_from_digest(string.rep("\0", 32), "", "PACK")).to.be_nil()
        t.expect(fingerprint.entry_from_digest(string.rep("\0", 32), "bad name", "PACK")).to.be_nil()
        t.expect(fingerprint.entry_from_digest(string.rep("\0", 32), string.rep("p", 129), "PACK")).to.be_nil()
    end)

    t.it("builds an entry from a precomputed digest", function()
        local digest = fingerprint.compute("shop.buy", { item = 1 }, fake_hash)
        local e = fingerprint.entry_from_digest(digest, "shop.buy", "PACK")
        t.expect(e.hash).to.equal(digest)
        t.expect(fingerprint.matches(e, "shop.buy", { item = 1 }, fake_hash)).to.equal(true)
    end)
end)

t.describe("fingerprint.matches", function()
    t.it("accepts a matching entry", function()
        local e = fingerprint.new_entry("shop.buy", { item = 1 }, "PACK", fake_hash)
        t.expect(fingerprint.matches(e, "shop.buy", { item = 1 }, fake_hash)).to.equal(true)
    end)

    t.it("reports a stale version with a typed kind", function()
        local good = fingerprint.new_entry("shop.buy", { item = 1 }, "PACK", fake_hash)
        local stale = {
            fingerprint_version = 2,
            name = good.name,
            hash = good.hash,
            pack = good.pack,
        }
        local ok, _, kind = fingerprint.matches(stale, "shop.buy", { item = 1 }, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.STALE_VERSION)
    end)

    t.it("reports a protocol mismatch with a typed kind", function()
        local good = fingerprint.new_entry("shop.buy", { item = 1 }, "PACK", fake_hash)
        local ok, _, kind = fingerprint.matches(good, "bag.use", { item = 1 }, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.PROTOCOL_MISMATCH)
    end)

    t.it("reports a missing or broken cached hash", function()
        local ok, _, kind = fingerprint.matches(
            { fingerprint_version = 1, name = "shop.buy" },
            "shop.buy",
            {},
            fake_hash
        )
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INVALID_HASH)

        ok, _, kind = fingerprint.matches(entry({ hash = "short" }), "shop.buy", {}, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INVALID_HASH)

        ok, _, kind = fingerprint.matches(nil, "shop.buy", {}, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.STALE_VERSION)

        -- 缺 hash 优先于协议冲突：旧条目要按 EXPIRED 处理
        ok, _, kind = fingerprint.matches({ fingerprint_version = 1, name = "shop.buy" }, "bag.use", {}, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INVALID_HASH)
    end)

    t.it("reports a different request as a mismatch", function()
        local good = fingerprint.new_entry("shop.buy", { item = 1 }, "PACK", fake_hash)
        local ok, _, kind = fingerprint.matches(good, "shop.buy", { item = 2 }, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.MISMATCH)
    end)

    t.it("rejects a tampered hash", function()
        local tampered = {
            fingerprint_version = 1,
            name = "shop.buy",
            hash = string.rep("\1", 32),
        }
        local ok, _, kind = fingerprint.matches(tampered, "shop.buy", { item = 1 }, fake_hash)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.MISMATCH)
    end)

    t.it("reports internal failures when hashing is unavailable", function()
        local good = fingerprint.new_entry("shop.buy", { item = 1 }, "PACK", fake_hash)

        local ok, _, kind = fingerprint.matches(good, "shop.buy", { item = 1 }, nil)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INTERNAL)

        ok, _, kind = fingerprint.matches(good, "shop.buy", { item = 1 }, function()
            error("boom", 0)
        end)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INTERNAL)

        ok, _, kind = fingerprint.matches(good, "shop.buy", { item = 1 }, function()
            return "short"
        end)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INTERNAL)
    end)

    t.it("guards the equality function", function()
        local good = fingerprint.new_entry("shop.buy", { item = 1 }, "PACK", fake_hash)

        local ok, _, kind = fingerprint.matches(good, "shop.buy", { item = 1 }, fake_hash, "eq")
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INTERNAL)

        ok, _, kind = fingerprint.matches(good, "shop.buy", { item = 1 }, fake_hash, function()
            error("boom", 0)
        end)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INTERNAL)

        ok, _, kind = fingerprint.matches(good, "shop.buy", { item = 1 }, fake_hash, function()
            return "yes"
        end)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INTERNAL)

        t.expect(fingerprint.matches(good, "shop.buy", { item = 1 }, fake_hash, function(a, b)
            return a == b
        end)).to
            .equal(true)
    end)
end)

-- 摘要已算好的路径（会话层 P03 用）：检查顺序必须与 matches 一致，
-- 条目不可用优先于语义冲突，比较函数异常按 INTERNAL 处理。
t.describe("fingerprint.matches_digest", function()
    local digest = string.rep("a", 32)
    local function entry(over)
        local e = { fingerprint_version = 1, name = "shop.buy", hash = digest, pack = "PACK" }
        for k, v in pairs(over or {}) do
            e[k] = v
        end
        return e
    end

    t.it("matches the same digest and rejects a different one", function()
        t.expect(fingerprint.matches_digest(entry(), "shop.buy", digest)).to.equal(true)
        local ok, _, kind = fingerprint.matches_digest(entry(), "shop.buy", string.rep("b", 32))
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.MISMATCH)
    end)

    t.it("reports an unusable entry before a protocol mismatch", function()
        local ok, _, kind = fingerprint.matches_digest(entry({ fingerprint_version = 0 }), "other.req", digest)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.STALE_VERSION)

        local _, _, hash_kind = fingerprint.matches_digest(entry({ hash = "short" }), "other.req", digest)
        t.expect(hash_kind).to.equal(fingerprint.KIND.INVALID_HASH)
    end)

    t.it("reports a protocol mismatch without comparing the digest", function()
        local ok, _, kind = fingerprint.matches_digest(entry(), "other.req", digest)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.PROTOCOL_MISMATCH)
    end)

    t.it("treats a broken compare function as an internal fault", function()
        local ok, _, kind = fingerprint.matches_digest(entry(), "shop.buy", digest, function()
            error("boom")
        end)
        t.expect(ok).to.equal(false)
        t.expect(kind).to.equal(fingerprint.KIND.INTERNAL)

        local _, _, bool_kind = fingerprint.matches_digest(entry(), "shop.buy", digest, function()
            return "yes"
        end)
        t.expect(bool_kind).to.equal(fingerprint.KIND.INTERNAL)
    end)
end)
