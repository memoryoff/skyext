local skynet = require "skynet"
local config = require "skyext.config"
local log = require "skyext.log"
local mongo_conn = require "skyext.mongo_conn"
local orm = require "orm"
local critical_fields = require "skyext.critical_fields"
local SCHEMA_PATH = "game.orm.schema"
local schema = require(SCHEMA_PATH)
local save_wheel = require "skyext.save_wheel"
local queue = require "skynet.queue"

local M = {}

-- 缓存条目的关键状态。普通回存路径只允许 NORMAL：
--   NORMAL                正常，普通回存与关键 CAS 都可以走
--   PREPARING             关键事务进行中：只允许关键 CAS 推进，普通回存必须让路，
--                         否则 PREPARE 之后的一次回存会把普通脏字段抢先写进去，
--                         COMMIT 的 _version 就对不上了
--   CRITICAL_QUARANTINED  关键写入结果未决：内存可能已被 apply 污染，禁止任何回写，
--                         等恢复任务按持久化事实判定后重载
--   DISCARDED             缓存已作废：任何写入都必须拒绝
M.STATE = {
    NORMAL = "NORMAL",
    PREPARING = "PREPARING",
    CRITICAL_QUARANTINED = "CRITICAL_QUARANTINED",
    DISCARDED = "DISCARDED",
}

-- 只有 NORMAL 允许普通回存。其余状态一律拒绝，并且必须给出原因，
-- 让调用方知道这是状态问题而不是网络抖动
local function save_allowed(entry)
    local state = entry.state or M.STATE.NORMAL
    if state == M.STATE.NORMAL then
        return true
    end
    return false, state
end

local g_collection_obj = {} -- 数据库链接
local g_cache_collection = {} -- 缓存数据对象
local g_row_locks = {}
local g_default_projection = { _id = false, _fence = false }
-- 认领 fence 时需要读回 _fence 判断归属，之后再从文档里剔除（schema 中没有这个字段）。
local g_claim_projection = { _id = false }
local FENCE_CLAIM_ATTEMPTS = 3
-- 配置有可能在模块加载之后才注入（dbmgr 会被很早 require 到），
-- 在加载期读取会把 nil / 空表永久缓存下来，因此改成惰性读取 + 缓存
local g_mongo_config
local function mongo_config()
    if not g_mongo_config then
        g_mongo_config = assert(config.get_table("mongo_config"), "mongo_config is not configured")
    end
    return g_mongo_config
end

local g_db_save_interval
local function db_save_interval()
    if not g_db_save_interval then
        g_db_save_interval = config.get_number("db_save_interval") or 3 * 60
    end
    return g_db_save_interval
end

local function check_collection(dbname, dbcoll)
    local db_config = mongo_config()[dbname]
    if db_config == nil then
        error("database not configured" .. dbname)
    end

    local coll_config = db_config.collections[dbcoll]
    if coll_config == nil then
        error("collection not configured" .. dbname .. "." .. dbcoll)
    end
end

local function get_cache_collection(dbname, dbcoll)
    if not g_cache_collection[dbname] then
        g_cache_collection[dbname] = {}
    end
    local colls = g_cache_collection[dbname]
    if not colls[dbcoll] then
        colls[dbcoll] = {}
    end
    return colls[dbcoll]
end

local function get_collection_obj(dbname, dbcoll)
    if not g_collection_obj[dbname] then
        g_collection_obj[dbname] = {}
    end
    local colls = g_collection_obj[dbname]
    if not colls[dbcoll] then
        local coll_obj = mongo_conn.get_collection(dbname, dbcoll)
        colls[dbcoll] = coll_obj
        log.info("new mongo collection", "dbname", dbname, "dbcoll", dbcoll)
    end
    return colls[dbcoll]
end

local function with_row_lock(dbname, dbcoll, unique_id, f)
    g_row_locks[dbname] = g_row_locks[dbname] or {}
    local collection = g_row_locks[dbname]
    collection[dbcoll] = collection[dbcoll] or {}
    local rows = collection[dbcoll]
    local lock = rows[unique_id]
    if not lock then
        lock = { run = queue(), users = 0 }
        rows[unique_id] = lock
    end
    lock.users = lock.users + 1
    local ok, result, err = pcall(lock.run, f)
    lock.users = lock.users - 1
    if lock.users == 0 then
        rows[unique_id] = nil
    end
    if not ok then
        error(result, 0)
    end
    return result, err
end

local function lease_valid(handle)
    return not handle or require("skyext.distributed_lock").is_valid(handle)
end

-- 统一 findAndModify 的失败形态：网络异常、ok ~= 1 都算调用失败。
local function find_and_modify(coll_obj, opts)
    local called, ret = pcall(coll_obj.find_and_modify, coll_obj, opts)
    if not called then
        return nil, ret, "UNKNOWN"
    end
    if type(ret) ~= "table" then
        return nil, ret or "no reply", "UNKNOWN"
    end
    if ret.ok ~= 1 then
        -- 命令级拒绝：确定没写，可以安全重试/判定失败
        return nil, ret.errmsg or "no reply", "REJECTED"
    end
    return ret, nil, "CONFIRMED"
end

-- Skynet Mongo 驱动把 BSON null 解码成单字节字符串 "\0"，
-- 因此只有 table 才算“命中并返回了文档”，其余一律视为没有匹配。
local function matched_value(ret)
    local value = ret and ret.value
    if type(value) == "table" then
        return value
    end
    return nil
end

-- 认领结果读取。关键路径优先用 majority 读，避免看到会被回滚的旧值
local function read_claim_doc(coll_obj, query)
    if coll_obj.critical_find then
        return pcall(coll_obj.critical_find, coll_obj, query, g_claim_projection)
    end
    return pcall(coll_obj.find_one, coll_obj, query, g_claim_projection)
end

-- 认领没匹配时弄清楚原因：文档不存在、已经属于更高的 fence，还是值得再认领一次。
-- 返回 value（文档已归我们）| nil, reason, detail；reason 为 nil 表示该重试，detail 是重试原因
local function resolve_unclaimed(coll_obj, key, unique_id, initial, fence, create)
    if not create then
        local called, existing, read_err = read_claim_doc(coll_obj, { [key] = unique_id })
        if not called then
            return nil, "fence claim failed", existing
        end
        -- majority 读失败不能降级成 "not found"：上层会把它当成"实体不存在"，
        -- 进而把待投可靠消息整批移进死信
        if existing == nil and read_err ~= nil then
            return nil, "fence claim failed", read_err
        end
        if type(existing) ~= "table" then
            return nil, "not found"
        end
        if existing._fence and existing._fence > fence then
            return nil, "fence superseded"
        end
        -- 两次查询之间 fence 又落回了可认领的范围，再试一次
        return nil, nil, "fence changed concurrently"
    end

    local created, create_err = find_and_modify(coll_obj, {
        query = { [key] = unique_id },
        -- 只有 $setOnInsert（initial 里已经带上 _fence），不会改动既有文档。
        update = { ["$setOnInsert"] = initial },
        -- 这一步需要读回 _fence 判断文档归谁，调用方负责在建 ORM 文档前剔除。
        fields = g_claim_projection,
        upsert = true,
        new = true,
    })
    local value = matched_value(created)
    if not value then
        return nil, "fence claim failed", create_err or (created and created.lastErrorObject)
    end
    if value._fence == fence then
        -- 要么是我们刚插入的（插入时就带上了 fence），要么本来就归我们。
        return value
    end
    if value._fence and value._fence > fence then
        return nil, "fence superseded"
    end
    -- 文档刚被别人创建且 fence 更低或缺失：回到上面重新认领。
    return nil, nil, "document created concurrently"
end

-- 原子地“认领 fence + 读取文档”。
--
-- 必须是同一次 findAndModify：先读后认领会留下窗口，旧持有者在窗口内的写入
-- 既不会被 fence 拒绝（此时 _fence 还是旧值），又不会出现在我们已经读到的快照里，
-- 结果是缓存文档落后于数据库，后续所有 _version 乐观锁写入永远失配。
--
-- 带 fence 约束的查询绝不能开 upsert：文档若已被更高 fence 认领，查询不匹配会让
-- upsert 直接插入一条同 key 的重复文档（除非恰好建了唯一索引，而索引是配置可选的）。
-- 所以“不存在就创建”单独走等值查询 + $setOnInsert，既不会改坏既有文档，
-- 也不会插出重复 key。create 为假时文档不存在就返回 "not found"，绝不新建。
-- 关键认领优先走 majority 写关注；老调用方/测试没有这个接口时退回普通 findAndModify，
-- 但必须把"写结果未知"和"确认未匹配"分开，前者不能继续走 resolve_unclaimed。
local function claim_find_and_modify(coll_obj, opts)
    local fn = coll_obj.critical_find_and_modify
    if not fn then
        return find_and_modify(coll_obj, opts)
    end
    local called, state, detail = pcall(fn, coll_obj, opts)
    if not called then
        return nil, state, "UNKNOWN"
    end
    if state == "CONFIRMED" then
        return detail, nil, "CONFIRMED"
    end
    return nil, detail, state
end

local function claim_with_fence(coll_obj, key, unique_id, initial, fence, create)
    local last_err
    for _ = 1, FENCE_CLAIM_ATTEMPTS do
        local ret, err, state = claim_find_and_modify(coll_obj, {
            query = {
                [key] = unique_id,
                ["$or"] = {
                    { _fence = { ["$lte"] = fence } },
                    { _fence = { ["$exists"] = false } },
                },
            },
            -- 只有 $set，没有 $setOnInsert：两个操作符同时写 _fence 会被 mongod 判为路径冲突。
            update = { ["$set"] = { _fence = fence } },
            -- 命中即代表 fence 已归我们，不需要把 _fence 读回来。
            fields = g_default_projection,
            upsert = false,
            new = true,
        })
        if not ret then
            if state == "UNKNOWN" then
                -- 写可能已经生效，只是没拿到 majority 确认。此时既不能当成未认领继续
                -- 走 $setOnInsert（可能插出重复文档），也不能当成已认领返回
                return nil, "fence claim unknown", err
            end
            return nil, "fence claim failed", err
        end
        local claimed = matched_value(ret)
        if claimed then
            return claimed
        end

        local value, reason, detail = resolve_unclaimed(coll_obj, key, unique_id, initial, fence, create)
        if value or reason then
            return value, reason, detail
        end
        last_err = detail
    end
    return nil, "fence claim failed", last_err
end

-- 普通回存。handle 可以覆盖（recover 用新租约写旧缓存），但状态永远取 entry 的：
-- 隔离/准备中的条目不能因为换了个 handle 就恢复写入
local function save_doc(entry, coll_obj, handle)
    local key, unique_id, doc = entry.key, entry.unique_id, entry.doc
    handle = handle or entry.handle
    local allowed, state = save_allowed(entry)
    if not allowed then
        log.warn("refusing save in a non-normal state", "key", key, "unique_id", unique_id, "state", state)
        return false
    end
    if not lease_valid(handle) then
        log.error("refusing save without lease", "key", key, "unique_id", unique_id)
        return false
    end
    if not orm.is_dirty(doc) then
        return true
    end

    local old_version = assert(doc._version, "document has no _version")
    local is_dirty, update, revision = orm.snapshot_mongo(doc)
    if not is_dirty then
        orm.ack_mongo(doc, revision, old_version)
        return true
    end

    local query = { [key] = unique_id, _version = old_version }
    if handle then
        query._fence = handle.fence
    end
    update["$set"] = update["$set"] or {}
    update["$set"]._version = old_version + 1
    local called, ok, err, ret = pcall(coll_obj.safe_update, coll_obj, query, update, false)
    if not called or not ok or type(ret) ~= "table" or ret.n ~= 1 or ret.nModified ~= 1 or ret.upserted then
        log.error("save failed", "query", query, "update", update, "reply", ret, "error", called and err or ok)
        return false
    end

    if not lease_valid(handle) then
        log.error("lease lost during save, retaining dirty state", "query", query)
        return false
    end
    orm.ack_mongo(doc, revision, old_version + 1)
    log.info("save success", "query", query, "version", old_version + 1)
    return true
end

-- 回存轮用的落库入口：等行锁期间文档可能已经被卸载或被新的持有者换掉，
-- 所以拿到锁之后要确认缓存里还是同一个条目，否则这一轮就不该再碰它
local function sweep_save(entry)
    return with_row_lock(entry.dbname, entry.dbcoll, entry.unique_id, function()
        if get_cache_collection(entry.dbname, entry.dbcoll)[entry.unique_id] ~= entry then
            return true
        end
        -- 非 NORMAL 状态不是"回存失败"，是"这一轮不该回存"。返回成功让轮子照常
        -- 排下一轮，否则 PREPARING 期间每一轮都会刷一条 sweep save failed
        if not save_allowed(entry) then
            return true
        end
        local coll_obj = get_collection_obj(entry.dbname, entry.dbcoll)
        return save_doc(entry, coll_obj)
    end)
end

-- 所有缓存文档共用一个回存轮，而不是一个文档挂一个定时器
local g_save_wheel
local function save_wheel_obj()
    if not g_save_wheel then
        g_save_wheel = save_wheel.new("dbmgr", db_save_interval(), function(entry)
            if not sweep_save(entry) then
                log.error(
                    "sweep save failed",
                    "dbname",
                    entry.dbname,
                    "dbcoll",
                    entry.dbcoll,
                    "unique_id",
                    entry.unique_id
                )
            end
        end)
    end
    return g_save_wheel
end

-- 读取文档并放进缓存与回存轮。
-- handle 是分布式锁句柄，带上时用它的 fence 认领文档。
-- opts.create 为真时文档不存在就按 opts.default 新建，否则返回 nil, "not found"：
-- 实体按 ID 寻址，调用方传错一个 ID 不该凭空造出一份文档。
function M.load(dbname, dbcoll, key, unique_id, handle, opts)
    opts = opts or {}
    local create = opts.create == true
    local default = opts.default
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        if not lease_valid(handle) then
            return nil, "lease expired"
        end
        local cache_collection = get_cache_collection(dbname, dbcoll)
        local cached = cache_collection[unique_id]
        if cached then
            -- 关键状态未定的缓存绝不能交回去当可写文档：内存可能已经被 apply 污染，
            -- 交出去只会在下一次回存里把污染状态写进库。DISCARDED 是确定作废，可以直接丢。
            local state = cached.state or M.STATE.NORMAL
            if state == M.STATE.CRITICAL_QUARANTINED then
                return nil, "critical state unknown"
            end
            if state == M.STATE.PREPARING then
                return nil, "critical write in progress"
            end
            if state == M.STATE.DISCARDED then
                save_wheel_obj():remove(cached)
                cache_collection[unique_id] = nil
            elseif cached.handle == handle then
                return cached.doc
            else
                if orm.is_dirty(cached.doc) then
                    return nil, "stale dirty cache requires recovery"
                end
                save_wheel_obj():remove(cached)
                cache_collection[unique_id] = nil
            end
        end

        -- 浅拷贝，避免把 key/_version/_fence 写回调用方传入的 default 表。
        local initial = {}
        for k, v in pairs(orm.to_bson(default or {})) do
            initial[k] = v
        end
        initial[key] = unique_id
        initial._version = 0
        initial._fence = handle and handle.fence or nil

        local coll_obj = get_collection_obj(dbname, dbcoll)
        local value
        if handle then
            if not lease_valid(handle) then
                return nil, "lease expired during load"
            end
            local claimed, reason, detail = claim_with_fence(coll_obj, key, unique_id, initial, handle.fence, create)
            if reason == "not found" then
                return nil, reason
            end
            if not claimed then
                log.error(
                    "fence claim failed",
                    "dbname",
                    dbname,
                    "dbcoll",
                    dbcoll,
                    "key",
                    key,
                    "unique_id",
                    unique_id,
                    "fence",
                    handle.fence,
                    "reason",
                    reason,
                    "detail",
                    detail
                )
                return nil, reason
            end
            -- 认领已经落库；此处即便发现租约失效也不回滚 _fence：
            -- 更低 fence 的旧持有者本来就该被拒绝，后继者的 fence 一定更大。
            if not lease_valid(handle) then
                return nil, "lease expired during fence claim"
            end
            claimed._fence = nil
            value = claimed
        elseif not create then
            local called, ret = pcall(coll_obj.find_one, coll_obj, { [key] = unique_id }, g_default_projection)
            if not called then
                log.error("load failed", "dbname", dbname, "dbcoll", dbcoll, "unique_id", unique_id, "error", ret)
                return nil, "database load failed"
            end
            if type(ret) ~= "table" then
                return nil, "not found"
            end
            value = ret
        else
            local ret, err = find_and_modify(coll_obj, {
                query = { [key] = unique_id },
                update = { ["$setOnInsert"] = initial },
                fields = g_default_projection,
                upsert = true,
                new = true,
            })
            value = matched_value(ret)
            if not value then
                log.error(
                    "load failed",
                    "dbname",
                    dbname,
                    "dbcoll",
                    dbcoll,
                    "key",
                    key,
                    "unique_id",
                    unique_id,
                    "ret",
                    ret,
                    "error",
                    err
                )
                return nil, "database load failed"
            end
        end

        local schema_type = assert(schema[dbcoll], "missing schema for " .. dbcoll)
        -- `orm.decode` 会原地删除 schema 之外的字段。关键元数据必须在它之前提取出来，
        -- 否则未决意图/已提交账本会被当成"旧版本残留"静默丢掉。未知的 _critical_*
        -- 直接拒绝加载：那可能是新版本写的，旧代码没有资格删它。
        local clean, critical, reject = critical_fields.extract(value)
        if not clean then
            log.error(
                "refusing to load a document with unusable critical metadata",
                "dbcoll",
                dbcoll,
                "unique_id",
                unique_id,
                "reason",
                tostring(critical),
                "fields",
                reject and table.concat(reject, ",") or nil
            )
            return nil, "critical metadata rejected"
        end
        local doc, dropped = orm.decode(schema_type, clean)
        if #dropped > 0 then
            -- 库里还留着这些字段，只是这份内存文档不再带它们
            log.warn(
                "document has fields the schema no longer declares",
                "dbcoll",
                dbcoll,
                "unique_id",
                unique_id,
                "fields",
                table.concat(dropped, ",")
            )
        end
        local entry = {
            doc = doc,
            handle = handle,
            dbname = dbname,
            dbcoll = dbcoll,
            key = key,
            unique_id = unique_id,
            -- 关键元数据的权威副本。普通 orm.snapshot_mongo 永远不会写这些路径，
            -- 只有关键 CAS 会读写它们
            critical = critical,
            state = M.STATE.NORMAL,
        }
        cache_collection[unique_id] = entry
        save_wheel_obj():add(entry)
        return doc
    end)
end

-- ===================== 关键写入（P07） =====================
--
-- 关键 CAS 与普通回存是两条独立通道：
--   * 普通回存走 orm.snapshot_mongo + safe_update，w=1；
--   * 关键 CAS 走 critical_update，w=majority+j，只写调用方给的 update，
--     **绝不调用 orm.snapshot_mongo**。PREPARE 阶段如果顺手把普通脏字段写进去，
--     等于把还没提交的资产变化提前落库，COMMIT 失败就再也回不去了。
--
-- 两者共用同一把行锁和同一个 entry，所以 _version 只有一个推进者。

local function get_entry(dbname, dbcoll, unique_id)
    return get_cache_collection(dbname, dbcoll)[unique_id]
end

-- 缓存里的关键元数据副本。**只读**：调用方不得就地修改，
-- 需要更新时走 set_critical（DB 是权威，内存只是跟随）
function M.cached_critical(dbname, dbcoll, unique_id)
    local entry = get_entry(dbname, dbcoll, unique_id)
    return entry and entry.critical or nil
end

-- 只读观测：测试与排障用
function M.state_of(dbname, dbcoll, unique_id)
    local entry = get_entry(dbname, dbcoll, unique_id)
    return entry and (entry.state or M.STATE.NORMAL) or nil
end

-- 进入关键事务：NORMAL -> PREPARING。失败返回 false, reason
function M.begin_critical(dbname, dbcoll, unique_id, handle)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local entry = get_entry(dbname, dbcoll, unique_id)
        if not entry then
            return false, "not cached"
        end
        if handle and entry.handle ~= handle then
            return false, "owner changed"
        end
        local state = entry.state or M.STATE.NORMAL
        if state == M.STATE.PREPARING then
            -- 同 owner 快速续做会重复进入，幂等
            return true
        end
        if state ~= M.STATE.NORMAL then
            return false, state
        end
        entry.state = M.STATE.PREPARING
        return true
    end)
end

-- 关键事务收尾。ok 为真回到 NORMAL，否则进入 CRITICAL_QUARANTINED 并摘除回存轮
function M.end_critical(dbname, dbcoll, unique_id, handle, ok)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local entry = get_entry(dbname, dbcoll, unique_id)
        if not entry then
            return false, "not cached"
        end
        if handle and entry.handle ~= handle then
            return false, "owner changed"
        end
        if ok then
            -- 只允许 PREPARING -> NORMAL。隔离条目已经被摘出回存轮，这里放回 NORMAL
            -- 会得到一个"状态正常但不在轮上"的条目，下一次 M.save 就能把污染内存写回库
            if (entry.state or M.STATE.NORMAL) ~= M.STATE.PREPARING then
                return false, entry.state or M.STATE.NORMAL
            end
            entry.state = M.STATE.NORMAL
            return true
        end
        entry.state = M.STATE.CRITICAL_QUARANTINED
        -- 摘掉回存轮是止血：隔离期间任何写入都必须失败，留在轮上只会每轮刷错误日志
        save_wheel_obj():remove(entry)
        return true
    end)
end

-- 直接隔离（例如 apply 抛错污染了内存，但 COMMIT 从未发出）
function M.quarantine_critical(dbname, dbcoll, unique_id, handle, reason)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local entry = get_entry(dbname, dbcoll, unique_id)
        if not entry then
            return false
        end
        if handle and entry.handle ~= handle then
            return false
        end
        entry.state = M.STATE.CRITICAL_QUARANTINED
        save_wheel_obj():remove(entry)
        log.error(
            "critical cache quarantined",
            "dbname",
            dbname,
            "dbcoll",
            dbcoll,
            "unique_id",
            unique_id,
            "reason",
            reason
        )
        return true
    end)
end

-- 关键 CAS。
-- expected_version 是调用方认为的当前持久化版本，函数内部补齐 key/_version/_fence 三个条件，
-- 调用方只需要给 update（$set / $unset / $inc 等）。
--
-- 返回：
--   "CONFIRMED", { version = 新版本, n = , nModified = }   -- 多数派已确认
--   "REJECTED",  reason                                    -- 确定没写（CAS 未匹配或命令级拒绝）
--   "UNKNOWN",   reason                                    -- 可能已写；entry 已进入隔离
function M.critical_update(dbname, dbcoll, key, unique_id, expected_version, update, opts)
    check_collection(dbname, dbcoll)
    opts = opts or {}
    if math.type(expected_version) ~= "integer" or expected_version < 0 then
        return "REJECTED", "expected_version must be a non-negative integer"
    end
    if type(update) ~= "table" then
        return "REJECTED", "update must be a table"
    end

    return with_row_lock(dbname, dbcoll, unique_id, function()
        local entry = get_entry(dbname, dbcoll, unique_id)
        if not entry then
            return "REJECTED", "not cached"
        end
        if opts.handle and entry.handle ~= opts.handle then
            return "REJECTED", "owner changed"
        end
        local state = entry.state or M.STATE.NORMAL
        if state == M.STATE.CRITICAL_QUARANTINED or state == M.STATE.DISCARDED then
            return "REJECTED", state
        end
        if entry.doc._version ~= expected_version then
            -- 内存版本和调用方的预期已经不一致，再发出去只会是无效 CAS
            return "REJECTED", "version mismatch"
        end

        local next_version = expected_version + 1
        -- 身份与版本必须是框架独占的：只看 $set 会漏掉 $unset/$inc/$rename，
        -- 那些同样能删掉 rid 或改掉 _version
        for op, fields in pairs(update) do
            if type(fields) == "table" then
                if fields[key] ~= nil then
                    return "REJECTED", "update must not rewrite the identity field"
                end
                if fields._fence ~= nil then
                    return "REJECTED", "update must not touch _fence"
                end
                if fields._version ~= nil then
                    if op ~= "$set" then
                        return "REJECTED", "_version is managed by the framework"
                    end
                    if fields._version ~= next_version then
                        return "REJECTED", "_version must advance by exactly one"
                    end
                end
            end
        end

        -- 浅拷贝，避免把注入的 _version 留在调用方的表里：同一张 update 表复用做
        -- 下一步 CAS 时会因为"_version 必须恰好 +1"被拒
        local write = {}
        for op, fields in pairs(update) do
            if type(fields) == "table" then
                local copied = {}
                for k, v in pairs(fields) do
                    copied[k] = v
                end
                write[op] = copied
            else
                write[op] = fields
            end
        end
        write["$set"] = write["$set"] or {}
        write["$set"]._version = next_version

        local query = { [key] = unique_id, _version = expected_version }
        local handle = opts.handle or entry.handle
        if handle then
            -- 锁已经释放（或换了持有者）时不能再发多数派写：fence 条件挡不住
            -- "同一个 fence 但租约已过期"的迟到写，这一层必须在本地拦
            if not lease_valid(handle) then
                return "REJECTED", "lease expired"
            end
            query._fence = handle.fence
        end

        local coll_obj = get_collection_obj(dbname, dbcoll)
        if not coll_obj.critical_update then
            -- 没有多数派写通道就不做关键写：降级成 w=1 等于放弃已提交语义
            return "REJECTED", "majority update unavailable"
        end

        local called, state_or_n, detail = pcall(coll_obj.critical_update, coll_obj, query, write, false)
        if not called then
            entry.state = M.STATE.CRITICAL_QUARANTINED
            save_wheel_obj():remove(entry)
            log.error("critical update raised, quarantining", "unique_id", unique_id, "err", state_or_n)
            return "UNKNOWN", state_or_n
        end
        if state_or_n == "UNKNOWN" then
            entry.state = M.STATE.CRITICAL_QUARANTINED
            save_wheel_obj():remove(entry)
            log.error("critical update unknown, quarantining", "unique_id", unique_id, "reason", detail)
            return "UNKNOWN", detail
        end
        if state_or_n ~= "CONFIRMED" then
            return "REJECTED", detail
        end
        local n = type(detail) == "table" and detail.n or 0
        if n ~= 1 then
            -- nMatched=0：版本或 fence 条件没命中，确定没有应用本次更新
            return "REJECTED", "cas mismatch"
        end

        -- 数据库已经到新版本，内存必须跟上。推进失败说明内存和库已经分叉，
        -- 这时既不能说成功（内存是旧的），也不能说失败（库里已经写了）
        if not orm.advance_persisted_version(entry.doc, expected_version, next_version) then
            entry.state = M.STATE.CRITICAL_QUARANTINED
            save_wheel_obj():remove(entry)
            log.error("critical update applied but memory version diverged", "unique_id", unique_id)
            return "UNKNOWN", "memory version diverged"
        end
        return "CONFIRMED", { version = next_version, n = n, nModified = detail.nModified }
    end)
end

-- 用多数派读拿原始 BSON 后像。恢复任务靠它核对 _fence/_version/_critical_*，
-- 不能用缓存里的内存副本代替
function M.critical_read(dbname, dbcoll, key, unique_id)
    check_collection(dbname, dbcoll)
    local coll_obj = get_collection_obj(dbname, dbcoll)
    local read = coll_obj.critical_find or coll_obj.find_one
    local called, ret, err = pcall(read, coll_obj, { [key] = unique_id }, { _id = false })
    if not called then
        return nil, "read failed", ret
    end
    if type(ret) ~= "table" then
        -- 读失败和"文档不存在"必须分开：恢复任务把读失败当成不存在，就会判定
        -- 未提交并重放，等于二次扣费
        if err ~= nil then
            return nil, "read failed", err
        end
        return nil, "not found"
    end
    return ret
end

-- 用 CAS 确认后的关键元数据替换缓存副本。DB 是权威，这里只是让内存跟上，
-- 所以进程在两步之间崩溃不影响正确性：下次加载会重新 extract
function M.set_critical(dbname, dbcoll, unique_id, critical, handle)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local entry = get_entry(dbname, dbcoll, unique_id)
        if not entry then
            return false
        end
        if handle and entry.handle ~= handle then
            return false
        end
        entry.critical = critical
        return true
    end)
end

function M.save(dbname, dbcoll, key, unique_id)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local cache = get_cache_collection(dbname, dbcoll)[unique_id]
        if not cache then
            return false
        end
        return save_doc(cache, get_collection_obj(dbname, dbcoll))
    end)
end

function M.unload(dbname, dbcoll, key, unique_id)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local cache_collection = get_cache_collection(dbname, dbcoll)
        local cache = cache_collection[unique_id]
        if not cache then
            return false
        end
        local ok = save_doc(cache, get_collection_obj(dbname, dbcoll))
        if not ok or orm.is_dirty(cache.doc) then
            log.error(
                "unload failed, retaining dirty cache",
                "dbname",
                dbname,
                "dbcoll",
                dbcoll,
                "unique_id",
                unique_id
            )
            return false
        end
        save_wheel_obj():remove(cache)
        cache_collection[unique_id] = nil
        return true
    end)
end

function M.discard_clean(dbname, dbcoll, unique_id, handle)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local cache_collection = get_cache_collection(dbname, dbcoll)
        local cache = cache_collection[unique_id]
        if not cache or cache.handle ~= handle or orm.is_dirty(cache.doc) then
            return false
        end
        if (cache.state or M.STATE.NORMAL) ~= M.STATE.NORMAL then
            return false
        end
        save_wheel_obj():remove(cache)
        cache_collection[unique_id] = nil
        return true
    end)
end

-- 租约没了之后把条目从回存轮上摘下来，但保留缓存。
-- 摘掉是为了止血：租约已经失效，save_doc 必然拒绝写入，留在轮上只会让每一轮都刷
-- 一条 "refusing save without lease"。缓存本身不能丢，里面可能还有没落库的改动，
-- 它的去向由 M.recover 决定。
function M.quarantine(dbname, dbcoll, unique_id, handle)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local cache = get_cache_collection(dbname, dbcoll)[unique_id]
        if not cache or cache.handle ~= handle then
            return false
        end
        return save_wheel_obj():remove(cache)
    end)
end

-- 放弃一份再也写不回去的缓存。调用方必须已经确认这些改动不能要了，
-- 并且自己留下了记录——走到这里就是一次确定的数据回退。
function M.discard(dbname, dbcoll, unique_id, handle)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local cache_collection = get_cache_collection(dbname, dbcoll)
        local cache = cache_collection[unique_id]
        if not cache or cache.handle ~= handle then
            return false
        end
        -- 先标 DISCARDED 再摘表：remove 可能失败，留一个明确状态比留一个
        -- "看起来还能用"的条目安全
        cache.state = M.STATE.DISCARDED
        save_wheel_obj():remove(cache)
        cache_collection[unique_id] = nil
        return true
    end)
end

-- 失去租约时内存里还有没落库的改动，拿到新租约后尝试把它接回去。
--
-- 安全性由两道独立的闸门保证：
-- 新 fence 认领把旧持有者挡在门外，而 _version 比较判断失租期间有没有人真的写过
-- 这个文档。只有 _version 没变才说明这份内存改动仍然是库里状态的延续——接管者
-- 可能只是把实体加载起来又原样卸载，什么都没改，那份改动依然作数。_version 变了
-- 就说明改动已经基于一份过时的快照，再写回去就是拿旧数据盖新数据。
--
-- 返回 true 表示改动已落库且缓存已清理；返回 false, "superseded" 表示改动已作废、
-- 缓存已清理，调用方可以安全丢掉实体；其余 false 表示这次没成功，缓存仍然留着，
-- 应该重试。
function M.recover(dbname, dbcoll, key, unique_id, old_handle, new_handle)
    check_collection(dbname, dbcoll)
    assert(new_handle, "recover requires a new lock handle")
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local cache_collection = get_cache_collection(dbname, dbcoll)
        local cache = cache_collection[unique_id]
        if not cache or cache.handle ~= old_handle then
            return false, "cache replaced"
        end
        -- 关键状态未定的缓存不能走"重新拿锁再存一遍"：内存可能已经被 apply 污染，
        -- 存回去就是拿污染状态盖掉库里的事实。这类条目只能由恢复任务判定后重载
        local state = cache.state or M.STATE.NORMAL
        if state ~= M.STATE.NORMAL then
            log.error("refusing to recover a critical cache", "unique_id", unique_id, "state", state)
            return false, state
        end
        local function drop()
            save_wheel_obj():remove(cache)
            cache_collection[unique_id] = nil
        end
        if not orm.is_dirty(cache.doc) then
            drop()
            return true
        end
        if not lease_valid(new_handle) then
            return false, "lease expired"
        end

        local coll_obj = get_collection_obj(dbname, dbcoll)
        local initial = { [key] = unique_id, _version = 0, _fence = new_handle.fence }
        local claimed, reason, detail = claim_with_fence(coll_obj, key, unique_id, initial, new_handle.fence, true)
        if not claimed then
            return false, reason, detail
        end

        local cached_version = cache.doc._version
        if claimed._version ~= cached_version then
            log.error(
                "dirty cache superseded while lease was lost",
                "dbname",
                dbname,
                "dbcoll",
                dbcoll,
                "unique_id",
                unique_id,
                "cached_version",
                cached_version,
                "db_version",
                claimed._version
            )
            drop()
            return false, "superseded"
        end

        -- 只把 new_handle 传给这一次写入，不改 cache.handle：写失败时缓存要原样留着，
        -- 下一轮重试仍然按 old_handle 找得到它。
        if not save_doc(cache, coll_obj, new_handle) then
            return false, "save failed"
        end
        drop()
        log.info("dirty cache recovered", "dbname", dbname, "dbcoll", dbcoll, "unique_id", unique_id)
        return true
    end)
end

local GM_CMD = {}
GM_CMD.reload_orm_schema = {
    desc = "重载 orm schema",
    handler = function()
        -- require 有缓存，必须先清掉才能拿到热更后的新代码
        package.loaded[SCHEMA_PATH] = nil
        local loaded, new_schema = pcall(require, SCHEMA_PATH)
        -- 不论成败都要把原来那张表放回去：整个进程只能有一份 schema 表，
        -- 否则 orm doc 的类型判定会分裂成两套
        package.loaded[SCHEMA_PATH] = schema
        local function abort(err)
            log.error("reload schema failed", "err", err)
            return false, err
        end
        if not loaded then
            return abort(new_schema)
        end
        if new_schema == schema then
            -- loader 返回的还是同一张表（package.preload 之类），
            -- 拿它 reload 等于把 schema 清空，必须拒绝
            return abort("new schema is the same table, reload skipped")
        end
        orm.reload_schema(schema, new_schema)
        log.info("reload schema success", "schema", tostring(schema), "new_schema", tostring(new_schema))
        return true
    end,
}

skynet.init(function()
    local gm_api = require "skyext.gm_api"
    gm_api.register(GM_CMD)
end)

return M
