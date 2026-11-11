local t = require "skytest"
local c = require "skyext.canonical_lua"

t.describe("canonical_lua scalars", function()
    t.it("encodes nil, booleans, integers and strings", function()
        t.expect(c.encode(nil)).to.equal("N")
        t.expect(c.encode(true)).to.equal("B1")
        t.expect(c.encode(false)).to.equal("B0")
        t.expect(c.encode(42)).to.equal("I2:42")
        t.expect(c.encode(-7)).to.equal("I2:-7")
        t.expect(c.encode(0)).to.equal("I1:0")
        t.expect(c.encode("hi")).to.equal("S2:hi")
        t.expect(c.encode("")).to.equal("S0:")
    end)

    t.it("normalizes integral floats to integer encoding", function()
        t.expect(c.encode(2.0)).to.equal(c.encode(2))
        t.expect(c.encode(-0.0)).to.equal(c.encode(0))
        t.expect(c.encode(2.0)).to.equal("I1:2")
    end)

    t.it("encodes non-integral floats as big-endian doubles", function()
        t.expect(c.encode(1.5)).to.equal("F" .. string.pack(">d", 1.5))
        t.expect(c.encode(-2.25)).to.equal("F" .. string.pack(">d", -2.25))
        t.expect(c.encode(1.5)).to_not.equal(c.encode(1.25))
    end)

    t.it("keeps binary strings byte-exact", function()
        local s = "a\0b\255"
        t.expect(c.encode(s)).to.equal("S4:" .. s)
    end)

    t.it("rejects NaN and infinities", function()
        t.expect(c.encode(0 / 0)).to.be_nil()
        t.expect(c.encode(math.huge)).to.be_nil()
        t.expect(c.encode(-math.huge)).to.be_nil()
    end)
end)

t.describe("canonical_lua injectivity", function()
    t.it("distinguishes frame-shaped strings from real frames", function()
        t.expect(c.encode({ "" })).to_not.equal(c.encode({ "S0:" }))
        t.expect(c.encode({ 1 })).to_not.equal(c.encode({ "I1:1" }))
        t.expect(c.encode({})).to_not.equal(c.encode({ "T0:" }))
        t.expect(c.encode("")).to_not.equal(c.encode({}))
    end)

    t.it("distinguishes nil, empty table and empty string", function()
        t.expect(c.encode(nil)).to_not.equal(c.encode({}))
        t.expect(c.encode({})).to_not.equal(c.encode(""))
    end)
end)

t.describe("canonical_lua tables", function()
    t.it("encodes empty and array tables with explicit count", function()
        t.expect(c.encode({})).to.equal("T0:")
        t.expect(c.encode({ "a", "b" })).to.equal("T2:I1:1S1:aI1:2S1:b")
    end)

    t.it("does not depend on insertion order", function()
        local a = {}
        a.b = 2
        a.a = 1
        a[10] = "ten"
        a[2] = "two"

        local b = {}
        b[2] = "two"
        b.a = 1
        b[10] = "ten"
        b.b = 2

        t.expect(c.encode(a)).to.equal(c.encode(b))
    end)

    t.it("orders keys by type rank then value", function()
        local out = c.encode({ [true] = "t", [false] = "f", ["1"] = "s", [1] = "n" })
        local bool_false = out:find("B0", 1, true)
        local bool_true = out:find("B1", 1, true)
        local number_one = out:find("I1:1", 1, true)
        local string_one = out:find("S1:1", 1, true)
        t.expect(bool_false).to.be_lt(bool_true) -- boolean 组内 false < true
        t.expect(bool_true).to.be_lt(number_one) -- boolean < number
        t.expect(number_one).to.be_lt(string_one) -- number < string
    end)

    t.it("sorts integers numerically", function()
        local out = c.encode({ [10] = true, [2] = true })
        t.expect(out:find("I1:2", 1, true)).to.be_lt(out:find("I2:10", 1, true))
    end)

    t.it("keeps numeric 1 distinct from string 1", function()
        t.expect(c.encode({ [1] = "x" })).to_not.equal(c.encode({ ["1"] = "x" }))
    end)

    t.it("encodes nested tables deterministically", function()
        local a = { aa = { bb = { 1, 2 } }, cc = true }
        local b = { cc = true, aa = { bb = { 1, 2 } } }
        t.expect(c.encode(a)).to.equal(c.encode(b))
    end)

    t.it("allows the same subtable in sibling positions", function()
        local shared = { 1 }
        t.expect(c.encode({ shared, shared })).to.equal(c.encode({ { 1 }, { 1 } }))
    end)

    t.it("is stable across many insertion orders", function()
        local keys = { "a", "b", "c", "d", "e" }
        local ref
        for seed = 1, 1000 do
            local v = {}
            for i = 1, #keys do
                local idx = (seed + i * 7) % #keys + 1
                v[keys[idx]] = keys[idx]
            end
            local out = c.encode(v)
            ref = ref or out
            t.expect(out).to.equal(ref)
        end
    end)
end)

t.describe("canonical_lua rejects unsupported input", function()
    t.it("rejects functions, coroutines and userdata", function()
        local out, err = c.encode(function() end)
        t.expect(out).to.be_nil()
        t.expect(err).to.contain("function")

        t.expect(c.encode(coroutine.create(function() end))).to.be_nil()
        t.expect(c.encode(io.stdout)).to.be_nil()
    end)

    t.it("rejects tables with a metatable", function()
        local out, err = c.encode(setmetatable({}, { __index = {} }))
        t.expect(out).to.be_nil()
        t.expect(err).to.contain("metatable")
    end)

    t.it("rejects protected metatables and nested ones", function()
        local protected = setmetatable({}, { __metatable = "locked" })
        t.expect(c.encode(protected)).to.be_nil()
        t.expect(c.encode({ nested = protected })).to.be_nil()
    end)

    t.it("rejects cycles", function()
        local v = {}
        v.self = v
        local out, err = c.encode(v)
        t.expect(out).to.be_nil()
        t.expect(err).to.contain("cycle")
    end)

    t.it("rejects table keys", function()
        local out, err = c.encode({ [{}] = 1 })
        t.expect(out).to.be_nil()
        t.expect(err).to.contain("key")
    end)

    t.it("rejects over-depth input", function()
        local deep = {}
        local cur = deep
        for _ = 1, c.MAX_DEPTH do
            local nxt = {}
            cur.n = nxt
            cur = nxt
        end
        local out, err = c.encode(deep)
        t.expect(out).to.be_nil()
        t.expect(err).to.contain("depth")
    end)

    t.it("rejects over-node input", function()
        local wide = {}
        for i = 1, c.MAX_NODES do
            wide[i] = true
        end
        local out, err = c.encode(wide)
        t.expect(out).to.be_nil()
        t.expect(err).to.contain("node")
    end)

    t.it("rejects over-byte input", function()
        local out, err = c.encode(string.rep("x", c.MAX_BYTES + 1))
        t.expect(out).to.be_nil()
        t.expect(err).to.contain("bytes")
    end)
end)

t.describe("canonical_lua request framing", function()
    t.it("prefixes the version domain and protocol name", function()
        local out = c.encode_request("shop.buy", { item = 1 })
        t.expect(out:sub(1, 2)).to.equal("F1")
        t.expect(out:find("8:shop.buy", 1, true)).to_not.be_nil()
        t.expect(c.encode_request("shop.buy", { item = 1 })).to.equal(out)
    end)

    t.it("separates protocol domains", function()
        t.expect(c.encode_request("shop.buy", {})).to_not.equal(c.encode_request("bag.use", {}))
    end)

    t.it("rejects invalid protocol names", function()
        t.expect(c.encode_request("", {})).to.be_nil()
        t.expect(c.encode_request(nil, {})).to.be_nil()
        t.expect(c.encode_request(123, {})).to.be_nil()
        t.expect(c.encode_request(string.rep("p", c.MAX_PROTOCOL_LEN + 1), {})).to.be_nil()
        t.expect(c.encode_request("shop buy", {})).to.be_nil()
        t.expect(c.encode_request("shop:buy", {})).to.be_nil()
        t.expect(c.encode_request("商店", {})).to.be_nil()
    end)

    t.it("accepts a protocol name at the length limit", function()
        t.expect(c.encode_request(string.rep("p", c.MAX_PROTOCOL_LEN), {})).to_not.be_nil()
    end)

    t.it("propagates value errors", function()
        local out, err = c.encode_request("shop.buy", 0 / 0)
        t.expect(out).to.be_nil()
        t.expect(err).to.contain("non-finite")
    end)
end)

t.describe("canonical_lua limits at the boundary", function()
    t.it("accepts the deepest allowed table and rejects one more level", function()
        local function nest(levels)
            local root = {}
            local cur = root
            for _ = 1, levels do
                local nxt = {}
                cur.n = nxt
                cur = nxt
            end
            return root
        end
        -- 根是第 1 层，所以 MAX_DEPTH-1 个嵌套恰好到限
        t.expect(c.encode(nest(c.MAX_DEPTH - 1))).to_not.be_nil()
        t.expect(c.encode(nest(c.MAX_DEPTH))).to.be_nil()
    end)

    t.it("accepts 8191 pairs and rejects 8192", function()
        local function wide(n)
            local v = {}
            for i = 1, n do
                v[i] = true
            end
            return v
        end
        -- 节点 = 1(表) + 2*对数；1+2*8191 <= 16384，1+2*8192 > 16384
        t.expect(c.encode(wide(8191))).to_not.be_nil()
        t.expect(c.encode(wide(8192))).to.be_nil()
    end)

    t.it("accepts a string exactly at the byte limit", function()
        local payload = string.rep("x", c.MAX_BYTES - 8)
        local out = c.encode(payload)
        t.expect(out).to_not.be_nil()
        t.expect(#out).to.equal(c.MAX_BYTES)
        t.expect(c.encode(payload .. "x")).to.be_nil()
    end)

    t.it("counts shared subtables toward the node limit", function()
        local shared = { 1 }
        local v = {}
        for i = 1, 5000 do
            v[i] = shared
        end
        local out, err = c.encode(v)
        t.expect(out).to.be_nil()
        t.expect(err).to.contain("node")
    end)

    t.it("leaves no state behind after a failure", function()
        t.expect(c.encode(string.rep("x", c.MAX_BYTES + 1))).to.be_nil()
        t.expect(c.encode({ ok = true })).to_not.be_nil()
    end)
end)

t.describe("canonical_lua numeric edges", function()
    t.it("encodes integer extremes and large floats deterministically", function()
        local values = {
            math.maxinteger,
            math.mininteger,
            2.0 ^ 63,
            -(2.0 ^ 63),
            5e-324,
            1e308,
        }
        for _, v in ipairs(values) do
            local first = c.encode(v)
            t.expect(first).to_not.be_nil()
            t.expect(c.encode(v)).to.equal(first)
        end
        t.expect(c.encode(math.maxinteger):sub(1, 1)).to.equal("I")
        t.expect(c.encode(2.0 ^ 63):sub(1, 1)).to.equal("F")
    end)

    t.it("orders float keys among numeric keys", function()
        local out = c.encode({ [1.5] = "a", [1] = "b", [-2.5] = "c" })
        t.expect(out:find("F", 1, true)).to.be_lt(out:find("I1:1", 1, true))
    end)
end)
