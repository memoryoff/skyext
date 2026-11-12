# skyext 缺陷台账（2026-11-12）

> **用途**：本轮「生产化验收与缺陷收敛」的唯一问题清单。所有修复、验证、排期以此为准，
> 不再散落在审查报告、收敛计划和对话记录里。
>
> **基准**：`main` 分支，外部实施审查报告（`memoryoff/skyext`，2026-11-12）→
> 提交 `9c34398`（第四批修复）→ 第五批「真实契约断链修复」。
>
> **证据写法**：用 `文件:函数/符号` 定位；行号仅作参考，会随提交漂移。
>
> **验收口径**：只有「新增/改写的自动化测试通过 + 全量门禁通过」才能把状态改成「已修」。
> 需要真实副本集、双节点或真实客户端的项，只能标「待环境」，不得写成「已验证」。
>
> **全量门禁**：`./bin/skyext test`、`luacheck .`、`stylua --check .`、
> `lua scripts/ci/check_paths.lua .`、`make -C example lint`、`sdk/ts: npx tsc --noEmit`。

---

## 1. 总览

| 分类 | 数量 | 说明 |
| --- | --- | --- |
| 已修复并验证（第五 ~ 七批） | 15 | 契约断链、取消兜底、回执归属、启动自检、回执唤醒，124 files / 124 passed |
| 代码层待修 | 7 | 本文件 §3，均有明确的测试验收标准 |
| 部分完成 | 1 | R-07 指标：迁移取消/兜底、恢复任务 due 已埋点，PREPARED 时长仍缺 |
| 需真实环境验证 | 7 | 本文件 §4，不是代码写错，是没跑过 |
| 设计权衡（记录不改） | 4 | 本文件 §5，改了反而更危险 |
| 后续优化 | 3 | P2 类，不阻塞生产验收 |

> **提交基线**：`ed9d05a`（第五批 + 本台账首次建立）。第六批修复在工作区，尚未提交。

原始审查报告 12 项修复清单（P0-01 ~ P2-02）的状态映射见 §6。

---

## 2. 已修复并验证（第五批，本台账建立前的基线）

> 验证：`124 files / 124 passed`；luacheck 309 files 0 警告；stylua / check_paths /
> example lint(44) / tsc --noEmit 全通过。`docs/review-2026-11-12-convergence-plan.md` §8 有详细记录。
> 新增契约测试 `lualib/skyext/fix_contract.test.lua`（真实 CMD 表、真实 `session.attach`、
> 真实回执链）与 `example/etc/nodes/common.app.test.lua`（配置合并）。

| 编号 | 问题 | 修复 | 验证用例 |
| --- | --- | --- | --- |
| F-01 | `session_export` 只在 `FRAMEWORK` 中，适配器按 CMD 直调必被 `cmd_api` 判未知命令，export 阶段全 FALLBACK | `entity_agent` 新增 `CMD.session_export`；`migration_adapter.export` 补齐 `entity_id` | `fix_contract.test.lua` 真实 CMD 表断言；`migration_adapter.test.lua` 参数断言 |
| F-02 | `session_import` 提前把 `io_.owner_epoch` 写成 target，`session.attach` 传自身 epoch 必然自拒，网关屏障无人解除 | 快照带 `source_owner_epoch`，目标按源端代际装载，`migration_target_epoch` 留给 attach 认领一次 | `fix_contract.test.lua` 真实 `session.attach`；`entity_agent.test.lua` 代际断言 |
| F-03 | 回执用 map 传 `reliable_send`，`table.unpack` 只解数组，handler 收到 `msg_id` 数字，`DELIVERED` 永远写不进 | `ack_source` 改数组 `{ { event_id } }` | `fix_contract.test.lua` 真实回执链到 `DELIVERED`；`outbox.test.lua` 数组形状断言 |
| F-04 | `PRECHECK_REJECTED` 被当持久化终态 ACK：源端已扣资产、事件被删且永不重投 | 移出终态集合，抛错进 DLQ 人工可见 | `outbox.test.lua` 不 ACK + 抛错用例 |
| F-05 | `INTERNAL_ERROR` 全仓无下游，`outbox.handle` 把它当契约失败进死信 | 走 `delivery.retryable`（连续阈值自动升级人工 = 受控重试）；`pay_webhook` 归入暂态，回 200 保持 GRANTING | `outbox.test.lua` retryable 用例；`pay_webhook.test.lua` 新增用例 |
| F-06 | `migration = { enabled = true }` 因 `x = x or {...}` 整表替换丢 adapter，节点启动失败 | `common.app.lua` 用 `with_defaults` 逐字段合并 | `common.app.test.lua` 4 例 |
| F-07 | DELIVERED 保留期两套口径（容量腾挪隐式 0 秒） | 统一到 `critical.OUTBOX_DELIVERED_RETENTION`，触顶显式传 0 | `critical.test.lua` 默认/触顶两组用例 |
| F-08 | 80% 预警挂在 `elseif`，真正触顶腾挪时反而不发 | 预警独立于腾挪 | `critical.test.lua` 触顶仍预警用例 |
| F-09 | 归档 `ledger:critical_find_and_modify` 无 pcall，驱动抛错上抛被维护服务吞成静默失败 | 加 pcall 转结构化失败，热条目保留 | `critical.test.lua` 驱动抛错用例 |
| F-10 | `archive_lag` 用 `now - oldest`，候选必然超期导致指标恒 ≥ 7 天、在 0 与 7 天间跳变 | 抽成纯函数 `M.archive_lag = max(0, now - oldest - retention)` | `critical_maintenance.test.lua` 口径用例 |

---

## 3. 代码层待修（可在本地闭环，按优先级）

### 3.0 第六 / 七批已修（第七批在工作区，未提交）

| 编号 | 修复 | 验证 |
| --- | --- | --- |
| R-01（部分） | 适配器新增 `begin_round` / `abort`：登记「已冻结但未 activate」的实体，`CMD.cancel` 时主动 `kick` 让网关会话连同 `frozen_epoch` 一起销毁；`call_agent` / `call_gate` 在取消后拒绝新的阶段 RPC（kick 除外）；`node_shutdown` 超时发 cancel 后加 10 tick 宽限。协调器 `CMD.run` 复位适配器状态，`CMD.stats().abort` 可观测，新增 `skyext_migration_cancelled_total` / `skyext_migration_abort_clients_total` | `migration_adapter.test.lua` 5 例、`migration_coordinator.test.lua` 2 例；124 files / 124 passed |
| R-02 | `outbox.is_valid_event_id` 在边界拒绝畸形 ID（含可靠消息追加的数字 `msg_id`），`FRAMEWORK.outbox_ack` 对畸形/错投回执抛错进 DLQ；回执携带 `receiver_type/receiver_id`，`mark_delivered` 用 `expect_target` 校验事件归属；`ack_source` 带接收方坐标 | `outbox.test.lua` 3 例、`entity_agent.test.lua` 3 例；124 files / 124 passed |
| R-11 | `launcher_entities` 用 `pcall(skynet.call, ...)` 统一「抛异常 / 返回 false」两种失败形态，错误信息带实体类型名与原因，删掉死分支 | `launcher.test.lua` 2 例；124 files / 124 passed |
| R-05 | `router.reliable_send` 新增 `opts.lazy`：回执仍持久化、重投仍再发（ACK 可能丢），但只通知**已加载**的源实体，不为一条回执加载离线角色；新增 `notify_reliable_loaded` 走 `deliver_reliable_loaded` | `router.test.lua` 2 例、`outbox.test.lua` 1 例断言 lazy；124 files / 124 passed |
| R-06 | `launcher.self_check()` 输出 enabled/disabled/problems 结构化摘要，`launcher_node` 在索引门禁后打印；启用但缺 `type_name`/`adapter`/`providers` 会 `log.error` | `launcher.test.lua` 4 例；124 files / 124 passed |
| R-07（部分） | `critical_reconciler` 每轮按状态统计 due 任务并 `set` 到 `skyext_critical_reconcile_due_jobs{state}`，`stats.due` 可断言；PREPARED 时长仍未埋点 | `critical_reconciler.test.lua` 2 例；124 files / 124 passed |

> R-01 只做到**兜底清理**，没有给跨节点 RPC 加 deadline；卡在 `cluster.call` 里的协程仍无法中断，
> 见 R-01 条目的「建议修复 ②」，这一半仍未完成。

### R-01 · P1-03 取消令牌打不断阶段内 RPC，超时后网关屏障残留 【高 · 兜底已修，RPC deadline 待修】

- **现象**：`node_shutdown.run_hooks_with_deadline` 超时只 `skynet.send(..., "cancel")` 且**不等待**协程结束，随即 `unload_entities` → `skynet.abort()`。`migration_coordinator.CMD.cancel` 仅置 `g_cancelled`；`migration.migrate_entity` 只在阶段边界检查 `is_cancelled`。
- **证据**：`service/node_shutdown.lua:run_hooks_with_deadline`、`service/migration_coordinator.lua:CMD.cancel`、`lualib/skyext/migration.lua:cancelled`、`example/lualib/migration_adapter.lua:call_agent/call_gate`（`cluster.call` / `skynet.call` 无超时）。
- **影响**：worker 卡在 `migration_commit` 的跨节点 RPC 时，源端已 `migration_release`、网关已 `freeze_owner`；进程退出后没有任何一方执行 `resume_owner` 或 `fallback` 的 `kick`，该连接的上下行被网关永久丢弃，只能等客户端超时重连。
- **建议修复**：① 给协调器增加 `abort` 兜底：cancel 时遍历「已冻结但未 activate」的实体，调网关 `resume_owner` 解屏障并 `kick` 让客户端重登；② 给阶段 RPC 加 deadline（或至少在阶段边界再校验一次代际租约），并把已开始的实体标记为 `FALLBACK/ABORTED`。
- **验收标准**：注入「`migration_commit` 永不返回」+ 停服超时，断言 `resume_owner`/`kick` 被调用、`g_inflight` 清空、`stats.cancelled` 与实体数一致；且重复 cancel 幂等。

### R-02 · Outbox 回执缺归属与格式校验 【高 · 已修，见 §3.0】

- **现象**：`FRAMEWORK.outbox_ack` 直接取 `args.event_id`（或 `args` 本身），不校验格式、前缀、来源；`outbox.mark_delivered` 允许 `PENDING → DELIVERED`。
- **证据**：`service/entity_agent.lua:FRAMEWORK.outbox_ack`、`lualib/skyext/outbox.lua:mark_delivered`。
- **影响**：任意能向源实体发可靠消息的内部调用方，只要猜到/拿到 `event_id`，就能把**尚未投出**的 PENDING 事件直接标成 DELIVERED 并被清理；源端资产已在同一次 CAS 扣除，业务效果却永不发生。
- **建议修复**：校验 `event_id` 为 `EVENT_PREFIX` 开头的定长字符串；回执只接受来自该事件 `target_type/target_id` 的消息（或由 capability/HMAC 绑定）；`PENDING → DELIVERED` 必须限定为「可靠消息已入队」的证据，否则拒绝。
- **验收标准**：伪造/畸形 `event_id` 被拒且事件状态不变；对 PENDING 事件的回执不推进；合法回执仍幂等推进到 DELIVERED。

### R-03 · Outbox 终态清理不成环 【中】

- **现象**：`outbox._finish_pump` 只在 `stats.pending == 0` 时调 `cleanup`；`outbox_worker.scan` 只查 `_critical_outbox_pending_count > 0` 的角色。
- **证据**：`lualib/skyext/outbox.lua:_finish_pump` / `M.cleanup`、`lualib/skyext/outbox_worker.lua:scan`。
- **影响**：回执丢失后事件停在 ENQUEUED、`pending_count` 归零，该角色不再被扫描；`_critical_outbox_v1` 里的终态/超期记录只能等下一次产生新事件、或撞容量上限时才被腾挪。长期静默高活跃角色的审计记录只增不减。
- **建议修复**：为终态事件增加独立的扫描入口（按 `updated_at` 的 TTL 索引或轻量扫描），或在 worker 每轮固定抽样清理；清理失败只记日志不影响投递。
- **验收标准**：构造「只有 ENQUEUED/DELIVERED、pending_count=0」的角色，跑一轮 worker 后终态记录被清；PENDING 永不被清。

### R-04 · PENDING 永不腾 + 512 上限导致永久拒绝 【中】

- **现象**：`critical.evictable_outbox_events` 明确「PENDING 永不腾」，超过 `MAX_OUTBOX = 512` 返回 `CAPACITY_EXCEEDED`。
- **证据**：`lualib/skyext/critical.lua:commit_core` / `evictable_outbox_events`、`lualib/skyext/outbox.lua:pump`（`deliver` 失败保持 PENDING）。
- **影响**：可靠消息或 Mongo 长时间不可写时，新事件持续堆积到 512，该角色**所有**关键操作被永久拒绝（即使依赖恢复，也要先人工清事件）。
- **建议修复**：区分「可重试的投递失败」与「事件本身」，给 PENDING 设置带保留期的告警/降级路径（例如写入独立的 `_critical_outbox_backlog` 集合、或允许在明确标记后腾挪并保留可重投锚点），并保证受控拒绝可自动恢复。
- **验收标准**：模拟 `deliver` 连续失败至触顶，断言依赖恢复后角色能自动恢复提交，且不丢事件、不重复入账。

### R-05 · 回执写放大与离线源角色加载 【中 · 已修，见 §3.0】

- **现象**：`RECEIVER_MT:ack_source` 在接收方实体队列内同步 `router.reliable_send`（内部 `save` + `poke_reliable`），会尝试唤醒/加载离线源角色；重投命中 COMMITTED 的历史结果时仍再发一条 ACK。
- **证据**：`lualib/skyext/outbox.lua:ack_source`、`lualib/skyext/entity/router.lua:reliable_send/poke_reliable`。
- **影响**：一次跨实体事件多一次 Mongo 写 + 一次可能的实体加载（抢锁、读库）；压测时这是接收方写放大的主要来源。
- **建议修复（已修正原判断）**：重投命中历史结果时**仍必须再发 ACK**——ACK 可能丢失，跳过会让源端事件永远停在 ENQUEUED；真正该优化的是唤醒方式：只通知已加载实体，不为一条回执加载离线源角色。
- **验收标准**：重复投递同一事件只产生一条回执；可统计「回执数 / 事件数」并纳入压测指标。

### R-06 · P2-06 启动配置自检缺失 【中 · 已修，见 §3.0】

- **现象**：只有每个可选服务自己的 `CMD.start` 做门禁，没有统一的「哪些服务未启用、哪些依赖缺失」的启动期自检。
- **证据**：`example/lualib/launcher.lua:launch_optional_services`、`example/etc/nodes/common.app.lua`。
- **影响**：`pay_callback.providers = {}` 这类「服务起来了但没有渠道」的配置，或 gateway 节点上配了 `pay_callback.enabled=true` 却静默不启动，只能靠日志排查。
- **建议修复**：在 `launcher_node` 输出一份结构化自检摘要（已启用 / 未启用 / 依赖缺失），对「启用但关键依赖为空」显式告警或拒绝启动。
- **验收标准**：配置矩阵用例覆盖「缺 providers」「非实体节点启用实体依赖服务」「全部关闭」三种情况，断言摘要与启动行为。

### R-07 · P2-04 指标覆盖不完整 【中 · 部分完成，见 §3.0】

- **缺口**：`skyext_critical_reconcile_jobs{state}`（恢复任务扫描口径，目前只有任务表可查）、
  `PREPARED 持续时间`、`迁移取消次数`（现在只有 `log.warn`）、`reconcile 队列年龄`。
- **已具备**：`skyext_outbox_delivered_seconds`、`skyext_outbox_acked_total`、`skyext_critical_archive_lag_seconds`、
  `skyext_critical_capacity_warning_total`、`skyext_gate_frozen_upstreams_total` 等。
- **证据**：`docs/design/p17_verification.md` §1 末尾「还没埋点的指标」、`service/critical_maintenance.lua`、
  `service/migration_coordinator.lua:CMD.cancel`。
- **验收标准**：每项指标有对应单测断言其在状态迁移时 `inc/set`，且不会把 `conn_id` 之类的高基数值当标签。

### R-08 · P2-05 Grant 未来 `issued_at` 无时钟偏差窗口 【低】

- **现象**：`grant.lua` 只校验 `issued_at >= 0` 与 `expires_at > issued_at`，没有对「未来时间」设置允许的时钟偏差。
- **证据**：`lualib/skyext/grant.lua:issue`（`issued_at` / `expires_at` 校验）。
- **影响**：签发侧与验证侧时钟不同步时，合法 Grant 会被误拒（或反之，未来签发的 Grant 提前生效）。
- **建议修复**：增加可配置的 `clock_skew`，验证时 `now + skew >= issued_at` 才接受；默认值写进示例配置。
- **验收标准**：偏差内接受、超出偏差拒绝、完全过期拒绝，三例。

### R-09 · P2-03 Outbox 同秒事件依赖 ID 排序 【低】

- **现象**：事件按 `event_id`/秒级时间戳排序，没有持久化因果序号。
- **证据**：`lualib/skyext/outbox.lua:event` / `new_event_id`、`lualib/skyext/entity/reliable_msg.lua` 头部注释（明确不保证并发生产者严格全序）。
- **影响**：严格要求顺序的业务（如同一角色连续扣/加）无法依赖 Outbox 保证顺序。
- **建议修复**：为需要顺序的业务提供可选的持久化 `causal_seq`（按实体 CAS 自增），不要改可靠消息既有的 `msg_id` 语义。
- **验收标准**：同实体并发事件按 `causal_seq` 严格有序；不启用时行为不变。

### R-10 · P2-02 Saga 复杂业务实战验证不足 【低】

- **缺口**：双角色交易、重复补偿、协调者崩溃、补偿 ACK 丢失四组用例。
- **证据**：`lualib/skyext/saga.test.lua` 现有以单实体状态机为主。
- **验收标准**：四组用例全部通过，且断言「同一业务操作最多一次经济效果」。

### R-11 · `launcher_entities` 的错误分支是死代码 【低 · 已修，见 §3.0】

- **现象**：`if not ok then error("entity system ... failed to start")` 永远不会触发，因为 `entity_agentmgr.start` 失败走 `error(err, 0)`，`skynet.call` 直接抛异常。
- **证据**：`example/lualib/launcher.lua:launcher_entities`、`service/entity_agentmgr.lua:CMD.start`。
- **建议修复**：用 `pcall(skynet.call, ...)` 包住并统一错误信息，或删掉死分支只保留 `is_ready` 复查。
- **验收标准**：注入 agentmgr start 抛错，断言节点启动失败且错误信息包含实体类型名。

### R-12 · conn_id 高基数指标标签 【低】

- **现象**：`conn_id` 含 `boot_id` + 单调序号，若作为 Prometheus 标签会造成高基数。
- **证据**：`lualib/skyext/connection_id.lua`、各网关指标埋点。
- **建议修复**：日志保留完整 `conn_id`，指标只用 `gate 类型 / 结果分类`；补一条 CI 静态检查禁止把 `conn_id` 传进指标标签。
- **验收标准**：全仓扫描指标标签参数不含 `conn_id`；已有指标行为不变。

---

## 4. 需真实环境验证（不是代码缺陷，不得写成「已验证」）

| 编号 | 验证项 | 现状 | 通过标准 |
| --- | --- | --- | --- |
| V-01 · P1-06 | 三节点副本集 `rs.stepDown()` + 并发关键操作 | 待跑 | 无重复资产效果；所有 UNKNOWN 能被 `critical.query` 归位；`_critical_ops_v1` 同一 op_id 只有一条 |
| V-02 · P1-07 | 双 skynet 节点 + 真实客户端迁移回环 | 待跑 | 连接不断、`session_epoch` 不变、`owner_epoch` +1、下行序号不重不漏、在途上行不重复执行 |
| V-03 | Mongo 网络分区（minority 侧写入） | 待跑 | 写入 fail-closed，恢复后对账收敛 |
| V-04 | etcd 租约抖动（暂停 10s） | 待跑 | 实体不丢锁、不重复加载，恢复后服务发现收敛 |
| V-05 | 真实 WebSocket 网络回环（握手期断网、ACK 丢） | 待跑 | 六状态机转移次数正确、配额归零、续接按 `(session_epoch, seq)` 去重 |
| V-06 · P1-04 | 账本容量压测（1k/5k/10k 关键操作） | 数值未采集 | 归档 P95/P99、CAS 冲突率、BSON 大小、`MAX_OPS` 预警阈值、腾挪次数有数据支撑 |
| V-07 · P2-07 | 自动化压测脚本 + 固定硬件基准报告 | 仓库只有指标与注入点 | 脚本可复跑，报告含硬件规格与原始数值 |

> `docs/design/p17_verification.md` §3 已有 B1 / P00-C / 跨节点回环的执行步骤。
> `critical.integration.test.lua` 使用真实 MongoDB，但单节点副本集的 `w:majority` **不能**证明真实多数派切主语义。

---

## 5. 设计权衡（记录，不改）

| 项 | 为什么保持现状 |
| --- | --- |
| ENQUEUED 超 7 天删源端副本 | 可靠消息层 `entity_msg` 仍持久化该消息，DLQ 也保留；源端副本只用于观测与去重。删它不等于丢事件 |
| 容量触顶显式放弃 DELIVERED 保留期 | 触顶时先腾终态再决定是否 `CAPACITY_EXCEEDED`，比直接拒绝玩家更可取；已显式传 `delivered_retention = 0`，不再是隐式行为 |
| 迁移冻结期上行静默丢弃 | 协议没有对应 `errcode`，回错误码会走断连兜底；客户端按超时重传同一 `req_id`，由新 owner 的幂等缓存回应 |
| 只有 `role` 节点调 `launch_optional_services` | `pay_callback` 是纯 HTTP 服务，在 account/gateway/robot 各起一份会端口冲突；其余三个服务都依赖实体路由，本就不该在非实体节点启动 |

---

## 6. 原始审查报告 12 项状态映射

| 报告编号 | 状态 | 说明 |
| --- | --- | --- |
| P0-01 | 已修 + 已验证 | `CMD.start` 门禁存在；`common.app.lua` 合并默认值后 `migration={enabled=true}` 不再启动失败（F-06） |
| P0-02 | 已修 + 已验证（代码链路） | 适配器 + 三段接管 + 真实契约测试（F-01/F-02）；真实双节点回环仍属 V-02 |
| P0-03 | 已修 | 启动顺序 node → entities(READY) → optional → gate；非实体节点不再起实体依赖服务 |
| P1-01 | 部分修 | DELIVERED 回写链路已通并通过契约测试（F-03），回执归属/格式（R-02）与懒唤醒（R-05）已修；清理闭环与 PENDING 容量兜底见 R-03/R-04 |
| P1-02 | 已修 + 已验证 | `INTERNAL_ERROR` + outbox/pay_webhook 下游（F-05） |
| P1-03 | **部分修** | `CMD.cancel`、阶段边界检查、取消时的网关屏障兜底（kick + 拒绝后续阶段 RPC）已实现；仍缺给跨节点 RPC 加 deadline，见 R-01 ② |
| P1-04 | 部分修 | 80% 预警、归档滞后指标已修（F-08/F-10）；压测数值见 V-06 |
| P1-05 | 已修 | `critical.query` 冷账本 pcall；归档写路径 pcall（F-09） |
| P1-06 | 待环境 | V-01 |
| P1-07 | 待环境 | V-02 |
| P2-01 | 部分修 | 收敛计划 §8 已撤回错误口径并同步本台账；`session_snapshot_v1.md` / `outbox_saga_v1.md` / `p17_verification.md` 仍需逐篇对齐 |
| P2-02 | 待修 | R-10 |

**对外表述**：核心架构已实现，跨模块契约已由自动化测试验证；真实故障验证与容量压测尚未完成，**暂不具备生产部署资格**。

---

## 7. 建议修复顺序

1. R-01 剩余半项：给 `cluster.call` / `skynet.call` 加 deadline 与阶段租约。**注意**：单纯超时返回会让源端 FALLBACK 而目标端仍可能完成 commit/attach，必须同时有迁移代际校验，否则是伪修复
2. R-03 / R-04（长期运行容量：终态清理成环、PENDING 触顶可自动恢复）
3. R-07 剩余：PREPARED 意图持续时间
4. R-08 ~ R-10、R-12（低风险补齐，可与 P2-01 文档对齐一起做）
5. V-01 / V-02 / V-06 / V-07（真实环境，是「能不能上生产」的判据）

**每完成一项**：在本文档把状态改成「已修」并注明验证用例与门禁结果，再进入下一项。
