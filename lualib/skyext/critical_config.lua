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

function M.same_collection(a, b)
    return type(a) == "table" and type(b) == "table" and a.db == b.db and a.coll == b.coll
end

function M.validate_entity_config(type_config)
    if type(type_config) ~= "table" then
        return false, "entity type config must be a table"
    end
    local ledger = type_config.critical_ledger
    local jobs = type_config.critical_jobs
    local ok, err = M.validate_collection_spec(ledger)
    if not ok then
        return false, "critical_ledger " .. err
    end
    ok, err = M.validate_collection_spec(jobs)
    if not ok then
        return false, "critical_jobs " .. err
    end
    if M.same_collection(ledger, jobs) then
        return false, "critical_ledger and critical_jobs must use different collections"
    end
    if type(type_config.db_name) == "string" and type(type_config.db_coll) == "string" then
        local role = { db = type_config.db_name, coll = type_config.db_coll }
        if M.same_collection(role, ledger) or M.same_collection(role, jobs) then
            return false, "critical ledger collections must differ from the entity collection"
        end
    end
    return true
end

return M
