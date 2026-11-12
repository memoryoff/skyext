--[[
指标标签高基数检查。

Prometheus 的标签会为每个不同取值建一条时间序列。把 conn_id / msg_id / rid
这类"每个请求都不同"的值当标签，指标服务的内存和存储会随连接数线性膨胀，
而且这种膨胀不会报错，只会在线上慢慢把进程拖死。

日志里保留完整 ID 没问题，指标只允许低基数分类（结果、状态、类型）。

用法：lua scripts/ci/check_metrics_labels.lua [repo_root]
]]

local root = (... or arg[1] or "."):gsub("/+$", "")

-- 一旦成为指标标签就会随请求/连接数增长的字段
local FORBIDDEN = {
    conn_id = true,
    session_id = true,
    rid = true,
    entity_id = true,
    msg_id = true,
    event_id = true,
    op_id = true,
    req_id = true,
    trace_id = true,
}

local CANDIDATES = { "metrics.counter(", "metrics.gauge(", "metrics.histogram(" }

local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

local function list_files(dir, out)
    local pipe = io.popen('find "' .. dir .. '" -name "*.lua" -not -name "*.test.lua" 2>/dev/null')
    if not pipe then
        return
    end
    for line in pipe:lines() do
        out[#out + 1] = line
    end
    pipe:close()
end

local function line_of(src, pos)
    local _, count = src:sub(1, pos):gsub("\n", "\n")
    return count + 1
end

-- 找到一次指标调用里的标签表：调用起点之后、右括号之前的第一对花括号。
-- 没有标签表（两参数形式）就跳过，不能把后面无关的 table 当标签。
local function label_block(src, from)
    local close_paren = src:find(")", from, true)
    local open = src:find("{", from, true)
    if not open or (close_paren and open > close_paren) then
        return nil, from
    end
    local depth = 0
    local limit = math.min(#src, open + 400)
    for i = open, limit do
        local c = src:sub(i, i)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
                return src:sub(open, i), i
            end
        end
    end
    return nil, from
end

local function check_file(path, src)
    local problems = {}
    local cursor = 1
    while true do
        local start_pos, end_pos
        for _, needle in ipairs(CANDIDATES) do
            local a, b = src:find(needle, cursor, true)
            if a and (not start_pos or a < start_pos) then
                start_pos, end_pos = a, b
            end
        end
        if not start_pos then
            break
        end
        local block, block_end = label_block(src, end_pos)
        if block then
            for label in block:gmatch('"([%w_%-%.]+)"') do
                if FORBIDDEN[label] then
                    problems[#problems + 1] = string.format(
                        "%s:%d: metric label %q is high-cardinality; use a result/state category instead",
                        path,
                        line_of(src, start_pos),
                        label
                    )
                end
            end
            cursor = block_end + 1
        else
            cursor = end_pos
        end
    end
    return problems
end

local files = {}
for _, dir in ipairs({ root .. "/lualib", root .. "/service", root .. "/example" }) do
    list_files(dir, files)
end

local problems = {}
for _, path in ipairs(files) do
    local src = read_file(path)
    if src then
        for _, problem in ipairs(check_file(path, src)) do
            problems[#problems + 1] = problem
        end
    end
end

if #problems > 0 then
    for _, problem in ipairs(problems) do
        io.stderr:write(problem .. "\n")
    end
    io.stderr:write(string.format("metrics label check failed: %d problem(s)\n", #problems))
    os.exit(1)
end

print(string.format("metrics label check passed (%d files)", #files))
