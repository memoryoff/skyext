# 可靠消息接收侧：环境故障分类与观测契约 v1

> 状态：P13 的前置契约。`entitymgr._deliver_one` / `entity.delivery` 已实现并有单测。

## 1. 分类

`entitymgr._deliver_one` 过去只看 handler 是否抛错，随后无条件 `dbmgr.save` +
`mark_delivered`。新关键 handler 需要表达"Mongo 暂不可用、稍后重投"，但不能让所有
`xpcall` 抛错都变成可重试——那样代码 bug 会永远卡在 pending，既不 ACK 也不进 DLQ。

冻结为三种终态：

| handler 表现 | 分类 | 处理 |
| --- | --- | --- |
| 返回 `nil` / `true` / `false` / 普通 table | 成功（旧合同） | `dbmgr.save` + `mark_delivered` |
| 返回 `delivery.retryable(reason)` | 环境故障 | 不 save、不 ACK、不计 attempts、不进 DLQ，保留 pending |
| 抛异常 / 没有 handler / 封包永久无效 | 毒消息 | 计 attempts，到上限进 DLQ |

`retryable` 是私有 metatable 标记，普通 table 不能伪造。业务 handler 必须在边界内
把 Mongo 断连、Fence 失效、恢复中转换成它；框架不替业务判断异常类型。

## 2. 接收侧观测（B6 原先只有发送侧 `skyext_outbox_pending`）

| 指标 | 类型 | 含义 |
| --- | --- | --- |
| `skyext_reliable_msg_pending{type}` | gauge | 本 VM 最近一次读取 pending 页观察到的条数（满页时是下界） |
| `skyext_reliable_msg_retryable_total{type}` | counter | handler 返回环境故障的转换次数 |
| `skyext_reliable_msg_retry_escalated_total{type}` | counter | 同一 `msg_id` 连续 N 次环境故障后升级人工的次数 |

- `N` 由 `reliable_msg_retry_escalate` 配置，默认 10；进程重启会清零，这是"同进程连续"
  的语义，与 DLQ 的持久 `attempts` 是两件事。
- 到阈值时打 `log.error` 并带上 traceback/reason，然后把连续计数归零，避免每条消息每次
  重投都刷日志；升级计数保留事实。
- 实体卸载时 `delivery.forget(type, id)` 清掉该实体的 pending 观察值，避免 gauge 永久
  保留已经不在本节点处理的实体。

## 3. 验收（T25A / T25B）

- `execute_internal` 返回 UNKNOWN / Mongo 断连：`_deliver_one` 不 `mark_delivered`、
  不当作毒消息计 attempts，恢复后用同一 `event_id` 重投。
- 旧 handler 分别返回 `nil/true/false/普通 table`：全部按成功路径保存并 ACK。
- 新 handler 返回私有 retryable：不 ACK、不计毒、后续重投。
- 同一 `msg_id` 连续 N 次 retryable：升级指标 + error 日志，仍不进 DLQ。
