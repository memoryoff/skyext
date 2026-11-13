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

> 本节数字以本文件实际条目为准；上一版存在重复行（「需真实环境验证」写了两遍）
> 与总数不自洽（写 21，实际 F-01~F-10 + R-01~R-12 = 22），已修正。

| 分类 | 数量 | 说明 |
| --- | --- | --- |
| 已修复并验证（第五 ~ 九批） | 22 | F-01 ~ F-10、R-01 ~ R-12 |
| 对抗审查发现 · 已修 | 14 | A-01 ~ A-14，见 §8 |
| 第二轮源码审计 · 已修 | 8 | B-01 ~ B-08（DB Fence / Critical Commit），见 §10 |
| 第三轮对抗审查 · 已修 | 11 | C-01 ~ C-11，见 §11 |
| 第四轮全量对抗审查 · 已修 | 37 | D-01 ~ D-37，见 §12 |
| 复核 `5bc8073` · 已修 | 8 | RV-01 ~ RV-08，见 §13 |
| 阻塞生产的 P0 | 1（已修） | 原有 5 条 P0 已收敛；本轮发现并修复 A-06 递归合并引入的配置执行环境回归，见 §12.7 |
| 需真实环境验证 | 5 | V-01/V-06 已实测；V-02 ~ V-05 与 V-07 生产硬件基准仍待跑 |
| 设计权衡（记录不改） | 4 | 见 §5 |
| 后续优化 | 3 | P2 类，不阻塞生产验收 |

> **提交基线**：`3ed7287`（已推送到 `origin/main`，含 §12 台账、第一批修复与 §13 复核修正）。
> 14 个提交在推送前做过一次 `filter-branch`，SHA 与 §12/§13 里记录的本地 SHA 不同，见 §14。
>
> **口径**：只把「代码改完 + 新增测试通过 + 全量门禁通过」记为已修；
> 需要真实多节点 / 故障注入的项一律标「待环境」，不写「已验证」。

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

### 3.0 第六 ~ 九批已修（第九批在工作区，未提交）

| 编号 | 修复 | 验证 |
| --- | --- | --- |
| R-01（部分） | 适配器新增 `begin_round` / `abort`：登记「已冻结但未 activate」的实体，`CMD.cancel` 时主动 `kick` 让网关会话连同 `frozen_epoch` 一起销毁；`call_agent` / `call_gate` 在取消后拒绝新的阶段 RPC（kick 除外）；`node_shutdown` 超时发 cancel 后加 10 tick 宽限。协调器 `CMD.run` 复位适配器状态，`CMD.stats().abort` 可观测，新增 `skyext_migration_cancelled_total` / `skyext_migration_abort_clients_total` | `migration_adapter.test.lua` 5 例、`migration_coordinator.test.lua` 2 例；124 files / 124 passed |
| R-02 | `outbox.is_valid_event_id` 在边界拒绝畸形 ID（含可靠消息追加的数字 `msg_id`），`FRAMEWORK.outbox_ack` 对畸形/错投回执抛错进 DLQ；回执携带 `receiver_type/receiver_id`，`mark_delivered` 用 `expect_target` 校验事件归属；`ack_source` 带接收方坐标 | `outbox.test.lua` 3 例、`entity_agent.test.lua` 3 例；124 files / 124 passed |
| R-11 | `launcher_entities` 用 `pcall(skynet.call, ...)` 统一「抛异常 / 返回 false」两种失败形态，错误信息带实体类型名与原因，删掉死分支 | `launcher.test.lua` 2 例；124 files / 124 passed |
| R-05 | `router.reliable_send` 新增 `opts.lazy`：回执仍持久化、重投仍再发（ACK 可能丢），但只通知**已加载**的源实体，不为一条回执加载离线角色；新增 `notify_reliable_loaded` 走 `deliver_reliable_loaded` | `router.test.lua` 2 例、`outbox.test.lua` 1 例断言 lazy；124 files / 124 passed |
| R-06 | `launcher.self_check()` 输出 enabled/disabled/problems 结构化摘要，`launcher_node` 在索引门禁后打印；启用但缺 `type_name`/`adapter`/`providers` 会 `log.error` | `launcher.test.lua` 4 例；124 files / 124 passed |
| R-07（部分） | `critical_reconciler` 每轮按状态统计 due 任务并 `set` 到 `skyext_critical_reconcile_due_jobs{state}`，`stats.due` 可断言；PREPARED 时长仍未埋点 | `critical_reconciler.test.lua` 2 例；124 files / 124 passed |
| R-07（完成） | `critical_maintenance` 对每个 PREPARED 意图 `observe(skyext_critical_prepared_seconds)`，恢复任务队列年龄可看趋势 | `critical_maintenance.test.lua` 走真实 metrics，无断言值；口径由 `scan_intents` 的 `prepared_at` 保证 |
| R-08 | `critical.GRANT_CLOCK_SKEW = 60`，`execute_client` 对「未来签发超过窗口」返回 `INTERNAL_AUTH_DENIED`，窗口内放行 | `critical.test.lua` 2 例（超出拒绝 / 窗口内提交） |
| R-04（部分） | `outbox.evictable` 与 `critical.evictable_outbox_events` 把 `FAILED` 纳入可腾范围（与 DELIVERED 同保留期），避免死信事件被 512 上限永久占位 | `outbox.test.lua` 清理用例、`critical.test.lua` 默认保留期用例 |
| R-01（完成） | 目标端新增 `CMD.migration_abort` + barrier 校验：源端 abort 先通知目标、再踢客户端；`migration_stage` 拒绝已取消 barrier 的迟到快照；`migration_commit` 先看取消标记再看暂存。**deadline 仍不做**：它必须与迁移代际校验一起设计，而当前「源端放弃、目标端接管」的竞态已被目标端拒绝堵住 | `entity_agent.test.lua` 3 例、`migration_adapter.test.lua` 2 例 |
| R-03（完成） | `_finish_pump` 按 `CLEANUP_INTERVAL=60s` 定期清理，不再只在 `pending == 0` 时清；静默角色仍由容量腾挪兜底 | `outbox.test.lua` 1 例 |
| R-04（完成） | `pump` 连续投递失败达到 `MAX_DELIVER_ATTEMPTS=5` 时把事件标 `FAILED` 并继续投后续事件，解决「毒事件永久阻塞同角色 outbox」；`FAILED` 可腾 | `outbox.test.lua` 3 例 |
| R-09 | `critical` 在同一次 CAS 分配 `_critical_outbox_seq`，事件带 `causal_seq`；`pending_events` 优先按因果序号排序，缺失时回退 `created_at` | `critical.test.lua` 1 例、`outbox.test.lua` 2 例 |
| R-10 | Saga 四组复杂交易：双角色 exactly-once、补偿 ACK 丢失、协调者崩溃接管、重复手工补偿拒绝 | `saga.test.lua` 4 例 |
| R-12 | 新增 `scripts/ci/check_metrics_labels.lua`，禁止 `conn_id` / `rid` / `msg_id` 等高基数字段作指标标签，接入 `lint.yml` | 本地 186 files 通过 |

> R-01 只做到**兜底清理**，没有给跨节点 RPC 加 deadline；卡在 `cluster.call` 里的协程仍无法中断，
> 见 R-01 条目的「建议修复 ②」，这一半仍未完成。

### R-01 · P1-03 取消令牌打不断阶段内 RPC，超时后网关屏障残留 【高 · 已修（竞态已堵，deadline 不做）】

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

### R-03 · Outbox 终态清理不成环 【中 · 已修，见 §3.0】

- **现象**：`outbox._finish_pump` 只在 `stats.pending == 0` 时调 `cleanup`；`outbox_worker.scan` 只查 `_critical_outbox_pending_count > 0` 的角色。
- **证据**：`lualib/skyext/outbox.lua:_finish_pump` / `M.cleanup`、`lualib/skyext/outbox_worker.lua:scan`。
- **影响**：回执丢失后事件停在 ENQUEUED、`pending_count` 归零，该角色不再被扫描；`_critical_outbox_v1` 里的终态/超期记录只能等下一次产生新事件、或撞容量上限时才被腾挪。长期静默高活跃角色的审计记录只增不减。
- **建议修复**：为终态事件增加独立的扫描入口（按 `updated_at` 的 TTL 索引或轻量扫描），或在 worker 每轮固定抽样清理；清理失败只记日志不影响投递。
- **验收标准**：构造「只有 ENQUEUED/DELIVERED、pending_count=0」的角色，跑一轮 worker 后终态记录被清；PENDING 永不被清。

### R-04 · PENDING 永不腾 + 512 上限导致永久拒绝 【中 · 已修，见 §3.0】

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

### R-07 · P2-04 指标覆盖不完整 【中 · 已修，见 §3.0】

- **缺口**：`skyext_critical_reconcile_jobs{state}`（恢复任务扫描口径，目前只有任务表可查）、
  `PREPARED 持续时间`、`迁移取消次数`（现在只有 `log.warn`）、`reconcile 队列年龄`。
- **已具备**：`skyext_outbox_delivered_seconds`、`skyext_outbox_acked_total`、`skyext_critical_archive_lag_seconds`、
  `skyext_critical_capacity_warning_total`、`skyext_gate_frozen_upstreams_total` 等。
- **证据**：`docs/design/p17_verification.md` §1 末尾「还没埋点的指标」、`service/critical_maintenance.lua`、
  `service/migration_coordinator.lua:CMD.cancel`。
- **验收标准**：每项指标有对应单测断言其在状态迁移时 `inc/set`，且不会把 `conn_id` 之类的高基数值当标签。

### R-08 · P2-05 Grant 未来 `issued_at` 无时钟偏差窗口 【低 · 已修，见 §3.0】

- **现象**：`grant.lua` 只校验 `issued_at >= 0` 与 `expires_at > issued_at`，没有对「未来时间」设置允许的时钟偏差。
- **证据**：`lualib/skyext/grant.lua:issue`（`issued_at` / `expires_at` 校验）。
- **影响**：签发侧与验证侧时钟不同步时，合法 Grant 会被误拒（或反之，未来签发的 Grant 提前生效）。
- **建议修复**：增加可配置的 `clock_skew`，验证时 `now + skew >= issued_at` 才接受；默认值写进示例配置。
- **验收标准**：偏差内接受、超出偏差拒绝、完全过期拒绝，三例。

### R-09 · P2-03 Outbox 同秒事件依赖 ID 排序 【低 · 已修，见 §3.0】

- **现象**：事件按 `event_id`/秒级时间戳排序，没有持久化因果序号。
- **证据**：`lualib/skyext/outbox.lua:event` / `new_event_id`、`lualib/skyext/entity/reliable_msg.lua` 头部注释（明确不保证并发生产者严格全序）。
- **影响**：严格要求顺序的业务（如同一角色连续扣/加）无法依赖 Outbox 保证顺序。
- **建议修复**：为需要顺序的业务提供可选的持久化 `causal_seq`（按实体 CAS 自增），不要改可靠消息既有的 `msg_id` 语义。
- **验收标准**：同实体并发事件按 `causal_seq` 严格有序；不启用时行为不变。

### R-10 · P2-02 Saga 复杂业务实战验证不足 【低 · 已修，见 §3.0】

- **缺口**：双角色交易、重复补偿、协调者崩溃、补偿 ACK 丢失四组用例。
- **证据**：`lualib/skyext/saga.test.lua` 现有以单实体状态机为主。
- **验收标准**：四组用例全部通过，且断言「同一业务操作最多一次经济效果」。

### R-11 · `launcher_entities` 的错误分支是死代码 【低 · 已修，见 §3.0】

- **现象**：`if not ok then error("entity system ... failed to start")` 永远不会触发，因为 `entity_agentmgr.start` 失败走 `error(err, 0)`，`skynet.call` 直接抛异常。
- **证据**：`example/lualib/launcher.lua:launcher_entities`、`service/entity_agentmgr.lua:CMD.start`。
- **建议修复**：用 `pcall(skynet.call, ...)` 包住并统一错误信息，或删掉死分支只保留 `is_ready` 复查。
- **验收标准**：注入 agentmgr start 抛错，断言节点启动失败且错误信息包含实体类型名。

### R-12 · conn_id 高基数指标标签 【低 · 已修，见 §3.0】

- **现象**：`conn_id` 含 `boot_id` + 单调序号，若作为 Prometheus 标签会造成高基数。
- **证据**：`lualib/skyext/connection_id.lua`、各网关指标埋点。
- **建议修复**：日志保留完整 `conn_id`，指标只用 `gate 类型 / 结果分类`；补一条 CI 静态检查禁止把 `conn_id` 传进指标标签。
- **验收标准**：全仓扫描指标标签参数不含 `conn_id`；已有指标行为不变。

---

## 4. 需真实环境验证（不是代码缺陷，不得写成「已验证」）

| 编号 | 验证项 | 现状 | 通过标准 |
| --- | --- | --- | --- |
| V-01 · P1-06 | 三节点副本集 `rs.stepDown()` + 并发关键操作 | **已验证（2026-11-13）**：本机 MongoDB 7.0.35 三节点副本集执行切主，term 2 → 3，主节点 `127.0.0.1:27022 → 127.0.0.1:27021`；持续 writer 在切主前后各有 4 个 worker 成功写，最终 `documents=1`、`version=hits=158`、`pre=93`、`post=65`。同时通过真实 MongoDB 的 critical 索引/CAS/保留字段 4 例与 reliable message 1 例集成测试 | 切主前后都有并发成功写；无重复资产效果；所有 UNKNOWN 能被 `critical.query` 归位；`_critical_ops_v1` 同一 op_id 只有一条 |
| V-02 · P1-07 | 双 skynet 节点 + 真实客户端迁移回环 | 待跑 | 连接不断、`session_epoch` 不变、`owner_epoch` +1、下行序号不重不漏、在途上行不重复执行 |
| V-03 | Mongo 网络分区（minority 侧写入） | 待跑 | 写入 fail-closed，恢复后对账收敛 |
| V-04 | etcd 租约抖动（暂停 10s） | 待跑 | 实体不丢锁、不重复加载，恢复后服务发现收敛 |
| V-05 | 真实 WebSocket 网络回环（握手期断网、ACK 丢） | 待跑 | 六状态机转移次数正确、配额归零、续接按 `(session_epoch, seq)` 去重 |
| V-06 · P1-04 | 账本容量压测（512 条事件 / 512 条操作满载） | **已跑（2026-11-12）**：`scripts/ci/bench_critical_capacity.sh` 在本地三节点副本集上实测。见下方数值 | 归档 P95/P99、CAS 冲突率、BSON 大小、`MAX_OPS` 预警阈值、腾挪次数有数据支撑 |
| V-07 · P2-07 | 自动化压测脚本 + 固定硬件基准报告 | **已提供脚本**：`scripts/ci/bench_critical_capacity.sh`；数值见下方 V-06 | 脚本可复跑，报告含硬件规格与原始数值 |

#### V-06 实测数值（2026-11-12，macOS 本地，三节点副本集 rs0，majority 写关注）

环境：单机三进程 mongod（27021-27023），`wiredTigerCacheSizeGB=0.25`，localhost 回环。
**这不是生产硬件**，数值用于判断数量级与相对关系，不能直接当容量上限。

| 指标 | 数值 |
| --- | --- |
| Outbox 满载（512 事件）文档大小 | **194,877 字节**（EJSON 上界，约 190KB） |
| 热账本满载（512 操作）文档大小 | **108,136 字节**（约 105KB） |
| 触顶提交（腾 1 条 + 新增 1 条 + 推进水位，单次 CAS） | **p50 66ms / p95 139ms / p99 143ms** |
| 归档一轮（64 次 upsert + 1 次 unset），**有** `rid+op_id` 索引 | **p50 104ms / p95 123ms / p99 255ms**，≈615 op/s |
| 归档一轮，**没有**索引（索引门禁被绕过） | **p50 115ms / p95 4226ms / p99 4270ms** |

结论：

1. **索引门禁必须保留。** 没有 `rid+op_id` 唯一索引时，冷账本 upsert 退化成 COLLSCAN，
   P95 从 123ms 涨到 4226ms（**34 倍**），而且随账本增长继续恶化。这就是
   `critical.ensure_indexes` 存在的理由，不是形式主义。
2. **文档体积不是瓶颈。** 512 条满载也只有约 190KB，离 16MB 上限两个数量级。
   512 这个上限的真实约束来自"单次提交要重写整份文档"，不是 BSON 大小。
3. **触顶提交 66ms 偏慢，值得关注。** 满载时每次提交都要重写约 190KB 文档。
   这意味着 Outbox 长期贴着 512 上限跑会让关键操作延迟明显上升——
   `CAPACITY_WARN_RATIO=0.8` 的预警线应该按这个延迟来调，而不是等撞顶。
4. **归档吞吐 ≈615 op/s 足够。** 单角色按每小时几百次关键操作估算，
   64 条/轮的批量远快于产生速度；真正的风险是索引缺失或长期不归档。

复跑：`scripts/ci/bench_critical_capacity.sh [mongo_uri] [rounds]`（默认 40 轮）。

> `docs/design/p17_verification.md` §3 已有 B1 / P00-C / 跨节点回环的执行步骤。
> **V-02 ~ V-05、V-07 的可执行步骤已单独整理成
> [`docs/design/p17_pending_verification_runbook.md`](p17_pending_verification_runbook.md)**：
> 含环境准备（etcd 三节点、Mongo 副本集、`make build`）、必改配置、启动顺序、
> 每项的注入方式 / 观察指标 / 通过标准 / 记录模板，以及失败定位顺序。
> 到环境上照着跑，跑完把结果贴回本节。
>
> `critical.integration.test.lua` 使用真实 MongoDB，但单节点副本集的 `w:majority` **不能**证明真实多数派切主语义。
>
> **V-01 复跑方式**（需要三节点副本集）：
>
> ```bash
> # 起临时副本集（示例端口，dbpath 放 /tmp）
> for i in 1 2 3; do
>   mongod --replSet rs0 --port 2702$i --dbpath /tmp/skyext-rs/$i --bind_ip 127.0.0.1 --fork \
>     --logpath /tmp/skyext-rs/$i.log --wiredTigerCacheSizeGB 0.25
> done
> mongosh --port 27021 --eval 'rs.initiate({_id:"rs0",members:[
>   {_id:0,host:"127.0.0.1:27021"},{_id:1,host:"127.0.0.1:27022"},{_id:2,host:"127.0.0.1:27023"}]})'
>
> SKYTEST_INTEGRATION=1 MONGO_PORT=27021 ./bin/skyext test
> scripts/ci/verify_replica_stepdown.sh
> ```
>
> 其余 V 项（V-02 ~ V-07）需要双节点 / 网络分区 / etcd 抖动 / 真实客户端 / 压测环境，
> 本机不具备，**未执行**，不得写成「已验证」。

---

## 5. 设计权衡（记录，不改）

| 项 | 为什么保持现状 |
| --- | --- |
| ENQUEUED 超 7 天删源端副本 | 可靠消息层 `entity_msg` 仍持久化该消息，DLQ 也保留；源端副本只用于观测与去重。删它不等于丢事件 |
| 容量触顶显式放弃 DELIVERED 保留期 | 触顶时先腾终态再决定是否 `CAPACITY_EXCEEDED`，比直接拒绝玩家更可取；已显式传 `delivered_retention = 0`，不再是隐式行为 |
| 迁移冻结期上行静默丢弃 | 协议没有对应 `errcode`，回错误码会走断连兜底；客户端按超时重传同一 `req_id`，由新 owner 的幂等缓存回应 |
| 只有 `role` 节点调 `launch_optional_services` | `pay_callback` 是纯 HTTP 服务，在 account/gateway/robot 各起一份会端口冲突；其余三个服务都依赖实体路由，本就不该在非实体节点启动 |
| 毒事件隔离后**放弃保序**（A-10） | 阈值内 break 保序；达到阈值说明这条事件短期不会成功，继续挡着会让整个角色饿死。两阶段行为不同是主动取舍，不是矛盾。代价是接收方可能乱序收到同一角色的事件，因此接收侧必须用 `service_op_id` 去重 + 参数自校验。契约写在 `outbox.MAX_DELIVER_ATTEMPTS` 注释与对应用例里 |
| 补偿是**至少一次**（A-14） | ACK 丢失与补偿失败在协调者看来不可区分，所以 `compensate` 会被重复调用。状态机只保证"离开 COMPENSATING 一次"，业务补偿必须自带幂等键。改成"恰好一次"需要补偿侧持久化去重表，成本远高于要求 handler 幂等 |

---

## 6. 原始审查报告 12 项状态映射

| 报告编号 | 状态 | 说明 |
| --- | --- | --- |
| P0-01 | 已修 + 已验证 | `CMD.start` 门禁存在；`common.app.lua` 合并默认值后 `migration={enabled=true}` 不再启动失败（F-06） |
| P0-02 | 已修 + 已验证（代码链路） | 适配器 + 三段接管 + 真实契约测试（F-01/F-02）；真实双节点回环仍属 V-02 |
| P0-03 | 已修 | 启动顺序 node → entities(READY) → optional → gate；非实体节点不再起实体依赖服务 |
| P1-01 | 已修 + 已验证 | DELIVERED 回写（F-03）、回执归属/格式（R-02）、懒唤醒（R-05）、定期清理成环（R-03）、毒事件隔离（R-04）、FAILED 保留期下限（A-09）、回执丢失角色的清理可达性（A-08）全部落地 |
| P1-02 | 已修 + 已验证 | `INTERNAL_ERROR` + outbox/pay_webhook 下游（F-05） |
| P1-03 | 已修（竞态已堵） | 取消兜底 + 目标端 `migration_abort` / barrier 校验已实现；abort 改为先踢后通知（A-11）；RPC deadline 不做，理由见 R-01 |
| P1-04 | 已修 + 已实测 | 80% 预警、归档滞后指标（F-08/F-10）；V-06 实测数值见 §4，含索引门禁 34 倍差异 |
| P1-05 | 已修 | `critical.query` 冷账本 pcall；归档写路径 pcall（F-09） |
| P1-06 | 已修 + 已验证 | V-01：2026-11-13 用新双窗口门禁在本机三节点副本集实测通过，切主前后各有 4 个 worker 成功写，无重复文档且 `_version == hits` |
| P1-07 | 待环境 | V-02 双节点回环，需要两个 skynet 节点 + 真实客户端 |
| P2-01 | 部分修 | 收敛计划 §8、本台账、`p17_verification.md` §3 已同步；`session_snapshot_v1.md` / `outbox_saga_v1.md` 仍需逐篇对齐 |
| P2-02 | 已修 | R-10 四组复杂交易用例；补偿语义（至少一次）已在 A-14 定清 |
| P2-03 | 已修 | R-09 因果序号 + A-03 全序比较器 |
| P2-04 | 已修 | R-07 指标补齐（迁移取消、恢复任务 due、PREPARED 时长） |
| P2-05 | 已修 | R-08 + A-05（`math.tointeger` 归一化，fail-closed） |
| P2-06 | 已修 | R-06 启动配置自检 + A-06 嵌套配置合并 |
| P2-07 | 部分完成 | V-07 脚本已提供（`bench_critical_capacity.sh`）；生产硬件基准仍待采集 |

**对外表述**：核心架构已实现，跨模块契约由自动化测试验证，容量压测与切主双窗口门禁已在本地环境实测；
**双节点迁移回环、网络分区、etcd 租约抖动仍未验证**，因此仍不建议直接生产部署。

---

## 7. 建议修复顺序

1. **代码层已无待修项**：R-01 ~ R-12、A-01 ~ A-14、B-01 ~ B-06 全部收敛，
   `./bin/skyext test` 128 files / 128 passed。
2. **真实环境验证**（不是代码缺陷，不能由单测替代）：
   - V-01 副本集 stepDown —— 2026-11-13 已用 D-31 双窗口新脚本实测通过（见 §4）
   - V-06 容量压测 —— 已实测，数值见 §4（含索引门禁的 34 倍差异）
   - V-02 双节点迁移回环（需要两个 skynet 节点 + 真实客户端）
   - V-03 Mongo 网络分区、V-04 etcd 租约抖动、V-05 真实 WebSocket 回环
   - V-07 压测脚本已提供（`scripts/ci/bench_critical_capacity.sh`），生产硬件基准仍待采集
3. R-01 的 RPC deadline 不再作为缺陷项：当前「源端放弃、目标端接管」的竞态已由目标端
   `migration_abort` + barrier 校验堵住；若将来要做 deadline，必须与迁移代际校验一起设计。
4. 剩下 4 项设计权衡见 §5：改动收益低于风险，需要产品级决策，不作为缺陷。

**每完成一项**：在本文档把状态改成「已修」并注明验证用例与门禁结果，再进入下一项。

---

## 8. 对抗审查发现（2026-11-12，第二批）

> 方法：5 个子代理按域并行审查 `9c34398..HEAD` 的未 push 代码，要求"能跑就跑、去证伪"。
> 关键结论由主代理用 `./bin/lua` 加载真实模块复跑确认；已修项用**变异测试**验证
> 新用例真的会变红（改坏实现 → 测试必须失败），不是又一层假绿。

### 8.1 本轮已修（A-01 ~ A-06）

#### A-01 · `_critical_outbox_seq` 写入 Mongo 但不在关键字段白名单 【致命 · 已修】

- **现象**：`critical.lua:commit_core` 把 `_critical_outbox_seq` 写进角色文档，
  但 `critical_fields.FIELDS` 没登记它。`extract` 对未知 `_critical_*` 一律拒绝
  （这是对的，旧代码没资格删新字段），于是 `dbmgr.load` 返回
  `"critical metadata rejected"`。
- **后果**：**任何提交过一次 Outbox 的角色，下次加载就永久登不上**。重启、迁移、
  卸载重载都会触发；`refresh_critical` 同样失败，pump 卡死。
- **为什么 124 个测试全绿**：没有任何用例把"提交后的文档"再喂回 `extract`。
- **修复**：
  - `critical_fields` 新增 `M.OUTBOX_SEQ` 并登记进 `FIELDS`，补非负整数校验；
  - `critical.lua` 的 6 个 `*_FIELD` 常量改为**引用** `critical_fields`，不再各写一份字面量；
  - `outbox.lua` 的 `FIELD` / `PENDING_COUNT_FIELD` 同样改为引用白名单模块
    （不从 `critical` 取——`critical` 会被测试桩替换，取到 nil）。
- **验证**：`fix_contract.test.lua` 新增 4 例，其中一条是**结构性不变式**：
  「`critical` 导出的每个 `*_FIELD` 常量都必须在白名单里」——以后新增字段漏登记会立刻变红。
  变异测试：把字段从 `FIELDS` 移除 → 3 个用例变红。

#### A-02 · `_quarantine_event` 先污染共享缓存再 CAS 【高 · 已修】

- **现象**：`copy_critical` 只复制一层，事件记录仍是缓存里的同一张表；
  `ev.status = FAILED` 在 `critical_update` 之前就地执行。
- **后果**：CAS 被拒后内存缓存显示 FAILED、库里仍是 PENDING，`pending_count` 没减。
  pump 把事件当成已隔离并继续投后续事件，而事件在内存里消失，worker 对着
  `pending_count>0` 的角色永远空扫。
- **修复**：先深拷贝事件再改，并写回 `next_table`（pump 会用返回的表 `set_critical`）。
- **验证**：`outbox.test.lua`「does not corrupt the cached event when the quarantine CAS is rejected」；
  变异回浅拷贝 → 该用例变红。

#### A-03 · `pending_events` 比较器非传递，升级期会乱序 【高 · 已修】

- **现象**：`两边都有 seq 才比 seq，否则退回 created_at`。混合数据下成环：
  A(无 seq, t=10) < B(seq=1, t=20)、B < C(seq=2, t=5)、C < A。
- **后果**：`table.sort` 拿到非传递比较器时行为未定义，可能把后发生的事件先投出去；
  依赖前序的业务会 `PRECHECK_REJECTED` → 进死信，而源端资产已扣。
  滚动升级期每个有历史事件的角色都会命中。
- **修复**：改成单一全序键 `(是否有 seq, seq 或 created_at, event_id)`；
  无 seq 只可能来自升级前，整体排在所有有 seq 的事件之前。
- **验证**：`outbox.test.lua`「keeps a total order when sequenced and legacy events are mixed」；
  变异回旧比较器 → 该用例变红。

#### A-04 · `archive_ops` 批处理中途失败时报 `archived=#moved` 【中 · 已修】

- **现象**：循环里遇到驱动抛错或冷账本未确认就 `return { archived = #moved, ... }`，
  但热账本的 `$unset` 在循环之后才执行。
- **后果**：`service/critical_maintenance` 把这批算成"已归档"，指标虚高、积压被掩盖，
  而热账本其实一条都没删。另外 `call_owner` 只回传两个值，错误串被丢掉。
- **修复**：中途失败返回 `archived = 0, written = #moved, pending = #victims, retry = true`。
  冷账本写是 `$setOnInsert`，重试幂等。
- **验证**：`critical.test.lua`「reports zero archived when the batch fails midway」（3 条 op，
  第 2 条抛错）；变异回 `archived=#moved` → 该用例变红。

#### A-05 · Grant 未来时间检查是 fail-open 的类型门 【中 · 已修】

- **现象**：`math.type(grant_fields.issued_at) == "integer"` 当门。整值浮点
  （JSON 往返、TS Number、某些 BSON 解码都可能产生）会**整条跳过**未来时间检查。
- **修复**：改为 `math.tointeger` 归一化后再比，归一化失败按 fail-closed 拒绝。
- **验证**：`critical.test.lua`「rejects a future grant whose issued_at is an integer-valued float」；
  变异回 `math.type` 门 → 该用例变红。

#### A-06 · `common.app.lua` 只合并顶层，嵌套表被整表替换 【中 · 已修】

- **现象**：注释写"逐字段合并"，实际 `for k,v in pairs(custom) do out[k]=v end` 只合一层。
  运维写 `pay_callback = { orders = { db = "role2" } }` → `orders.coll` 丢失。
- **后果**：`pay_callback` 静默回退默认集合名，订单写进另一个集合——支付链路上很难事后发现。
- **修复**：递归合并；数组仍整表替换（合并数组会得到既不是默认也不是用户意图的结果）。
- **验证**：`common.app.test.lua` 新增 2 例（嵌套合并、默认表不被跨次加载共享）；
  变异回只合顶层 → 变红。

### 8.2 本轮已修（A-07 ~ A-14，第十批）

| 编号 | 问题 | 修复 |
| --- | --- | --- |
| A-07 | 迁移 abort 标记的 TTL 只在**别的实体 stage** 时被 prune；同 barrier 的迟到 stage 在 prune 之前就早退。默认 barrier 是 `mig_<id>`（每轮相同）→ 停服重试时该实体在目标节点上永久迁不进来 | `migration.migrate_entity` 每轮生成唯一 barrier（`mig_<id>_<time>_<seq>`）；`migration_stage` / `migration_abort` / `migration_commit` 都**先 prune 再判取消**；新增 `CMD._test_advance_time` 让 TTL 可测 |
| A-08 | Outbox 定期清理对"回执丢失"角色不可达：worker 只扫 `pending_count>0`，计数归零后不再被扫 | 新增 `_critical_outbox_cleanup_at`（登记白名单 + 校验）；`transition` / `_quarantine_event` / `mark_delivered` 与状态同一次 CAS 落标记；`cleanup` 清理后重算或删除标记；worker 用 `$or(pending>0, cleanup_at<=now)` 扫描并新增偏索引 |
| A-09 | 投递失败计数不区分环境故障（Mongo 抖动 5 次≈25s 就把"资产已扣"的事件标 FAILED）；FAILED 无重放入口，容量腾挪 `delivered_retention=0` 立即删除 | `default_deliver` 把落库异常/空 msg_id 翻成 `delivery.retryable`；`pump` 对 retryable **不计数只停轮**；FAILED 改用独立下限 `OUTBOX_FAILED_MIN_RETENTION=7d`，容量腾挪时单独传参并 `log.error` + `failed_lost` 指标记录 event_id + failed_reason（见 `docs/design/outbox_saga_v1.md` §11.2） |
| A-10 | 注释写"失败即 break 保序"，隔离后却 `continue`，自相矛盾 | 把两阶段取舍写成显式契约（阈值内 break 保序；达阈值后主动放弃保序换可用性），并新增一条用例把两段行为放在一起断言 |
| A-11 | `abort` 先通知目标（无超时 cluster.call）再踢客户端：目标不可达时踢人不执行，网关屏障永久冻结；`g_inflight` 无条件清；kick 返回 `nil` 也算成功 | 顺序改为**先踢后通知**；通知走 `call_agent_raw` 绕过 `g_aborted` 守卫；踢/通知分别计数，失败条目保留以便重试；返回值新增 `notified / notify_failed / pending` |
| A-12 | `CMD.migration_commit(entity_id)` 无 barrier 参数，无法区分轮次 | 新增可选 `barrier_id` 参数并校验与暂存快照一致（不一致返回 `barrier mismatch`）；适配器 `handoff` 带上本轮 barrier |
| A-13 | 两个 CI 门禁假绿 | 见 §8.3（上一轮已修）；V-01 已重跑 |
| A-14 | `saga.test.lua` 标题「compensates only once」却断言 `refunds==2` | 明确契约：补偿是**至少一次**，状态机只保证"离开 COMPENSATING 一次"；`saga.lua` 加注释，用例改名并断言两次调用 |

### 8.3 上一轮已修的门禁（A-13）

- `scripts/ci/verify_replica_stepdown.sh`：新增三条硬门禁——必须是 ≥3 节点副本集、
  必须真的换 primary（不吞 stepDown 结果）、`hits >= 1`（排除"全程没写成功"的空跑）。
  之前 `0 == 0` 也会打印 passed。
- `scripts/ci/check_metrics_labels.lua`：先做遮罩（注释与字符串内容抹成空格、长度不变）
  再匹配，消除注释误红与 help 文本含括号导致的漏检；补 `metrics:counter(` 方法形式；
  扫到 0 个文件时直接失败，不再"没扫到" = "全合规"。

### 8.4 确认没问题的部分

对抗审查同时确认了以下修复是真实有效的（实跑验证，非读码推断）：

- `CMD.session_export` 契约闭合：真实适配器调用真实 CMD，参数个数 `n=3` 与签名一致；
- owner_epoch 严格前进：`restore` 停在源端代际 → `attach(target)` → 推进一代 →
  `resume_owner` 带新代际、网关 `frozen_epoch` 解除、`session.replay` 执行；
  重复 attach 被 "owner epoch must advance" 拒绝；
- `launcher_entities` 的 `pcall` 解包正确，异常与 `false` 两种形态都能带类型名报错；
- `INTERNAL_ERROR` 在 outbox / pay_webhook / charge_order / saga 下游均未被当成成功；
- `critical.query` 冷账本读取已 pcall；`causal_seq` 在同一 CAS 内分配不会重号。

### 8.5 测试有效性说明（重要）

本轮新增/修改的 6 项修复，全部用**变异测试**确认过新用例会变红：

| 变异 | 变红的用例数 |
| --- | --- |
| 白名单移除 `_critical_outbox_seq` | 3 |
| 排序器改回非传递比较 | 1 |
| 隔离时不再拷贝事件 | 1（另连带 1） |
| 配置只合顶层 | 1 |
| Grant 改回 `math.type` 门 | 多条 |
| 归档中途失败报 `#moved` | 1 |

未覆盖的路径（仍无测试，读码判断）：`mark_delivered` 的 UNKNOWN/BLOCKED 分支、
`causal_seq` 并发 CAS 重试、`node_shutdown` 的 `skynet.sleep` 宽限、
`migration_adapter` 的 abort 失败路径。

**第十批已把这四条全部补上**：

| 路径 | 新增用例 |
| --- | --- |
| `mark_delivered` UNKNOWN / BLOCKED / 重试耗尽 | `outbox.test.lua` 3 例（含 refresh 调用次数、重试次数上限） |
| `mark_delivered` 落清理标记 | `outbox.test.lua` 1 例（断言 `$set` 里带 `_critical_outbox_cleanup_at`） |
| `causal_seq` 版本冲突 | `critical.test.lua`「does not advance the sequence for a commit that never landed」 |
| `node_shutdown` 宽限 | `node_shutdown.test.lua` 断言 `slept == 110`（1s 预算 100 tick + 10 tick 宽限） |
| `migration_adapter.abort` 失败路径 | `migration_adapter.test.lua` 4 例（先踢后通知、kick 失败可重试、拒绝不计成功、handoff 带 barrier） |

补测试过程中还发现并修掉一个真实缺陷：`mark_delivered` 的 `$set` **漏写清理标记**——
`transition` 在内存副本里设了 `cleanup_at`，但没写进 CAS，于是"回执到达"这条路径
产出的角色文档没有标记，终态事件又回到"没人清"的状态（A-08 只修了一半）。
现已与状态同一次写入，并有专门用例守着。

**第十批变异测试**（每条都确认「改坏实现 → 对应用例变红」）：

| 变异 | 变红的用例 |
| --- | --- |
| `_advance` 的 `$set` 漏写 `cleanup_at` | `stamps the cleanup marker when an event becomes ENQUEUED` |
| `mark_delivered` 的 `$set` 漏写 `cleanup_at` | `persists the cleanup marker together with the delivered status` |
| worker 忽略 `cleanup_due` | `pumps a role whose only work is an expired cleanup marker` |
| FAILED 沿用 `delivered_retention` | `keeps a young FAILED event even when the outbox is at capacity` |
| `pump` 把 retryable 当毒事件 | `does not quarantine an event whose delivery hit an environment fault` |
| barrier 退回固定 `mig_<id>` | `gives every round its own barrier` |
| abort 里 kick 只看 pcall 是否抛异常 | `does not count a rejected kick as success` |
| `cleanup` 后不重算标记 | `recomputes or clears the cleanup marker after a cleanup` |

这一步不是形式主义：第一版变异里 `_advance` 那条**没有**变红，才发现
"ENQUEUED 路径的标记写入"完全没有断言，补了用例才把它守住。

---

## 10. 第二轮源码审计（DB Fence / Critical Commit）

> 来源：外部第二轮审计（对 `6bfc9c5` 的 Critical Commit / DB Fence 逐函数审查）。
> 处置口径与前面一致：只有「改完代码 + 新增用例 + 全量门禁通过」才算已修。
> 门禁：`./bin/skyext test` 124 files / 124 passed；`luacheck .` 310 files 0 警告；
> `stylua --check .`、`check_paths`、`make -C example lint`（44 files）全通过。

### 10.1 已修

| 编号 | 问题 | 修复 | 验证 |
| --- | --- | --- | --- |
| B-01 | `$rename` 的目标路径绕过身份字段保护：`{["$rename"]={gold="rid"}}` 里 `fields["rid"]` 是 nil，校验只看 key 就会放行，真实 mongod 会把 `rid` 改成 gold 的值 | `dbmgr.critical_update` 加**更新操作符白名单**（只允许 `$set` / `$unset`）。`$inc`/`$currentDate` 一并拒绝：它们会让库里的值偏离内存副本，而 CAS 之后内存仍是普通字段的权威副本。非表载荷也在这里拒绝（否则 `write["$set"]._version` 会索引到字符串上，冒成 Lua 错误而不是拒绝） | `dbmgr.test.lua`「refuses $rename before it can retarget the identity, fence or version」「refuses update operators outside the whitelist」 |
| B-02 | `extra_query` 的"只允许等值"只查 `type(v)=="table"`，`$where` 的值是字符串 → 放行，CAS 变成任意服务端表达式 | 拒绝 `$` 前缀的键与非字符串键；等值条件仍然可用（Outbox 的"该事件仍是 PENDING"依赖它） | `dbmgr.test.lua`「refuses extra_query operators so the CAS stays an equality match」 |
| B-03 | PREPARE 被拒一律回 `NORMAL` 并报 `UNKNOWN`：CAS/版本/fence 不符说明缓存已不是库的副本，继续回存只会每轮失败；而 `UNKNOWN` 又暗示"可能写了"，与 `critical.query` 的 `NOT_STARTED` 矛盾 | `critical_update` 返回第三个值 `code`（`dbmgr.REASON`）；`commit_core` 按 code 分级：`version_mismatch`/`cas_mismatch`/`lease_expired`/`state_invalid` → 隔离；`owner_changed` → 不碰（条目已归新 owner）；`invalid_update`/`majority_unavailable`/`server_rejected` → 回 `NORMAL`。状态统一改报 `INTERNAL_ERROR`（确定零写入）。**残留已修**：普通回存 `save_doc` 的 `safe_update` 回包不确定时做多数派读回，按版本/fence 对齐内存或保留 dirty，避免旧版本无限 CAS | `critical.test.lua` 3 例（隔离 / 保持可写 / 不动他人条目）；`dbmgr.test.lua`「aligns the cached version when a committed save loses its reply」及读回失败可恢复用例 |
| B-04 | `critical_probe` 只发 `hello`，注释却写"确认能走 majority 写"；secondary 也能应答 `hello` | 改成真实的 `w:majority, j:true` 写入 → 多数派读回 → 清理，写的是独立集合 `skyext_health_probe`（绝不往角色集合插测试记录）。任一条腿没确认都返回失败，清理失败也不报健康 | `service/mongo_conn.test.lua` 2 例（命令序列 + 三种失败腿） |
| B-05 | `execute_client` 只强制 `hmac_fn`，漏传 `equal_fn` 时 `grant.verify` 静默退回 `==` | 入口强制要求 `equal_fn` 是函数，缺失/类型错一律 `INTERNAL_AUTH_DENIED` | `critical.test.lua`「refuses a client call without a constant-time comparator」 |
| B-06 | 示例游戏没有 `charge_handlers`：`pay_callback → charge_grant → critical.execute_internal` 链路在框架侧完整，但游戏层缺资产效果，启用支付会直接报 "entity handler has no charge_handlers" | `example/lualib/entity_handler/role.lua` 实现充值到账 handler：validate 纯读、apply 只改内存（`modules.bag:add_item`），换算只写一份避免 validate/apply 分叉 | `example/lualib/entity_handler/role.test.lua` 3 例 |
| B-07 | B-03 的隔离把 PREPARE 被拒的角色卡成"加载不了"：`dbmgr.load` 对 `CRITICAL_QUARANTINED` 一律拒绝，而 `unload` 又因为状态非 NORMAL 失败，只能等实体卸载重试到 `give_up` 再 discard | `load` 区分"有没有未决意图"：缓存里**没有** `_critical_intent_v1` 说明库里从没写过 PREPARE，内存里的脏数据只属于那次失败的操作，丢掉重读是安全的；有意图时必须等恢复任务判定（可能已落库、只是 ACK 丢了） | `dbmgr.test.lua`「quarantines the cache when the majority write is unknown」（重载拿回库里文档）与「refuses to reload a quarantined cache that still carries an intent」 |
| B-08 | `critical_probe` 修成真探针后仍然没有任何调用点，运维只能照手册抄代码片段，等于没接 | `critical_maintenance.probe()` 收口"取集合 → 调探针 → 归一原因"，`service/critical_maintenance.lua` 注册 GM 命令 `critical_probe`（可按 `type_name` 指定实体类型），注册失败只告警不拖垮服务 | `critical_maintenance.test.lua` 4 例；GM 文档新增命令说明 |

顺带修正的文档不一致：

- `docs/design/p00_gate_evidence.md` §0 原写"`extract_critical_fields` / `advance_persisted_version`
  尚未接入生产路径"，与 §2 末尾"`dbmgr.load` 已在 decode 前调用 extract"自相矛盾；已统一为
  "两项均已接入（P07）"。
- `docs/design/p17_verification.md` §3 B1 第 2 步原写"用 `critical_probe()` 确认命令通道可用"，
  与 B-04 修复后的语义对齐为"确认多数派写可用"。

### 10.2 仍未闭合（不是代码缺陷，不得写成"已验证"）

| 项 | 现状 |
| --- | --- |
| V-02 双节点迁移回环 | 待跑（需要两个 skynet 节点 + 真实客户端） |
| V-03 Mongo 网络分区 | 待跑 |
| V-04 etcd 租约抖动 | 待跑 |
| V-05 真实 WebSocket 回环 | 待跑 |

### 10.3 这轮确认"不是缺陷"的两点

- `$rename` / `$where` 只有内部调用方能触达（`critical` 自己只产生 `$set`/`$unset`，
  `outbox` 用 `$set`），属于框架 API 硬化缺口，不是远程可利用路径；修复的价值在于
  "所有权不变量不依赖调用方自觉"。
- 普通回存（`save_doc`）本身带 `_version` + `_fence` 条件，所以 B-03 修复前的实际后果是
  "过期缓存继续被业务读取、普通回存持续 CAS 失败刷日志"，不是直接把错误数据写进库。

---

## 11. 未推送提交的对抗审查（四个子代理并行）

> 范围：`9c34398..HEAD`（10 个提交，66 文件）。方法：按域拆四个子代理（DB Fence/提交内核、
> Outbox/投递、迁移/网关、支付/CI），要求"能跑就跑、去证伪"；关键结论由主代理逐条回源码复核，
> 其中 outbox 缺省 `now`、`$rename` 类问题另用临时用例实跑确认。

### 11.1 本轮已修（C-01 ~ C-11）

| 编号 | 级别 | 问题 | 修复 |
| --- | --- | --- | --- |
| C-01 | P0 | `outbox.pump` 的 `now` 只有 `opts.now` 一个来源，而生产链路 `outbox_pump → pump_entity` 只传 `limit`。`transition` 里 `now + retention` 直接抛错 → 事件永远停在 PENDING、每轮重复投一条可靠消息、毒事件阈值永不触发 | `opts.now or os.time()`；新增"不传 now 也能推进到 ENQUEUED"的用例 |
| C-02 | P0 | `charge_order` 所有写入走驱动的 `findAndModify`，不注入 `writeConcern`（默认 w:1）。切主回滚会让"渠道已 ACK、订单行消失"变成永久丢单 | 新增 `write_order()`：集合支持 `critical_find_and_modify` 时走 majority+j，三态里只有 CONFIRMED 算成功，UNKNOWN 返回失败让渠道重推 |
| C-03 | P0 | 冷账本只写 `$setOnInsert`：同一 op 先以 ABORTED 归档、之后重放成 COMMITTED 再归档时状态写不进去，`query` 永远报"未执行" → 调用方重放 → 二次入账 | 身份字段（rid/op_id）留 `$setOnInsert`，状态类字段改 `$set` |
| C-04 | P1 | 恢复任务永远取消不了自己那条未决意图：`query` 回 `IN_PROGRESS`，resolver 判 UNKNOWN，任务永远 RETRY_WAIT，同角色其它关键操作一直被"another critical operation is in flight"挡住 | `query` 增加 `intent_op_id`；resolver 在"意图就是本 op"且实体已持新 fence 时主动 `abort_intent` |
| C-05 | P1 | `BUSINESS_REJECTED` 不维护 `_critical_ops_oldest_at`：这些角色永远不被归档扫描命中，攒到 `MAX_OPS` 后所有关键操作被容量拒绝且无法自愈 | 归档水位改为两种终态都写（库与内存副本同口径） |
| C-06 | P1 | `refresh_critical` 把 `extract` 的错误字符串当 critical 表缓存：下一次 PREPARE 写意图时对字符串索引抛错，缓存永久停在 PREPARING | 改为判 `extract` 的第一个返回值，失败回 `extract failed: ...` |
| C-07 | P1 | 迁移 FALLBACK 从不解网关屏障：export 成功、release 失败时 `_released` 仍是 nil，`unquiesce` 又被 "snapshot already exported" 拒绝，客户端上下行被静默丢弃 | 改为"只要网关可能还冻着就必须踢"：`_released` 或（`_quiesced` 且解冻失败） |
| C-08 | P1 | 卡在 `VERIFIED_RECEIVED` 的订单永远不被对账：`record` 不写 `updated_at`，扫描也不含该状态。落单后、transition 前崩溃 → 钱收了奖不发 | `record` 写 `updated_at`；对账增加 `VERIFIED_RECEIVED` 档（沿用宽限期） |
| C-09 | P2 | `abort` 把每一次成功的 kick 都记成失败：两个网关的 `CMD.kick` 成功时返回 nil | `gate_tcp` / `gate_ws` 的 `kick` 返回 `true`（幂等：连接已不在也算成功） |
| C-10 | P2 | `query` 冷账本分支原样回 `ABORTED`，与热分支（映射成 `NOT_STARTED`）不一致，对账会永久 PENDING | 冷分支套用同一份状态映射 |
| C-11 | P2 | `saga` 的 `COMPENSATING → COMPENSATED` 漏传 `owner`，与其它四个转移不一致 | 补 `owner = opts.owner` |

### 11.2 未修（记入待办，不在本轮做）

| 项 | 级别 | 为什么先不做 |
| --- | --- | --- |
| `validate_outbox_events` 不校验 payload 的字节/深度/键安全，`load` 侧却 fail-closed | P1 | 需要先定"事件 payload 的上限"这个产品口径（多大算合法），再决定拒绝还是截断；直接套 `critical_fields` 的 512 KiB 预算会让大附件事件无法投递 |
| `cleanup` 无受害者时残留清理标记 | P1 | 需要与 `critical.commit_core` 的容量腾挪放在同一次 CAS 里改，改动面比看起来大；当前只是每轮空扫，不影响资产 |
| `metadata_only` 的 CAS 未命中不标 `stale` | P2 | 与 C-03 同源（版本分叉后归档空转），但修它要动 `outbox._advance` 的重试语义，留给下一轮 |
| `_advance` 的"读后像重试"读的是内存缓存而非多数派读 | P2 | 同上；真实版本分叉时才触发，且业务侧靠 `service_op_id` 去重不会重复入账 |
| `session.attach` 不校验实体是否已被重新绑定 | P2 | 需要定"迟到 attach 该失败还是该覆盖"的契约，涉及迁移代际语义 |
| `gate_ws` 的 RESERVED 槽位没有握手超时 | P2 | 需要在 `websocket.accept` 外层加超时并补状态机用例，属独立改动 |
| `pay_webhook.ack` 写失败仍回 200（注释与行为相反） | P2 | 是否回 500 取决于渠道重推成本，属产品决策 |
| `check_metrics_labels` 遮罩漏长字符串、首参非字面量时跳过 | P2 | CI 门禁增强，需要独立用例；当前仓库没有这两种写法，是潜在缺口 |
| `check_metrics_labels` 只在三个目录全空时才失败 | P2 | 同上 |
| `verify_replica_stepdown.sh` 两条恒真断言（`_version == hits`、`documents == 1`） | P2 | 要重写并发注入方式才能证伪"迟到写"，属验证脚本重构 |
| `bench_critical_capacity.sh` 未加 majority 写关注、失败路径仍打印数值、40 样本取 p99 | P2 | 需要重跑一轮才能更新文档里的数值，本轮不引入未经实测的新数字 |
| `critical_ledger` 未配置时：维护服务归档到默认集合，发奖路径却静默跳过 | P2 | 三处要统一成同一个默认值或统一拒绝，属配置契约调整 |

### 11.3 推测项（有机制、无端到端证据，未计入缺陷）

- `resume_owner` 与 `install_conn` 之间的窗口里到达的上行可能被 `client not bound` 踢线（取决于调度顺序，单进程无法稳定复现）。
- `barrier_id` 的 seq 是进程内计数，两个源节点同秒对同一实体迁移会撞名（代价是一轮 FALLBACK）。
- 客户端可控的 `req_id` 超出 `u32` 会让 `string.pack` 抛错，导致该实体每次 export 都失败。
- `unresumable` 快照被 `session.attach` 忽略，迁移会"成功"接上一个存在永久缺口的会话。
- outbox 接收方 `handle` 不传 `ledger`：同一事件若在 7 天后被人工重投，热账本已归档、冷账本又不查，可能二次执行业务。

### 11.4 范围观察

本轮 25 条里约 5 条属支付业务（订单状态机、对账、渠道 ACK），20 条属引擎不变量。
补强从"架构"扩到"资金业务"的边界问题单独记录在
[`framework_boundary_v1.md`](framework_boundary_v1.md)：那里给了三层判据、逐模块归类、
以及"领域包必须可删除"的候选门禁。后续每条缺陷都建议标一层（引擎 / 领域包 / 游戏层）。

---

## 12. 第四轮对抗审查（全量架构，2026-11-13）

> **范围**：基点 `0175f97`（upstream/main）到 `4bd0c70`，43 个提交、153 文件、+35194 行、
> 27116 行非测试代码。前三轮已修 55 项，本轮只登记**新发现**。
> **方法**：按域拆六个子代理并行（提交内核/账本、Outbox/Saga、支付对账、迁移网关、
> 会话协议、SDK/示例/CI），要求"能跑就跑、去证伪"；P0 与关键 P1 由主代理逐条回源码复核，
> 标注 ✅ 的为已复核。
> **验收口径不变**：只有「改完代码 + 新增用例 + 全量门禁通过」才把状态改成「已修」。

### 12.1 总览

| 级别 | 数量 | 说明 |
| --- | --- | --- |
| P0 | 5 | 资产安全或角色永久卡死 |
| P1 | 10 | 漏发奖、可用性、契约不一致 |
| P2 | 20 | 状态错乱、可观测性、门禁缺口 |

**已修（本轮第一批，D-01 ~ D-07、D-09、D-14、D-15）**：

| 编号 | 修复要点 |
| --- | --- |
| D-01 | `dbmgr` 给隔离态开一条"只清意图"的写通道（`allow_quarantined_intent_abort` + 形状校验）；`unload` 对 DISCARDED / 无意图隔离直接丢弃；新增 `mark_discarded`；`abort_intent` 成功后标作废，恢复任务卸载实体后从库重读 |
| D-02 | `critical.query` / `abort_intent` 增加 `majority_read`：恢复任务按持久化事实判定，不再被"内存没有意图"骗成 `NOT_STARTED` |
| D-03 | `outbox.new_receiver` 接受 `ledger`，`handle` 透传给 `execute_internal`；缺失时 `retryable` fail-closed；示例 handler 从 `critical_ledger` 配置取集合 |
| D-04 | `charge_order.record` 对 `rid` 做 `tonumber` + `math.tointeger` 归一，非正整数拒绝；落库与冲突比较都用归一后的值 |
| D-05 | 示例汇率改为 `CNY = 1`（1 分 = 1 金币），注释写明 amount 是最小单位；测试改用 600 分断言，100 倍错误一定被抓 |
| D-06 | `pump` 的 CAS 重试用尽分支：先 `refresh_critical` 对齐，仍 PENDING 才记一次尝试，到阈值标 FAILED |
| D-07 | `validate_outbox_events` 增加批内 `event_id` 唯一性校验 |
| D-09 | `scan_archive` 支持 `skip`，`run_once` 用 `deps.archive_cursor` 轮转，卡住的文档不会占满候选页 |
| D-14 | `sproto_api` 的 RESPONSE 分支校验 `pending.fd == fd`，外来连接不能注入他人响应 |
| D-15 | `session.with_request` 入口拒绝非 u32 的 `req_id`，避免快照 `string.pack` 抛错导致角色永久不可迁移 |

**后续批次已修**：D-08（满容量先归档）、D-10（对账 keyset 游标）、D-11（容量超限可重试）、
D-12（迁移 FALLBACK 解屏障）、D-13（迁移取消后强制卸载源实体）、D-16（启动依赖检查）、
D-17（TS SDK bigint/binary 契约）、D-18（ABORTED 维护归档水位）、D-19（对账结案）、
D-20（action 冲突）、D-21（解除对账阻断）、D-22（生产 schedule_grant）、D-23（非法摘要进 DLQ）、
D-24/D-25/D-36（网关代际与不可续接会话）、D-37（Outbox 扫描页积压指标）。

**后续批次已修（D-26 ~ D-35）**：capability 命名空间私有化、channel 配置冲突拒绝、critical query
op_id 门禁、charge_count 边界回归、metrics label 完整解析并接入 lint CI、agent_count 启动校验、
critical 配置统一校验、框架命令扩展点移除 entity_agent 对支付包的硬依赖、fallback 进入必需依赖。
D-31 的切主脚本已改成前后双窗口门禁，并于 2026-11-13 在真实三节点副本集复跑通过。

**结构性结论**：框架把"正常路径"写得很严密，但"异常路径的出口"普遍缺失。
隔离、恢复任务、对账、迁移降级四处都是"进入条件清楚、退出条件没写"。
P0-1 与 P0-2 是同一个病的两个实例。

### 12.2 P0（资产安全 / 永久卡死）

| 编号 | 问题 | 位置 | 证据 |
| --- | --- | --- | --- |
| D-01 | **隔离态是单行道**：`save_doc` 对非 NORMAL 一律拒绝 → `unload` 永远失败 → `_abort_unload` 不清 `entity.unloading`（全文件无复位）→ `_ensure_loaded` 恒返回 `"entity unloading"` → 恢复任务的 `critical_update` 又被 `state_invalid` 拒绝。一次瞬时多数派超时 = 本局普通进度不落库 + 角色卡死，唯一出口是 etcd 租约过期后的 `_recover_dirty` | `dbmgr.lua:281-288`（save）、`:621`（quarantine）、`:966-991`（unload）；`entitymgr.lua:1002`（置位）、`:624-625`（拒绝）、`:849-852`（_abort_unload） | ✅ 代码路径逐行确认；`discard` 仅 `_recover_dirty.give_up` 一个调用点 |
| D-02 | **PREPARE UNKNOWN 留下清不掉的意图，恢复任务写死后永不复开**：UNKNOWN 分支不 `set_critical` → 内存无意图 → `query` 报 `NOT_STARTED` → reconciler 判 `NOT_COMMITTED` → 任务写 `COMPLETED_*`；`reconcile` 用 `$setOnInsert` 不重置，`claim_job` 不接受 COMPLETED → 库里 PREPARED 意图永久残留，角色重载后所有关键操作回 `IN_PROGRESS` | `critical.lua:741-748`、`:1133-1191`、`:1247-1284`、`:1296-1340`；`critical_reconciler.lua:94-126` | ✅ 三处代码路径确认（UNKNOWN 不写 set_critical、$setOnInsert、claim 白名单） |
| D-03 | **Outbox 接收方不去重冷账本**：`new_receiver` 没有 ledger 参数，`handle` 调 `execute_internal` 不传 `opts.ledger` → 热账本 7 天归档后重投，`query` 查不到 → 二次执行同一业务效果。`charge_order.lua:302` 有同样处理，outbox 这条链漏了 | `outbox.lua:985-1002`、`:1071-1077` | ✅ 对比 `critical.lua:482`（`req.ledger` 分支）与 `charge_order.lua:302` |
| D-04 | **支付订单 `rid` 不校验类型**：`record` 只判 `rid == nil`；JSON 渠道把 rid 按字符串回传极常见，落单后 `placement.calc_node` 对非整数直接 `error` → 回调 500 → 渠道永远重推 → 对账 `query_op` 同样抛错 → 永远 UNKNOWN，既不 NOT_STARTED 也不 block | `charge_order.lua:136-138`；`placement.lua:94-96` | ✅ 两处代码确认；`amount` 有 `math.type` 校验，`rid` 没有 |
| D-05 | **示例充值汇率把"分"当"元"**：`CHARGE_RATE.CNY = 100` 注释"1 元 = 100 金币"，但 `pay_webhook` 要求 `amount` 是整数最小单位（分）。6 元订单 `amount=600` → 60000 金币，应为 600。测试把 `amount=100 → 10000` 固化了，掩盖了单位错误 | `example/lualib/entity_handler/role.lua:101`；`pay_webhook.lua:130-132`；`role.test.lua:125` | ✅ 三处对齐确认；照抄示例接真实渠道每笔多发 100 倍 |

### 12.3 P1（漏发奖 / 可用性 / 契约）

| 编号 | 问题 | 位置 |
| --- | --- | --- |
| D-06 | **Outbox CAS 失败不计投递次数**：`_advance` 返回 BLOCKED/REJECTED 时只 `break`，`_note_deliver_attempt` 只在投递器明确失败时调用 → 毒事件阈值对"CAS 卡住"无效，事件永远 PENDING、每 5 秒重投一条（约 1.7 万条/天），且 `_advance` 重试读的是同一份内存缓存，必然耗尽 | `outbox.lua:636`、`:738-762` |
| D-07 | **同一批 `event_id` 重复静默丢分片**：`validate_outbox_events` 不查批内唯一性 → `$set` 同路径写两次只留最后一份，但 `pending_count += #new_events` 按 2 计 → 第二个分片的业务效果永久丢失，且计数比真实事件多，`scan` 每轮命中该角色永不收敛 | `critical.lua:212-244`、`:821-832` |
| D-08 | **热账本 512 无降级路径**：`op_count >= MAX_OPS` 直接 `CAPACITY_EXCEEDED`，归档只搬超过 7 天的；`BUSINESS_REJECTED` 与 COMMITTED 同占额度 → 客户端持续发起被业务拒绝的操作即可把自己锁死；`charge_grant` 走同一内核，付费订单会一直拿到 CAPACITY_EXCEEDED | `critical.lua:55`、`:576-583`、`:839-877`；**已修 + 已验证**：触顶时先用 `req.ledger` 同步归档最多 64 条已结算热记录，再重新计数；归档失败才继续拒绝。`critical.test.lua`「archives settled operations before rejecting a full ledger」 |
| D-09 | **归档扫描无轮转**：`scan_archive` 只有 limit 无 skip/游标，卡住的文档不会离开候选集；≥32 个卡住文档后后续角色永远排不进这一页 | `critical_maintenance.lua:51-74` |
| D-10 | **对账扫描被毒单饿死**：注释称"不排序避免卡住的单占住队头"，但无显式 sort 时 Mongo 走 `{status, updated_at}` 索引就是 updated_at 升序；PENDING 分支不写任何字段，毒单永远留在最老位置 | `charge_reconcile.lua:45-66`；**已修 + 已验证**：`scan_orders` 显式按 `(updated_at, provider, order_id)` 排序并用 keyset 游标续扫，`run_once` 用 `deps.scan_cursors` 持久化游标；`charge_reconcile.test.lua` 稳定排序/游标推进用例 |
| D-11 | **`CAPACITY_EXCEEDED` 被 ACK**：webhook 回 200 + ACK，渠道不再重推，订单留 GRANTING；对账重投仍是 CAPACITY_EXCEEDED，永远 RETRY、不 block、不告警；唯一出路 `critical_maintenance` 在示例配置默认关闭 | `pay_webhook.lua:232-246`；**已修 + 已验证**：返回 `503 capacity_exceeded` + `retryable=true`，不 ACK，订单留 GRANTING 并记录错误；`pay_webhook.test.lua` 容量超限用例 |
| D-12 | **迁移 FALLBACK 只解实体冻结、不解网关屏障**：`unquiesce` 成功即 `unfrozen=true` → 不踢人，但 `unquiesce` 只清 `entity.migrating`，从不调 `resume_owner` → 网关 `frozen_epoch` 仍在，双向静默黑洞直到客户端心跳判死 | `migration_adapter.lua:236-280`；`entitymgr.lua:1180-1207`；**已修 + 已验证**：fallback 检测 `_barrier` 并必踢，kick 失败保留 inflight 供 abort 重试；`migration_adapter.test.lua` 4 个新增用例 |
| D-13 | **迁移取消后 `entity.migrating` 不复位**：fallback 踢客户端后实体仍带 `migrating=true`，客户端重连 `bind` 成功但每条上行在 `CMD.client_msg` 被丢 → "在线但操作无响应" | `migration.lua:158-160`；`session.lua:283-311`；`entity_agent.lua:644`；**已修 + 已验证**：已导出/释放且无法 unquiesce 的源实体在踢客户端后强制走 `unload_entity`，重连必须从库重载；`migration_adapter.test.lua` 覆盖强制卸载与可恢复场景不卸载 |
| D-14 | **`sproto_api` 响应不校验来源连接**：`g_sessions` 只按客户端可选的 session 编号做键，RESPONSE 分支丢弃 `fd` 直接唤醒 → 任意连接发 `session=N` 即可注入/伪造他人 pending 响应 | `sproto_api.lua:315-321`、`:346-360` |
| D-15 | **`req_id >= 2^32` 让快照编码抛错**：`with_request` 只判下界不判上界，`session_snapshot.encode` 用 `string.pack("<I4", req_id)` 无符号溢出抛错（不是返回 nil,err）→ 迁移每次失败，角色被钉在本节点 | `session.lua:174-192`；`session_snapshot.lua:119` |
| D-16 | **`launcher.self_check` 只打日志不阻断**：`pay_callback` 无 `depends_on`，单开它不检查 `critical_maintenance` → 热账本永不归档 → 约 512 笔充值后新发奖全被拒，渠道已 ACK、玩家不到账 | `launcher.lua:18-27`、`:57-70`、`:135`；**已修 + 已验证**：启动自检阻断 `pay_callback`/`outbox_worker` 缺少 `critical_maintenance` 的配置，维护服务缺失 `critical_ledger/jobs` 也 fail-fast；`launcher.test.lua` 18 例覆盖依赖与阻断 |
| D-17 | **TS SDK 与服务端契约不一致**：`OperationGrantV1.rid` 为 `number | string` 不含 `bigint`（17 位 rid 必超 2^53），`mac: string` 而文档写"二进制" → 长 rid 的 Grant 三条路都不通 | `sdk/ts/src/critical.ts:12,18`；`critical_grant_v1.md:38`；**已修 + 已验证**：`rid` 接受安全整数、`bigint` 或规范十进制字符串，`mac` 接受非空字符串或 `Uint8Array`；`critical.test.ts` 覆盖 17 位 rid 与二进制 mac，`tsc --noEmit` 通过 |

### 12.4 P2（状态错乱 / 可观测性 / 门禁）

| 编号 | 问题 |
| --- | --- |
| D-18 | `abort_intent` 写已结算 op 却不维护 `_critical_ops_oldest_at` → 纯 abort 的账本只增不减，撞 512 后无法自愈。【已修 + 已验证：ABORTED CAS 同步推进库与内存归档水位；`critical.test.lua` 断言 oldest_at】 |
| D-19 | `VERIFIED_RECEIVED + COMMITTED` 永远无法结案：`mark_reconciled` 的 CAS 只认 GRANTED。【已修 + 已验证：`charge_reconcile` 先 CAS 到 GRANTED 再结案；`charge_reconcile.test.lua` 覆盖 COMMITTED 结案与 CAS 落空】 |
| D-20 | 重复回调冲突校验漏 `action`：退款/拒付回调被当"重复发奖"静默 ACK，漏补偿。【已修 + 已验证：保留 `(provider, order_id)` 唯一索引，在冲突路径显式返回 `order conflict` 并记录 action 差异，不再静默返回旧单；`charge_order.test.lua` 覆盖不同 action 拒绝与同 action 幂等】 |
| D-21 | `block_reconcile` 无解封路径，发奖成功后也不清标记 → 已发货订单永久停在 GRANTED。【已修 + 已验证：新增 `unblock_reconcile`；成功 transition/mark_reconciled 原子 `$unset` 阻断标记；`charge_order.test.lua`、`pay_webhook.test.lua` 覆盖】 |
| D-22 | `ack_before_grant` 生产接线没有 `schedule_grant`（只在测试注入）→ 先 ACK 后只能等对账，发货延迟约 90s。【已修 + 已验证：HTTP 路由用 `skynet.fork` 异步发奖，失败仍交对账；`pay_callback_router.test.lua` 覆盖生产接线】 |
| D-23 | 接收侧"永久无效"直接 ACK：资产已扣、无 FAILED 记录、不可重放；`outbox.event` 只校验 `param_hash` 长度不校验 hex。【已修 + 已验证：永久无效信封抛错进入可靠消息死信；64 字符摘要额外校验小写 hex；`outbox.test.lua`/`critical.test.lua` 覆盖】 |
| D-24 | `replay` 下行不带 `owner_epoch`，`push_allowed` 对 nil 一律放行 → 屏障与代际过滤在重放路径失效。【已修 + 已验证：`session.replay` 的 push 携带当前 `owner_epoch`；`session.test.lua` 断言 attach 后重放代际】 |
| D-25 | `unresumable` 会话仍被迁移并报 READY → 迁移"成功"但客户端存在永久缺口。【已修 + 已验证：实体枚举暴露 `unresumable`，适配器过滤，编排状态机兜底降级；`entitymgr.test.lua`、`migration.test.lua`、`migration_adapter.test.lua` 覆盖】 |
| D-26 | `capability.ALLOWED_NAMESPACES` 是导出的可变普通表 → 任何模块一行赋值即可自签 cap。【已修 + 已验证：命名空间表私有化，只暴露 `is_allowed_namespace`；`capability.test.lua` 验证外部写同名模块字段无法扩展签发边界】 |
| D-27 | `channel.get_or_create` 静默忽略同名频道的第二份配置 → 鉴权策略被首个创建者锁定；`authorize` 未做类型校验。【已修 + 已验证：按有效配置和 `authorize` 身份比较，冲突返回 `channel configuration conflict`；`channel.test.lua` 覆盖复用、冲突及非法回调】 |
| D-28 | `critical.query` 不校验 op_id 格式 → 大写 hex/少一位被当"从未执行"。【已修 + 已验证：只接受规范 `srv_<64 lowercase hex>` 或 Grant `<32 hex>_<4 hex>`，非法值在任何状态读取前返回 `UNKNOWN/invalid_op_id`；`critical.test.lua` 断言冷账本未读】 |
| D-29 | 示例 `charge_count` 乘法溢出后负值仍通过 validate。【已修 + 已验证：现有 `math.type + count > 0` 防线保留，新增最大整数与绕回负数回归用例；`role.test.lua` 覆盖】 |
| D-30 | `check_metrics_labels` 只扫 ≤400 字符的字面量标签表，变量/长表直接跳过 → 门禁假绿。【已修 + 已验证：完整匹配指标调用并平衡解析标签表，支持 histogram buckets 和方法/空白/别名调用，动态标签 fail-closed，加入自测并接入 `lint.yml`；本地 `--self-test` 11 例、实仓 186 files 通过】 |
| D-31 | `verify_replica_stepdown.sh` 用 `sleep 0.5` 后 stepDown，不证明切主瞬间仍有并发写。【已修 + 已验证：writer 持续到新 primary 确认后停止，同一 CAS 原子累计 `pre_hits/post_hits`，term 从 `rs.status()` 归一化读取；命中门禁要求切主前后各至少 2 个不同 worker 成功写，并允许切主期间个别客户端掉线。2026-11-13 本机 MongoDB 7.0.35 三节点副本集通过：term 2→3、`documents=1`、`version=hits=158`、`pre=93`、`post=65`】 |
| D-32 | `entity_types.agent_count = 0` 无下界校验 → 节点"就绪"但无 agent，`% 0` 抛错。【已修 + 已验证：类型配置首次加载统一校验，缺省仍为 1，0/负数/非整数直接拒绝；`types.test.lua` 覆盖】 |
| D-33 | `critical_ledger` 未配置时 maintenance 静默回退默认集合、entity_agent 返回 UNKNOWN，三处口径不一致。【已修 + 已验证：新增 `critical_config` 共享形状与集合冲突校验，maintenance、launcher、entity_agent 同口径；服务级 `critical_maintenance.test.lua` 覆盖启动门禁，`launcher.test.lua`、`entity_agent.test.lua` 覆盖调用侧】 |
| D-34 | 引擎硬依赖领域包 `skyext.charge_order`（`entity_agent.lua:230-237`）→ `framework_boundary_v1` 的"可删除"只在测试路径成立。【已修 + 已验证：`entity_agent` 增加 `handler.framework_commands` 扩展点，支付发奖实现移回游戏层 role；`charge_grant` 是保留命令，业务 handler 不能冒充。`entity_agent.test.lua` 覆盖扩展、冲突和禁止加载支付包，`role.test.lua` 覆盖真实 role 注册】 |
| D-35 | `fallback` 清空 `g_inflight` 抵消 abort 的"失败可重试"；且 `fallback` 不在 `REQUIRED_DEPS`。【已修 + 已验证：保留失败 inflight 的既有修复，并将 fallback 提升为必需依赖；`migration_coordinator.test.lua` 缺 fallback 时拒绝启动】 |
| D-36 | 迁移 `resume` 中网关 RPC 抛错时 `owner_epoch` 已推进且不回滚 → 下行被网关当迟到包丢弃。【已修 + 已验证：bind 用 pcall + 抛错/拒绝双回滚；`session.test.lua` 覆盖】 |
| D-37 | `skyext_outbox_pending` gauge 是"最后一个被 pump 的角色"，不能当积压告警。【已修 + 已验证：移除错误的 last-role gauge，改为 `skyext_outbox_pending_scanned` 扫描页索引汇总；`outbox_worker.test.lua` 断言 `scan_pending`】 |

### 12.5 架构级观察

1. **异常路径只有入口、没有出口**。隔离（D-01）、恢复任务（D-02）、对账（D-10）、
   迁移降级（D-12/D-13）四处同构。建议后续把"每个异常态必须有确定的退出通道"
   作为设计检查项，而不是逐条补。
2. **测试验证的是函数，不是调用链**。Outbox 124 个用例全绿，但生产链路
   `outbox_pump → pump_entity` 不传 `now`（上轮 C-01）、不传 `ledger`（本轮 D-03）。
   建议加契约测试：直接加载真实 `entity_agent` 的 `FRAMEWORK` 表，断言入口参数形状。
3. **"可删除的领域包"已从文档承诺推进为可执行边界**（D-34）：`entity_agent` 不再硬依赖
   `skyext.charge_order`，支付发奖通过游戏层框架命令扩展点接线；支付包自身仍留在
   `lualib/skyext/`，后续是否移目录仍按 `framework_boundary_v1.md` 单独评估。

### 12.6 与 §11.3 推测的关系

§11.3 第 5 条推测（"outbox 接收方 handle 不传 ledger，7 天后可能二次执行业务"）
本轮被证实为 **D-03（P0）**。§11.3 第 3 条推测（"`req_id` 超出 u32 会让 export 失败"）
被证实为 **D-15（P1）**。§11.3 第 4 条（`unresumable` 被 attach 忽略）为 **D-25（P2）**。
推测项应当在下一轮审查前先做一次可达性验证，而不是等到下一轮才升级。

### 12.7 回归：配置执行环境 P0（2026-11-13）

`66e6afa` 的 A-06 递归合并让配置文件开始调用全局 `type`/`pairs`，但
`config.lua` 执行配置时使用隔离环境，只注入 `include`。结果是 `config.init()` 在加载真实
`example/etc/nodes/*.app.lua` 时直接报 `attempt to call a nil value (global 'type')`，节点无法启动。

- **根因**：配置执行环境与测试环境不一致；旧测试用 `_G` 兜底，形成假绿。
- **修复**：`config.lua` 向隔离环境注入受限基础函数白名单（`type`/`pairs`/`ipairs`/`next`/
  `tostring`/`tonumber`/`assert`/`error`/`select`/`pcall`/`string`/`table`/`math`/`os` 等安全子集）。
- **验证**：`lualib/skyext/config.test.lua` 新增真正走 `config.init()` 的集成用例，覆盖真实配置
  `include` 链与 `with_defaults`/`merge_table`；`example/etc/nodes/common.app.test.lua` 36 passing。
- **状态**：**已修 + 已验证**。这是本轮新发现并修复的 P0 回归，不改变原有 5 条 P0 已收敛的结论。

---

## 13. 对 `5bc8073` 的再审查（复核上一批修复）

> 三个子代理按域复核刚提交的 10 项修复，要求"找修复引入的新问题"并做变异测试。
> 共报 12 条新问题、8 条未闭合。最严重的一条是 **P0-1 的出口根本派发不到**——
> 代码写了，但运行时走不通，属于"修复没闭合"。

### 13.1 已修

| 编号 | 级别 | 问题 | 修复 |
| --- | --- | --- | --- |
| RV-01 | **P0** | `critical_maintenance` 用 `call_owner(..., "unload_entity", rid)` → 走 `router.call` → `entity_call` → `handler_of`，而 `unload_entity` 只是 `CMD` 裸命令，既不在 `FRAMEWORK` 也不在业务 handlers 里，直接 `error("unknown entity command")`，被 pcall 吞成一条 warn。`DISCARDED` 之后实体不卸载、隔离态普通回存全停，在线角色整段会话零落库 | 新增 `router.unload_entity()` 裸命令通道（仿 `bind_session` 的本地/跨节点分发）；maintenance 改用它。**不能注册进 FRAMEWORK**：`entity_call` 已在实体队列内，再调 unload 会重入 gate 死锁 |
| RV-02 | P1 | `critical_resolve_intent` 的 COMMITTED 分支不带 `discard`。COMMIT 落库但 ACK 丢失时实体仍隔离，任务写 COMPLETED_COMMITTED 后永远停在隔离态（`refresh_critical` 不清 state，全仓无 `隔离→NORMAL` 迁移） | COMMITTED/BUSINESS_REJECTED 时用 `dbmgr.state_of` 判断，隔离态也返回 `discard=true`；正常态不打扰 |
| RV-03 | P1 | `abort_intent` 忽略 `mark_discarded` 返回值。失败时库里意图已清、内存意图还在，`scan_intents` 不再按库建任务，该实体永久卡住 | 只有原本隔离态才要求标记成功，失败返回 `UNKNOWN` 让任务重试 |
| RV-04 | P1 | D-06 位于"`deliver` 已返回 true"的分支内，CAS 连续失败 5 轮会把**已经投出去**的消息标成 FAILED（`failed_reason="status CAS kept missing"`），与 FAILED"消息从未投出"的语义冲突；源端不再重投，消息一旦丢失就是永久丢业务 | 改用独立 `cas_attempts` 计数（`_note_deliver_attempt` 增加 field 参数），**不标 FAILED**，只限流日志 + 告警 |
| RV-05 | P2 | D-07 用 `ipairs` 校验、调用方用 `#events` 计数；`#[1]=a,[3]=b` 结果不确定，能造出"写 2 条、计数 +3"的永久偏高 | `validate_outbox_events` 先断言键是 `1..n` 的连续正整数（稠密数组），再按 `1..count` 校验 |
| RV-06 | P2 | D-15 上界取 `0xFFFFFFFF`，淘汰时 `min_cached_req_id = req_id + 1` 变成 `0x100000000`，快照 `string.pack("<I4", ...)` 仍抛 overflow；且 `req_id < min_cached_req_id` 对所有 u32 成立，会话被打成不可用 | 上界改 `0xFFFFFFFE`，给淘汰水位留一个值 |
| RV-07 | P1 | D-04 只归一入口，历史字符串 `rid` 订单重复回调时 `existing.rid ~= rid` → `order conflict`（409），钱收了奖不发且对账也救不回 | 抽出 `normalize_rid`，读侧比较也归一 |
| RV-08 | P1 | outbox 缺 ledger 只在运行期 `retryable`，事件永远 pending、无 DLQ、无根因；`new_receiver` 构造成功但业务永久不执行 | `new_receiver` 构造期直接拒绝缺 ledger；示例 handler 的 ledger 查找失败只留 warn，真正的失败点是构造期 `assert` |

**边界加固**（同一批）：
- `normalize_rid` 字符串只收 `^%d+$`（`tonumber` 会收 `"0x10"`→16、`"7e2"`→700、`" 7 "`）；float 超过 2^53 拒绝
- `is_intent_abort_shape` 禁止 `_critical_ops_v1.<op>.<子字段>` 多段路径
- `sproto_api.call` 拒绝 `fd == nil`（否则 `pending.fd` 为 nil，来源连接校验被跳过）
- outbox 的 CAS 重试在 `refresh_critical` 失败时补一条 warn（原先三条失败子路径零日志）

**测试**：新增/改写 14 条，其中 3 条专门补子代理变异测试指出的覆盖缺口（"refresh 失败不计数""已被别人推进不计数""计数要累加"），2 条验证 `router.unload_entity` 走的是裸命令而非 `entity_call`。

### 13.2 明确取舍（不是缺陷，记录理由）

- **COMMITTED 分支的 discard 会踢在线玩家**：`unload_entity` → `_release_lock` 无 `detach`，会 `_kick_client`。但隔离态下 `save_allowed` 恒 false，不卸载的后果是整段会话零落库、进程一崩全丢。两害相权，掉线重连（数据不丢）优于静默丢数据。
- **D-06 的 refresh 永久失败仍不计数**：这是环境故障，按 A-09 的既定口径不该计入毒事件阈值。已补日志，但没有把它变成 FAILED。
- **已丢精度的 float 无法从值上识别**：`9007199254740993.0` 在 Lua 里解析成 `…992.0`，量级检查拦不住。只在量级（>2^53）上拒绝，并在注释说明局限。

### 13.3 复核确认没问题的部分

- `is_intent_abort_shape` 通过后，identity/`_fence`/`_version` 与路径冲突检查**仍然执行**（隔离分支不是 else），`$set` 的 value 是子文档不会被当操作符；业务字段写入被拦。
- `refresh_critical` 只调 `critical_read`，无 `query` 回环；失败时 `query` 回 UNKNOWN → reconciler 写 RETRY_WAIT，不会被误判成"没执行过"。
- `deps.archive_cursor` 不满页即归零，不会无限增长；重启从 0 开始只重复扫一轮，幂等。
- D-06 没有把环境故障误计入阈值：`_advance` 只对 `cas mismatch`/`version mismatch` 走 REJECTED，`server_rejected`/`majority_unavailable`/`lease_expired`/`state_invalid` 全部走 BLOCKED。
- 生产路径 `call`/`dispatch` 的连接标识都是 `conn_id`，类型一致；文档注明 `M.call` 当前无业务调用者。

---

## 14. 推送记录（2026-11-13）

**主体 14 个提交推送到 `origin/main` = `3ed7287f3d68e4d76a73e8246c318befe6eea12e`；
随后补推了本节的文档提交，最终 HEAD = `4e7cce7`（再往后还有一个本节的修订提交）。
本地与远端一致。**
推送前门禁：`124 files / 124 passed`。

### 14.1 遇到的阻塞

`memoryoff` 账号的 OAuth token（`gho_…`，scopes `gist, read:org, repo`）缺 `workflow`。
GitHub 对 `.github/workflows/*.yml` 的写入在**三条路径上都拒绝**：

| 路径 | 表现 |
| --- | --- |
| `git push` | `refusing to allow an OAuth App to create or update workflow … without workflow scope` |
| Contents API `PUT /contents/.github/workflows/lint.yml` | `404 Not Found`（权限不足的伪装） |
| Git Data API `POST /git/trees`（entry 路径为 workflow 文件） | `404 Not Found`；同一请求换成 `docs/_api_probe.txt` 立即成功 |

`hanxlman` 的 PAT 有 `workflow` scope，但对该仓库 `push: false`，不能代推。
`gh auth refresh -s workflow` 三次都因代理对 `github.com/login/device/code` 返回 502 失败。
SSH 通道 `git@github.com:22` 可达，但两个本地 key 均未注册。

### 14.2 处理方式

用 `git filter-branch --index-filter` 把 `6bfc9c5..HEAD` 范围内 14 个提交里的
`.github/workflows/lint.yml` 固定为远端版本（blob `533334a`），使 push 中不含任何
workflow 路径变更。**14 个提交全部保留**，除该文件外与改写前零差异（`git diff --stat`
为空），提交信息与作者信息不变。

- 改写前 HEAD：`5c2e48c`，保存在本地分支 **`backup/pre-push-14`**（未删除）
- 改写后 HEAD / 远端 main：`3ed7287`
- §12、§13 里出现的 `5bc8073`、`5c2e48c` 是改写前的本地 SHA，仅作审查记录，
  不再对应远端对象

### 14.3 待补的一处

被剥离的 10 行 CI 改动是两项**纯检查步骤**，不影响任何运行时代码：

- `Metrics label check` → `lua scripts/ci/check_metrics_labels.lua .`
- `Shell script syntax check` → `bash -n` 两个 CI 脚本

补丁保存于 `/tmp/skyext-lint-yml-pending.patch`（也完整保存在 `backup/pre-push-14`）。
等 `memoryoff` 的 `workflow` scope 刷新后，一条命令即可补回：

```bash
git apply /tmp/skyext-lint-yml-pending.patch
git add .github/workflows/lint.yml
git commit -m "ci(lint): restore metrics label and shell syntax checks"
git push origin main
```
