local t = require "skytest"
local critical_config = require "skyext.critical_config"

t.describe("critical collection config", function()
    t.it("accepts a complete db/coll spec", function()
        t.expect(critical_config.validate_collection_spec({ db = "role", coll = "op_ledger" })).to.equal(true)
    end)

    t.it("rejects missing, malformed and empty db/coll values", function()
        for _, spec in ipairs({
            nil,
            "role.op_ledger",
            {},
            { db = "role" },
            { db = "", coll = "op_ledger" },
            { db = "role", coll = "" },
            { db = 1, coll = "op_ledger" },
            { db = "role", coll = false },
        }) do
            local ok, err = critical_config.validate_collection_spec(spec)
            t.expect(ok).to.equal(false)
            t.expect(type(err)).to.equal("string")
        end
    end)
end)
