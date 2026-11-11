local t = require "skytest"
local skynet = require "skynet"
local queue = require "skynet.queue"
local fs = require "skyext.util.fs"
local connection_id = require "skyext.connection_id"
local lfs = require "lfs"
local errcode = require "skyext.errcode"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/entity_agent.lua")

-- 网关的注册名。登录服务转过来的绑定请求必须说清楚连接落在哪个网关上，
-- 裸 TCP 和 WebSocket 是两个进程
local GATE = ".gate_tcp"
local BOOT = string.rep("c", 32)
local function cid(seq, gate_node, gate_service)
    return assert(connection_id.new(gate_node or "gate1", gate_service or GATE, BOOT, seq))
end

local function harness(opts)
    opts = opts or {}
    local h = {
        events = {},
        bound = {},
        calls = {},
        deliveries = 0,
        cluster_calls = 0,
        registered_modules = {},
        aborted = {},
    }
    local noop = function() end
    local gates = {}
    local entity = { id = 7, data = { name = "before" } }
    h.entity = entity
    local fake_mgr = {}
    function fake_mgr:with_entity(id, f)
        t.expect(id).to.equal(7)
        local gate = gates[id]
        if not gate then
            gate = queue()
            gates[id] = gate
        end
        return gate(function()
            if h.with_entity_error then
                return false, h.with_entity_error, h.with_entity_owner
            end
            local result = table.pack(f(entity))
            return true, table.unpack(result, 1, result.n)
        end)
    end
    function fake_mgr:with_loaded_entity(id, f)
        t.expect(id).to.equal(7)
        if h.lease_expired then
            return false, "expired"
        end
        return self:with_entity(id, f)
    end
    function fake_mgr:ensure_loaded(id)
        t.expect(id).to.equal(7)
        if h.ensure_error then
            return false, h.ensure_error
        end
        return true, entity
    end
    function fake_mgr:unload_all()
        h.events[#h.events + 1] = "unload_all"
        return h.unload_remaining or 0
    end
    function fake_mgr:try_ensure_loaded(id)
        t.expect(id).to.equal(7)
        return not h.lock_error, h.lock_error, h.owner
    end
    function fake_mgr:unload(id)
        t.expect(id).to.equal(7)
        h.events[#h.events + 1] = "unload"
        return h.unload_ok ~= false
    end
    function fake_mgr:deliver_pending(id, opts)
        t.expect(id).to.equal(7)
        h.deliveries = h.deliveries + 1
        h.deliver_opts = opts
        if h.with_entity_error then
            return false, h.with_entity_error, h.with_entity_owner
        end
        return h.deliver_ok ~= false, h.deliver_error
    end
    h.mgr = fake_mgr

    local fake_session = {}
    function fake_session.init(manager)
        t.expect(manager).to.equal(fake_mgr)
    end
    function fake_session.key(conn_id)
        return conn_id
    end
    function fake_session.parse_conn(conn_id)
        return connection_id.parse(conn_id)
    end
    function fake_session.get_entity(key)
        return h.bound[key]
    end
    function fake_session.bind(conn_id, e, owner_service)
        if h.session_bind_result == false then
            return false
        end
        local parsed = assert(connection_id.parse(conn_id))
        local key = fake_session.key(conn_id)
        h.bound[key] = e
        e.session = { conn_id = conn_id, gate_node = parsed.gate_node, gate_service = parsed.gate_service, key = key }
        h.bind_gate_service = parsed.gate_service
        h.bind_owner = owner_service
        h.events[#h.events + 1] = "bind"
        return true, "nonce-" .. tostring(parsed.local_seq)
    end
    function fake_session.resume(conn_id, e, owner_service, nonce, recv)
        if h.session_resume_code and h.session_resume_code ~= errcode.OK then
            return h.session_resume_code
        end
        local parsed = assert(connection_id.parse(conn_id))
        local key = fake_session.key(conn_id)
        if e.session then
            h.bound[e.session.key] = nil
        end
        h.bound[key] = e
        e.session = { conn_id = conn_id, gate_node = parsed.gate_node, gate_service = parsed.gate_service, key = key }
        h.resume_args = { nonce = nonce, recv = recv, owner = owner_service }
        h.events[#h.events + 1] = "resume"
        return errcode.OK, "nonce-" .. tostring(parsed.local_seq), 42
    end
    function fake_session.replay()
        h.events[#h.events + 1] = "replay"
    end
    fake_session.cmds = { ping = function() end }
    function fake_session.unbind(key)
        local e = h.bound[key]
        h.bound[key] = nil
        if e and e.session and e.session.key == key then
            e.session = nil
        end
        h.events[#h.events + 1] = "unbind"
    end
    function fake_session.unbind_kick(key, expected_entity)
        t.expect(expected_entity).to.equal(h.bound[key])
        fake_session.unbind(key)
        h.events[#h.events + 1] = "kick"
    end

    local fake_cluster = {}
    function fake_cluster.call(node, agent, command, id, ...)
        h.cluster_call = { node, agent, command, id, ... }
        h.cluster_calls = h.cluster_calls + 1
        if h.cluster_error then
            error(h.cluster_error)
        end
        if h.release_clears_lock then
            -- 上一个持有者真的放了手：之后的重试应该能拿到实体
            h.with_entity_error = nil
            h.lock_error = nil
        end
        if command ~= "unload_entity" then
            -- 持锁节点对转发请求的回复
            return table.unpack(h.remote_reply or { true }, 1, h.remote_reply and h.remote_reply.n or 1)
        end
        return h.cluster_released ~= false
    end

    h.handler = {
        handlers = {
            change = function(e, value)
                h.events[#h.events + 1] = "handler-start"
                if h.pause_handler then
                    skynet.sleep(5)
                end
                e.data.name = value
                h.events[#h.events + 1] = "handler-end"
                return value, nil, 3
            end,
        },
        on_bind_client = function(_, key)
            h.events[#h.events + 1] = "on_bind:" .. key
        end,
        on_unbind_client = function()
            h.events[#h.events + 1] = "on_unbind"
        end,
        on_resume_client = function(_, key)
            h.events[#h.events + 1] = "on_resume:" .. key
        end,
    }
    local fake_skynet = setmetatable({
        start = function(fn)
            h.boot = fn
        end,
        register = function(name)
            h.registered = name
        end,
    }, { __index = skynet })
    local imports = {
        skynet = fake_skynet,
        ["skyext.cmd_api"] = {
            dispatch = function(commands)
                h.CMD = commands
            end,
        },
        ["skyext.entity.types"] = {
            get = function()
                return { client_enabled = true }
            end,
            format_agent_service_name = function()
                return ".entity_agent:role:1"
            end,
            calc_agent_index = function()
                return 1
            end,
        },
        ["skyext.entity.entitymgr"] = {
            NOT_LOADED = "not loaded",
            new = function()
                return fake_mgr
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                if key == "cluster_node_name" then
                    return "node-a"
                end
            end,
        },
        ["skyext.distributed_lock"] = {
            shutdown = function()
                h.lock_closed = (h.lock_closed or 0) + 1
                return true
            end,
        },
        ["skyext.entity.session"] = fake_session,
        ["skyext.log"] = { info = noop, warn = noop, error = noop },
        ["skyext.errcode"] = errcode,
        ["skynet.cluster"] = fake_cluster,
        ["entity_handler.role"] = h.handler,
        ["skyext.sproto_api"] = {
            abort_conn = function(conn_id)
                h.aborted[#h.aborted + 1] = conn_id
                return 0
            end,
            dispatch_message = function(conn, data)
                h.dispatched = { conn = conn, data = data }
            end,
            register_module = function(name, module, request)
                t.expect(module).to.equal(fake_session)
                h.registered_modules[#h.registered_modules + 1] = { name = name, request = request }
            end,
        },
    }
    for name, mod in pairs(opts.module_sources or {}) do
        imports[name] = mod
    end
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))("role", "1")
    h.boot()
    h.start_conf = { modules_path = "modules", modules = opts.modules or {} }
    if not opts.manual_start then
        h.CMD.start(h.start_conf)
    end
    return h
end

t.describe("entity_agent serialized ingress", function()
    t.it("runs RPC handlers through the entity gate and preserves multiple return values", function()
        local h = harness()
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ true, "new", nil, 3, n = 4 })
        t.expect(h.entity.data.name).to.equal("new")
        h.with_entity_error = "no lease"
        t.expect(table.pack(h.CMD.entity_call(7, "change", "ignored"))).to.equal({ false, "no lease", n = 2 })
        t.expect(h.entity.data.name).to.equal("new")
    end)

    t.it("serializes concurrent entity_call and entity_send handlers for one entity", function()
        local h = harness()
        h.pause_handler = true
        local done = 0
        skynet.fork(function()
            h.CMD.entity_call(7, "change", "first")
            done = done + 1
        end)
        skynet.sleep(1)
        skynet.fork(function()
            h.CMD.entity_send(7, "change", "second")
            done = done + 1
        end)
        for _ = 1, 30 do
            if done == 2 then
                break
            end
            skynet.sleep(1)
        end
        t.expect(done).to.equal(2)
        t.expect(h.events).to.equal({ "handler-start", "handler-end", "handler-start", "handler-end" })
        t.expect(h.entity.data.name).to.equal("second")
    end)

    t.it("does not bind a session while a handler owns the entity gate", function()
        local h = harness()
        h.pause_handler = true
        local done = 0
        skynet.fork(function()
            h.CMD.entity_call(7, "change", "first")
            done = done + 1
        end)
        skynet.sleep(1)
        skynet.fork(function()
            t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.OK)
            done = done + 1
        end)
        skynet.sleep(1)
        t.expect(h.bound[cid(9)]).to.be_nil()
        for _ = 1, 30 do
            if done == 2 then
                break
            end
            skynet.sleep(1)
        end
        t.expect(done).to.equal(2)
        t.expect(h.events).to.equal({ "handler-start", "handler-end", "bind", "on_bind:" .. cid(9) })
    end)

    t.it("wakes ordered persistent delivery instead of executing or acknowledging inline", function()
        local h = harness()
        t.expect(h.CMD.__deliver_reliable(7, 11, "missing", { "ignored" })).to.equal(true)
        t.expect(h.deliveries).to.equal(1)
        t.expect(h.events).to.equal({})
        h.deliver_ok = false
        h.deliver_error = "persistence failed"
        t.expect(h.CMD.__deliver_reliable(7)).to.equal(false)
        t.expect(h.deliveries).to.equal(2)
    end)

    t.it("remote handoff uses a verified owner and requires confirmed unload", function()
        local h = harness()
        h.lock_error = "etcd unavailable"
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.LOCK_FAILED)
        t.expect(h.cluster_call).to.be_nil()
        h.lock_error = "lock held"
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.LOCK_FAILED)
        h.owner = "node-b"
        h.cluster_released = false
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.IN_OTHER_NODE)
        t.expect(h.cluster_call).to.equal({ "node-b", ".entity_agent:role:1", "unload_entity", 7 })
        t.expect(h.bound[cid(9)]).to.be_nil()
        h.cluster_error = "node down"
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.IN_OTHER_NODE)
        h.cluster_error = nil
        h.cluster_released = true
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.OK)
        t.expect(h.bound[cid(9)]).to.equal(h.entity)
        -- 绑定成功后 gate 被指向本 agent，后续上行包直接转给它，不再经过 watchdog
        t.expect(h.bind_owner).to.equal(".entity_agent:role:1")
    end)

    t.it("bind_session reports SESSION_CLOSED when the gate already dropped the connection", function()
        local h = harness()
        h.session_bind_result = false
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.SESSION_CLOSED)
        t.expect(h.bound[cid(9)]).to.be_nil()
    end)

    t.it("bind_session kicks the previous session when a role relogs on a new connection", function()
        local h = harness()
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.OK)
        t.expect(h.CMD.bind_session(7, cid(10))).to.equal(errcode.OK)
        -- 旧会话被解绑并踢掉，新会话生效
        t.expect(h.bound[cid(9)]).to.be_nil()
        t.expect(h.bound[cid(10)]).to.equal(h.entity)
        t.expect(h.entity.session.key).to.equal(cid(10))
        t.expect(h.events).to.equal({ "bind", "on_bind:" .. cid(9), "unbind", "kick", "bind", "on_bind:" .. cid(10) })
    end)

    t.it("resume_session replays the backlog before telling the handler, and rotates the credential", function()
        local h = harness()
        h.CMD.bind_session(7, cid(9))
        h.events = {}
        local code, nonce, sent = h.CMD.resume_session(7, cid(5, "gate2", ".gate_ws"), "nonce-9", 3)
        t.expect(code).to.equal(errcode.OK)
        t.expect(nonce).to.equal("nonce-5")
        t.expect(sent).to.equal(42)
        t.expect(h.resume_args).to.equal({ nonce = "nonce-9", recv = 3, owner = ".entity_agent:role:1" })
        -- 重放必须排在 on_resume_client 之前：回调里推的新包要跟在旧包后面
        t.expect(h.events).to.equal({ "resume", "replay", "on_resume:" .. cid(5, "gate2", ".gate_ws") })
        t.expect(h.bound[cid(9)]).to.be_nil()
        t.expect(h.bound[cid(5, "gate2", ".gate_ws")]).to.equal(h.entity)
    end)

    t.it("resume_session passes the session layer's refusal through untouched", function()
        local h = harness()
        h.CMD.bind_session(7, cid(9))
        h.events = {}
        h.session_resume_code = errcode.AUTH_FAILED
        t.expect(h.CMD.resume_session(7, cid(5, "gate2", ".gate_ws"), "wrong", 0)).to.equal(errcode.AUTH_FAILED)
        t.expect(h.events).to.equal({})
        t.expect(h.bound[cid(9)]).to.equal(h.entity)
    end)

    -- 续接绝不加载实体：不验 token、不查库，能触发加载就等于开放一个无认证的接口
    t.it("resume_session refuses rather than load an entity that is no longer in memory", function()
        local h = harness()
        h.lease_expired = true
        t.expect(h.CMD.resume_session(7, cid(9), "nonce-9", 0)).to.equal(errcode.ENTITY_NOT_FOUND)
        t.expect(h.events).to.equal({})
    end)

    t.it("does not hand off to itself when its previous process still holds the lock", function()
        local h = harness()
        h.lock_error = "lock held"
        h.owner = "node-a"
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.LOCK_FAILED)
        t.expect(h.cluster_calls).to.equal(0)
    end)

    t.it("reports a missing entity instead of a lock failure", function()
        local h = harness()
        h.lock_error = "not found"
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.ENTITY_NOT_FOUND)
    end)

    t.it("forwards a call to the node holding the lock instead of taking the entity", function()
        -- 集群成员变化后路由指到了这里，但实体还在上一个节点上：转过去执行，不卸载
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.remote_reply = table.pack(true, "remote")
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ true, "remote", n = 2 })
        t.expect(h.cluster_call).to
            .equal({ "node-b", ".entity_agent:role:1", "entity_call_loaded", 7, "change", "new" })
        t.expect(h.cluster_calls).to.equal(1)
        t.expect(h.events).to.equal({})
        t.expect(h.entity.data.name).to.equal("before")
    end)

    t.it("runs locally once more when the holder has already unloaded the entity", function()
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.release_clears_lock = true
        h.remote_reply = table.pack(false, "not loaded")
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ true, "new", nil, 3, n = 4 })
        t.expect(h.cluster_calls).to.equal(1)
        t.expect(h.entity.data.name).to.equal("new")
    end)

    t.it("gives up after one forward so two nodes cannot bounce a request", function()
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.remote_reply = table.pack(false, "not loaded")
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ false, "lock held", n = 2 })
        t.expect(h.cluster_calls).to.equal(1)
        t.expect(h.entity.data.name).to.equal("before")
    end)

    t.it("raises a failed forward instead of retrying it locally", function()
        -- 分不清是没送到还是对方 handler 执行到一半，重试可能让副作用发生两次
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.cluster_error = "node down"
        t.expect(function()
            h.CMD.entity_call(7, "change", "new")
        end).to
            .throw("node down")
        t.expect(h.cluster_calls).to.equal(1)
        t.expect(h.entity.data.name).to.equal("before")
    end)

    t.it("does not forward without an owner, to itself, or for other failures", function()
        local h = harness()
        h.with_entity_error = "lock held"
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ false, "lock held", n = 2 })
        h.with_entity_owner = "node-a"
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ false, "lock held", n = 2 })
        h.with_entity_error = "entity lease expired"
        h.with_entity_owner = "node-b"
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ false, "entity lease expired", n = 2 })
        t.expect(h.cluster_calls).to.equal(0)
    end)

    t.it("entity_send is forwarded the same way", function()
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.CMD.entity_send(7, "change", "sent")
        t.expect(h.cluster_call).to
            .equal({ "node-b", ".entity_agent:role:1", "entity_call_loaded", 7, "change", "sent" })
        t.expect(h.events).to.equal({})
    end)

    t.it("forwarded calls only touch an entity that is already loaded", function()
        local h = harness()
        t.expect(table.pack(h.CMD.entity_call_loaded(7, "change", "fwd"))).to.equal({ true, "fwd", nil, 3, n = 4 })
        h.lease_expired = true
        t.expect(table.pack(h.CMD.entity_call_loaded(7, "change", "late"))).to.equal({ false, "expired", n = 2 })
        t.expect(h.entity.data.name).to.equal("fwd")
    end)

    t.it("wakes reliable delivery on the node holding the lock", function()
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        t.expect(h.CMD.__deliver_reliable(7)).to.equal(true)
        t.expect(h.cluster_call).to.equal({ "node-b", ".entity_agent:role:1", "deliver_reliable_loaded", 7 })
        h.with_entity_error = nil
        t.expect(h.CMD.deliver_reliable_loaded(7)).to.equal(true)
        t.expect(h.deliver_opts).to.equal({ loaded_only = true })
    end)

    t.it("activate loads an entity and reports why it could not", function()
        local h = harness()
        t.expect(table.pack(h.CMD.activate(7))).to.equal({ true, nil, n = 2 })
        h.ensure_error = "lock held"
        t.expect(table.pack(h.CMD.activate(7))).to.equal({ false, "lock held", n = 2 })
    end)

    t.it("shutdown unloads every entity and reports what is left", function()
        local h = harness()
        h.unload_remaining = 2
        t.expect(h.CMD.shutdown()).to.equal(2)
        -- 还有实体没卸掉时锁租约必须留着，它们落库、解锁都要用
        t.expect(h.lock_closed).to.be_nil()
        h.unload_remaining = 0
        t.expect(h.CMD.shutdown()).to.equal(0)
        t.expect(h.lock_closed).to.equal(1)
        t.expect(h.events).to.equal({ "unload_all", "unload_all" })
    end)

    t.it("entity_send_loaded never loads an entity that is not in memory", function()
        local h = harness()
        h.handler.handlers.peek = function()
            h.peeked = true
        end
        h.lease_expired = true
        t.expect(h.CMD.entity_send_loaded(7, "peek")).to.equal(false)
        t.expect(h.peeked).to.be_nil()

        h.lease_expired = nil
        h.mgr:ensure_loaded(7)
        t.expect(h.CMD.entity_send_loaded(7, "peek")).to.equal(true)
        t.expect(h.peeked).to.equal(true)
    end)

    t.it("rejects an invalid conn_id on every entry point", function()
        local h = harness()
        t.expect(h.CMD.bind_session(7, "not-a-conn-id")).to.equal(errcode.PARAM_ERROR)
        t.expect(h.CMD.resume_session(7, "not-a-conn-id", "nonce", 0)).to.equal(errcode.PARAM_ERROR)
        h.CMD.client_msg("not-a-conn-id", "DATA")
        t.expect(h.dispatched).to.be_nil()
        h.CMD.session_closed("not-a-conn-id")
        t.expect(h.events).to.equal({})
    end)

    t.it("dispatches a valid conn_id to the protocol layer untouched", function()
        local h = harness()
        h.CMD.client_msg(cid(9), "DATA")
        t.expect(h.dispatched).to.equal({ conn = cid(9), data = "DATA" })
    end)

    t.it("session_closed respects the entity gate and unbinds an expired session", function()
        local h = harness()
        t.expect(h.CMD.bind_session(7, cid(9))).to.equal(errcode.OK)
        h.CMD.session_closed(cid(9))
        t.expect(h.bound[cid(9)]).to.be_nil()
        t.expect(h.events[#h.events]).to.equal("on_unbind")
        h.CMD.bind_session(7, cid(10))
        h.lease_expired = true
        h.CMD.session_closed(cid(10))
        t.expect(h.bound[cid(10)]).to.be_nil()
        t.expect(h.events[#h.events]).to.equal("unbind")
    end)

    t.it("aborts in-flight active RPCs when the connection closes", function()
        local h = harness()
        h.CMD.session_closed(cid(9))
        -- abort_conn 必须挂在真实断连路径上，而不是只留一个没人调用的辅助函数
        t.expect(h.aborted).to.equal({ cid(9) })
    end)

    t.it("propagates unload success or failure to the remote handoff caller", function()
        local h = harness()
        h.unload_ok = false
        t.expect(h.CMD.unload_entity(7)).to.equal(false)
        h.unload_ok = true
        t.expect(h.CMD.unload_entity(7)).to.equal(true)
    end)
end)

t.describe("entity_agent module loading", function()
    local MODULES = {
        { name = "bag", init = true, request = true },
        { name = "mail", init = false, request = true },
        { name = "note", init = true, request = false },
    }

    local function sources()
        return {
            ["modules.bag"] = { new = function() end },
            ["modules.bag.request"] = { use = function() end },
            ["modules.mail.request"] = { read = function() end },
            ["modules.note"] = { new = function() end },
        }
    end

    -- 心跳、续接这类传输层协议也注册成 "login.*"，和业务模块走同一条分发路径
    local LOGIN_MODULE = { name = "login", request = { ping = true } }

    local function without_login(registered)
        local out = {}
        for _, entry in ipairs(registered) do
            if entry.name ~= "login" then
                out[#out + 1] = entry
            end
        end
        return out
    end

    t.it("registers exactly the request modules that exist on disk, plus the transport protocols", function()
        local src = sources()
        local h = harness({ modules = MODULES, module_sources = src })
        t.expect(#h.registered_modules).to.equal(3)
        t.expect(h.registered_modules[3].name).to.equal(LOGIN_MODULE.name)
        t.expect(without_login(h.registered_modules)).to.equal({
            { name = "bag", request = src["modules.bag.request"] },
            { name = "mail", request = src["modules.mail.request"] },
        })
    end)

    t.it("only keeps init modules that expose new", function()
        local h = harness({
            modules = {
                { name = "bag", init = true, request = false },
                { name = "plain", init = true, request = false },
            },
            module_sources = {
                ["modules.bag"] = { new = function() end },
                ["modules.plain"] = { helper = function() end },
            },
        })
        t.expect(without_login(h.registered_modules)).to.equal({})
    end)

    -- 回归：路径配错时 require 失败必须炸掉启动。
    -- 以前这里是 pcall 吞掉的，结果协议一个都没注册，客户端只能看到超时。
    t.it("fails agent start when a request module cannot be loaded", function()
        local src = sources()
        src["modules.mail.request"] = nil
        local h = harness({ modules = MODULES, module_sources = src, manual_start = true })
        t.expect(function()
            h.CMD.start(h.start_conf)
        end).to
            .throw("modules.mail.request")
        t.expect(h.registered_modules).to.equal({ { name = "bag", request = src["modules.bag.request"] } })
    end)

    t.it("fails agent start when an init module cannot be loaded", function()
        local src = sources()
        src["modules.bag"] = nil
        local h = harness({ modules = MODULES, module_sources = src, manual_start = true })
        t.expect(function()
            h.CMD.start(h.start_conf)
        end).to
            .throw("modules.bag")
    end)

    t.it("rejects a request module that does not return a table", function()
        local src = sources()
        src["modules.mail.request"] = function() end
        local h = harness({ modules = MODULES, module_sources = src, manual_start = true })
        t.expect(function()
            h.CMD.start(h.start_conf)
        end).to
            .throw("modules%.mail%.request must return a table")
    end)
end)

t.describe("entity_agent 框架内部命令", function()
    -- `router.call` 固定走 entity_call，只认 handler.handlers。框架命令（Outbox 调度、
    -- 支付发奖、对账查证）必须在这里注册，否则永远是 unknown entity command
    t.it("dispatches framework commands through entity_call", function()
        local h = harness()
        local ok, result = h.CMD.entity_call(7, "critical_status", "srv_" .. string.rep("a", 64))
        t.expect(ok).to.equal(true)
        -- 测试实体没有 db 坐标：读不到状态时必须回 UNKNOWN，而不是"没执行"
        t.expect(result.status).to.equal("UNKNOWN")
    end)

    t.it("never claims NOT_STARTED when the cold ledger is not configured", function()
        local h = harness()
        local ok, result = h.CMD.entity_call(7, "critical_status", "srv_" .. string.rep("a", 64))
        t.expect(ok).to.equal(true)
        -- 热条目可能已被归档搬走；没有冷账本就没有资格判断"从未执行"，
        -- 否则支付对账会拿同一个 service_op_id 再发一次奖
        t.expect(result.status).to.equal("UNKNOWN")
        t.expect(result.reason).to.equal("critical_ledger is not configured")
    end)

    t.it("does not let a business handler hijack a framework command", function()
        local h = harness()
        h.handler.handlers.charge_grant = function()
            return "hijacked"
        end
        local ok, result, err = h.CMD.entity_call(7, "charge_grant", {})
        t.expect(ok).to.equal(true)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("entity handler has no charge_handlers")
    end)

    t.it("still rejects a genuinely unknown command", function()
        local h = harness()
        local ok = pcall(function()
            h.CMD.entity_call(7, "no_such_command")
        end)
        t.expect(ok).to.equal(false)
    end)
end)

t.describe("entity_agent 会话迁移命令", function()
    local function session_io()
        return {
            session_epoch = string.rep("a", 32),
            session_mode = 1,
            nonce = "nonce-bytes",
            sent = 2,
            acked = 1,
            out_buf = { [2] = "PACK-2" },
            out_bytes = 6,
            resp_cache = {},
            resp_order = { head = 1, tail = 0 },
            resp_bytes = 0,
            min_cached_req_id = 0,
            owner_epoch = 3,
            unresumable = false,
            replaying = false,
        }
    end

    -- 快照只搬字节：out_buf 里的包是已经编码好的，重包装会让客户端按
    -- (session_epoch, seq) 去重时错位
    t.it("exports and imports the same session bytes", function()
        local source = harness()
        source.entity.session_io = session_io()
        local ok, exported = source.CMD.entity_call(7, "session_export", "b1")
        t.expect(ok).to.equal(true)
        t.expect(exported.session_epoch).to.equal(string.rep("a", 32))
        -- 新 owner 的 epoch 必须严格前进，否则网关会继续放行旧 owner 的下行
        t.expect(exported.owner_epoch).to.equal(4)
        t.expect(exported.sent).to.equal(2)
        -- 导出即冻结源：之后不再追加 out_buf，否则目标拿到的是过期快照
        t.expect(source.entity.session_io.migrating).to.equal(true)

        local target = harness()
        local imported_ok, result = target.CMD.entity_call(7, "session_import", exported)
        t.expect(imported_ok).to.equal(true)
        t.expect(result.sent).to.equal(2)
        t.expect(result.owner_epoch).to.equal(4)
        t.expect(target.entity.session_io.out_buf[2]).to.equal("PACK-2")
        -- wire 上的会话身份必须保持不变
        t.expect(target.entity.session_io.session_epoch).to.equal(string.rep("a", 32))
    end)

    t.it("refuses to export without a session io", function()
        local h = harness()
        local ok, result = h.CMD.entity_call(7, "session_export", "b1")
        t.expect(ok).to.equal(true)
        t.expect(result).to.be_nil()
    end)

    t.it("refuses a snapshot that would move the owner epoch backwards", function()
        local h = harness()
        h.entity.session_io = session_io()
        local payload = { bytes = "", session_epoch = string.rep("a", 32), owner_epoch = 1 }
        local ok, result, err = h.CMD.entity_call(7, "session_import", payload)
        t.expect(ok).to.equal(true)
        t.expect(result).to.be_nil()
        t.expect(err).to_not.be_nil()
        -- 失败时不能改动目标上已有的会话
        t.expect(h.entity.session_io.owner_epoch).to.equal(3)
    end)

    t.it("refuses a corrupted snapshot", function()
        local h = harness()
        local ok, result, err = h.CMD.entity_call(7, "session_import", {
            bytes = "SKXS" .. string.rep("\0", 60),
            session_epoch = string.rep("a", 32),
            owner_epoch = 1,
        })
        t.expect(ok).to.equal(true)
        t.expect(result).to.be_nil()
        t.expect(err).to_not.be_nil()
        t.expect(h.entity.session_io).to.be_nil()
    end)
end)
