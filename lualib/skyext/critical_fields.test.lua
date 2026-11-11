-- P00-B 运行时探针：真实 BSON 角色文档里的 `_critical_*` 保留字段。
--
-- 核心事实（必须先证明，否则 P07/P08 无法开工）：
--   1. `orm.decode` 会**原地删除** schema 之外的字段，并把名字记进 `dropped`；
--   2. 所以在 decode 之前必须 `extract` 出保留字段并深拷贝；
--   3. 普通 ORM 的 dirty/save 路径不得生成任何 `_critical_*` 路径。
--
-- 这里用的是真实 bson 编解码，不是手工构造的 Lua 表。
local t = require "skytest"
local bson = require "bson"
local orm = require "orm"
local critical_fields = require "skyext.critical_fields"

local integer = { type = "integer" }
local role = { type = "message", rid = integer, _version = integer, gold = integer }
function role:_parse_k(k)
    assert(self[k], "unknown key: " .. tostring(k))
    return k
end
function role:_check_k(k)
    self:_parse_k(k)
end
function role:_check_kv(_, value)
    assert(type(value) == "number")
end
function role:fields()
    return { "rid", "_version", "gold" }
end

local OP_HASH = string.rep("ab", 16) -- 32 字节二进制摘要
local OP_ID = "0123456789abcdef0123456789abcdef_0001"

local function role_doc(over)
    local doc = {
        rid = 1001,
        _version = 7,
        gold = 500,
        _critical_intent_v1 = {
            op_id = OP_ID,
            op_type = "shop.buy",
            param_hash = OP_HASH,
            owner_fence = "fence-1",
            prepared_at = 1700000000,
            state = "PREPARED",
        },
        _critical_ops_v1 = {
            [OP_ID] = { op_type = "shop.buy", param_hash = OP_HASH, status = "COMMITTED", committed_at = 1700000001 },
        },
        _critical_outbox_v1 = {
            ["evt_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"] = {
                type = "mail.send",
                target = "rid:1002",
                status = "PENDING",
                created_at = 1700000002,
            },
        },
    }
    for k, v in pairs(over or {}) do
        doc[k] = v
    end
    return doc
end

local function roundtrip(doc)
    return bson.decode(bson.encode(doc))
end

t.describe("P00-B critical field extraction", function()
    t.it("keeps reserved metadata out of orm.decode and out of dropped", function()
        local raw = roundtrip(role_doc())
        local clean, critical = critical_fields.extract(raw)
        t.expect(clean).to.exist()
        t.expect(clean._critical_intent_v1).to.be_nil()
        t.expect(clean._critical_ops_v1).to.be_nil()
        t.expect(clean._critical_outbox_v1).to.be_nil()

        local doc, dropped = orm.decode(role, clean)
        t.expect(doc.rid).to.equal(1001)
        t.expect(doc._version).to.equal(7)
        t.expect(doc.gold).to.equal(500)
        t.expect(dropped).to.equal({})

        t.expect(critical_fields.names(critical)).to.equal({
            critical_fields.INTENT,
            critical_fields.OPS,
            critical_fields.OUTBOX,
        })
        t.expect(critical[critical_fields.INTENT].op_id).to.equal(OP_ID)
        t.expect(critical[critical_fields.OPS][OP_ID].status).to.equal("COMMITTED")
    end)

    t.it("shows what happens without extraction: decode drops them and says so", function()
        local raw = roundtrip(role_doc())
        local _, dropped = orm.decode(role, raw)
        t.expect(#dropped).to.equal(3)
        -- 这三个名字一旦出现在 dropped 里，就说明未决意图/账本被当成垃圾删掉了
        local joined = table.concat(dropped, ",")
        t.expect(joined).to.match("_critical_intent_v1")
        t.expect(joined).to.match("_critical_ops_v1")
        t.expect(joined).to.match("_critical_outbox_v1")
    end)

    t.it("does not mutate the source document", function()
        local raw = roundtrip(role_doc())
        critical_fields.extract(raw)
        t.expect(raw._critical_intent_v1).to.exist()
        t.expect(raw.gold).to.equal(500)
    end)

    t.it("deep copies so the ORM copy and the critical copy never alias", function()
        local raw = roundtrip(role_doc())
        local _, critical = critical_fields.extract(raw)
        raw._critical_ops_v1[OP_ID].status = "DISCARDED"
        t.expect(critical[critical_fields.OPS][OP_ID].status).to.equal("COMMITTED")

        critical[critical_fields.INTENT].op_type = "changed"
        t.expect(raw._critical_intent_v1.op_type).to.equal("shop.buy")
    end)

    t.it("survives a save/reload round trip without leaking critical paths into $set", function()
        local raw = roundtrip(role_doc())
        local clean, critical = critical_fields.extract(raw)
        local doc = orm.decode(role, clean)
        doc.gold = 450
        local dirty, update = orm.snapshot_mongo(doc)
        t.expect(dirty).to.equal(true)
        t.expect(update["$set"].gold).to.equal(450)
        for key in pairs(update["$set"] or {}) do
            t.expect(key:sub(1, 10) == "_critical_").to.equal(false)
        end
        t.expect(update["$unset"]).to.be_nil()

        -- 重新加载后仍然能拿到同一份元数据
        local reloaded = roundtrip({ rid = 1001, _version = 7, gold = 450 })
        local clean2, critical2 = critical_fields.extract(reloaded)
        t.expect(clean2._critical_intent_v1).to.be_nil()
        t.expect(critical2[critical_fields.INTENT]).to.be_nil()
        t.expect(critical[critical_fields.INTENT].op_id).to.equal(OP_ID)
    end)
end)

t.describe("P00-B fail-closed", function()
    t.it("refuses an unknown critical version instead of letting ORM drop it", function()
        local raw = roundtrip(role_doc({ _critical_intent_v2 = { state = "PREPARED" } }))
        local clean, err, unknown = critical_fields.extract(raw)
        t.expect(clean).to.be_nil()
        t.expect(err).to.match("unknown critical field")
        t.expect(unknown).to.equal({ "_critical_intent_v2" })
    end)

    t.it("refuses malformed intent, unsafe op keys and non-table entries", function()
        local bad_state = role_doc()
        bad_state._critical_intent_v1.state = "DONE"
        local clean, err = critical_fields.extract(bad_state)
        t.expect(clean).to.be_nil()
        t.expect(err).to.match("unknown state")

        local bad_hash = role_doc()
        bad_hash._critical_intent_v1.param_hash = "short"
        clean, err = critical_fields.extract(bad_hash)
        t.expect(clean).to.be_nil()
        t.expect(err).to.match("param_hash")

        local unsafe = role_doc()
        unsafe._critical_ops_v1["a.b"] = { status = "COMMITTED" }
        clean, err = critical_fields.extract(unsafe)
        t.expect(clean).to.be_nil()
        t.expect(err).to.match("unsafe key")

        local non_table = role_doc()
        non_table._critical_outbox_v1["evt_x"] = "PENDING"
        clean, err = critical_fields.extract(non_table)
        t.expect(clean).to.be_nil()
        t.expect(err).to.match("must be a table")
    end)

    t.it("shares one size budget across all three reserved fields", function()
        local doc = role_doc()
        local chunk = string.rep("x", 200 * 1024)
        for _, name in ipairs({ "evt_a", "evt_b", "evt_c" }) do
            doc._critical_outbox_v1[name] = { status = "PENDING", payload = chunk }
        end
        local clean, err = critical_fields.extract(doc)
        t.expect(clean).to.be_nil()
        t.expect(err).to.match("size limit")
    end)

    t.it("refuses userdata, cycles and oversized metadata", function()
        local with_userdata = role_doc()
        with_userdata._critical_ops_v1[OP_ID].result = coroutine.create(function() end)
        local clean, err = critical_fields.extract(with_userdata)
        t.expect(clean).to.be_nil()
        t.expect(err).to.match("unsupported type")

        local cycle = role_doc()
        cycle._critical_intent_v1.self = cycle._critical_intent_v1
        clean, err = critical_fields.extract(cycle)
        t.expect(clean).to.be_nil()
        t.expect(err).to.match("cycle")

        local big = role_doc()
        big._critical_outbox_v1["evt_big"] =
            { status = "PENDING", payload = string.rep("x", critical_fields.MAX_BYTES + 1) }
        clean, err = critical_fields.extract(big)
        t.expect(clean).to.be_nil()
        t.expect(err).to.match("size limit")
    end)
end)
