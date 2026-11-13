local log = require "skyext.log"

local M = {}

M.handlers = {}

function M.handlers.get_online_info(entity)
    if not entity.session then
        return nil
    end
    return { rid = entity.id, name = entity.data.name }
end

function M.handlers.kick(entity)
    if entity.session then
        local session = require "skyext.entity.session"
        session.unbind_kick(entity.session.key, entity)
    end
    return true
end

-- 可靠消息的 handler：最后一个参数是 msg_id。消息至少投递一次，
-- 拿 msg_id 当邮件 id，重复投递时 mail 模块会认出来并跳过
function M.handlers.recv_mail(entity, mail, msg_id)
    mail.mail_id = msg_id
    if entity.modules.mail:receive(mail) then
        log.info("mail received", "rid", entity.id, "mail_id", msg_id)
    end
end

-- Outbox 事件接收端（P13）。发送方在角色文档的同一个 CAS 里写资产扣减与
-- `_critical_outbox_v1[event_id]`，worker 经可靠消息投递到这里。
-- 去重键是 `event_id -> service_op_id` 的纯函数映射，**不是** msg_id：
-- 同一条事件允许出现多条底层队列消息，业务效果至多一次。
local g_outbox_receiver

local function outbox_receiver()
    if g_outbox_receiver then
        return g_outbox_receiver
    end
    local outbox = require "skyext.outbox"
    local crypto = require "crypto"
    -- 冷账本：热账本 7 天后归档，没有它就无法证明同一个 service_op_id 执行过，
    -- 重投就会二次入账。取不到时 receiver 会在投递阶段 fail-closed，不会静默放行
    local ledger
    local ok_ledger, got = pcall(function()
        local types = require "skyext.entity.types"
        local tc = types.get("role")
        if tc and type(tc.critical_ledger) == "table" then
            return require("skyext.mongo_conn").get_collection(tc.critical_ledger.db, tc.critical_ledger.coll)
        end
    end)
    if ok_ledger then
        ledger = got
    end
    -- op_types 必须显式给出：空白名单等于放行任意操作类型
    g_outbox_receiver = assert(outbox.new_receiver({
        hash_fn = crypto.hmac_sha256,
        op_types = { "mail.send" },
        ledger = ledger,
    }))
    return g_outbox_receiver
end

-- 示例业务语义：把事件当一封邮件投递。真正的资产效果由游戏层定义，
-- 但"至多一次"由 critical 的 service_op_id 保证，不依赖这里的实现
local function outbox_handlers()
    return {
        validate = function(_, params)
            return type(params) == "table" and type(params.title) == "string"
        end,
        apply = function(entity, params)
            if not entity.modules or not entity.modules.mail then
                return false, "mail module is not loaded"
            end
            return entity.modules.mail:receive({
                title = params.title,
                body = params.body,
                attachments = params.attachments,
            }) and true or false
        end,
    }
end

-- 最后一个参数是 msg_id（可靠消息的队列身份）。这里保留形参以匹配投递约定，
-- 但绝不拿它当业务去重键
function M.handlers.__apply_outbox_event(entity, envelope, msg_id)
    local ok, result, err = pcall(function()
        return outbox_receiver():handle(entity, envelope, outbox_handlers())
    end)
    if not ok then
        -- handler 自身抛错属于契约/代码问题：让 _deliver_one 计入 attempts，最终进 DLQ
        error(result, 0)
    end
    if result == nil then
        -- 永久无效（信封/目标/摘要不符）：ACK 掉，不要进 DLQ 循环
        log.error("outbox event rejected", "rid", tostring(entity.id), "err", tostring(err))
        return nil, err
    end
    -- UNKNOWN / 环境暂态时 result 是 delivery.retryable 标记，原样透传，
    -- 由 _deliver_one 保留 pending、不计毒、稍后重投
    return result
end

-- 充值到账（P09/P11）。链路：
--   pay_callback 验签落单 -> entity_agent.framework_charge_grant 签 capability
--   -> charge_order.grant -> critical.execute_internal -> 这里
--
-- 没有这个 handler，`charge_grant` 会直接报 "entity handler has no charge_handlers"：
-- 框架侧的支付链路是完整的，缺的正是游戏层这一条资产效果。
--
-- 两条硬约束（critical 的 handler 契约）：
--   * validate 纯读、不 yield；
--   * apply 只改内存，不 RPC、不推送、不发邮件——本角色 CAS 失败时没有任何东西可回滚。
-- 示例汇率：**amount 是整数最小单位（分），不是元**。
-- `pay_webhook` 明确要求 amount 为正整数最小单位，所以这里按"1 分 = 1 金币"换算，
-- 也就是 1 元 = 100 金币。写成 CNY = 100 会把分当元，每笔多发 100 倍
local CHARGE_RATE = { CNY = 1 }
local CHARGE_RES = { res_type = 1, res_id = 1 } -- 金币在 res 表里的坐标

-- validate 与 apply 必须用同一份换算：两边各写一遍迟早会在浮点/取整上分叉，
-- 而分叉的后果是"校验通过、apply 算出的数量不同"
local function charge_count(params)
    if type(params) ~= "table" then
        return nil, "params is required"
    end
    local amount = math.tointeger(params.amount)
    if not amount or amount <= 0 then
        return nil, "invalid amount"
    end
    local rate = CHARGE_RATE[params.currency]
    if not rate then
        return nil, "unsupported currency: " .. tostring(params.currency)
    end
    local count = amount * rate
    -- 乘法溢出会绕回负数，而负数是 truthy：不拦就会以负 count 调 add_item（实际是扣减）
    if math.type(count) ~= "integer" or count <= 0 then
        return nil, "amount overflow"
    end
    return count
end

function M.charge_handlers(entity, _order)
    return {
        validate = function(_, params)
            local count, err = charge_count(params)
            if not count then
                return false, err
            end
            if not entity.modules or not entity.modules.bag then
                return false, "bag module is not loaded"
            end
            return true
        end,
        apply = function(entity, params)
            local count = charge_count(params)
            if not count then
                -- validate 已经拦过：走到这里说明有人绕过了它，不能悄悄发 0 个
                return false, "invalid charge params"
            end
            entity.modules.bag:add_item(CHARGE_RES.res_type, CHARGE_RES.res_id, count)
            return true
        end,
    }
end

function M.on_load(entity)
    log.info("role entity loaded", "rid", entity.id)
end

function M.on_unload(entity)
    log.info("role entity unloading", "rid", entity.id)
end

-- entity.session 由 skyext.entity.session 维护，这里只放业务上的上下线逻辑
function M.on_bind_client(entity, session_key)
    log.info("role client bound", "rid", entity.id, "session", session_key)
end

function M.on_unbind_client(entity)
    log.info("role client unbound", "rid", entity.id)
end

-- 断线续接成功。**不是**一次上线：续接的全部意义就是这次网络抖动不构成上下线，
-- 所以 on_bind_client / on_unbind_client 都不会触发。在线时长、上线奖励、好友在线
-- 状态这类逻辑不要写在这里，它们属于那两个钩子
function M.on_resume_client(entity, session_key)
    log.info("role client resumed", "rid", entity.id, "session", session_key)
end

return M
