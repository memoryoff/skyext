local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local orm = require "orm"
local skynet = require "skynet"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/dbmgr.lua")

-- 与 generate schema 产出的结构体同形：dbmgr 会把它直接交给 orm.decode，
-- 所以字段必须是真的类型表，fields() 也得能列出来
local function role_schema(extra)
    local self =
        { type = "struct", rid = { type = "integer" }, _version = { type = "integer" }, name = { type = "string" } }
    for k, v in pairs(extra or {}) do
        self[k] = v
    end
    local names = {}
    for k, v in pairs(self) do
        if type(v) == "table" and v.type then
            names[#names + 1] = k
        end
    end
    table.sort(names)
    function self.fields()
        return names
    end
    function self:_parse_k(k)
        assert(self[k], "unknown key: " .. tostring(k))
        return k
    end
    function self:_check_k(k)
        self:_parse_k(k)
    end
    function self:_check_kv(k, value)
        assert(self[k])
        assert(type(value) == (k == "name" and "string" or "number"))
    end
    function self.new(data)
        return orm.new(self, data)
    end
    return self
end

-- 下面是一个极小的 Mongo 行为模型：只支持 dbmgr 真正用到的算子，
-- 但 query/update/upsert/projection 的语义与 mongod 一致，
-- 这样测试才能复现“旧持有者在认领前后写入”的交错。
local function copy(doc)
    local out = {}
    for k, v in pairs(doc) do
        out[k] = v
    end
    return out
end

local function match_doc(doc, query)
    if not doc then
        return false
    end
    for k, v in pairs(query) do
        if k == "$or" then
            local any = false
            for _, sub in ipairs(v) do
                if match_doc(doc, sub) then
                    any = true
                    break
                end
            end
            if not any then
                return false
            end
        elseif type(v) == "table" then
            for op, operand in pairs(v) do
                if op == "$lte" then
                    -- mongod 的类型分组：缺失字段不会匹配数值比较算子
                    if doc[k] == nil or doc[k] > operand then
                        return false
                    end
                elseif op == "$exists" then
                    if (doc[k] ~= nil) ~= operand then
                        return false
                    end
                else
                    error("unsupported query operator: " .. tostring(op))
                end
            end
        elseif doc[k] ~= v then
            return false
        end
    end
    return true
end

local function apply_update(doc, update, inserting)
    for op, fields in pairs(update) do
        if op == "$set" or (op == "$setOnInsert" and inserting) then
            for k, v in pairs(fields) do
                doc[k] = v
            end
        elseif op == "$unset" then
            for k in pairs(fields) do
                doc[k] = nil
            end
        elseif op ~= "$setOnInsert" then
            error("unsupported update operator: " .. tostring(op))
        end
    end
end

local function project(doc, fields)
    local out = {}
    for k, v in pairs(doc) do
        if not fields or fields[k] ~= false then
            out[k] = v
        end
    end
    return out
end

local DEFAULT_ROW = { rid = 7, _version = 0, name = "original" }

-- harness(handle, stored, defer)
--   stored: nil 用默认行；false 表示集合里还没有这条文档；table 则作为初始文档
--   defer:  true 时不自动 load，由用例自己调用
local function harness(handle, stored, defer)
    local h = {
        calls = 0,
        fam = {},
        updates = {},
        critical_updates = {},
        errors = {},
        warnings = {},
        cancelled = false,
        fail = false,
        handle = handle,
        duplicates = 0,
    }
    if stored == nil then
        h.store = copy(DEFAULT_ROW)
    elseif stored then
        h.store = stored
    end

    local collection = {}
    h.collection = collection

    -- 打开 majority 认领路径：state 是 CONFIRMED/REJECTED/UNKNOWN
    function h:enable_critical(state, detail, read_doc)
        h.critical_state, h.critical_detail, h.critical_doc = state, detail, read_doc
        function collection:critical_find_and_modify()
            return h.critical_state, h.critical_detail
        end
        function collection:critical_find(query, fields)
            h.critical_read = { query = query, fields = fields }
            if h.critical_read_error then
                return nil, h.critical_read_error
            end
            return h.critical_doc
        end
    end

    local function run_find_and_modify(opts)
        assert(opts.query, "findAndModify requires query")
        assert(opts.update, "findAndModify requires update")
        if opts.update["$set"] and opts.update["$setOnInsert"] then
            for k in pairs(opts.update["$set"]) do
                assert(opts.update["$setOnInsert"][k] == nil, "conflicting update path: " .. k)
            end
        end
        if h.fam_fail == "exception" then
            error("network failure")
        elseif h.fam_fail then
            return { ok = 0, errmsg = "command failed" }
        end
        if match_doc(h.store, opts.query) then
            local before = copy(h.store)
            apply_update(h.store, opts.update, false)
            return { ok = 1, value = project(opts.new and h.store or before, opts.fields) }
        end
        if not opts.upsert then
            -- 驱动把 BSON null 解码成单字节字符串
            return { ok = 1, value = "\0", lastErrorObject = { n = 0 } }
        end
        if h.store then
            -- 真实 mongod 会插入第二条同 key 文档（没有唯一索引时），
            -- 这里只记账，用例断言实现永远不走到这条路径。
            h.duplicates = h.duplicates + 1
            return { ok = 1, value = "\0", lastErrorObject = { n = 0 } }
        end
        local inserted = {}
        for k, v in pairs(opts.query) do
            if k ~= "$or" and type(v) ~= "table" then
                inserted[k] = v
            end
        end
        apply_update(inserted, opts.update, true)
        h.store = inserted
        return {
            ok = 1,
            value = opts.new and project(inserted, opts.fields) or "\0",
            lastErrorObject = { n = 1, upserted = 1 },
        }
    end

    function collection:find_and_modify(opts)
        h.calls = h.calls + 1
        h.fam[#h.fam + 1] = opts
        if h.on_fam then
            h.on_fam(opts)
        end
        local reply = run_find_and_modify(opts)
        if h.after_fam then
            h.after_fam(opts)
        end
        return reply
    end

    function collection:find_one(query, fields)
        h.finds = (h.finds or 0) + 1
        if h.find_fail then
            error("network failure")
        end
        if match_doc(h.store, query) then
            return project(h.store, fields)
        end
        return nil
    end

    -- 关键 CAS 通道（多数派）。默认按真实语义执行；用例可以用 h.critical_state 强制三态
    function collection:critical_update(query, update, upsert)
        h.critical_updates[#h.critical_updates + 1] = { query = query, update = update, upsert = upsert }
        if h.critical_state then
            return h.critical_state, h.critical_detail
        end
        if not match_doc(h.store, query) then
            return "CONFIRMED", { n = 0, nModified = 0 }
        end
        apply_update(h.store, update, false)
        return "CONFIRMED", { n = 1, nModified = 1 }
    end

    function collection:safe_update(query, update, upsert)
        h.updates[#h.updates + 1] = { query = query, update = update, upsert = upsert }
        if h.on_update then
            h.on_update()
        end
        if h.fail == "exception" then
            error("network failure")
        end
        if h.fail then
            return false, "write failed", { n = 0, nModified = 0 }
        end
        if h.matched == false then
            return true, nil, { n = 0, nModified = 0 }
        end
        if not match_doc(h.store, query) then
            return true, nil, { n = 0, nModified = 0 }
        end
        apply_update(h.store, update, false)
        -- 模拟"主库已经写入、回包在网络里丢了"：更新先落地，之后才抛错/丢结果。
        -- 普通 w=1 回存从返回值上分不出它和"确实没写"，这正是要收敛的场景
        if h.lost_reply == "exception" then
            error("reply lost after commit")
        end
        if h.lost_reply then
            return false, "reply lost", nil
        end
        return true, nil, { n = 1, nModified = 1 }
    end

    -- dbmgr 加载时 require 到的那张 schema 表；reload_orm_schema 的用例会把
    -- imports["game.orm.schema"] 换成新版本，模拟热更后重新 require 的结果
    local schema_mock = { role = role_schema() }
    h.schema = schema_mock

    local imports = {
        skynet = {
            init = function(f)
                f()
            end,
        },
        ["skyext.gm_api"] = {
            register = function(cmds)
                h.gm = cmds
            end,
        },
        ["skyext.config"] = {
            get_table = function()
                return { demo = { collections = { role = {} } } }
            end,
            get_number = function()
                return 10
            end,
        },
        ["skyext.log"] = {
            debug = function() end,
            info = function() end,
            warn = function(msg)
                h.warnings[#h.warnings + 1] = msg
            end,
            error = function(msg)
                h.errors[#h.errors + 1] = msg
            end,
        },
        ["skyext.mongo_conn"] = {
            get_collection = function()
                return collection
            end,
        },
        ["skyext.distributed_lock"] = {
            is_valid = function(lease)
                return lease.valid
            end,
        },
        ["game.orm.schema"] = schema_mock,
        ["skyext.save_wheel"] = {
            new = function(_, period, on_entry)
                h.wheel_period = period
                h.sweep_entry = on_entry
                return {
                    add = function(_, entry)
                        h.entry = entry
                    end,
                    remove = function(_, entry)
                        t.expect(entry).to.equal(h.entry)
                        h.cancelled = true
                        return true
                    end,
                }
            end,
        },
    }
    h.imports = imports
    local env = setmetatable({
        require = function(name)
            if h.require_error and h.require_error[name] then
                error(h.require_error[name])
            end
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.db = assert(loadfile(source, "t", env))()
    if not defer then
        h.doc, h.load_error = h.db.load("demo", "role", "rid", 7, handle, { create = true })
        if not handle or h.doc then
            assert(h.doc, h.load_error)
        end
    end
    -- 模拟回存轮转到这个条目：与真实轮子调用 dbmgr 回调的方式一致
    function h.sweep(entry)
        h.sweep_entry(entry or assert(h.entry, "no entry on the wheel"))
    end

    return h
end

t.describe("dbmgr persistence", function()
    t.it("retains a dirty document and version on write failure", function()
        local h = harness()
        h.doc.name = "updated"
        h.fail = true
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.doc._version).to.equal(0)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        t.expect(h.updates[1].upsert).to.equal(false)
        t.expect(h.updates[1].update["$set"]._version).to.equal(1)
        t.expect(h.db.load("demo", "role", "rid", 7, nil, { create = true })).to.equal(h.doc)
        t.expect(h.calls).to.equal(1)
        h.fail = false
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.doc._version).to.equal(1)
        t.expect(orm.is_dirty(h.doc)).to.equal(false)
        t.expect(h.store.name).to.equal("updated")
        t.expect(h.store._version).to.equal(1)
    end)

    -- 修复前：库里 _version 已经 +1，内存还停在旧版本且 dirty=true，
    -- 之后每一轮 CAS 都 n=0，回存和卸载一起卡死
    t.it("aligns the cached version when a committed save loses its reply", function()
        local h = harness()
        h.doc.name = "updated"
        h.lost_reply = true
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.store.name).to.equal("updated")
        t.expect(h.store._version).to.equal(1)
        t.expect(h.doc._version).to.equal(1)
        t.expect(orm.is_dirty(h.doc)).to.equal(false)
        -- 没有新脏字段时不再重复写库
        h.lost_reply = false
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(#h.updates).to.equal(1)
        -- 后续改动能接着用新版本正常落库
        h.doc.name = "again"
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.doc._version).to.equal(2)
        t.expect(h.store.name).to.equal("again")
    end)

    t.it("does not wedge unload when the DB commits but the ack is lost", function()
        local h = harness()
        h.doc.name = "updated"
        h.lost_reply = "exception"
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.doc._version).to.equal(1)
        t.expect(orm.is_dirty(h.doc)).to.equal(false)
        t.expect(h.store.name).to.equal("updated")
    end)

    t.it("keeps the cache dirty but recoverable when the write result cannot be read back", function()
        local h = harness()
        h.doc.name = "updated"
        h.lost_reply = true
        h.find_fail = true
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.doc._version).to.equal(0)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        -- 读恢复后，下一轮 CAS 命中旧版本会 n=0，再读一次即对齐，不会覆盖已提交的数据
        h.find_fail = false
        h.lost_reply = false
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.doc._version).to.equal(1)
        t.expect(h.store.name).to.equal("updated")
        t.expect(#h.updates).to.equal(2)
    end)

    t.it("discards a cache whose version was superseded instead of retrying the old CAS forever", function()
        local h = harness()
        h.doc.name = "updated"
        h.fail = true
        -- 别的新持有者已经把文档推进了两个版本
        h.store._version = 3
        h.store._fence = 99
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
        -- 作废后任何写入都被拒，不会再拿 _version=0 去撞 CAS
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
        t.expect(#h.updates).to.equal(1)
        -- 缓存作废后 load 会丢掉这份过期副本，重新从库里读
        local fresh = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        t.expect(fresh == h.doc).to.equal(false)
        t.expect(fresh._version).to.equal(3)
        t.expect(fresh.name).to.equal("original")
    end)

    t.it("does not evict cache or cancel retry timer on uncertain or unmatched writes", function()
        local h = harness()
        h.doc.name = "updated"
        h.fail = "exception"
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.cancelled).to.equal(false)
        t.expect(h.db.load("demo", "role", "rid", 7, nil, { create = true })).to.equal(h.doc)
        h.fail = false
        h.matched = false
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(false)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        h.matched = true
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.cancelled).to.equal(true)
    end)

    t.it("claims a fencing token and constrains every subsequent write by fence and version", function()
        local handle = { fence = 13, valid = true }
        local h = harness(handle)
        t.expect(h.calls).to.equal(1)
        local claim = h.fam[1]
        t.expect(claim.query.rid).to.equal(7)
        t.expect(claim.query["$or"][1]._fence["$lte"]).to.equal(13)
        t.expect(claim.query["$or"][2]._fence["$exists"]).to.equal(false)
        t.expect(claim.update["$set"]._fence).to.equal(13)
        t.expect(claim.update["$setOnInsert"]).to.be_nil()
        t.expect(claim.upsert).to.equal(false)
        t.expect(claim.new).to.equal(true)
        t.expect(claim.fields._fence).to.equal(false)
        t.expect(h.store._fence).to.equal(13)
        t.expect(#h.updates).to.equal(0)
        h.doc.name = "saved"
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.updates[1].query._version).to.equal(0)
        t.expect(h.updates[1].query._fence).to.equal(13)
        t.expect(h.updates[1].upsert).to.equal(false)
        h.doc.name = "unsaved"
        handle.valid = false
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.db.discard_clean("demo", "role", 7, handle)).to.equal(false)
        t.expect(#h.updates).to.equal(1)
        t.expect(h.cancelled).to.equal(false)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        local replacement, err = h.db.load("demo", "role", "rid", 7, { fence = 14, valid = true }, { create = true })
        t.expect(replacement).to.be_nil()
        t.expect(err).to.equal("stale dirty cache requires recovery")
    end)

    t.it("loads the document its own claim returned, so a losing holder cannot strand the cache", function()
        -- 旧持有者 fence=5 还在写；新持有者 fence=13 来接管。
        local h = harness(nil, { rid = 7, _version = 0, name = "original", _fence = 5 }, true)
        h.after_fam = function()
            -- 认领返回之后旧持有者才把写入发出去：读与认领若不是同一次操作，
            -- 这条写入就会落在两者之间，缓存文档从此永远追不上数据库。
            h.after_fam = nil
            local _, _, reply = h.collection:safe_update(
                { rid = 7, _version = 0, _fence = 5 },
                { ["$set"] = { name = "old-write", _version = 1 } },
                false
            )
            h.old_reply = reply
        end
        local doc = assert(h.db.load("demo", "role", "rid", 7, { fence = 13, valid = true }, { create = true }))
        -- 认领已经抬高 fence，旧持有者的写入被拒
        t.expect(h.old_reply.n).to.equal(0)
        t.expect(h.store.name).to.equal("original")
        t.expect(h.store._fence).to.equal(13)
        t.expect(doc.name).to.equal("original")
        t.expect(doc._version).to.equal(0)
        -- 缓存与数据库一致，新持有者的写入能生效
        doc.name = "successor"
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.store.name).to.equal("successor")
        t.expect(h.store._version).to.equal(1)
    end)

    t.it("adopts a write that landed before the claim instead of reading a stale snapshot", function()
        local h = harness(nil, { rid = 7, _version = 0, name = "original", _fence = 5 }, true)
        h.on_fam = function()
            h.on_fam = nil
            h.collection:safe_update(
                { rid = 7, _version = 0, _fence = 5 },
                { ["$set"] = { name = "in-flight", _version = 1 } },
                false
            )
        end
        local doc = assert(h.db.load("demo", "role", "rid", 7, { fence = 13, valid = true }, { create = true }))
        t.expect(doc.name).to.equal("in-flight")
        t.expect(doc._version).to.equal(1)
        doc.name = "successor"
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.store._version).to.equal(2)
    end)

    t.it("refuses to claim or duplicate a row already owned by a higher fence", function()
        local h = harness({ fence = 4, valid = true })
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        h.store._fence = 9
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence superseded")
        t.expect(h.duplicates).to.equal(0)
        t.expect(h.store._fence).to.equal(9)
        -- 创建分支只能带 $setOnInsert，不能改动既有文档
        t.expect(h.fam[#h.fam].update["$setOnInsert"]).to.be_type("table")
        t.expect(h.fam[#h.fam].update["$set"]).to.be_nil()
        t.expect(h.fam[#h.fam].query["$or"]).to.be_nil()
        t.expect(h.store.name).to.equal("original")
        -- fence 更高的后继者照常接管
        local successor = assert(h.db.load("demo", "role", "rid", 7, { fence = 11, valid = true }, { create = true }))
        t.expect(successor).to.be_type("table")
        t.expect(h.store._fence).to.equal(11)
    end)

    t.it("rejects an unconfirmed fence claim without caching the document", function()
        local h = harness(nil, nil, true)
        h.fam_fail = true
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = true })
        t.expect(doc).to.be_nil()
        -- ok=0 是命令级拒绝：确定没写，按失败处理
        t.expect(err).to.equal("fence claim failed")
        t.expect(h.store._fence).to.be_nil()
        t.expect(h.entry).to.be_nil()
        h.fam_fail = "exception"
        doc, err = h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence claim unknown")
        h.fam_fail = nil
        local successor = assert(h.db.load("demo", "role", "rid", 7, { fence = 6, valid = true }, { create = true }))
        t.expect(successor).to.be_type("table")
        t.expect(h.store._fence).to.equal(6)
    end)

    t.it("creates a missing row that already carries the claiming fence", function()
        local h = harness(nil, false, true)
        local doc = assert(
            h.db.load(
                "demo",
                "role",
                "rid",
                7,
                { fence = 21, valid = true },
                { create = true, default = { name = "fresh" } }
            )
        )
        t.expect(doc.name).to.equal("fresh")
        t.expect(doc._version).to.equal(0)
        t.expect(h.calls).to.equal(2)
        t.expect(h.duplicates).to.equal(0)
        t.expect(h.store.rid).to.equal(7)
        t.expect(h.store._version).to.equal(0)
        t.expect(h.store._fence).to.equal(21)
        t.expect(h.fam[2].update["$setOnInsert"]._fence).to.equal(21)
        -- _fence 不能泄漏进 ORM 文档（schema 里没有这个字段）
        t.expect(rawget(doc, "_fence")).to.be_nil()
    end)

    t.it("does not stamp a fence onto a row created without a lock handle", function()
        local h = harness(nil, false, true)
        local doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true, default = { name = "fresh" } }))
        t.expect(doc.name).to.equal("fresh")
        t.expect(h.calls).to.equal(1)
        t.expect(h.store._fence).to.be_nil()
        t.expect(h.fam[1].fields._fence).to.equal(false)
    end)

    t.it("does not write the key, version or fence back into the caller's default table", function()
        local h = harness(nil, false, true)
        local default = { name = "fresh" }
        assert(h.db.load("demo", "role", "rid", 7, { fence = 2, valid = true }, { create = true, default = default }))
        t.expect(default.rid).to.be_nil()
        t.expect(default._version).to.be_nil()
        t.expect(default._fence).to.be_nil()
    end)

    t.it("retries the claim when another node creates the row first", function()
        local h = harness(nil, false, true)
        h.after_fam = function()
            if h.calls == 1 then
                h.store = { rid = 7, _version = 0, name = "created-elsewhere" }
            end
        end
        local doc = assert(h.db.load("demo", "role", "rid", 7, { fence = 8, valid = true }, { create = true }))
        t.expect(doc.name).to.equal("created-elsewhere")
        t.expect(h.calls).to.equal(3)
        t.expect(h.duplicates).to.equal(0)
        t.expect(h.store._fence).to.equal(8)
    end)

    t.it("does not cache the document when the lease dies during the claim", function()
        local handle = { fence = 30, valid = true }
        local h = harness(nil, nil, true)
        h.after_fam = function()
            h.after_fam = nil
            handle.valid = false
        end
        local doc, err = h.db.load("demo", "role", "rid", 7, handle, { create = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("lease expired during fence claim")
        t.expect(h.entry).to.be_nil()
        -- fence 已落库且不回滚：旧持有者本就该被拒，后继者的 fence 一定更大
        t.expect(h.store._fence).to.equal(30)
        local successor = assert(h.db.load("demo", "role", "rid", 7, { fence = 31, valid = true }, { create = true }))
        t.expect(successor).to.be_type("table")
        t.expect(h.store._fence).to.equal(31)
    end)

    t.it("refuses to touch the database once the lease is already gone", function()
        local h = harness(nil, nil, true)
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 3, valid = false }, { create = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("lease expired")
        t.expect(h.calls).to.equal(0)
        t.expect(h.store._fence).to.be_nil()
    end)

    t.it("retains a detached snapshot when the lease expires during an acknowledged write", function()
        local handle = { fence = 21, valid = true }
        local h = harness(handle)
        h.doc.name = "snapshot"
        h.on_update = function()
            if #h.updates == 1 then
                handle.valid = false
                h.doc.name = "later"
            end
        end
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.updates[1].update["$set"].name).to.equal("snapshot")
        t.expect(h.doc._version).to.equal(0)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.cancelled).to.equal(false)
    end)

    t.it("serializes two concurrent writes to one row and preserves intervening changes", function()
        local h = harness()
        h.doc.name = "first"
        local running, done = 0, 0
        local results = {}
        h.on_update = function()
            running = running + 1
            t.expect(running).to.equal(1)
            if #h.updates == 1 then
                h.started = true
                skynet.sleep(10)
            end
            running = running - 1
        end
        skynet.fork(function()
            results[1] = h.db.save("demo", "role", "rid", 7)
            done = done + 1
        end)
        for _ = 1, 50 do
            if h.started then
                break
            end
            skynet.sleep(1)
        end
        t.expect(h.started).to.equal(true)
        h.doc.name = "second"
        skynet.fork(function()
            results[2] = h.db.unload("demo", "role", "rid", 7)
            done = done + 1
        end)
        skynet.sleep(2)
        t.expect(#h.updates).to.equal(1)
        for _ = 1, 50 do
            if done == 2 then
                break
            end
            skynet.sleep(1)
        end
        t.expect(done).to.equal(2)
        t.expect(results[1]).to.equal(true)
        t.expect(results[2]).to.equal(true)
        t.expect(h.updates[1].update["$set"].name).to.equal("first")
        t.expect(h.updates[2].query._version).to.equal(1)
        t.expect(h.updates[2].update["$set"].name).to.equal("second")
        t.expect(h.cancelled).to.equal(true)
    end)

    t.it("preserves changes made while a Mongo operation is in flight", function()
        local h = harness()
        h.doc.name = "snapshot"
        h.on_update = function()
            h.doc.name = "later"
        end
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.updates[1].update["$set"].name).to.equal("snapshot")
        t.expect(h.doc._version).to.equal(1)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        h.on_update = nil
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.updates[2].query._version).to.equal(1)
        t.expect(h.updates[2].update["$set"].name).to.equal("later")
    end)
end)

-- 失租恢复：租约断了但内存里还有没落库的改动时，这三个接口决定这份改动的去向。
-- 判定安全的唯一依据是 _version——新 fence 只能挡住旧持有者，挡不住“接管者已经
-- 写过一轮”这件事。
t.describe("dbmgr lease loss recovery", function()
    local function dirty_cache()
        local handle = { fence = 13, valid = true }
        local h = harness(handle)
        h.doc.name = "unsaved"
        handle.valid = false
        return h, handle
    end

    -- 探测缓存是否还在：带着新租约去 load，脏缓存会挡住加载并要求先恢复
    local function dirty_cache_remains(h)
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 31, valid = true }, { create = true })
        return doc == nil and err == "stale dirty cache requires recovery"
    end

    t.it("quarantine 把条目摘下回存轮但保留缓存", function()
        local h, handle = dirty_cache()
        t.expect(h.db.quarantine("demo", "role", 7, handle)).to.equal(true)
        t.expect(h.cancelled).to.equal(true)
        -- 缓存必须还在：里面的改动还没决定去向
        t.expect(dirty_cache_remains(h)).to.equal(true)
    end)

    t.it("quarantine 拒绝对不上 handle 的调用", function()
        local h = dirty_cache()
        t.expect(h.db.quarantine("demo", "role", 7, { fence = 99, valid = true })).to.equal(false)
        t.expect(h.cancelled).to.equal(false)
    end)

    t.it("recover 在文档没被改过时用新租约把改动落库", function()
        local h, old = dirty_cache()
        local new = { fence = 21, valid = true }
        t.expect(h.db.recover("demo", "role", "rid", 7, old, new)).to.equal(true)
        -- 认领抬高 fence，然后在新 fence 下写入
        t.expect(h.store._fence).to.equal(21)
        t.expect(h.store.name).to.equal("unsaved")
        t.expect(h.store._version).to.equal(1)
        -- 缓存已经清掉：同一个 id 再 load 会回数据库重新认领
        local reloaded = assert(h.db.load("demo", "role", "rid", 7, { fence = 22, valid = true }, { create = true }))
        t.expect(reloaded.name).to.equal("unsaved")
        t.expect(h.store._fence).to.equal(22)
    end)

    t.it("recover 对干净缓存直接丢掉，不多写一次库", function()
        local handle = { fence = 13, valid = true }
        local h = harness(handle)
        handle.valid = false
        local writes = #h.updates
        t.expect(h.db.recover("demo", "role", "rid", 7, handle, { fence = 21, valid = true })).to.equal(true)
        t.expect(#h.updates).to.equal(writes)
        t.expect(h.cancelled).to.equal(true)
    end)

    t.it("文档在失租期间被改过时判定 superseded 并丢弃改动", function()
        local h, old = dirty_cache()
        -- 接管者拿着更高的 fence 写了一轮，_version 跟着涨
        h.store._fence = 20
        h.store._version = 5
        h.store.name = "written-by-successor"
        local ok, reason = h.db.recover("demo", "role", "rid", 7, old, { fence = 21, valid = true })
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("superseded")
        -- 绝不能拿旧状态盖掉接管者写的内容
        t.expect(h.store.name).to.equal("written-by-successor")
        t.expect(#h.errors).to.be_gte(1)
        -- 缓存清掉，调用方可以安全地把实体忘掉
        local reloaded = assert(h.db.load("demo", "role", "rid", 7, { fence = 22, valid = true }, { create = true }))
        t.expect(reloaded.name).to.equal("written-by-successor")
    end)

    t.it("新租约本身已经失效时拒绝恢复并保留缓存", function()
        local h, old = dirty_cache()
        local ok, reason = h.db.recover("demo", "role", "rid", 7, old, { fence = 21, valid = false })
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("lease expired")
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        t.expect(dirty_cache_remains(h)).to.equal(true)
    end)

    t.it("落库失败时保留缓存，下一轮仍能按旧 handle 找到它", function()
        local h, old = dirty_cache()
        h.fail = true
        local ok = h.db.recover("demo", "role", "rid", 7, old, { fence = 21, valid = true })
        t.expect(ok).to.equal(false)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        t.expect(dirty_cache_remains(h)).to.equal(true)
        -- 关键：cache.handle 没有被改成新 handle，否则下一轮按 old 就找不到缓存了；
        -- 重试传的仍然是 old，成功说明改动真的落了库
        h.fail = false
        t.expect(h.db.recover("demo", "role", "rid", 7, old, { fence = 22, valid = true })).to.equal(true)
        t.expect(h.store.name).to.equal("unsaved")
    end)

    t.it("缓存已经换人时报 cache replaced，不碰数据库", function()
        local h = dirty_cache()
        local writes = #h.updates
        local ok, reason = h.db.recover(
            "demo",
            "role",
            "rid",
            7,
            { fence = 99, valid = false },
            { fence = 100, valid = true }
        )
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("cache replaced")
        t.expect(#h.updates).to.equal(writes)
    end)

    t.it("discard 强行丢掉写不回去的缓存", function()
        local h, handle = dirty_cache()
        t.expect(h.db.discard("demo", "role", 7, handle)).to.equal(true)
        t.expect(h.cancelled).to.equal(true)
        -- 库里还是旧内容：这是一次确定的数据回退，调用方必须已经记过账
        t.expect(h.store.name).to.equal("original")
        local reloaded = assert(h.db.load("demo", "role", "rid", 7, { fence = 21, valid = true }, { create = true }))
        t.expect(reloaded.name).to.equal("original")
    end)

    t.it("discard 拒绝对不上 handle 的调用", function()
        local h = dirty_cache()
        t.expect(h.db.discard("demo", "role", 7, { fence = 99, valid = true })).to.equal(false)
    end)
end)

t.describe("dbmgr save wheel", function()
    t.it("puts every loaded document on one wheel keyed by the configured interval", function()
        local h = harness()
        t.expect(h.wheel_period).to.equal(10)
        t.expect(h.entry.dbname).to.equal("demo")
        t.expect(h.entry.dbcoll).to.equal("role")
        t.expect(h.entry.key).to.equal("rid")
        t.expect(h.entry.unique_id).to.equal(7)
        t.expect(h.entry.doc).to.equal(h.doc)
    end)

    t.it("writes a dirty document back when the wheel sweeps it", function()
        local h = harness()
        h.sweep()
        -- 干净的文档不该产生任何写入
        t.expect(#h.updates).to.equal(0)
        h.doc.name = "swept"
        h.sweep()
        t.expect(#h.updates).to.equal(1)
        t.expect(h.store.name).to.equal("swept")
        t.expect(h.doc._version).to.equal(1)
        t.expect(#h.errors).to.equal(0)
    end)

    t.it("reports a failed sweep without dropping the document", function()
        local h = harness()
        h.doc.name = "swept"
        h.fail = true
        h.sweep()
        t.expect(h.errors[#h.errors]).to.equal("sweep save failed")
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        t.expect(h.cancelled).to.equal(false)
        h.fail = false
        h.sweep()
        t.expect(h.store.name).to.equal("swept")
    end)

    t.it("ignores a wheel entry the cache has already replaced", function()
        local h = harness()
        local stale = h.entry
        h.doc.name = "updated"
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        local writes = #h.updates

        local doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        -- equal 是深比较，这里要的是“不是同一个条目”
        t.expect(h.entry == stale).to.equal(false)
        doc.name = "again"
        -- 上一轮排队的旧条目不能再碰这一行
        h.sweep(stale)
        t.expect(#h.updates).to.equal(writes)
        t.expect(#h.errors).to.equal(0)

        h.sweep()
        t.expect(#h.updates).to.equal(writes + 1)
        t.expect(h.store.name).to.equal("again")
    end)
end)

t.describe("dbmgr schema drift", function()
    t.it("loads a document carrying fields the schema no longer declares", function()
        -- 删字段不需要任何迁移脚本：旧文档里残留的 nick 丢掉就行，
        -- 否则它会直接撞在 orm 的类型检查上，这一行永远加载不起来
        local h = harness(nil, { rid = 7, _version = 0, name = "legacy", nick = "old" }, true)
        local doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        t.expect(doc.name).to.equal("legacy")
        t.expect(rawget(doc, "nick")).to.be_nil()
        t.expect(#h.warnings).to.equal(1)
        -- 库里那份文档不动：丢字段只是这份内存文档的事
        t.expect(h.store.nick).to.equal("old")
    end)

    t.it("fills a field the document predates without marking it dirty", function()
        -- 加字段同样不需要迁移：补零值，玩法代码不用为"上个版本没有这个字段"分支
        local h = harness(nil, { rid = 7, _version = 0 }, true)
        local doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        t.expect(doc.name).to.equal("")
        t.expect(#h.warnings).to.equal(0)
        -- 补出来的零值不算改动，不该因此产生一次回写
        t.expect(orm.is_dirty(doc)).to.equal(false)
        h.sweep()
        t.expect(#h.updates).to.equal(0)
    end)
end)

t.describe("dbmgr reload_orm_schema", function()
    local SCHEMA_PATH = "game.orm.schema"

    t.it("reloads definitions in place and keeps one canonical schema table", function()
        local h = harness(nil, nil, true)
        local v1_role = h.schema.role
        local v2_role = role_schema({ mail = true })
        local v2_bag = role_schema()
        h.imports[SCHEMA_PATH] = { role = v2_role, bag = v2_bag }

        local ok, err = h.gm.reload_orm_schema.handler()
        t.expect(err).to.be_nil()
        t.expect(ok).to.equal(true)

        -- 原地替换：外面持有的 role 引用不变，内容换成新版本
        t.expect(h.schema.role).to.equal(v1_role)
        t.expect(v1_role.mail).to.equal(true)
        t.expect(v1_role.new).to.equal(v2_role.new)
        -- 新版本里新增的类型不能丢
        t.expect(h.schema.bag).to.equal(v2_bag)
        -- 整个进程只能有一份 schema 表，require 回来还是它
        t.expect(package.loaded[SCHEMA_PATH]).to.equal(h.schema)
    end)

    t.it("refuses to reload when require hands back the very same table", function()
        local h = harness(nil, nil, true)
        local v1_role = h.schema.role
        v1_role.rid = true

        -- 没有替换 imports，热更后 require 拿回来的仍是同一张表。
        -- 这种时候继续 reload 等于把每个 schema 对象清空再自我赋值，
        -- 一次调用就能毁掉整个进程的存档能力，必须拒绝。
        local ok, err = h.gm.reload_orm_schema.handler()
        t.expect(ok).to.equal(false)
        t.expect(err).to.be_type("string")

        t.expect(h.schema.role).to.equal(v1_role)
        t.expect(v1_role.rid).to.equal(true)
        t.expect(package.loaded[SCHEMA_PATH]).to.equal(h.schema)
    end)

    t.it("restores the canonical table when the new schema fails to load", function()
        local h = harness(nil, nil, true)
        local v1_role = h.schema.role
        v1_role.rid = true
        h.require_error = { [SCHEMA_PATH] = "syntax error in schema" }

        local ok, err = h.gm.reload_orm_schema.handler()
        t.expect(ok).to.equal(false)
        t.expect(err).to.be_type("string")

        -- 旧 schema 原样保留，package.loaded 也不能停在 nil 上
        t.expect(h.schema.role).to.equal(v1_role)
        t.expect(v1_role.rid).to.equal(true)
        t.expect(package.loaded[SCHEMA_PATH]).to.equal(h.schema)

        h.require_error = nil
        h.imports[SCHEMA_PATH] = { role = role_schema({ mail = true }) }
        t.expect(h.gm.reload_orm_schema.handler()).to.equal(true)
        t.expect(v1_role.mail).to.equal(true)
    end)

    t.it("reloads a schema that dbmgr is already caching documents for", function()
        local h = harness(nil, nil, false)
        local doc = h.doc
        t.expect(doc).to.be_type("table")

        h.imports[SCHEMA_PATH] = { role = role_schema({ mail = true }) }
        t.expect(h.gm.reload_orm_schema.handler()).to.equal(true)

        -- 已加载的 doc 仍然可写、可落库
        doc.name = "reloaded"
        t.expect(orm.is_dirty(doc)).to.equal(true)
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.store.name).to.equal("reloaded")
    end)
end)

t.describe("dbmgr load without create", function()
    t.it("reports a missing row as not found and never inserts one", function()
        local h = harness(nil, false, true)
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 4, valid = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("not found")
        t.expect(h.store).to.be_nil()
        for _, opts in ipairs(h.fam) do
            t.expect(opts.upsert).to.equal(false)
        end
        t.expect(h.entry).to.be_nil()
        -- 文档不存在是调用方传错 ID，不是数据库故障，不该刷 error
        t.expect(h.errors).to.equal({})
    end)

    t.it("reports a missing row as not found without a lock handle too", function()
        local h = harness(nil, false, true)
        t.expect(table.pack(h.db.load("demo", "role", "rid", 7))).to.equal({ nil, "not found", n = 2 })
        t.expect(h.calls).to.equal(0)
        t.expect(h.store).to.be_nil()
    end)

    t.it("reads an existing row without a lock handle by a plain query", function()
        local h = harness(nil, nil, true)
        local doc = assert(h.db.load("demo", "role", "rid", 7))
        t.expect(doc.name).to.equal("original")
        t.expect(h.calls).to.equal(0)
        t.expect(h.finds).to.equal(1)
    end)

    t.it("claims an existing row under the handle's fence", function()
        local h = harness(nil, nil, true)
        local doc = assert(h.db.load("demo", "role", "rid", 7, { fence = 3, valid = true }))
        t.expect(doc.name).to.equal("original")
        t.expect(h.store._fence).to.equal(3)
        t.expect(h.finds).to.be_nil()
    end)

    t.it("refuses a row already claimed by a higher fence", function()
        local h = harness(nil, { rid = 7, _version = 2, name = "taken", _fence = 9 }, true)
        t.expect(table.pack(h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }))).to.equal({
            nil,
            "fence superseded",
            n = 2,
        })
        t.expect(h.store._fence).to.equal(9)
    end)

    t.it("fails the load when the existence check itself fails", function()
        local h = harness(nil, false, true)
        h.find_fail = true
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 4, valid = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence claim failed")
    end)
end)

-- P06：majority 认领的三态必须严格区分。UNKNOWN 不能当成未匹配继续 $setOnInsert
t.describe("fence claim majority 结果分类", function()
    t.it("returns the document on a confirmed claim", function()
        local h = harness(nil, nil, true)
        h:enable_critical("CONFIRMED", { value = { rid = 7 }, lastErrorObject = { n = 1 } })
        local doc = assert(h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = true }))
        t.expect(doc.rid).to.equal(7)
        t.expect(h.duplicates).to.equal(0)
    end)

    t.it("does not insert a duplicate when the claim result is unknown", function()
        local h = harness(nil, false, true)
        h:enable_critical("UNKNOWN", "write concern timeout")
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence claim unknown")
        t.expect(h.duplicates).to.equal(0)
        t.expect(h.entry).to.be_nil()
    end)

    t.it("treats a rejected claim as a definite failure", function()
        local h = harness(nil, nil, true)
        h:enable_critical("REJECTED", "bad query")
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence claim failed")
    end)

    t.it("does not turn a failed majority read into not-found", function()
        local h = harness(nil, false, true)
        h:enable_critical("CONFIRMED", { value = "\0", lastErrorObject = { n = 0 } }, nil)
        h.critical_read_error = "read timeout"
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = false })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence claim failed")
    end)

    t.it("reads the unclaimed document with majority read when available", function()
        local h = harness(nil, false, true)
        h:enable_critical("CONFIRMED", { value = "\0", lastErrorObject = { n = 0 } }, nil)
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = false })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("not found")
        t.expect(h.critical_read.query).to.equal({ rid = 7 })
    end)
end)

-- P07：关键元数据在 orm.decode 之前提取，普通 ORM 文档看不到它们
t.describe("dbmgr 关键字段提取", function()
    -- 与 critical.param_hash_of 的真实输出一致：32 字节摘要的 64 位 hex
    local OP_HASH = string.rep("ab", 32)
    local OP_ID = "0123456789abcdef0123456789abcdef_0001"

    t.it("keeps reserved metadata out of the ORM document and in the cache entry", function()
        local stored = copy(DEFAULT_ROW)
        stored._critical_intent_v1 = {
            op_id = OP_ID,
            op_type = "shop.buy",
            param_hash = OP_HASH,
            owner_fence = 5,
            prepared_at = 1700000000,
            state = "PREPARED",
        }
        local h = harness(nil, stored, true)
        local doc = assert(h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = false }))
        -- ORM 文档对未知键会直接报错，这里用快照证明它没有把保留字段带进普通保存路径
        t.expect(doc.rid).to.equal(7)
        t.expect(h.entry.critical._critical_intent_v1.op_id).to.equal(OP_ID)
        -- 普通保存不能生成任何 _critical_* 路径
        h.entry.doc.name = "changed"
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        local update = h.updates[#h.updates].update
        t.expect(update["$set"].name).to.equal("changed")
        for key in pairs(update["$set"]) do
            t.expect(key:sub(1, 10) == "_critical_").to.equal(false)
        end
    end)

    t.it("refuses a document carrying an unknown critical field version", function()
        local stored = copy(DEFAULT_ROW)
        stored._critical_intent_v2 = { state = "PREPARED" }
        local h = harness(nil, stored, true)
        local doc, err = h.db.load("demo", "role", "rid", 7, { fence = 5, valid = true }, { create = false })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("critical metadata rejected")
        t.expect(h.entry).to.be_nil()
    end)
end)

-- P07：关键状态机与专用 CAS。
-- 核心不变量：PREPARE 只推进 _version，不写普通脏字段；UNKNOWN 之后内存绝不能再回库
t.describe("dbmgr 关键状态机", function()
    local OP = "_critical_ops_v1.op_a"

    t.it("blocks ordinary saves while a critical transaction is preparing", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.doc.name = "pending change"
        t.expect(h.db.begin_critical("demo", "role", 7)).to.equal(true)
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.PREPARING)

        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
        t.expect(#h.updates).to.equal(0)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)

        t.expect(h.db.end_critical("demo", "role", 7, nil, true)).to.equal(true)
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.updates[1].update["$set"].name).to.equal("pending change")
    end)

    t.it("writes only the critical paths and advances _version on PREPARE", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        -- PREPARE 之前就有普通脏字段：这次 CAS 绝不能把它带上
        h.doc.name = "uncommitted"
        h.db.begin_critical("demo", "role", 7)

        local state, detail = h.db.critical_update("demo", "role", "rid", 7, 0, {
            ["$set"] = { _critical_intent_v1 = { state = "PREPARED", op_id = "op_a" } },
        })
        t.expect(state).to.equal("CONFIRMED")
        t.expect(detail.version).to.equal(1)
        t.expect(h.critical_updates[1].query._version).to.equal(0)
        t.expect(h.critical_updates[1].update["$set"]._version).to.equal(1)
        t.expect(h.critical_updates[1].update["$set"].name).to.be_nil()
        -- 内存版本跟上，但普通脏字段必须还在
        t.expect(h.doc._version).to.equal(1)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        t.expect(h.store.name).to.equal("original")
    end)

    t.it("treats a zero-match CAS as a definite rejection, not an unknown", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        -- 库里版本已经被别人推进
        h.store._version = 3
        local state, reason =
            h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { [OP] = { status = "COMMITTED" } } })
        t.expect(state).to.equal("REJECTED")
        t.expect(reason).to.equal("cas mismatch")
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.NORMAL)
        t.expect(h.doc._version).to.equal(0)
    end)

    t.it("quarantines the cache when the majority write is unknown", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.doc.name = "polluted"
        h.critical_state = "UNKNOWN"
        h.critical_detail = "write concern timeout"

        local state, reason =
            h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { [OP] = { status = "COMMITTED" } } })
        t.expect(state).to.equal("UNKNOWN")
        t.expect(reason).to.equal("write concern timeout")
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.CRITICAL_QUARANTINED)

        -- 隔离之后：普通回存、关键 CAS 都必须拒绝
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { [OP] = { status = "COMMITTED" } } })).to
            .equal("REJECTED")
        -- 但缓存里**没有**未决意图，说明库里从没写过 PREPARE：重载是安全的，
        -- 拿回的是库里的文档（内存里那份被污染的 name 不会写回去）
        local doc, err = h.db.load("demo", "role", "rid", 7, nil, { create = true })
        t.expect(err).to.be_nil()
        t.expect(doc.name).to.equal("original")
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.NORMAL)
    end)

    -- 有未决意图时不能重载：那次 PREPARE 可能已经落库、只是 ACK 丢了，
    -- 必须等恢复任务按持久化事实判定，不能靠"重新读一次"把未决状态抹掉
    t.it("refuses to reload a quarantined cache that still carries an intent", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.db.quarantine_critical("demo", "role", 7, nil, "commit unknown")
        assert(
            h.db.set_critical(
                "demo",
                "role",
                7,
                { ["_critical_intent_v1"] = { op_id = "op_a", state = "PREPARED" } },
                nil
            )
        )

        local doc, err = h.db.load("demo", "role", "rid", 7, nil, { create = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("critical state unknown")
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.CRITICAL_QUARANTINED)
    end)

    -- 隔离是异常态，必须有确定的出口。没有未决意图时内存里的脏数据只属于那次
    -- 失败的操作，卸载丢弃是安全的——否则 unloading 永久置位，角色再也加载不了
    t.it("lets unload discard a quarantined cache that holds no intent", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.doc.name = "polluted"
        h.db.quarantine_critical("demo", "role", 7, nil, "commit unknown")

        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        -- 缓存被丢弃，下一次 load 从库里重读干净文档
        local doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        t.expect(doc.name).to.equal("original")
    end)

    -- 有意图时必须等恢复任务：那次 PREPARE 可能已经落库，只是 ACK 丢了
    t.it("refuses to unload a quarantined cache that still carries an intent", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.db.quarantine_critical("demo", "role", 7, nil, "commit unknown")
        assert(
            h.db.set_critical(
                "demo",
                "role",
                7,
                { ["_critical_intent_v1"] = { op_id = "op_a", state = "PREPARED" } },
                nil
            )
        )

        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.CRITICAL_QUARANTINED)
    end)

    -- 隔离态唯一允许的写是"取消未决意图"：只碰 ops.<op_id> 与 intent，不碰业务字段。
    -- 没有这条通道，恢复任务永远推不动隔离条目
    t.it("allows only the intent-abort shape to write through a quarantined cache", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.db.quarantine_critical("demo", "role", 7, nil, "commit unknown")

        local op_path = "_critical_ops_v1.op_a"
        local abort_update = {
            ["$set"] = { [op_path] = { status = "ABORTED" } },
            ["$unset"] = { _critical_intent_v1 = true },
        }
        -- 业务字段写入必须拒绝，哪怕带了开关
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { gold = 999 } }, {
            allow_quarantined_intent_abort = true,
        })).to
            .equal("REJECTED")
        -- 不带开关时，连意图取消也不许
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, abort_update)).to.equal("REJECTED")
        -- 只准整条 op 记录，不许往里写子字段（会让下次 load 提取失败）
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, {
            ["$set"] = { ["_critical_ops_v1.op_a.nested"] = { status = "ABORTED" } },
            ["$unset"] = { _critical_intent_v1 = true },
        }, { allow_quarantined_intent_abort = true })).to
            .equal("REJECTED")
        -- 正确形状放行
        local state = h.db.critical_update("demo", "role", "rid", 7, 0, abort_update, {
            allow_quarantined_intent_abort = true,
        })
        t.expect(state).to.equal("CONFIRMED")
    end)

    -- 取消意图后不能回 NORMAL（内存可能带着 apply 的痕迹），标 DISCARDED 等卸载丢弃
    t.it("marks a quarantined entry discarded and unloads it without a write", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.doc.name = "polluted"
        h.db.quarantine_critical("demo", "role", 7, nil, "commit unknown")

        t.expect(h.db.mark_discarded("demo", "role", 7, nil)).to.equal(true)
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.DISCARDED)
        local before = #h.critical_updates
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        -- 丢弃不等于回写：一次 Mongo 写都不该发出
        t.expect(#h.critical_updates).to.equal(before)
    end)

    t.it("does not let a dirty-cache recovery write a quarantined document back", function()
        local old_handle = { fence = 1, valid = true }
        local new_handle = { fence = 2, valid = true }
        local h = harness(old_handle, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, old_handle, { create = true }))
        h.doc.name = "polluted"
        h.db.quarantine_critical("demo", "role", 7, old_handle, "apply raised")

        local ok, reason = h.db.recover("demo", "role", "rid", 7, old_handle, new_handle)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal(h.db.STATE.CRITICAL_QUARANTINED)
        t.expect(#h.updates).to.equal(0)
        -- 缓存必须留着，等恢复任务判定，不能被丢掉也不能被写回
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.CRITICAL_QUARANTINED)
    end)

    t.it("refuses updates that would rewrite identity, fence or skip a version", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))

        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { rid = 8 } })).to.equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { _fence = 9 } })).to.equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { _version = 5 } })).to
            .equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 2, { ["$set"] = {} })).to.equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 1.5, { ["$set"] = {} })).to.equal("REJECTED")
        t.expect(#h.critical_updates).to.equal(0)
        t.expect(h.doc._version).to.equal(0)
    end)

    t.it("refuses parent/child and duplicate update paths before sending the CAS", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))

        -- 合并 ORM 增量与 _critical_* 字段时，父子路径会让 Mongo 整条拒绝 CAS；
        -- 那已经是发出去的写入，调用方只能误判成 UNKNOWN 并隔离玩家资产
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, {
            ["$set"] = {
                ["_critical_ops_v1"] = {},
                ["_critical_ops_v1.op1"] = { status = "COMMITTED" },
            },
        })).to
            .equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, {
            ["$set"] = { gold = 1 },
            ["$unset"] = { gold = true },
        })).to
            .equal("REJECTED")
        t.expect(#h.critical_updates).to.equal(0)
        t.expect(h.doc._version).to.equal(0)
    end)

    t.it("fails closed when the collection has no majority channel", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.collection.critical_update = nil
        local state, reason = h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { [OP] = {} } })
        t.expect(state).to.equal("REJECTED")
        t.expect(reason).to.equal("majority update unavailable")
    end)

    t.it("quarantines when the database moved but memory could not follow", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        -- 模拟内存版本在 CAS 期间被别的路径改掉：数据库写成功了，内存却对不上
        local real = h.collection.critical_update
        h.collection.critical_update = function(self, query, update, upsert)
            h.doc._version = 99
            return real(self, query, update, upsert)
        end
        local state, reason = h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { [OP] = {} } })
        t.expect(state).to.equal("UNKNOWN")
        t.expect(reason).to.equal("memory version diverged")
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.CRITICAL_QUARANTINED)
    end)

    t.it("reads the raw document for reconciliation instead of the memory copy", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.store._version = 4
        h.store._fence = 11
        -- 走多数派读通道，不是普通 find_one
        local read_via
        function h.collection:critical_find(query, fields)
            read_via = { query = query, fields = fields }
            return copy(h.store)
        end
        local raw = assert(h.db.critical_read("demo", "role", "rid", 7))
        t.expect(raw._version).to.equal(4)
        t.expect(raw._fence).to.equal(11)
        t.expect(read_via.query).to.equal({ rid = 7 })
        t.expect(h.doc._version).to.equal(0)
    end)

    -- 读失败被当成"文档不存在"，恢复任务就会判定未提交并重放，等于二次扣费
    t.it("does not report a failed majority read as not found", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        function h.collection:critical_find()
            return nil, "read timeout"
        end
        local raw, reason, err = h.db.critical_read("demo", "role", "rid", 7)
        t.expect(raw).to.be_nil()
        t.expect(reason).to.equal("read failed")
        t.expect(err).to.equal("read timeout")
    end)

    t.it("refuses to revive a quarantined entry through end_critical", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.db.quarantine_critical("demo", "role", 7, nil, "apply raised")
        local ok, state = h.db.end_critical("demo", "role", 7, nil, true)
        t.expect(ok).to.equal(false)
        t.expect(state).to.equal(h.db.STATE.CRITICAL_QUARANTINED)
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
    end)

    -- 身份、fence、版本都是框架独占的：$set/$unset 两条通道都要拦
    t.it("rejects identity, fence and version writes on every allowed operator", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { rid = 8 } })).to.equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$unset"] = { rid = true } })).to
            .equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$unset"] = { _version = true } })).to
            .equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$unset"] = { _fence = true } })).to
            .equal("REJECTED")
        t.expect(#h.critical_updates).to.equal(0)
    end)

    -- $rename 的 key 是**源路径**、value 才是目标路径。只查 key 时
    -- {["$rename"] = { gold = "rid" }} 能通过校验并把身份字段改成 gold 的值
    t.it("refuses $rename before it can retarget the identity, fence or version", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.store.gold = 500
        local before = copy(h.store)

        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$rename"] = { gold = "rid" } })).to
            .equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$rename"] = { gold = "_fence" } })).to
            .equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$rename"] = { _fence = "old_fence" } })).to
            .equal("REJECTED")
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$rename"] = { gold = "_version" } })).to
            .equal("REJECTED")

        -- 一次都不能发出去：发出去之后只有 UNKNOWN 一条路，玩家资产只能隔离
        t.expect(#h.critical_updates).to.equal(0)
        t.expect(h.doc._version).to.equal(0)
        t.expect(h.store).to.equal(before)
    end)

    -- 白名单之外的操作符一律拒绝。$inc/$currentDate 会让库里的值偏离内存副本，
    -- 而关键 CAS 之后内存仍是普通字段的权威副本
    t.it("refuses update operators outside the whitelist", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))

        local state, reason, code = h.db.critical_update("demo", "role", "rid", 7, 0, { ["$inc"] = { gold = 1 } })
        t.expect(state).to.equal("REJECTED")
        t.expect(reason).to.equal('unsupported update operator: "$inc"')
        t.expect(code).to.equal(h.db.REASON.INVALID_UPDATE)
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$currentDate"] = { at = true } })).to
            .equal("REJECTED")
        -- 非表载荷会让后面的 write["$set"]._version 索引到字符串上（Lua 错误，不是拒绝）
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = "not a table" })).to.equal("REJECTED")
        t.expect(#h.critical_updates).to.equal(0)
        t.expect(h.doc._version).to.equal(0)
    end)

    -- extra_query 只能追加等值条件。`$where` 的值是字符串，能绕过"不许 table"的类型检查
    t.it("refuses extra_query operators so the CAS stays an equality match", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))

        local state, reason, code = h.db.critical_update(
            "demo",
            "role",
            "rid",
            7,
            0,
            { ["$set"] = { gold = 1 } },
            { extra_query = { ["$where"] = "this.rid == 7" } }
        )
        t.expect(state).to.equal("REJECTED")
        t.expect(reason).to.equal("extra_query must not use query operators")
        t.expect(code).to.equal(h.db.REASON.INVALID_UPDATE)
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { gold = 1 } }, {
            extra_query = { _version = 99 },
        })).to
            .equal("REJECTED")
        t.expect(#h.critical_updates).to.equal(0)

        -- 普通等值条件仍然可用（Outbox 依赖它做"该事件仍是 PENDING"）
        t.expect(h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { gold = 1 } }, {
            extra_query = { name = "original" },
        })).to
            .equal("CONFIRMED")
        t.expect(h.critical_updates[1].query.name).to.equal("original")
    end)

    -- 同一张 update 表复用做下一步 CAS 时，注入的 _version 不能留在调用方表里
    t.it("does not mutate the caller's update table", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        local update = { ["$set"] = { [OP] = { status = "PREPARED" } } }
        t.expect((h.db.critical_update("demo", "role", "rid", 7, 0, update))).to.equal("CONFIRMED")
        t.expect(update["$set"]._version).to.be_nil()
        t.expect(update["$set"][OP].status).to.equal("PREPARED")
        -- 复用同一张表推进到下一版本
        t.expect((h.db.critical_update("demo", "role", "rid", 7, 1, update))).to.equal("CONFIRMED")
        t.expect(h.doc._version).to.equal(2)
    end)

    t.it("refuses a majority write once the lease is gone", function()
        local handle = { fence = 3, valid = true }
        local h = harness(handle, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, handle, { create = true }))
        handle.valid = false
        local state, reason = h.db.critical_update("demo", "role", "rid", 7, 0, { ["$set"] = { [OP] = {} } })
        t.expect(state).to.equal("REJECTED")
        t.expect(reason).to.equal("lease expired")
        t.expect(#h.critical_updates).to.equal(0)
    end)

    -- PREPARING 期间回存轮不该报"回存失败"：这一轮本来就不该回存
    t.it("skips the save wheel quietly while preparing", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.doc.name = "uncommitted"
        h.db.begin_critical("demo", "role", 7)
        h.errors = {}
        -- 回存轮的回调本身不返回值，这里看的是它有没有记错误
        h.sweep()
        t.expect(#h.errors).to.equal(0)
        t.expect(#h.updates).to.equal(0)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
    end)
end)

-- P13：Outbox 状态 CAS 是元数据写，不能和资产提交的 UNKNOWN 混为一类
t.describe("dbmgr 元数据 CAS 与版本对齐", function()
    local OUTBOX = { ["$set"] = { ["_critical_outbox_v1.evt"] = { status = "ENQUEUED" } } }

    t.it("does not quarantine the cache for a metadata-only unknown", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h:enable_critical("UNKNOWN", "write concern timeout")

        local state, reason = h.db.critical_update("demo", "role", "rid", 7, 0, OUTBOX, { metadata_only = true })
        t.expect(state).to.equal("UNKNOWN")
        t.expect(reason).to.equal("write concern timeout")
        -- 玩家资产操作不能被一次写关注超时锁死
        t.expect(h.db.state_of("demo", "role", 7)).to.equal(h.db.STATE.NORMAL)
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
    end)

    t.it("aligns the memory version and critical fields with the majority read", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h:enable_critical(nil, nil, {
            rid = 7,
            _version = 3,
            name = "original",
            _critical_outbox_v1 = { evt = { status = "ENQUEUED" } },
            _critical_outbox_pending_count = 0,
        })

        local ok, version = h.db.refresh_critical("demo", "role", "rid", 7)
        t.expect(ok).to.equal(true)
        t.expect(version).to.equal(3)
        t.expect(h.doc._version).to.equal(3)
        t.expect(h.db.cached_critical("demo", "role", 7)._critical_outbox_pending_count).to.equal(0)
    end)

    -- 读到旧副本时绝不能把内存版本退回去：那会让下一次 CAS 永远打不中
    t.it("refuses a read that is older than the cached version", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.doc._version = 2
        h:enable_critical(nil, nil, { rid = 7, _version = 1, name = "original" })

        local ok, reason = h.db.refresh_critical("demo", "role", "rid", 7)
        t.expect(ok).to.be_nil()
        t.expect(reason).to.equal("stale read")
        t.expect(h.doc._version).to.equal(2)
    end)

    t.it("reports a read failure instead of pretending the document is gone", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h:enable_critical(nil, nil, nil)
        h.critical_read_error = "socket closed"

        local ok, reason = h.db.refresh_critical("demo", "role", "rid", 7)
        t.expect(ok).to.be_nil()
        t.expect(reason).to.equal("read failed")
    end)

    -- extract 失败时第二个返回值是**错误字符串**。只判 truthy 会把它存进
    -- entry.critical，下一次 PREPARE 写意图时对字符串索引直接抛错，
    -- 缓存永久停在 PREPARING（load 只会回 "critical write in progress"）
    t.it("never caches an extract error as the critical table", function()
        local h = harness(nil, nil, true)
        h.doc = assert(h.db.load("demo", "role", "rid", 7, nil, { create = true }))
        h.store._critical_evil_v9 = { x = 1 }

        local ok, reason = h.db.refresh_critical("demo", "role", "rid", 7)
        t.expect(ok).to.be_nil()
        t.expect(reason).to.match("extract failed")
        local cached = h.db.cached_critical("demo", "role", 7)
        t.expect(type(cached)).to.equal("table")
        t.expect(cached._critical_evil_v9).to.be_nil()
    end)
end)
