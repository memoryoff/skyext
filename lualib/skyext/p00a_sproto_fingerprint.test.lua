-- P00-A 运行时探针：Sproto 解码语义 + canonical_lua_v1 稳定性 + crypto HMAC 固定向量。
--
-- 这个文件回答三个问题，任一不成立 P03 都不能开工：
--   1. 真实 sproto 解码出来的表，规范化后是不是"同语义同输出、异语义不同输出"；
--   2. 解码器补零/缺省/空容器的实际表现，是否会让两个不同请求撞成同一摘要；
--   3. `crypto.hmac_sha256(key, msg)` 的参数顺序、输出长度和固定向量是否正确。
--
-- 用的是仓库里真实的 skynet/lualib/sproto.lua 与 luaclib/crypto.so，不是桩。
local t = require "skytest"
local sproto = require "sproto"
local crypto = require "crypto"
local canonical = require "skyext.canonical_lua"
local fingerprint = require "skyext.fingerprint"

local SCHEMA = [[
.kv {
  k 0 : string
  v 1 : integer
}
.bar {
  id 0 : integer
  ratio 1 : double
  flag 2 : boolean
  blob 3 : string
  big 4 : integer
}
.foo {
  name 0 : string
  tags 1 : *string
  attrs 2 : *kv(k)
}
probe_req 900 {
  request {
    name 0 : string
    count 1 : integer
    ratio 2 : double
    nested 3 : foo
    items 4 : *bar
    attrs 5 : *kv(k)
    alias 6 : string
  }
  response { ok 0 : boolean }
}
]]

local sp = sproto.parse(SCHEMA)

local function decode(args)
    local bytes = sp:request_encode("probe_req", args)
    return sp:request_decode("probe_req", bytes)
end

-- 确定性 LCG，避免依赖 math.random 的全局状态；同一 seed 在每次运行得到同一排列
local function lcg(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return (state % n) + 1
    end
end

local function shuffled(list, rand)
    local out = {}
    for i = 1, #list do
        out[i] = list[i]
    end
    for i = #out, 2, -1 do
        local j = rand(i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

-- 同语义、不同插入顺序的请求（解码后的形状：map 是 key 索引的表）。
-- 字段与 map 条目的写入顺序都由 seed 决定，确保"稳定"不是碰巧。
local function sample(seed)
    local rand = lcg(seed)
    local attrs = {}
    local entries = { { "k1", 7 }, { "k2", 8 }, { "k3", -9 }, { "k4", 10 }, { "k5", -11 }, { "k6", 12 } }
    for _, e in ipairs(shuffled(entries, rand)) do
        attrs[e[1]] = e[2]
    end
    local fields = {
        name = "alice",
        count = -42,
        ratio = 1.5,
        nested = { name = "n", tags = { "a", "b" }, attrs = attrs },
        items = {
            { id = 1, ratio = 2.5, flag = true, blob = "\0\1\2", big = 9007199254740991 },
            { id = 2, ratio = -0.25, flag = false, blob = "x", big = -9007199254740991 },
        },
        attrs = attrs,
        alias = "alice",
    }
    local keys = { "name", "count", "ratio", "nested", "items", "attrs", "alias" }
    local out = {}
    for _, k in ipairs(shuffled(keys, rand)) do
        out[k] = fields[k]
    end
    return out
end

-- sproto 的 wire 形状：map 字段编码时是 {k=,v=} 数组。
-- 数组顺序由 seed 打乱——解码器按 wire 顺序插入 Lua 表，这样每次得到的解码表
-- 内部布局都不同，稳定性测试才真正覆盖"真实解码结果"而不是同一张构造表。
local function to_wire(t, seed)
    local rand = lcg(seed * 7 + 1)
    local function map_to_array(map)
        local arr = {}
        for k, v in pairs(map) do
            arr[#arr + 1] = { k = k, v = v }
        end
        return shuffled(arr, rand)
    end
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    out.attrs = map_to_array(t.attrs)
    out.nested = { name = t.nested.name, tags = t.nested.tags, attrs = map_to_array(t.nested.attrs) }
    return out
end

local function map_to_array(map)
    local arr = {}
    for k, v in pairs(map) do
        arr[#arr + 1] = { k = k, v = v }
    end
    table.sort(arr, function(a, b)
        return a.k < b.k
    end)
    return arr
end

t.describe("P00-A sproto decode semantics", function()
    t.it("decodes nested structs, keyed maps, arrays, binary strings and 64-bit integers", function()
        local decoded = decode({
            name = "alice",
            count = -42,
            ratio = 1.5,
            nested = { name = "n", tags = { "a", "b" }, attrs = map_to_array({ x = 1, y = 2 }) },
            items = { { id = 1, ratio = 2.5, flag = true, blob = "\0\1\2", big = 9007199254740991 } },
            attrs = map_to_array({ k1 = 7, k2 = 8 }),
        })

        t.expect(decoded.name).to.equal("alice")
        t.expect(decoded.count).to.equal(-42)
        t.expect(decoded.ratio).to.equal(1.5)
        t.expect(decoded.nested.name).to.equal("n")
        t.expect(decoded.nested.tags).to.equal({ "a", "b" })
        t.expect(decoded.nested.attrs.x.v).to.equal(1)
        t.expect(decoded.items[1].big).to.equal(9007199254740991)
        t.expect(decoded.items[1].blob).to.equal("\0\1\2")
        t.expect(decoded.attrs.k1.v).to.equal(7)
        t.expect(decoded.attrs.k2.v).to.equal(8)
    end)

    t.it("leaves absent optional fields absent instead of inventing zero values", function()
        local decoded = decode({ name = "" })
        t.expect(decoded.name).to.equal("")
        t.expect(decoded.count).to.be_nil()
        t.expect(decoded.nested).to.be_nil()
        t.expect(decoded.items).to.be_nil()
        t.expect(decoded.attrs).to.be_nil()
    end)

    t.it("keeps an explicitly empty map distinct from a missing one", function()
        local empty = decode({ name = "x", attrs = {} })
        local missing = decode({ name = "x" })
        t.expect(type(empty.attrs)).to.equal("table")
        t.expect(next(empty.attrs)).to.be_nil()
        t.expect(missing.attrs).to.be_nil()
        -- 规范化后必须不同：一个编码了空表，一个编码了 nil 字段
        local a = canonical.encode_request("probe_req", empty)
        local b = canonical.encode_request("probe_req", missing)
        t.expect(a == b).to.equal(false)
    end)

    -- sp:default() 返回的占位表带 __array/__type 标记，不是真实请求。它只能用于
    -- 生成响应模板，绝不能拿去算指纹，否则同一语义会出现第二个摘要
    t.it("does not treat sproto default placeholders as request data", function()
        local default = sp:default("probe_req", "REQUEST")
        t.expect(default.nested.__type).to.equal("foo")
        local decoded = decode({ name = "" })
        t.expect(canonical.encode_request("probe_req", default) == canonical.encode_request("probe_req", decoded)).to
            .equal(false)
    end)
end)

t.describe("P00-A canonical stability", function()
    t.it("produces one byte string for 1000 different wire orders of the same request", function()
        -- 每次都是真实 sproto 解码出来的表；wire 里的 map 数组顺序与字段写入顺序都不同，
        -- 因此解码表的内部布局也不同，而不是同一张构造表算 1000 次
        local baseline = canonical.encode_request("probe_req", decode(to_wire(sample(1), 1)))
        t.expect(baseline).to.exist()
        local distinct_inputs = {}
        for seed = 2, 1000 do
            local wire = sp:request_encode("probe_req", to_wire(sample(seed), seed))
            distinct_inputs[wire] = true
            local encoded = canonical.encode_request("probe_req", sp:request_decode("probe_req", wire))
            if encoded ~= baseline then
                error(string.format("unstable canonical output at seed %d", seed))
            end
        end
        -- 如果 1000 个 seed 都生成了同一份 wire，上面的循环等于只测了一次
        local n = 0
        for _ in pairs(distinct_inputs) do
            n = n + 1
        end
        t.expect(n > 100).to.equal(true)
    end)

    t.it("keeps integer 2 before 10 and number 1 distinct from string '1'", function()
        local a = canonical.encode({ [2] = "two", [10] = "ten" })
        local b = canonical.encode({ [10] = "ten", [2] = "two" })
        t.expect(a).to.equal(b)
        local numeric = canonical.encode({ [1] = "x" })
        local textual = canonical.encode({ ["1"] = "x" })
        t.expect(numeric == textual).to.equal(false)
    end)

    t.it("normalizes 2.0 to 2 and -0.0 to 0", function()
        t.expect(canonical.encode({ v = 2.0 })).to.equal(canonical.encode({ v = 2 }))
        t.expect(canonical.encode({ v = -0.0 })).to.equal(canonical.encode({ v = 0 }))
    end)

    t.it("separates requests that differ only in array order", function()
        local a = canonical.encode({ items = { 1, 2 } })
        local b = canonical.encode({ items = { 2, 1 } })
        t.expect(a == b).to.equal(false)
    end)
end)

t.describe("P00-A fingerprint domains", function()
    local function hash(domain, input)
        return crypto.hmac_sha256(domain, input)
    end

    t.it("gives the same digest for the same decoded semantics", function()
        local first = decode(to_wire(sample(1), 1))
        local second = decode(to_wire(sample(7), 7))
        local a = fingerprint.compute("probe_req", first, hash)
        local b = fingerprint.compute("probe_req", second, hash)
        t.expect(#a).to.equal(32)
        t.expect(a).to.equal(b)
    end)

    t.it("gives different digests for different values, protocols and array order", function()
        local base = { name = "alice", count = 1 }
        local d1 = fingerprint.compute("probe_req", base, hash)
        local d2 = fingerprint.compute("probe_req", { name = "alice", count = 2 }, hash)
        local d3 = fingerprint.compute("other_req", base, hash)
        local d4 = fingerprint.compute("probe_req", { name = "alice", count = 1, items = { 1, 2 } }, hash)
        local d5 = fingerprint.compute("probe_req", { name = "alice", count = 1, items = { 2, 1 } }, hash)
        t.expect(d1 == d2).to.equal(false)
        t.expect(d1 == d3).to.equal(false)
        t.expect(d1 == d4).to.equal(false)
        t.expect(d4 == d5).to.equal(false)
    end)

    t.it("documents that a constant hash collapses different inputs, so vectors are the guard", function()
        local constant = function()
            return string.rep("\0", 32)
        end
        local a = fingerprint.compute("probe_req", { name = "a" }, constant)
        local b = fingerprint.compute("probe_req", { name = "b" }, constant)
        -- 指纹模块本身只保证 32 字节；"不同输入同摘要"由 P00-A 的向量用例证明 hash_fn 可用，
        -- 这里显式记录这个边界，避免把 constant 当合法实现
        t.expect(a).to.equal(b)
        t.expect(
            fingerprint.matches(
                { fingerprint_version = 1, name = "probe_req", hash = a, pack = "" },
                "probe_req",
                { name = "c" },
                constant
            )
        ).to
            .equal(true)
    end)
end)

t.describe("P00-A fail-closed", function()
    local function expect_reject(value, label)
        local out, err = canonical.encode(value)
        if out ~= nil then
            error(label .. " should be rejected")
        end
        t.expect(type(err)).to.equal("string")
    end

    t.it("rejects cycles, functions, metatables, NaN and infinity", function()
        local cycle = {}
        cycle.self = cycle
        expect_reject(cycle, "cycle")
        expect_reject({ f = function() end }, "function")
        expect_reject(setmetatable({}, {}), "metatable")
        expect_reject({ v = 0 / 0 }, "nan")
        expect_reject({ v = math.huge }, "infinity")
    end)

    t.it("rejects inputs over the depth, node and byte limits", function()
        local deep = {}
        local cur = deep
        for _ = 1, canonical.MAX_DEPTH + 2 do
            local next_ = {}
            cur.child = next_
            cur = next_
        end
        expect_reject(deep, "deep")

        local wide = {}
        for i = 1, canonical.MAX_NODES do
            wide["k" .. i] = i
        end
        expect_reject(wide, "wide")

        expect_reject({ v = string.rep("x", canonical.MAX_BYTES + 1) }, "large")
    end)

    t.it("rejects a protocol name that could collide with the framing", function()
        local out, err = canonical.encode_request("bad:name", {})
        t.expect(out).to.be_nil()
        t.expect(type(err)).to.equal("string")
    end)
end)

t.describe("P00-A crypto hmac vectors", function()
    -- RFC 4231 Test Case 1
    t.it("matches RFC 4231 test case 1", function()
        local key = string.rep("\11", 20)
        local mac = crypto.hmac_sha256(key, "Hi There")
        t.expect(#mac).to.equal(32)
        t.expect((mac:gsub(".", function(c)
            return string.format("%02x", c:byte())
        end))).to
            .equal("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    end)

    -- RFC 4231 Test Case 2
    t.it("matches RFC 4231 test case 2 and keeps the key/msg argument order", function()
        local mac = crypto.hmac_sha256("Jefe", "what do ya want for nothing?")
        t.expect((mac:gsub(".", function(c)
            return string.format("%02x", c:byte())
        end))).to
            .equal("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        t.expect(crypto.hmac_sha256("what do ya want for nothing?", "Jefe") == mac).to.equal(false)
    end)

    t.it("keeps the fingerprint domain separate from a business secret", function()
        local a = crypto.hmac_sha256("skyext:fingerprint:v1", "payload")
        local b = crypto.hmac_sha256("skyext:grant:v1", "payload")
        t.expect(a == b).to.equal(false)
    end)
end)
