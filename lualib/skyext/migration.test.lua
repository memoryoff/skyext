local t = require "skytest"

local migration = require "skyext.migration"

local function entity(over)
    local e = { id = 7, conn_id = "conn-1", owner_epoch = 3 }
    for k, v in pairs(over or {}) do
        e[k] = v
    end
    return e
end

-- 记录调用顺序的 deps；over 可以替换任意一步
local function deps(over)
    local d = { calls = {} }
    local function ok(name)
        d[name] = function()
            d.calls[#d.calls + 1] = name
            return true
        end
    end
    ok("quiesce")
    ok("freeze")
    ok("handoff")
    ok("activate")
    d.export = function()
        d.calls[#d.calls + 1] = "export"
        return { bytes = "SNAP", session_epoch = "S" }
    end
    d.transfer = function(_, snapshot)
        d.calls[#d.calls + 1] = "transfer"
        d.transferred = snapshot
        return true
    end
    for k, v in pairs(over or {}) do
        d[k] = v
    end
    return d
end

t.describe("migration 六阶段", function()
    t.it("walks every phase in order", function()
        local d = deps()
        local status = assert(migration.migrate_entity(d, entity(), { barrier_id = "b1" }))
        t.expect(status).to.equal("READY")
        t.expect(d.calls).to.equal({ "quiesce", "freeze", "export", "transfer", "handoff", "activate" })
        t.expect(d.transferred.bytes).to.equal("SNAP")
    end)

    -- 任何一步失败都不能宣称"无感迁移成功"：客户端会被留在没有下行入口的会话上
    t.it("falls back when quiescing fails", function()
        local d = deps({
            quiesce = function()
                return nil, "entity busy"
            end,
        })
        local status, reason = migration.migrate_entity(d, entity(), {})
        t.expect(status).to.equal("FALLBACK")
        t.expect(reason).to.match("quiesce")
        t.expect(d.calls).to.equal({})
    end)

    t.it("falls back when the gate barrier cannot be confirmed", function()
        local d = deps({
            freeze = function()
                return nil, "gate timeout"
            end,
        })
        local status, reason = migration.migrate_entity(d, entity(), {})
        t.expect(status).to.equal("FALLBACK")
        t.expect(reason).to.match("barrier")
        -- 屏障没确认就不能往下走：否则旧 owner 还能发下行
        t.expect(d.transferred).to.be_nil()
    end)

    t.it("falls back when the snapshot cannot be exported", function()
        local d = deps({
            export = function()
                return nil, "out_buf gap"
            end,
        })
        local status, reason = migration.migrate_entity(d, entity(), {})
        t.expect(status).to.equal("FALLBACK")
        t.expect(reason).to.match("export")
    end)

    t.it("falls back when the handoff is refused", function()
        local d = deps({
            handoff = function()
                return nil, "fence claim lost"
            end,
        })
        local status, reason = migration.migrate_entity(d, entity(), {})
        t.expect(status).to.equal("FALLBACK")
        t.expect(reason).to.match("handoff")
        t.expect(d.calls[#d.calls]).to.equal("transfer")
    end)

    -- 回放失败也不能退回旧 owner：它的下行入口已经被屏障切断
    t.it("falls back when replaying fails", function()
        local d = deps({
            activate = function()
                return nil, "client ack timeout"
            end,
        })
        local status, reason = migration.migrate_entity(d, entity(), {})
        t.expect(status).to.equal("FALLBACK")
        t.expect(reason).to.match("replay")
    end)

    t.it("treats a raising step as a failure", function()
        local d = deps({
            freeze = function()
                error("cluster unreachable")
            end,
        })
        local status, reason = migration.migrate_entity(d, entity(), {})
        t.expect(status).to.equal("FALLBACK")
        t.expect(reason).to.match("cluster unreachable")
    end)
end)

t.describe("migration 批次", function()
    t.it("migrates every ready entity and reports statistics", function()
        local d = deps()
        d.list_entities = function()
            return { entity({ id = 1 }), entity({ id = 2 }) }
        end
        local stats = assert(migration.run(d, {}))
        t.expect(stats.total).to.equal(2)
        t.expect(stats.ready).to.equal(2)
        t.expect(stats.fallback).to.equal(0)
    end)

    -- 单个玩家的关键操作未决不能永久阻塞整节点退出
    t.it("degrades a critical-unknown entity without blocking the rest", function()
        local d = deps()
        d.list_entities = function()
            return { entity({ id = 1 }), entity({ id = 2, critical_unknown = true }), entity({ id = 3 }) }
        end
        local fallen = {}
        d.fallback = function(e, status)
            fallen[#fallen + 1] = { id = e.id, status = status }
        end
        local stats = assert(migration.run(d, {}))
        t.expect(stats.total).to.equal(3)
        t.expect(stats.ready).to.equal(2)
        t.expect(stats.critical_unknown).to.equal(1)
        t.expect(#fallen).to.equal(1)
        -- fallback 收到的是原因（"critical_unknown"），不是状态名
        t.expect(fallen[1].status).to.equal("critical_unknown")
    end)

    t.it("counts a failed entity as fallback and keeps going", function()
        local d = deps()
        local first = true
        d.quiesce = function()
            if first then
                first = false
                return nil, "busy"
            end
            return true
        end
        d.list_entities = function()
            return { entity({ id = 1 }), entity({ id = 2 }) }
        end
        local stats = assert(migration.run(d, {}))
        t.expect(stats.fallback).to.equal(1)
        t.expect(stats.ready).to.equal(1)
    end)

    t.it("reports a listing failure", function()
        local ok, err = migration.run({
            list_entities = function()
                error("etcd down")
            end,
        }, {})
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("etcd down")
    end)

    t.it("requires a listing function", function()
        t.expect(migration.run({}, {})).to.be_nil()
    end)
end)

t.describe("migration 忙碌等待", function()
    t.it("returns true as soon as the entity is ready", function()
        local probes = 0
        local ok = migration.wait_busy({
            probe = function()
                probes = probes + 1
                return probes == 2
            end,
            sleep = function() end,
        }, entity(), { attempts = 5 })
        t.expect(ok).to.equal(true)
        t.expect(probes).to.equal(2)
    end)

    -- 无限等待会让节点退出被一个玩家拖死
    t.it("gives up after the attempt budget", function()
        local ok = migration.wait_busy({
            probe = function()
                return false
            end,
            sleep = function() end,
        }, entity(), { attempts = 3 })
        t.expect(ok).to.equal(false)
    end)

    t.it("refuses to wait without a probe", function()
        t.expect(migration.wait_busy({}, entity())).to.equal(false)
    end)
end)

t.describe("migration 依赖与忙碌", function()
    -- 缺 export 不能当成功：会得到"宣称迁移完成、快照从未送达"的会话
    t.it("fails closed when a required step is not configured", function()
        local d = deps()
        d.export = nil
        local status, reason = migration.migrate_entity(d, entity(), {})
        t.expect(status).to.equal("FALLBACK")
        t.expect(reason).to.match("export is not configured")
    end)

    -- `router.call` 成功时返回 payload（table），不能只认字面 true
    t.it("accepts a step that returns a payload table", function()
        local d = deps({
            handoff = function()
                return { owner_epoch = 4, sent = 2 }
            end,
        })
        local status = assert(migration.migrate_entity(d, entity(), {}))
        t.expect(status).to.equal("READY")
    end)

    t.it("waits for a busy entity before migrating", function()
        local d = deps()
        local probes = 0
        d.probe = function()
            probes = probes + 1
            return probes >= 2
        end
        d.sleep = function() end
        d.list_entities = function()
            return { entity({ id = 1, busy = true }) }
        end
        local stats = assert(migration.run(d, { attempts = 5 }))
        t.expect(stats.ready).to.equal(1)
        t.expect(stats.busy).to.equal(0)
    end)

    t.it("degrades a busy entity that never becomes ready", function()
        local d = deps()
        d.probe = function()
            return false
        end
        d.sleep = function() end
        d.list_entities = function()
            return { entity({ id = 1, busy = true }) }
        end
        local stats = assert(migration.run(d, { attempts = 2 }))
        t.expect(stats.ready).to.equal(0)
        t.expect(stats.busy).to.equal(1)
        t.expect(stats.fallback).to.equal(1)
    end)
end)
