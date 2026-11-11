# 请求缓存处置（CACHEABLE / NO_CACHE）契约 v1

> 状态：P03/P08 的前置契约。`sproto_api` 与 `session.with_request` 已实现并有单测。

## 1. 问题

`session.with_request()` 目前只看 `type(result[1]) == "string"` 就写 L1 `resp_cache`。
业务 handler 返回正常错误响应时，`sproto_api` 也会先编码成字符串，于是"余额不足"这类
**纯读预检拒绝**会被永久缓存：客户端重传时命中旧拒绝，即使余额已经变化。

同时不能把 `cache_policy` 塞进 `dispatch_request` 的 `reason` / `code` 位：
`raw_dispatch` 把 `(nil, reason)` 当成"请求被拒绝"，一个没有 response 的单向协议
（handler 返回 nil、但带 NO_CACHE）会被误判成拒绝并可能踢线。

## 2. 冻结接口

```lua
-- 业务 handler 返回私有哨兵，不是普通响应表
return sproto_api.decision({ errcode = errcode.NOT_ENOUGH }, sproto_api.NO_CACHE)
return sproto_api.decision({ errcode = errcode.OK, ... }, sproto_api.CACHEABLE)
```

- `CriticalDecision` 用私有 metatable 识别，普通 table 不可能撞上；不导出给 sproto/RPC。
- `dispatch_request_unlocked` 在内部解包：`response_cb` 只编码 `decision.response`，
  `cache_policy` 走**独立的第 4 个返回值**，不占 `reason` / `code`。
- `session.with_request` 在实体串行临界区内按 `result[4]` 决定是否写 L1；
  `NO_CACHE` 的任何返回包都不写缓存。
- 旧 handler 不返回决定值时 `cache_policy` 为 nil，缓存规则与改造前一致。
- 没有 response 的协议：`decision(nil, NO_CACHE)` 返回 `(nil, nil, nil, policy)`，
  `raw_dispatch` 不再把"协议本来就没有 response"当成客户端在等回包。
  注意 sproto 对无 response 协议也会给一个只编码包头的闭包，所以判断"客户端在等"
  必须看 schema 是否声明了 response，而不是 `response_cb ~= nil`。

## 3. 语义

| 结果 | 缓存 | 说明 |
| --- | --- | --- |
| `COMMITTED` / 已持久化 `BUSINESS_REJECTED` | `CACHEABLE` | 重传回放同一业务结果 |
| `PRECHECK_REJECTED`（纯读预检拒绝） | `NO_CACHE` | 条件可能变化，同 op_id 可重新预检 |
| `UNKNOWN` / `RETRYABLE_ENVIRONMENT_FAULT` | `NO_CACHE` | 结果未定，不能固定成永久拒绝 |
| 旧 handler 的普通响应 | 沿用旧规则 | 行为不回退 |

`critical.query(grant_id, seq)` 只报告持久化事实（`NOT_STARTED` /
`EXPIRED_NOT_EXECUTED` / `IN_PROGRESS` / `UNKNOWN` / 已提交结果），不报告未持久化的
纯读预检；数据库不可用不能伪称 `NOT_STARTED`。

## 4. 验收（T09A）

- 余额不足返回正常业务错误包，连接不断开。
- 同一 `req_id` 在余额变化后重传，未因 L1 命中而固定拒绝（`resp_cache` 里没有该条目）。
- 已提交的同一业务操作仍缓存并可跨重传回放。
- `NO_CACHE` 且无 response 的协议不产生拒绝、不断连。
- 旧无标记 handler 的缓存行为不变。
