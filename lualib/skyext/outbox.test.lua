local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local orm = require "orm"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/outbox.lua")

local function role_schema()
    local self = {
        type = "struct",
        rid = { type = "integer" },
        _version = { type = "integer" },
        gold = { type = "integer" },
    }
    local names = { "_version", "gold", "rid" }
    function self.fields()
        return names
    end
    function self:_parse_k(k)
        assert(self[k], "unknown key: " .. tostring(k))
        return k
    end
    function self:_check_k(k)
        self:_parse_k(k)
    end
    function self:_check_kv(_, value)
        assert(type(value) == "number")
    end
    function self.new(data)
        return orm.new(self, data)
    end
    return self
end

local EVENT = "evt_" .. string.rep("a", 64)
local HASH = string.rep("b", 64)

-- 假 dbmgr：实现 outbox 依赖的 cached_critical / critical_update / set_critical
local function fake_dbmgr(store)
    local M = {}
    function M.cached_critical()
        return store.critical
    end
    function M.set_critical(_, _, _, value)
        store.critical = value
        return true
    end
    function M.refresh_critical()
        store.refreshed = (store.refreshed or 0) + 1
        return true, store.doc._version
    end
    function M.critical_update(_, _, _, _, expected, update, opts)
        store.cas = store.cas or {}
        store.cas[#store.cas + 1] = { expected = expected, update = update, opts = opts }
        if store.unknown then
            return "UNKNOWN", store.unknown
        end
        if store.reject then
            return "REJECTED", "cas mismatch"
        end
        if store.doc._version ~= expected then
            return "REJECTED", "version mismatch"
        end
        assert(orm.advance_persisted_version(store.doc, expected, expected + 1))
        return "CONFIRMED", { version = expected + 1, n = 1, nModified = 1 }
    end
    return M
end

local function harness(overrides)
    local doc = orm.new(role_schema(), { rid = 7, _version = 0, gold = 100 })
    local store = { doc = doc, critical = {} }
    local h = { doc = doc, store = store, now = 1700000000, acks = {} }
    h.dbmgr = fake_dbmgr(store)
    h.critical_override = overrides and overrides.critical
    h.ctx = {
        dbname = "demo",
        dbcoll = "role",
        key = "rid",
        unique_id = 7,
        handle = { fence = 5, valid = true },
        doc = doc,
    }
    local env = setmetatable({
        require = function(name)
            if name == "skyext.dbmgr" then
                return h.dbmgr
            end
            if name == "skyext.critical" and h.critical_override then
                return h.critical_override
            end
            if name == "skyext.log" then
                return { debug = function() end, info = function() end, warn = function() end, error = function() end }
            end
            -- 回执走可靠消息：单元测试里只记录，不碰数据库
            if name == "skyext.entity.router" then
                return {
                    reliable_send = function(type_name, id, cmd, args, opts)
                        h.acks[#h.acks + 1] = {
                            type_name = type_name,
                            id = id,
                            cmd = cmd,
                            args = args,
                            opts = opts,
                        }
                        return "msg-ack"
                    end,
                }
            end
            return require(name)
        end,
    }, { __index = _G })
    h.outbox = assert(loadfile(source, "t", env))()

    function h.event(over)
        local opts = {
            event_id = EVENT,
            target_type = "role",
            target_id = 9,
            op_type = "mail.send",
            param_hash = HASH,
            payload = { item = 1 },
            now = h.now,
        }
        for k, v in pairs(over or {}) do
            opts[k] = v
        end
        return h.outbox.event(opts)
    end

    function h.seed(events, count)
        local outbox = {}
        for _, e in ipairs(events) do
            outbox[e.event_id] = e
        end
        h.store.critical = {
            _critical_outbox_v1 = outbox,
            _critical_outbox_pending_count = count or #events,
        }
    end

    return h
end

t.describe("outbox 事件与信封", function()
    t.it("generates a stable-format event id", function()
        local h = harness()
        local id = assert(h.outbox.new_event_id(function(n)
            return string.rep("\1", n)
        end))
        t.expect(#id).to.equal(68)
        t.expect(id:sub(1, 4)).to.equal("evt_")
        t.expect(id:sub(5)).to.equal(string.rep("01", 32))
    end)

    t.it("refuses a random source that returns the wrong size", function()
        local h = harness()
        t.expect(h.outbox.new_event_id(function()
            return "short"
        end)).to
            .be_nil()
    end)

    t.it("builds an event and validates its fields", function()
        local h = harness()
        local event = assert(h.event())
        t.expect(event.status).to.equal(h.outbox.STATUS.PENDING)
        t.expect(event.attempt).to.equal(0)
        t.expect(h.event({ event_id = "bad" })).to.be_nil()
        t.expect(h.event({ target_type = "" })).to.be_nil()
        t.expect(h.event({ op_type = "" })).to.be_nil()
        t.expect(h.event({ param_hash = "short" })).to.be_nil()
    end)

    t.it("wraps an event in an envelope that survives validation", function()
        local h = harness()
        local event = assert(h.event())
        local env = assert(h.outbox.envelope(event, { type = "role", id = 7 }))
        t.expect(env.version).to.equal(1)
        t.expect(env.event_id).to.equal(EVENT)
        t.expect(env.source_type).to.equal("role")
        t.expect(env.source_id).to.equal(7)
        t.expect(h.outbox.validate_envelope(env)).to.equal(true)
        -- 业务键是 event_id 的字节级映射
        t.expect(h.outbox.service_op_id(env)).to.equal("srv_" .. string.rep("a", 64))
    end)

    t.it("rejects a malformed envelope", function()
        local h = harness()
        local event = assert(h.event())
        local base = assert(h.outbox.envelope(event, { type = "role", id = 7 }))
        local function mutate(over)
            local copy = {}
            for k, v in pairs(base) do
                copy[k] = v
            end
            for k, v in pairs(over) do
                copy[k] = v
            end
            return copy
        end
        t.expect(h.outbox.validate_envelope(nil)).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ version = 2 }))).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ event_id = "evt_short" }))).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ target_type = "" }))).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ param_hash = "x" }))).to.be_nil()
        t.expect(h.outbox.validate_envelope(mutate({ source_type = "" }))).to.be_nil()
        -- nil 不会出现在 pairs 里，必须显式删
        local no_source = mutate({})
        no_source.source_id = nil
        t.expect(h.outbox.validate_envelope(no_source)).to.be_nil()
    end)
end)

t.describe("outbox 状态推进", function()
    t.it("lists pending events in creation order", function()
        local h = harness()
        local older = assert(h.event({ event_id = "evt_" .. string.rep("1", 64), now = 10 }))
        local newer = assert(h.event({ event_id = "evt_" .. string.rep("2", 64), now = 20 }))
        local done = assert(h.event({ event_id = "evt_" .. string.rep("3", 64), now = 5 }))
        done.status = h.outbox.STATUS.DELIVERED
        h.seed({ newer, older, done })

        local pending = h.outbox.pending_events(h.store.critical, 10)
        t.expect(#pending).to.equal(2)
        t.expect(pending[1].event_id).to.equal(older.event_id)
        t.expect(pending[2].event_id).to.equal(newer.event_id)
        t.expect(h.outbox.count_pending(h.store.critical)).to.equal(2)
    end)

    t.it("respects the batch limit", function()
        local h = harness()
        local events = {}
        for i = 1, 5 do
            events[i] = assert(h.event({ event_id = "evt_" .. string.format("%064x", i), now = i }))
        end
        h.seed(events)
        t.expect(#h.outbox.pending_events(h.store.critical, 2)).to.equal(2)
    end)

    -- pending_count 只能减一次：重复推进同一事件不能把它减成负数
    t.it("decrements the pending count exactly once per event", function()
        local h = harness()
        local event = assert(h.event())
        h.seed({ event })

        local next_table = assert(h.outbox.transition(h.store.critical, EVENT, h.outbox.STATUS.ENQUEUED, 100))
        t.expect(next_table._critical_outbox_pending_count).to.equal(0)
        t.expect(next_table._critical_outbox_v1[EVENT].status).to.equal("ENQUEUED")
        t.expect(next_table._critical_outbox_v1[EVENT].attempt).to.equal(1)
        -- 原表不能被就地修改
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("PENDING")

        local again = assert(h.outbox.transition(next_table, EVENT, h.outbox.STATUS.DELIVERED, 101))
        t.expect(again._critical_outbox_pending_count).to.equal(0)
    end)

    t.it("refuses to transition an unknown event", function()
        local h = harness()
        h.seed({})
        t.expect(h.outbox.transition(h.store.critical, EVENT, h.outbox.STATUS.ENQUEUED, 100)).to.be_nil()
    end)
end)

t.describe("outbox 投递", function()
    t.it("delivers, then CASes the status and the pending count", function()
        local h = harness()
        h.seed({ assert(h.event()) })

        local delivered = {}
        local stats = assert(h.outbox.pump(h.ctx, function(env)
            delivered[#delivered + 1] = env
            return true
        end, { now = 100, source = { type = "role", id = 7 } }))

        t.expect(#delivered).to.equal(1)
        t.expect(stats.enqueued).to.equal(1)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("ENQUEUED")
        t.expect(h.store.critical._critical_outbox_pending_count).to.equal(0)
        -- CAS 必须带"该事件仍是 PENDING"的条件，否则另一个 worker 推进过就会重复减计数
        local cas = h.store.cas[#h.store.cas]
        t.expect(cas.opts.extra_query["_critical_outbox_v1." .. EVENT .. ".status"]).to.equal("PENDING")
        t.expect(cas.update["$set"]["_critical_outbox_pending_count"]).to.equal(0)
    end)

    -- 投递未确认时保持 PENDING，允许底层 msg_id 重复，业务靠 event_id 去重
    t.it("keeps the event pending when the delivery is not confirmed", function()
        local h = harness()
        h.seed({ assert(h.event()) })
        local stats = assert(h.outbox.pump(h.ctx, function()
            return false
        end, { now = 100 }))
        t.expect(stats.failed).to.equal(1)
        t.expect(stats.enqueued).to.equal(0)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("PENDING")
        t.expect(#(h.store.cas or {})).to.equal(0)
    end)

    t.it("treats a raising deliver function as an unconfirmed delivery", function()
        local h = harness()
        h.seed({ assert(h.event()) })
        local stats = assert(h.outbox.pump(h.ctx, function()
            error("network down")
        end, { now = 100 }))
        t.expect(stats.failed).to.equal(1)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("PENDING")
    end)

    -- CAS 未命中不是"资产已执行但 ACK 丢失"，只是另一个 worker 先推进了
    t.it("treats a CAS miss as a retry, not as an unknown asset state", function()
        local h = harness()
        h.seed({ assert(h.event()) })
        h.store.reject = "cas mismatch"
        local stats = assert(h.outbox.pump(h.ctx, function()
            return true
        end, { now = 100 }))
        t.expect(stats.failed).to.equal(1)
        t.expect(stats.unknown).to.equal(0)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("PENDING")
    end)

    -- 状态未决时必须停下来：在不确定的文档上继续叠加写入只会让恢复更难
    t.it("stops the batch when the status CAS is unknown", function()
        local h = harness()
        local a = assert(h.event({ event_id = "evt_" .. string.rep("1", 64), now = 1 }))
        local b = assert(h.event({ event_id = "evt_" .. string.rep("2", 64), now = 2 }))
        h.seed({ a, b })
        h.store.unknown = "write concern timeout"

        local calls = 0
        local stats = assert(h.outbox.pump(h.ctx, function()
            calls = calls + 1
            return true
        end, { now = 100 }))
        t.expect(stats.unknown).to.equal(1)
        t.expect(calls).to.equal(1)
    end)

    t.it("does nothing when the document is not loaded", function()
        local h = harness()
        h.store.critical = nil
        local ok, err = h.outbox.pump(h.ctx, function()
            return true
        end)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("document not loaded")
    end)

    t.it("returns an empty result when there is nothing pending", function()
        local h = harness()
        h.seed({})
        local stats = assert(h.outbox.pump(h.ctx, function()
            return true
        end))
        t.expect(stats.enqueued).to.equal(0)
        t.expect(#(h.store.cas or {})).to.equal(0)
    end)

    -- 另一个 worker 已经推进过：不能再投一次、也不能把计数减第二次
    t.it("recognizes an event already advanced by another writer", function()
        local h = harness()
        local event = assert(h.event())
        h.seed({ event })
        -- 第一次 CAS 之前，别的 writer 已经把状态推到 ENQUEUED 并清了计数
        h.store.doc._version = 0
        local original = h.dbmgr.critical_update
        local calls = 0
        h.dbmgr.critical_update = function(...)
            calls = calls + 1
            if calls == 1 then
                h.store.critical = {
                    _critical_outbox_v1 = { [EVENT] = { status = "ENQUEUED", attempt = 1 } },
                    _critical_outbox_pending_count = 0,
                }
                return "REJECTED", "cas mismatch"
            end
            return original(...)
        end

        local delivered = 0
        local stats = assert(h.outbox.pump(h.ctx, function()
            delivered = delivered + 1
            return true
        end, { now = 100 }))
        t.expect(stats.already).to.equal(1)
        t.expect(stats.failed).to.equal(0)
        -- 只在第一次投递，重试路径不会再发一遍
        t.expect(delivered).to.equal(1)
        t.expect(h.store.critical._critical_outbox_pending_count).to.equal(0)
    end)

    -- 版本冲突后读后像仍是 PENDING：用新版本重试，成功推进
    t.it("retries the status CAS against the freshly read version", function()
        local h = harness()
        h.seed({ assert(h.event()) })
        local original = h.dbmgr.critical_update
        local calls = 0
        h.dbmgr.critical_update = function(...)
            calls = calls + 1
            if calls == 1 then
                -- 模拟版本被别的写入推进：内存文档前进一版，事件仍是 PENDING
                assert(orm.advance_persisted_version(h.store.doc, 0, 1))
                return "REJECTED", "cas mismatch"
            end
            return original(...)
        end

        local stats = assert(h.outbox.pump(h.ctx, function()
            return true
        end, { now = 100 }))
        t.expect(stats.enqueued).to.equal(1)
        t.expect(calls).to.equal(2)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("ENQUEUED")
    end)

    t.it("reports the age of the oldest pending event", function()
        local h = harness()
        h.seed({ assert(h.event({ now = 100 })) })
        t.expect(h.outbox.oldest_age(h.store.critical, 160)).to.equal(60)
        t.expect(h.outbox.oldest_age(h.store.critical, 90)).to.equal(0)
        t.expect(h.outbox.oldest_age({}, 160)).to.equal(0)
    end)
end)

-- ---------------------------------------------------------------------------
-- 接收方
-- ---------------------------------------------------------------------------
local HASH_BYTES = string.rep("\2", 32)

local function fake_hash()
    return function()
        return HASH_BYTES
    end
end

local real_critical = require "skyext.critical"

local function receiver_harness()
    -- execute_internal 在 load 期就被 outbox.lua 捕获，所以替身必须在加载前构造好
    local holder = { calls = {} }
    local critical_override = setmetatable({
        execute_internal = function(entity, service_op_id, op_type, params, handlers, opts)
            holder.calls[#holder.calls + 1] = {
                entity = entity,
                service_op_id = service_op_id,
                op_type = op_type,
                params = params,
                handlers = handlers,
                opts = opts,
            }
            return holder.result or { status = real_critical.STATUS.COMMITTED }
        end,
    }, { __index = real_critical })

    local h = harness({ critical = critical_override })
    h.holder = holder
    h.param_hash = assert(real_critical.param_hash_of("mail.send", { item = 1 }, fake_hash()))

    local receiver, err = h.outbox.new_receiver({ hash_fn = fake_hash(), op_types = { "mail.send" } })
    assert(receiver, err)
    h.receiver = receiver
    h.entity = {
        type_name = "role",
        id = 7,
        rid = 7,
        db_coords = { dbname = "demo", dbcoll = "role", key = "rid", unique_id = 7 },
    }
    function h.envelope(over)
        local event = assert(h.event(over))
        local env = assert(h.outbox.envelope(event, { type = "role", id = 9 }))
        -- 信封目标必须是本实体，否则接收方按"错投"拒绝，测不到后面的校验
        env.target_id = h.entity.id
        env.param_hash = h.param_hash
        return env
    end
    return h
end

t.describe("outbox 接收方", function()
    t.it("issues a capability and runs the internal commit kernel", function()
        local h = receiver_harness()
        local result = h.receiver:handle(h.entity, h.envelope(), {})
        t.expect(result.status).to.equal("COMMITTED")
        t.expect(#h.holder.calls).to.equal(1)
        local call = h.holder.calls[1]
        t.expect(call.service_op_id).to.equal("srv_" .. string.rep("a", 64))
        t.expect(call.op_type).to.equal("mail.send")
        t.expect(call.opts.source_namespace).to.equal("outbox")
        t.expect(call.opts.source_id).to.equal("role:9")
        -- cap 必须是真实签发的对象，字符串 source 不构成鉴权
        t.expect(require("skyext.capability").is_cap(call.opts.capability)).to.equal(true)

        -- 业务终态必须回执：没有它源端事件永远停在 ENQUEUED，最终撞容量上限
        t.expect(#h.acks).to.equal(1)
        t.expect(h.acks[1].cmd).to.equal("outbox_ack")
        t.expect(h.acks[1].type_name).to.equal("role")
        t.expect(h.acks[1].id).to.equal(9)
        -- 契约：可靠消息用 table.unpack(msg.args) 展开，args 必须是数组。
        -- 传 map 会展开成 0 个参数，handler 只拿到 msg.msg_id，回执永远失效。
        local unpacked = table.pack(table.unpack(h.acks[1].args))
        t.expect(unpacked.n).to.equal(1)
        t.expect(type(unpacked[1])).to.equal("table")
        t.expect(unpacked[1].event_id).to.equal(EVENT)
        -- 回执带上接收方坐标，源端据此校验没有错投
        t.expect(unpacked[1].receiver_type).to.equal("role")
        t.expect(unpacked[1].receiver_id).to.equal(7)
        -- 只通知已加载的源实体，不为一条回执加载离线角色
        t.expect(h.acks[1].opts.lazy).to.equal(true)
    end)

    -- 纯读预检拒绝不是持久化终态：源端资产已扣，ACK 会让事件被删且永不重投
    t.it("does not ack a pure precheck rejection and keeps it visible", function()
        local h = receiver_harness()
        h.holder.result = { status = "PRECHECK_REJECTED", reason = "mail module is not loaded" }
        local ok, err = pcall(h.receiver.handle, h.receiver, h.entity, h.envelope(), {})
        t.expect(ok).to.equal(false)
        t.expect(tostring(err):find("precheck rejected", 1, true)).to_not.be_nil()
        t.expect(#h.acks).to.equal(0)
    end)

    -- validate 抛错发生在 PREPARE 之前，零写入：按环境暂态受控重试，不能当毒消息
    t.it("treats an internal validation error as a retryable fault", function()
        local h = receiver_harness()
        local delivery = require "skyext.entity.delivery"
        h.holder.result = { status = "INTERNAL_ERROR", reason = "validate raised" }
        local value = h.receiver:handle(h.entity, h.envelope(), {})
        t.expect(delivery.is_retryable(value)).to.equal(true)
        t.expect(#h.acks).to.equal(0)
    end)

    -- UNKNOWN 是环境暂态：转成 retryable，让可靠消息保留 pending 而不是进 DLQ
    t.it("converts an unknown commit into a retryable delivery fault", function()
        local h = receiver_harness()
        local delivery = require "skyext.entity.delivery"
        h.holder.result = { status = "UNKNOWN", reason = "mongo down" }
        local value = h.receiver:handle(h.entity, h.envelope(), {})
        t.expect(delivery.is_retryable(value)).to.equal(true)
        -- 没有终态就不能回执：回执意味着"这件事永远不用再做了"
        t.expect(#h.acks).to.equal(0)
    end)

    t.it("rejects an envelope addressed to another entity", function()
        local h = receiver_harness()
        local env = h.envelope()
        env.target_id = 8
        local value, err = h.receiver:handle(h.entity, env, {})
        t.expect(value).to.be_nil()
        t.expect(err).to.equal("envelope target mismatch")
        t.expect(#h.holder.calls).to.equal(0)
    end)

    -- 载荷被改过：重试永远不会成功，按永久无效处理
    t.it("rejects a payload whose hash does not match the envelope", function()
        local h = receiver_harness()
        local env = h.envelope()
        env.param_hash = string.rep("c", 64)
        local value, err = h.receiver:handle(h.entity, env, {})
        t.expect(value).to.be_nil()
        t.expect(err).to.equal("param hash mismatch")
        t.expect(#h.holder.calls).to.equal(0)
    end)

    t.it("refuses to run without a hash function", function()
        local h = receiver_harness()
        h.receiver.hash_fn = nil
        local value, err = h.receiver:handle(h.entity, h.envelope(), {})
        t.expect(value).to.be_nil()
        t.expect(err).to.equal("hash_fn is required")
    end)

    t.it("rejects a malformed envelope before touching the entity", function()
        local h = receiver_harness()
        local value, err = h.receiver:handle(h.entity, { version = 2 }, {})
        t.expect(value).to.be_nil()
        t.expect(err).to.equal("unsupported envelope version")
        t.expect(#h.holder.calls).to.equal(0)
    end)

    t.it("refuses to create a receiver without a namespace", function()
        local h = receiver_harness()
        t.expect(h.outbox.new_receiver({ op_types = { "" } })).to.be_nil()
    end)
end)

t.describe("outbox 状态 CAS 的拒绝分类", function()
    -- 只有版本/条件冲突能重试。租约过期、归属变更、多数派不可用都是环境问题：
    -- 重试只会每轮重复投一条可靠消息，把队列越堆越大
    t.it("stops instead of retrying when the owner lost the lease", function()
        local h = harness()
        local a = assert(h.event({ event_id = "evt_" .. string.rep("1", 64), now = 1 }))
        local b = assert(h.event({ event_id = "evt_" .. string.rep("2", 64), now = 2 }))
        h.seed({ a, b })
        local calls = 0
        local original = h.dbmgr.critical_update
        h.dbmgr.critical_update = function(...)
            calls = calls + 1
            return "REJECTED", "lease expired"
        end

        local delivered = 0
        local stats = assert(h.outbox.pump(h.ctx, function()
            delivered = delivered + 1
            return true
        end, { now = 100 }))
        t.expect(stats.failed).to.equal(1)
        -- 只投了第一条，第二条不能抢跑
        t.expect(delivered).to.equal(1)
        t.expect(calls).to.equal(1)
        t.expect(h.store.critical._critical_outbox_v1[a.event_id].status).to.equal("PENDING")
        h.dbmgr.critical_update = original
    end)

    -- 元数据 CAS 是 metadata_only：UNKNOWN 不能隔离玩家资产
    t.it("marks the status CAS as metadata only and refreshes after an unknown", function()
        local h = harness()
        h.seed({ assert(h.event()) })
        h.store.unknown = "write concern timeout"
        local seen
        local original = h.dbmgr.critical_update
        h.dbmgr.critical_update = function(_, _, _, _, _, _, opts)
            seen = opts
            return original(_, _, _, _, _, _, opts)
        end
        local stats = assert(h.outbox.pump(h.ctx, function()
            return true
        end, { now = 100 }))
        t.expect(stats.unknown).to.equal(1)
        t.expect(seen.metadata_only).to.equal(true)
        -- 写入可能已生效：必须用多数派读对齐版本，否则下一轮永远 CAS 不中
        t.expect(h.store.refreshed).to.equal(1)
    end)
end)

t.describe("outbox 事件摘要", function()
    -- param_hash 必须是接收方重算的那份（op_type + payload），不是源操作参数的摘要
    t.it("computes the payload hash when a hash function is given", function()
        local h = harness()
        -- nil 不会出现在 pairs 里，只能直接构造：这里要的是"调用方没给 param_hash"
        local event = assert(h.outbox.event({
            event_id = EVENT,
            target_type = "role",
            target_id = 9,
            op_type = "mail.send",
            payload = { item = 1 },
            hash_fn = fake_hash(),
            now = 100,
        }))
        t.expect(event.param_hash).to
            .equal(assert(require("skyext.critical").param_hash_of("mail.send", { item = 1 }, fake_hash())))
    end)

    t.it("rejects a caller-supplied hash that disagrees with the payload", function()
        local h = harness()
        t.expect(h.event({ param_hash = string.rep("c", 64), hash_fn = fake_hash() })).to.be_nil()
    end)
end)

t.describe("outbox 实体 ID 归一化", function()
    -- BSON 往返后 int64 会变成字符串：裸 ~= 会把合法信封判成错投并永久 ACK
    t.it("treats a numeric and a decimal-string id as the same", function()
        local h = receiver_harness()
        local env = h.envelope()
        env.target_id = tostring(h.entity.id)
        local result = h.receiver:handle(h.entity, env, {})
        t.expect(result.status).to.equal("COMMITTED")
    end)
end)

t.describe("outbox 接收方状态映射", function()
    -- IN_PROGRESS 是"另一个意图在飞"，ACK 掉就永不执行
    t.it("keeps an in-progress commit pending", function()
        local h = receiver_harness()
        local delivery = require "skyext.entity.delivery"
        h.holder.result = { status = "IN_PROGRESS", reason = "another critical operation is in flight" }
        t.expect(delivery.is_retryable(h.receiver:handle(h.entity, h.envelope(), {}))).to.equal(true)
    end)

    t.it("keeps a capacity rejection pending", function()
        local h = receiver_harness()
        local delivery = require "skyext.entity.delivery"
        h.holder.result = { status = "CAPACITY_EXCEEDED", reason = "ledger full" }
        t.expect(delivery.is_retryable(h.receiver:handle(h.entity, h.envelope(), {}))).to.equal(true)
    end)

    -- 契约/鉴权失败重试不会成功，也不能静默 ACK：抛出去进死信队列才有人看得见
    t.it("raises on a permanent contract violation", function()
        local h = receiver_harness()
        h.holder.result = { status = "OP_CONFLICT", reason = "op_id reused" }
        local ok = pcall(function()
            h.receiver:handle(h.entity, h.envelope(), {})
        end)
        t.expect(ok).to.equal(false)
    end)
end)

-- 投递闭环：接收方回执 -> DELIVERED -> 清理。
-- 没有这一段时 `_critical_outbox_v1` 只增不减，角色撞上 MAX_OUTBOX 后
-- 关键操作会被永久拒绝
t.describe("outbox 投递闭环", function()
    local function eid(ch)
        return "evt_" .. string.rep(ch, 64)
    end

    t.it("marks an enqueued event delivered and stays idempotent", function()
        local h = harness()
        h.seed({
            {
                event_id = EVENT,
                status = "ENQUEUED",
                created_at = h.now - 10,
                updated_at = h.now - 10,
                op_type = "mail.send",
            },
        }, 0)

        t.expect(h.outbox.mark_delivered(h.ctx, EVENT, { now = h.now })).to.equal(true)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("DELIVERED")
        t.expect(#h.store.cas).to.equal(1)

        -- 重复回执（可靠消息重投）：不再写库
        t.expect(h.outbox.mark_delivered(h.ctx, EVENT, { now = h.now })).to.equal(true)
        t.expect(#h.store.cas).to.equal(1)
    end)

    -- 回执可能比本端的状态 CAS 更早到：PENDING 直接到 DELIVERED，计数只减一次
    t.it("acks an event that is still pending without double counting", function()
        local h = harness()
        h.seed({ { event_id = EVENT, status = "PENDING", created_at = h.now - 10, op_type = "mail.send" } }, 1)
        assert(h.outbox.mark_delivered(h.ctx, EVENT, { now = h.now }))
        t.expect(h.store.critical._critical_outbox_pending_count).to.equal(0)
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("DELIVERED")
    end)

    t.it("treats an ack for a cleaned-up event as a late delivery", function()
        local h = harness()
        h.seed({}, 0)
        local ok, err = h.outbox.mark_delivered(h.ctx, eid("f"), { now = h.now })
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("unknown event")
        t.expect(#(h.store.cas or {})).to.equal(0)
    end)

    t.it("rejects malformed event ids at the boundary", function()
        local h = harness()
        t.expect(h.outbox.is_valid_event_id(EVENT)).to.equal(true)
        t.expect(h.outbox.is_valid_event_id("evt_short")).to.equal(false)
        t.expect(h.outbox.is_valid_event_id(987654321)).to.equal(false)
        local ok, err = h.outbox.mark_delivered(h.ctx, "evt_short", { now = h.now })
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("invalid event_id")
    end)

    t.it("only accepts an ack from the event's declared receiver", function()
        local h = harness()
        h.seed({
            {
                event_id = EVENT,
                status = "ENQUEUED",
                created_at = h.now - 10,
                op_type = "mail.send",
                target_type = "role",
                target_id = 9,
            },
        }, 0)
        local ok, err = h.outbox.mark_delivered(h.ctx, EVENT, {
            now = h.now,
            expect_target = { target_type = "role", target_id = 8 },
        })
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("ack receiver mismatch")
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("ENQUEUED")

        assert(h.outbox.mark_delivered(h.ctx, EVENT, {
            now = h.now,
            expect_target = { target_type = "role", target_id = "9" },
        }))
        t.expect(h.store.critical._critical_outbox_v1[EVENT].status).to.equal("DELIVERED")
    end)

    t.it("cleans up delivered and expired events but never pending ones", function()
        local week = 8 * 24 * 3600
        local h = harness()
        h.seed({
            { event_id = eid("a"), status = "DELIVERED", updated_at = h.now - week, op_type = "mail.send" },
            { event_id = eid("b"), status = "DELIVERED", updated_at = h.now - 60, op_type = "mail.send" },
            { event_id = eid("c"), status = "ENQUEUED", updated_at = h.now - week, op_type = "mail.send" },
            { event_id = eid("d"), status = "PENDING", created_at = h.now - week, op_type = "mail.send" },
            { event_id = eid("e"), status = "FAILED", updated_at = h.now - week, op_type = "mail.send" },
            { event_id = eid("f"), status = "FAILED", updated_at = h.now - 60, op_type = "mail.send" },
        }, 1)

        local removed = h.outbox.cleanup(h.ctx, { now = h.now })
        t.expect(removed).to.equal(3)
        local box = h.store.critical._critical_outbox_v1
        t.expect(box[eid("a")]).to.be_nil()
        t.expect(box[eid("c")]).to.be_nil()
        -- FAILED 已进死信：超期后可以腾，否则会被上限永久占位
        t.expect(box[eid("e")]).to.be_nil()
        -- 刚投递/刚失败的留着审计，没投出去的永远不删
        t.expect(box[eid("b")]).to.exist()
        t.expect(box[eid("d")]).to.exist()
        t.expect(box[eid("f")]).to.exist()
        -- 一批删除只推进一次 _version
        t.expect(#h.store.cas).to.equal(1)
    end)

    t.it("does not write anything when there is nothing to clean", function()
        local h = harness()
        h.seed({ { event_id = EVENT, status = "DELIVERED", updated_at = h.now, op_type = "mail.send" } }, 0)
        t.expect(h.outbox.cleanup(h.ctx, { now = h.now })).to.equal(0)
        t.expect(#(h.store.cas or {})).to.equal(0)
    end)
end)
