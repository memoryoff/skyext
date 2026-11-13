local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/mongo_conn.lua")

-- 这是连接服务那一半：它直接持有 mongo 驱动的 collection 对象。
-- 客户端那一半（lualib/skyext/mongo_conn.lua）另有测试，这里只验
-- "CMD 怎么把参数翻译成驱动调用" 和 "游标怎么被读干净"。
local function harness(opts)
    opts = opts or {}
    local h = {
        mongo_config = opts.mongo_config,
        name = opts.name or "game",
        index = opts.index or "1",
        clients = {},
        logs = {},
        config_reads = 0,
        cursors = {},
        docs = {}, -- find 游标要吐出来的文档
    }

    -- 游标只提供 mongo 驱动真正用到的那几个方法，多余的方法被调到就会报错，
    -- 这样 CMD 里多发一次 sort/skip 之类的调用不会悄悄溜过去
    local function new_cursor()
        local cursor = { calls = {}, pos = 0 }
        function cursor:sort(...)
            self.calls[#self.calls + 1] = { "sort", table.pack(...) }
            return self
        end
        function cursor:skip(n)
            self.calls[#self.calls + 1] = { "skip", table.pack(n) }
            return self
        end
        function cursor:limit(n)
            self.calls[#self.calls + 1] = { "limit", table.pack(n) }
            return self
        end
        function cursor:hasNext()
            return self.pos < #h.docs
        end
        function cursor:next()
            self.pos = self.pos + 1
            return h.docs[self.pos]
        end
        h.cursors[#h.cursors + 1] = cursor
        return cursor
    end

    local function new_collection(coll_name)
        return {
            -- 真实驱动对象带 name，关键写入的 runCommand 会用它拼集合名
            name = coll_name,
            find = function(_, doc, projection)
                h.last = { op = "find", coll = coll_name, doc = doc, projection = projection }
                return new_cursor()
            end,
            findOne = function(_, doc, projection)
                h.last = { op = "findOne", coll = coll_name, doc = doc, projection = projection }
                return h.found
            end,
            findAndModify = function(_, doc)
                h.last = { op = "findAndModify", coll = coll_name, doc = doc }
                return "fam"
            end,
            createIndex = function(_, keys, options)
                h.last = { op = "createIndex", coll = coll_name, keys = keys, options = options }
                return "idx"
            end,
            raw_safe_insert = function(_, bson_str)
                h.last = { op = "raw_safe_insert", coll = coll_name, bson = bson_str }
                return "inserted"
            end,
            raw_safe_update = function(_, bson_str)
                h.last = { op = "raw_safe_update", coll = coll_name, bson = bson_str }
                return "updated"
            end,
            -- majority 关键写入走 runCommand
            database = {
                runCommand = function(_, ...)
                    local args = table.pack(...)
                    h.last = { op = "runCommand", coll = coll_name, args = args }
                    h.commands = h.commands or {}
                    h.commands[#h.commands + 1] = { coll = coll_name, args = args }
                    if h.run_command_error then
                        error(h.run_command_error)
                    end
                    -- 按命令名分别回包：探针一轮里要 insert / find / delete 三种结果
                    local by_cmd = h.run_command_results
                    if by_cmd and by_cmd[args[1]] ~= nil then
                        return by_cmd[args[1]]
                    end
                    return h.run_command_result
                end,
            },
        }
    end

    local fake_mongo = {
        client = function(cfg)
            h.clients[#h.clients + 1] = cfg
            return setmetatable({}, {
                __index = function(_, dbname)
                    h.opened_db = dbname
                    return setmetatable({}, {
                        __index = function(_, coll_name)
                            return new_collection(coll_name)
                        end,
                    })
                end,
            })
        end,
    }

    local function record(level)
        return function(msg, ...)
            h.logs[#h.logs + 1] = { level = level, msg = msg, args = table.pack(...) }
        end
    end

    local imports = {
        skynet = {
            start = function(fn)
                h.start = fn
            end,
        },
        ["skynet.db.mongo"] = fake_mongo,
        ["skyext.config"] = {
            get_table = function(key)
                h.config_reads = h.config_reads + 1
                if key == "mongo_config" then
                    return h.mongo_config
                end
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(CMD)
                h.CMD = CMD
            end,
        },
        ["skyext.log"] = {
            config = function(cfg)
                h.log_config = cfg
            end,
            debug = record("debug"),
            info = record("info"),
            warn = record("warn"),
            error = record("error"),
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))(h.name, h.index)
    assert(h.start, "mongo_conn did not register a start callback")
    return h
end

-- 跑完启动回调，拿到装好的 CMD
local function started(opts)
    opts = opts or {}
    opts.mongo_config = opts.mongo_config or { game = { cfg = { host = "127.0.0.1" } } }
    local h = harness(opts)
    h.start()
    assert(h.CMD, "mongo_conn did not dispatch CMD")
    return h
end

-- 某个值是否出现在日志里（按引用比，用来验存档没被整份刷进日志）
local function logged(h, value)
    for _, entry in ipairs(h.logs) do
        if entry.msg == value then
            return true
        end
        for i = 1, entry.args.n do
            if entry.args[i] == value then
                return true
            end
        end
    end
    return false
end

t.describe("mongo_conn 服务启动", function()
    t.it("日志名由库名和连接序号拼成，序号按数字格式化", function()
        -- 启动参数从 skynet 命令行过来全是字符串，少了 tonumber 这一步
        -- "%d" 会直接把启动炸掉
        local h = harness({ index = "3" })
        t.expect(h.log_config.name).to.equal("mongo_conn:game:3")
    end)

    t.it("日志带 traceback，避免把请求 upvalue 一起打出来", function()
        local h = harness({})
        t.expect(h.log_config.traceback).to.be_type("function")
    end)

    t.it("加载 chunk 时不读配置，只有启动回调里才读", function()
        local h = harness({ mongo_config = { game = { cfg = {} } } })
        t.expect(h.config_reads).to.equal(0)
        h.start()
        t.expect(h.config_reads).to.equal(1)
    end)

    t.it("连上的是自己负责的那个库，用的是该库自己的 cfg", function()
        local h = started({ mongo_config = { game = { cfg = { host = "db1" } } } })
        t.expect(h.clients).to.equal({ { host = "db1" } })
        t.expect(h.opened_db).to.equal("game")
    end)

    t.it("库没配时启动直接失败并报出库名", function()
        -- 带着 nil 的 g_db 起来，后面每一条请求都会以 index nil 崩掉，
        -- 必须在启动期就炸
        local h = harness({ name = "nosuch", mongo_config = { game = { cfg = {} } } })
        t.expect(function()
            h.start()
        end).to
            .throw("Database not configured: nosuch")
    end)
end)

t.describe("mongo_conn find 游标", function()
    t.it("find 把游标读干净后一次性返回", function()
        local h = started()
        h.docs = { { rid = 1 }, { rid = 2 }, { rid = 3 } }
        local all = h.CMD.find("role", { lv = 10 }, { rid = 1 })
        t.expect(all).to.equal({ { rid = 1 }, { rid = 2 }, { rid = 3 } })
        t.expect(h.last.coll).to.equal("role")
        t.expect(h.last.doc).to.equal({ lv = 10 })
        t.expect(h.last.projection).to.equal({ rid = 1 })
    end)

    t.it("没有命中时返回空表而不是 nil", function()
        local h = started()
        h.docs = {}
        -- 调用方普遍直接 ipairs 结果，返回 nil 会让它们全部崩
        t.expect(h.CMD.find("role", {})).to.equal({})
    end)
end)

t.describe("mongo_conn find_many 选项", function()
    t.it("不传 opts 时不对游标做任何额外设置", function()
        local h = started()
        h.docs = { { rid = 1 } }
        local all = h.CMD.find_many("role", { lv = 1 })
        t.expect(all).to.equal({ { rid = 1 } })
        t.expect(h.cursors[1].calls).to.have_length(0)
        t.expect(h.last.projection).to.be_nil()
    end)

    t.it("表形式的 sort 整张表作为一个参数传给游标", function()
        local h = started()
        h.CMD.find_many("role", {}, { sort = { seq = 1 } })
        local call = h.cursors[1].calls[1]
        t.expect(call[1]).to.equal("sort")
        t.expect(call[2].n).to.equal(1)
        t.expect(call[2][1]).to.equal({ seq = 1 })
    end)

    t.it("数组形式的 sort 按顺序展开成多个参数", function()
        -- 多字段排序的先后决定索引能不能命中，合成一个表传下去顺序就丢了
        local h = started()
        h.CMD.find_many("entity_msg", {}, { sort = { { target_id = 1 }, { seq = -1 } } })
        local call = h.cursors[1].calls[1]
        t.expect(call[1]).to.equal("sort")
        t.expect(call[2].n).to.equal(2)
        t.expect(call[2][1]).to.equal({ target_id = 1 })
        t.expect(call[2][2]).to.equal({ seq = -1 })
    end)

    t.it("skip/limit/projection 原样设置到游标上", function()
        local h = started()
        h.CMD.find_many("role", { a = 1 }, { skip = 10, limit = 100, projection = { rid = 1 } })
        t.expect(h.last.projection).to.equal({ rid = 1 })
        t.expect(h.cursors[1].calls[1]).to.equal({ "skip", table.pack(10) })
        t.expect(h.cursors[1].calls[2]).to.equal({ "limit", table.pack(100) })
    end)

    t.it("skip 为 0 时仍然下发，不被当成没传", function()
        local h = started()
        h.CMD.find_many("role", {}, { skip = 0, limit = 0 })
        t.expect(h.cursors[1].calls[1]).to.equal({ "skip", table.pack(0) })
        t.expect(h.cursors[1].calls[2]).to.equal({ "limit", table.pack(0) })
    end)
end)

t.describe("mongo_conn 其余命令", function()
    t.it("find_and_modify 原样投递文档", function()
        local h = started()
        local doc = { query = { _id = "role:1" }, update = { ["$inc"] = { seq = 1 } }, new = true }
        t.expect(h.CMD.find_and_modify("entity_msg_seq", doc)).to.equal("fam")
        t.expect(h.last.op).to.equal("findAndModify")
        t.expect(h.last.doc).to.equal(doc)
    end)

    t.it("create_index 不传 options 时不往驱动里塞一个 nil 参数", function()
        local h = started()
        t.expect(h.CMD.create_index("role", { rid = 1 })).to.equal("idx")
        t.expect(h.last.keys).to.equal({ rid = 1 })
        t.expect(h.last.options).to.be_nil()

        h.CMD.create_index("role", { rid = 1 }, { unique = true })
        t.expect(h.last.options).to.equal({ unique = true })
    end)

    t.it("find_one 把驱动返回的文档原样交回去", function()
        local h = started()
        h.found = { rid = 7, name = "alice" }
        t.expect(h.CMD.find_one("role", { rid = 7 }, { name = 1 })).to.equal({ rid = 7, name = "alice" })
        t.expect(h.last.op).to.equal("findOne")
        t.expect(h.last.projection).to.equal({ name = 1 })
    end)

    t.it("find_one 没查到时返回 nil", function()
        local h = started()
        h.found = nil
        t.expect(h.CMD.find_one("role", { rid = 7 })).to.be_nil()
    end)

    t.it("find_one 的日志只记命中与否，不把整份存档刷进去", function()
        local h = started()
        local doc = { rid = 7, bag = { items = { 1, 2, 3 } }, password_hash = "hunter2" }
        h.found = doc
        h.CMD.find_one("role", { rid = 7 })
        t.expect(logged(h, doc)).to.equal(false)
        -- 定位信息还得留着，否则线上查不了问题
        t.expect(logged(h, "find_one")).to.equal(true)
        t.expect(logged(h, true)).to.equal(true)
    end)

    t.it("raw_safe_insert/raw_safe_update 把 bson 原样递给驱动", function()
        local h = started()
        t.expect(h.CMD.raw_safe_insert("role", "bson-i")).to.equal("inserted")
        t.expect(h.last.bson).to.equal("bson-i")
        t.expect(h.CMD.raw_safe_update("role", "bson-u")).to.equal("updated")
        t.expect(h.last.op).to.equal("raw_safe_update")
        t.expect(h.last.bson).to.equal("bson-u")
    end)
end)

-- P06：关键写入必须 majority + journal，并把 CONFIRMED/REJECTED/UNKNOWN 分开
t.describe("mongo_conn 关键写入", function()
    local function with_result(result)
        local h = started()
        h.run_command_result = result
        return h
    end

    t.it("returns CONFIRMED with matched counts", function()
        local h = with_result({ ok = 1, n = 1, nModified = 1 })
        local state, detail = h.CMD.raw_critical_update("role", "BSON")
        t.expect(state).to.equal("CONFIRMED")
        t.expect(detail).to.equal({ n = 1, nModified = 1 })
        t.expect(h.last.args[1]).to.equal("update")
        t.expect(h.last.args[2]).to.equal("role")
        -- 最后一个参数对是 majority 写关注
        t.expect(h.last.args[h.last.args.n - 1]).to.equal("writeConcern")
        t.expect(h.last.args[h.last.args.n]).to.equal({ w = "majority", j = true })
    end)

    t.it("returns REJECTED when mongod reports a write error", function()
        local h = with_result({ ok = 1, writeErrors = { { errmsg = "duplicate key" } } })
        local state, err = h.CMD.raw_critical_update("role", "BSON")
        t.expect(state).to.equal("REJECTED")
        t.expect(err).to.equal("duplicate key")
    end)

    t.it("returns UNKNOWN for a write concern error or a lost reply", function()
        local h = with_result({ ok = 1, writeConcernError = { errmsg = "not majority" } })
        local state, err = h.CMD.raw_critical_update("role", "BSON")
        t.expect(state).to.equal("UNKNOWN")
        t.expect(err).to.equal("not majority")

        h.run_command_error = "socket closed"
        state, err = h.CMD.raw_critical_update("role", "BSON")
        t.expect(state).to.equal("UNKNOWN")
        t.expect(err).to.match("socket closed")
    end)

    t.it("distinguishes a command rejection from an ok=1 reply that still carries errmsg", function()
        local h = with_result({ ok = 0, errmsg = "unauthorized" })
        local state, err = h.CMD.raw_critical_update("role", "BSON")
        t.expect(state).to.equal("REJECTED")
        t.expect(err).to.equal("unauthorized")

        h.run_command_result = { ok = 1, errmsg = "partial" }
        state, err = h.CMD.raw_critical_update("role", "BSON")
        t.expect(state).to.equal("UNKNOWN")
        t.expect(err).to.equal("partial")
    end)

    t.it("critical_find reads the first document with majority read concern", function()
        local h = with_result({ ok = 1, cursor = { firstBatch = { { rid = 7 } } } })
        local doc = h.CMD.critical_find("role", { rid = 7 }, { _fence = false })
        t.expect(doc).to.equal({ rid = 7 })
        t.expect(h.last.args[1]).to.equal("find")
        t.expect(h.last.args[h.last.args.n - 1]).to.equal("readConcern")
        t.expect(h.last.args[h.last.args.n]).to.equal({ level = "majority" })
    end)

    t.it("critical_find returns nil when the cursor is empty", function()
        local h = with_result({ ok = 1, cursor = { firstBatch = {} } })
        t.expect(h.CMD.critical_find("role", { rid = 7 })).to.be_nil()
    end)

    t.it("critical_find_and_modify appends the majority write concern", function()
        local h = with_result({ ok = 1, value = { rid = 7 }, lastErrorObject = { n = 1 } })
        local state, ret =
            h.CMD.critical_find_and_modify("role", { query = { rid = 7 }, update = { ["$set"] = { _fence = 5 } } })
        t.expect(state).to.equal("CONFIRMED")
        t.expect(ret.value).to.equal({ rid = 7 })
        t.expect(h.last.args[1]).to.equal("findAndModify")
        t.expect(h.last.args[2]).to.equal("role")
        t.expect(h.last.args[h.last.args.n - 1]).to.equal("writeConcern")
        t.expect(h.last.args[h.last.args.n]).to.equal({ w = "majority", j = true })
    end)

    -- 只发 hello 是假探针：secondary 也能应答 hello。这里必须真的写一次、
    -- 多数派读回、再清理，而且绝不能写进玩家角色集合
    t.it("critical_probe writes, reads back and cleans up with majority", function()
        local h = started()
        h.run_command_results = {
            insert = { ok = 1, n = 1 },
            find = { ok = 1, cursor = { firstBatch = { { _id = "probe" } } } },
            delete = { ok = 1, n = 1 },
        }
        t.expect(h.CMD.critical_probe("role")).to.equal(true)

        local names = {}
        for _, call in ipairs(h.commands) do
            names[#names + 1] = call.args[1]
        end
        t.expect(names).to.equal({ "insert", "find", "delete" })

        local insert = h.commands[1].args
        t.expect(insert[2]).to.equal("skyext_health_probe")
        t.expect(insert[2] == "role").to.equal(false)
        t.expect(insert[3]).to.equal("documents")
        t.expect(type(insert[4][1]._id)).to.equal("string")
        t.expect(insert[insert.n - 1]).to.equal("writeConcern")
        t.expect(insert[insert.n]).to.equal({ w = "majority", j = true })

        local find = h.commands[2].args
        t.expect(find[2]).to.equal("skyext_health_probe")
        t.expect(find[find.n - 1]).to.equal("readConcern")
        t.expect(find[find.n]).to.equal({ level = "majority" })

        local delete = h.commands[3].args
        t.expect(delete[2]).to.equal("skyext_health_probe")
        t.expect(delete[delete.n - 1]).to.equal("writeConcern")
        t.expect(delete[delete.n]).to.equal({ w = "majority", j = true })
    end)

    t.it("critical_probe refuses to report health when any leg is unconfirmed", function()
        -- 写没确认：UNKNOWN 也不能算健康
        local h = started()
        h.run_command_results = {
            insert = { ok = 1, writeConcernError = { errmsg = "not majority" } },
        }
        local ok, err = h.CMD.critical_probe("role")
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("majority write not confirmed")

        -- 写确认了但读不到：读关注没生效
        h.run_command_results = {
            insert = { ok = 1, n = 1 },
            find = { ok = 1, cursor = { firstBatch = {} } },
        }
        ok, err = h.CMD.critical_probe("role")
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("not visible to a majority read")

        -- 清理失败不能当成功：否则每跑一次留一条垃圾
        h.run_command_results = {
            insert = { ok = 1, n = 1 },
            find = { ok = 1, cursor = { firstBatch = { { _id = "probe" } } } },
            delete = { ok = 0, errmsg = "unauthorized" },
        }
        ok, err = h.CMD.critical_probe("role")
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("cleanup not confirmed")
        t.expect(logged(h, "critical probe cleanup not confirmed")).to.equal(true)

        -- 命令通道直接抛错
        h.run_command_error = "socket closed"
        ok, err = h.CMD.critical_probe("role")
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("probe insert raised")
    end)
end)
