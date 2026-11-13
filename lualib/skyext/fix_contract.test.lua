-- 跨模块契约测试：直接加载**真实源码**，只桩外部依赖。
--
-- 为什么需要这一组：122 个单测里，launcher 用恒真的 start 桩、适配器用
-- 对 session_export 直接返回快照的假 skynet.call、entity_agent 用不做 epoch
-- 校验的假 session。它们能全绿，却测不到"命令是否存在 / 参数形状是否匹配 /
-- 代际能否推进"。这里把三处修复钉在真实模块的契约上。
local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local ROOT = fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir())

local function noop() end
local function loose()
    return setmetatable({}, {
        __index = function()
            return noop
        end,
    })
end
local function log_stub()
    return { info = noop, warn = noop, error = noop, debug = noop, notice = noop }
end
local function metrics_stub()
    local o = { inc = noop, set = noop, observe = noop, dec = noop, add = noop }
    return {
        counter = function()
            return o
        end,
        gauge = function()
            return o
        end,
        histogram = function()
            return o
        end,
    }
end

local function load_module(path, imports, ...)
    local env = setmetatable({
        require = function(name)
            if imports[name] ~= nil then
                return imports[name]
            end
            return require(name)
        end,
    }, { __index = _G })
    return assert(loadfile(fs.join(ROOT, path), "t", env))(...)
end

--------------------------------------------------------------------------------
-- 真实 entity_agent 的 CMD 表
--------------------------------------------------------------------------------
local function real_agent_cmd()
    local CMD, started
    load_module("service/entity_agent.lua", {
        skynet = {
            start = function(fn)
                started = fn
            end,
            register = noop,
            call = noop,
            send = noop,
            now = function()
                return 10000
            end,
        },
        ["skynet.cluster"] = loose(),
        ["skyext.cmd_api"] = {
            dispatch = function(c)
                CMD = c
            end,
            register = noop,
        },
        ["skyext.entity.types"] = {
            get = function()
                return { client_enabled = false }
            end,
            format_agent_service_name = function(name, i)
                return ".entity_agent:" .. name .. ":" .. i
            end,
            calc_agent_index = function()
                return 1
            end,
            calc_node = function()
                return "node-a"
            end,
        },
        ["skyext.entity.entitymgr"] = loose(),
        ["skyext.distributed_lock"] = loose(),
        ["skyext.log"] = log_stub(),
        ["skyext.errcode"] = loose(),
        ["skyext.config"] = {
            get = function()
                return "node-a"
            end,
            get_table = function()
                return {}
            end,
        },
    }, "role", 1)
    assert(started)
    started()
    assert(CMD)
    return CMD
end

t.describe("迁移链路契约", function()
    t.it("exposes session_export as a real service command", function()
        local CMD = real_agent_cmd()
        t.expect(type(CMD.session_export)).to.equal("function")
        t.expect(type(CMD.entity_call)).to.equal("function")
        t.expect(type(CMD.session_attach)).to.equal("function")
    end)

    t.it("lets the real adapter export through a dispatch that only knows real CMDs", function()
        local CMD = real_agent_cmd()
        local seen
        local adapter = load_module("example/lualib/migration_adapter.lua", {
            skynet = {
                localname = function()
                    return "mgr"
                end,
                -- 模拟 cmd_api.dispatch：不认识的命令直接 error
                call = function(_, _, cmd, ...)
                    seen = { cmd = cmd, args = table.pack(...) }
                    if type(CMD[cmd]) ~= "function" then
                        error("Unknown command: " .. tostring(cmd), 0)
                    end
                    if cmd == "session_export" then
                        return true, { bytes = "SNAPSHOT", owner_epoch = 3, source_owner_epoch = 2 }
                    end
                    return true
                end,
            },
            ["skynet.cluster"] = {
                call = function()
                    return true
                end,
            },
            ["skyext.cluster_discovery"] = {
                state = function()
                    return { nodes = { "node-b" } }
                end,
            },
            ["skyext.config"] = {
                get = function()
                    return "node-a"
                end,
            },
            ["skyext.connection_id"] = {
                parse = function()
                    return { gate_node = "gate1", gate_service = ".gate_tcp" }
                end,
            },
            ["skyext.log"] = log_stub(),
            ["skyext.entity.types"] = {
                format_agent_service_name = function(name, i)
                    return ".entity_agent:" .. name .. ":" .. i
                end,
                calc_agent_index = function()
                    return 1
                end,
                calc_node = function()
                    return "node-b"
                end,
            },
        })
        adapter.init({ type_name = "role" })
        local snapshot = assert(adapter.export({ id = 7, owner_epoch = 2 }, "b1"))
        t.expect(snapshot.bytes).to.equal("SNAPSHOT")
        -- CMD.session_export(entity_id, barrier_id, target_owner_epoch)
        t.expect(seen.args[1]).to.equal(7)
        t.expect(seen.args[2]).to.equal("b1")
        t.expect(seen.args[3]).to.equal(3)
    end)

    t.it("accepts a strictly newer owner epoch in the real session.attach", function()
        local session = load_module("lualib/skyext/entity/session.lua", {
            skynet = {
                now = function()
                    return 10000
                end,
                call = function()
                    return true
                end,
                send = noop,
            },
            ["skynet.cluster"] = loose(),
            crypto = loose(),
            ["skyext.config"] = {
                get = function()
                    return "gate1"
                end,
                get_number = function()
                    return 300
                end,
            },
            ["skyext.connection_id"] = {
                parse = function()
                    return { gate_node = "gate1", gate_service = ".gate_tcp" }
                end,
            },
            ["skyext.downlink"] = loose(),
            ["skyext.errcode"] = loose(),
            ["skyext.fingerprint"] = loose(),
            ["skyext.log"] = log_stub(),
            ["skyext.timer"] = loose(),
            ["skyext.metrics"] = metrics_stub(),
        })
        local entity = { type_name = "role", id = 7, session_io = { owner_epoch = 2, session_epoch = "e1" } }
        -- 修复前这里传的是 io_.owner_epoch（2），必然返回 "owner epoch must advance"
        local ok, err = session.attach("conn-7", entity, ".entity_agent:role:2", 3)
        t.expect(err).to.be_nil()
        t.expect(ok).to.equal(true)
        t.expect(entity.session_io.owner_epoch).to.equal(3)
    end)
end)

--------------------------------------------------------------------------------
-- Outbox 回执：acks 数组 -> table.unpack -> mark_delivered -> DELIVERED
--------------------------------------------------------------------------------
t.describe("Outbox 回执链路契约", function()
    local function setup()
        local EVENT = "evt_" .. string.rep("c", 64)
        local HASH = string.rep("a", 64)
        local acks = {}
        local store = {
            critical = {
                _critical_outbox_v1 = {
                    [EVENT] = { status = "PENDING", created_at = 1000, op_type = "mail.send" },
                },
                _critical_outbox_pending_count = 1,
            },
        }
        local fake_critical = {
            OUTBOX_FIELD = "_critical_outbox_v1",
            EVENT_PREFIX = "evt_",
            STATUS = { COMMITTED = "COMMITTED", PRECHECK_REJECTED = "PRECHECK_REJECTED" },
            param_hash_of = function()
                return HASH
            end,
            service_op_id_from_event = function()
                return "svc_op_1"
            end,
        }
        local outbox = load_module("lualib/skyext/outbox.lua", {
            ["skyext.critical"] = fake_critical,
            ["skyext.dbmgr"] = {
                cached_critical = function()
                    return store.critical
                end,
                critical_update = function()
                    return "CONFIRMED"
                end,
                set_critical = function(_, _, _, value)
                    store.critical = value
                end,
                refresh_critical = function()
                    return true
                end,
            },
            ["skyext.log"] = log_stub(),
            ["skyext.metrics"] = metrics_stub(),
            ["skyext.capability"] = {
                new_issuer = function()
                    return "issuer"
                end,
                issue = function()
                    return "cap"
                end,
            },
            ["skyext.entity.delivery"] = {
                retryable = function(r)
                    return { reason = r }
                end,
            },
            ["skyext.entity.router"] = {
                reliable_send = function(type_name, id, cmd, args)
                    acks[#acks + 1] = { type_name = type_name, id = id, cmd = cmd, args = args }
                    return 12345
                end,
            },
            crypto = {
                random_bytes = function(n)
                    return string.rep("x", n)
                end,
            },
        })
        return outbox, EVENT, acks, store
    end

    t.it("delivers a real event_id through table.unpack and reaches DELIVERED", function()
        local outbox, EVENT, acks, store = setup()
        local receiver = assert(outbox.new_receiver({
            op_types = { "mail.send" },
            hash_fn = function()
                return "h"
            end,
            -- 构造期要求冷账本；这条用例只验证回执解包，不进 handle
            ledger = {},
        }))
        receiver:ack_source({ source_type = "role", source_id = 1, event_id = EVENT })

        t.expect(#acks).to.equal(1)
        t.expect(acks[1].cmd).to.equal("outbox_ack")
        -- entitymgr._deliver_one 的真实解包：先展开 args，再追加 msg.msg_id
        local msg = { args = acks[1].args, msg_id = 987654321 }
        local args = table.pack(table.unpack(msg.args or {}))
        args.n = args.n + 1
        args[args.n] = msg.msg_id
        t.expect(args.n).to.equal(2)
        t.expect(type(args[1])).to.equal("table")
        t.expect(args[1].event_id).to.equal(EVENT)

        local ctx = { dbname = "demo", dbcoll = "role", key = "rid", unique_id = 1, doc = { _version = 1 } }
        local ok, err = outbox.mark_delivered(ctx, args[1].event_id, { now = 2000 })
        t.expect(err).to.be_nil()
        t.expect(ok).to.equal(true)
        t.expect(store.critical._critical_outbox_v1[EVENT].status).to.equal("DELIVERED")
    end)
end)

--------------------------------------------------------------------------------
-- 关键字段白名单契约
--
-- 这一组守的是一个"上线即炸"的失败模式：critical 往文档里写了某个
-- `_critical_*` 字段，但 critical_fields 的白名单没登记它。extract 看到未知的
-- `_critical_*` 会直接拒绝整个文档（这是对的，旧代码没资格删新字段），
-- 结果是**写过 Outbox 的角色下次加载就永久登不上**。
--
-- 124 个单测全绿也发现不了，因为没有一个用例把"提交后的文档"再喂回 extract。
-- 所以这里既断言当前字段齐全，也断言"critical 导出的每个 *_FIELD 都在白名单里"
-- 这条结构性不变式，以后新增字段漏登记会立刻变红。
--------------------------------------------------------------------------------
t.describe("关键字段白名单契约", function()
    t.it("exposes the outbox seq field in the whitelist", function()
        local cf = require "skyext.critical_fields"
        local allowed = {}
        for _, name in ipairs(cf.FIELDS) do
            allowed[name] = true
        end
        t.expect(allowed["_critical_outbox_seq"]).to.equal(true)
    end)

    t.it("keeps every critical *_FIELD constant inside the whitelist", function()
        local cf = require "skyext.critical_fields"
        local crit = require "skyext.critical"
        local allowed = {}
        for _, name in ipairs(cf.FIELDS) do
            allowed[name] = true
        end
        local missing = {}
        for key, value in pairs(crit) do
            if type(key) == "string" and key:match("_FIELD$") and type(value) == "string" then
                if not allowed[value] then
                    missing[#missing + 1] = key .. "=" .. value
                end
            end
        end
        table.sort(missing)
        -- 失败信息要直接指出是哪个常量漏登记，而不是只说"断言失败"
        t.expect(table.concat(missing, ", ")).to.equal("")
    end)

    t.it("accepts a document written by a full commit round trip", function()
        local cf = require "skyext.critical_fields"
        local crit = require "skyext.critical"
        -- 按 critical 自己的字段常量拼一份"刚提交完"的文档后像
        local doc = {
            rid = 7,
            gold = 100,
            [crit.OUTBOX_FIELD] = {
                evt_abc = {
                    event_id = "evt_abc",
                    status = "PENDING",
                    causal_seq = 1,
                    target_type = "role",
                    target_id = 8,
                    op_type = "mail.send",
                    param_hash = string.rep("a", 64),
                    created_at = 1000,
                },
            },
            [crit.OUTBOX_PENDING_FIELD] = 1,
            [crit.OUTBOX_SEQ_FIELD] = 1,
            -- 终态清理标记也必须在白名单里，否则 worker 写完之后角色就加载不了
            [crit.OUTBOX_CLEANUP_FIELD] = 2000,
            [crit.OPS_FIELD] = {
                srv_abc = { status = "COMMITTED", op_type = "mail.send", at = 1000 },
            },
            [crit.OPS_OLDEST_FIELD] = 1000,
        }
        local clean, critical, reject = cf.extract(doc)
        t.expect(reject).to.be_nil()
        t.expect(clean).to.exist()
        t.expect(critical).to.exist()
        t.expect(critical[crit.OUTBOX_SEQ_FIELD]).to.equal(1)
        t.expect(critical[crit.OUTBOX_PENDING_FIELD]).to.equal(1)
        t.expect(critical[crit.OUTBOX_CLEANUP_FIELD]).to.equal(2000)
    end)

    t.it("rejects a seq that is not a non-negative integer", function()
        local cf = require "skyext.critical_fields"
        local crit = require "skyext.critical"
        local ok, err = cf.extract({
            rid = 7,
            [crit.OUTBOX_SEQ_FIELD] = 1.5,
        })
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("_critical_outbox_seq")
    end)
end)
