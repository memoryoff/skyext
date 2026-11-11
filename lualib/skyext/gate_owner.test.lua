local t = require "skytest"
local gate_owner = require "skyext.gate_owner"

local function session()
    return {}
end

t.describe("gate_owner", function()
    t.it("binds once and rejects the same or an older epoch", function()
        local s = session()
        t.expect(gate_owner.bind(s, 1, "node1", ".entity_agent:role:1")).to.equal(true)
        t.expect(s.owner_epoch).to.equal(1)
        t.expect(s.owner_node).to.equal("node1")

        -- 相等是重复投递，小于 是上一个 owner 的迟到 RPC，两者都不能改状态
        local dup_ok, dup_err = gate_owner.bind(s, 1, "node2", ".entity_agent:role:1")
        t.expect(dup_ok).to.be_nil()
        t.expect(dup_err).to.equal(gate_owner.ERR.STALE_EPOCH)
        local old_ok, old_err = gate_owner.bind(s, 0, "node2", ".entity_agent:role:1")
        t.expect(old_ok).to.be_nil()
        t.expect(old_err).to.equal(gate_owner.ERR.INVALID_EPOCH)
        t.expect(s.owner_node).to.equal("node1")
    end)

    t.it("accepts a newer epoch and moves ownership", function()
        local s = session()
        gate_owner.bind(s, 1, "node1", ".entity_agent:role:1")
        t.expect(gate_owner.bind(s, 2, "node2", ".entity_agent:role:1")).to.equal(true)
        t.expect(s.owner_epoch).to.equal(2)
        t.expect(s.owner_node).to.equal("node2")
    end)

    t.it("drops a push from a different epoch", function()
        local s = session()
        gate_owner.bind(s, 3, "node1", ".entity_agent:role:1")
        t.expect(gate_owner.push_allowed(s, 3)).to.equal(true)
        local _, err = gate_owner.push_allowed(s, 2)
        t.expect(err).to.equal(gate_owner.ERR.STALE_EPOCH)
        local _, future_err = gate_owner.push_allowed(s, 4)
        t.expect(future_err).to.equal(gate_owner.ERR.STALE_EPOCH)
    end)

    -- 没有版本信息的旧调用方按放行处理，避免升级期直接断流
    t.it("allows an unversioned push but refuses one before any bind", function()
        local s = session()
        t.expect(gate_owner.push_allowed(s, nil)).to.equal(true)
        local ok, err = gate_owner.push_allowed(s, 1)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal(gate_owner.ERR.NOT_BOUND)
    end)

    t.it("freezes at the current epoch and reports how much was already sent", function()
        local s = session()
        gate_owner.bind(s, 2, "node1", ".entity_agent:role:1")
        s.pushed = 7
        local ok, info = gate_owner.freeze(s, 2, "barrier-1")
        t.expect(ok).to.equal(true)
        t.expect(info).to.equal({ sent = 7, epoch = 2, barrier_id = "barrier-1" })
        t.expect(s.frozen_epoch).to.equal(2)
    end)

    t.it("refuses to freeze a different epoch than the bound one", function()
        local s = session()
        gate_owner.bind(s, 2, "node1", ".entity_agent:role:1")
        local ok, err = gate_owner.freeze(s, 1, "barrier-1")
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal(gate_owner.ERR.STALE_EPOCH)
        t.expect(s.frozen_epoch).to.be_nil()
    end)

    -- 屏障之后旧 owner 的迟到包必须被丢掉，否则迁移会把上一段会话的包混进来
    t.it("drops every push at or below the frozen epoch", function()
        local s = session()
        gate_owner.bind(s, 2, "node1", ".entity_agent:role:1")
        gate_owner.freeze(s, 2, "barrier-1")
        local ok, err = gate_owner.push_allowed(s, 2)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal(gate_owner.ERR.FROZEN)
        local _, older = gate_owner.push_allowed(s, 1)
        t.expect(older).to.equal(gate_owner.ERR.FROZEN)
    end)

    t.it("resumes only with a strictly newer epoch and clears the barrier", function()
        local s = session()
        gate_owner.bind(s, 2, "node1", ".entity_agent:role:1")
        gate_owner.freeze(s, 2, "barrier-1")

        local ok, err = gate_owner.resume(s, 2, "node2", ".entity_agent:role:1")
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal(gate_owner.ERR.STALE_EPOCH)
        t.expect(s.frozen_epoch).to.equal(2)

        t.expect(gate_owner.resume(s, 3, "node2", ".entity_agent:role:1")).to.equal(true)
        t.expect(s.frozen_epoch).to.be_nil()
        t.expect(s.owner_epoch).to.equal(3)
        t.expect(gate_owner.push_allowed(s, 3)).to.equal(true)
        -- 解冻之后旧 epoch 仍然是迟到包
        t.expect(gate_owner.push_allowed(s, 2)).to.be_nil()
    end)

    t.it("reports its state without exposing the whole session", function()
        local s = session()
        gate_owner.bind(s, 5, "node1", ".entity_agent:role:1")
        s.pushed = 3
        t.expect(gate_owner.state(s)).to.equal({ owner_epoch = 5, frozen_epoch = nil, barrier_id = nil, pushed = 3 })
    end)

    t.it("rejects non-integer epochs instead of coercing them", function()
        local s = session()
        t.expect(gate_owner.bind(s, 1.5, "n", "s")).to.be_nil()
        t.expect(gate_owner.bind(s, "1", "n", "s")).to.be_nil()
        t.expect(gate_owner.bind(s, -1, "n", "s")).to.be_nil()
        t.expect(s.owner_epoch).to.be_nil()
    end)
end)
