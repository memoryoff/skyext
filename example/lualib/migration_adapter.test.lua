-- 迁移适配器：六个阶段各自只做一件事，失败要能定位到"送不到 / 抢不到锁 / 网关不认账"。
-- 这里用桩把跨节点调用全部记下来，断言调用顺序与参数；真实集群回环另见 P17 清单。
local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local migration = require "skyext.migration"

local SOURCE =
    fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/lualib/migration_adapter.lua")

local SELF_NODE = "node-a"

local function harness(opts)
    opts = opts or {}
    local h = { calls = {}, nodes = opts.nodes or { SELF_NODE, "node-b" }, entities = opts.entities }
    local noop = function() end

    local function record(transport, target, cmd, ...)
        local call = { transport = transport, target = target, cmd = cmd, args = table.pack(...) }
        h.calls[#h.calls + 1] = call
        return call
    end

    local function last_call(cmd)
        for i = #h.calls, 1, -1 do
            if h.calls[i].cmd == cmd then
                return h.calls[i]
            end
        end
    end
    h.last_call = last_call

    local fake_skynet = {
        localname = function(name)
            h.localname = name
            if opts.mgr_missing then
                return nil
            end
            return "mgr-addr"
        end,
        call = function(addr, proto, cmd, ...)
            t.expect(proto).to.equal("lua")
            record("local", addr, cmd, ...)
            if cmd == "migration_list" then
                return h.entities
            end
            if cmd == "migration_quiesce" then
                return h.quiesce_ok ~= false, h.quiesce_err
            end
            if cmd == "migration_release" then
                return h.release_ok ~= false, h.release_err
            end
            if cmd == "migration_unquiesce" then
                return h.unquiesce_ok ~= false, h.unquiesce_err
            end
            if cmd == "session_export" then
                return h.export_ok ~= false, h.snapshot or { bytes = "BYTES", session_epoch = "e1", owner_epoch = 4 }
            end
            return true
        end,
    }

    local fake_cluster = {
        call = function(node, addr, cmd, ...)
            record("cluster", node .. "!" .. addr, cmd, ...)
            if cmd == "migration_stage" then
                return h.stage_ok ~= false, h.stage_err
            end
            if cmd == "migration_commit" then
                return h.commit_ok ~= false, h.commit_err
            end
            if cmd == "session_attach" then
                return h.attach_ok ~= false, h.attach_err
            end
            if cmd == "freeze_owner" then
                return h.freeze_info or { sent = 0, epoch = 2, barrier_id = "b1" }, h.freeze_err
            end
            -- 取消兜底的两条腿要能分别注入失败：A-11 的核心是
            -- "目标不可达时踢人仍然必须发生"
            if cmd == "kick" then
                if opts.kick_raises then
                    error("gate down")
                end
                return opts.kick_ok ~= false, opts.kick_err
            end
            if cmd == "migration_abort" then
                if opts.abort_raises then
                    error("target unreachable")
                end
                return opts.abort_ok ~= false, opts.abort_err
            end
            return true
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skynet.cluster"] = fake_cluster,
        ["skyext.cluster_discovery"] = {
            state = function(service)
                h.discovery_service = service
                return { state = "VERIFIED", nodes = h.nodes }
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("cluster_node_name")
                return SELF_NODE
            end,
        },
        ["skyext.connection_id"] = {
            parse = function(conn_id)
                if conn_id == "bad" then
                    return nil, "invalid conn_id"
                end
                return { gate_node = "gate1", gate_service = ".gate_tcp" }
            end,
        },
        ["skyext.log"] = { info = noop, warn = noop, error = noop, debug = noop },
        ["skyext.entity.types"] = {
            format_agent_service_name = function(type_name, index)
                return ".entity_agent:" .. type_name .. ":" .. tostring(index)
            end,
            calc_agent_index = function()
                return 1
            end,
            calc_node = function(_, id)
                return (opts.placement or {})[id] or "node-b"
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.adapter = assert(loadfile(SOURCE, "t", env))()
    h.adapter.init({ type_name = "role" })
    return h
end

local function entity(extra)
    local e = { id = 7, conn_id = "conn-7", owner_epoch = 2, persistent = true, busy = false }
    for k, v in pairs(extra or {}) do
        e[k] = v
    end
    return e
end

t.describe("migration_adapter 枚举", function()
    t.it("only offers entities that can be handed over without a reconnect", function()
        local h = harness({
            entities = {
                entity({ id = 7 }),
                -- 没有连接：迁移过去也没有下行出口，留给普通卸载
                { id = 8, owner_epoch = 2, persistent = true, busy = false },
                entity({ id = 9, busy = true }),
                entity({ id = 10, persistent = false }),
            },
        })
        local list = h.adapter.list_entities()
        t.expect(#list).to.equal(1)
        t.expect(list[1].id).to.equal(7)
        t.expect(h.localname).to.equal(".entity_agentmgr:role")
    end)

    t.it("refuses to run when this node does not host the entity type", function()
        local h = harness({ mgr_missing = true })
        local list, err = h.adapter.list_entities()
        t.expect(list).to.be_nil()
        t.expect(err:find("entity_agentmgr", 1, true) ~= nil).to.equal(true)
    end)
end)

t.describe("migration_adapter 六阶段", function()
    t.it("freezes the entity on the source node", function()
        local h = harness()
        t.expect(h.adapter.quiesce(entity())).to.equal(true)
        local call = h.last_call("migration_quiesce")
        t.expect(call.transport).to.equal("local")
        t.expect(call.args[1]).to.equal(7)
    end)

    t.it("puts the gate barrier on the connection, not on the node", function()
        local h = harness()
        t.expect(h.adapter.freeze(entity(), "b1")).to.equal(true)
        local call = h.last_call("freeze_owner")
        t.expect(call.transport).to.equal("cluster")
        t.expect(call.target).to.equal("gate1!.gate_tcp")
        t.expect(call.args[1]).to.equal("conn-7")
        t.expect(call.args[2]).to.equal(2)
        t.expect(call.args[3]).to.equal("b1")
    end)

    t.it("refuses to freeze an entity without an owner epoch", function()
        local h = harness()
        local ok, err = h.adapter.freeze({ id = 7, conn_id = "conn-7" }, "b1")
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("entity has no owner epoch")
        t.expect(h.last_call("freeze_owner")).to.be_nil()
    end)

    t.it("exports with a strictly newer owner epoch", function()
        local h = harness()
        local snapshot = h.adapter.export(entity(), "b1")
        t.expect(snapshot.bytes).to.equal("BYTES")
        local call = h.last_call("session_export")
        -- CMD.session_export(entity_id, barrier_id, target_owner_epoch)
        t.expect(call.args[1]).to.equal(7)
        t.expect(call.args[2]).to.equal("b1")
        t.expect(call.args[3]).to.equal(3)
    end)

    t.it("releases the source before staging on the target", function()
        local h = harness()
        t.expect(h.adapter.transfer(entity(), { bytes = "BYTES" })).to.equal(true)
        local release = h.last_call("migration_release")
        local stage = h.last_call("migration_stage")
        t.expect(release.transport).to.equal("local")
        -- 目标必须显式寻址：router.call 会按 HRW 转回源节点
        t.expect(stage.transport).to.equal("cluster")
        t.expect(stage.target).to.equal("node-b!.entity_agent:role:1")
        t.expect(stage.args[1]).to.equal(7)
        t.expect(stage.args[2].bytes).to.equal("BYTES")
        t.expect(h.calls[#h.calls - 1].cmd).to.equal("migration_release")
    end)

    t.it("does not stage anything when the source refuses to release", function()
        local h = harness()
        h.release_ok = false
        h.release_err = "snapshot not exported"
        local ok, err = h.adapter.transfer(entity(), { bytes = "BYTES" })
        t.expect(ok).to.be_nil()
        t.expect(err:find("snapshot not exported", 1, true) ~= nil).to.equal(true)
        t.expect(h.last_call("migration_stage")).to.be_nil()
    end)

    -- HRW 还指着本节点（成员视图未更新）时必须另选一个存活节点，否则整批迁移都失败
    t.it("falls back to another live node when HRW still points at the source", function()
        local h = harness({ placement = { [7] = SELF_NODE } })
        t.expect(h.adapter.transfer(entity(), { bytes = "BYTES" })).to.equal(true)
        t.expect(h.discovery_service).to.equal("entity:role")
        t.expect(h.last_call("migration_stage").target).to.equal("node-b!.entity_agent:role:1")
    end)

    t.it("reports a missing target instead of pretending the transfer worked", function()
        local h = harness({ placement = { [7] = SELF_NODE }, nodes = { SELF_NODE } })
        local ok, err = h.adapter.transfer(entity(), { bytes = "BYTES" })
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("no other node serves role")
        t.expect(h.last_call("migration_stage")).to.be_nil()
    end)

    t.it("claims and installs on the chosen target, then hands the connection over", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.transfer(e, { bytes = "BYTES" }))
        t.expect(h.adapter.handoff(e)).to.equal(true)
        t.expect(h.last_call("migration_commit").target).to.equal("node-b!.entity_agent:role:1")

        t.expect(h.adapter.activate(e)).to.equal(true)
        local attach = h.last_call("session_attach")
        t.expect(attach.target).to.equal("node-b!.entity_agent:role:1")
        t.expect(attach.args[2]).to.equal("conn-7")
    end)

    t.it("refuses to hand off without a target", function()
        local h = harness()
        local ok, err = h.adapter.handoff(entity())
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("no target was chosen")
        local attached, aerr = h.adapter.activate(entity())
        t.expect(attached).to.be_nil()
        t.expect(aerr).to.equal("no target was chosen")
    end)

    t.it("surfaces a target refusal at every step", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.transfer(e, { bytes = "BYTES" }))

        h.commit_ok = false
        h.commit_err = "no staged snapshot"
        local ok, err = h.adapter.handoff(e)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("no staged snapshot")

        h.attach_ok = false
        h.attach_err = "gate rejected the new owner"
        local attached, aerr = h.adapter.activate(e)
        t.expect(attached).to.be_nil()
        t.expect(aerr).to.equal("gate rejected the new owner")
    end)
end)

t.describe("migration_adapter 降级", function()
    t.it("unfreezes the entity when the source still owns it", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.quiesce(e))
        h.adapter.fallback(e, "barrier failed")
        local call = h.last_call("migration_unquiesce")
        t.expect(call.args[1]).to.equal(7)
        t.expect(call.args[2]).to.equal("barrier failed")
    end)

    -- 锁已经放了，源端没有实体可解冻；此时必须踢掉客户端让它立刻重连，
    -- 否则它会对着一个没有 owner 的连接重试到空闲超时
    t.it("kicks the client once the entity is released", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.transfer(e, { bytes = "BYTES" }))
        h.adapter.fallback(e, "handoff failed")
        t.expect(h.last_call("migration_unquiesce")).to.be_nil()
        local kick = h.last_call("kick")
        t.expect(kick.target).to.equal("gate1!.gate_tcp")
        t.expect(kick.args[1]).to.equal("conn-7")
    end)

    -- export 成功、release 失败：`_released` 仍是 nil，而源端实体已经导出了快照，
    -- unquiesce 会被明确拒绝。此时网关屏障还在，只看 `_released` 就既不unfreeze
    -- 也不 kick，客户端上下行被静默丢弃（只能等客户端自己超时重连）
    t.it("kicks the client when an exported entity cannot be unfrozen", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.quiesce(e))
        local snapshot = assert(h.adapter.export(e))
        h.release_ok = false
        t.expect(h.adapter.transfer(e, snapshot)).to.be_nil()

        h.unquiesce_ok = false
        h.unquiesce_err = "snapshot already exported"
        h.adapter.fallback(e, "release failed")

        local kick = h.last_call("kick")
        t.expect(kick).to_not.be_nil()
        t.expect(kick.args[1]).to.equal("conn-7")
    end)
end)

-- 用真实的编排状态机跑一遍，确认适配器的返回值形状与 migration.run 的约定对得上
t.describe("migration_adapter 与编排状态机", function()
    t.it("migrates a ready entity end to end", function()
        local h = harness({ entities = { entity() } })
        local stats = assert(migration.run(h.adapter, {}))
        t.expect(stats.total).to.equal(1)
        t.expect(stats.ready).to.equal(1)
        t.expect(stats.fallback).to.equal(0)
        local order = {}
        for _, call in ipairs(h.calls) do
            order[#order + 1] = call.cmd
        end
        t.expect(order).to.equal({
            "migration_list",
            "migration_quiesce",
            "freeze_owner",
            "session_export",
            "migration_release",
            "migration_stage",
            "migration_commit",
            "session_attach",
        })
    end)

    t.it("reports a critical-unknown entity as a fallback without touching it", function()
        local h = harness({ entities = { entity({ critical_unknown = true }) } })
        local stats = assert(migration.run(h.adapter, {}))
        t.expect(stats.critical_unknown).to.equal(1)
        t.expect(stats.ready).to.equal(0)
        -- 关键操作未决：不能无感移交，也不该被解冻（它本来就没冻结）
        t.expect(h.last_call("migration_quiesce")).to.be_nil()
        t.expect(h.last_call("migration_unquiesce")).to.be_nil()
    end)

    t.it("keeps the rest of the batch going when one entity fails", function()
        local h = harness({
            entities = { entity({ id = 7 }), entity({ id = 8, conn_id = "conn-8" }) },
        })
        h.quiesce_ok = false
        h.quiesce_err = "no session"
        local stats = assert(migration.run(h.adapter, {}))
        t.expect(stats.total).to.equal(2)
        t.expect(stats.ready).to.equal(0)
        t.expect(stats.fallback).to.equal(2)
    end)
end)

-- 停服超时后协调器只置 is_cancelled，卡在 cluster.call 里的阶段协程收不到。
-- 兜底必须主动解掉网关屏障，否则客户端上下行会被永久丢弃。
t.describe("migration_adapter 取消兜底", function()
    t.it("kicks every client still behind a barrier", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.freeze(e, "b1"))
        local stats = h.adapter.abort("shutdown deadline")
        t.expect(stats.kicked).to.equal(1)
        t.expect(stats.failed).to.equal(0)
        local kick = h.last_call("kick")
        t.expect(kick).to_not.be_nil()
        t.expect(kick.args[1]).to.equal("conn-7")
    end)

    t.it("does not kick a client whose new owner already resumed the barrier", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.freeze(e, "b1"))
        assert(h.adapter.transfer(e, { bytes = "BYTES" }))
        assert(h.adapter.handoff(e))
        assert(h.adapter.activate(e))
        local stats = h.adapter.abort("shutdown deadline")
        t.expect(stats.kicked).to.equal(0)
        t.expect(h.last_call("kick")).to.be_nil()
    end)

    t.it("does not kick twice after a fallback already handled the entity", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.freeze(e, "b1"))
        h.adapter.fallback(e, "no snapshot")
        local stats = h.adapter.abort("shutdown deadline")
        t.expect(stats.kicked).to.equal(0)
    end)

    t.it("refuses new phase RPCs after abort but still allows the abort kick", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.freeze(e, "b1"))
        h.adapter.abort("shutdown deadline")
        local snapshot, err = h.adapter.export(e, "b1")
        t.expect(snapshot).to.be_nil()
        t.expect(tostring(err)).to.match("migration aborted")
    end)

    -- 只踢客户端不够：目标端可能已经收到 stage，迟到的 commit 仍会接管
    t.it("tells the chosen target to reject a late commit", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.freeze(e, "b1"))
        assert(h.adapter.transfer(e, { bytes = "BYTES" }))
        h.adapter.abort("shutdown deadline")
        local abort_call = h.last_call("migration_abort")
        t.expect(abort_call).to_not.be_nil()
        t.expect(abort_call.target).to.equal("node-b!.entity_agent:role:1")
        t.expect(abort_call.args[1]).to.equal(7)
        t.expect(abort_call.args[2]).to.equal("b1")
        -- 客户端仍然要被踢下线重连
        t.expect(h.last_call("kick")).to_not.be_nil()
    end)

    t.it("does not notify a target that was never chosen", function()
        local h = harness()
        assert(h.adapter.freeze(entity(), "b1"))
        h.adapter.abort("shutdown deadline")
        t.expect(h.last_call("migration_abort")).to.be_nil()
        t.expect(h.last_call("kick")).to_not.be_nil()
    end)

    t.it("resets abort state when a new round begins", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.freeze(e, "b1"))
        h.adapter.abort("shutdown deadline")
        h.adapter.begin_round()
        local snapshot = h.adapter.export(e, "b1")
        t.expect(snapshot.bytes).to.equal("BYTES")
    end)

    -- A-11：通知目标走的是无超时的 cluster.call，而目标不可达恰恰是取消的常见原因。
    -- 先通知再踢的话，通知一阻塞，踢人循环就永远不跑，网关 frozen_epoch 留到进程退出，
    -- 玩家连接卡死——正好是取消兜底要避免的最坏结果
    t.it("kicks the client before trying to notify the target", function()
        local h = harness({ abort_raises = true })
        local e = entity()
        assert(h.adapter.freeze(e, "b1"))
        assert(h.adapter.transfer(e, { bytes = "B", barrier_id = "b1" }))
        local stats = h.adapter.abort("deadline")
        t.expect(stats.kicked).to.equal(1)
        t.expect(stats.notify_failed).to.equal(1)
        -- 顺序：kick 必须先于 migration_abort
        local kick_at, notify_at
        for i, call in ipairs(h.calls) do
            if call.cmd == "kick" then
                kick_at = kick_at or i
            elseif call.cmd == "migration_abort" then
                notify_at = notify_at or i
            end
        end
        t.expect(kick_at).to.exist()
        t.expect(notify_at).to.exist()
        t.expect(kick_at < notify_at).to.equal(true)
    end)

    t.it("keeps an entry whose kick failed so a later abort can retry", function()
        local opts = { kick_raises = true }
        local h = harness(opts)
        local e = entity()
        assert(h.adapter.freeze(e, "b1"))
        local first = h.adapter.abort("deadline")
        t.expect(first.kicked).to.equal(0)
        t.expect(first.failed).to.equal(1)
        -- 之前无条件清空 g_inflight，失败的连接就再也没有第二次机会
        t.expect(first.pending).to.equal(1)
        -- 网关恢复后，下一次取消必须补上这一脚
        opts.kick_raises = false
        local second = h.adapter.abort("retry")
        t.expect(second.kicked).to.equal(1)
        t.expect(second.pending).to.equal(0)
    end)

    t.it("does not count a rejected kick as success", function()
        -- call_gate 返回 (nil, "invalid conn_id") 时，pcall 本身是成功的，
        -- 旧实现只看 pcall 是否抛异常，把这种失败也计入 kicked
        local h = harness({ kick_ok = false })
        local e = entity()
        assert(h.adapter.freeze(e, "b1"))
        local stats = h.adapter.abort("deadline")
        t.expect(stats.kicked).to.equal(0)
        t.expect(stats.failed).to.equal(1)
    end)

    t.it("passes the round barrier when committing on the target", function()
        local h = harness()
        local e = entity()
        assert(h.adapter.freeze(e, "round-42"))
        assert(h.adapter.transfer(e, { bytes = "B", barrier_id = "round-42" }))
        assert(h.adapter.handoff(e))
        local call = h.last_call("migration_commit")
        -- 不带 barrier 的话，目标端只能用暂存快照去猜轮次
        t.expect(call.args[1]).to.equal(7)
        t.expect(call.args[2]).to.equal("round-42")
    end)
end)
