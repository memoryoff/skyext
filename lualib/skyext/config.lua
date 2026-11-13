local skynet = require "skynet"

local M = {}

-- 三份缓存各自独立：
--   raw_conf   环境变量读到的原始字符串（get 的视图）
--   typed_conf get_boolean / get_number 的类型化结果
--   table_conf get_table 求值出来的表
-- 早期三者共用一张 conf：先 get 把 "false"/"1024" 写进去，之后 get_boolean 直接把
-- 字符串 "false" 返回（Lua 里非空字符串为真）、get_number 直接返回字符串，
-- if config.get_boolean("x") then 就会在本该为假时走进 true 分支。
local raw_conf = {}
local typed_conf = {}
local table_conf = {}

local function read_env(key)
    return skynet.getenv(key)
end

function M.get(key)
    local cached = raw_conf[key]
    if cached ~= nil then
        return cached
    end

    local value = read_env(key)
    if value == nil then
        return
    end

    raw_conf[key] = value
    return value
end

-- 类型化取值只读原始缓存、不写它：get_number 对非数字值的既有语义是"每次重新读"
-- （转换失败的结果存不进缓存表），写了原始缓存会把这个语义悄悄改掉
local function peek(key)
    local cached = raw_conf[key]
    if cached ~= nil then
        return cached
    end
    return read_env(key)
end

function M.get_boolean(key)
    local cached = typed_conf[key]
    if cached ~= nil then
        return cached
    end

    local value = peek(key)
    if value == nil then
        return
    end

    -- 配置里只认小写 "true"；"1"/"yes"/"TRUE" 都是假
    value = value == "true"
    typed_conf[key] = value
    return value
end

function M.get_number(key)
    local cached = typed_conf[key]
    if cached ~= nil then
        return cached
    end

    local value = peek(key)
    if value == nil then
        return
    end

    value = tonumber(value)
    if value == nil then
        -- nil 存不进缓存表，保持"每次重新问一遍"的既有语义
        return
    end
    typed_conf[key] = value
    return value
end

function M.get_table(key)
    local cached = table_conf[key]
    if cached ~= nil then
        return cached
    end

    local s = M.get(key)
    if type(s) ~= "string" then
        -- 未设置（nil）时直接返回，不去 load 空字符串
        return s
    end

    local f, err1 = load("return " .. s, "@" .. key)
    if not f then
        error("load config failed:" .. err1 .. s)
    end

    local ok, err2 = pcall(f)
    if not ok then
        error("exec config failed:" .. err2)
    end

    table_conf[key] = err2
    return err2
end

function M.serialize(t)
    if type(t) == "table" then
        local parts = { "{" }
        for k, v in pairs(t) do
            parts[#parts + 1] = "[" .. M.serialize(k) .. "]=" .. M.serialize(v) .. ","
        end
        parts[#parts + 1] = "}"
        return table.concat(parts)
    elseif type(t) == "string" then
        return string.format("%q", t)
    else
        return tostring(t)
    end
end

local function load_config(config_name)
    local result = {}
    local function getenv(name)
        return assert(os.getenv(name), [[os.getenv() failed: ]] .. name)
    end
    local sep = package.config:sub(1, 1)
    local current_path = [[.]] .. sep
    local function include(filename)
        local last_path = current_path
        local path, name = filename:match([[(.*]] .. sep .. [[)(.*)$]])
        if path then
            if path:sub(1, 1) == sep then -- root
                current_path = path
            else
                current_path = current_path .. path
            end
        else
            name = filename
        end
        local f = assert(io.open(current_path .. name))
        local code = assert(f:read [[*a]])
        code = string.gsub(code, [[%$([%w_%d]+)]], getenv)
        f:close()
        assert(load(code, [[@]] .. filename, [[t]], result))()
        current_path = last_path
    end
    -- 配置在隔离环境里执行：__index 只暴露这份白名单，读不到进程里的全局变量，
    -- 也拿不到 skynet / io / loadfile 这些能碰到进程状态的东西。
    -- 标准库给只读视图：读 `table.concat` 没问题，写 `table.concat = nil` 会污染
    -- 整个进程，必须挡掉。
    local function readonly_view(stdlib)
        return setmetatable({}, {
            __index = stdlib,
            __newindex = function(_, key)
                error("config must not modify the Lua standard library: " .. tostring(key), 2)
            end,
        })
    end
    setmetatable(result, {
        __index = {
            include = include,
            type = type,
            pairs = pairs,
            ipairs = ipairs,
            next = next,
            tostring = tostring,
            tonumber = tonumber,
            assert = assert,
            error = error,
            pcall = pcall,
            select = select,
            string = readonly_view(string),
            table = readonly_view(table),
            math = readonly_view(math),
            os = readonly_view({ getenv = os.getenv, time = os.time, date = os.date }),
        },
    })
    include(config_name)
    setmetatable(result, nil)
    return result
end

function M.init()
    local app_config_loaded = skynet.getenv("app_config_loaded")
    if app_config_loaded then
        return
    end

    local app_config_path = skynet.getenv("app_config_path")
    if app_config_path == nil then
        error("app_config_path is nil")
    end
    local ok, result = pcall(load_config, app_config_path)
    if not ok then
        error("load app config failed:" .. result)
    end
    skynet.setenv("app_config_loaded", "true")
    for k, v in pairs(result) do
        if type(v) == "table" then
            skynet.setenv(k, M.serialize(v))
        else
            skynet.setenv(k, tostring(v))
        end
    end
end

return M
