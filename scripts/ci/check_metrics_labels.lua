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

local CANDIDATES = {
    "metrics.counter(",
    "metrics.gauge(",
    "metrics.histogram(",
    "metrics:counter(",
    "metrics:gauge(",
    "metrics:histogram(",
}

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

-- 把注释和字符串**内容**替换成空格，保持长度不变。
--
-- 两件事都必须在遮罩上做，否则会误判：
--   * 注释里举例写的 `-- metrics.counter("x", "h", { "session_id" })` 不是真代码，
--     在注释里扫会直接把 CI 判红；
--   * help 文本里的括号（"events (total)"）会让"第一个右括号"定位提前收口，
--     把真正的标签表漏掉。
-- 标签名仍从原文的同一区间里取，所以遮罩不影响提取。
local function mask(src)
    local out = {}
    local i, n = 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if c == "-" and src:sub(i, i + 1) == "--" then
            -- 块注释 --[[ ... ]] / --[==[ ... ]==]
            local eq = src:match("^%-%-%[(=*)%[", i)
            if eq then
                local closer = "]" .. eq .. "]"
                local stop = src:find(closer, i + 4 + #eq, true)
                stop = stop and (stop + #closer - 1) or n
                out[#out + 1] = (src:sub(i, stop):gsub("[^\n]", " "))
                i = stop + 1
            else
                local stop = src:find("\n", i, true) or (n + 1)
                out[#out + 1] = (src:sub(i, stop - 1):gsub("[^\n]", " "))
                i = stop
            end
        elseif c == '"' or c == "'" then
            local quote = c
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then
                    j = j + 2
                elseif d == quote then
                    break
                else
                    j = j + 1
                end
            end
            -- 保留引号，中间内容抹成空格
            out[#out + 1] = quote .. (src:sub(i + 1, j - 1):gsub("[^\n]", " ")) .. quote
            i = j + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- 找到一次指标调用里的标签表：调用起点之后、右括号之前的第一对花括号。
-- 没有标签表（两参数形式）就跳过，不能把后面无关的 table 当标签。
-- 位置全部在遮罩上算，返回的区间用于从原文取标签名
local function label_block(masked, from)
    local close_paren = masked:find(")", from, true)
    local open = masked:find("{", from, true)
    if not open or (close_paren and open > close_paren) then
        return nil, from
    end
    local depth = 0
    local limit = math.min(#masked, open + 400)
    for i = open, limit do
        local c = masked:sub(i, i)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
                return { open = open, stop = i }, i
            end
        end
    end
    return nil, from
end

local function check_file(path, src)
    local problems = {}
    local masked = mask(src)
    local cursor = 1
    while true do
        local start_pos, end_pos
        for _, needle in ipairs(CANDIDATES) do
            local a, b = masked:find(needle, cursor, true)
            if a and (not start_pos or a < start_pos) then
                start_pos, end_pos = a, b
            end
        end
        if not start_pos then
            break
        end
        local block, block_end = label_block(masked, end_pos)
        if block then
            -- 从原文取标签名：遮罩把字符串内容抹掉了
            local text = src:sub(block.open, block.stop)
            for label in text:gmatch('"([%w_%-%.]+)"') do
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

-- 扫到 0 个文件时不能报 passed：目录名改过、root 传错、find 不可用都会走到这里，
-- 而"没扫到东西"看起来和"全部合规"一模一样
if #files == 0 then
    io.stderr:write(
        string.format("metrics label check found no files under %s (expected lualib/ service/ example/)\n", root)
    )
    os.exit(1)
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
