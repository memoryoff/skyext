# Transactional Outbox 与消息信封（v1）

> **状态：Outbox、调度器、接收方与 Saga 协调者均已实现（P13）。**
> 代码：`lualib/skyext/outbox.lua`、`lualib/skyext/outbox_worker.lua`、
> `lualib/skyext/saga.lua`、`service/outbox_worker.lua`；
> 用例：`outbox.test.lua`、`outbox_worker.test.lua`、`saga.test.lua`。

## 1. 根本限制

`router.reliable_send` 内部每次 `id_generator.newid()` 分配新的 `msg_id`，所以
"重试同一事件"**不会**自动去重底层队列消息。想靠 `msg_id` 做业务去重是错的：
同一个业务事件在重试后会有多个不同 `msg_id`。

本模块不改队列主键，改用**消息信封**。

## 2. 一次 CAS 里完成的事

源角色文档在同一次多数派 CAS 中持久化：

```text
资产扣减 + 消费记录 _critical_ops_v1[op_id] + _critical_outbox_v1[event_id] = {status="PENDING"}
+ _critical_outbox_pending_count（可索引标志，供恢复扫描）
```

这条约束由 `critical` 的提交内核保证：调用方把事件表放在 `opts.outbox`，内核在
COMMIT 的 `$set` 里同时写 `_critical_outbox_v1.<event_id>` 与
`_critical_outbox_pending_count = 旧值 + 事件数`。**发送方扣资源与 Outbox 是同一次原子写**。

`_critical_outbox_pending_count` 与三个结构字段一起在 `critical_fields` 白名单里：
它既是索引字段，也是"离开 PENDING 时恰减一次"的凭据。漏进白名单会让写了 Outbox 的
角色在下次加载时被当成"未知关键字段"直接拒绝。

容量：单角色 `_critical_outbox_v1` 最多 `critical.MAX_OUTBOX`（512）条，超了在
PREPARE 之前 `CAPACITY_EXCEEDED`，而不是等 Mongo 报文档过大。

## 3. 事件与信封

| 字段 | 说明 |
|---|---|
| `event_id` | `evt_<64 hex>`，由可信来源**一次**生成并与 Outbox 记录一起持久化；重试不得重新随机 |
| `target_type` / `target_id` | 接收方实体 |
| `op_type` | 接收方业务类型（白名单校验） |
| `param_hash` | 64 hex，与 `critical` 用同一条摘要通道 |
| `status` | `PENDING` / `ENQUEUED` / `DELIVERED` / `FAILED` |
| `attempt` | 进入 `ENQUEUED` 的次数，用于观测重复投递 |

投递信封带 `event_id`、来源、目标、`op_type`、`payload`、`param_hash`。
接收方用 `service_op_id_from_event(event_id)` 得到稳定业务键，再经
`critical.execute_internal` 保证至多一次业务效果。

**`msg_id` 只用于队列 ACK/重试计数/死信；`event_id` 才是业务去重键。**

## 4. 投递顺序：先投递、后 CAS

```text
pump:
  取一批 PENDING（按 created_at 排序，同角色事件有先后依赖）
  -> deliver(envelope)          -- 可靠消息确认入队；可能 yield
  -> CAS: status=PENDING -> ENQUEUED，同时 pending_count - 1
```

顺序是硬约束。先 CAS 再投递的话，进程在两步之间崩溃会留下"已入队但从未发出"的事件，
而 `pending_count` 已经减掉，恢复扫描再也找不到它。

CAS 的 query 额外带 `_critical_outbox_v1.<event_id>.status = "PENDING"`：
另一个 worker 已经推进过就命中不了，`pending_count` 不会被减第二次。

## 5. 结果分类

| 情况 | 处理 |
|---|---|
| `deliver` 返回 true | 推进 `ENQUEUED`，计数减一 |
| `deliver` 返回 false / 抛错 | **保持 PENDING**，允许底层 `msg_id` 重复，业务靠 `event_id` 去重；本批就此停下，后面的事件不能抢跑 |
| CAS `cas mismatch` / `version mismatch` | 读后像后有界重试；若事件已被别的 writer 推进则结束（`ALREADY`），不重投也不重复减计数 |
| CAS 其它 `REJECTED`（`lease expired` / `owner changed` / 隔离 / 多数派不可用） | **BLOCKED**：环境或归属问题，不重试、不继续本批。重试只会每轮重复投一条可靠消息 |
| CAS `UNKNOWN` | `OUTBOX_STATUS_UNKNOWN`：立即停止本批；用 `dbmgr.refresh_critical` 多数派读对齐版本，等下一轮 |

状态 CAS 走 `dbmgr.critical_update(..., { metadata_only = true })`：它写的是元数据，
UNKNOWN 时**不隔离玩家资产缓存**。把它和 `CRITICAL_COMMIT_UNKNOWN` 混为一类，会让一次
写关注超时锁死玩家的全部经济操作。

把 CAS miss 当成 UNKNOWN 会让每一次正常的并发推进都触发隔离；把 UNKNOWN 当成
CAS miss 则会宣称一个可能没写成功的状态。

`ENQUEUED` 只表示"可靠消息入队已确认"，**不等于接收方已入账**。只有接收方持久化
ACK 才能推进 `DELIVERED` 或做安全清理；在那之前不能删除唯一可恢复的事件源。

## 6. 调度器（`outbox_worker`）

扫描与投递分离，**worker 从不直接写角色文档**：

```text
scan  --(索引 _critical_outbox_pending_count > 0)--> [rid...]
  -> router.call_loaded(rid, "outbox_pump", limit)     -- 实体不在内存则跳过
  -> （可选）router.call 受控加载，单轮上限 max_loads
  -> 实体队列内 with_loaded_entity -> outbox.pump -> 可靠消息 + 状态 CAS
```

- 为什么必须经 owner：`PENDING -> ENQUEUED` 是一次 `_version` CAS，角色文档的写入
  必须和玩家请求走同一条实体队列。绕过 owner 直接写会和业务请求抢同一个 `_version`，
  把版本冲突变成线上随机失败。
- 索引是门禁：`ensure_indexes` 失败时调度器**不启动**，宁可不投递也不用全表扫描。
- 轮转游标：每轮记录 `skip`，页满时前进、页不满归零，避免前面的角色一直投不出去时
  后面的角色饿死。
- 离线角色：默认允许受控加载（`max_loads`），否则玩家不在线时积压永远排不空。

指标：`skyext_outbox_scan_total{result}`、`skyext_outbox_scan_candidates`、
`skyext_outbox_pump_total{result}`、`skyext_outbox_pending_age_seconds{type}`、
`skyext_outbox_cas_retry_total{op_type}`。

## 7. 接收方（`outbox.new_receiver`）

游戏层的 `__apply_outbox_event` 只需要一行 `return receiver:handle(entity, envelope)`。
框架在这一层做完四件事：

1. 信封自洽校验（版本、`event_id` 格式、目标、`op_type`、`param_hash` 长度）；
2. **目标必须就是本实体**——错投的事件绝不在本实体上执行；
3. 用同一条摘要通道重算 `param_hash`，与信封不符按永久无效处理（重试不会成功）；
4. 在 `entity_agent` 进程内签发 capability（cap 不能跨进程传），再走
   `critical.execute_internal`。

返回值语义：

| 情况 | 返回 | `_deliver_one` 的行为 |
|---|---|---|
| `COMMITTED` / `BUSINESS_REJECTED` / `PRECHECK_REJECTED` | `critical` 的 decision | 业务终态，ACK |
| `UNKNOWN` / `IN_PROGRESS` / `CAPACITY_EXCEEDED` | `delivery.retryable(reason)` | 保留 pending，不累计 attempts、不进 DLQ |
| 永久无效（信封/目标/摘要不符） | `nil, err` | 按旧合同 ACK，不重复重投 |
| `OP_CONFLICT` / `INTERNAL_AUTH_DENIED` | **抛错** | 计入 attempts，到上限进 DLQ，人工可见 |

`IN_PROGRESS` 和容量不足都是暂态：ACK 掉会让业务永不执行且不再重投，这是最隐蔽的
丢事件方式。

信封里的 `target_id` 与实体 `id` 用归一化比较（`outbox.id_key`）：BSON 往返后 int64
会变成字符串，裸 `~=` 会把一个完全合法的信封判成"错投"并永久 ACK。

## 8. Saga 协调者（`skyext.saga`）

```text
CREATED --reserve--> RESERVED --commit--> COMMITTED
                       |                    |
                       +-----compensate-----+--> COMPENSATING --compensated--> COMPENSATED
CREATED --业务拒绝--> FAILED
```

- 迁移表是**显式**的：只判断"源状态可认领"会让 `CREATED` 直接跳到 `COMPENSATED`，
  跳过整个补偿过程还宣称已冲正。
- `saga_id = sag_<64hex>` 由 `(kind, business_key)` 确定性推导，创建天然幂等。
- 步骤键 `evt_<64hex>` / `srv_<64hex>` 由 `(kind, key, step)` 推导，重试不变；
  信封复用 Outbox 接收方，Saga 不需要第二套投递协议。
- `run` 每次只做"读文档 → 执行当前状态那一步 → CAS 推进状态"。状态在步骤**之后**落库，
  崩溃后重跑同一步是幂等的（同一个 `service_op_id`）。
- 补偿失败保持 `COMPENSATING`：资产要么守恒，要么留在明确可恢复的冻结状态，
  不能因为补偿报错就宣称交易结束。
- `scan_due` 只返回"可认领状态 + 租约过期"的文档，按 `updated_at` 升序，命中
  `state_lease` 索引。步骤实现（reserve/commit/compensate）由玩法在自己的进程里注入，
  框架不跨进程注册业务 handler。

## 9. 未覆盖

- 归档 worker 与 `op_ledger` 冷账本写入属于同一批后续工作（`critical` 已有索引与
  `MAX_OPS`/`MAX_OUTBOX` 上限，但异步归档吞吐还没实现）。
- `skyext_outbox_*` / `skyext_saga_*` 指标目前只在本 VM 累加，跨节点汇总依赖
  `.metrics` 抓取。
- 接收方的 `DELIVERED` 回写（接收端 ACK 后清理源角色 Outbox 条目）尚未实现：
  当前保留 `ENQUEUED` 条目，清理策略需要与归档 worker 一起设计，避免删掉唯一
  可恢复事件源。
- 同角色事件的先后顺序依赖 `created_at`（秒级）+ 本批"遇到失败即停"。同一秒内创建的
  多个事件没有严格顺序；需要严格因果的场景应把多个效果放进**同一次提交**，而不是
  依赖两条事件之间的顺序。
- Outbox 扫描是 `skip` 分页 + `{pending_count:1}` 偏索引。积压规模很大时应改为
  `{pending_count:1, rid:1}` 复合索引 + keyset 分页。
