# Transactional Outbox 与消息信封（v1）

> **状态：Outbox 部分已实现（P13）。** 代码：`lualib/skyext/outbox.lua`；
> 用例：`lualib/skyext/outbox.test.lua`。
> **Saga 协调者尚未实现**，见 §6。

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

这条约束由 `critical` 的提交内核保证：`apply` 只改内存，`_critical_outbox_v1` 与
资产增量进同一个 `critical_update`。**发送方扣资源与 Outbox 是同一次原子写**。

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
| `deliver` 返回 false / 抛错 | **保持 PENDING**，允许底层 `msg_id` 重复，业务靠 `event_id` 去重 |
| CAS `nMatched=0` | 视为"另一个 worker 先推进了"，**不是**资产已执行但 ACK 丢失的 UNKNOWN；有界重试 |
| CAS `UNKNOWN` | `OUTBOX_STATUS_UNKNOWN`：立即停止本批，不做后续写入，等对账 |

把 CAS miss 当成 UNKNOWN 会让每一次正常的并发推进都触发隔离；把 UNKNOWN 当成
CAS miss 则会宣称一个可能没写成功的状态。

`ENQUEUED` 只表示"可靠消息入队已确认"，**不等于接收方已入账**。只有接收方持久化
ACK 才能推进 `DELIVERED` 或做安全清理；在那之前不能删除唯一可恢复的事件源。

## 6. 未覆盖

- **Saga 协调者**（`CREATED → RESERVED → COMMITTED` / `COMPENSATING → COMPENSATED`）
  尚未实现。它的每一步都应当复用本模块的 `event_id` + `service_op_id` 映射与
  `critical.execute_internal`，但协调者状态机、补偿与"最终资产守恒或明确冻结"
  的验收还没有代码。
- Outbox worker 的**索引扫描**（`_critical_outbox_pending_count > 0`）与跨角色调度
  还没有独立服务；`pump` 只处理单个已加载角色。
- 归档 worker 与 `op_ledger` 冷账本写入属于同一批后续工作。
- `skyext_outbox_*` 指标目前只在本 VM 累加，跨节点汇总依赖 `.metrics` 抓取。
