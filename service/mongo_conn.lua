local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local mongo = require "skynet.db.mongo"
local log = require "skyext.log"

local g_name, g_index = ...
g_index = tonumber(g_index)
local g_db
local service_name = string.format("mongo_conn:%s:%d", g_name, g_index)

-- log 配置使用 traceback 避免出错打印upvale。
-- upvalue 中包含的请求，会消耗大量的内存
log.config({
    name = service_name,
    traceback = debug.traceback,
})

local CMD = {}

local function init_db(dbname)
    -- 配置由 skyext 的 skynet.init 回调注入，必须在启动回调里读，
    -- 加载期读到的永远是 nil
    local mongo_config = config.get_table("mongo_config")
    local db_config = mongo_config and mongo_config[dbname]
    assert(db_config, "Database not configured: " .. dbname)
    local dbs = mongo.client(db_config.cfg)
    g_db = dbs[dbname]
end

function CMD.find_and_modify(coll, doc)
    local col_obj = g_db[coll]
    return col_obj:findAndModify(doc)
end

function CMD.find(coll, doc, projection)
    local col_obj = g_db[coll]
    local it = col_obj:find(doc, projection)
    local all = {}
    while it:hasNext() do
        local role = it:next()
        all[#all + 1] = role
    end
    return all
end

-- opts = { projection = {...}, sort = {...} | { {k1=1}, {k2=-1} }, skip = n, limit = n }
function CMD.find_many(coll, doc, opts)
    opts = opts or {}
    local col_obj = g_db[coll]
    local it = col_obj:find(doc, opts.projection)
    local sort = opts.sort
    if sort then
        if sort[1] ~= nil then
            -- 数组形式：保证多字段排序的先后顺序
            it:sort(table.unpack(sort))
        else
            it:sort(sort)
        end
    end
    if opts.skip then
        it:skip(opts.skip)
    end
    if opts.limit then
        it:limit(opts.limit)
    end
    local all = {}
    while it:hasNext() do
        all[#all + 1] = it:next()
    end
    return all
end

function CMD.create_index(coll, keys, options)
    local col_obj = g_db[coll]
    if options then
        return col_obj:createIndex(keys, options)
    end
    return col_obj:createIndex(keys)
end

function CMD.find_one(coll, doc, projection)
    local col_obj = g_db[coll]
    local ret = col_obj:findOne(doc, projection)
    -- 逐字段打印会把整份存档（含玩家数据）刷进日志，这里只留一条概要
    log.debug("find_one", "coll", coll, "doc", doc, "projection", projection, "found", ret ~= nil)
    return ret
end

function CMD.raw_safe_insert(coll, bson_str)
    local col_obj = g_db[coll]
    return col_obj:raw_safe_insert(bson_str)
end

function CMD.raw_safe_update(coll, bson_str)
    local col_obj = g_db[coll]
    log.debug("raw_safe_update", "coll", coll, "bson_str", bson_str)
    return col_obj:raw_safe_update(bson_str)
end

function CMD.safe_delete(coll, query, single)
    local col_obj = g_db[coll]
    return col_obj:safe_delete(query, single)
end

-- ---------------------------------------------------------------- 关键写入
--
-- 经济操作不能接受 w=1 的"成功"：主节点写完就 ACK，切主后可能回滚。
-- 这里统一用 majority + journal，并把结果分成三态：
--   CONFIRMED  多数派已确认，可以继续提交
--   REJECTED   明确被拒（writeErrors），业务上确定没写进去
--   UNKNOWN    超时/网络/写关注错误：**可能已经写进去了**，调用方必须按未决处理，
--              不能当成"没写"重试，也不能当成"已提交"
local MAJORITY_WRITE_CONCERN = { w = "majority", j = true }

local function classify_write(r)
    if type(r) ~= "table" then
        return "UNKNOWN", "no reply", r
    end
    if r.writeErrors then
        local first = r.writeErrors[1]
        return "REJECTED", (type(first) == "table" and first.errmsg) or "write error", r
    end
    if r.writeConcernError then
        return "UNKNOWN", r.writeConcernError.errmsg or "write concern error", r
    end
    if r.ok ~= 1 then
        -- 命令级拒绝（参数错、权限不足等）：确定没写，可以按业务失败处理
        return "REJECTED", r.errmsg or "command failed", r
    end
    if r.errmsg then
        -- ok=1 但仍带 errmsg：命令执行过，写入可能已生效，只能按未决处理
        return "UNKNOWN", r.errmsg, r
    end
    return "CONFIRMED", nil, r
end

local function run_command(col_obj, ...)
    return pcall(col_obj.database.runCommand, col_obj.database, ...)
end

function CMD.raw_critical_update(coll, bson_str)
    local col_obj = g_db[coll]
    local called, r =
        run_command(col_obj, "update", col_obj.name, "updates", { bson_str }, "writeConcern", MAJORITY_WRITE_CONCERN)
    if not called then
        return "UNKNOWN", r
    end
    local state, err, detail = classify_write(r)
    if state == "CONFIRMED" then
        return state, { n = detail.n or 0, nModified = detail.nModified or 0 }
    end
    return state, err
end

function CMD.critical_find_and_modify(coll, doc)
    local col_obj = g_db[coll]
    local cmd = { "findAndModify", col_obj.name }
    -- findAndModify 的参数顺序不敏感，但命令名必须在第一位
    for _, key in ipairs({ "query", "sort", "remove", "update", "new", "fields", "upsert" }) do
        if doc[key] ~= nil then
            cmd[#cmd + 1] = key
            cmd[#cmd + 1] = doc[key]
        end
    end
    cmd[#cmd + 1] = "writeConcern"
    cmd[#cmd + 1] = MAJORITY_WRITE_CONCERN
    local called, r = run_command(col_obj, table.unpack(cmd))
    if not called then
        return "UNKNOWN", r
    end
    local state, err, detail = classify_write(r)
    if state == "CONFIRMED" then
        return state, detail
    end
    return state, err
end

function CMD.critical_find(coll, query, projection)
    local col_obj = g_db[coll]
    local called, r = run_command(
        col_obj,
        "find",
        col_obj.name,
        "filter",
        query,
        "projection",
        projection or {},
        "limit",
        1,
        "singleBatch",
        true,
        "readConcern",
        { level = "majority" }
    )
    if not called then
        return nil, r
    end
    if type(r) ~= "table" or r.ok ~= 1 then
        return nil, (type(r) == "table" and r.errmsg) or r or "no reply"
    end
    local batch = r.cursor and r.cursor.firstBatch
    return batch and batch[1] or nil
end

-- 探针：确认这个连接**真的能走 majority 写**。返回 true 或 nil, err
--
-- 为什么不能只发 hello：secondary 也能正常应答 hello，而关键经济操作要的是
-- "多数派确认 + journal 落盘"。一个 hello 通过的连接完全可能在 w:majority 上
-- 超时（副本数不够、journal 不可用、连接其实挂在 secondary 上）。
-- 所以这里做一次真实的写入 → 多数派读回 → 清理。
--
-- 写的是独立集合，**绝不往玩家角色集合里插测试记录**：探针会随运维手动执行，
-- 把垃圾写进 role 集合迟早被当成真实存档读出来。
local PROBE_COLLECTION = "skyext_health_probe"

local function probe_id()
    return string.format("probe:%s:%s:%d:%d", tostring(g_name), tostring(g_index), os.time(), math.random(1, 1000000))
end

function CMD.critical_probe(coll)
    local probe_coll = g_db[PROBE_COLLECTION]
    local id = probe_id()

    local called, r = run_command(
        probe_coll,
        "insert",
        PROBE_COLLECTION,
        "documents",
        { { _id = id, at = os.time() } },
        "writeConcern",
        MAJORITY_WRITE_CONCERN
    )
    if not called then
        return nil, "probe insert raised: " .. tostring(r)
    end
    local state, err = classify_write(r)
    if state ~= "CONFIRMED" then
        -- UNKNOWN 同样不能算健康：探针存在的意义就是不接受"可能写了"
        return nil, string.format("probe majority write not confirmed (%s): %s", state, tostring(err))
    end

    -- 多数派读回：写入确认了但对读不可见，说明读关注没生效
    local doc, read_err = CMD.critical_find(PROBE_COLLECTION, { _id = id }, { _id = true })
    if not doc then
        return nil, "probe document not visible to a majority read: " .. tostring(read_err or "not found")
    end

    -- 清理失败不能让探针报健康：每跑一次留一条垃圾，最终会把告警淹没
    local del_called, del = run_command(
        probe_coll,
        "delete",
        PROBE_COLLECTION,
        "deletes",
        { { q = { _id = id }, limit = 1 } },
        "writeConcern",
        MAJORITY_WRITE_CONCERN
    )
    if not del_called then
        log.error("critical probe cleanup raised", "coll", coll, "id", id, "err", tostring(del))
        return nil, "probe cleanup raised: " .. tostring(del)
    end
    local del_state, del_err = classify_write(del)
    if del_state ~= "CONFIRMED" then
        log.error("critical probe cleanup not confirmed", "coll", coll, "id", id, "state", del_state)
        return nil, string.format("probe cleanup not confirmed (%s): %s", del_state, tostring(del_err))
    end
    return true
end

skynet.start(function()
    init_db(g_name)
    cmd_api.dispatch(CMD)
end)
