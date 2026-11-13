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
        elseif c == "[" and src:match("^%[(=*)%[", i) then
            -- 长字符串也可能包含括号、逗号或伪指标调用；整体遮罩，避免破坏调用解析
            local eq = src:match("^%[(=*)%[", i)
            local closer = "]" .. eq .. "]"
            local stop = src:find(closer, i + 2 + #eq, true)
            stop = stop and (stop + #closer - 1) or n
            out[#out + 1] = (src:sub(i, stop):gsub("[^\n]", " "))
            i = stop + 1
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

local function trimmed(masked, first, last)
    while first <= last and masked:sub(first, first):match("%s") do
        first = first + 1
    end
    while last >= first and masked:sub(last, last):match("%s") do
        last = last - 1
    end
    return first, last
end

-- 找到与调用左括号配对的右括号。指标 help 文本已经先被遮罩，里面的括号
-- 不会干扰；这里不设长度上限，避免跨行长表被静默跳过。
local function call_close(masked, open_paren)
    local depth = 0
    for i = open_paren, #masked do
        local c = masked:sub(i, i)
        if c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = depth - 1
            if depth == 0 then
                return i
            end
        end
    end
    return nil
end

-- 在调用参数里按顶层逗号分段；括号、方括号和花括号内的逗号不属于参数分隔符。
local function split_args(masked, first, last)
    local ranges = {}
    local start = first
    local parens, brackets, braces = 0, 0, 0
    for i = first, last do
        local c = masked:sub(i, i)
        if c == "(" then
            parens = parens + 1
        elseif c == ")" then
            parens = parens - 1
        elseif c == "[" then
            brackets = brackets + 1
        elseif c == "]" then
            brackets = brackets - 1
        elseif c == "{" then
            braces = braces + 1
        elseif c == "}" then
            braces = braces - 1
        elseif c == "," and parens == 0 and brackets == 0 and braces == 0 then
            ranges[#ranges + 1] = { first = start, last = i - 1 }
            start = i + 1
        end
    end
    ranges[#ranges + 1] = { first = start, last = last }
    return ranges
end

local function matching_brace(masked, open)
    local depth = 0
    for i = open, #masked do
        local c = masked:sub(i, i)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
                return i
            end
        end
    end
    return nil
end

-- 标签参数必须是静态字面量表，且每个元素都是字符串。变量表、拼接表或表内
-- 动态表达式都无法由 CI 证明低基数，必须 fail-closed，而不是静默跳过。
local function label_names(src, masked, first, last)
    first, last = trimmed(masked, first, last)
    if first > last or masked:sub(first, first) ~= "{" then
        return nil, "metric labels must be a literal table; dynamic labels cannot be audited"
    end
    local close = matching_brace(masked, first)
    if not close or close ~= last then
        return nil, "metric labels must be one complete literal table"
    end
    if close == first + 1 then
        return {}
    end

    local labels = {}
    local ranges = split_args(masked, first + 1, close - 1)
    for index, range in ipairs(ranges) do
        local a, b = trimmed(masked, range.first, range.last)
        if a > b then
            if index == #ranges then
                -- 允许尾随逗号
                break
            end
            return nil, "metric labels must not contain empty entries"
        end
        local quote = masked:sub(a, a)
        if (quote ~= '"' and quote ~= "'") or masked:sub(b, b) ~= quote then
            return nil, "metric labels must contain only literal strings"
        end
        if masked:sub(a + 1, b - 1):find("%S") then
            return nil, "metric labels must contain only literal strings"
        end
        labels[#labels + 1] = src:sub(a + 1, b - 1)
    end
    return labels
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
        local close_paren = call_close(masked, end_pos)
        if not close_paren then
            problems[#problems + 1] =
                string.format("%s:%d: metric call has no matching close parenthesis", path, line_of(src, start_pos))
            break
        end
        local args = split_args(masked, end_pos + 1, close_paren - 1)
        if #args > 3 then
            problems[#problems + 1] =
                string.format("%s:%d: metric call has unexpected extra arguments", path, line_of(src, start_pos))
        elseif #args == 3 then
            local labels, label_err = label_names(src, masked, args[3].first, args[3].last)
            if not labels then
                problems[#problems + 1] = string.format("%s:%d: %s", path, line_of(src, start_pos), label_err)
            else
                for _, label in ipairs(labels) do
                    if FORBIDDEN[label] then
                        problems[#problems + 1] = string.format(
                            "%s:%d: metric label %q is high-cardinality; use a result/state category instead",
                            path,
                            line_of(src, start_pos),
                            label
                        )
                    end
                end
            end
        end
        cursor = close_paren + 1
    end
    return problems
end

local function self_test()
    local cases = {
        { name = "short literal label", source = [[metrics.counter("x", "help", { "rid" })]], expected = 1 },
        {
            name = "long literal label table",
            source = 'metrics.counter("x", "help", {' .. string.rep(" ", 500) .. '"rid"})',
            expected = 1,
        },
        {
            name = "dynamic labels fail closed",
            source = [[local labels = { "ok" }; metrics.gauge("x", "help", labels)]],
            expected = 1,
        },
        {
            name = "dynamic label entry fails closed",
            source = [[metrics.histogram("x", "help", { "ok", some_label })]],
            expected = 1,
        },
        {
            name = "balanced multiline table",
            source = 'metrics.counter(\n "x",\n "help (total)",\n {\n  "status",\n  "rid",\n }\n)',
            expected = 1,
        },
        { name = "safe table", source = [[metrics.counter("x", "help", { "status", "reason" })]], expected = 0 },
    }
    for _, case in ipairs(cases) do
        local got = #check_file("self-test.lua", case.source)
        if got ~= case.expected then
            io.stderr:write(
                string.format(
                    "metrics label self-test %q failed: expected %d problem(s), got %d\n",
                    case.name,
                    case.expected,
                    got
                )
            )
            os.exit(1)
        end
    end
    print(string.format("metrics label self-test passed (%d cases)", #cases))
end

if arg[1] == "--self-test" then
    self_test()
    os.exit(0)
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
