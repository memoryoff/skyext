# skyext 生产化验收与缺陷收敛计划（2026-11-12）

> **状态：代码侧缺陷已收敛，并由真实模块契约测试验证；真实故障验证（P1-06 / P1-07）与压测数据仍待环境。**
> **修订（2026-11-12 复核）：** 第四批曾写"全部 P0 与 P1 已实施"，但 122 个用例测的是桩，
> 迁移 export / attach 与 Outbox 回执在真实调用链上仍是断的（详见 §8）。该口径已撤回。
> **核实基准：** 本仓库 `main` @ `6bfc9c5`，逐条回源码验证，不采信审查报告的行号与结论。
> **本轮定位：** 不新增功能，只做缺陷收敛与真实故障验证。审查报告把"实施完善度"压到 80 分，
> 与源码一致的部分见 §1，与源码不符或需要限定的部分也一并标出。

---

## 1. 审查报告核实结论

| 编号 | 报告结论 | 核实 | 证据 |
| --- | --- | --- | --- |
| P0-01 | `migration_coordinator` 缺 `CMD.start`，`migration.enabled = true` 时节点起不来 | **成立** | `example/lualib/launcher.lua` 对每个可选服务调 `start`；该服务只定义了 `set_adapter` / `run` / `stats`。原 `launcher.test.lua` 用桩把 `start` 一律返回 `true`，所以测试全绿而真实服务不可启动——这是"测试验证了桩，没验证契约" |
| P0-02 | 迁移只有编排，没有业务适配器 | **成立，且文档自认** | `migration_coordinator.lua` 的 `default_adapter()` 返回空列表；`docs/design/migration_v1.md` §6 明确列出网关重指向、Fence 认领、跨节点回环未实现 |
| P0-03 | 可选服务先于实体系统启动 | **成立** | `launcher_node()` 末尾调 `launch_optional_services()`，而 `entity_agentmgr` 由节点入口在之后才创建 |
| P1-01 | Outbox 无 DELIVERED 回写与清理 | **成立** | `DELIVERED` 只是 `outbox.STATUS` 的常量，生产路径无任何写入点；只有 `outbox.test.lua` 用到 |
| P1-02 | `validate` 抛错被报成资产提交 `UNKNOWN` | **成立** | 该分支在 PREPARE 之前，不写库、不隔离、无恢复任务，而 `critical.query` 只会回 `NOT_STARTED` |
| P1-03 | 迁移超时后 hook 协程未取消，与卸载并发 | **成立** | `node_shutdown.run_hooks_with_deadline` 超时只记日志，`skynet.fork` 出去的协程继续跑 |
| P1-04 | 账本容量与归档吞吐未证明 | **成立，属验证缺口而非缺陷** | `MAX_OPS = 512`、归档 64 条/轮、60 秒一轮都是初始配置 |
| P1-05 | `critical.query` 冷账本读取无异常保护 | **成立** | 提交路径同一处查询用 `pcall`，查询路径直接调 `critical_find` |

报告未提、本轮顺带修掉的两处：

- `migration_coordinator` 的 `DEP_NAMES` 漏了 `probe`，导致 `migration.wait_busy` 永远拿不到探针，
  **所有 BUSY 实体必然降级**（静默少一次等待机会）。
- 可选服务原挂在 `launcher_node()` 上，而 `account` / `gateway` 节点也调它：一旦打开
  `outbox_worker`，每个非实体节点都会各起一份调度器。改成"实体就绪后再起"顺带消除了这个隐患。

---

## 2. 已实施（本批）

### 2.1 P0-01 迁移协调器启动门禁

`service/migration_coordinator.lua`

- 新增 `CMD.start(conf)`：校验 `enabled` → 取适配器（`set_adapter` 注入优先，否则 `require(conf.adapter)`）
  → 校验六个必需阶段 → 可选 `adapter.init(conf)` → 注册 `migrate` 停服钩子。
  任一步失败返回 `false, reason`，launcher 让节点启动失败。
- 停服钩子从 `skynet.start` 移到 `CMD.start`：没通过门禁就不该挂上一个"会跑迁移"的钩子。
- `CMD.run` 在未启动时明确失败，不再用空实体列表伪装成功。
- `CMD.stats()` 改为 `{ installed, type_name, adapter }`，抓取端能判断迁移到底开没开。
- `probe` / `fallback` 作为可选阶段透传，`probe` 缺失不再静默降级（缺了就没有 BUSY 等待）。

### 2.2 P0-03 启动顺序

- `launcher_node()` 只做基础设施与 Mongo 索引门禁，**不再启动可选服务**。
- 新增 `launcher_entities(type_names)`：逐个创建 `entity_agentmgr`，`start` 后**再问一次 `is_ready`**，
  不是 `true` 就报错。返回即代表实体系统可接请求。
- `example/nodes/role/main.lua` 固定为：`launcher_node` → `launcher_entities` → `admin`
  → `launch_optional_services` → `launcher_gate`。
- `account` / `gateway` 节点不再触发任何依赖实体路由的后台服务。

### 2.3 P1-02 `validate` 异常不再伪装成 UNKNOWN

- 新增 `critical.STATUS.INTERNAL_ERROR`：`NO_CACHE`、不进 L1、不隔离、无 `recovery_id`。
- 语义与 `critical.query` 对齐：这次操作确实没开始（`NOT_STARTED`），允许受控重试。
- 下游影响已核对：Outbox 接收方会把它抛给可靠消息（进死信、人工可见），
  支付回调落到 5xx 让渠道重推，都不会被当成成功 ACK。

### 2.4 P1-05 查询路径异常保护

- `critical.query` 的冷账本读取改为 `pcall(opts.ledger.critical_find, ...)`，
  抛错与返回 err 一样转成结构化 `UNKNOWN`（`reason = "ledger read raised: ..."`）。

### 2.5 本批第二批：P0-02 实体侧三段

- `entitymgr:list_loaded()`：只读枚举 `id` / `conn_id` / `owner_epoch` / `session_epoch` /
  `critical_unknown`（查 `dbmgr.cached_critical` 的未决意图）/ `busy` / `persistent`。
- `entitymgr:quiesce` / `unquiesce`：在实体队列里冻结，取消空闲卸载计时器；
  快照一旦导出（`entity.migration_exported`）就不再允许撤销冻结。
- `entitymgr:release_for_migration`：落库 + 释放锁 + `session.unbind`，
  **不踢客户端**；`_release_lock` 新增 `detach` 分支，`release_detach` 会带到卸载重试上。
- `entity_agent`：`migration_list` / `migration_quiesce` / `migration_unquiesce` /
  `migration_release` 四个命令；`CMD.client_msg` 对冻结实体静默丢弃上行。
- `entity_agentmgr.migration_list`：跨 agent 聚合，补 `agent_index`；单 agent 失败只记日志。
- 网关：`gate_owner.upstream_allowed` + 两个网关的 `handler.message`/`forward`，
  屏障期间上行一并丢弃，新增 `skyext_gate_frozen_upstreams_total`。

### 2.6 第三批：P0-02 目标侧接管与适配器

- `session.attach(conn_id, entity, owner_service, owner_epoch)`：先 `resume_owner`，
  网关认账后才推进本地 epoch、挂连接记录、进入 replaying；`migrating` 一并清掉
  （快照可能带着源端的冻结标记）。
- `entity_agent`：`migration_stage`（目标暂存，TTL 60s / 上限 64）、
  `migration_commit`（`with_entity` 抢锁 = Fence 认领 + 装快照，失败保留暂存）、
  `session_attach`（接管连接 + 重放）；`FRAMEWORK.session_attach`。
- `example/lualib/migration_adapter.lua`：六阶段 + 目标选择（HRW 优先，指回自己时
  从服务发现另选）+ 降级（已冻结未释放才解冻）。
- 配置：`migration.adapter = "migration_adapter"`。

### 2.7 第四批：P1-01 / P1-03 / P1-04 / P1-08 / P1-09

- **P1-01 Outbox 闭环**：接收方在业务终态后经 `router.reliable_send` 发 `outbox_ack`
  （不轮询，避免跨实体死锁）；源端 `FRAMEWORK.outbox_ack` → `outbox.mark_delivered`
  一次 CAS 推进 `DELIVERED`（允许 `PENDING → DELIVERED`，回执可能比状态 CAS 更早到）；
  `outbox.cleanup` 与容量腾挪负责删除；可靠消息投递改用 `handler.resolve` 解析框架命令。
- **P1-03 取消令牌**：`node_shutdown` 超时给 migrate 钩子发 `cancel`；协调器置位并把
  `is_cancelled` 传进 `migration.run`，每个阶段边界检查；已开始的实体走 FALLBACK，
  未开始的计入 `stats.cancelled` 交给卸载。
- **P1-08 并发**：`migration.run` 支持 `opts.concurrency` + `deps.parallel`，
  协调器用 `skynet.fork` 起 N 条流水线（默认 4）。
- **P1-09 半卸载实体**：`unquiesce` 在 `persisted` / `unloading` 时拒绝，
  不再把"释放失败"的实体误报成"留在本节点继续服务"。
- **P1-04 容量预警**：80% 预警（按实体只打一次）+ `skyext_critical_archive_lag_seconds`
  + `skyext_critical_outbox_evicted_total`；压测步骤写进 `p17_verification.md`，
  **数值仍未测**。

### 2.8 验证

```bash
./bin/skyext test                      # 122 files, 122 passed
lua scripts/ci/check_paths.lua .       # passed
luacheck .                             # 308 files, 0 warnings / 0 errors
stylua --check .                       # 通过
```

新增/改写的用例：`service/migration_coordinator.test.lua`（启动门禁 6 例 + 运行 6 例）、
`example/lualib/launcher.test.lua`（顺序契约 3 例）、`critical.test.lua`（`INTERNAL_ERROR` 1 例、
账本抛错 2 例）、`entitymgr.test.lua`（迁移三段 7 例）、`entity_agent.test.lua`
（接线 5 例 + 接管 6 例）、`entity_agentmgr.test.lua`（枚举聚合 2 例）、`gate_owner.test.lua`
（上行屏障 3 例）、`gate_ws.test.lua`（冻结期间上行 2 例）、`session.test.lua`（接管 5 例）、
`migration_adapter.test.lua`（枚举/六阶段/降级/与真实编排状态机联跑，18 例）。
第四批新增：`outbox.test.lua`（回执/DELIVERED/清理 5 例 + 回执断言）、`critical.test.lua`
（容量腾挪 2 例 + 预警 2 例）、`migration.test.lua`（取消 3 例 + 并发 4 例）、
`migration_coordinator.test.lua`（取消令牌 2 例）、`node_shutdown.test.lua`（截止取消 2 例）、
`entitymgr.test.lua`（框架命令投递 2 例 + 半卸载拒绝 1 例）、`entity_agent.test.lua`
（Outbox 回执 3 例）。

---

## 3. P0-02 业务迁移适配器（已完成，待真实回环验证）

**闭环已打通**：源端枚举/冻结/释放 → 快照送达目标暂存 → 目标抢锁认领并安装 →
目标接管连接并重放。剩余只有真实双节点回环验证与并发/取消（见 §5）。

### 3.1 原语

| 能力 | 位置 |
| --- | --- |
| 枚举 / 冻结 / 撤销冻结 / 释放（不踢人） | `entitymgr:list_loaded` / `quiesce` / `unquiesce` / `release_for_migration`，经 `entity_agent.migration_*` 与 `entity_agentmgr.migration_list` 暴露 |
| 导出/安装会话快照 | `entity_agent.FRAMEWORK.session_export` / `session_import`（`cluster.call` 可达） |
| 目标暂存 / 认领安装 / 接管连接 | `migration_stage` / `migration_commit` / `session_attach` |
| 网关屏障与重指向 | `CMD.freeze_owner` / `CMD.resume_owner`；屏障覆盖**上行**（`gate_owner.upstream_allowed`） |
| 目标侧接管 | `session.attach`：先 `resume_owner` 再改本地 epoch 与连接记录 |
| 示例适配器 | `example/lualib/migration_adapter.lua`（`migration.adapter = "migration_adapter"`） |

### 3.2 关键不变量

1. **接管先问网关**：`session.attach` 必须 `resume_owner` 成功后才推进本地 `owner_epoch`；
   反过来的话网关拒绝时本地已推进，之后所有下行被当迟到包丢弃且无法回滚。
2. **目标显式寻址**：`transfer` / `handoff` / `activate` 用 `cluster.call(target_node, ...)`，
   不能用 `router.call`（HRW 会转回源节点）。
3. **先释放再认领**：`transfer` 里源端 `migration_release` 必须在目标 `migration_commit`
   之前，否则目标抢不到 etcd 锁。
4. **冻结期上行静默丢弃**：不回错误码——没有 `errcode` 字段的协议会走断连兜底。

### 3.3 验收

- 已完成：单测覆盖六阶段调用顺序、目标选择回退、各阶段拒绝路径、降级分流，
  并用真实 `migration.run` 跑通 `list → quiesce → freeze → export → release → stage →
  commit → attach` 全序列。
- 待完成：真实双节点 + 真实客户端（连接不断、`session_epoch` 不变、`owner_epoch` 前进、
  序号不重不漏、在途上行不重复执行）。

---

## 4. P1-01 Outbox 投递闭环（已完成）

原状：`PENDING → ENQUEUED` 之后没人收尾，`_critical_outbox_v1` 只增不减，
必然撞 `MAX_OUTBOX = 512` 触发 `CAPACITY_EXCEEDED`（受控拒绝，但玩家功能就废了）。

实际实现与最初的"源端轮询"设想不同——轮询要么得加载离线角色，要么在实体队列里
跨实体调用，两个角色互相等就是死锁。改成**接收方回执**：

1. 接收方在 `COMMITTED` / `BUSINESS_REJECTED` / `PRECHECK_REJECTED` 后，
   `router.reliable_send(source, "outbox_ack", { event_id })`。可靠消息持久化，
   源角色离线时随下次加载投递。
2. 源端 `FRAMEWORK.outbox_ack` → `outbox.mark_delivered`：一次 CAS 到 `DELIVERED`，
   幂等；允许 `PENDING → DELIVERED`（回执可能比状态 CAS 更早到，计数恰好减一次）。
3. 清理：容量不足时腾 `DELIVERED`（任意年龄）与超过 7d 的 `ENQUEUED`，
   **与新增事件同一次 CAS**；`outbox.pump` 收尾时清超过 7d 的终态事件。
   `PENDING` 永远不删。
4. 可靠消息投递改用 `handler.resolve`（`handler_of`）解析命令，否则框架命令
   `outbox_ack` 永远 "no handler" 进死信队列。
5. 观测：`skyext_outbox_acked_total{result}`、`skyext_outbox_delivered_seconds{op_type}`、
   `skyext_outbox_evicted_total{reason}`、`skyext_critical_outbox_evicted_total{reason}`。

遗留：回执多一次 `entity_msg` 写入，压测时要算进接收方写放大。

---

## 5. P1-03 迁移取消与并发（已完成）

取消：
- `node_shutdown` 超时后给 migrate 钩子发 `cancel`（`skynet.send`），协调器置位；
- `migration.run` 把 `is_cancelled` 传进 `migrate_entity`，每个阶段边界检查，
  命中即 `FALLBACK`；未开始的实体计入 `stats.cancelled`，交给卸载。

并发：
- `migration.run` 支持 `opts.concurrency` + `deps.parallel(tasks)`；协调器用
  `skynet.fork` 起 N 条流水线，每条从共享下标取实体（默认 4，配置
  `migration.concurrency`）；
- 没有 `deps.parallel` 时退化成串行，单测与单进程部署不引入协程依赖。

遗留：并发度没有压测依据；它直接放大 Mongo 与网关的瞬时压力，实测后再定值。

---

## 6. 验证矩阵（P1-04 / P1-06 / P1-07）

| 验证项 | 方法 | 通过标准 |
| --- | --- | --- |
| Mongo 多数派切主 | 三节点副本集 `rs.stepDown()`，切主期间并发关键操作 | 无重复资产效果；`UNKNOWN` 全部能被 `critical.query` 归位 |
| 网络分区 | `iptables` 丢 minority 侧写入 | 写入 fail-closed，恢复后对账收敛 |
| etcd 租约抖动 | 暂停 etcd 10s | 实体不丢锁、不重复加载；恢复后服务发现收敛 |
| 双节点迁移回环 | 两 skynet 节点 + 一个客户端，GM shutdown 源节点 | 连接不断、序号不重不漏、`owner_epoch` +1 |
| 账本容量 | 单角色 1k/5k/10k 关键操作压测 | 归档 P95、CAS 冲突率、`MAX_OPS` 预警阈值有数据支撑 |
| 文档体积 | 关键字段 BSON 大小随操作数增长 | 512 条内不超 512 KiB 预算 |

容量结论出来之前，不要调大 `MAX_OPS`，也不要把 `archive_limit` 当性能参数随意放大。

---

## 7. 执行顺序

1. ~~P0-01 / P0-03~~（已完成）
2. ~~P1-02 / P1-05~~（已完成）
3. ~~P0-02：实体枚举 → quiesce → release → 目标暂存/认领/接管 → 适配器模块~~（已完成）
4. ~~P1-01：DELIVERED 回写 → 清理 → 指标~~（已完成）
5. ~~P1-03 / P1-08：取消令牌 + 迁移并发~~（已完成）
6. ~~P1-09：半卸载实体拒绝解冻~~（已完成）
7. ~~P1-04：容量预警指标~~（已完成，**数值待压测**）
8. **P1-06 / P1-07**：真实副本集切主、真实迁移回环（这两项是"能不能上生产"的判据）
9. **P1-04 数值 / P2-01~07**：压测数据、文档对齐、Saga 复杂交易用例

**口径**：代码侧 P0/P1 已全部落地，**且经第五批（§8）的真实契约测试验证过跨模块链路**，
但 P1-06 / P1-07 与压测数值仍缺，所以对外表述只能是"已实现，待生产验证"，
不能写成"已验证"。

---

## 8. 第五批：真实契约断链修复（复核后）

第四批的 122 个用例全绿，但 `migration_adapter.test.lua` 用假 `skynet.call` 直接返回快照、
`launcher.test.lua` 用恒真的 `start` 桩、`entity_agent.test.lua` 用不做 epoch 校验的假
`session`。三处跨模块契约因此从未被验证：

| 断链 | 修复 |
| --- | --- |
| `session_export` 只在 `FRAMEWORK` 里，适配器直接当 CMD 调用必被 `cmd_api` 判为未知命令，export 阶段全部 FALLBACK | 新增 `CMD.session_export`（`in_entity` 包装），适配器补齐 `entity_id` 参数 |
| `session_import` 提前把 `io_.owner_epoch` 推到目标代际，`session.attach` 传入自身 epoch 必然自拒，网关屏障无人解除 | 快照携带 `source_owner_epoch`；目标侧按源端代际装载，`migration_target_epoch` 留给 attach 认领一次；网关 `resume_owner(target)` |
| 回执用 map 传 `router.reliable_send`，`entitymgr._deliver_one` 的 `table.unpack` 只解数组，handler 收到 `msg_id` 数字，`mark_delivered` 永远拒绝 | `ack_source` 改成数组 `{ { event_id } }`，与 `outbox_worker.default_deliver` 一致 |
| `PRECHECK_REJECTED` 被当持久化终态 ACK（源端资产已扣、事件被删且永不重投） | 移出终态集合，抛错进死信人工可见；`INTERNAL_ERROR` 改走 `delivery.retryable` 受控重试（连续阈值会升级人工） |
| `migration = { enabled = true }` 因 `x = x or {...}` 整表替换丢掉 adapter，节点启动失败 | `common.app.lua` 改为逐字段合并默认值 |
| DELIVERED 保留期两套口径（容量腾挪隐式 0 秒）、触顶不发 80% 预警、归档驱动抛异常上抛、`archive_lag` 恒 >= 7 天 | 统一到 `OUTBOX_DELIVERED_RETENTION`；预警独立于腾挪；归档写加 `pcall` 转结构化失败；滞后改为"超期后的额外等待" |

**验证（本批口径以测试为准）**：

```bash
./bin/skyext test                 # 124 files, 124 passed, 0 failed
luacheck .                        # 309 files, 0 warnings
stylua --check .                  # 通过
lua scripts/ci/check_paths.lua .  # 通过
make -C example lint              # 44 files, 0 warnings
sdk/ts: npx tsc --noEmit          # 通过
```

新增 `lualib/skyext/fix_contract.test.lua`：用 `loadfile` 加载**真实模块源码**（只桩外部依赖），
断言真实 CMD 表存在 `session_export`、真实适配器在该分发下能拿到快照、真实
`session.attach` 接受严格前进的 epoch、真实回执链能把事件推进到 `DELIVERED`。
新增 `example/etc/nodes/common.app.test.lua` 覆盖配置合并。其余回归断言同步更新。

**本批未覆盖（如实列出）**：P1-03 的取消令牌只能停在阶段边界，卡在无超时
`cluster.call` 里的协程仍无法打断；P1-06 副本集 `stepDown`、P1-07 双节点回环、
压测数值、P2-02 Saga 复杂交易用例仍待真实环境。这些不是"已修复"。
