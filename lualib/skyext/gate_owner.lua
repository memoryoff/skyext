-- 网关侧的 owner_epoch 路由过滤（P14）。
--
-- `owner_epoch` 是**网关内部的**所有权代际：Role 每取得一次新的 Fence 就推进它，并通过
-- `bind_owner` 通知网关。网关只比较 RPC 参数里的这个整数，**绝不解码客户端 sproto**
-- 去取 epoch——网关不解码协议这条约束不能因为防迟到而破坏。
--
-- 与 `session_epoch` 的分工：
--   * `session_epoch` 是逻辑会话身份，写在 DownlinkV2 里，断线续接与计划内迁移都不变；
--   * `owner_epoch` 只活在网关内存里，每次 Role 所有权切换都会推进。
--   同一个逻辑会话迁移后，wire 上的 session_epoch 与 seq 都不变，变的只有 owner_epoch。
--
-- 这个模块是纯函数集合，只操作调用方给的 session 表，便于单测；两个网关共用同一份语义。
local M = {}

M.ERR = {
    INVALID_EPOCH = "invalid_epoch",
    STALE_EPOCH = "stale_epoch",
    FROZEN = "frozen",
    NOT_BOUND = "not_bound",
}

local function check_epoch(epoch)
    if math.type(epoch) ~= "integer" or epoch < 1 then
        return nil, M.ERR.INVALID_EPOCH
    end
    return epoch
end
M.check_epoch = check_epoch

-- 绑定/接管所有权。旧 epoch（含相等）一律拒绝：相等说明是重复投递，
-- 小于说明是上一个 owner 的迟到 RPC。
function M.bind(session, epoch, owner_node, owner_service)
    local e, err = check_epoch(epoch)
    if not e then
        return nil, err
    end
    if session.owner_epoch and e <= session.owner_epoch then
        return nil, M.ERR.STALE_EPOCH
    end
    session.owner_epoch = e
    session.owner_node = owner_node
    session.owner_service = owner_service
    session.frozen_epoch = nil
    session.barrier_id = nil
    -- 每次换 owner 重新计数：这个数字只描述"本次所有权期间网关受理了多少下行"，
    -- 不是客户端已收包数，不能与 Role 的 io_.acked 直接比对
    session.pushed = 0
    return true
end

-- 下行过滤。epoch 为 nil 表示调用方没有版本信息（旧调用方），按放行处理；
-- 生产路径必须带 epoch。
function M.push_allowed(session, epoch)
    if epoch == nil then
        return true
    end
    local e, err = check_epoch(epoch)
    if not e then
        return nil, err
    end
    if session.frozen_epoch and e <= session.frozen_epoch then
        -- 屏障已经切断这个 owner：它之后发的包一律不能到达客户端
        return nil, M.ERR.FROZEN
    end
    if session.owner_epoch == nil then
        return nil, M.ERR.NOT_BOUND
    end
    if e ~= session.owner_epoch then
        return nil, M.ERR.STALE_EPOCH
    end
    return true
end

-- 屏障：从这一刻起，epoch <= frozen_epoch 的下行全部丢弃。
--
-- 返回的 `sent` 是**网关本次所有权期间受理的下行数**（含写失败的尝试），
-- 只用来判断"屏障前有没有包被漏在队列里"。**客户端实际收到多少，只有 Role 的
-- `io_.sent` / `io_.acked` 说了算**——那两个才是重放与 ACK 的权威计数。
function M.freeze(session, epoch, barrier_id)
    local e, err = check_epoch(epoch)
    if not e then
        return nil, err
    end
    if session.owner_epoch ~= e then
        return nil, M.ERR.STALE_EPOCH
    end
    session.frozen_epoch = e
    session.barrier_id = barrier_id
    return true, { sent = session.pushed or 0, epoch = e, barrier_id = barrier_id }
end

-- 解除屏障并把所有权交给新 epoch。新 epoch 必须严格更大，
-- 否则"解冻"会被旧 owner 的迟到 RPC 利用
function M.resume(session, new_epoch, owner_node, owner_service)
    local e, err = check_epoch(new_epoch)
    if not e then
        return nil, err
    end
    if session.owner_epoch and e <= session.owner_epoch then
        return nil, M.ERR.STALE_EPOCH
    end
    session.owner_epoch = e
    session.owner_node = owner_node
    session.owner_service = owner_service
    session.frozen_epoch = nil
    session.barrier_id = nil
    session.pushed = 0
    return true
end

-- 只读观测
function M.state(session)
    return {
        owner_epoch = session.owner_epoch,
        frozen_epoch = session.frozen_epoch,
        barrier_id = session.barrier_id,
        pushed = session.pushed or 0,
    }
end

return M
