-- 支付对账 worker（P09）。
--
-- 对账回答一个问题：**这笔订单的发奖到底落库了没有**。
-- 唯一可信的证据是角色文档里 `_critical_ops_v1[service_op_id].status`，
-- 不是"HTTP 回调返回过 200"，也不是"grant 调用没报错"。
--
-- 状态推进：
--   GRANTING  --(证明已 COMMITTED)--> GRANTED --> RECONCILED
--   GRANTED   --(证明已 COMMITTED)--> RECONCILED
--
-- 业务明确拒绝（BUSINESS_REJECTED）不自动改写订单：钱已经收了但东西没给出去，
-- 这是要人工介入的补偿单，不能由 worker 悄悄标成已结案。
local charge_order = require "skyext.charge_order"
local log = require "skyext.log"
local metrics = require "skyext.metrics"

local M = {}

M.DEFAULT_GRACE = 60
M.DEFAULT_SCAN = 32
M.INDEX_NAME = "status_updated_at_order"

M.OUTCOME = {
    RECONCILED = "RECONCILED",
    GRANTED = "GRANTED",
    RETRY = "RETRY",
    PENDING = "PENDING",
    BUSINESS_REJECTED = "BUSINESS_REJECTED",
    UNKNOWN = "UNKNOWN",
}

local m_outcome = metrics.counter("skyext_charge_reconcile_total", "Charge reconciliation outcomes", { "outcome" })

-- 扫描需要核对的订单。
-- grace 是"别抢正在处理的单子"的宽限期：回调可能刚把订单推进到 GRANTING，
-- 发奖还在飞，立刻对账只会读到 NOT_STARTED 然后重投一遍。
function M.scan_orders(orders_coll, opts)
    opts = opts or {}
    if type(orders_coll) ~= "table" then
        return nil, "orders collection is required"
    end
    local status = opts.status or charge_order.STATUS.GRANTING
    local now = opts.now or os.time()
    local grace = opts.grace or M.DEFAULT_GRACE
    local limit = opts.limit or M.DEFAULT_SCAN
    local query = {
        status = status,
        updated_at = { ["$lte"] = now - grace },
        -- 已转人工的单子不再自动扫：否则它会永远占住结果集，把新单饿死
        reconcile_blocked_at = { ["$exists"] = false },
    }
    if type(opts.cursor) == "table" then
        -- keyset 而不是 skip：扫描期间订单会离开当前状态集合，skip 的页边界
        -- 会随集合收缩漂移。按稳定复合键从上一页末尾往后扫，毒单不会占住队头。
        local cursor = opts.cursor
        query["$or"] = {
            { updated_at = { ["$gt"] = cursor.updated_at } },
            {
                updated_at = cursor.updated_at,
                provider = { ["$gt"] = cursor.provider },
            },
            {
                updated_at = cursor.updated_at,
                provider = cursor.provider,
                order_id = { ["$gt"] = cursor.order_id },
            },
        }
    end
    local called, docs, err = pcall(orders_coll.find_many, orders_coll, query, {
        projection = {
            provider = 1,
            order_id = 1,
            rid = 1,
            amount = 1,
            currency = 1,
            action = 1,
            service_op_id = 1,
            status = 1,
            updated_at = 1,
            _id = 0,
        },
        -- Mongo 不显式排序时通常仍按索引顺序返回；毒单会一直占着页首。
        -- 显式稳定排序是 keyset 游标能够续扫下一页的前提。
        sort = { { updated_at = 1 }, { provider = 1 }, { order_id = 1 } },
        limit = limit,
    })
    if not called then
        return nil, "scan failed: " .. tostring(docs)
    end
    if type(docs) ~= "table" then
        return nil, tostring(err or "scan failed")
    end
    return docs
end

-- 对账一单。deps.query_op(rid, service_op_id) 返回 critical.query 的结果：
--   { status = COMMITTED / BUSINESS_REJECTED / NOT_STARTED / IN_PROGRESS / UNKNOWN ... }
-- deps.grant(order) 用于"发奖从未开始"时重新投递（幂等：同一个 service_op_id）
function M.reconcile_order(orders_coll, order, deps, opts)
    opts = opts or {}
    if type(order) ~= "table" then
        return M.OUTCOME.UNKNOWN, "order is required"
    end
    local now = opts.now or os.time()
    local proof, perr = deps.query_op(order.rid, order.service_op_id)
    if not proof then
        -- 查不到证明不等于没执行：绝不能因此把订单标成未发奖
        log.warn("charge reconcile query failed", "order", tostring(order.order_id), "err", tostring(perr))
        m_outcome:inc(1, { outcome = M.OUTCOME.UNKNOWN })
        return M.OUTCOME.UNKNOWN, perr
    end

    -- 只有"角色文档里该 op 已 COMMITTED"才算发奖落库
    if proof.status == "COMMITTED" then
        local reconcile_proof = {
            op_id = order.service_op_id,
            status = proof.status,
            version = proof.version,
            checked_at = now,
        }
        if order.status == charge_order.STATUS.GRANTING or order.status == charge_order.STATUS.VERIFIED_RECEIVED then
            local moved, merr = charge_order.transition(
                orders_coll,
                order.provider,
                order.order_id,
                order.status,
                charge_order.STATUS.GRANTED,
                { granted_at = now, reconcile_proof = reconcile_proof },
                now
            )
            if not moved then
                -- 状态已经被别的路径推进：交给下一轮按最新状态判断
                log.info("charge reconcile transition missed", "order", tostring(order.order_id), "err", tostring(merr))
                m_outcome:inc(1, { outcome = M.OUTCOME.PENDING })
                return M.OUTCOME.PENDING, merr
            end

            -- VERIFIED_RECEIVED 说明落单后还没来得及 transition 到 GRANTING；
            -- COMMITTED 已经是持久化事实，可以安全补到 GRANTED 并立即结案。
            -- GRANTING 保留原来的两阶段推进，下一轮扫到 GRANTED 时再补对账证明。
            if order.status == charge_order.STATUS.VERIFIED_RECEIVED then
                local reconciled, rerr = charge_order.mark_reconciled(orders_coll, order, reconcile_proof, now)
                if not reconciled then
                    m_outcome:inc(1, { outcome = M.OUTCOME.PENDING })
                    return M.OUTCOME.PENDING, rerr
                end
                m_outcome:inc(1, { outcome = M.OUTCOME.RECONCILED })
                return M.OUTCOME.RECONCILED, reconcile_proof
            end
            m_outcome:inc(1, { outcome = M.OUTCOME.GRANTED })
            return M.OUTCOME.GRANTED, reconcile_proof
        end
        if order.status ~= charge_order.STATUS.GRANTED then
            m_outcome:inc(1, { outcome = M.OUTCOME.PENDING })
            return M.OUTCOME.PENDING, "unexpected order state"
        end
        local reconciled, rerr = charge_order.mark_reconciled(orders_coll, order, reconcile_proof, now)
        if not reconciled then
            m_outcome:inc(1, { outcome = M.OUTCOME.PENDING })
            return M.OUTCOME.PENDING, rerr
        end
        m_outcome:inc(1, { outcome = M.OUTCOME.RECONCILED })
        return M.OUTCOME.RECONCILED, reconcile_proof
    end

    if proof.status == "BUSINESS_REJECTED" then
        -- 收了钱但业务拒绝发货：这是补偿单，不是"已结案"
        log.error(
            "charge grant was rejected by business rules, manual compensation required",
            "order",
            tostring(order.order_id),
            "rid",
            tostring(order.rid)
        )
        charge_order.block_reconcile(orders_coll, order, "business_rejected", now)
        m_outcome:inc(1, { outcome = M.OUTCOME.BUSINESS_REJECTED })
        return M.OUTCOME.BUSINESS_REJECTED, proof
    end

    if proof.status == "NOT_STARTED" and type(deps.grant) == "function" then
        local ok, result = pcall(deps.grant, order)
        if not ok then
            log.error("charge regrant raised", "order", tostring(order.order_id), "err", tostring(result))
            m_outcome:inc(1, { outcome = M.OUTCOME.UNKNOWN })
            return M.OUTCOME.UNKNOWN, result
        end
        if type(result) == "table" and result.status == "COMMITTED" then
            -- 刚提交：本轮只推进到 GRANTED，下一轮再核对 RECONCILED
            local reconcile_proof = { op_id = order.service_op_id, status = result.status, checked_at = now }
            local moved, merr = charge_order.transition(
                orders_coll,
                order.provider,
                order.order_id,
                order.status,
                charge_order.STATUS.GRANTED,
                { granted_at = now, reconcile_proof = reconcile_proof },
                now
            )
            if not moved then
                -- CAS 没命中：状态已被别的路径推进，下一轮按最新状态判断
                log.info("charge regrant transition missed", "order", tostring(order.order_id), "err", tostring(merr))
                m_outcome:inc(1, { outcome = M.OUTCOME.PENDING })
                return M.OUTCOME.PENDING, merr
            end
            m_outcome:inc(1, { outcome = M.OUTCOME.GRANTED })
            return M.OUTCOME.GRANTED, reconcile_proof
        end
        m_outcome:inc(1, { outcome = M.OUTCOME.RETRY })
        return M.OUTCOME.RETRY, result
    end

    -- IN_PROGRESS / UNKNOWN / 其它中间态：留待下一轮，绝不当作"没发"
    m_outcome:inc(1, { outcome = M.OUTCOME.PENDING })
    return M.OUTCOME.PENDING, proof.status
end

-- 跑一轮：先补 GRANTED 的 RECONCILED，再处理卡在 GRANTING 的
--
-- deps:
--   orders_coll   订单集合
--   query_op(rid, op_id) -> proof
--   grant(order)  可选：重新投递发奖
--   scan_cursors  可选：按状态保存 keyset 游标，由本函数维护
--   now / grace / limit
function M.run_once(deps, opts)
    opts = opts or {}
    if type(deps) ~= "table" or type(deps.query_op) ~= "function" then
        return nil, "deps.query_op is required"
    end
    local stats = { scanned = 0, reconciled = 0, granted = 0, retried = 0, pending = 0, rejected = 0, unknown = 0 }
    local cursors = opts.cursors or deps.scan_cursors
    if cursors == nil then
        cursors = {}
    end
    local scan_limit = opts.limit or M.DEFAULT_SCAN

    local function bump(outcome)
        if outcome == M.OUTCOME.RECONCILED then
            stats.reconciled = stats.reconciled + 1
        elseif outcome == M.OUTCOME.GRANTED then
            stats.granted = stats.granted + 1
        elseif outcome == M.OUTCOME.RETRY then
            stats.retried = stats.retried + 1
        elseif outcome == M.OUTCOME.BUSINESS_REJECTED then
            stats.rejected = stats.rejected + 1
        elseif outcome == M.OUTCOME.PENDING then
            stats.pending = stats.pending + 1
        else
            stats.unknown = stats.unknown + 1
        end
    end

    -- GRANTED 已经发过奖，核对完就能结案，不需要宽限期。
    -- VERIFIED_RECEIVED 也要扫：落单成功、transition 到 GRANTING 之前崩溃的单子
    -- 否则永远没人看，钱收了奖不发
    for _, status in ipairs({
        charge_order.STATUS.GRANTED,
        charge_order.STATUS.GRANTING,
        charge_order.STATUS.VERIFIED_RECEIVED,
    }) do
        local grace = status == charge_order.STATUS.GRANTED and 0 or (opts.grace or M.DEFAULT_GRACE)
        local cursor = cursors[status]
        local orders, err = M.scan_orders(deps.orders_coll, {
            status = status,
            grace = grace,
            now = opts.now,
            cursor = cursor,
            limit = scan_limit,
        })
        if not orders then
            log.error("charge reconcile scan failed", "status", status, "err", tostring(err))
            return nil, err
        end
        if #orders >= scan_limit then
            local last = orders[#orders]
            cursors[status] = {
                updated_at = last.updated_at,
                provider = last.provider,
                order_id = last.order_id,
            }
        else
            cursors[status] = nil
        end
        stats.scanned = stats.scanned + #orders
        for _, order in ipairs(orders) do
            local outcome = M.reconcile_order(deps.orders_coll, order, deps, opts)
            bump(outcome)
        end
    end
    return stats
end

function M.index_specs(colls)
    return {
        {
            colls.orders,
            {
                { status = 1 },
                { updated_at = 1 },
                { provider = 1 },
                { order_id = 1 },
                name = M.INDEX_NAME,
            },
        },
    }
end

-- 返回 true 或 nil, err。索引建不起来时调用方必须禁止启用对账 worker
function M.ensure_indexes(colls)
    for _, spec in ipairs(M.index_specs(colls)) do
        local coll, keys = spec[1], spec[2]
        if not coll then
            return nil, "missing collection for index " .. tostring(keys.name)
        end
        local called, ok, err = pcall(coll.create_index, coll, keys)
        if not called then
            return nil, "create_index raised: " .. tostring(ok)
        end
        if type(ok) == "table" then
            if ok.ok ~= 1 then
                return nil, "create_index failed: " .. tostring(ok.errmsg or keys.name)
            end
        elseif ok ~= true then
            return nil, "create_index failed: " .. tostring(err or keys.name)
        end
    end
    return true
end

return M
