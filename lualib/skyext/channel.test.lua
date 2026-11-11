local t = require "skytest"
local channel = require "skyext.channel"

t.describe("channel", function()
    t.it("joins idempotently and leaves once", function()
        local c = assert(channel.new({ name = "world" }))
        t.expect(c:join(1)).to.equal(true)
        t.expect(c:join(1)).to.equal(true)
        t.expect(c:size()).to.equal(1)
        t.expect(c:has(1)).to.equal(true)
        t.expect(c:leave(1)).to.equal(true)
        t.expect(c:leave(1)).to.equal(false)
        t.expect(c:size()).to.equal(0)
    end)

    t.it("refuses a member the authorizer rejects", function()
        local c = assert(channel.new({
            name = "guild",
            authorize = function(rid)
                if rid ~= 7 then
                    return false, "not a guild member"
                end
                return true
            end,
        }))
        t.expect(c:join(7)).to.equal(true)
        local ok, err = c:join(8)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("not a guild member")
        t.expect(c:size()).to.equal(1)
    end)

    t.it("enforces the member cap", function()
        local c = assert(channel.new({ name = "room", max_members = 2 }))
        t.expect(c:join(1)).to.equal(true)
        t.expect(c:join(2)).to.equal(true)
        local ok, err = c:join(3)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("channel is full")
        -- 已订阅的人再 join 不该被上限挡住
        t.expect(c:join(1)).to.equal(true)
    end)

    t.it("delivers to every healthy member and counts skips", function()
        local c = assert(channel.new({ name = "world" }))
        for rid = 1, 4 do
            c:join(rid)
        end
        local seen = {}
        local stats = assert(c:broadcast("PACK", function(rid, payload)
            seen[rid] = payload
            -- 3 号离线
            return rid ~= 3
        end))
        t.expect(stats.delivered).to.equal(3)
        t.expect(stats.skipped).to.equal(1)
        t.expect(seen[1]).to.equal("PACK")
        t.expect(seen[4]).to.equal("PACK")
    end)

    -- 频道消息是可丢的：连续失败的成员要被摘出去，避免拖垮整轮广播
    t.it("stops trying a member after repeated failures and recovers on join", function()
        local c = assert(channel.new({ name = "world", max_failures = 2 }))
        c:join(1)
        c:join(2)

        local function fail_rid2(rid)
            return rid ~= 2
        end
        assert(c:broadcast("A", fail_rid2))
        assert(c:broadcast("B", fail_rid2))
        t.expect(c:stats().slow).to.equal(1)

        -- slow 成员不再被尝试，只计 slow_skipped
        local tried = 0
        local stats = assert(c:broadcast("C", function(rid)
            tried = tried + 1
            return rid ~= 2
        end))
        t.expect(tried).to.equal(1)
        t.expect(stats.slow_skipped).to.equal(1)
        t.expect(stats.delivered).to.equal(1)

        -- 成员重新 join 视为恢复
        t.expect(c:join(2)).to.equal(true)
        t.expect(c:stats().slow).to.equal(0)
        t.expect(assert(c:broadcast("D", function()
            return true
        end)).delivered).to
            .equal(2)
    end)

    -- 投递过程中有人 join/leave，不能跳过其它成员
    t.it("is not confused by membership changes during a broadcast", function()
        local c = assert(channel.new({ name = "world" }))
        for rid = 1, 3 do
            c:join(rid)
        end
        local visited = {}
        assert(c:broadcast("PACK", function(rid)
            visited[#visited + 1] = rid
            if rid == 1 then
                c:leave(2)
                c:join(9)
            end
            return true
        end))
        table.sort(visited)
        -- 2 号在本轮投递途中退订，所以拿不到这一包；3 号不能因此被跳过
        -- （直接遍历 self.order 会跳过元素，这里遍历的是快照）
        t.expect(visited).to.equal({ 1, 3 })
        t.expect(c:has(9)).to.equal(true)
    end)

    t.it("counts batches so a large fanout can yield", function()
        local c = assert(channel.new({ name = "world", batch_size = 2 }))
        for rid = 1, 5 do
            c:join(rid)
        end
        local stats = assert(c:broadcast("PACK", function()
            return true
        end))
        t.expect(stats.batches).to.equal(3)
    end)

    -- 分批的意义是让调用方有机会 yield；本模块是纯 Lua，不能自己让出
    t.it("invokes the batch callback so the caller can yield", function()
        local c = assert(channel.new({ name = "world", batch_size = 2 }))
        for rid = 1, 5 do
            c:join(rid)
        end
        local batches = {}
        assert(c:broadcast("PACK", function()
            return true
        end, function(n)
            batches[#batches + 1] = n
        end))
        t.expect(batches).to.equal({ 1, 2, 3 })
    end)

    -- deliver 忘了 return 时不能被当成成功
    t.it("treats a non-boolean deliver result as a failure", function()
        local c = assert(channel.new({ name = "world", max_failures = 1 }))
        c:join(1)
        local stats = assert(c:broadcast("PACK", function()
            return 1
        end))
        t.expect(stats.delivered).to.equal(0)
        t.expect(stats.skipped).to.equal(1)
    end)

    t.it("survives a deliver function that raises", function()
        local c = assert(channel.new({ name = "world", max_failures = 1 }))
        c:join(1)
        local stats = assert(c:broadcast("PACK", function()
            error("boom")
        end))
        t.expect(stats.delivered).to.equal(0)
        t.expect(stats.skipped).to.equal(1)
        t.expect(c:stats().slow).to.equal(1)
    end)

    t.it("refuses an invalid configuration instead of guessing defaults", function()
        t.expect(channel.new({ name = "" })).to.be_nil()
        t.expect(channel.new({ name = "x", max_members = 0 })).to.be_nil()
        t.expect(channel.new({ name = "x", batch_size = 1.5 })).to.be_nil()
        t.expect(channel.new("x")).to.be_nil()
    end)
end)

t.describe("channel directory", function()
    t.it("creates one channel per name and reuses it", function()
        channel.reset()
        local a = assert(channel.get_or_create({ name = "world" }))
        local b = assert(channel.get_or_create({ name = "world" }))
        t.expect(a).to.equal(b)
        t.expect(channel.list()).to.equal({ "world" })
        t.expect(channel.get("world")).to.equal(a)
        t.expect(channel.remove("world")).to.equal(true)
        t.expect(channel.get("world")).to.be_nil()
        t.expect(channel.remove("world")).to.equal(false)
    end)

    t.it("rejects an empty name", function()
        channel.reset()
        t.expect(channel.get_or_create({ name = "" })).to.be_nil()
        t.expect(channel.get_or_create(nil)).to.be_nil()
        t.expect(channel.list()).to.equal({})
    end)
end)
