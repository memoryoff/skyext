local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source =
    fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/nodes/role/modules/bag/init.lua")

local function harness()
    local imports = {
        orm = {
            totable = function(value)
                return value
            end,
        },
        ["skyext.res"] = { param = { InitItem = {} } },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    local M = assert(loadfile(source, "t", env))()
    return setmetatable({ data = { bags = {} } }, M)
end

t.describe("bag item addition", function()
    t.it("rejects an overflow before mutating the item", function()
        local bag = harness()
        assert(bag:add_item(1, 1, math.maxinteger))
        local added, err = bag:add_item(1, 1, 1)
        t.expect(added).to.be_nil()
        t.expect(err).to.equal("item count overflow")
        t.expect(bag:count(1, 1)).to.equal(math.maxinteger)
    end)

    t.it("accepts the exact largest representable stack", function()
        local bag = harness()
        assert(bag:add_item(1, 1, 1))
        t.expect(bag:add_item(1, 1, math.maxinteger - 1)).to.equal(true)
        t.expect(bag:count(1, 1)).to.equal(math.maxinteger)
    end)
end)
