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
