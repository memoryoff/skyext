-- 客户端关键操作入口（P08 / grant_v1）。
--
-- 只做两件事：校验服务端签发的 Grant 结构，把它组装成一次请求。
-- **不自签 Grant、不实现请求指纹、不猜业务去重**——这三件事都在服务端，
-- 客户端多做一层只会制造第二套语义。契约见 docs/design/critical_grant_v1.md。
--
-- 这里的校验是"早失败"：字段明显不合法时不要发出去，免得占一个 seq 还拿不到结果。
-- mac 的验签只有服务端密钥能做，客户端不碰。
local M = {}

M.VERSION = 1
M.MAX_SEQ = 0xffff

local function is_int(v)
    return math.type(v) == "integer"
end

local function non_empty(v)
    return type(v) == "string" and #v > 0
end

-- 结构校验。返回 true 或 nil, reason
function M.validate_grant(grant)
    if type(grant) ~= "table" then
        return nil, "grant must be a table"
    end
    if grant.version ~= M.VERSION then
        return nil, "unsupported grant version"
    end
    -- rid 允许整数或字符串：64-bit ID 走字符串才不会被 JS Number 截断
    if not (is_int(grant.rid) or non_empty(grant.rid)) then
        return nil, "invalid rid"
    end
    if not non_empty(grant.grant_id) or #grant.grant_id ~= 32 then
        return nil, "invalid grant_id"
    end
    if not is_int(grant.issued_at) or not is_int(grant.expires_at) then
        return nil, "invalid timestamps"
    end
    if grant.expires_at <= grant.issued_at then
        return nil, "expires_at must be after issued_at"
    end
    if not is_int(grant.max_seq) or grant.max_seq < 1 or grant.max_seq > M.MAX_SEQ then
        return nil, "invalid max_seq"
    end
    if not non_empty(grant.key_id) then
        return nil, "invalid key_id"
    end
    if not non_empty(grant.mac) then
        return nil, "invalid mac"
    end
    return true
end

-- 组装一次关键操作请求。
-- protocol 是承载它的 sproto 协议名，由游戏层给出：SDK 不猜 wire 名字，
-- 否则协议改名后客户端会静默发到一个服务端不认识的地方。
function M.request(opts)
    opts = opts or {}
    local ok, err = M.validate_grant(opts.grant)
    if not ok then
        return nil, err
    end
    if not is_int(opts.seq) or opts.seq < 1 or opts.seq > opts.grant.max_seq then
        return nil, "seq out of range"
    end
    if not non_empty(opts.op_type) then
        return nil, "op_type is required"
    end
    if opts.params ~= nil and type(opts.params) ~= "table" then
        return nil, "params must be a table"
    end
    if not non_empty(opts.protocol) then
        return nil, "protocol is required"
    end
    return {
        protocol = opts.protocol,
        request = {
            grant = opts.grant,
            seq = opts.seq,
            op_type = opts.op_type,
            params = opts.params or {},
        },
    }
end

-- 查询一次操作的持久化结果。只读，不触发执行，也不换 op_id 重试。
-- 无记录时服务端返回 NOT_STARTED / EXPIRED_NOT_EXECUTED，客户端不得自行改键重发。
function M.query(opts)
    opts = opts or {}
    if not non_empty(opts.protocol) then
        return nil, "protocol is required"
    end
    if not non_empty(opts.op_id) then
        return nil, "op_id is required"
    end
    return {
        protocol = opts.protocol,
        request = { op_id = opts.op_id },
    }
end

return M
