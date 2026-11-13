-- 关键账本/恢复任务集合的配置形状校验。
--
-- maintenance 启动门禁、launcher 自检、entity_agent 运行期 fail-closed 必须使用
-- 同一口径；否则一处接受空集合名、另一处拒绝，最终仍会出现“服务已启动但命令拒绝”。
local M = {}

local function valid_name(value)
    return type(value) == "string" and value ~= ""
end

function M.validate_collection_spec(spec)
    if type(spec) ~= "table" then
        return false, "must be a table"
    end
    if not valid_name(spec.db) then
        return false, "db must be a non-empty string"
    end
    if not valid_name(spec.coll) then
        return false, "coll must be a non-empty string"
    end
    return true
end

return M
