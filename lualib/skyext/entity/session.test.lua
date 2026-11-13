local t = require "skytest"
local skynet = require "skynet"
local downlink = require "skyext.downlink"
local errcode = require "skyext.errcode"
local fs = require "skyext.util.fs"
local connection_id = require "skyext.connection_id"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/entity/session.lua")

-- 本节点名：会话键里的 gate_node 等于它时走本地消息，否则走 cluster
local SELF_NODE = "role1"
local GATE = ".gate_tcp"
local OWNER = ".entity_agent:role:1"
local BOOT = string.rep("b", 32)

-- 网关生成的连接标识。测试用固定 boot_id + 序号，断言可以直接比较字符串
local function cid(seq, gate_node, gate_service)
    return assert(connection_id.new(gate_node or SELF_NODE, gate_service or GATE, BOOT, seq))
end

-- 16 字节：session_epoch 要求 16 字节随机源，nonce 的断言也基于同一格式
local function fake_nonce(n)
    return string.format("nonce%011d", n)
end

local function harness(opts)
    opts = opts or {}
    local h = { kicks = {}, gate_ops = {}, mgr_calls = 0, now = 10000, nonce_seq = 0, conf = opts.conf or {} }
    local noop = function() end

    h.entity = { type_name = "role", id = 7 }

    local fake_mgr = {}
    -- 行为对齐 entitymgr:with_loaded_entity：进不去串行队列时返回 false, reason，
    -- 处理期间丢租约同样返回 false
    function fake_mgr:with_loaded_entity(id, f)
        h.mgr_calls = h.mgr_calls + 1
        h.mgr_id = id
        if h.not_loaded then
            return false, "entity not loaded or lease expired"
        end
        if h.before_handler then
            local cb = h.before_handler
            h.before_handler = nil
            cb()
        end
        local result = table.pack(f(h.active or h.entity))
        if h.expire_during then
            return false, "entity lease expired during handler"
        end
        return true, table.unpack(result, 1, result.n)
    end
    function fake_mgr:touch(id)
        h.touched = id
    end
    function fake_mgr:get(id)
        if h.entity and h.entity.id == id and not h.entity_gone then
            return h.entity
        end
        return nil
    end

    -- 网络网关：同节点走 skynet 本地消息，跨节点走 cluster。两者都把原始字节交给网关
    local function record_call(transport, node, service, cmd, ...)
        local op = { transport, cmd, ... }
        h.last_gate_service = service
        if node then
            table.insert(op, 2, node)
        end
        h.gate_ops[#h.gate_ops + 1] = op
        return op
    end
    local function record_kick(node, fd)
        h.kicks[#h.kicks + 1] = { node = node, fd = fd }
    end

    local fake_skynet = setmetatable({
        now = function()
            return h.now
        end,
        send = function(addr, proto, cmd, ...)
            t.expect(proto).to.equal("lua")
            local op = record_call("local", nil, addr, cmd, ...)
            if cmd == "kick" then
                record_kick(SELF_NODE, op[3])
            end
        end,
        call = function(addr, proto, cmd, ...)
            t.expect(proto).to.equal("lua")
            record_call("local", nil, addr, cmd, ...)
            if cmd == "bind" then
                if h.gate_bind_raises then
                    error("gate bind timeout")
                end
                return h.gate_bind_result ~= false
            end
            if cmd == "resume_owner" then
                return h.gate_resume_result ~= false
            end
            return true
        end,
    }, { __index = skynet })

    -- 跨节点的网关走 cluster：cluster.send/call 不像 skynet.send/call 带 proto，
    -- 参数直接就是 (node, address, cmd, ...)
    local fake_cluster = {
        send = function(node, addr, cmd, ...)
            local op = record_call("cluster", node, addr, cmd, ...)
            if cmd == "kick" then
                record_kick(node, op[4])
            end
        end,
        call = function(node, addr, cmd, ...)
            record_call("cluster", node, addr, cmd, ...)
            if cmd == "bind" then
                if h.gate_bind_raises then
                    error("gate bind timeout")
                end
                return h.gate_bind_result ~= false
            end
            if cmd == "resume_owner" then
                return h.gate_resume_result ~= false
            end
            return true
        end,
    }

    local fake_sproto = {
        set_sender = function(sender)
            h.sender = sender
        end,
        encode_notify = function(name, msg)
            return "PACK:" .. name .. ":" .. tostring(msg and msg.id or "")
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skynet.cluster"] = fake_cluster,
        -- 续接凭据必须不可预测，但测试要能断言"轮换过了"，所以发可递增的假值
        crypto = {
            random_bytes = function()
                h.nonce_seq = h.nonce_seq + 1
                return fake_nonce(h.nonce_seq)
            end,
            const_equals = function(a, b)
                return a == b
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("cluster_node_name")
                return SELF_NODE
            end,
            get_number = function(key)
                return h.conf[key]
            end,
        },
        ["skyext.log"] = { info = noop, warn = noop, error = noop, debug = noop },
        ["skyext.timer"] = {
            repeat_delayed = function(_, _, f)
                h.idle_sweep = f
            end,
        },
        ["skyext.sproto_api"] = fake_sproto,
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.session = assert(loadfile(source, "t", env))()
    if not opts.no_mgr then
        h.session.init(fake_mgr)
    end
    h.mgr = fake_mgr
    return h
end

-- 绑定会话并返回会话键
local function bind(h, seq, gate_node, entity)
    gate_node = gate_node or SELF_NODE
    entity = entity or h.entity
    local key = cid(seq, gate_node)
    local ok, nonce = h.session.bind(key, entity, OWNER)
    return ok, key, nonce
end

-- 只保留 push 操作，断言下行顺序时用
local function pushes(h)
    local out = {}
    for _, op in ipairs(h.gate_ops) do
        if op[2] == "push" then
            -- op = { transport, "push", conn_id, pack, owner_epoch }
            out[#out + 1] = op[4]
        end
    end
    return out
end

t.describe("session bind", function()
    t.it("installs the session, cancels a pending unload and points the gate at this service", function()
        local h = harness()
        local cancelled = false
        h.entity.unload_timer = {
            cancel = function()
                cancelled = true
            end,
        }
        local ok, key, nonce = bind(h, 9)
        t.expect(ok).to.equal(true)
        t.expect(key).to.equal(cid(9))
        t.expect(nonce).to.equal(fake_nonce(1))
        t.expect(h.entity.session.key).to.equal(cid(9))
        t.expect(h.entity.session.gate_service).to.equal(GATE)
        t.expect(h.entity.unload_timer).to.be_nil()
        t.expect(cancelled).to.equal(true)
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "local", "bind", cid(9), "role1", OWNER, 1 })
    end)

    t.it("refuses a bind with an invalid conn_id instead of guessing a gate", function()
        local h = harness()
        t.expect(h.session.bind("not-a-conn-id", h.entity, OWNER)).to.equal(false)
        t.expect(h.entity.session).to.be_nil()
        t.expect(h.gate_ops).to.equal({})
    end)

    t.it("routes the bind to a remote gate over cluster", function()
        local h = harness()
        local ok, key = bind(h, 9, "gate1")
        t.expect(ok).to.equal(true)
        t.expect(key).to.equal(cid(9, "gate1"))
        t.expect(h.entity.session.key).to.equal(cid(9, "gate1"))
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "cluster", "gate1", "bind", cid(9, "gate1"), "role1", OWNER, 1 })
    end)

    t.it("reports failure when the gate already dropped the connection", function()
        local h = harness()
        h.gate_bind_result = false
        local ok = h.session.bind(cid(9), h.entity, OWNER)
        t.expect(ok).to.equal(false)
        t.expect(h.entity.session).to.be_nil()
        t.expect(h.entity.session_io).to.be_nil()
    end)

    -- 顶号和同账号重登走的是同一个实体对象，沿用旧 session_io 会让后来者继承前一个
    -- 客户端的凭据、计数和响应缓存
    t.it("rebuilds the session state on every login so a relog cannot inherit it", function()
        local h = harness()
        local _, _, first = bind(h, 9)
        h.session.push(h.entity, "mail_notify", { id = 1 })
        t.expect(h.entity.session_io.sent).to.equal(1)

        local _, _, second = bind(h, 10)
        t.expect(second).to_not.equal(first)
        t.expect(h.entity.session_io.sent).to.equal(0)
        t.expect(h.entity.session_io.acked).to.equal(0)

        -- 旧凭据对新会话无效
        t.expect(h.session.resume(cid(11), h.entity, OWNER, first, 0)).to.equal(errcode.AUTH_FAILED)
    end)
end)

t.describe("session request gating", function()
    -- req_id 直接来自客户端包头：超出 u32 会让会话快照的 `<I4` 编码抛错，
    -- 迁移每次失败、角色被永久钉在本节点。必须在入口拦住
    t.it("rejects a request id outside the u32 range before running the handler", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ran = false
        local ok, reason = h.session.with_request(key, function()
            ran = true
        end, 0x100000000)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("invalid request id")
        t.expect(ran).to.equal(false)

        t.expect(h.session.with_request(key, function() end, -1)).to.equal(false)
        t.expect(h.session.with_request(key, function() end, 1.5)).to.equal(false)
        -- 上界是 0xFFFFFFFE：淘汰会写 min_cached_req_id = req_id + 1，
        -- 留一个值给它，否则淘汰最后一个 id 之后快照编码同样溢出
        t.expect(h.session.with_request(key, function() end, 0xFFFFFFFF)).to.equal(false)
    end)

    t.it("runs the handler inside the entity gate and keeps all of its return values", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ok, a, b = h.session.with_request(key, function()
            return "pack", 3
        end)
        t.expect(ok).to.equal(true)
        t.expect(a).to.equal("pack")
        t.expect(b).to.equal(3)
        t.expect(h.mgr_id).to.equal(7)
    end)

    t.it("reports success when the handler produced nothing", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ok, result = h.session.with_request(key, function() end)
        t.expect(ok).to.equal(true)
        t.expect(result).to.be_nil()
    end)

    t.it("rejects with a reason instead of silently dropping unbound requests", function()
        local h = harness()
        local ran = false
        local ok, reason = h.session.with_request(cid(9), function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client not bound")
        t.expect(ran).to.equal(false)
        t.expect(h.mgr_calls).to.equal(0)
    end)

    t.it("rejects requests that arrive before the entity manager is ready", function()
        local h = harness({ no_mgr = true })
        -- 手动装一个会话，绕过 init（没有 entitymgr）
        h.session.bind(cid(9), h.entity, OWNER)
        local ok, reason = h.session.with_request(cid(9), function() end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("entity manager not ready")
    end)

    t.it("rejects when the entity is gone or its lease expired", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.not_loaded = true
        local ran = false
        local ok, reason = h.session.with_request(key, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("entity not loaded or lease expired")
        t.expect(ran).to.equal(false)

        h.not_loaded = false
        h.expire_during = true
        local ok2, reason2 = h.session.with_request(key, function()
            return "pack"
        end)
        t.expect(ok2).to.equal(false)
        t.expect(reason2).to.equal("entity lease expired during handler")
    end)

    t.it("rejects a request whose session was unbound while it waited in the queue", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ran = false
        h.before_handler = function()
            h.session.unbind(key)
        end
        local ok, reason = h.session.with_request(key, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client binding revoked")
        t.expect(ran).to.equal(false)
        t.expect(h.touched).to.equal(7)
    end)

    t.it("rejects a request whose session key was rebound to another entity while it waited", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ran = false
        h.before_handler = function()
            h.session.unbind(key)
            h.session.bind(key, { type_name = "role", id = 7 }, OWNER)
        end
        local ok, reason = h.session.with_request(key, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client binding revoked")
        t.expect(ran).to.equal(false)
    end)

    t.it("rejects when the gate handed over a reloaded entity instance", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.active = { type_name = "role", id = 7 }
        local ran = false
        local ok, reason = h.session.with_request(key, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client binding revoked")
        t.expect(ran).to.equal(false)
    end)

    t.it("lets handler errors propagate so the caller can answer the client", function()
        local h = harness()
        local _, key = bind(h, 9)
        t.expect(function()
            h.session.with_request(key, function()
                error("boom")
            end)
        end).to
            .throw("boom")
    end)

    t.it("records the last upstream packet time for the idle check", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.now = 99999
        h.session.with_request(key, function() end)
        t.expect(h.entity.session_io.last_seen).to.equal(99999)
    end)
end)

-- 续接之后客户端按原 request id 重发在途请求，服务端必须认出来回缓存的响应。
-- 重新执行一遍扣费、抽卡比丢一个回包危险得多
t.describe("session upstream idempotency", function()
    t.it("re-checks the cache inside the entity queue so an interleaved request cannot run twice", function()
        local h = harness()
        local _, key = bind(h, 9)
        local fingerprint = require "skyext.fingerprint"
        local digest = string.rep("d", 32)
        local runs = 0
        local function handler()
            runs = runs + 1
            return "RESP"
        end
        -- 模拟另一个协程抢先提交并写好 L1，而本请求在排队等待期间才进入队列。
        -- 查重若发生在队列外，这里就已经 miss 了，进队列后 handler 会执行第二次
        h.before_handler = function()
            h.entity.session_io.resp_cache[5] = assert(fingerprint.entry_from_digest(digest, "shop.buy", "CACHED"))
        end
        local ok, pack = h.session.with_request(key, handler, 5, "shop.buy", digest)
        t.expect(ok).to.equal(true)
        t.expect(pack).to.equal("CACHED")
        t.expect(runs).to.equal(0)
    end)

    t.it("answers a repeated request id from cache without running the handler again", function()
        local h = harness()
        local _, key = bind(h, 9)
        local runs = 0
        local function handler()
            runs = runs + 1
            return "RESP"
        end
        local digest = string.rep("d", 32)
        t.expect({ h.session.with_request(key, handler, 5, "shop.buy", digest) }).to.equal({ true, "RESP" })
        t.expect({ h.session.with_request(key, handler, 5, "shop.buy", digest) }).to.equal({ true, "RESP" })
        t.expect(runs).to.equal(1)
    end)

    t.it("does not cache anything for requests that carry no request id", function()
        local h = harness()
        local _, key = bind(h, 9)
        local runs = 0
        local function handler()
            runs = runs + 1
            return "RESP"
        end
        h.session.with_request(key, handler)
        h.session.with_request(key, handler)
        t.expect(runs).to.equal(2)
    end)

    t.it("refuses an evicted request id instead of silently running it a second time", function()
        local h = harness({ conf = { session_respcache_count = 2 } })
        local _, key = bind(h, 9)
        local runs = 0
        local function handler()
            runs = runs + 1
            return "RESP"
        end
        local function digest_of(req_id)
            return string.rep(string.char(96 + req_id), 32)
        end
        for req_id = 1, 3 do
            h.session.with_request(key, handler, req_id, "shop.buy", digest_of(req_id))
        end
        t.expect(runs).to.equal(3)

        local ok, reason, code = h.session.with_request(key, handler, 1, "shop.buy", digest_of(1))
        t.expect(ok).to.equal(false)
        t.expect(code).to.equal(errcode.REQUEST_EXPIRED)
        t.expect(reason).to.equal("response for this request id was already evicted")
        t.expect(runs).to.equal(3)

        -- 还在缓存里的照常命中
        t.expect({ h.session.with_request(key, handler, 3, "shop.buy", digest_of(3)) }).to.equal({ true, "RESP" })
        t.expect(runs).to.equal(3)
    end)

    -- 客户端在续接之后重置了 request id 计数器：续接不重建 session_io，缓存还是
    -- 断线前那张，小 id 会命中别的请求的响应。只有协议名能看出来
    t.it("refuses a cached request id that now carries a different request", function()
        local h = harness()
        local _, key = bind(h, 9)
        local function handler(resp)
            return function()
                return resp
            end
        end
        local digest = string.rep("b", 32)
        t.expect({ h.session.with_request(key, handler("BAG"), 1, "bag.use_item", digest) }).to.equal({ true, "BAG" })

        local ok, reason, code = h.session.with_request(key, handler("SHOP"), 1, "shop.buy", digest)
        t.expect(ok).to.equal(false)
        t.expect(code).to.equal(errcode.REQUEST_CONFLICT)
        t.expect(reason).to.equal("request id reused for a different request")

        -- 同名的照常命中缓存，不重新执行
        local runs = 0
        t.expect({
            h.session.with_request(key, function()
                runs = runs + 1
                return "AGAIN"
            end, 1, "bag.use_item", digest),
        }).to
            .equal({ true, "BAG" })
        t.expect(runs).to.equal(0)
    end)
end)

t.describe("session lookup", function()
    t.it("get_obj wraps a live entity and returns nil once it is gone", function()
        local h = harness()
        local _, key = bind(h, 9)
        t.expect(h.session.get_entity(key)).to.equal(h.entity)
        t.expect(h.session.get_obj(key)).to.equal({ entity = h.entity })
        t.expect(h.session.is_online(h.entity)).to.equal(true)
        h.entity_gone = true
        t.expect(h.session.get_obj(key)).to.be_nil()
    end)
end)

t.describe("session disconnect", function()
    t.it("kick pushes to the gate that owns the session", function()
        local h = harness()
        bind(h, 9)
        h.session.kick(cid(9))
        t.expect(h.kicks).to.equal({ { node = "role1", fd = cid(9) } })
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "local", "kick", cid(9) })
    end)

    t.it("kick reaches a remote gate over cluster", function()
        local h = harness()
        bind(h, 12, "gate1")
        h.session.kick(cid(12, "gate1"))
        t.expect(h.kicks).to.equal({ { node = "gate1", fd = cid(12, "gate1") } })
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "cluster", "gate1", "kick", cid(12, "gate1") })
    end)

    t.it("ignores a kick for a session it does not know", function()
        local h = harness()
        h.session.kick(cid(12, "gate1"))
        t.expect(h.kicks).to.equal({})
    end)

    t.it("reject_client kicks without unbinding so the disconnect flow still runs", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.session.reject_client(key, "client binding revoked")
        t.expect(h.kicks).to.equal({ { node = "role1", fd = cid(9) } })
        t.expect(h.session.get_entity(key)).to.equal(h.entity)
        t.expect(h.entity.session.key).to.equal(cid(9))
        t.expect(h.touched).to.be_nil()
    end)

    t.it("unbinds and kicks when the entity side drops the connection", function()
        local h = harness()
        local _, key = bind(h, 9)
        t.expect(h.session.unbind_kick(key, h.entity)).to.equal(true)
        t.expect(h.kicks).to.equal({ { node = "role1", fd = cid(9) } })
        t.expect(h.session.get_entity(key)).to.be_nil()
        t.expect(h.entity.session).to.be_nil()
        t.expect(h.touched).to.equal(7)
    end)

    -- 断开的只是连接，会话状态要活到实体卸载，否则续接无从谈起
    t.it("keeps the session state across a disconnect", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.session.push(h.entity, "mail_notify", { id = 1 })
        h.session.unbind(key)
        t.expect(h.session.is_online(h.entity)).to.equal(false)
        t.expect(h.entity.session_io.sent).to.equal(1)
    end)

    t.it("does not disconnect a new binding when an old entity kick runs late", function()
        local h = harness()
        local old_entity = { type_name = "role", id = 7 }
        bind(h, 9, SELF_NODE, old_entity)
        bind(h, 9, SELF_NODE, h.entity)

        t.expect(h.session.unbind_kick(cid(9), old_entity)).to.equal(false)
        t.expect(h.session.get_entity(cid(9))).to.equal(h.entity)
        t.expect(h.entity.session.key).to.equal(cid(9))
        t.expect(h.kicks).to.equal({})
        t.expect(h.touched).to.be_nil()
    end)

    t.it("kicks a connection whose client stopped sending anything", function()
        local h = harness({ conf = { session_idle_timeout = 60 } })
        bind(h, 9)
        h.session.sweep_idle()
        t.expect(h.kicks).to.equal({})
        h.now = h.now + 61 * 100
        h.session.sweep_idle()
        t.expect(h.kicks).to.equal({ { node = "role1", fd = cid(9) } })
    end)
end)

t.describe("session downstream counting", function()
    t.it("counts and buffers every push, and writes it to the gate when online", function()
        local h = harness()
        bind(h, 9)
        t.expect(h.session.push(h.entity, "mail_notify", { id = 1 })).to.equal(true)
        t.expect(h.session.push(h.entity, "mail_notify", { id = 2 })).to.equal(true)
        t.expect(h.entity.session_io.sent).to.equal(2)
        t.expect(pushes(h)).to.equal({ "PACK:mail_notify:1", "PACK:mail_notify:2" })
    end)

    -- 离线时包不是丢了，是进了重放缓冲等续接
    t.it("buffers a push while the client is offline instead of dropping it", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.session.unbind(key)
        t.expect(h.session.push(h.entity, "mail_notify", { id = 1 })).to.equal(false)
        t.expect(h.entity.session_io.sent).to.equal(1)
        t.expect(pushes(h)).to.equal({})
    end)

    t.it("refuses to push to an entity that never had a session", function()
        local h = harness()
        t.expect(h.session.push(h.entity, "mail_notify", {})).to.equal(false)
    end)

    t.it("the sproto sender counts responses but not transport handshakes", function()
        local h = harness()
        bind(h, 9)
        h.sender(cid(9), "RESP", "role.bag_list")
        t.expect(h.entity.session_io.sent).to.equal(1)
        -- resume / ping 的回包处在计数边界之外：算进去客户端的自校验立刻失配
        h.sender(cid(9), "PONG", "login.ping")
        h.sender(cid(9), "RESUMED", "login.resume")
        t.expect(h.entity.session_io.sent).to.equal(1)
        t.expect(pushes(h)).to.equal({ "RESP", "PONG", "RESUMED" })
    end)

    t.it("the sender drops a package for a session that is gone", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.session.unbind(key)
        local before = #h.gate_ops
        h.sender(key, "RAWBYTES")
        t.expect(#h.gate_ops).to.equal(before)
    end)

    t.it("trims the replay buffer when the client acknowledges", function()
        local h = harness()
        bind(h, 9)
        for i = 1, 3 do
            h.session.push(h.entity, "mail_notify", { id = i })
        end
        h.session.ack(h.entity, 2)
        local io_ = h.entity.session_io
        t.expect(io_.acked).to.equal(2)
        t.expect(io_.out_buf[1]).to.be_nil()
        t.expect(io_.out_buf[3]).to.equal("PACK:mail_notify:3")
    end)

    t.it("gives up on replay rather than keep an unbounded buffer", function()
        local h = harness({ conf = { session_replay_packets = 2 } })
        local _, key = bind(h, 9)
        h.session.unbind(key)
        for i = 1, 3 do
            h.session.push(h.entity, "mail_notify", { id = i })
        end
        t.expect(h.entity.session_io.unresumable).to.equal(true)
        t.expect(h.session.resume(cid(10), h.entity, OWNER, fake_nonce(1), 0)).to.equal(errcode.RESUME_UNAVAILABLE)
    end)

    t.it("marks the session unresumable when the client acknowledges an impossible count", function()
        local h = harness()
        bind(h, 9)
        h.session.push(h.entity, "mail_notify", { id = 1 })
        h.session.ack(h.entity, 5)
        t.expect(h.entity.session_io.unresumable).to.equal(true)
    end)
end)

t.describe("session resume", function()
    local function bind_and_push(h, count)
        local _, key, nonce = bind(h, 9)
        for i = 1, count or 0 do
            h.session.push(h.entity, "mail_notify", { id = i })
        end
        return key, nonce
    end

    t.it("moves the session onto a new connection and rotates the credential", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 2)
        local code, new_nonce, sent = h.session.resume(cid(20), h.entity, OWNER, nonce, 1)
        t.expect(code).to.equal(errcode.OK)
        t.expect(new_nonce).to_not.equal(nonce)
        t.expect(sent).to.equal(2)
        t.expect(h.entity.session.conn_id).to.equal(cid(20))
        t.expect(h.session.get_entity(cid(20))).to.equal(h.entity)
        t.expect(h.session.get_entity(cid(9))).to.be_nil()
    end)

    -- 旧连接多半还半开着，要回收；但不能走 unbind_kick——那条路会引出网关的
    -- session_closed，触发 on_unbind_client，业务层就看到一次假的下线再上线
    t.it("reclaims the half-open old connection without unbinding the entity", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 0)
        h.session.resume(cid(20), h.entity, OWNER, nonce, 0)
        t.expect(h.kicks).to.equal({ { node = "role1", fd = cid(9) } })
        t.expect(h.entity.session).to_not.be_nil()
        t.expect(h.touched).to.be_nil()
    end)

    -- 热替换之后旧连接的 session_closed 才迟迟到达，不能把新连接清掉
    t.it("survives a session_closed for the old connection arriving after the swap", function()
        local h = harness()
        local old_key, nonce = bind_and_push(h, 0)
        h.session.resume(cid(20), h.entity, OWNER, nonce, 0)
        h.session.unbind(old_key)
        t.expect(h.entity.session).to_not.be_nil()
        t.expect(h.entity.session.conn_id).to.equal(cid(20))
        t.expect(h.touched).to.be_nil()
    end)

    t.it("holds back new pushes until the replay is done, then releases them in order", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 3)
        h.session.ack(h.entity, 1)
        h.gate_ops = {}

        h.session.resume(cid(20), h.entity, OWNER, nonce, 1)
        -- 续接只做热替换，重放还没开始
        t.expect(pushes(h)).to.equal({})
        -- 业务在 on_resume_client 之前推的包也要排在旧包后面
        h.session.push(h.entity, "mail_notify", { id = 9 })
        t.expect(pushes(h)).to.equal({})

        h.session.replay(h.entity)
        t.expect(pushes(h)).to.equal({ "PACK:mail_notify:2", "PACK:mail_notify:3", "PACK:mail_notify:9" })
        -- 重放结束后恢复直发
        h.session.push(h.entity, "mail_notify", { id = 10 })
        t.expect(pushes(h)[4]).to.equal("PACK:mail_notify:10")
    end)

    t.it("replays nothing when the client already received everything", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 2)
        h.gate_ops = {}
        h.session.resume(cid(20), h.entity, OWNER, nonce, 2)
        h.session.replay(h.entity)
        t.expect(pushes(h)).to.equal({})
    end)

    t.it("rejects a wrong credential and a credential that was already rotated", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 0)
        t.expect(h.session.resume(cid(20), h.entity, OWNER, "wrong", 0)).to.equal(errcode.AUTH_FAILED)
        t.expect(h.session.resume(cid(20), h.entity, OWNER, nil, 0)).to.equal(errcode.AUTH_FAILED)
        -- 仍然挂在原连接上
        t.expect(h.entity.session.conn_id).to.equal(cid(9))

        h.session.resume(cid(20), h.entity, OWNER, nonce, 0)
        t.expect(h.session.resume(cid(21), h.entity, OWNER, nonce, 0)).to.equal(errcode.AUTH_FAILED)
    end)

    t.it("rejects an entity that never had a session", function()
        local h = harness()
        t.expect(h.session.resume(cid(20), h.entity, OWNER, fake_nonce(1), 0)).to.equal(errcode.RESUME_UNAVAILABLE)
    end)

    -- 隐式计数不自带校验，这是唯一一次对账的机会
    t.it("rejects a received count that cannot be true", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 2)
        t.expect(h.session.resume(cid(20), h.entity, OWNER, nonce, 3)).to.equal(errcode.RESUME_UNAVAILABLE)
        h.session.ack(h.entity, 2)
        t.expect(h.session.resume(cid(20), h.entity, OWNER, nonce, 1)).to.equal(errcode.RESUME_UNAVAILABLE)
    end)

    t.it("reports a closed connection when the gate dropped the new fd first", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 0)
        h.gate_bind_result = false
        t.expect(h.session.resume(cid(20), h.entity, OWNER, nonce, 0)).to.equal(errcode.SESSION_CLOSED)
        t.expect(h.entity.session.conn_id).to.equal(cid(9))
    end)

    -- 网关 RPC 抛错与明确拒绝同样不能留下已推进的 owner_epoch
    t.it("rolls back owner_epoch when the gate bind raises", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 0)
        local before = h.entity.session_io.owner_epoch
        h.gate_bind_raises = true
        t.expect(h.session.resume(cid(20), h.entity, OWNER, nonce, 0)).to.equal(errcode.SESSION_CLOSED)
        t.expect(h.entity.session_io.owner_epoch).to.equal(before)
    end)

    -- 会话和传输无关：TCP 断了可以从 WS 接回来，也可以换一个网关节点
    t.it("accepts a resume from another gate node and another transport", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 0)
        local code = h.session.resume(cid(3, "gate2", ".gate_ws"), h.entity, OWNER, nonce, 0)
        t.expect(code).to.equal(errcode.OK)
        t.expect(h.entity.session.gate_node).to.equal("gate2")
        t.expect(h.entity.session.gate_service).to.equal(".gate_ws")
    end)

    t.it("answers a ping with the current sent count and trims the buffer", function()
        local h = harness()
        bind_and_push(h, 2)
        local reply = h.session.cmds.ping({ recv = 2 }, 9, { entity = h.entity })
        t.expect(reply).to.equal({ sent = 2 })
        t.expect(h.entity.session_io.acked).to.equal(2)
    end)
end)

-- P14 的协议门禁：session_epoch 只在完整登录时生成，模式终身锁定，V2 下行按
-- (session_epoch, seq) 去重，续接不换 epoch。旧 SDK 走 LEGACY，行为不变
t.describe("session downlink v2", function()
    local function bind_v2(h, seq, mode)
        return h.session.bind(cid(seq or 9), h.entity, OWNER, mode or h.session.MODE_V2)
    end

    t.it("issues a 32 hex epoch and locks the negotiated mode", function()
        local h = harness()
        local ok, nonce, epoch, mode = bind_v2(h, 9)
        t.expect(ok).to.equal(true)
        t.expect(mode).to.equal(h.session.MODE_V2)
        t.expect(#epoch).to.equal(32)
        t.expect(epoch:match("^[0-9a-f]+$") ~= nil).to.equal(true)
        t.expect(epoch).to_not.equal(nonce)
        t.expect(h.entity.session_io.session_epoch).to.equal(epoch)
    end)

    t.it("rejects an unknown mode instead of silently falling back to legacy", function()
        local h = harness()
        t.expect(h.session.bind(cid(9), h.entity, OWNER, 7)).to.equal(false)
        t.expect(h.entity.session_io).to.be_nil()
    end)

    t.it("wraps every counted downlink in DownlinkV2 and stores the encoded bytes", function()
        local h = harness()
        local _, _, epoch = bind_v2(h, 9)
        h.session.push(h.entity, "mail_notify", { id = 1 })
        local pack = pushes(h)[1]
        local decoded = assert(downlink.decode(pack))
        t.expect(decoded.session_epoch).to.equal(epoch)
        t.expect(decoded.seq).to.equal(1)
        t.expect(decoded.payload).to.equal("PACK:mail_notify:1")
        -- out_buf 存的是完整信封，迁移时可以原样重放，不需要重新包装
        t.expect(h.entity.session_io.out_buf[1]).to.equal(pack)
    end)

    t.it("keeps transport handshakes outside the envelope", function()
        local h = harness()
        bind_v2(h, 9)
        h.sender(cid(9), "PINGPACK", "login.ping")
        t.expect(pushes(h)[1]).to.equal("PINGPACK")
        t.expect(h.entity.session_io.sent).to.equal(0)
    end)

    t.it("acks by (epoch, last_contiguous_seq) and trims only on a matching epoch", function()
        local h = harness()
        local _, _, epoch = bind_v2(h, 9)
        h.session.push(h.entity, "a", {})
        h.session.push(h.entity, "b", {})

        local reply = h.session.cmds.ping({
            session_epoch = string.rep("a", 32),
            last_contiguous_seq = 2,
        }, 9, { entity = h.entity })
        t.expect(h.entity.session_io.acked).to.equal(0)
        t.expect(reply.acked).to.equal(0)
        t.expect(reply.session_epoch).to.equal(epoch)

        reply = h.session.cmds.ping({ session_epoch = epoch, last_contiguous_seq = 2 }, 9, { entity = h.entity })
        t.expect(reply.acked).to.equal(2)
        t.expect(h.entity.session_io.out_buf[1]).to.be_nil()
        t.expect(h.entity.session_io.out_bytes).to.equal(0)
    end)

    t.it("keeps the same epoch across resume and only rotates the credential", function()
        local h = harness()
        local _, nonce, epoch = bind_v2(h, 9)
        local code, new_nonce, sent, resumed_epoch, mode = h.session.resume(
            cid(10),
            h.entity,
            OWNER,
            nonce,
            0,
            { session_mode = h.session.MODE_V2, session_epoch = epoch }
        )
        t.expect(code).to.equal(errcode.OK)
        t.expect(new_nonce).to_not.equal(nonce)
        t.expect(sent).to.equal(0)
        t.expect(resumed_epoch).to.equal(epoch)
        t.expect(mode).to.equal(h.session.MODE_V2)
    end)

    t.it("refuses a resume with another mode or another epoch", function()
        local h = harness()
        local _, nonce = bind_v2(h, 9)
        t.expect(h.session.resume(cid(10), h.entity, OWNER, nonce, 0, {
            session_mode = h.session.MODE_LEGACY,
        })).to
            .equal(errcode.RESUME_UNAVAILABLE)
        t.expect(h.session.resume(cid(10), h.entity, OWNER, nonce, 0, {
            session_mode = h.session.MODE_V2,
            session_epoch = string.rep("b", 32),
        })).to
            .equal(errcode.RESUME_UNAVAILABLE)
    end)

    -- 同协议但参数不同：只看协议名会静默回放上一次的结果
    t.it("refuses a cached request id whose parameters changed", function()
        local h = harness()
        local _, key = bind(h, 9)
        local runs = 0
        local function handler()
            runs = runs + 1
            return "RESP"
        end
        h.session.with_request(key, handler, 1, "shop.buy", string.rep("a", 32))
        local ok, _, code = h.session.with_request(key, handler, 1, "shop.buy", string.rep("c", 32))
        t.expect(ok).to.equal(false)
        t.expect(code).to.equal(errcode.REQUEST_CONFLICT)
        t.expect(runs).to.equal(1)
    end)

    -- 旧格式条目没有 version/hash，无法证明参数相同，只能按 EXPIRED 让客户端重走流程
    t.it("refuses a legacy cache entry without a fingerprint", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.entity.session_io.resp_cache[1] = { pack = "OLD", name = "shop.buy" }
        local ok, _, code = h.session.with_request(key, function()
            return "NEW"
        end, 1, "shop.buy", string.rep("a", 32))
        t.expect(ok).to.equal(false)
        t.expect(code).to.equal(errcode.REQUEST_EXPIRED)
    end)

    t.it("does not cache a NO_CACHE response in L1", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ok = h.session.with_request(key, function()
            return "REJECT_PACK", nil, nil, "no_cache"
        end, 1, "role.buy")
        t.expect(ok).to.equal(true)
        t.expect(h.entity.session_io.resp_cache[1]).to.be_nil()

        -- 同 req_id 再传必须重新执行，而不是回放上一次的瞬时拒绝
        local ran = false
        h.session.with_request(key, function()
            ran = true
            return "OK_PACK", nil, nil, "no_cache"
        end, 1, "role.buy")
        t.expect(ran).to.equal(true)
    end)
end)

-- P14：owner_epoch 是网关内部的所有权代际。续接会推进它，但 wire 上的
-- session_epoch 与 seq 必须保持不变——客户端看到的是同一个逻辑会话
t.describe("owner epoch", function()
    t.it("advances owner_epoch on resume without touching the wire epoch or seq", function()
        local h = harness()
        local key = cid(9)
        local ok, nonce, epoch = h.session.bind(key, h.entity, OWNER, h.session.MODE_V2)
        t.expect(ok).to.equal(true)
        t.expect(h.entity.session_io.owner_epoch).to.equal(1)

        t.expect(h.session.push(h.entity, "mail_notify", { id = 1 })).to.equal(true)
        -- bind 与 push 都必须带 owner_epoch，网关靠它过滤迟到包
        t.expect(h.gate_ops[#h.gate_ops - 1][6]).to.equal(1)
        t.expect(h.gate_ops[#h.gate_ops][5]).to.equal(1)

        local code, _, sent, resumed_epoch = h.session.resume(cid(10), h.entity, OWNER, nonce, 1)
        t.expect(code).to.equal(errcode.OK)
        t.expect(h.entity.session_io.owner_epoch).to.equal(2)
        -- 逻辑会话身份不变，seq 继续往前走
        t.expect(resumed_epoch).to.equal(epoch)
        t.expect(sent).to.equal(1)
        t.expect(h.entity.session_io.sent).to.equal(1)
    end)

    t.it("starts every new session io at owner epoch 1", function()
        local h = harness()
        t.expect(h.session.bind(cid(9), h.entity, OWNER, h.session.MODE_LEGACY)).to.equal(true)
        t.expect(h.entity.session_io.owner_epoch).to.equal(1)
        -- 顶号/重登会重建 session_io，代际从头开始；网关的 bind 也会接受更高的新代际
        t.expect(h.session.bind(cid(11), h.entity, OWNER, h.session.MODE_LEGACY)).to.equal(true)
        t.expect(h.entity.session_io.owner_epoch).to.equal(1)
    end)
end)

-- P15：目标侧接管。客户端全程没断线，所以不重建会话、不轮换 nonce，
-- 只把连接挂到新 owner 上并推进 owner_epoch
t.describe("session 迁移接管", function()
    local function restored_io(epoch)
        return {
            session_epoch = "epoch-a",
            session_mode = 1,
            nonce = "nonce-from-source",
            owner_epoch = epoch,
            sent = 3,
            acked = 1,
            out_buf = { [2] = "PACK-2", [3] = "PACK-3" },
            out_bytes = 12,
            resp_cache = {},
            resp_order = { head = 1, tail = 0 },
            resp_bytes = 0,
            min_cached_req_id = 0,
            last_seen = 0,
            unresumable = false,
            replaying = false,
        }
    end

    local function find_op(h, cmd)
        for i = #h.gate_ops, 1, -1 do
            local op = h.gate_ops[i]
            local name = op[1] == "cluster" and op[3] or op[2]
            if name == cmd then
                return op
            end
        end
    end

    t.it("attaches the live connection and advances the owner epoch", function()
        local h = harness()
        h.entity.session_io = restored_io(3)
        local key = cid(1)

        local ok, err = h.session.attach(key, h.entity, OWNER, 4)
        t.expect(err).to.be_nil()
        t.expect(ok).to.equal(true)
        t.expect(h.entity.session_io.owner_epoch).to.equal(4)
        t.expect(h.entity.session.key).to.equal(key)
        -- 网关先认账：resume_owner 带的是新 epoch 与新 owner
        local op = find_op(h, "resume_owner")
        t.expect(op[3]).to.equal(key)
        t.expect(op[4]).to.equal(4)
        t.expect(op[5]).to.equal(SELF_NODE)
        t.expect(op[6]).to.equal(OWNER)
        -- 重放前保持 replaying：新包必须排在旧包后面
        t.expect(h.entity.session_io.replaying).to.equal(true)
    end)

    t.it("replays the unacknowledged packets after attaching", function()
        local h = harness()
        h.entity.session_io = restored_io(3)
        assert(h.session.attach(cid(1), h.entity, OWNER, 4))
        t.expect(h.session.replay(h.entity)).to.equal(true)
        local out = pushes(h)
        t.expect(#out).to.equal(2)
        t.expect(out[1]).to.equal("PACK-2")
        t.expect(out[2]).to.equal("PACK-3")
        -- replay 也属于新 owner 的下行，必须带新代际，否则网关会把迟到旧包放行
        for _, op in ipairs(h.gate_ops) do
            if op[2] == "push" then
                t.expect(op[5]).to.equal(4)
            end
        end
        t.expect(h.entity.session_io.replaying).to.equal(false)
    end)

    t.it("refuses an epoch that does not advance", function()
        local h = harness()
        h.entity.session_io = restored_io(3)
        local ok, err = h.session.attach(cid(1), h.entity, OWNER, 3)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("owner epoch must advance")
        -- 没推进代际就没有所有权切换，网关不该收到任何指令
        t.expect(find_op(h, "resume_owner")).to.be_nil()
        t.expect(h.entity.session).to.be_nil()
    end)

    t.it("leaves the local state untouched when the gate rejects the new owner", function()
        local h = harness()
        h.entity.session_io = restored_io(3)
        h.gate_resume_result = false
        local ok, err = h.session.attach(cid(1), h.entity, OWNER, 4)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("gate rejected the new owner")
        -- 网关不认账时本地不能推进 epoch，否则之后的下行全被当迟到包丢掉
        t.expect(h.entity.session_io.owner_epoch).to.equal(3)
        t.expect(h.entity.session).to.be_nil()
    end)

    t.it("needs a session io to attach to", function()
        local h = harness()
        local ok, err = h.session.attach(cid(1), h.entity, OWNER, 2)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("no session io")
    end)
end)
