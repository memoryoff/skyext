# 01 · `lualib/` 基础设施：binaryheap、loader、ORM

> 覆盖 `lualib/binaryheap.lua`、`lualib/loader.lua`、`lualib/orm/init.lua`、`lualib/skyext/binaryheap.lua`。
> 第二列是源码起始行号，编辑器按行跳转即可。

## `lualib/binaryheap.lua`（406 行，vendored）

上游 binaryheap 0.4（由 `build.mk` 从 `3rd/binaryheap.lua/src/binaryheap.lua` 拷入），`skyext.timer` 的底层容器。它提供两类堆：**普通堆**（每个元素一个值）与 **唯一堆**（值 + 唯一 payload，删除按 payload 定位）。

### 构造

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.binaryHeap(swap, erase, lt)` | 61 | 底层构造器：传入交换/删除回调和比较函数，返回带 `bubbleUp`/`sinkDown` 的堆对象 |
| `M.minHeap(lt)` | 220 | 新建最小堆（默认 `a < b`） |
| `M.maxHeap(gt)` | 230 | 新建最大堆（默认 `a > b`） |
| `M.minUnique(lt)` | 385 | 新建带唯一 payload 的最小堆；`skyext.timer` 用的就是这个 |
| `M.maxUnique(gt)` | 399 | 新建带唯一 payload 的最大堆 |

### 堆对象方法

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `heap:insert(value)` | 161 | 插入并上浮 | `nil` 值断言失败 |
| `heap:update(pos, newValue)` | 120 | 改指定位置的值，再上浮/下沉修复 | `pos` 越界断言失败 |
| `heap:remove(pos)` | 133 | 删指定位置：与末位交换后修复 | `pos` 非法返回 `nil` |
| `heap:pop()` | 172 | 弹出堆顶 | 空堆返回 `nil` |
| `heap:peek()` | 182 | 只看堆顶 | 空堆返回 `nil` |
| `heap:size()` | 190 | 元素个数 | — |
| `heap:bubbleUp(pos)` / `heap:sinkDown(pos)` | 70 / 82 | 修复堆序的两个原语 | — |
| `unique:insert(value, payload)` / `:update(payload, value)` / `:remove(payload)` / `:pop()` / `:peek()` / `:peekValue()` / `:valueByPayload(payload)` | 266 / 256 / 280 / 296 / 308 / 316 / 330 | 唯一堆版本：**管理函数一律按 payload 定位**，value 只用于排序 | payload 重复会断言失败 |

## `lualib/loader.lua`（91 行，每个服务的启动 chunk）

没有命名导出函数，整个文件就是 `snlua` 加载服务时执行的脚本。执行顺序：

1. 读全局 `SERVICE_ARGS`，按空白切成 `args`；`SERVICE_NAME = args[1]` 去掉 `:后面的部分`（L1-12）。
2. 按全局 `LUA_SERVICE`（来自 `paths.conf.lua` 的 `luaservice`）逐条 `loadfile`，`?` 替换成服务名，第一个存在的就是入口；全失败时把所有错误拼起来抛出（L16-31）。
3. 把 `LUA_PATH`/`LUA_CPATH` 落成 `package.path`/`package.cpath`，清掉全局；从命中的模式里推出 `SERVICE_PATH`（服务所在目录）（L33-44）。
4. 三次 `package.path` 前置，优先级从高到低：**服务独有库 `SERVICE_PATH<SERVICE_NAME>/lualib/` → 服务所在目录 → 节点独有库 `nodes/<start>/lualib/`**（原有的游戏库/引擎库/skynet 库留在后面）（L55-80）。
5. `pcall(require, "skytest.cov")`：覆盖率钩子没部署时静默跳过，**模块自身报错不会被吞**（L83-86）。
6. `require "skyext"`（失败直接抛，由 snlua 的 traceback 处理器打完整堆栈），最后 `main(select(2, table.unpack(args)))` 调用服务入口（L89-91）。

注意开头的注释：**不要覆盖 `_G.error`**——snlua 把 traceback 函数当消息处理器调用本文件，loader 顶层抛错天然带完整调用栈。

## `lualib/orm/init.lua`（460 行，ORM 文档代理）

一个 ORM 文档是「`__stage` 存放真实字段 + 元表代理」的对象：读走代理、写经 `doc_change` 标脏并递增 `__revision`，落库时只导出脏字段。

### 导出 API

| 方法 | 行 | 作用 | 返回 / 边界 |
| --- | --- | --- | --- |
| `orm.new(schema, init)` | 278 | 按 schema 建文档（`init` 是普通表，不能是另一个 orm 文档） | 文档对象；`__revision = 0` |
| `orm.decode(schema, init)` | 357 | 用当前 schema 解码库里的旧文档：**多出的字段丢掉、缺的字段补零值**，补出来的值不算脏 | `doc, dropped`；`dropped` 是排序后的被丢字段路径 |
| `orm.to_bson(value)` | 195 | 递归转成纯 BSON 表，脱离 ORM 代理；array 打专用元表 | 新表；循环引用直接 `error("cannot encode circular table")` |
| `orm.snapshot_mongo(doc)` | 373 | 生成 `$set` 增量快照 | `is_dirty, update, revision` |
| `orm.ack_mongo(doc, revision, version)` | 395 | 写库成功后确认：`revision` 未变则清脏 | `unchanged`（布尔） |
| `orm.is_dirty(doc)` | 406 | 是否有未落库改动 | 布尔 |
| `orm.clone(doc)` | 410 | 克隆文档（同 schema，独立副本） | 新文档 |
| `orm.is_orm(doc)` | 414 | 是否 ORM 文档 | 布尔 |
| `orm.check_type(doc)` | 365 | 类型自检（递归校验字段类型） | `false` 或 `true` |
| `orm.reload_schema(old_schema, new_schema)` | 423 | **就地热重载**：保持 `old_schema` 及每个 schema_obj 的引用不变（进程里所有 doc 的类型判定和生成代码的闭包都持有它们） | `orm`；两张表必须是不同表，传同一张会把类型定义清空 |
| `orm.next` / `orm.unpack` / `orm.concat` / `orm.insert` / `orm.remove` | 453-457 | `next`/`table.unpack`/`table.concat`/`table.insert`/`table.remove` 在 ORM 文档上的显式版本（分别是 `doc_next` 等的别名）。**全局 `next`/`table.*` 不再被覆盖**，遍历 ORM 文档必须用这组接口 | 同标准库语义 |

### 内部实现

| 函数 | 行 | 作用 |
| --- | --- | --- |
| `doc_len` / `doc_next` / `doc_pairs` / `doc_ipairs` / `doc_unpack` / `doc_concat` | 16-36 | `#`、`next`、`pairs`、`ipairs`、`table.unpack`、`table.concat` 的代理版本，都作用在 `doc.__stage` |
| `mark_dirty(doc)` | 40 | `__revision + 1` 并置脏标记 |
| `doc_change_value` / `doc_change_recursively` / `doc_change` | 48-80 | 赋值的三条路径：标量、容器递归、通用入口；禁止把非根节点挂到别的对象上 |
| `doc_totable(object)` | 92 | 深转普通表；遇到环报 `not support circular reference` |
| `_copy` / `_clone_doc` | 94 / 112 | 递归复制；`_clone_doc` 只接受 orm 文档 |
| `doc_insert` / `doc_remove` | 119 / 147 | `table.insert`/`table.remove` 语义的代理，位置必须是整数且在界内 |
| `copy_bson` | 175 | `to_bson` 的实现体：按 schema 类型决定 array 元表，环检测 |
| `_clear_dirty(doc, watched)` | 260 | 递归清脏；`watched` 防环（真出现环直接报 `why orm has circular reference`） |
| `is_container(schema)` | 286 | `map` / `array` 判定 |
| `zero_value(schema, path, dropped, seen)` | 293 | 给旧文档缺的字段补零值（数字 0、字符串 `""`、容器 `{}`、可选字段 `nil`） |
| `sub_path(path, k)` | 310 | 拼字段路径，供 `dropped` 与错误信息使用 |

## `lualib/skyext/binaryheap.lua`（14 行）

引擎自用的堆副本，**不写 `require "binaryheap"`**：`paths.conf.lua` 把游戏库排在引擎库之前，游戏层放一个同名文件就能顶替它，而它是 `skyext.timer` 的底座（定时器又是锁心跳、回存轮、实体卸载重试的底座）。做法是按 `skyext_root` 拼**绝对路径** `loadfile`，绕开 `package.path`，保持单一副本。

| 行为 | 行 | 说明 |
| --- | --- | --- |
| `local chunk = assert(loadfile(path))` | 13 | 路径 = `skynet.getenv("skyext_root") or "./"` + `lualib/binaryheap.lua` |
| `return chunk()` | 14 | 加载 vendored 堆并原样返回 |
