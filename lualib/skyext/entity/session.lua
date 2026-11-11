-- 实体侧的客户端会话。连接在网关上（service/gate_tcp.lua 或 gate_ws.lua），实体这边只
-- 持有一个连接记录；回包和推送都发给会话所在的网关，同进程走本地消息，否则走 cluster。
--
-- 这里有两个寿命不同的东西，分清楚才能看懂续接：
--
--   entity.session    连接。网络一断就是 nil，会话键 key = conn_id（ConnectionIdentity v1）
--   entity.session_io 会话。从首次登录活到实体卸载，跨连接存活，**它才是「会话」**
--
-- 续接就是把 session_io 挂到一条新连接上。续接窗口因此天然等于实体的 unload_delay，
-- 不需要单独的计时器；实体失租或卸载时 session_io 一起消失，续接自然失败并退化成登录。
-- 设计背景见 docs/archive/session_resume.md。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local crypto = require "crypto"
local config = require "skyext.config"
local connection_id = require "skyext.connection_id"
local downlink = require "skyext.downlink"
local errcode = require "skyext.errcode"
local fingerprint = require "skyext.fingerprint"
local log = require "skyext.log"
local timer = require "skyext.timer"

local M = {}

-- 会话协商后的下行模式，终身锁定，不混发。
-- LEGACY：沿用隐式计数（客户端数收到的包，ping/resume 里对账）
-- V2：每个计数内下行包套 DownlinkV2 信封，客户端按 (session_epoch, seq) 去重
M.MODE_LEGACY = 0
M.MODE_V2 = 1

-- sproto_api 的 NO_CACHE 决定元数据。字符串常量必须与 skyext.sproto_api.NO_CACHE 一致；
-- 这里不 require sproto_api，避免会话层在初始化前拉入协议加载器
local NO_CACHE = "no_cache"

-- 续接凭据长度。必须用 crypto.random_bytes：skynet.crypto.randomkey 是 random() 且只有
-- 8 字节，当会话凭据不合格
local NONCE_BYTES = 16

-- 传输层握手的回包不计入下行计数。它们处在计数边界之外：resume 的响应若计数，客户端会
-- 在收到重放的旧包之前先把计数加一，自校验立刻失配；ping 的响应若计数，"已发出多少包"
-- 这个值就要回答"包括我自己吗"，是现成的差一错误
local UNCOUNTED_RESPONSE = {
    ["login.resume"] = true,
    ["login.ping"] = true,
}

local g_conns = {} -- 会话键 -> 连接记录
local g_entitymgr = nil

local g_self_node
local function self_node()
    if not g_self_node then
        g_self_node = config.get("cluster_node_name")
    end
    return g_self_node
end

local g_conf = {}
local function conf_number(key, default)
    local v = g_conf[key]
    if v == nil then
        v = config.get_number(key) or default
        g_conf[key] = v
    end
    return v
end

-- 会话键就是连接标识本身（ConnectionIdentity v1）：网关生成，实体只解析和比较。
-- 裸 fd 会跨网关重复、关闭后还会被复用，不能当全局身份。
function M.key(conn_id)
    return conn_id
end

-- 解析并校验连接标识。失败返回 nil, err，调用方必须拒绝，不能猜一个 gate 出来
function M.parse_conn(conn_id)
    return connection_id.parse(conn_id)
end

local function gate_send(conn, cmd, ...)
    if conn.gate_node == self_node() then
        skynet.send(conn.gate_service, "lua", cmd, ...)
        return
    end
    local ok, err = pcall(cluster.send, conn.gate_node, conn.gate_service, cmd, ...)
    if not ok then
        log.warn("send to gate failed", "gate", conn.gate_node, "cmd", cmd, "err", err)
    end
end

local function gate_call(gate_node, gate_service, cmd, ...)
    if gate_node == self_node() then
        return skynet.call(gate_service, "lua", cmd, ...)
    end
    return cluster.call(gate_node, gate_service, cmd, ...)
end

local function kick_conn(conn)
    gate_send(conn, "kick", conn.conn_id)
end

-- ---------------------------------------------------------------- 会话状态

local function new_session_io(mode)
    mode = mode or M.MODE_LEGACY
    -- 先取 nonce 再取 epoch：两者都来自同一 CSPRNG，顺序不影响安全性；
    -- 先 nonce 让 bind 的返回值在既有调用方眼里保持不变
    local nonce = crypto.random_bytes(NONCE_BYTES)
    local epoch, err = downlink.epoch_from_bytes(crypto.random_bytes(16))
    if not epoch then
        -- 没有可信随机数就没有会话身份。宁可让登录失败，也不能退化成可预测的 epoch
        error("session epoch unavailable: " .. tostring(err))
    end
    return {
        -- 逻辑会话身份。完整登录/顶号创建新的 session_io 时换新；断线续接和计划内
        -- Role 迁移都保持不变，否则客户端会把同一个会话当成两次登录
        session_epoch = epoch,
        session_mode = mode,
        -- 网关内部的所有权代际。完整登录创建新 session_io 时从 1 开始；断线续接与
        -- 计划内迁移每次换 owner 都 +1。它只影响网关的迟到包过滤，
        -- **不改变 wire 上的 session_epoch 与 seq**
        owner_epoch = 1,
        nonce = nonce,
        -- 下行计数。LEGACY 下 seq 不上线，两端各数各的，只在 resume/ping 对账；
        -- V2 下 seq 写进 DownlinkV2 信封，客户端按 (session_epoch, seq) 去重。
        -- 计数从 session_io 创建时的 0 开始，不随连接重置
        sent = 0,
        acked = 0,
        out_buf = {}, -- seq -> 已编码的包（V2 下是完整 DownlinkV2），覆盖 (acked, sent]
        out_bytes = 0,
        -- 上行幂等。键是客户端的 request id（sproto 包头的 session 字段），
        -- 值是 { pack = 已编码的响应, name = 协议名 }
        resp_cache = {},
        resp_order = { head = 1, tail = 0 },
        resp_bytes = 0,
        min_cached_req_id = 0,
        last_seen = skynet.now(),
        unresumable = false,
        replaying = false,
    }
end

-- 重放缓冲撑爆：丢掉重放能力，但连接本身不动。下次续接时退化成完整登录
local function drop_replay(io_)
    log.warn("replay buffer overflow, session becomes unresumable", "sent", io_.sent, "acked", io_.acked)
    io_.unresumable = true
    io_.out_buf = {}
    io_.out_bytes = 0
    io_.acked = io_.sent
end

local function evict_oldest_response(io_)
    local order = io_.resp_order
    local req_id = order[order.head]
    order[order.head] = nil
    order.head = order.head + 1
    local entry = io_.resp_cache[req_id]
    io_.resp_cache[req_id] = nil
    io_.resp_bytes = io_.resp_bytes - #entry.pack
    -- 淘汰之后这个 id 再来就不能静默重新执行了。对扣费、抽卡来说，"悄悄执行第二遍"
    -- 比"报个错让客户端重走流程"危险得多
    if req_id >= io_.min_cached_req_id then
        io_.min_cached_req_id = req_id + 1
    end
end

local function cache_response(io_, req_id, pack, request_name, request_digest)
    local entry, err = fingerprint.entry_from_digest(request_digest, request_name, pack)
    if not entry then
        -- 没有摘要就不能写缓存：旧格式条目无法在重传时证明参数相同
        log.warn("refuse to cache a response without a fingerprint", "req_id", req_id, "err", err)
        return
    end
    local order = io_.resp_order
    order.tail = order.tail + 1
    order[order.tail] = req_id
    io_.resp_cache[req_id] = entry
    io_.resp_bytes = io_.resp_bytes + #pack

    local max_count = conf_number("session_respcache_count", 64)
    local max_bytes = conf_number("session_respcache_bytes", 16 * 1024)
    while order.tail >= order.head and (order.tail - order.head + 1 > max_count or io_.resp_bytes > max_bytes) do
        evict_oldest_response(io_)
    end
end

-- 下行的唯一收口：计数、入重放缓冲、在线才写网关。任何绕过这里写客户端的路径都会让
-- 两端的计数失同步，重放就会错位
local function record_and_send(entity, pack)
    local io_ = entity.session_io
    if not io_ then
        log.warn("drop a package for an entity without a session", "type", entity.type_name, "id", entity.id)
        return false
    end
    if io_.migrating then
        -- 迁移导出后源端不再追加 out_buf：继续写会让目标拿到一份过期的 sent/out_buf，
        -- 客户端 ACK 一旦超过目标的 sent，整个会话就只能重登
        log.warn("drop a package while the session is migrating", "type", entity.type_name, "id", entity.id)
        return false
    end
    io_.sent = io_.sent + 1
    if io_.session_mode == M.MODE_V2 then
        -- out_buf 里存的是完整的 DownlinkV2 原始字节：迁移时原样重放，不再 decode→换 epoch→
        -- re-encode。seq 就是 io_.sent，不另设计数器
        local wrapped, err = downlink.encode(io_.session_epoch, io_.sent, pack)
        if not wrapped then
            io_.sent = io_.sent - 1
            log.error("downlink encode failed", "type", entity.type_name, "id", entity.id, "err", err)
            return false
        end
        pack = wrapped
    end
    io_.out_buf[io_.sent] = pack
    io_.out_bytes = io_.out_bytes + #pack
    if io_.out_bytes > conf_number("session_replay_bytes", 32 * 1024) then
        drop_replay(io_)
    elseif io_.sent - io_.acked > conf_number("session_replay_packets", 256) then
        drop_replay(io_)
    end

    local conn = entity.session
    if not conn or io_.replaying then
        return false
    end
    gate_send(conn, "push", conn.conn_id, pack, io_.owner_epoch)
    return true
end

-- sproto_api 的发送端：conn 是会话键，request_name 在回包时才有
local function sender(key, pack, request_name)
    local conn = g_conns[key]
    if not conn or conn.entity.session ~= conn then
        log.warn("drop a package for a session that is gone", "session", key)
        return
    end
    if UNCOUNTED_RESPONSE[request_name] then
        local io_ = conn.entity.session_io
        gate_send(conn, "push", conn.conn_id, pack, io_ and io_.owner_epoch)
        return
    end
    record_and_send(conn.entity, pack)
end

-- ------------------------------------------------------------ 绑定与续接

local function cancel_unload(entity)
    if entity.unload_timer then
        entity.unload_timer:cancel()
        entity.unload_timer = nil
    end
end

local function install_conn(conn_id, parsed, entity)
    local conn = {
        key = conn_id,
        conn_id = conn_id,
        gate_node = parsed.gate_node,
        gate_service = parsed.gate_service,
        entity = entity,
    }
    g_conns[conn.key] = conn
    entity.session = conn
    cancel_unload(entity)
    return conn
end

-- 完整登录：把会话绑到实体上，并让网关把之后的包转给 owner_service（本服务的名字）。
-- 网关那边连接已经断开时返回 false，否则返回 true、续接凭据、session_epoch 和模式。
--
-- **无条件重建 session_io**。实体是长寿的，顶号和同账号重登走的是同一个实体对象，
-- 沿用旧的 session_io 会让后来者继承前一个客户端的 nonce（能冒充续接）、下行计数
-- （重放错位）和响应缓存（读到别人的回包）。
--
-- session_mode 在完整登录时协商并终身锁定：只接受 0（LEGACY）/1（V2），
-- 其它值 fail-closed，不能悄悄退回 LEGACY 让客户端以为自己在 V2
function M.bind(conn_id, entity, owner_service, session_mode)
    if session_mode ~= nil and session_mode ~= M.MODE_LEGACY and session_mode ~= M.MODE_V2 then
        log.warn("reject unknown session mode", "mode", tostring(session_mode))
        return false
    end
    local parsed, perr = connection_id.parse(conn_id)
    if not parsed then
        log.warn("reject invalid conn_id", "err", perr)
        return false
    end
    local io_ = new_session_io(session_mode)
    if
        not gate_call(
            parsed.gate_node,
            parsed.gate_service,
            "bind",
            conn_id,
            self_node(),
            owner_service,
            io_.owner_epoch
        )
    then
        return false
    end
    local conn = install_conn(conn_id, parsed, entity)
    entity.session_io = io_
    log.info("session bind", "type", entity.type_name, "id", entity.id, "session", conn.key)
    return true, entity.session_io.nonce, entity.session_io.session_epoch, entity.session_io.session_mode
end

-- 续接：把会话热替换到一条新连接上。只作用于已经在内存里的实体，不查库、不抢锁。
-- 返回 errcode, 轮换后的新凭据, 服务端已发出的包数, session_epoch, session_mode。
--
-- opts（可选）是客户端声明的 { session_mode, session_epoch }：两者都必须与现有会话一致。
-- 客户端拿旧 epoch 续接到另一个逻辑会话时必须失败，否则会把两次登录的包混在一起。
-- 缺省（旧 SDK）按 LEGACY 处理，不校验 epoch。
--
-- 失败一律让客户端退化成完整登录，所以不区分"凭据错"和"状态没了"之外的细节。
function M.resume(conn_id, entity, owner_service, nonce, recv, opts)
    local parsed, perr = connection_id.parse(conn_id)
    if not parsed then
        log.warn("reject invalid conn_id", "err", perr)
        return errcode.PARAM_ERROR
    end
    local io_ = entity.session_io
    if not io_ or io_.unresumable then
        return errcode.RESUME_UNAVAILABLE
    end
    -- 恒定时间比对，且只认当前这一枚：每次 bind / resume 都轮换，用过的立即失效。
    -- 先验 nonce 再看 mode/epoch：未认证的调用方不该能探测会话的协商结果
    if type(nonce) ~= "string" or not crypto.const_equals(nonce, io_.nonce) then
        return errcode.AUTH_FAILED
    end
    if opts then
        if opts.session_mode ~= nil and opts.session_mode ~= io_.session_mode then
            log.warn(
                "resume mode mismatch",
                "id",
                entity.id,
                "mode",
                tostring(opts.session_mode),
                "session_mode",
                io_.session_mode
            )
            return errcode.RESUME_UNAVAILABLE
        end
        if opts.session_epoch ~= nil and opts.session_epoch ~= "" and opts.session_epoch ~= io_.session_epoch then
            log.warn("resume epoch mismatch", "id", entity.id)
            return errcode.RESUME_UNAVAILABLE
        end
    end
    -- 隐式计数不自带校验，在这条低频路径上补一次：客户端报的收包数必须落在 [acked, sent]
    recv = recv or 0
    if recv < io_.acked or recv > io_.sent then
        log.warn("resume recv out of range", "id", entity.id, "recv", recv, "acked", io_.acked, "sent", io_.sent)
        return errcode.RESUME_UNAVAILABLE
    end
    -- 续接是一次所有权切换：owner_epoch 前进一格，网关据此拒绝旧 owner 的迟到下行。
    -- wire 上的 session_epoch 与 seq 都不动，客户端看到的是同一个逻辑会话
    io_.owner_epoch = (io_.owner_epoch or 1) + 1
    if
        not gate_call(
            parsed.gate_node,
            parsed.gate_service,
            "bind",
            conn_id,
            self_node(),
            owner_service,
            io_.owner_epoch
        )
    then
        io_.owner_epoch = io_.owner_epoch - 1
        return errcode.SESSION_CLOSED
    end

    local old = entity.session
    -- 先置标志再换连接：这段窗口里别的协程推的包照常计数入缓冲但不直接写网关，
    -- 等 M.replay 统一按序发出，避免新包抢在重放的旧包前面
    io_.replaying = true
    local conn = install_conn(conn_id, parsed, entity)
    if old and old.key ~= conn.key then
        g_conns[old.key] = nil
        -- 旧连接多半还半开着（切网络不产生 FIN/RST），踢一次回收它。这里不能走
        -- unbind_kick：那条路会引出网关的 session_closed，触发 on_unbind_client，
        -- 业务层就会观察到一次假的下线再上线
        kick_conn(old)
    end

    M.ack(entity, recv)
    io_.nonce = crypto.random_bytes(NONCE_BYTES)
    io_.last_seen = skynet.now()
    log.info("session resume", "type", entity.type_name, "id", entity.id, "session", conn.key, "recv", recv)
    return errcode.OK, io_.nonce, io_.sent, io_.session_epoch, io_.session_mode
end

-- 重放客户端还没收到的下行包，然后解除 replaying。
-- 必须在 on_resume_client 之前调用：回调里业务多半会推状态，那些新包要排在旧包后面，
-- 否则客户端的收包顺序和实际顺序对不上。
-- 和 resume 响应之间没有顺序保证，也无从保证：响应由登录服务发，实体这边不知道它发了没，
-- 跨节点时两者还走两条不同的 TCP 连接。客户端必须能接受任意顺序。
function M.replay(entity)
    local io_ = entity.session_io
    local conn = entity.session
    if not io_ or not conn then
        return false
    end
    local seq = io_.acked
    -- 不用 for：上界要每轮重取，这样重放期间新入缓冲的包天然排在后面一起发出
    while seq < io_.sent do
        seq = seq + 1
        local pack = io_.out_buf[seq]
        if not pack then
            -- 缓冲在重放途中被撑爆了。两端已经无法对齐，踢掉让客户端重新登录
            io_.replaying = false
            log.error("replay gap, kicking the client", "type", entity.type_name, "id", entity.id, "seq", seq)
            kick_conn(conn)
            return false
        end
        gate_send(conn, "push", conn.conn_id, pack)
    end
    io_.replaying = false
    return true
end

-- 客户端确认收到了 recv 个包，裁剪重放缓冲
function M.ack(entity, recv)
    local io_ = entity.session_io
    if not io_ then
        return
    end
    recv = recv or 0
    if recv < io_.acked or recv > io_.sent then
        -- 计数已经失同步，继续重放只会把错位的数据发给客户端
        log.warn("ack out of range", "id", entity.id, "recv", recv, "acked", io_.acked, "sent", io_.sent)
        io_.unresumable = true
        return
    end
    for seq = io_.acked + 1, recv do
        local pack = io_.out_buf[seq]
        if pack then
            io_.out_bytes = io_.out_bytes - #pack
            io_.out_buf[seq] = nil
        end
    end
    io_.acked = recv
end

-- V2 的 ClientAckV2：带 session_epoch 的连续确认。
-- epoch 不匹配时**绝不推进 acked**——旧逻辑会话的 ACK 落到新会话上会裁掉尚未送达的包。
-- 返回是否接受了这次 ACK，调用方（ping）据此回显 acked，客户端发现 epoch 对不上就会重登。
function M.ack_v2(entity, session_epoch, last_contiguous_seq)
    local io_ = entity.session_io
    if not io_ or io_.session_mode ~= M.MODE_V2 then
        return false
    end
    if session_epoch ~= io_.session_epoch then
        log.warn("ack epoch mismatch", "id", entity.id)
        return false
    end
    -- sproto 的 integer 正常是 Lua integer；这里仍做一次无损归一，避免绑定层
    -- 把整数解成整数值浮点时整条 ACK 被静默忽略
    if math.type(last_contiguous_seq) ~= "integer" then
        last_contiguous_seq = math.tointeger(last_contiguous_seq)
        if not last_contiguous_seq then
            return false
        end
    end
    if last_contiguous_seq < io_.acked or last_contiguous_seq > io_.sent then
        log.warn(
            "ack v2 out of range",
            "id",
            entity.id,
            "seq",
            last_contiguous_seq,
            "acked",
            io_.acked,
            "sent",
            io_.sent
        )
        io_.unresumable = true
        return false
    end
    for seq = io_.acked + 1, last_contiguous_seq do
        local pack = io_.out_buf[seq]
        if pack then
            io_.out_bytes = io_.out_bytes - #pack
            io_.out_buf[seq] = nil
        end
    end
    io_.acked = last_contiguous_seq
    return true
end

function M.unbind(key)
    local conn = g_conns[key]
    if not conn then
        return
    end
    g_conns[key] = nil
    local entity = conn.entity
    -- 会话可能已经热替换到新连接上，这时旧连接迟到的 session_closed 不该清掉新连接。
    -- session_io 一律保留，它要活到实体卸载，续接全靠它
    if entity.session == conn then
        entity.session = nil
    end
    if g_entitymgr then
        g_entitymgr:touch(entity.id)
    end
    log.info("session unbind", "type", entity.type_name, "id", entity.id, "session", key)
end

-- 断开客户端连接。解绑交给网关的断开通知（session_closed），这样 on_unbind_client 照常执行
function M.kick(key)
    local conn = g_conns[key]
    if conn then
        kick_conn(conn)
    end
end

-- 只在会话确实属于 expected_entity 时解绑并断开，防止误踢已经换绑的新会话
function M.unbind_kick(key, expected_entity)
    local conn = g_conns[key]
    if not conn or not expected_entity or conn.entity ~= expected_entity then
        return false
    end
    M.unbind(key)
    kick_conn(conn)
    return true
end

-- ---------------------------------------------------------------- 查询与分发

function M.init(entitymgr)
    g_entitymgr = entitymgr
    require("skyext.sproto_api").set_sender(sender)
    timer.repeat_delayed("session_idle_check", conf_number("session_idle_interval", 10), M.sweep_idle)
end

-- 空闲超时：最后一个上行包超过 session_idle_timeout 就断开连接。心跳 15s 一发，默认
-- 60s 判死即连续 4 次未达。被判死的只是连接，session_io 照常留到实体卸载，客户端可以续接
function M.sweep_idle()
    local deadline = skynet.now() - conf_number("session_idle_timeout", 60) * 100
    for key, conn in pairs(g_conns) do
        local io_ = conn.entity.session_io
        if io_ and io_.last_seen < deadline then
            log.info("session idle timeout", "session", key, "id", conn.entity.id)
            kick_conn(conn)
        end
    end
end

function M.get_entity(key)
    local conn = g_conns[key]
    return conn and conn.entity
end

function M.get_obj(key)
    local conn = g_conns[key]
    if not conn or not g_entitymgr or g_entitymgr:get(conn.entity.id) ~= conn.entity then
        return nil
    end
    return { entity = conn.entity }
end

function M.is_online(entity)
    return entity.session ~= nil
end

-- 在会话所绑定实体的串行队列里执行协议处理函数 f，顺带做上行幂等。
-- request_name 只用于核对幂等缓存命中的那一条是不是同一个请求。
-- 返回 true, ...        : f 已经执行（或命中缓存），后面是回包
-- 返回 false, reason, code : 请求被拒绝，f 没有执行
function M.with_request(key, f, req_id, request_name, request_digest)
    local conn = g_conns[key]
    if not conn then
        return false, "client not bound"
    end
    if not g_entitymgr then
        return false, "entity manager not ready"
    end
    local entity = conn.entity
    local io_ = entity.session_io
    if io_ then
        io_.last_seen = skynet.now()
        if req_id then
            local cached = io_.resp_cache[req_id]
            if cached then
                -- 同 req_id 必须同时满足协议名与参数摘要。只看协议名会让"同协议不同参数"
                -- 的重传拿到上一次的结果；续接不重建 session_io，这张缓存还是断线前那张
                local same, why, kind =
                    fingerprint.matches_digest(cached, request_name, request_digest, crypto.const_equals)
                if not same then
                    if kind == fingerprint.KIND.PROTOCOL_MISMATCH or kind == fingerprint.KIND.MISMATCH then
                        log.warn(
                            "request id reused for a different request",
                            "id",
                            entity.id,
                            "req_id",
                            req_id,
                            "cached",
                            cached.name,
                            "got",
                            request_name,
                            "reason",
                            why
                        )
                        return false, "request id reused for a different request", errcode.REQUEST_CONFLICT
                    end
                    if kind == fingerprint.KIND.INTERNAL then
                        -- 比较函数/摘要本身出问题：按内部失败处理，不能伪装成"缓存过期"
                        -- 让客户端重走流程，那可能把同一个操作执行第二遍
                        log.error(
                            "request fingerprint comparison failed",
                            "id",
                            entity.id,
                            "req_id",
                            req_id,
                            "reason",
                            why
                        )
                        return false, "request fingerprint unavailable"
                    end
                    -- 旧格式条目（没有 version/hash）：不能猜测着重放
                    log.warn("cached response is not usable", "id", entity.id, "req_id", req_id, "reason", why)
                    return false, "cached response is not usable", errcode.REQUEST_EXPIRED
                end
                -- 续接之后客户端按原 id 重发的在途请求：回缓存的响应，绝不重新执行
                return true, cached.pack
            end
            if req_id < io_.min_cached_req_id then
                return false, "response for this request id was already evicted", errcode.REQUEST_EXPIRED
            end
        end
    end

    local ok, result = g_entitymgr:with_loaded_entity(entity.id, function(active)
        -- 排队等待期间会话可能已经解绑，或者换绑到别的实体上
        if active ~= entity or g_conns[key] ~= conn then
            return nil
        end
        return table.pack(f())
    end)
    if not ok then
        return false, tostring(result or "entity unavailable")
    end
    if result == nil then
        return false, "client binding revoked"
    end
    -- result[4] 是 sproto_api 的内部缓存处置（CACHEABLE/NO_CACHE）。纯读预检拒绝、
    -- 环境 UNKNOWN 这类瞬时结果不能写 L1，否则客户端重传时会被旧拒绝钉死。
    -- 旧 handler 不返回决定值时是 nil，维持原来的缓存规则
    if io_ and req_id and type(result[1]) == "string" and result[4] ~= NO_CACHE then
        cache_response(io_, req_id, result[1], request_name, request_digest)
    end
    return true, table.unpack(result, 1, result.n)
end

-- 请求被拒绝、且错误码无法通过协议回给客户端时的兜底：断开连接，让客户端立刻失败重连
function M.reject_client(key, reason)
    log.warn("session rejected", "session", key, "reason", reason)
    M.kick(key)
end

-- 给实体自己的客户端推一条消息。返回的是"有没有写到网关"，不在线时包已经进了重放缓冲、
-- 不是丢了；判断在不在线用 M.is_online
function M.push(entity, name, msg)
    if not entity.session_io then
        return false
    end
    return record_and_send(entity, require("skyext.sproto_api").encode_notify(name, msg))
end

-- 传输层协议，和业务协议一样进实体的串行队列，但实现在会话层。
-- 注册名也是 "login"：绑定之后上行包由网关直接转给实体，登录服务再也看不到这条连接，
-- 两份同名注册在不同进程角色里，不会冲突
M.cmds = {}

function M.cmds.ping(request, _, obj)
    local entity = obj.entity
    local io_ = entity.session_io
    if io_ and io_.session_mode == M.MODE_V2 then
        -- V2 的 ACK 走 ping 的扩展字段，而不是另开协议：ping 本来就在计数边界之外，
        -- 心跳频率足够承载连续确认，也避免多一条需要协商的通道
        if request.session_epoch == io_.session_epoch and request.last_contiguous_seq ~= nil then
            M.ack_v2(entity, request.session_epoch, request.last_contiguous_seq)
        end
        return {
            sent = io_.sent,
            acked = io_.acked,
            session_epoch = io_.session_epoch,
        }
    end
    M.ack(entity, request.recv)
    return { sent = io_ and io_.sent or 0 }
end

M.middleware_cbs = {}

return M
