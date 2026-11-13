-- 客户端只做结构校验与组装：不自签 Grant、不实现指纹、不改业务键重试。
local t = require "skytest"
local critical = require "skyext.client.critical"

local function grant(over)
    local g = {
        version = 1,
        rid = 7,
        grant_id = string.rep("a", 32),
        issued_at = 1000,
        expires_at = 4600,
        max_seq = 5,
        key_id = "k1",
        mac = "deadbeef",
    }
    for k, v in pairs(over or {}) do
        g[k] = v
    end
    return g
end

local function opts(over)
    local o = {
        grant = grant(),
        seq = 1,
        op_type = "shop.buy",
        params = { amount = 1 },
        protocol = "critical.execute",
    }
    for k, v in pairs(over or {}) do
        o[k] = v
    end
    return o
end

t.describe("client critical request", function()
    t.it("builds a request from a well-formed grant", function()
        local g = grant()
        local req = assert(critical.request(opts({ grant = g })))
        t.expect(req.protocol).to.equal("critical.execute")
        t.expect(req.request.grant).to.equal(g)
        t.expect(req.request.seq).to.equal(1)
        t.expect(req.request.op_type).to.equal("shop.buy")
        t.expect(req.request.params.amount).to.equal(1)
    end)

    t.it("refuses a seq outside the grant range or a non-integer seq", function()
        t.expect(critical.request(opts({ seq = 0 }))).to.be_nil()
        t.expect(critical.request(opts({ seq = 6 }))).to.be_nil()
        t.expect(critical.request(opts({ seq = 1.5 }))).to.be_nil()
        t.expect(critical.request(opts({ seq = 5 })) ~= nil).to.equal(true)
    end)

    t.it("refuses a grant with an invalid max_seq instead of truncating it", function()
        t.expect(critical.request(opts({ grant = grant({ max_seq = 0 }) }))).to.be_nil()
        t.expect(critical.request(opts({ grant = grant({ max_seq = 0x10000 }) }))).to.be_nil()
        t.expect(critical.request(opts({ grant = grant({ max_seq = 65535 }) })) ~= nil).to.equal(true)
    end)

    t.it("refuses a grant whose lifetime is inverted or whose id is malformed", function()
        t.expect(critical.request(opts({ grant = grant({ expires_at = 1000 }) }))).to.be_nil()
        t.expect(critical.request(opts({ grant = grant({ grant_id = "short" }) }))).to.be_nil()
        t.expect(critical.request(opts({ grant = grant({ version = 2 }) }))).to.be_nil()
        t.expect(critical.request(opts({ grant = grant({ key_id = "" }) }))).to.be_nil()
    end)

    t.it("requires op_type, protocol and a table params", function()
        t.expect(critical.request(opts({ op_type = "" }))).to.be_nil()
        t.expect(critical.request(opts({ protocol = "" }))).to.be_nil()
        t.expect(critical.request(opts({ params = "x" }))).to.be_nil()
        -- 不带 params 是合法的：服务端会按空表处理
        t.expect(critical.request({
            grant = grant(),
            seq = 1,
            op_type = "shop.buy",
            protocol = "critical.execute",
        }) ~= nil).to
            .equal(true)
    end)

    t.it("builds a read-only query without inventing an op id", function()
        local q = assert(critical.query({ protocol = "critical.query", op_id = "srv_" .. string.rep("a", 64) }))
        t.expect(q.request.op_id).to.equal("srv_" .. string.rep("a", 64))
        t.expect(critical.query({ protocol = "critical.query" })).to.be_nil()
        t.expect(critical.query({ op_id = "x" })).to.be_nil()
        t.expect(critical.query({ protocol = "critical.query", op_id = "srv_" .. string.rep("A", 64) })).to.be_nil()
        t.expect(critical.query({ protocol = "critical.query", op_id = string.rep("a", 33) .. "_0001" })).to.be_nil()
    end)
end)
