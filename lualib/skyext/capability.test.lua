local t = require "skytest"
local skynet = require "skynet"
local capability = require "skyext.capability"

local function issuer()
    return assert(capability.new_issuer("payment", { "grant_coin" }))
end

local function fields(over)
    local f = {
        rid = 7,
        service_op_id = "srv_" .. string.rep("a", 64),
        op_type = "grant_coin",
        payload_hash = "hash1",
        source_id = "order-1",
        now = 1000,
        ttl = 30,
    }
    for k, v in pairs(over or {}) do
        f[k] = v
    end
    return f
end

t.describe("capability issuance", function()
    t.it("issues an opaque cap that verifies against its binding", function()
        local cap = assert(capability.issue(issuer(), fields()))
        t.expect(capability.is_cap(cap)).to.equal(true)
        t.expect(capability.verify(cap, fields(), 1001)).to.equal(true)
        -- cap 本身不暴露可复制的字段：伪造者拿不到 rid/source 去拼一个等价对象
        t.expect(cap.rid).to.be_nil()
        t.expect(cap.source).to.be_nil()
    end)

    t.it("rejects a plain table that claims to be a cap", function()
        local fake = { source = "payment", rid = 7, op_type = "grant_coin" }
        t.expect(capability.verify(fake, fields(), 1001)).to.equal(false)
        t.expect(capability.is_cap(fake)).to.equal(false)
    end)

    t.it("rejects a copied cap even when the copy steals the metatable", function()
        local cap = assert(capability.issue(issuer(), fields()))
        local copy = {}
        for k, v in pairs(cap) do
            copy[k] = v
        end
        t.expect(capability.verify(copy, fields(), 1001)).to.equal(false)

        -- 模拟跨进程/快照后重建：对象身份丢失，metatable 也救不回来
        local rebuilt = setmetatable({}, getmetatable(cap))
        t.expect(capability.verify(rebuilt, fields(), 1001)).to.equal(false)
    end)

    t.it("rejects an expired cap and accepts one just before expiry", function()
        local cap = assert(capability.issue(issuer(), fields({ now = 1000, ttl = 5 })))
        t.expect(capability.verify(cap, fields(), 1004)).to.equal(true)
        local ok, err = capability.verify(cap, fields(), 1005)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal(capability.ERR.EXPIRED)
    end)

    t.it("rejects a revoked cap and makes consume single use", function()
        local cap = assert(capability.issue(issuer(), fields()))
        t.expect(capability.consume(cap, fields(), 1001)).to.equal(true)
        local ok, err = capability.verify(cap, fields(), 1001)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal(capability.ERR.REVOKED)

        local other = assert(capability.issue(issuer(), fields()))
        t.expect(capability.revoke(other)).to.equal(true)
        t.expect(capability.verify(other, fields(), 1001)).to.equal(false)
    end)

    t.it("binds rid, op_type, payload and service_op_id", function()
        local cap = assert(capability.issue(issuer(), fields()))
        for _, expected in ipairs({
            { rid = 8 },
            { op_type = "buy_item" },
            { payload_hash = "hash2" },
            { service_op_id = "srv_" .. string.rep("b", 64) },
            { source_id = "order-2" },
            { namespace = "outbox" },
        }) do
            local ok, err = capability.verify(cap, expected, 1001)
            t.expect(ok).to.equal(false)
            t.expect(err).to.equal(capability.ERR.BINDING_MISMATCH)
        end
    end)

    t.it("rejects a cap that went through cross-process serialization", function()
        local cap = assert(capability.issue(issuer(), fields()))
        -- 真实跨进程路径会经过 skynet.pack/unpack；对象身份丢失后必须失效。
        -- pack 本身可能拒绝带 metatable 的表，两种结果都不能让伪造者通过
        local ok, bytes, size = pcall(skynet.pack, cap)
        if ok then
            local copy = skynet.unpack(bytes, size)
            t.expect(capability.verify(copy, fields(), 1001)).to.equal(false)
        end
        t.expect(capability.verify(cap, fields(), 1001)).to.equal(true)
    end)

    t.it("refuses op types the issuer is not allowed to sign", function()
        local cap, err = capability.issue(issuer(), fields({ op_type = "refund" }))
        t.expect(cap).to.be_nil()
        t.expect(err).to_not.be_nil()
    end)

    t.it("refuses a forged issuer object", function()
        local cap, err = capability.issue({ namespace = "payment" }, fields())
        t.expect(cap).to.be_nil()
        t.expect(err).to.equal(capability.ERR.ISSUER)
    end)
end)

t.describe("capability coroutine context", function()
    t.it("keeps the current cap per coroutine instead of a module global", function()
        local cap_a = assert(capability.issue(issuer(), fields()))
        local cap_b = assert(capability.issue(issuer(), fields({ rid = 9 })))

        local seen_a, seen_b, seen_main
        capability.run_with(cap_a, function()
            seen_a = capability.current()
            -- 另一个协程并发进入受控上下文，不能覆盖 A 的 cap
            local co = coroutine.create(function()
                capability.run_with(cap_b, function()
                    seen_b = capability.current()
                end)
            end)
            coroutine.resume(co)
            seen_main = capability.current()
        end)
        t.expect(seen_a).to.equal(cap_a)
        t.expect(seen_b).to.equal(cap_b)
        t.expect(seen_main).to.equal(cap_a)
        t.expect(capability.current()).to.be_nil()
    end)

    t.it("restores the previous cap on nested calls and on errors", function()
        local outer = assert(capability.issue(issuer(), fields()))
        local inner = assert(capability.issue(issuer(), fields({ rid = 9 })))
        capability.run_with(outer, function()
            capability.run_with(inner, function()
                t.expect(capability.current()).to.equal(inner)
            end)
            t.expect(capability.current()).to.equal(outer)

            local ok = pcall(function()
                capability.run_with(inner, function()
                    error("boom")
                end)
            end)
            t.expect(ok).to.equal(false)
            t.expect(capability.current()).to.equal(outer)
        end)
    end)

    t.it("refuses to enter a context with a non-cap value", function()
        local ok, err = capability.run_with({ source = "payment" }, function() end)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal(capability.ERR.INVALID)
    end)
end)

t.describe("capability 签发边界", function()
    t.it("refuses an issuer with an empty op type whitelist", function()
        -- 空白名单原本等价于"放行任意 op_type"，业务白名单等于被签发调用方绕过
        local ok, err = capability.new_issuer("payment", {})
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("allowed_op_types must be a non-empty list")
        t.expect(capability.new_issuer("payment", nil)).to.be_nil()
        t.expect(capability.new_issuer("payment", { "" })).to.be_nil()
    end)

    t.it("refuses issuers outside the trusted dispatch namespaces", function()
        t.expect(capability.new_issuer("verified_source", { "grant_coin" })).to.be_nil()
        t.expect(capability.new_issuer("client", { "grant_coin" })).to.be_nil()
        t.expect(capability.new_issuer("payment", { "grant_coin" }) ~= nil).to.equal(true)
    end)

    t.it("keeps the trusted namespace registry private", function()
        t.expect(capability.ALLOWED_NAMESPACES).to.be_nil()
        t.expect(capability.is_allowed_namespace("payment")).to.equal(true)
        t.expect(capability.is_allowed_namespace("client")).to.equal(false)

        -- 外部即使写入同名模块字段也不能扩展签发边界
        capability.ALLOWED_NAMESPACES = { client = true }
        local issuer, err = capability.new_issuer("client", { "grant_coin" })
        t.expect(issuer).to.be_nil()
        t.expect(err).to.equal("namespace is not a trusted dispatch entry")
        capability.ALLOWED_NAMESPACES = nil

        -- 公开查询函数也不能作为签发判定的入口
        local original_is_allowed = capability.is_allowed_namespace
        capability.is_allowed_namespace = function()
            return true
        end
        local forged, forged_err = capability.new_issuer("client", { "grant_coin" })
        t.expect(forged).to.be_nil()
        t.expect(forged_err).to.equal("namespace is not a trusted dispatch entry")
        capability.is_allowed_namespace = original_is_allowed
    end)

    t.it("only reports a namespace for a real registered cap", function()
        t.expect(capability.namespace_of({ namespace = "payment", source = "verified" })).to.be_nil()
        local cap = assert(capability.issue(issuer(), fields()))
        t.expect(capability.namespace_of(cap)).to.equal("payment")
    end)
end)
