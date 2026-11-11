# 架构与目录索引

> 本文回答两个问题：**代码放在哪**、**每个目录/文件负责什么**。运行机制、节点协作与部署形态见[架构概览](overview.md)；安装、构建与排错见[快速上手](getting-started.md)。
>
> 以仓库中的实现、配置与测试为准。`docs/design/`、`docs/plan/`、`docs/archive/` 里的提案和记录描述的是写作当时的状态，不代表当前能力。
>
> 维护约定：新增、删除、改名目录或文件时同步更新本文对应表格；只写代码里能核实的作用，不把规划写成现状。

## 1. 一句话架构

skyext 是跑在 [skynet](https://github.com/cloudwu/skynet) 上的分布式游戏服务器**引擎**：`lualib/skyext/` 提供配置、日志、etcd、实体、会话、协议、HTTP、GM、指标等通用库；`service/` 是这些库对应的 skynet 服务；`example/` 是用引擎写的一个完整示例游戏（Account / Role / Gateway / Robot 四类节点）；`sdk/` 是客户端双实现；`scripts/` 与 `bin/` 是统一 CLI。

数据面大致是：客户端 SDK → 网关（`service/gate_tcp.lua` / `service/gate_ws.lua`）→ 实体（`service/entity_agent*.lua` + `lualib/skyext/entity/`）→ ORM（`lualib/orm/`）→ MongoDB；etcd 负责节点租约、服务发现、实体锁与区服目录。

## 2. 分层与依赖方向

| 层级 | 路径 | 职责 |
| --- | --- | --- |
| 引擎库 | `lualib/skyext/`、`lualib/orm/`、`lualib/skytest/` | 通用能力，`skyext.*` 命名空间；不 require 游戏模块 |
| 引擎服务 | `service/` | 网关、实体、集群、存储、GM、热更、指标、日志 |
| 原生扩展 | `lualib-src/`、`service-src/`、`build.mk` | Lua C 模块与 C 服务 |
| 游戏层（示例） | `example/` | 节点入口、业务模块、登录/运营服务、配置、协议、schema |
| 客户端 | `sdk/lua/`、`sdk/ts/` | 与服务端无进程关系，只经 TCP/WebSocket 接入 |
| 工具 | `scripts/`、`bin/` | CLI：test / serve / generate / package / hotfix / cov / schema |
| 依赖 | `skynet/`、`3rd/` | Git submodule，不在此层做二次修改 |

依赖只向下：游戏层通过扩展点（实体 handler、GM 命令、HTTP 路由、停服钩子）与 `require "skyext.*"` 使用引擎；引擎不反向 require 游戏代码。

### 2.1 模块搜索优先级

`example/etc/paths.conf.lua` 定义 `lua_path`，`lualib/loader.lua` 启动时再前置两类路径，最终由高到低：

1. 服务独有库 `<service_path>/<service_name>/lualib/`
2. 服务所在目录（服务 chunk 根）
3. 节点独有库 `example/nodes/<start>/lualib/`
4. 节点根目录 `example/nodes/<start>/`
5. 游戏公共库 `example/lualib/`
6. 游戏生成物 `example/build/lualib/`（ORM schema 产物，Git 忽略）
7. 客户端 SDK `sdk/lua/`
8. 引擎库 `lualib/`
9. skynet 库 `skynet/lualib/`

所以引擎代码一律写 `require "skyext.xxx"`，避免被同名游戏模块静默顶替；`scripts/ci/check_paths.lua` 在 CI 里检查这条规则。

### 2.2 启动链

正常入口是 CLI（实现见 9.5）。`serve` 本身不做服务端初始化，只是以仓库根为 cwd 启动 skynet：

```bash
./bin/skyext serve account1

# serve 启动时只做三件事：把节点名解析成 example/etc/account1.conf.lua、
# 检查 bin/skynet 存在、以仓库根为 cwd 启动它（额外参数原样透传）。
# 所以在仓库根执行下面这条，服务进程的行为与上面完全相同：
./bin/skynet example/etc/account1.conf.lua
```

`serve` 不注入环境变量、不改写配置、也不在服务端做任何额外初始化——配置加载、bootstrap、loader、配置/日志初始化都在 skynet 与 conf/loader 里完成。跳过它只省掉节点名简写、错误提示和「cwd 必须是仓库根」这层保证；换个目录手跑 `./bin/skynet` 就会因为 `root = "./"` 而找不到文件。

进程内的顺序：

1. skynet 读 `example/etc/account1.conf.lua`：得到 `start = "account"` 与 `app_config_path`，再 `include "core.conf.lua"` 定义 `root = "./"`、`skyext_root`、`game_root`，并由它 `include "paths.conf.lua"` 配好 `lua_path`、`luaservice`、`lualoader`、`lua_cpath`、`cpath`。
2. `bootstrap = "snlua bootstrap"` 先起 bootstrap 服务；它用 `start` 的值调 `skynet.newservice(start)`，`account` 因此成为本进程的第一个业务服务。
3. 新服务由 snlua 按 `lualoader = skyext_root .. "lualib/loader.lua"` 加载：loader 按 `luaservice` 的通配模式找到 `example/nodes/account/main.lua`，把 `package.path` 重排成「服务目录 → 节点目录 → 游戏库 → 引擎库 → skynet 库」（完整顺序见 2.1），再 `require "skyext"`。
4. `require "skyext"` 落到 `lualib/skyext/init.lua`：它只**注册** `skynet.init` 回调，此时不执行——回调里是 `skyext.config.init()`（读 `app_config_path` 指向的应用配置并 `setenv`，`app_config_loaded` 保证同一进程的多个服务只读一次）与 `skyext.log.init()`（按 `log_*` 配置初始化日志）。
5. loader 随后调用服务入口 `main(...)`；入口里的 `skynet.start(fn)` 由 skynet 在首个调度周期执行：先跑 `init_all()`（即第 4 步注册的配置与日志初始化），再执行 `fn`。节点在 `fn` 里拉起 HTTP、实体、网关等服务；引擎服务链路相同，只是入口换成 `service/<name>.lua`。

注意 `start` 一处配置、三处使用：bootstrap 用它选首个服务，`paths.conf.lua` 用它拼 `luaservice` 通配（`nodes/<start>/...`），loader 用它前置节点独有库（`nodes/<start>/lualib/`）。改节点目录名时三处要一起对上。

## 3. 顶层目录

| 目录 | 作用 |
| --- | --- |
| `.github/` | GitHub Actions：构建发布、CI 测试与文档站部署、Lua 检查 |
| `3rd/` | 第三方 submodule：lua-cjson、binaryheap.lua、luafilesystem、sprotodump |
| `bin/` | 构建产物与 CLI 入口脚本；除两个脚本外全部 Git 忽略 |
| `docs/` | 使用指南、设计记录、规划、归档与 docsify 站点入口 |
| `example/` | 示例游戏：节点、业务代码、配置、协议、schema、配表、热更包、联调工具 |
| `lualib/` | 引擎 Lua 库：`skyext/`、`orm/`、`skytest/`、`loader.lua`、`binaryheap.lua` |
| `lualib-src/` | Lua C 模块源码（traceback、crypto、tool_process、profiler、skytest hook） |
| `public/` | 静态资源（GM 单页面板） |
| `scripts/` | CLI 的 Lua 实现、覆盖率/打包/生成工具、CI 路径检查、sproto_orm 生成器 |
| `sdk/` | 客户端 SDK 双实现：Lua（`skyext.client.*`）与 TypeScript |
| `service/` | 引擎 skynet 服务 |
| `service-src/` | C 服务源码（profiler 骨架） |
| `skynet/` | skynet 运行时 submodule（含 Lua 5.5、ltls 等） |

## 4. 根目录文件

| 文件 | 作用 |
| --- | --- |
| `.gitattributes` | 行尾属性：`bin/*.bat` 固定 CRLF |
| `.gitignore` | 忽略构建产物（`bin/*` 除两个入口、`luaclib/`、`cservice/`、`example/build/`、`logs/`、`release-assets/` 等） |
| `.gitmodules` | 7 个 submodule 的路径与地址 |
| `.luacheckrc` | Luacheck 配置：`std = "max"`、skynet 全局变量白名单、排除 `3rd/`、`etc/`、`example/etc/`、`skynet/` |
| `.stylua.toml` | StyLua 格式规则：120 列、4 空格、Unix 换行、优先双引号 |
| `.styluaignore` | StyLua 忽略 `skynet/`、`3rd/` 与 vendored 的 `lualib/binaryheap.lua` |
| `AGENTS.md` | 面向 AI/贡献者的编码约定：项目边界、模块加载、构建验证、提交规范 |
| `LICENSE` | MIT 许可证 |
| `Makefile` | 顶层快捷入口：`make init`（拉 submodule）、`make build`（转 `example/`） |
| `README.md` | 项目介绍、能力清单、快速体验、目录职责、验证命令、文档导航 |
| `build.mk` | 引擎构建规则：skynet、C 模块（cjson/lfs/crypto/tool_process/traceback/profiler）、skytest hook、C 服务、mingw 交叉编译、覆盖率插桩 |

## 5. `bin/`

| 文件 | 作用 |
| --- | --- |
| `bin/skyext` | POSIX sh 入口：定位自身目录，用构建出的 `bin/lua` 执行 `scripts/skyext.lua` |
| `bin/skyext.bat` | Windows CMD/PowerShell 入口，同上（CRLF） |

构建后还会生成（Git 忽略）`bin/skynet`、`bin/lua`、`bin/luac` 等运行时文件，见第 15 节。

## 6. `lualib/` 引擎库

| 文件/目录 | 作用 |
| --- | --- |
| `lualib/loader.lua` | 每个服务的启动器：解析 `SERVICE_NAME`/`SERVICE_ARGS`、按 `LUA_SERVICE` 找到入口文件、重排 `package.path`、可选加载覆盖率钩子、`require "skyext"`，最后执行服务入口 |
| `lualib/binaryheap.lua` | 二叉堆实现，由 `build.mk` 从 `3rd/binaryheap.lua/src/binaryheap.lua` 拷贝而来；`skyext.timer` 的底层容器 |
| `lualib/orm/` | ORM 运行时（见 6.9） |
| `lualib/skytest/` | 测试框架与覆盖率（见 6.10） |
| `lualib/skyext/` | 引擎主命名空间（见 6.1–6.8） |

### 6.1 `skyext` 入口与基础运行时

| 文件 | 作用 |
| --- | --- |
| `lualib/skyext/init.lua` | `require "skyext"` 的落点：注册 `skynet.init` 回调，初始化配置与日志；有意不覆盖全局 `next`/`table.*` |
| `lualib/skyext/config.lua` | 应用配置读取：`get`/`get_boolean`/`get_number`/`get_table`、`serialize`、`init`；支持 `include` 链式加载 |
| `lualib/skyext/time.lua` | 时间封装：`now`（skynet 1/100 秒刻度）、`time`（秒）、`now_ms`（毫秒）、`format` |
| `lualib/skyext/timer.lua` | 秒级定时器：最小堆 + 单协程唤醒；导出 `timeout`/`repeat_immediately`/`repeat_delayed`/`repeat_random_delayed`，句柄上有 `cancel`/`wakeup`，另有 `active_count`/`shutdown` |
| `lualib/skyext/ptype.lua` | 只定义 skyext 自用的 log 协议段：`PTYPE_LOG = 128` / `PTYPE_LOG_ERR = 129`（`[0, 128)` 留给 skynet） |
| `lualib/skyext/errcode.lua` | 引擎错误码常量：`OK`、`IN_OTHER_NODE`、`LOCK_FAILED`、`DB_ERROR`、`PARAM_ERROR`、`AUTH_FAILED`、`ENTITY_*`、`SESSION_CLOSED`、`RESUME_UNAVAILABLE`、`REQUEST_*`、`MONGO_DUPLICATE_KEY` |
| `lualib/skyext/secret.lua` | 密钥/口令强度校验：示例默认值黑名单与统一判定入口 |
| `lualib/skyext/snowflake.lua` | snowflake ID 服务：`CMD.newid`/`newids`、`CMD.shutdown` 归还机器号 |
| `lualib/skyext/id_generator.lua` | ID 生成客户端：本地缓存池、批量预取、`newid`/`newids` |
| `lualib/skyext/machine_id.lua` | 机器号槽位：向 etcd 抢一个带租约的编号，供 snowflake 使用 |
| `lualib/skyext/binaryheap.lua` | 引擎自用堆副本，按绝对路径加载，避免被游戏层同名文件顶替 |
| `lualib/skyext/init.test.lua` | `skyext.init` 的测试 |
| `lualib/skyext/config.test.lua` | 配置读取/`include` 测试 |
| `lualib/skyext/errcode.test.lua` | 错误码常量测试 |
| `lualib/skyext/id_generator.test.lua` | ID 缓存池测试 |
| `lualib/skyext/ptype.test.lua` | 协议号测试 |
| `lualib/skyext/secret.test.lua` | 密钥强度校验测试 |
| `lualib/skyext/snowflake.test.lua` | snowflake 服务测试 |
| `lualib/skyext/time.test.lua` | 时间封装测试 |
| `lualib/skyext/timer.test.lua` | 定时器测试 |

### 6.2 日志

| 文件 | 作用 |
| --- | --- |
| `lualib/skyext/log/init.lua` | 默认 logger 门面（`debug`/`info`/`warn`/`error`/`sys_*`）与按配置初始化 |
| `lualib/skyext/log/logger.lua` | logger 对象：级别过滤、来源/表展开、多 bucket 分发、`xpcall` 封装 |
| `lualib/skyext/log/formatter.lua` | 日志行格式化（时间、级别、来源、内容） |
| `lualib/skyext/log/log_level.lua` | 等级常量与优先级 |
| `lualib/skyext/log/util.lua` | 日志参数与等级解析辅助 |
| `lualib/skyext/log/bucket/init.lua` | 按名字动态加载 bucket 实现，默认 `console` |
| `lualib/skyext/log/bucket/console.lua` | 输出到屏幕 |
| `lualib/skyext/log/bucket/file.lua` | 输出到文件，支持按 size/line/day/hour 切分 |
| `lualib/skyext/log/bucket/service.lua` | 把日志推送到独立的 logger 服务（跨进程集中输出） |
| `lualib/skyext/log/logger.test.lua` | logger 单元测试 |
| `lualib/skyext/log/formatter.test.lua` | 格式化单元测试 |
| `lualib/skyext/log/log_level.test.lua` | 等级工具测试 |
| `lualib/skyext/log/bucket/file.test.lua` | 文件 bucket 单元测试 |

### 6.3 etcd 与集群

| 文件 | 作用 |
| --- | --- |
| `lualib/skyext/etcd/init.lua` | etcd v3 客户端（HTTP gRPC-gateway）：构造客户端并聚合各子模块方法 |
| `lualib/skyext/etcd/transport.lua` | 传输层：端点解析、故障端点摘除、单请求内换端点重试 |
| `lualib/skyext/etcd/auth.lua` | JWT 鉴权与提前刷新（3 分钟 + 随机抖动，避免多 worker 同时刷新） |
| `lualib/skyext/etcd/codec.lua` | key/value 的 base64 与 JSON 编解码规则 |
| `lualib/skyext/etcd/kv.lua` | KV 读写、前缀（目录）读写、事务 |
| `lualib/skyext/etcd/lease.lua` | 租约申请/续租/撤销；租约 ID 按字符串透传避免 int64 丢精度 |
| `lualib/skyext/etcd/watch.lua` | watch 事件流：HTTP chunked、可关闭对象、每次调用读一批事件 |
| `lualib/skyext/node_lease.lua` | `service/node_lease` 的客户端：节点租约本地只读视图与失效通知 |
| `lualib/skyext/distributed_lock.lua` | 基于 etcd 的实体锁，fencing token 用锁键的 create_revision |
| `lualib/skyext/cluster_discovery.lua` | 服务发现客户端：注册/注销服务、按服务名取存活节点、随机挑节点、变更回调 |
| `lualib/skyext/realm.lua` | 区服目录查询端：server → game → zone 与网关列表，内存快照 + 变更广播 |
| `lualib/skyext/etcd/auth.test.lua` | JWT 鉴权与刷新测试 |
| `lualib/skyext/etcd/codec.test.lua` | base64/JSON 编解码测试 |
| `lualib/skyext/etcd/init.test.lua` | 客户端构造与聚合测试 |
| `lualib/skyext/etcd/kv.test.lua` | KV/目录/事务测试 |
| `lualib/skyext/etcd/lease.test.lua` | 租约测试 |
| `lualib/skyext/etcd/transport.test.lua` | 端点/重试测试 |
| `lualib/skyext/etcd/watch.test.lua` | watch 流测试 |
| `lualib/skyext/cluster_discovery.test.lua` | 服务发现客户端测试 |
| `lualib/skyext/distributed_lock.test.lua` | 实体锁测试 |
| `lualib/skyext/realm.test.lua` | 区服目录查询端测试 |
| `lualib/skyext/machine_id.test.lua` | 机器号槽位单元测试（mock etcd） |
| `lualib/skyext/machine_id.integration.test.lua` | 机器号槽位集成测试（真 etcd，需 `SKYTEST_INTEGRATION=1`） |

### 6.4 实体与会话

| 文件 | 作用 |
| --- | --- |
| `lualib/skyext/entity/types.lua` | 实体类型注册表：读取 `entity_types` 配置、ID 计算、agent 分片、`scoped_id`、预加载 ID、服务名格式 |
| `lualib/skyext/entity/placement.lua` | 实体放置：把服务发现的存活节点接到路由上，用 rendezvous hashing（HRW）选节点 |
| `lualib/skyext/entity/router.lua` | 实体调用门面（8 个导出）：`call`/`send`/`poke_reliable`/`bind_session`/`resume_session`/`scoped_call`/`scoped_send`/`reliable_send` |
| `lualib/skyext/entity/entitymgr.lua` | 单个实体的运行时：加载/卸载、加锁、模块与 handler 生命周期、实体定时器、可靠消息投递排队 |
| `lualib/skyext/entity/reliable_msg.lua` | 可靠消息（at-least-once）：落库、seq 分配、重试、毒消息转死信 |
| `lualib/skyext/entity/session.lua` | 实体侧客户端会话：连接（`entity.session`）与会话（`entity.session_io`）分离、下行重放、上行幂等缓存、续接 |
| `lualib/skyext/entity/types.test.lua` | 实体类型/ID/分片测试 |
| `lualib/skyext/entity/placement.test.lua` | HRW 放置测试 |
| `lualib/skyext/entity/router.test.lua` | 路由/粘性转发测试 |
| `lualib/skyext/entity/entitymgr.test.lua` | 实体生命周期与消息投递测试 |
| `lualib/skyext/entity/reliable_msg.test.lua` | 可靠消息单元测试 |
| `lualib/skyext/entity/reliable_msg.integration.test.lua` | 可靠消息集成测试（真 MongoDB） |
| `lualib/skyext/entity/session.test.lua` | 会话/续接/重放测试 |
| `lualib/skyext/entity/persistence.integration.test.lua` | 实体持久化集成测试（真 MongoDB） |

### 6.5 持久化与 schema

| 文件 | 作用 |
| --- | --- |
| `lualib/skyext/dbmgr.lua` | 数据管理器：ORM 对象加载/缓存、脏跟踪、行锁与 fence、按回存轮写入 MongoDB |
| `lualib/skyext/save_wheel.lua` | 回存轮：一个定时器把条目摊到多个槽轮转刷库，慢写不阻塞其他定时任务 |
| `lualib/skyext/mongo_conn.lua` | MongoDB 客户端封装（8 个）：连接/集合、`find`/`find_many`（带 `sort`/`skip`/`limit`，多字段排序必须用数组形式）/`find_one`/`find_and_modify`/`safe_insert`/`safe_update`/`safe_delete`/`create_index` |
| `lualib/skyext/orm_compat.lua` | schema 兼容性比较：拦改类型、改名、重用已删字段名 |
| `lualib/skyext/dbmgr.test.lua` | 数据管理器单元测试 |
| `lualib/skyext/save_wheel.test.lua` | 回存轮单元测试 |
| `lualib/skyext/mongo_conn.test.lua` | MongoDB 封装测试（mock） |
| `lualib/skyext/orm_compat.test.lua` | schema 兼容比较测试 |

### 6.6 HTTP、GM 与应用服务

| 文件 | 作用 |
| --- | --- |
| `lualib/skyext/http_server/init.lua` | HTTP 服务器门面：按名字创建独立实例（watchdog + agent + 路由表），`start`/`register_router`/`stats` |
| `lualib/skyext/http_server/watchdog.lua` | 监听与 accept、agent 池管理、连接上限、统计 |
| `lualib/skyext/http_server/agent.lua` | 单连接处理：HTTP 解析、keep-alive、路由分发、响应写回 |
| `lualib/skyext/http_server/limits.lua` | 连接数/读写超时/keep-alive/body 上限的配置解析与默认值 |
| `lualib/skyext/http_server/deadline.lua` | 连接读写超时守卫：到点 shutdown fd，打断阻塞读写 |
| `lualib/skyext/http_server/fixtures/public_router.lua` | 测试用公开路由 |
| `lualib/skyext/http_server/fixtures/admin_router.lua` | 测试用管理路由 |
| `lualib/skyext/httpc.lua` | `httpc.post_json` 便捷封装 |
| `lualib/skyext/gm_api.lua` | 业务侧 GM 命令注册（`register`/`unregister`/`execute_command`） |
| `lualib/skyext/gm_router.lua` | GM HTTP 路由：鉴权、参数解析、转发给 `.gm` |
| `lualib/skyext/cmd_api.lua` | `skynet.dispatch("lua")` 统一封装：合并 CMD 表、登记指标、`dispatch`/`dispatch_socket` |
| `lualib/skyext/event_channel_api.lua` | 服务间事件通道：`subscribe`/`publish` |
| `lualib/skyext/node_shutdown_api.lua` | 停服钩子注册（`stop_accepting`/`release`），流程在 `service/node_shutdown.lua` |
| `lualib/skyext/http_server/init.test.lua` | HTTP 服务器门面测试 |
| `lualib/skyext/http_server/limits.test.lua` | 上限解析测试 |
| `lualib/skyext/http_server/deadline.test.lua` | 超时守卫测试 |
| `lualib/skyext/http_server/resource.test.lua` | 连接/资源上限的集成式测试 |
| `lualib/skyext/httpc.test.lua` | httpc 封装测试 |
| `lualib/skyext/gm_api.test.lua` | GM 命令注册测试 |
| `lualib/skyext/gm_router.test.lua` | GM HTTP 路由测试 |
| `lualib/skyext/cmd_api.test.lua` | CMD 分发测试 |
| `lualib/skyext/event_channel_api.test.lua` | 事件通道测试 |

### 6.7 指标与观测

| 文件 | 作用 |
| --- | --- |
| `lualib/skyext/metrics.lua` | 进程内指标原语：counter/gauge/histogram，纯内存自增 |
| `lualib/skyext/metrics_api.lua` | 把当前服务挂到 `.metrics`，抓取时被统一拉取 |
| `lualib/skyext/metrics_merge.lua` | 合并各服务上报的指标快照（同名同标签相加） |
| `lualib/skyext/metrics_router.lua` | Prometheus 抓取 HTTP 路由（转发到 `.metrics` 统一渲染） |
| `lualib/skyext/metrics_text.lua` | 渲染 Prometheus 文本格式（`text/plain; version=0.0.4`） |
| `lualib/skyext/profiler.lua` | Lua 层采样原型（GM 命令注册；默认不加载） |
| `lualib/skyext/metrics.test.lua` | 指标原语测试 |
| `lualib/skyext/metrics_api.test.lua` | 指标注册测试 |
| `lualib/skyext/metrics_merge.test.lua` | 合并逻辑测试 |
| `lualib/skyext/metrics_router.test.lua` | 抓取路由测试 |
| `lualib/skyext/metrics_text.test.lua` | 文本渲染测试 |
| `lualib/skyext/profiler.test.lua` | 采样原型测试 |

### 6.8 协议、配表与热更

| 文件 | 作用 |
| --- | --- |
| `lualib/skyext/sproto_api.lua` | sproto 请求注册/分发/回包、错误码映射、断连处理 |
| `lualib/skyext/sproto_host.lua` | 自带 sproto host：`dispatch` 把客户端 request id 作为第 5 个返回值暴露，供上行幂等缓存使用 |
| `lualib/skyext/res.lua` | 策划配表加载与热重载（`sharetable`），供业务模块读取 |
| `lualib/skyext/hotfix_checksum.lua` | 热更包 checksum 计算与校验 |
| `lualib/skyext/sproto_api.test.lua` | 协议分发表测试 |
| `lualib/skyext/sproto_host.test.lua` | sproto host 测试 |
| `lualib/skyext/res.test.lua` | 配表加载/重载测试 |
| `lualib/skyext/hotfix_checksum.test.lua` | 热更 checksum 测试 |

### 6.9 `skyext.util`

五个无状态小工具，全部是 `local M = {} … return M` 形式，**不依赖 skynet**，所以在服务进程、测试进程、CLI 的裸 Lua 里都能直接用（`scripts/skyext.lua` 就运行在 skynet 之外）。它们只做「把路径/文件/表/字符串处理好」，不含业务语义。

共同约定：

- 路径分隔符在模块加载时由 `package.config` 取一次：Windows 为 `\`，Unix 为 `/`。
- 工程文件操作走 `fs`，失败用 `assert` 直接抛出（调用方是 CLI、打包、热更，失败即中止比返回 `nil` 更容易暴露）；面向外部输入的读写走 `io`，返回 `nil/false` 让调用方转成提示。
- `fs` 依赖 C 模块 `lfs`（由 `build.mk` 编译到 `luaclib/lfs.so`）；其余四个只用标准库。

#### 6.9.1 `lualib/skyext/util/fs.lua`

文件系统操作的唯一入口：路径拼接、目录遍历、读写复制、临时目录、切换工作目录。内部只有一个私有函数 `native(path)`，把正反斜杠统一成当前平台分隔符；**但只有 `join`、`absolute`、`mkdir` 会拿它处理传入的路径**，`mode`、`entries`、`read`、`with_dir` 等把路径原样交给 `lfs.*`/`io.*`（`write`/`copy` 只是先调 `mkdir` 建父目录）。正常用法下没问题——调用方的路径都由前面的 `join`/`absolute` 产出；自己拼了 `/` 再直接传给 `read`/`mode`，Windows 上不会被纠正。

| 方法 | 作用 | 行为与边界 |
| --- | --- | --- |
| `join(...)` | 用原生分隔符拼接任意段路径 | 跳过空串；**`nil` 会终止遍历**（`ipairs` 语义），其后的段全部丢弃，可选段应放末尾或调用前先滤掉 `nil`；前一段末尾的分隔符会被去掉再加一个，不产生重复；**遇到绝对路径段（以 `/`、`\` 开头，或盘符后紧跟分隔符如 `C:\`）就从该段重新开始**，避免 `join(base, user_input)` 拼出不存在的怪路径；无参数返回空串 |
| `absolute(path)` | 相对路径转绝对路径 | 已是绝对路径则只做分隔符规范化后原样返回；否则拼接 `lfs.currentdir()` |
| `mode(path)` | 查询路径类型 | 走 `lfs.symlinkattributes`，返回 `"file"`/`"directory"`/`"link"`/…；**路径不存在返回 `nil` 而不报错**，这是模块里唯一不抛错的查询 |
| `mkdir(path)` | 递归创建目录 | 已存在且是目录直接返回（可重复调用）；已存在但是普通文件时 `assert` 失败（`"not a directory: …"`）；逐级建父目录，遇到不存在的盘符报 `"drive not found"`；`lfs.mkdir` 失败后再查一次类型，兼容并发创建 |
| `entries(path)` | 列出目录项名字 | 过滤 `.` 与 `..`，按字典序排序后返回数组，保证遍历结果稳定 |
| `walk(root, accept)` | 递归遍历目录树 | 深度优先，返回 `{ path, relative, mode }` 列表，`relative` 一律用 `/`；`accept(relative, mode)` 返回假值时**整棵子树被剪掉**（不加入、也不再递归）；软链只接受「指向同目录内普通文件」的，指向目录外或非普通文件都 `assert` 失败；其他文件类型（设备、管道等）同样拒绝 |
| `read(path)` | 二进制读整个文件 | 打开失败、读取失败都 `assert`；文件不存在直接报错，**不返回空串**，避免把「没读到」当成「内容为空」 |
| `write(path, data)` | 二进制写文件 | 自动 `mkdir` 父目录，覆盖已有文件 |
| `copy(source, target)` | 复制单个文件 | 自动建目标父目录；按 64 KiB 块循环读写，不一次性把大文件读进内存 |
| `copy_tree(source, target, accept)` | 整棵目录复制 | 源必须是目录（否则 `assert`）；先建目标根，再按 `walk` 的结果逐项建目录/拷文件，`accept` 语义与 `walk` 一致 |
| `remove_tree(path)` | 递归删除 | 目录先递归删子项再 `lfs.rmdir`；文件用 `os.remove`；**路径不存在是空操作**，便于清理临时目录时无条件调用 |
| `temporary_dir(base)` | 创建唯一临时目录 | `base` 依次取参数、`TMPDIR`/`TEMP`/`TMP`、当前目录；用 `skyext-<时间戳>-<随机数>` 尝试 100 次，成功返回路径，全失败则报错 |
| `with_dir(path, fn)` | 临时切换工作目录执行回调 | 记录原目录 → `chdir` 目标 → `xpcall(fn, debug.traceback)` 执行 → **无论成功失败都先切回原目录**；成功时用 `table.unpack(results, 2, results.n)` 原样带回多返回值，失败时按原错误重新抛出 |

使用方：`scripts/skyext.lua`（定位仓库根）、`scripts/lib/lcov.lua`（读 tracefile）、测试框架 `lualib/skytest/init.lua`（生成临时节点配置、`data_path`）、覆盖率报告，以及几乎所有测试的「临时目录 + 清理」样板。`walk` 的软链规则是打包时的安全边界：不允许把工程目录外的文件通过软链带进发布包。

#### 6.9.2 `lualib/skyext/util/io.lua`

最薄的一层文件读写，只包 `io.open`，**不建父目录、不抛错**。

| 方法 | 作用 | 行为与边界 |
| --- | --- | --- |
| `readfile(file)` | 二进制读文件 | 成功返回内容字符串；打开失败返回 `nil, err`（错误信息原样带出，供上层写日志或转成 HTTP 错误） |
| `writefile(file, data)` | 写文件（覆盖） | 成功返回 `true`；打开失败返回 `false`；用 `"w+b"` 打开，已存在则清空重写 |

与 `fs` 的分工：需要「工程内文件必须成功，否则流程中止」时用 `fs.read`/`fs.write`；热更包、配表这类**由外部提供路径、失败要变成提示**的读取用 `io.readfile`。生产调用方：`lualib/skyext/res.lua`（配表加载与热重载）、`service/hotfix.lua`（热更配置与代码文件）、`lualib/skyext/hotfix_checksum.lua`、`lualib/skyext/http_server/agent.lua`（读静态文件）。

#### 6.9.3 `lualib/skyext/util/path.lua`

跨平台路径拼接的轻量版本，只有 `join(...)` 一个方法：

- 过滤空串；与 `fs.join` 一样用 `ipairs` 遍历，`nil` 会终止遍历、其后的段被丢弃。
- 用 `table.concat(parts, sep)` 拼接。
- 规范化连续分隔符：Unix 折叠 `/+`，Windows 折叠 `\+` 并把 `/` 全换成 `\`。
- 无参数或全为空串时返回 `""`。

与 `fs.join` 的差别：**不认识绝对路径段**（不会因为某段以 `/` 开头就丢弃前面的段），也不处理盘符特例。现有生产调用都传「根目录 + 包内相对路径」，两种实现等价；要「绝对路径覆盖」语义时用 `fs.join`。使用方：`service/hotfix.lua`、`lualib/skyext/hotfix_checksum.lua`。

#### 6.9.4 `lualib/skyext/util/string.lua`

| 方法 | 作用 | 行为与边界 |
| --- | --- | --- |
| `fromhex(str)` | 十六进制文本转字节串 | 大小写均可；空串返回空串；按每两个字符替换，**奇数长度时最后一个字符会原样留下**；非法十六进制会让 `tonumber` 返回 `nil` 并在 `string.char` 处报错，不做额外校验 |
| `tohex(str)` | 字节串转大写十六进制 | 每字节 `%02X`；与 `fromhex` 可无损往返（含 `\0` 字节） |
| `split(s, delim)` | 按分隔符切分 | 实现是先用字符类 `[^<delim>]+` 提取非分隔片段，所以**连续分隔符产生的空段被跳过**（`"a,,b"` 得到两段），首尾分隔符也忽略；`delim` 会被拼进字符类，传多字符或正则元字符（如 `-`、`]`）结果不符合直觉 |

目前只有单元测试引用，属于留给游戏层/工具链的通用工具，不在引擎生产链路上。

#### 6.9.5 `lualib/skyext/util/table.lua`

| 方法 | 作用 | 行为与边界 |
| --- | --- | --- |
| `deepcopy(orig, copies)` | 深拷贝 | 递归复制表、键和值；内部 `copies` 表记录「原表 → 副本」，因此**环引用和重复引用都保持原有共享关系**，不会无限递归；非表值原样返回 |
| `keys(data)` | 取出所有键 | 返回普通数组；顺序由 `pairs` 决定，不稳定 |
| `size(data)` | 统计条目数 | 用 `pairs` 计数；非表（含 `nil`）返回 `0` |
| `values(data)` | 取出所有值 | 返回普通数组；**浅拷贝**，表值仍是原引用 |
| `clear(t)` | 原地清空 | 逐个置 `nil`，保留表本身（引用不变） |
| `merge(t1, t2)` | 浅合并 | 把 `t2` 的键值写进 `t1`，同名键由 `t2` 覆盖；原地修改且不返回新表 |
| `tostring(tbl)` | 把表序列化成可读字符串 | 字符串做转义（`\n`、按内容选单/双引号）；合法标识符键不加引号，其他键写成 `[key]`；函数值加引号输出；有 `__tostring` 元方法的表直接调用它；**第二次出现的表（环或共享引用）输出 `"<ref: 0x…>"`**（`seen` 只增不清）；结果片段超过 1M 时插入 `"...,"` 截断，防止日志被超大表拖死；键顺序同样不稳定 |
| `tostring_tbl(tbl, result, seen)` | `tostring` 的分步实现（第一步） | 把序列化片段追加到 `result` 数组；供需要自行拼接的场景复用 |
| `concat_tostring_tbl(result)` | `tostring` 的分步实现（第二步） | 清掉内部游标后 `table.concat`，与上一步配对使用 |
| `in_array(tbl, value)` | 按值找键 | 遍历 `pairs` 返回第一个相等值的键（数组得到下标，哈希键得到键名）；找不到返回 `nil` |

使用方：`lualib/skyext/log/logger.lua` 用它把 table 参数打印成日志；`service/cluster_discovery.lua` 用 `deepcopy` 复制节点信息，避免把内部缓存的表直接交给调用方改坏；`lualib/skyext/etcd/init.test.lua` 用 `tostring` 输出断言差异。

#### 6.9.6 测试

| 测试文件 | 覆盖内容 |
| --- | --- |
| `lualib/skyext/util/fs.test.lua` | 路径拼接与绝对路径段、`mkdir` 递归与「目标是文件」、`entries` 排序、`remove_tree` 幂等、`temporary_dir` 唯一性、二进制读写、跨 64 KiB 块的 `copy`、`walk` 的排序/剪枝/软链三种拒绝、`copy_tree`、`with_dir` 的返回值与异常后恢复目录 |
| `lualib/skyext/util/io.test.lua` | `writefile`/`readfile` 往返、覆盖写、二进制内容、缺失文件返回 `nil, err` |
| `lualib/skyext/util/path.test.lua` | `join` 的段数、空段过滤、重复分隔符折叠、无参数 |
| `lualib/skyext/util/string.test.lua` | hex 双向转换（大小写、空串、`\0`）、往返一致、`split` 的空段跳过 |
| `lualib/skyext/util/table.test.lua` | 深拷贝隔离与混合键、`keys`/`values`/`size`、`clear`、`merge` 覆盖、`tostring` 嵌套与环引用、`in_array` |

注意：`io.test.lua` 用 `/tmp/…` 固定路径、`path.test.lua` 断言 `"a/b"` 字面量，这两个测试以 POSIX 为基线（CI 在 Linux 运行）；`fs.test.lua` 用 `package.config` 取分隔符并在临时目录里跑，Windows 也能过。

### 6.10 `lualib/orm/`

| 文件 | 作用 |
| --- | --- |
| `lualib/orm/init.lua` | ORM 运行时：文档代理与字段变更跟踪（脏标记）、`_version`、`decode` 容忍字段增删、`totable`/`next`/`unpack` 等显式接口 |
| `lualib/orm/init.test.lua` | ORM 运行时单元测试 |

### 6.11 `lualib/skytest/`

| 文件 | 作用 |
| --- | --- |
| `lualib/skytest/init.lua` | 测试框架 API：`describe`/`it`/`before_*`/`after_*`、`start_skynet`、`wait_for_port`、`data_path`、`run` |
| `lualib/skytest/expect.lua` | 断言库（相等、类型、错误、深比较等） |
| `lualib/skytest/reporter.lua` | 终端输出：套件、通过/失败/跳过、汇总 |
| `lualib/skytest/runner.lua` | 单测试文件执行入口（`service/skytest_runner.lua` 调用） |
| `lualib/skytest/http.lua` | 测试用 HTTP 客户端（GET/POST/JSON） |
| `lualib/skytest/cov/init.lua` | 覆盖率开关入口 |
| `lualib/skytest/cov/config.lua` | 覆盖率配置（include/exclude、输出路径） |
| `lualib/skytest/cov/install.lua` | 在服务/协程上安装行覆盖钩子 |
| `lualib/skytest/cov/collector.lua` | 收集各服务覆盖率数据 |
| `lualib/skytest/cov/source_lines.lua` | 计算文件可执行行，供覆盖率报告 |
| `lualib/skytest/cov/lcov_reporter.lua` | 输出 LCOV `.info` |
| `lualib/skytest/expect.test.lua` | 断言库测试 |
| `lualib/skytest/process.test.lua` | 子进程执行能力测试 |
| `lualib/skytest/process.test/fixture.lua` | `process.test.lua` 的子进程 fixture |
| `lualib/skytest/cov/source_lines.test.lua` | 可执行行计算测试 |
| `lualib/skytest/cov/source_lines.test/nested.lua` | 上述测试的嵌套函数 fixture |
| `lualib/skytest/cov/lcov_reporter.test.lua` | LCOV 输出测试 |

## 7. `service/` 引擎服务

### 7.1 接入与实体

| 文件 | 作用 |
| --- | --- |
| `service/gate_tcp.lua` | 裸 TCP 网关：连接表、未绑定包交给登录服务、已绑定包按 owner 转发、`bind`/`push`/`kick` |
| `service/gate_ws.lua` | WebSocket 网关：对外接口与 TCP 网关一致，仅传输层不同（独立服务，因为 skynet 的 `PTYPE_SOCKET` 只能注册一次） |
| `service/entity_agent.lua` | 单个实体 agent：加载实体、按命令找 handler、粘性转发/交接、`entity_call` |
| `service/entity_agentmgr.lua` | 每个实体类型的 agent 池：模块发现、启动、作用域实体预加载、停服卸载 |
| `service/entity_dlq.lua` | 可靠消息死信运维端：`dlq_list`/`dlq_replay`/`dlq_discard` |
| `service/entity_agent.test.lua` | 实体 agent 测试 |
| `service/entity_agentmgr.test.lua` | agent 池/预加载测试 |
| `service/entity_dlq.test.lua` | 死信命令测试 |
| `service/gate_ws.test.lua` | WS 网关测试（TCP 网关逻辑与之共用，未单列测试） |

### 7.2 集群与存储

| 文件 | 作用 |
| --- | --- |
| `service/node_lease.lua` | 节点级 etcd 租约：全进程唯一，申请/续租/失效广播；实体锁与服务发现都挂它 |
| `service/node_lease.test.lua` | 节点租约服务测试 |
| `service/cluster_discovery.lua` | 服务发现服务端：节点/服务键注册与 watch，向调用方广播变更 |
| `service/cluster_discovery.test.lua` | 服务发现服务测试 |
| `service/realm.lua` | 区服目录服务：etcd 读写与 watch、整表广播、网关地址上报 |
| `service/realm.test.lua` | 区服目录服务测试 |
| `service/mongo_conn.lua` | MongoDB 连接池服务：按库/集合转发请求 |
| `service/mongo_conn.test.lua` | 连接池服务测试 |
| `service/mongo_index.lua` | 启动时创建 MongoDB 索引（`create_indexes`） |
| `service/mongo_index.test.lua` | 索引创建测试 |
| `service/sproto_loader.lua` | 加载 `sproto.spb`、提供协议校验和、支持热重载 |
| `service/sproto_loader.test.lua` | 协议加载测试 |

### 7.3 运维

| 文件 | 作用 |
| --- | --- |
| `service/gm.lua` | GM HTTP 服务：token 鉴权、命令注册表、跨服务执行与结果汇总 |
| `service/gm_sys.lua` | skynet 系统调试命令包装（节点/服务/内存/统计信息） |
| `service/hotfix.lua` | 热更执行：校验、清 Lua 缓存、重载配表/协议/schema、注入代码、历史记录 |
| `service/node_shutdown.lua` | 停服编排：停接入 → 卸实体 → 释放钩子 → 撤销节点租约 → 退出 |
| `service/metrics.lua` | 指标抓取与导出：并发拉取各服务快照、合并、Prometheus 文本输出 |
| `service/gm.test.lua` | GM 服务测试 |
| `service/gm_sys.test.lua` | 系统命令测试 |
| `service/gm_sys.test/inject_script.lua` | 上述测试的注入脚本 fixture |
| `service/hotfix.test.lua` | 热更流程测试 |
| `service/node_shutdown.test.lua` | 停服编排测试 |
| `service/metrics.test.lua` | 抓取/渲染测试 |

### 7.4 `service/logger/`

| 文件 | 作用 |
| --- | --- |
| `service/logger/main.lua` | logger 服务入口：用 `xpcall` 包裹启动，失败时写 `bootfaillogpath` |
| `service/logger/start.lua` | 服务初始化与消息分发：读取配置、建立 bucket、接管日志协议 |
| `service/logger/bucket.lua` | bucket 管理：初始化/写入/重载/关闭 |
| `service/logger/checker.lua` | 过载保护：按队列长度判断日志积压，避免 OOM |
| `service/logger/cmd.lua` | 对 logger 服务的 `put`/`close`/`reload` 指令 |
| `service/logger/global.lua` | logger 服务内共享状态（bucket、过载标记） |
| `service/logger/bucket.test.lua` | bucket 管理测试 |
| `service/logger/checker.test.lua` | 过载判定测试 |

### 7.5 测试支撑

| 文件 | 作用 |
| --- | --- |
| `service/skytest_runner.lua` | 单个测试文件的 skynet 进程入口：按 `SKYTEST_FILE` 加载并运行 |
| `service/skytest_cov.lua` | 覆盖率收集服务：合并各服务统计、生成报告、`DUMP`/`STATUS`/`RESET` |

## 8. 原生扩展

| 文件 | 作用 |
| --- | --- |
| `lualib-src/traceback.c` | 结构化 traceback Lua 模块（服务崩溃时输出完整调用栈） |
| `lualib-src/crypto.c` | OpenSSL 封装：HMAC、RSA/ECDSA、base64url、安全随机数，供 JWT 使用 |
| `lualib-src/tool_process.c` | 跨平台子进程执行（CLI 的 test/package 等命令使用） |
| `lualib-src/profiler.c` | C 层低开销采样模块骨架（未完成） |
| `lualib-src/skytest_hook.c` | C 加速行覆盖钩子（`skytest.hook`） |
| `service-src/service_profiler.c` | 跨 worker 采样 C 服务骨架（未完成） |

## 9. `scripts/` 与 CLI

统一 CLI 是仓库里唯一跨平台的工具入口：`bin/` 下两个包装脚本负责找到构建出的 Lua 解释器，实现全部在 `scripts/`。命令既承担开发期动作（测试、生成、起服），也承担交付与运维动作（打包、热更校验、覆盖率与 schema 门禁）。

### 9.1 `scripts/` 文件清单

| 文件 | 作用 |
| --- | --- |
| `scripts/skyext.lua` | CLI 入口：从 `arg[0]` 定位仓库根、设置 `package.path/cpath`、建 `context`、分发子命令 |
| `scripts/commands/test.lua` | `skyext test`：扫描 `*.test.lua`、按文件起 skynet 进程、汇总结果、可选 Lua/C 覆盖率 |
| `scripts/commands/serve.lua` | `skyext serve`：列出节点、切到仓库根、启动对应 `.conf.lua` |
| `scripts/commands/generate.lua` | `skyext generate proto` / `generate schema`：调用 sproto 编译与 ORM schema 生成 |
| `scripts/commands/package.lua` | `skyext package`：打游戏包（`example/skyext.zip`）或框架发布包（`release-assets/*.zip`） |
| `scripts/commands/hotfix.lua` | `skyext hotfix refresh`：重算包内 checksum 并刷新 `time` |
| `scripts/commands/cov.lua` | `skyext cov`：覆盖率的 merge/check/summary/html |
| `scripts/commands/schema.lua` | `skyext schema`：`check`/`accept`/`retired`，对比基线与计算墓碑 |
| `scripts/lib/lcov.lua` | LCOV tracefile 解析与合并 |
| `scripts/lib/zip.lua` | 纯 Lua ZIP 写入（打包用，无外部依赖） |
| `scripts/ci/check_paths.lua` | CI 检查：引擎代码里的裸名 `require`、节点目录名与服务名撞车 |
| `scripts/ci/patches/skynet-mingw-clock.patch` | skynet 在 mingw 下的时钟补丁（构建时应用） |
| `scripts/tools/sproto_orm/gen_schema.lua` | ORM schema 生成器：读 `example/schema/*.sproto` 产出 `example/build/lualib/game/orm/` |
| `scripts/tools/sproto_orm/sproto2lua.lua` | sproto 定义转 Lua 表 |
| `scripts/tools/sproto_orm/README.md` | 生成器说明 |
| `scripts/tools/sproto_orm/LICENSE` | 生成器许可证 |

### 9.2 调用方式与前提

包装脚本做的事只有一件：找到 Lua 解释器并执行 `scripts/skyext.lua`。

| 入口 | 行为 |
| --- | --- |
| `./bin/skyext` | POSIX sh：定位自身目录，优先用 `bin/lua`，没有则用 `bin/lua.exe`，`exec` 执行 `../scripts/skyext.lua "$@"` |
| `bin\skyext.bat` | Windows CMD/PowerShell：用同目录 `lua.exe` 执行 `..\scripts\skyext.lua`，透传退出码 |
| `./bin/lua scripts/skyext.lua` | 绕过包装脚本，直接调用实现体；`example/Makefile` 的 `SKYEXT_TOOL` 就是这种写法 |

`scripts/skyext.lua` 自身的职责：

1. 从 `arg[0]` 反推仓库根，把 `root/?.lua`、`root/lualib/?.lua`、`root/lualib/?/init.lua`、`skynet/lualib/?.lua` 加进 `package.path`，把 `luaclib/?.so`、`skynet/luaclib/?.so` 加进 `package.cpath`——所以它不依赖当前目录。
2. 构造 `context = { root, game = root .. "example", fs = skyext.util.fs, process = tool_process }`，后面所有子命令都只通过它拿路径和子进程能力。
3. 按 `commands` 表分发到 `scripts/commands/<name>.lua`，用 `xpcall(..., debug.traceback)` 包住：异常时打印完整 traceback 并退出 1，否则用子命令的返回值作为退出码。

前提与约定：

- 先 `make init`（`generate` 还依赖 `3rd/sprotodump`）和 `make build`（产出 `bin/lua`、`bin/skynet`、`luaclib/*.so`）；`test`、`serve` 缺 `bin/skynet` 时会明确提示。
- 尽量在**仓库根目录**执行：入口本身能定位根，但 `test` 的显式目标先按当前目录解析、`cov html` 的默认输出相对当前目录；`serve` 则自己把 skynet 的工作目录设为仓库根。
- 顶层无命令或 `--help`/`-h` 打印总帮助；每个子命令也接受 `-h`。未知命令直接退出 1。

### 9.3 命令与产物总览

| 命令 | 参数 | 产物 / 副作用 | 额外依赖 |
| --- | --- | --- | --- |
| `test` | `[--cov] [--cov-c] [--match TEXT] [--timeout SECS] [--conf FILE] [file/dir...]` | 终端汇总；`--cov` 时写 `coverage/` | `bin/skynet` |
| `serve` | `<node / config-file> [skynet-args...]` | 前台运行一个 skynet 节点 | `bin/skynet` |
| `generate` | `<proto / schema>` | `example/build/` 下的协议包或 ORM schema | `3rd/sprotodump`；schema 还需 `stylua` |
| `package game` | 无 | `example/skyext.zip` | 已构建的 `.so` 与 `bin/` |
| `package framework` | `<platform>` | `release-assets/skyext-<platform>.zip` | 可选系统 `zip` |
| `hotfix refresh` | `<patch-dir>` | 改写该热更目录的 `hotfix.conf.lua` | 无 |
| `cov` | `merge / check / summary / html` | 合并后的 `.info`、HTML 报告 | `html` 需要 `genhtml` |
| `schema` | `check / accept / retired` | 读/写 `example/schema/schema.lock.lua` | 先 `generate schema`；`accept` 需 `stylua` |

### 9.4 `test`：逐文件起进程跑测试

- 目标解析：不给目标时扫描 `lualib`、`service`、`example`、`sdk` 四个目录；给文件就直接跑，给目录就递归找 `*.test.lua`，显式目标不存在会报错。遍历时跳过 `node_modules` 与名字以 `.` 开头的项（`example/tools` 下的联调子模块不进扫描范围）。
- 每个测试文件跑在**独立的 skynet 进程**里：`bin/skynet` + 临时配置 `example/etc/.skytest_<时间>_<随机>.conf.lua`（`start = "skytest_runner"`），文件跑完即删；用 `--conf` 可换成自己的配置。
- 选项：`--match` 按相对仓库根的路径子串过滤；`--timeout` 单文件超时（默认 120，或环境变量 `SKYTEST_TIMEOUT`）；`--cov`/`--cov-c` 见下。
- 结果分类：退出码 2 记为 `errors`（加载/执行失败），其他非 0 记为 `failed`；`>128` 会翻译信号名（`SIGSEGV` 等），超时单独打印 `TIMEOUT`；有任一失败返回 1。
- 环境变量：`*.integration.test.lua` 由测试文件自己读 `SKYTEST_INTEGRATION`，不为 `1` 时在文件头直接 `return`（CLI 不按文件名筛选，进程仍会启动，只是没有用例）；设为 `1` 时需真实 MongoDB/etcd，地址可用 `MONGO_HOST`、`MONGO_PORT`、`ETCD_ENDPOINTS` 覆盖。覆盖率相关变量见 `--cov` 实现（`SKYTEST_COV_OUTPUT_DIR`、`SKYTEST_COV_SOURCE_DIRS`、`SKYTEST_COV_EXCLUDE`）。
- `--cov`：每个测试进程把 tracefile 写进临时目录，结束后合并成两份——`coverage/lua_coverage.info`（全部）与 `coverage/lua_coverage_clean.info`（只保留 `./` 工程源码，排除 `example/etc`、`example/hotfix`、`example/tools`、`example/res`），装有 `genhtml` 时再出 `coverage/html`。
- `--cov-c`：需要 `make build C_COVERAGE=1`（Linux/GCC）。每个测试进程用独立的 `GCOV_PREFIX` 目录隔离 `.gcda`，避免并发合并损坏，再逐目录 capture（损坏的目录只跳过并告警），产出 `coverage/c_coverage.info` 与 `coverage/html-c`。

### 9.5 `serve`：按配置启动节点

- 参数解析：先按当前目录把参数当文件路径解析，再按仓库根解析；都不是文件且形如节点名时，拼成 `example/etc/<node>.conf.lua`。无参数时列出 `example/etc` 下可用节点（排除 `core`、`paths`）。
- 启动：拼出 `bin/skynet`（Windows 为 `skynet.exe`），把剩余参数原样透传给 skynet，`cwd` 固定为仓库根，前台阻塞；skynet 的退出码即命令退出码。它不做服务端初始化（不注入环境变量、不改配置），所以行为与「在仓库根手跑 `./bin/skynet example/etc/<node>.conf.lua`」一致，区别只是节点名解析、存在性检查和 cwd 保证。
- 因为 skynet 配置里 `root = "./"`，直接手跑 `./bin/skynet ...` 也必须在根目录；`serve` 把这个前提收敛进工具里。
- 停服不要直接杀进程：走 GM 的 `shutdown` 命令，否则内存里未回存的改动会丢、etcd 锁要等租约过期。

### 9.6 `generate`：生成协议与 ORM schema

- 两个子命令都先检查 `3rd/sprotodump/core.lua`，缺失时提示 `git submodule update --init 3rd/sprotodump`；工作目录会切到 `example/`，因此与调用时的 cwd 无关。
- `proto`：递归收集 `example/proto/` 下的 `*.sproto`（相对路径统一成 `/`），交给 `example/tools/proto2spb.lua` 编译，产物 `example/build/proto/sproto.spb`；产物不存在即判定失败。
- `schema`：收集 `example/schema/*.sproto`，先由 `sproto2lua.lua` 生成 `example/build/lualib/game/orm/schema_define.lua`，再由 `gen_schema.lua` 生成 `schema.lua`，最后强制用 `stylua` 格式化（未安装则失败）。
- `sproto.spb` 的 MD5 会成为登录时的 `proto_checksum`；客户端与服务端必须用同一份产物。

### 9.7 `package`：两种包，两种用途

两种打包都先「遍历 → 生成清单 → 排序 → 写临时文件 → 原子替换」，输出都落在 Git 忽略目录，重复执行结果稳定。

#### 9.7.1 `package game`

产出 **`example/skyext.zip`**：一个能直接部署运行的包，包含引擎、示例游戏和 skynet 运行时，不含测试源码。

1. 遍历仓库根，按**顶层名字精确比较**排除 `3rd`、`example`、`skynet`、`.git`、`.github`、`.claude`、`coverage`、`logs`、`release-assets`、`build-output`，另外任何层级的 `node_modules` 也跳过。注意 `.git` 是精确比较（`first ~= ".git"`），framework 包那边才是 `^%.git` 通配；这一步的遍历只收 `.so`/`.lua`，`.gitignore` 这类文件本来也不会被收集，所以差别只体现在遍历范围上。
2. `.so` 原样收集；`.lua`（跳过 `*.test.lua`）用 `loadfile(..., "t")` + `string.dump` **编译成字节码**，已经是字节码（以 `\27Lua` 开头）的不再编译。
3. 遍历 `example/` 做同样处理：按顶层名字排除 `dist`、`3rd`、`skyext.zip`，再排除 `tools/gamepass`、`tools/phaser-game` 与四个本地数据卷目录（`tools/mongodb/db`、`tools/etcd/etcd{1,2,3}_data`）；`.lua` 里跳过 `*.test.lua` 与 `etc/.skytest_*.conf.lua`（临时测试配置的文件名里没有 `.test`，只能单独判）。这一轮只收 `.so` 与 `.lua`，所以 `tools/browser_e2e.mjs` 自然不会进来，它在第 4 步的过滤表里另有一条兜底。
4. 加入 skynet 的 `luaclib/`、`cservice/` 里的 `.so`，以及整个 `bin/`、`skynet/lualib`、`skynet/service`、`example/{etc,tools,proto,schema,build}`；这一轮再过一张清单表，跳过 `example/tools/gamepass`、`example/tools/phaser-game`、`example/tools/browser_e2e.mjs`、四个数据卷目录，以及 `*.test.lua` 与 `example/etc/.skytest_*.conf.lua`。`logs/`、`README.md`、`LICENSE` 只在源目录/文件已存在时才加入（不会新建）。
5. 按相对路径排序写入 ZIP，先写临时文件再原子改名。

注意：它不会替你生成协议和 schema——`example/build` 里没有产物时，包里也不会有，需先 `generate`。代码是字节码，调试堆栈只有行号；热更要配套部署 `update_files` 的源码。

#### 9.7.2 `package framework <platform>`

产出 **`release-assets/skyext-<platform>.zip`**：用于分发引擎本身（作 submodule 或发布版）。

- 整仓遍历并排除 `.git*`、`.vscode`、`.claude`、`.aone_copilot`、`.DS_Store`、`node_modules`、`._*`、`.env*`、`.skytest_*.conf.lua`、`build-output`、`release-assets`、`coverage`、`logs`、`example/dist`、`example/skyext.zip` 和 **`3rd/sprotodump`**。
- 在临时目录里用硬链接（失败则复制）搭出同样的树，调用系统 `zip -qr`；系统没有 `zip`（退出码 127）时回退到纯 Lua 的无压缩 ZIP，其他失败直接报错。
- `<platform>` **只参与文件名**，不做交叉编译；CI 在 linux/macosx/windows/freebsd 上各自构建后各调用一次（见 `.github/workflows/build-release.yml`）。

**不含 `3rd/sprotodump` 的后果**：发布包不能再运行 `generate proto/schema`（解析器许可证未核实，框架包不分发它），重新生成需要源码检出并初始化子模块。

#### 9.7.3 两种包的区别

| | `package game` | `package framework <platform>` |
| --- | --- | --- |
| 产物 | `example/skyext.zip` | `release-assets/skyext-<platform>.zip` |
| 内容 | 可运行部署包：引擎 + `example/` + `bin/` + skynet 运行时，Lua 为字节码 | 开发用源码包：整仓源码、文档、SDK、测试与子模块内容 |
| 用途 | 上线/联调机器直接跑 | 给游戏项目引用或发布框架版本 |

### 9.8 `hotfix refresh <dir>`：回写热更校验和

热更执行前服务端会校验包完整性，这个命令负责在提交/发布前把 `checksum` 与 `time` 写回热更目录的 `hotfix.conf.lua`。

1. 目录必须是相对工程根的路径，拒绝绝对路径和 `.`/`..` 段。
2. 以沙箱方式加载 `<dir>/hotfix.conf.lua`（只接受返回 table）。
3. 计算校验和：按数组顺序读取 `update_files`（相对仓库根）与 `code_files`（相对热更目录）的内容，拼接后取 MD5；**顺序参与计算**，任一文件读不到即失败。
4. 精确替换文件里唯一的 `time` 与 `checksum` 字段（各必须恰好出现一次），写入前重新加载校验，成功后打印路径、时间与校验和。

它与执行侧的分工：`service/hotfix.lua` 执行时会用同一份配置重算并比对，不一致直接拒绝——用于防止「改了文件清单却忘了刷新」和传输损坏。它只刷新元数据，不执行热更；执行走 GM 的 `hotfix` 命令，流程见 `docs/guide/hotfix.md`。

### 9.9 `cov`：覆盖率读写与门槛

| 子命令 | 作用 | 关键行为 |
| --- | --- | --- |
| `merge -o <out> <in...>` | 合并多份 LCOV tracefile | 只解析 `SF:`/`DA:`/`end_of_record`；同一「源文件 + 行号」累加命中；负计数按 0 处理（与 lcov 2.x 的 negative 语义一致）；跳过不存在或空文件；禁止输出同时作为输入；输出按文件名、行号排序并补 `LF`/`LH` |
| `check <file> [--threshold N]` | 卡覆盖率门槛 | 统计「可执行行 / 命中行」；低于阈值或没有数据返回 1；默认阈值 0，`N` 取 0–100 |
| `summary <file>` | 打印摘要 | 百分比、命中/总行数、文件数 |
| `html <file> [outdir]` | 生成 HTML 报告 | 调系统 `genhtml`，默认输出 `coverage/html` |

数据来源：`test --cov` 产出的 `coverage/lua_coverage_clean.info`（已剔除配置/联调脚本路径）与 `--cov-c` 产出的 `coverage/c_coverage.info`。CI 用 `cov check coverage/lua_coverage_clean.info --threshold 85` 和 `cov check coverage/c_coverage.info --threshold 60`，再把 `summary` 写进流水线摘要。

### 9.10 `schema`：ORM schema 兼容性门禁

运行期 `orm.decode` 容忍字段增删（丢旧字段、补零值），但**改名、改类型、重新使用删过的名字**会悄悄丢数据或读错数据。这里用一份基线把这类改动拦在提交前。

基线文件 `example/schema/schema.lock.lua` 的结构：

```lua
return {
    types = { role = { rid = { type = "integer" }, ... }, ... },  -- 上次确认的结构
    retired = { fields = { role = { create_time = "integer" } }, types = {} },  -- 墓碑
}
```

- `check`：读 `example/build/lualib/game/orm/schema_define.lua` 与基线做 diff，按 `[级别] 结构.字段: 说明` 打印。级别判定：

  | 级别 | 含义 |
  | --- | --- |
  | `break` | 改类型（含 map 键值、array 元素类型）、重新使用删过的字段名或结构名 |
  | `warn` | 删字段、删结构、疑似改名（同结构一删一加且类型相同） |
  | `info` | 新增字段、新增结构 |

  退出码只看「是否与基线一致」：一致返回 0；有 `break` 返回 1 并提示改用「加新字段、双写、再删旧字段」；只有 `warn`/`info` 也返回 1，提示执行 `accept`；基线不存在同样返回 1。
- `accept [--force]`：用当前 schema 生成新基线；有 `break` 且未加 `--force` 时拒绝。墓碑只增不减（删掉的结构会连字段名一起退休）；被 `--force` 放行、重新出现在当前 schema 里的名字会从墓碑移除，避免之后每次检查都失败。写文件后调用 `stylua` 定版式。
- `retired [结构名]`：列出基线里已退休、不能再用的名字及当时类型，起新字段名前先查一眼。

注意：`check`/`accept` 都要求先 `generate schema`；基线要跟 `.sproto` 改动一起提交；墓碑按结构隔离（`role.create_time` 退休不影响 `bag.create_time`）；`reload_orm_schema` 热更只适用于加删字段。细节见 `docs/guide/orm_schema_change.md`。

## 10. 客户端 SDK

### 10.1 `sdk/lua/`

| 文件 | 作用 |
| --- | --- |
| `sdk/lua/skyext/client/account.lua` | Account HTTP 层：hosts 轮换、Bearer token、`servers`/`roles`/`create_role`/`gates`/`dev_login` |
| `sdk/lua/skyext/client/session.lua` | 会话层：连网关、`login`/`resume`/`ping`、请求 id 与下行计数、心跳、断线续接（五条义务） |
| `sdk/lua/skyext/client/account.test.lua` | Account 层测试 |
| `sdk/lua/skyext/client/session.test.lua` | 会话层测试（与 TS 版共用同一套协议语义基线） |

### 10.2 `sdk/ts/`

| 文件 | 作用 |
| --- | --- |
| `sdk/ts/package.json` | 包信息：ESM，`exports` 指向 `src/index.ts`，`bun test`/`tsc --noEmit` |
| `sdk/ts/tsconfig.json` | TypeScript 编译配置 |
| `sdk/ts/bun.lock` | bun 依赖锁定 |
| `sdk/ts/README.md` | SDK 安装、导出、目录与开发命令 |
| `sdk/ts/src/index.ts` | 公开导出入口（门面、Account、Session、Codec、Transport、类型、错误码） |
| `sdk/ts/src/types.ts` | 公共类型：`GateInfo`/`ServerInfo`/`RoleInfo`/`SessionState` 等 |
| `sdk/ts/src/errcode.ts` | 错误码常量（对应 `lualib/skyext/errcode.lua`） |
| `sdk/ts/src/bin.ts` | 字节助手：latin1 与 UTF-8 两组转换 |
| `sdk/ts/src/json.ts` | int64 安全 JSON 解析：超 2^53 的整数还原为 `bigint` |
| `sdk/ts/src/md5.ts` | 纯 TS md5（`proto_checksum`） |
| `sdk/ts/src/codec.ts` | sproto 编解码门面：`pack`/`dispatch`/`checksum` |
| `sdk/ts/src/transport.ts` | `Transport` 接口与浏览器 WebSocket 实现 |
| `sdk/ts/src/session.ts` | 会话层：状态机、计数、心跳、续接（`session.lua` 的 TS 等价实现） |
| `sdk/ts/src/account.ts` | Account HTTP 层（`account.lua` 的 TS 等价实现） |
| `sdk/ts/src/client.ts` | `SkyextClient` 门面：account + codec + session 串成「拿 token → 进游戏」 |
| `sdk/ts/src/sproto/index.ts` | vendored sproto-js 的 ESM 入口 |
| `sdk/ts/src/sproto/sproto.ts` | vendored sproto-js（MIT）+ 两个补丁：string 字节透明、int64 用 bigint |
| `sdk/ts/src/account.test.ts` | Account 层测试 |
| `sdk/ts/src/bin.test.ts` | 字节助手测试 |
| `sdk/ts/src/codec.test.ts` | 编解码测试 |
| `sdk/ts/src/json.test.ts` | int64 JSON 测试 |
| `sdk/ts/src/md5.test.ts` | md5 测试 |
| `sdk/ts/src/session.test.ts` | 会话层测试 |
| `sdk/ts/test/e2e/login.test.ts` | 真服务器端到端测试（`SKYEXT_E2E=1` 门控） |

## 11. `example/` 示例游戏

### 11.1 `example/etc/`

| 文件 | 作用 |
| --- | --- |
| `example/etc/core.conf.lua` | skynet 公共配置：`root`、`skyext_root`、`game_root`、线程数、bootstrap、logger |
| `example/etc/paths.conf.lua` | 服务/Lua/C 模块搜索路径与 `lualoader`；注释说明节点目录名不能与服务名撞车 |
| `example/etc/account1.conf.lua` | account1 节点启动配置（指向 `account1.app.lua`，`start = "account"`） |
| `example/etc/account2.conf.lua` | account2 节点启动配置 |
| `example/etc/role1.conf.lua` | role1 节点启动配置（`start = "role"`） |
| `example/etc/role2.conf.lua` | role2 节点启动配置 |
| `example/etc/gate1.conf.lua` | 独立网关节点启动配置（`start = "gateway"`） |
| `example/etc/robot.conf.lua` | 机器人节点启动配置（`start = "robot"`） |
| `example/etc/nodes/common.app.lua` | 应用公共配置：日志、etcd/mongo、实体类型、会话上限、配表、JWT、HTTP 上限、指标、区服种子 |
| `example/etc/nodes/account1.app.lua` | account1 应用配置：集群名/端口、日志、HTTP 8080、GM 9090、指标 9190 |
| `example/etc/nodes/account2.app.lua` | account2 应用配置：HTTP 8081、GM 9091、指标 9191 |
| `example/etc/nodes/role1.app.lua` | rolenode1 应用配置：集群 7011、gate 7012/7013、GM 9092、指标 9192 |
| `example/etc/nodes/role2.app.lua` | rolenode2 应用配置：集群 7021、gate 7022/7023、GM 9093、指标 9193 |
| `example/etc/nodes/gate1.app.lua` | gate1 应用配置：集群 7051、bare TCP 7052、WS 7053、GM 9094、指标 9194 |
| `example/etc/nodes/robot.app.lua` | 机器人配置：数量、account 地址、传输类型（tcp/ws）、日志 |

### 11.2 `example/nodes/`

| 文件 | 作用 |
| --- | --- |
| `example/nodes/account/main.lua` | Account 节点入口：起 launcher、HTTP 服务、注册 `account_router` |
| `example/nodes/role/main.lua` | Role 节点入口：起 launcher、为 `role`/`rank` 各起 agentmgr、可选同进程 gate、admin 服务 |
| `example/nodes/gateway/main.lua` | 独立网关节点入口：只起 launcher 与 gate，不承载实体 |
| `example/nodes/robot/main.lua` | Robot 节点入口：按配置创建若干 `robot/robotagent` |
| `example/nodes/robot/robotagent/main.lua` | 机器人：走 Lua SDK 完成 dev_login/选服/建角/网关发现，再在 TCP 与 WS 上各跑一遍业务与续接验收 |
| `example/nodes/account/lualib/account_router.lua` | Account HTTP 路由：`/dev_login`、`/servers`、`/gates`、`/roles`、`/create_role` |
| `example/nodes/account/lualib/account_router.test.lua` | 账号路由测试 |
| `example/nodes/role/modules/role/request.lua` | 角色模块协议入口：`login_info` |
| `example/nodes/role/modules/bag/init.lua` | 背包模块：初始道具、增减、快照（数组化） |
| `example/nodes/role/modules/bag/request.lua` | 背包协议入口：`get_bag` |
| `example/nodes/role/modules/mail/init.lua` | 邮件模块：收信去重、上限淘汰、列表、领取附件 |
| `example/nodes/role/modules/mail/request.lua` | 邮件协议入口：`list`/`send`（可靠消息）/`claim` |
| `example/nodes/role/modules/mail/init.test.lua` | 邮件模块测试 |
| `example/nodes/role/modules/rank/request.lua` | 排行榜协议入口：`submit`/`top`，按角色出生服现查 game 再 `scoped_call` |

### 11.3 `example/service/`

| 文件 | 作用 |
| --- | --- |
| `example/service/login/main.lua` | 登录服务：接收未绑定会话、鉴权、`router.bind_session` 绑到角色实体；TCP/WS 与独立网关共用 |
| `example/service/login/client.lua` | 登录服务发给客户端的下行封装（按网关地址发回包） |
| `example/service/login/login_request.lua` | `login`/`resume`/`ping` 的请求处理与校验（JWT、协议 checksum、nonce） |
| `example/service/admin/main.lua` | 示例运营服务：演示非实体服务经可靠消息给角色发系统邮件 |
| `example/service/admin/main.test.lua` | 运营服务测试 |

### 11.4 `example/lualib/`

| 文件 | 作用 |
| --- | --- |
| `example/lualib/launcher.lua` | 节点公共启动：起 metrics/gm/hotfix、停服编排、realm、建 MongoDB 索引；`launcher_gate` 起 TCP/WS 网关并上报地址 |
| `example/lualib/entity_handler/role.lua` | `role` 实体 handler：`get_online_info`、`kick`、可靠消息 `recv_mail`、生命周期与上下线/续接钩子 |
| `example/lualib/entity_handler/rank.lua` | `rank` 作用域实体 handler：提交分数、前 N 名、定时刷新排名、落库 |
| `example/lualib/entity_handler/rank.test.lua` | 排行榜 handler 测试 |
| `example/lualib/jwt.lua` | 示例 JWT 签发/校验（HS256，登录 token） |
| `example/lualib/jwt.test.lua` | JWT 测试 |
| `example/lualib/errcode.lua` | 游戏层错误码扩展（`ROLE_NOT_EXIST`、`TOKEN_ERROR`、`NAME_TAKEN` 等） |
| `example/lualib/errcode.test.lua` | 错误码测试 |
| `example/lualib/role_db_api.lua` | 角色文档读写：按 rid 取、按账号列角色、创建、存在性检查 |
| `example/lualib/user_db_api.lua` | 账号文档读写：`ensure_get_user`、按服占/还角色名额 |
| `example/lualib/role_name_api.lua` | 角色名占用：`(server, name)` 唯一，先占名再建角 |

### 11.5 协议与 schema

| 文件 | 作用 |
| --- | --- |
| `example/proto/base.sproto` | 基础包结构（`type`/`session`） |
| `example/proto/login.sproto` | 登录/续接/心跳协议（100/101/102） |
| `example/proto/roleagent/role.sproto` | 角色协议：`login_info`（200） |
| `example/proto/roleagent/bag.sproto` | 背包协议与结构：`get_bag`（210） |
| `example/proto/roleagent/mail.sproto` | 邮件协议与结构：`list`/`send`/`claim`（220–222） |
| `example/proto/roleagent/rank.sproto` | 排行榜协议与结构：`submit`/`top`（230/231） |
| `example/schema/role.sproto` | 角色 ORM schema：角色文档与模块表 |
| `example/schema/bag.sproto` | 背包 ORM schema：`role_bag`/`bag`/`resource` |
| `example/schema/mail.sproto` | 邮件 ORM schema：`role_mail`/`mail`/`mail_sender`/`mail_attach` |
| `example/schema/rank.sproto` | 排行榜 ORM schema：`rank`/`rank_entry` |
| `example/schema/schema.lock.lua` | schema 基线锁：字段指纹与已退休名字，供 `skyext schema check` 对比 |

### 11.6 `example/res/` 与 `example/hotfix/`

| 文件 | 作用 |
| --- | --- |
| `example/res/hero.lua` | 示例英雄配表（数值与名称） |
| `example/res/lazy/param.lua` | 全局参数表（`NameLimit`、`InitItem` 等），首次读取时懒加载 |
| `example/res/lazy/hotfix_demo.lua` | 热更示例专用配表（仅热更包引用） |
| `example/hotfix/20260120-patch1/hotfix.conf.lua` | 热更包描述：校验和、`update_files`、`reload_*` 开关、`code_files` |
| `example/hotfix/20260120-patch1/code1.lua` | 热更注入代码：在 role 实体里读一次配表，验证 `reload_res` 生效 |

### 11.7 `example/tools/`

| 文件 | 作用 |
| --- | --- |
| `example/Makefile` | 示例构建入口（8 个目标）：`build`/`proto`/`schema`/`format`/`lint`/`dist`/`clean`/`game_clean`；`clean` 依赖 `game_clean`，`dist` 依赖 `build`；include `build.mk` |
| `example/tools/proto2spb.lua` | sproto 文本编译为 `.spb` 的脚本 |
| `example/tools/browser_e2e.mjs` | phaser-game 浏览器全链路 E2E（OAuth→选服→建角→进游戏→两种断线续接） |
| `example/tools/etcd/docker-compose.yml` | 三节点 etcd 本地集群（2379/2378/2377） |
| `example/tools/mongodb/docker-compose.yml` | 单节点 MongoDB 6（27017） |
| `example/tools/gamepass/` | 第三方登录鉴权服务（submodule，Go）：OAuth 签发 JWT，供联调 |
| `example/tools/phaser-game/` | 示例 Phaser 浏览器客户端（submodule）：登录/选服/建角/游戏场景与 TS SDK 接入 |

两个子模块内部目录（`gamepass` 的 `config/`、`db/`、`handlers/`、`middlewares/`、`models/`、`services/`、`utils/`、`static/`、`templates/`；`phaser-game` 的 `src/` 下 auth、config、lib、managers、scenes、services、types、ui 各目录，以及 `public/`）由各自仓库维护，本仓库只作为联调用例引用。

## 12. `docs/`

| 文件 | 作用 |
| --- | --- |
| `docs/architecture.md` | 本文：逐目录、逐文件的架构与职责索引 |
| `docs/README.md` | 文档索引与阅读顺序 |
| `docs/_sidebar.md` | docsify 侧边栏 |
| `docs/index.html` | docsify 站点入口/首页 |
| `docs/.nojekyll` | 让 GitHub Pages 跳过 Jekyll 处理 |
| `docs/getting-started.md` | 依赖、构建、启动、测试、常见问题 |
| `docs/overview.md` | 架构概览：分层、节点、启动链、核心能力位置、部署形态 |
| `docs/non-goals.md` | 做过又删掉的设计与理由（日志脱敏、ORM 迁移、GM 权限分级等） |
| `docs/guide/client_protocol.md` | 客户端接入规范：传输格式、会话状态机、客户端五条义务 |
| `docs/guide/client_sdk.md` | 官方 Lua/TypeScript SDK 的安装、用法、错误码与验收 |
| `docs/guide/login.md` | 登录与选服流程 |
| `docs/guide/login_diagram.md` | 登录时序图（mermaid） |
| `docs/guide/fullstack_client.md` | gamepass + phaser-game 全链路联调 |
| `docs/guide/hotfix.md` | 热更包、预演、执行与失败处理 |
| `docs/guide/gm_api.md` | GM HTTP API：token、命令查询与执行 |
| `docs/guide/http_server.md` | HTTP 服务端：命名实例、连接/超时上限、路由注册 |
| `docs/guide/metrics.md` | 指标原语、Prometheus 端点与内置指标 |
| `docs/guide/orm_schema_change.md` | 改 ORM schema：字段增删容忍、改名/改类型拦截 |
| `docs/design/entity_system.md` | 实体系统设计（已实现） |
| `docs/design/skytest.md` | 测试框架与覆盖率设计（已实现） |
| `docs/design/profiler.md` | 火焰图采集设计（原型阶段） |
| `docs/plan/architecture_refactor.md` | 逻辑服 + 共享基础设施的重构规划（部分实现） |
| `docs/plan/admin_panel.md` | 管理后台规划（未实现） |
| `docs/archive/README.md` | 归档说明 |
| `docs/archive/session_resume.md` | 会话续接与 WS 接入的落地记录 |
| `docs/archive/client_sdk_plan.md` | 客户端双 SDK 的实施记录 |

`design/`、`plan/`、`archive/` 不发布到在线文档站；规划文档不代表已交付。

## 13. `public/`

| 文件 | 作用 |
| --- | --- |
| `public/gm.html` | 单页 GM 命令面板：填 token、列命令、按参数表单执行 |

## 14. `.github/`

| 文件 | 作用 |
| --- | --- |
| `.github/workflows/build-release.yml` | 多平台构建与发布打包：linux/macosx/windows 走矩阵（windows 用 mingw 目标构建），freebsd 是独立 job |
| `.github/workflows/coverage.yml` | CI：构建、Lua 测试与覆盖率门槛、TypeScript 检查与测试、文档站部署 |
| `.github/workflows/lint.yml` | 搜索路径检查（`scripts/ci/check_paths.lua`）+ Luacheck + `stylua --check` |

## 15. 生成物与运行时目录（Git 忽略）

| 路径 | 来源与用途 |
| --- | --- |
| `luaclib/` | `build.mk` 编译的 C 模块（cjson、lfs、crypto、tool_process、traceback、profiler_c、skytest/hook） |
| `cservice/` | 编译出的 C 服务（`profiler.so`） |
| `bin/skynet`、`bin/lua`、`bin/luac` | 从 `skynet/` 拷贝的运行时 |
| `example/build/lualib/game/orm/` | `skyext generate schema` 产出的 ORM schema |
| `example/build/proto/sproto.spb` | `skyext generate proto` 产出的协议包 |
| `example/luaclib/`、`example/cservice/` | 游戏层自有 C 模块/服务（当前示例为空） |
| `logs/` | 各节点日志（`account.log`、`role1.log` 等）与 `bootfail.log` |
| `example/tools/etcd/etcd*_data`、`example/tools/mongodb/db` | 本地 etcd/MongoDB 数据 |
| `hotfix_history.jsonl` | 节点执行热更后的历史记录 |
| `example/skyext.zip`、`release-assets/` | 打包产物 |
| `coverage/` | 覆盖率报告 |
| `node_modules/` | SDK 与前端工具的依赖 |

## 16. 按任务找入口

| 想改的东西 | 先看这里 |
| --- | --- |
| 客户端连不上 / 登录失败 | `service/gate_tcp.lua`、`service/gate_ws.lua`、`example/service/login/`、`docs/guide/login.md` |
| 实体加载、路由、锁 | `lualib/skyext/entity/`、`service/entity_agent*.lua`、`docs/design/entity_system.md` |
| 断线续接 / 下行重放 | `lualib/skyext/entity/session.lua`、`sdk/lua/skyext/client/session.lua`、`sdk/ts/src/session.ts` |
| 存库 / 回存 / schema 兼容 | `lualib/skyext/dbmgr.lua`、`lualib/orm/init.lua`、`scripts/commands/schema.lua` |
| 加协议 | `example/proto/` → `skyext generate proto` → `example/nodes/role/modules/*/request.lua` |
| 加配置/配表 | `example/etc/nodes/common.app.lua`、`example/res/`、`skyext.config` |
| 加 GM 命令 | `lualib/skyext/gm_api.lua` / `service/gm_sys.lua`、`docs/guide/gm_api.md` |
| 加 HTTP 接口 | `lualib/skyext/http_server/`、`docs/guide/http_server.md` |
| 加指标 | `lualib/skyext/metrics*.lua`、`docs/guide/metrics.md` |
| 加节点 | `example/etc/*.conf.lua`、`example/etc/nodes/*.app.lua`、`example/nodes/<start>/main.lua`、`paths.conf.lua` 的命名约束 |
| 加 CLI 命令 | `scripts/skyext.lua`、`scripts/commands/` |

## 17. 维护本文

- 新增目录/文件：在对应表格补一行，写「谁在什么时机用它」，不写实现细节。
- 删除/改名：同步删除或改写，避免留下指向不存在路径的条目。
- 规划与现状分开：规划写入 `docs/plan/`，落地后再更新本文与 `docs/overview.md`。
