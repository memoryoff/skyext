# 07 · `scripts/` 与 CLI

> 覆盖 `scripts/skyext.lua`（CLI 入口）、`scripts/commands/`（7 个子命令）、`scripts/lib/`（`lcov`、`zip`）、`scripts/ci/check_paths.lua`、`scripts/tools/sproto_orm/`。
> 入口壳 `bin/skyext`（Unix）与 `bin/skyext.bat`（Windows）只负责定位 `bin/lua`（缺失则退 `lua.exe`）并 `exec` 到 `scripts/skyext.lua`。

## `scripts/skyext.lua`（73 行，命令分发）

没有导出函数，整个文件就是 CLI 主体：

1. 从 `arg[0]` 反推仓库前缀，把 `?.lua` / `lualib/?.lua` / `lualib/?/init.lua` / `skynet/lualib/?.lua` 与 `luaclib/*.so` 前置进 `package.path`/`package.cpath`（L5-12）。
2. 用 `fs.with_dir` 切到前缀目录取绝对 `root`，建 `context = { root, game = root/example, fs, process }`（L16-22）。
3. `commands` 表把命令名映射到模块名：`test` / `serve` / `generate` / `package` / `hotfix` / `cov` / `schema`（L24-32）。
4. `usage()` 打印全部用法（L34-47）；`-h`/`--help`/无参数时打印后返回。
5. 未知命令写 stderr 并 `os.exit(1)`；否则 `xpcall(require("scripts.commands." .. 模块名)(context, command, args))`，异常打完整栈并退 1，正常以命令返回码退出（L66-73）。

## `commands/test.lua`（419 行，跑测试与覆盖率）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `parse(args)` | 16 | 解析 `--match` / `--timeout`（默认 `SKYTEST_TIMEOUT` 或 120 秒）/ `--conf` 与目标列表 | 缺值、未知选项、超时非正数都断言失败 |
| `discover(ctx, options)` | 45 | 把目标展开成 `*.test.lua` 列表：目录就递归 walk，文件就直接用；跳过 `node_modules` 与 `^%.` 开头的目录/文件 | 目标不存在 `error`；结果排序 |
| `temp_config(ctx)` | 92 | 生成 `.skytest_<时间>_<随机>.conf.lua` 到 `example/etc/`，写完即用 | 同名已存在断言失败 |
| `coverage(ctx, dir, run_dir)` | 119 | Lua 覆盖率：收集各进程 tracefile → 合并 → 过滤出工程源码 → 统计 | 没有 tracefile / 没有工程覆盖率数据都断言失败 |
| `run_lcov` / `c_coverage_start` / `c_capture` / `c_coverage` | 160-269 | C 覆盖率：`lcov --zerocounters` 起点、逐目录 capture、合并 | `lcov` 缺失时断言失败并提示 `install lcov and rebuild with make build C_COVERAGE=1` |
| `c_source_filter(root)` | 182 | 只保留工程内源码的 `SF`/`DA` 行（lcov 2.x capture 后不再用它，改用 `scripts/lib/lcov.lua` 合并，见下） | — |
| `c_gcda_dirs` / `c_mirror_gcno` / `c_build_tree_has_gcda` | 216-252 | `GCOV_PREFIX` 数据树按目录逐个 capture；capture 前把 `.gcno` 镜像到数据树（lcov 2.x 要求 gcno/gcda 同目录） | 某目录 gcda 损坏（如进程被 SIGKILL）只跳过该目录并警告，不影响整体 |
| `usage()` | 6 | 用法文本 | — |

为什么 C 覆盖率要逐目录 capture：**多个进程退出时并发合并同一份 `.gcda` 会损坏计数器**（负数计数，lcov 2.x 直接报 `negative`）。所以每个测试进程用 `GCOV_PREFIX` 写进相互隔离的目录，再逐目录采集。

## `commands/serve.lua`（30 行）

| 行为 | 行 | 说明 |
| --- | --- | --- |
| 帮助 | 3-12 | `--help` 时列出 `example/etc/*.conf.lua` 里的可用节点（排除 `core`/`paths`） |
| 解析目标 | 16-20 | 传文件就用绝对路径；否则先当相对 `root` 的路径，再退化成 `example/etc/<名>.conf.lua` |
| 校验 | 17-23 | 配置文件必须存在；`bin/skynet(.exe)` 必须已构建，否则提示 `先执行 make build` |
| 启动 | 24-28 | `process.run({binary, config, ...}, { cwd = ctx.root })`——**工作目录固定为仓库根**，这是 skynet 能加载配置的前提 |

## `commands/generate.lua`（67 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `run_script(path, args)` | 1 | 用空环境 `loadfile` 执行生成脚本 | — |
| `sproto_files(fs, root)` | 10 | 递归取 `*.sproto` | 一个都没有就断言失败 |
| 主函数 | — | `generate proto`：用 `3rd/sprotodump` 把协议编成 `.spb`；`generate schema`：调 `sproto_orm` 生成 `example/build/lualib/game/orm/`（需要 `stylua`） | 只接受 `proto`/`schema` 之一 |

## `commands/package.lua`（275 行，打包）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `package_game(ctx, args)` | 93 | 打 `example/skyext.zip`：游戏层代码 + 引擎运行所需文件，Lua 编译成 `.luac` | 只接受 `package game`（无多余参数） |
| `package_framework(ctx, args)` | 29 | 打 `release-assets/skyext-<platform>.zip` | 平台名必须匹配 `^[%w][%w_-]*$` |
| `publish(fs, path, entries, writer)` | 4 | 先写临时 zip 再 `rename` 覆盖：**打包失败不会留下半个正式包** | 目标不是普通文件断言失败 |
| `add(relative, source, mode)` / `add_tree(directory, relative, accept)` | 100 / 103 | 收集条目，目录递归（目录不存在就跳过） | — |
| `add_compiled(relative, source)` | 112 | 读源码 → `loadfile` → `string.dump` 成 `.luac` 写入临时目录 | 编不过即失败（不打半个包） |
| `sorted_manifest(manifest)` | 18 | 清单按 `relative` 排序，同一份输入打出来的 zip 条目顺序稳定 | — |

framework 包的排除规则（`package_framework` 里逐条判断）：构建/发布产物目录（`build-output`、`release-assets`、`coverage`、`logs`）、`example/dist`、`example/skyext.zip`、`3rd/sprotodump`；游戏顶层按**精确名**排除（`first ~= ".git"` 这种比较，不是 `^%.git` 通配），`3rd` 整目录排除，临时测试配置 `etc/.skytest_*.conf.lua` 也排除。同时收集 `skynet/luaclib`、`skynet/cservice` 的 `.so`。

## `commands/hotfix.lua`（47 行）

| 行为 | 行 | 说明 |
| --- | --- | --- |
| `hotfix refresh <patch-dir>` | — | 重算并回写热更包的 `checksum` / `time`：读 `hotfix.conf.lua`、`load` 成表、调 `hotfix_checksum.compute`、生成新文件 | 目录名不能含 `.`/`..`；只接受 `refresh` 一个子命令 |

## `commands/cov.lua`（78 行）

子命令 `cov merge` / `cov check` / `cov summary` / `cov html`：

| 子命令 | 行为 |
| --- | --- |
| `merge` | 把多个 tracefile 合并成一份（`-o <output>`），输出不能同时是输入 |
| `check` | 按阈值判定：**默认阈值 0，范围限定 0–100**；`found == 0`（没有可比对的源码）或低于阈值都返回 `1` |
| `summary` / `html` | 打印汇总 / 生成 HTML 报告 |

CI（`.github/workflows/coverage.yml`）用的阈值是 85（Lua）与 60（C），比本地默认严。

## `lib/lcov.lua`（100 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.parse(path)` | 5 | 只认 `SF:`（源文件）、`DA:行,次数`、`end_of_record` | `DA` 出现在 `SF` 之前、行号/次数非法都断言失败 |
| `M.merge(files, accept)` | 30 | 多文件合并，`accept(source)` 可过滤 | 合并结果表 |
| `M.stats(sources)` | 45 | 统计 | `files, found, hit` |
| `M.write(path, sources)` | 59 | 写回 tracefile（文件名与行号都排序） | — |
| `M.project_source(source)` | 88 | 保留工程内源码的过滤器（排除 `skynet/`、`3rd/`、`luaclib/` 等外部目录） | 布尔 |

为什么不用 lcov 自带的 merge：lcov 2.x 读 tracefile 时会做函数/行计数一致性校验，`gcov` 数据可能触发 `inconsistent` 报错。这个精简实现只保留 `SF`/`DA`，行为在 1.x/2.x 下一致。

## `lib/zip.lua`（161 行，最小 ZIP 写入器）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.write(path, entries)` | 58 | 写 zip：本地文件头 + 数据 + 中央目录 + EOCD；支持目录条目 | 条目数 `<= 65535`、单文件 `<= 4 GiB`、路径不能为空/绝对/含 `.`/`..`、只支持 file/directory |
| `file_details(path)` | 28 | 取大小与 CRC32（`crc ~ 0xffffffff & 0xffffffff`） | 超 4 GiB 断言失败 |
| `crc32(crc, data)` | 15 | 逐字节 CRC32 | — |
| `dos_date(timestamp)` | 22 | 转 DOS 日期/时间（年份钳在 1980–2107，秒按 2 秒精度） | — |
| `copy_file(path, archive)` | 45 | 分块拷贝进归档 | — |

只写不读（不做压缩），够打包用。

## `ci/check_paths.lua`（262 行，CI 静态检查）

跑法：`lua scripts/ci/check_paths.lua .`。两类检查，任一违例写 stderr 并 `os.exit(1)`。

| 方法 | 行 | 作用 |
| --- | --- | --- |
| 检查一 · 裸名 require | 132-162 | 逐行扫 Lua 代码，注释里的 `require` 不算（跟踪 `--[[ ]]` 块）；抓到 `require "config"` 一类裸名就报告——引擎代码必须用 `skyext.*` 全名，否则会被游戏层同名文件遮蔽 |
| 检查二 · 节点目录名撞服务名 | 206-227 | 扫 `*/nodes/*` 下的节点目录名，与 `service/` 里的服务名比对；撞车会让 `luaservice` 解析到错误文件 |
| `makefile_list(path, varname)` | 67 | 从 Makefile 取 `VAR = a b c` 清单（支持反斜杠续行、跳过 `$(...)` make 变量）：**C 模块一律从 Makefile 声明枚举**，因为 `.so` 是构建产物、CI 里不编译就扫不到，`.so` 扫描只作本地补充 |
| `external_modules()` / `service_names()` / `add_dir(dir)` | 97-208 | 收集外部模块名（`lualib-src/`、`service-src/` 等目录名 + Makefile 声明）与服务名 |
| `popen_lines` / `exists` / `basename` / `report` / `iter_code_lines` | 26-132 | shell 取行（`ls`/`find`）、存在性、去后缀、收集违例、逐行迭代（含块注释状态机） |

## `tools/sproto_orm/`

### `gen_schema.lua`（347 行，sproto → ORM 代码）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `read_file` / `write_file` | 18 / 25 | 读写生成物 | — |
| `interp(s, tab)` | 35 | `${name}` 模板替换 | — |
| `sort_pairs(t, f)` | 41 | 按比较函数产出有序 `k, v` 迭代器（生成代码要稳定） | — |
| `_parse_k_tp` / `_check_k_tp` / `_check_v_tp` | 105-133 | 键/值的类型断言：`integer`/`real`/`string`/`boolean` 各有独立报错 | 类型不符直接 `error`（带实际值与期望值） |
| `parse_k_func` / `check_k_func` / `check_kv_func` | 160-172 | 按期望类型生成解析/校验闭包 | — |
| `parse_k` / `check_k` / `check_kv` | 179-194 | 实例方法：缺键报 `not exist key: …` | 运行期校验用 |
| `typename(t)` | 268 | 类型名映射（`schema_number` 等） | — |
| 生成主体 | 194-347 | 为每个结构生成 `schema_<name>` / `<name>_fields` / `orm.new(...)`，map/array 生成 `schema_map_<kv>` / `schema_arr_<v>`；**禁用字段名与重复对象名都直接断言失败** | — |

### `sproto2lua.lua`（96 行，schema 定义导出）

纯脚本（无导出函数）：`arg[1]` 是输出文件、其余是 `.sproto` 输入；用 `3rd/sprotodump` 的 `core.gen_trunk` 解析，把 `build.type` 里非协议的结构转成 `{ 结构名 = { 字段 = { type = … } } }`（`array` 带 `item`、`map` 带 `key`/`value`），用 `serpent.block` 序列化后写成 `-- Code generated from …` 开头的 `return <表>` 文件。

这就是 `example/build/lualib/game/orm/` 下生成物的来源；`orm_compat.diff` 拿它和 `schema.lock.lua` 比对。
