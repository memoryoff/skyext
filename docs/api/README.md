# `docs/api/` —— 逐文件、逐方法索引

这套文档回答一个问题：**这个仓库里每个 Lua / TS 文件到底干什么，里面每个函数/方法分别做什么、边界在哪。**

它和 `docs/architecture.md` 的分工：

| 文档 | 视角 | 什么时候看 |
| --- | --- | --- |
| `docs/architecture.md` | 鸟瞰：目录、启动链、调用关系、设计取舍 | 想先建立整体印象 |
| `docs/api/`（本目录） | 逐文件：一个文件一张表，方法级 | 已经知道该动哪个文件，或者想知道某能力落在哪 |

## 30 秒上手

**场景 1：我要改 `lualib/skyext/entity/session.lua`**
→ 打开 [02 · 集群、实体与锁](02-engine-cluster-entity.md)，搜 `session.lua`，表里直接列出每个方法的名字、行号、作用、返回与边界。

**场景 2：我要找「断线续接」在哪实现的**
→ 先看本文末尾的[能力 → 文件](#能力--文件速查)，再去对应册。

**场景 3：我想核对文档说的和代码是否一致**
→ 重跑 `_tools/evidence.py`，对比行号（见下节）。表里的行号是**源码起始行**，代码一改就能发现偏移。

## 分册

| 册 | 主题 | 主要覆盖 |
| --- | --- | --- |
| [01](01-lualib.md) | 基础库与加载器 | `lualib/binaryheap.lua`、`lualib/loader.lua`、`lualib/orm/init.lua`、`skyext/binaryheap` |
| [02](02-engine-cluster-entity.md) | 集群、实体、锁、错误码 | `config`、`cmd_api`、`cluster_discovery`、`distributed_lock`、`dbmgr`、`entity/*`（entitymgr / session / reliable_msg / router / types / placement）、`errcode` |
| [03](03-engine-etcd-http-log.md) | etcd、HTTP、日志 | `etcd/*`、`event_channel_api`、`gm_api` / `gm_router`、`hotfix_checksum`、`http_server/*`、`httpc`、`id_generator`、`init.lua`、`log/*`、`machine_id` |
| [04](04-engine-metrics-storage.md) | 指标、存储、租约、区服、配表 | `metrics*`、`mongo_conn`、`node_lease`、`node_shutdown_api`、`orm_compat`、`profiler`、`ptype`、`realm`、`res`、`save_wheel`、`secret`、`snowflake` |
| [05](05-engine-protocol-util.md) | 协议分发、定时器、工具库 | `sproto_api`、`sproto_host`、`time`、`timer`、`util/*` |
| [06](06-skytest.md) | 测试框架 | `lualib/skytest/*`（DSL、断言、HTTP 助手、reporter、runner、`cov/*`） |
| [07](07-cli.md) | CLI 与构建工具 | `scripts/skyext.lua`、`commands/*`、`lib/lcov`、`lib/zip`、`ci/check_paths`、`tools/sproto_orm/*` |
| [08](08-sdk.md) | 客户端 SDK | `sdk/lua/skyext/client/*`、`sdk/ts/src/*` |
| [09](09-service.md) | 引擎服务 | `service/` 25 个非测试服务（含 `logger/` 分层） |
| [10](10-example.md) | 示例游戏层 | `example/` 全部（配置、协议、角色模块、节点入口、跨节点服务、工具） |

## 每篇的行文结构

每个文件固定四段，便于横向比对：

```
## `路径`（N 行，一句话职责）
| 方法 | 行 | 作用 | 返回/边界 |
| 内部函数 / 导出常量 / 模块级约定 |
| 调用方 / 测试 |
```

- **「行」是源码起始行号**（`function M.foo` 所在行），用来直接跳过去。
- 「作用」写的是从代码里能核实的行为，不写猜测的意图。
- 「返回/边界」优先写**失败方式**：断言失败、返回 `nil`、返回错误码、还是静默降级。这是读代码最容易猜错的地方。
- 代码注释里写明的业务理由（比如「续接不验 token，能触发加载就等于开放一个无认证接口」）原样转成说明，不重写。

## `_tools/`：可重跑的抽取脚本

两个脚本都不依赖第三方库，只用标准库，在仓库根目录跑：

```powershell
# Windows PowerShell
$env:PYTHONIOENCODING = "utf-8"
python docs\api\_tools\evidence.py > $env:TEMP\ev2.txt
python docs\api\_tools\extract.py
```

```bash
# Unix / macOS
python3 docs/api/_tools/evidence.py > /tmp/ev2.txt
python3 docs/api/_tools/extract.py
```

| 脚本 | 输出 | 用途 |
| --- | --- | --- |
| `evidence.py` | 每个文件的全部定义：行号、签名、上方 7 行注释、函数体内命中关键字的前 8 条语句 | **写/改本目录文档的事实来源**。当前跑出 `196 files, 1476 defs` |
| `extract.py` | 精简的方法清单骨架 | 只想看「有哪些方法」时用，比 evidence 轻 |
| `verify_docs.py` | 自检：本目录声明的文件行数、表格里的行号是否与实际源码一致 | 改完文档跑一次，退出码 0 才算对齐（见下节） |

`evidence.py` 认这些形态：`function M.foo`、`function M.methods.bar`（多级模块名）、`function M:baz`、`M.foo = function`、`local function`（标 `[internal]`）、`return { a = ... }` 的导出键；TS 侧认 `export function|class|const|interface|type|enum` 与 class 方法。跳过 `*.test.*`、`*fixture.lua`、`*nested.lua`。

**它是正则而不是 AST**：能稳定给出「定义在哪、上面写了什么注释、里面调了什么」，但不理解语义。所以文档里凡是涉及「为什么这么做」的判断，都是在 evidence 输出 + 直接读源码之后写的。

## 覆盖口径（哪些没逐条展开）

- **零定义文件**（纯数据或纯入口）：各 `example/etc/*.conf.lua`、`*.app.lua`、`example/nodes/*/main.lua`、`service/logger/main.lua`、`service/skytest_runner.lua`、`scripts/commands/serve.lua` 等，按「职责 + 关键字段 + 调用关系」写，不硬凑方法表。
- **vendored 文件**：`sdk/ts/src/sproto/sproto.ts`（2075 行）来自上游 sproto 移植，只写对外接口与两处本地补丁（string 按 latin1 字节串、64 位整数用 bigint），不逐函数展开。
- **测试文件**：`*.test.lua` 只在所属模块里提一句，不逐条解释用例。
- **C 源码**（`lualib-src/`、`service-src/`）不在本套范围内。

## 挂到 docsify

本目录是纯 Markdown，docsify 直接可读。要进左侧导航，在 `docs/_sidebar.md` 里加一段（自行决定放在「使用指南」之后）：

```markdown
- **逐文件 API 索引**
  - [总索引](api/README.md)
  - [01 基础库与加载器](api/01-lualib.md)
  - [02 集群与实体](api/02-engine-cluster-entity.md)
  - [03 etcd / HTTP / 日志](api/03-engine-etcd-http-log.md)
  - [04 指标与存储](api/04-engine-metrics-storage.md)
  - [05 协议与工具库](api/05-engine-protocol-util.md)
  - [06 测试框架](api/06-skytest.md)
  - [07 CLI](api/07-cli.md)
  - [08 客户端 SDK](api/08-sdk.md)
  - [09 引擎服务](api/09-service.md)
  - [10 示例游戏层](api/10-example.md)
```

也可以直接用编辑器打开本目录下的 md 文件——不依赖 docsify。

## 代码改了怎么更新

1. 重跑 `evidence.py` 到临时文件。
2. 只看你这轮改过的文件对应的块（脚本按文件输出，块头是 `=== 路径 (N行, M defs) ===`）。
3. 改对应册里的：文件头行数、方法行号、新增/删除的方法行、边界描述。
4. 跑 `python docs\api\_tools\verify_docs.py` 确认行数/行号与实际源码一致（退出码 0）。

不必整册重写——表是按文件独立的，改一个文件只动那一段。行号漂移是判断「文档是否过期」的最快信号，`verify_docs.py` 就是查这个的。

## 能力 → 文件速查

| 想做的事 | 去哪 |
| --- | --- |
| 加一个协议 / 查协议怎么分发 | `05` 的 `sproto_api`、`sproto_host`；下发链在 `02` 的 `entity/session` |
| 查配置怎么读 | `02` 的 `config`、`03` 的 `init.lua` |
| 实体怎么加锁、怎么在节点间迁移 | `02` 的 `entity/*` + `distributed_lock`、`09` 的 `entity_agent` / `entity_agentmgr` |
| 断线续接 | `02` 的 `entity/session`（服务端）、`08` 的 `session`（客户端两端） |
| 定时器 | `05` 的 `timer`；定时回存用 `04` 的 `save_wheel` |
| Mongo 读写 | `04` 的 `mongo_conn`（客户端对象）、`09` 的 `mongo_conn` / `mongo_index`（服务端） |
| 指标暴露 | `04` 的 `metrics*`、`09` 的 `metrics` |
| 日志写到哪 | `03` 的 `log/*`、`09` 的 `logger/*` |
| 停服顺序 | `04` 的 `node_shutdown_api`、`09` 的 `node_shutdown` |
| 热更 | `03` 的 `hotfix_checksum`、`07` 的 `commands/hotfix`、`09` 的 `hotfix` |
| 测试怎么写、覆盖率怎么算 | `06` 全册、`07` 的 `commands/test` |
| 打包发布 | `07` 的 `commands/package`、`lib/zip` |
| 客户端接进来 | `08` 全册、`09` 的 `gate_tcp` / `gate_ws` |
| 开服 / 区服目录 / 网关列表 | `04` 的 `realm`、`09` 的 `realm` |
| ID 生成 | `04` 的 `snowflake`；机器号由 `03` 的 `machine_id` 提供 |
