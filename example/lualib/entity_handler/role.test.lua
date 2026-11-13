-- Outbox 接收端接线：可靠消息的 msg_id 只能当队列身份，业务去重必须走 event_id。
-- handler 的返回值语义要和 entitymgr._deliver_one 的旧合同对齐：
--   普通返回值（含 nil）→ ACK；抛错 → 计入 attempts；retryable 标记 → 保留 pending。
local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source =
    fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/lualib/entity_handler/role.lua")

local function harness(opts)
    opts = opts or {}
    local h = { handled = {}, errors = {} }
    local imports = {
        ["skyext.log"] = {
            info = function() end,
            warn = function() end,
            error = function(...)
                h.errors[#h.errors + 1] = table.pack(...)
            end,
        },
        ["skyext.outbox"] = {
            new_receiver = function(conf)
                h.receiver_conf = conf
                return {
                    handle = function(_, entity, envelope, handlers)
                        h.handled[#h.handled + 1] = {
                            entity = entity,
                            envelope = envelope,
                            handlers = handlers,
                        }
                        if opts.handle_raises then
                            error("receiver exploded")
                        end
                        return opts.handle_result
                    end,
                }
            end,
        },
        crypto = {
            hmac_sha256 = function()
                return "hash"
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.handler = assert(loadfile(source, "t", env))()
    return h
end

local function envelope()
    return {
        version = 1,
        event_id = "evt_" .. string.rep("a", 64),
        source_type = "role",
        source_id = 9,
        target_type = "role",
        target_id = 7,
        op_type = "mail.send",
        payload = { title = "hello" },
        param_hash = string.rep("b", 64),
    }
end

t.describe("role outbox receiver", function()
    t.it("registers the __apply_outbox_event handler with a fixed op type whitelist", function()
        local h = harness({ handle_result = { status = "COMMITTED" } })
        local entity = { id = 7, type_name = "role" }
        local result = h.handler.handlers.__apply_outbox_event(entity, envelope(), "msg-1")
        t.expect(result.status).to.equal("COMMITTED")
        t.expect(h.receiver_conf.op_types).to.equal({ "mail.send" })
        t.expect(type(h.receiver_conf.hash_fn)).to.equal("function")
        -- handle 只拿到 entity/envelope/handlers，msg_id 不进入业务去重
        t.expect(#h.handled).to.equal(1)
        t.expect(h.handled[1].entity).to.equal(entity)
    end)

    t.it("passes the retryable marker through so _deliver_one keeps the message pending", function()
        local retryable = { retryable = "unknown" }
        local h = harness({ handle_result = retryable })
        local result = h.handler.handlers.__apply_outbox_event({ id = 7 }, envelope(), "msg-1")
        t.expect(result).to.equal(retryable)
    end)

    t.it("re-raises receiver failures so they count as attempts, not as success", function()
        local h = harness({ handle_raises = true })
        t.expect(function()
            h.handler.handlers.__apply_outbox_event({ id = 7 }, envelope(), "msg-1")
        end).to
            .throw("receiver exploded")
    end)

    t.it("acks a permanently invalid envelope instead of looping it in the DLQ", function()
        local h = harness()
        local result, err = h.handler.handlers.__apply_outbox_event({ id = 7 }, envelope(), "msg-1")
        t.expect(result).to.be_nil()
        t.expect(err).to.be_nil()
        t.expect(#h.errors).to.equal(1)
    end)
end)

-- 支付发奖：框架的 charge_grant 需要游戏层给出真实的资产效果。
-- 这组用例盯的是 critical 的 handler 契约：validate 纯读、apply 只改内存。
t.describe("role 充值发奖 handler", function()
    local function entity_with_bag()
        local bag = { items = {} }
        function bag:add_item(res_type, res_id, count)
            self.items[#self.items + 1] = { res_type = res_type, res_id = res_id, count = count }
        end
        return { id = 7, data = { modules = {} }, modules = { bag = bag } }, bag
    end

    t.it("adds the converted amount to the bag on apply", function()
        local h = harness()
        local entity, bag = entity_with_bag()
        local handlers = h.handler.charge_handlers(entity, { order_id = "o-1" })
        t.expect(handlers.validate(entity, { amount = 100, currency = "CNY" })).to.equal(true)
        -- validate 必须纯读：跑完 validate 背包还是空的
        t.expect(#bag.items).to.equal(0)
        t.expect(handlers.apply(entity, { amount = 100, currency = "CNY" })).to.equal(true)
        t.expect(bag.items[1]).to.equal({ res_type = 1, res_id = 1, count = 10000 })
    end)

    t.it("rejects an unsupported currency or a non-positive amount before touching memory", function()
        local h = harness()
        local entity, bag = entity_with_bag()
        local handlers = h.handler.charge_handlers(entity, {})
        t.expect(handlers.validate(entity, { amount = 100, currency = "USD" })).to.equal(false)
        t.expect(handlers.validate(entity, { amount = 0, currency = "CNY" })).to.equal(false)
        t.expect(handlers.validate(entity, { amount = -1, currency = "CNY" })).to.equal(false)
        -- 整值浮点（JSON/BSON 往返常见）必须按整数收下，不能被当成非法
        t.expect(handlers.validate(entity, { amount = 100.0, currency = "CNY" })).to.equal(true)
        t.expect(#bag.items).to.equal(0)
    end)

    t.it("refuses to apply when the bag module is missing", function()
        local h = harness()
        local entity = { id = 7, modules = {}, data = { modules = {} } }
        local handlers = h.handler.charge_handlers(entity, {})
        t.expect(handlers.validate(entity, { amount = 100, currency = "CNY" })).to.equal(false)
        -- apply 不依赖 validate 的结果：绕过校验直接调也不能静默发 0 个
        t.expect(handlers.apply(entity, { amount = 100, currency = "XXX" })).to.equal(false)
    end)
end)
