# 06 · `lualib/skytest/` 测试框架

> 覆盖 `lualib/skytest/` 全部文件：`init.lua`、`expect.lua`、`http.lua`、`reporter.lua`、`runner.lua`、`cov/`（`collector`、`config`、`init`、`install`、`lcov_reporter`、`source_lines`）。
> 第二列是源码起始行号。

## `init.lua`（279 行，测试 DSL 与运行时）

`require "skytest"` 返回的 `t` 表就是 DSL：`describe` / `it` / 四个钩子 / 断言无关的辅助函数。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `t.describe(name, fn)` | 26 | 建套件并入树；`fn` 内可继续嵌套 | 可嵌套 |
| `t.it(name, fn)` | 39 | 注册一条用例 | **必须在 `describe` 内**，否则 `error("[skytest] it() must be called inside describe()")` |
| `t.before_all(fn)` / `t.after_all(fn)` | 46 / 53 | 套件级钩子 | 同上，必须在该套件内 |
| `t.before_each(fn)` / `t.after_each(fn)` | 60 / 67 | 用例级钩子 | 同上 |
| `t.run()` | 245 | 执行整棵树：逐套件跑 `before_all → (before_each → it → after_each)* → after_all`，失败用 `xpcall(..., debug.traceback)` 收集 | 返回结果表 |
| `t.start_skynet(opts)` | 102 | 起一个子 skynet 进程跑测试：按 `SKYTEST_ROOT`/`SKYTEST_FILE` 生成临时配置（`root`、`start`、`luaservice` 加上 `<base>.test/?.lua;`），配置键必须匹配 `^[%a_][%w_]*$` | 测试目录不存在/键非法断言失败 |
| `t.data_path(filename)` | 157 | 测试数据文件路径（基于 `SKYTEST_FILE` 推出的 `<base>.test/`） | 缺 `SKYTEST_FILE` 时 `error` |
| `t.wait_for_port(port, timeout)` | 86 | 轮询 `127.0.0.1:port` 直到可连，默认 5 秒 | 超时 `error("[skytest] wait_for_port(…) timed out after …s")` |
| `t._cleanup()` | 262 | 收尾：关子进程句柄、删临时配置；若过程中有错误则断言失败把错误拼出来 | — |
| `run_suite` / `new_suite` | 164 / 15 | 递归执行套件；套件对象字段 `name`/`before_all_fn`/`after_all_fn`/`before_each_fn`/`after_each_fn`/`items` | `after_each`/`after_all` 报错只打印不中断（避免掩盖用例本身的失败） |

## `expect.lua`（267 行，断言）

`expect(value)` 返回 `{ to = …, to_not = … }`，两侧共用同一套断言实现（`make_assertions(value, negated)`），失败信息区分肯定/否定两种措辞。

| 断言 | 行 | 说明 |
| --- | --- | --- |
| `equal(expected)` | 48 | 深比较（表逐键，数组按长度） |
| `exist()` / `be_nil()` | 61 / 73 | 非 `nil` / 是 `nil` |
| `be_truthy()` / `be_falsy()` | 85 / 98 | 真值语义（`false` 与 `nil` 都算 falsy） |
| `be_type(expected)` | 111 | `type()` 相等 |
| `be_gt` / `be_gte` / `be_lt` / `be_lte` | 126-162 | 数值比较；**否定式对 `NaN` 也必须失败**，并保留元方法行为 |
| `contain(substr)` | 175 | 字符串**字面子串**（`string.find(..., 1, true)`，不解释模式） |
| `match(pattern)` | 191 | 字符串**模式**匹配 |
| `have_key(key)` | 207 | 表是否有该键 |
| `have_length(n)` | 223 | `#value == n` |
| `throw(pattern)` | 236 | 调函数必须抛错且错误信息匹配模式 |
| `deep_equal` / `format_value` / `fail` | 1-41 | 深比较实现；失败信息里的值渲染（字符串 `%q`、表递归）；`fail` 用 `error(msg, level+1)` 让栈指向调用方 |

## `http.lua`（73 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.get(host, path)` | 6 | GET，返回原始 body |
| `M.get_json(host, path)` | 10 | GET + `cjson.decode` |
| `M.post(host, path, data, content_type)` | 18 | POST 原始数据（默认 `application/json`） |
| `M.post_json(host, path, tbl)` | 26 | POST 表并解码回包 |
| `M.request(method, host, path, opts)` | 37 | 通用请求：`opts.json`、`opts.headers`、`opts.timeout`（临时改 `httpc.timeout` 后还原）；`opts.json` 为真时解回包 |

## `reporter.lua`（44 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.describe_start(name, depth)` | 7 | 套件标题（两空格缩进/层） |
| `M.it_pass(name, duration_ms, depth)` | 11 | 绿色 `✓` + 耗时 |
| `M.it_fail(name, duration_ms, err, depth)` | 15 | 红色 `✗` + 耗时 + 逐行错误 |
| `M.it_skip(name, reason, depth)` | 23 | 青色 `- 名称 (原因)` |
| `M.summary(passed, failed, total_ms)` | 31 | 汇总；全 0 时输出 `0 tests` |

## `runner.lua`（31 行）

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.run_file(filepath)` | 3 | 加载并执行一个测试文件（`xpcall` 分三段：加载、执行、运行） | 进程退出码：`2` 加载/执行失败、`1` 运行失败、`0` 通过 |

## `cov/`（覆盖率）

### `cov/config.lua`（81 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.get()` | 72 | 取配置单例（首次读环境变量） |
| `M.load()` | 25 | 从 `skynet.getenv` 读 `skytest_cov_output_dir` / `skytest_cov_include` / `skytest_cov_exclude`；`SKYTEST_COV` 环境变量（`0` 视为关） |
| `to_patterns(s)` | 14 | 把 `a,b,c` 或数组统一成模式数组 |

### `cov/collector.lua`（93 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.should_track(source)` | 19 | 该源文件是否计入（include/exclude 模式 + 配置开关） |
| `M.dump(filtered)` | 47 | 导出命中快照（行号 → 次数） |
| `M.merge(other_stats)` | 61 | 合并另一份统计 |
| `M.reset()` | 73 | 清零 |
| `M.register_debug_cmd()` | 77 | 注册 `skynet.debug` 命令，可直接查 dump |
| `M.report_to_central()` | 85 | 把快照 `send` 给集中服务（`config.get().service_name`） |
| `match_patterns(source, patterns)` | 10 | 模式匹配 | — |

### `cov/install.lua`（173 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.setup()` | 109 | 装钩子：确定配置、打协程补丁、探针自检、起 `skytest_cov` 服务、挂退出上报 | 各失败点向 stderr 输出 `WARNING`，**不中断测试** |
| `patch_coroutine_hook()` | 22 | 把 `skynet.fork` 的 `co_create` 上值换掉，让每个新建协程也装 `debug.sethook` | 找不到上值返回 `false, warnings` |
| `new_co_create(f)` | 35 | 包装版协程创建：先 `debug.sethook` 再 resume；装完回读校验 | — |
| `probe_coroutine_hook()` / `probe_fn` | 59 / 64 | 自检：起一个探针协程，确认它确实被统计到（对应行命中数 > 0） | 未执行/零命中都返回 `false, 原因` |
| `install_exit_anchor()` | 97 | 退出前把统计上报一次 | — |
| `find_upvalue(fn, name)` | 8 | 找函数的具名上值 | `nil, nil` 表示找不到 |

装钩子的意思是：**覆盖率靠 `debug.sethook` 逐行计数**，而 skynet 每个服务/协程是新协程，所以必须把 `co_create` 也包一层，否则只有主协程被统计。

### `cov/source_lines.lua`（148 行，算分母）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.scan(source_dirs, exclude_patterns)` | 57 | 扫描源码目录，产出 `baseline`（文件 → 可执行行集合）与 `failures` | **扫描失败的文件必须报上去**：静默跳过等于把整个文件从分母抹掉，覆盖率会因为「编不过」而变好看 |
| `scan_file(filepath)` | 8 | 单个文件的可执行行：用 `hook.proto_lines(f)` 而不是 `debug.getinfo(f,"L").activelines`——后者只有顶层 chunk 的行，嵌套函数体一行都不含，当分母会让覆盖率虚高 | `nil, err` 解析失败 |
| `M.merge_with_stats(baseline, stats)` | 106 | 把命中数叠加到 baseline 上；**分母只由 baseline 决定**，绝不因为「跑到了」就把新行/新文件补进分母（否则每个加载过的文件都是 100%） | 返回 `merged, { unknown_sources, orphan_lines }` 作为配置错漏的诊断 |
| `list_lua_files` / `excluded` / `visit` / `get_cwd_pattern` / `normalize_source` | 16-89 | 目录遍历（排序、跟随目录符号链接、按 exclude 过滤）、路径归一化（Windows 反斜杠） | — |

### `cov/lcov_reporter.lua`（60 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.generate(stats, test_name)` | 3 | 生成 lcov tracefile：`TN:` / `SF:` / `DA:行,次数` / `end_of_record`，文件与行号都排序 | 文本 |
| `M.write(stats, filepath, test_name)` | 49 | 写盘 | `nil, "cannot open …"` |

### `cov/init.lua`（11 行）

覆盖率模块的装载入口：被 `lualib/loader.lua` 用 `pcall(require, "skytest.cov")` 拉起（未部署时静默跳过，模块自身报错不会被吞），内部转调 `cov.install.setup()`。

## 运行方式（与代码对应）

- 单文件：`scripts/skyext.lua test <target>` → `scripts/commands/test.lua` 扫出 `*.test.lua` → 每个文件一个 skynet 进程 → `skytest.runner.run_file`。
- 依赖外部服务的用例命名 `*.integration.test.lua`，需要 `SKYTEST_INTEGRATION=1`，否则跳过。
- 覆盖率：`SKYTEST_COV=1` 装钩子 → 退出上报 → `lcov` tracefile 合并 → 阈值由 `scripts/commands/cov` 判定。
