# P17 验证矩阵：故障注入与压测

> **状态：清单与验收口径已固化；需要在集成环境执行的部分明确标注为"待跑"。**
> 本文不是"已完成"的声明——每一行都写清楚它由哪个用例覆盖，或者为什么还没跑。

## 1. 故障注入（已由单测覆盖）

注入方式是**依赖替身**而不是运行期开关：`dbmgr` / `mongo collection` / `skynet.call`
在用例里被替换成带故障位的假实现（`critical_update` 返回 `UNKNOWN`、`find_many` 抛错、
`create_index` 回 `{ok=0}` 等）。好处是故障点精确、可重复，也不会在生产代码里留下
一个能被误触发的开关。

| 编号 | 注入 | 期望 | 用例 |
|---|---|---|---|
| I01 | 连接身份缺失/伪造 | 网关拒绝，不解码、不建会话 | `gate_ws.test.lua`、`connection_id.test.lua` |
| I02 | 同 conn_id 重复 open | 新连接顶掉旧连接，旧 close 回调不误关新连接 | `gate_ws.test.lua` |
| I03 | PREPARE 后崩溃 | 加载时按 `_critical_intent_v1` 恢复，不重放已提交操作 | `dbmgr.test.lua`、`critical.test.lua` |
| I04 | COMMIT 前多数派 ACK 丢 | 返回 UNKNOWN，缓存隔离，不宣称成功 | `dbmgr.test.lua` |
| I05 | 资产 CAS 已执行但 ACK 丢 | 重放 `service_op_id` 拿到历史结果，不二次入账 | `critical.test.lua` |
| I06 | 旧请求在新 fence 认领后到达 | `lease expired` 拒绝，不写库 | `dbmgr.test.lua` |
| I07 | 同 op 换参数 | `OP_CONFLICT`，不执行 | `critical.test.lua` |
| I08 | 归档后重放 | 冷账本命中，不重复执行 | `critical.test.lua` |
| I09 | 解码前保留字段 | `_critical_*` 在 `orm.decode` 之前提取，未知字段拒绝加载 | `critical_fields.test.lua` |
| I10 | 支付回调重复 | 唯一索引 + `service_op_id` 去重，只发一次奖 | `pay_webhook.test.lua` |
| I11 | 支付回调串单 | `409`，不改已有订单 | `pay_webhook.test.lua` |
| I12 | 发奖结果 UNKNOWN | ACK 且留在 GRANTING，对账收尾 | `pay_webhook.test.lua`、`charge_reconcile.test.lua` |
| I13 | 对账读不到证明 | 保持 GRANTING，不标未发奖 | `charge_reconcile.test.lua` |
| I14 | Outbox 投递未确认 | 保持 PENDING，本批停止 | `outbox.test.lua` |
| I15 | Outbox 状态 CAS 未命中 | 读后像重试；已被推进则不再减计数 | `outbox.test.lua` |
| I16 | Outbox 状态 CAS UNKNOWN | 停批 + 多数派读对齐版本，**不隔离玩家资产** | `outbox.test.lua`、`dbmgr.test.lua` |
| I17 | Outbox 事件错投/摘要不符 | 永久无效，ACK 不进 DLQ | `outbox.test.lua` |
| I18 | 接收方 UNKNOWN / IN_PROGRESS | `delivery.retryable`，保留 pending | `outbox.test.lua`、`entitymgr.test.lua` |
| I19 | 接收方契约类失败 | 抛错计入 attempts，最终进 DLQ | `outbox.test.lua` |
| I20 | Saga 补偿失败 | 保持 COMPENSATING，不宣称结案 | `saga.test.lua` |
| I21 | Saga 失租 | `not owner` / `lease expired`，不执行步骤 | `saga.test.lua` |
| I22 | 迁移任一步失败 | FALLBACK，不宣称无感成功 | `migration.test.lua` |
| I23 | 迁移回放失败 | FALLBACK，不退回旧 owner | `migration.test.lua` |
| I24 | 快照损坏/超限/epoch 不符 | 拒绝导入，目标会话不变 | `session_snapshot.test.lua`、`entity_agent.test.lua` |
| I25 | 索引建不起来 | 调度器/回调服务拒绝启动 | `outbox_worker.test.lua`、`charge_reconcile.test.lua`、`saga.test.lua` |
| I26 | 停服时实体卸不掉 | 进程不退出，可重试 | `node_shutdown.test.lua` |
| I28 | 冷账本写入未确认 | 热条目原样保留，不出现"两边都没有" | `critical.test.lua` |
| I29 | 热条目已归档后查询 | 回落冷账本；读失败报 UNKNOWN 而非"没执行" | `critical.test.lua` |
| I30 | PREPARED 但没有恢复任务 | 维护扫描补建任务 | `critical_maintenance.test.lua` |
| I27 | 迁移钩子卡住 | 截止时间到后继续卸载，不永久阻塞 | `node_shutdown.test.lua` |

**未覆盖的注入**（需要真实依赖，见 §3）：真实副本集 `stepDown`、Mongo 网络分区、
etcd 租约抖动、网关进程 kill、跨节点 RPC 超时。

**还没埋点的指标**：`skyext_critical_reconcile_jobs{state}`（恢复任务需要一个扫描口径，
现在只有任务表本身可查）与 `skyext_ws_handshake_inflight`（WS 六状态机里没有单独的
握手计数）。这两项在压测前需要补，否则"MANUAL_REVIEW 堆积"和"握手洪峰"只能靠日志看。

## 2. 压测清单

没有对照数据不改 HRW、ORM 或网关热路径。以下指标全部已在代码里埋点，压测只负责采集。

| 指标 | 含义 | 关注点 |
|---|---|---|
| `skyext_mongo_call_seconds{op}` | 单次 Mongo 调用耗时（含连接排队） | 连接数是否够 |
| `skyext_critical_decisions_total{status}` | 关键操作三态分布 | UNKNOWN 比例 |
| `skyext_critical_quarantined_total{reason}` | 隔离次数 | 应为 0 |
| `skyext_critical_same_owner_resume_total` | 同 owner 续做率 | PREPARED 卡住的比例 |
| `skyext_outbox_pending`、`skyext_outbox_pending_age_seconds` | 待发积压与最老事件年龄 | 年龄持续增长=投递跟不上 |
| `skyext_outbox_cas_retry_total` | 状态 CAS 冲突 | 突然升高=有绕过实体队列的写入 |
| `skyext_charge_reconcile_total{outcome}` | 对账结果分布 | `UNKNOWN` 长期不降 |
| `skyext_saga_state_total{state}` | Saga 状态迁移 | `COMPENSATING` 堆积 |
| `skyext_migration_phase_seconds{phase}`、`skyext_migration_fallback_total{reason}` | 迁移耗时与降级率 | 单阶段 P95、降级原因分布 |
| `skyext_session_dedup_hit_total{mode}` | 上行幂等命中 | 客户端重传趋势 |
| `skyext_gate_connections`、`skyext_gate_stale_binds_total` | 网关连接与迟到绑定 | 连接泄漏 |

**场景**（按依赖顺序）：

1. **登录洪峰**：N 客户端 60s 内集中登录。看 `ws_handshake_inflight`、登录失败率、
   实体加载时延（`entity loaded` 日志间隔）。
2. **单角色关键操作**：同一角色串行打 `critical.execute_client`。
   采集**两次多数派写整体 P95/P99**、实体队列占用时长、同 owner 续做率。
3. **Outbox 吞吐**：制造积压后观察排空速率与 `pending_age` 曲线，确认扫描不吃满 Mongo。
4. **支付回调**：并发重复回调同一单号，确认只发一次奖（看 `skyext_pay_grant_total`）。
5. **迁移**：整节点迁移 K 个在线角色，采集 `migration_phase_seconds` 与降级率。

**通过标准（初值，需按硬件校准）**：关键操作 P99 不随在线人数线性上升；
`critical_quarantined_total` 为 0；`outbox_pending_age` 在压测结束后 5 分钟内归零；
迁移降级率 < 1% 且没有 `CRITICAL_UNKNOWN` 之外的降级原因。

## 3. 需要在集成环境执行的部分（待跑）

以下三条**没有**在 CI 里跑，因为它们需要真实的多节点/副本集环境。步骤固定下来，
避免下次又从零摸索。

### B1：真实副本集多数派实测

1. 起三节点副本集（`rs.initiate`），确认 `w:majority, j:true` 生效。
2. 用 `coll:critical_probe()` 确认命令通道可用。
3. 压测期间对主节点执行 `rs.stepDown(60)`：期望进行中的关键操作返回 `UNKNOWN`，
   缓存进入隔离，恢复任务把它推进到终态，**不出现**"同一 op 两次入账"。
4. 断言：`_critical_ops_v1` 里同一 `op_id` 只有一条记录，`_version` 单调递增。

### P00-C：真实网络 WS 回环

1. 起 `gate_ws` + 一个 echo 实体，用真实 WebSocket 客户端连入。
2. 校验六状态机：RESERVED → HANDSHAKING → OPEN → CLOSING → CLOSED 的转移次数。
3. 握手期间断网/重连，确认配额无泄漏（`ws_handshake_inflight` 回零）。
4. 客户端已收包但 ACK 丢：续接后服务端重放，客户端按 `(session_epoch, seq)` 去重。

### 跨节点迁移回环

1. 两个 skynet 节点 + 一个客户端，角色在 A 上在线。
2. 对 A 发 `node_shutdown`：期望客户端**不断线**，`session_epoch` 不变，
   `owner_epoch` 递增，缺失的 seq 被重放且只交付一次。
3. 注入：快照传输失败、Gateway ack 丢、迁移中 `CRITICAL_UNKNOWN`。
   期望分别落到 `FALLBACK`，客户端重连后可继续，且没有重复资产效果。

## 4. 已知边界

- 压测脚本不在仓库里：仓库只提供指标与注入点，压测工具（wrk/自研 bot）属于部署侧。
- 故障注入是依赖替身，不是运行期开关：生产环境**没有**可以打开"注入故障"的入口，
  这是刻意设计。
- 归档的**吞吐**没有压测数据：保留期 7 天、单角色单次 64 条是初值，需要按
  `skyext_critical_archive_total` 与 `_critical_ops_v1` 体积实测校准。
- 迁移的 `activate` 需要游戏层接上网关 `bind_owner`，框架只提供原语与失败语义。
