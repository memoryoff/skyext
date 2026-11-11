# 支付订单与发奖（v1）

> **状态：订单、发奖适配层、HTTP 回调与对账 worker 均已实现（P09）。**
> 代码：`lualib/skyext/charge_order.lua`、`lualib/skyext/pay_webhook.lua`、
> `lualib/skyext/pay_callback_router.lua`、`lualib/skyext/charge_reconcile.lua`、
> `service/pay_callback.lua`；
> 用例：`charge_order.test.lua`、`pay_webhook.test.lua`、`charge_reconcile.test.lua`。

## 1. 与客户端授权的分工

支付回调**没有客户端 Grant**，所以它不能走 `critical.execute_client`。它走
`critical.execute_internal`，与 Outbox 接收方、Saga 步骤共用同一个提交内核。

`service_op_id` 由 `(provider, order_id, action)` 规范化后 HMAC 得到，格式
`srv_<64 hex>`。**在订单第一次持久化时确定并保存**，之后只读不重算：密钥轮换后
重新计算会得到不同的键，去重立刻失效。

## 2. 订单落单

```text
record(orders_coll, { provider, order_id, rid, amount, currency, action, hash_fn })
  -> order, created   -- 重复回调返回已有订单且 created=false
```

- `(provider, order_id)` **唯一索引**是重复回调只创建一条订单的唯一保证；
  `ensure_indexes` 建不出唯一索引时调用方必须禁止启用支付模块。
- 重复回调的金额、币种、账号必须与首次**完全一致**：任一不同都是串单或伪造，
  不能"以最新一次为准"。
- `created` 优先取驱动的 `lastErrorObject.updatedExisting`；没有这个字段时才退回
  比较 `created_at`。不要用"这次有没有走插入分支"来推断。

## 3. 状态机

```text
VERIFIED_RECEIVED -> GRANTING -> GRANTED -> RECONCILED
                              \-> (UNKNOWN 保持 GRANTING，等对账)
COMPENSATING -> COMPENSATED     -- 退款/拒付，独立操作键
```

`transition` 只在 `from` 状态上做 CAS：重复回调不能把 `GRANTED` 退回 `GRANTING`。

**HTTP ACK 与业务状态分开保存**（`webhook_ack_at` / `ack_result`）：渠道协议允许
"确认已可靠接收"后异步发奖，不能一概要求先 `GRANTED` 再 ACK。

## 4. 发奖

```text
grant(entity, order, handlers, { capability, hash_fn, orders_coll })
  -> critical decision
```

- 只有 `COMMITTED` 才把订单推进到 `GRANTED`；
- `UNKNOWN` 保持 `GRANTING` 并记 `last_error`，**不能重试成"没发"**，也不能宣称已发；
- 已经 `GRANTED` 的订单直接返回 `duplicate=true`，不再调用提交内核；
- 退款/拒付用 `compensation_op_id` 生成独立操作键，**不删除原流水**。

## 5. HTTP 回调

```text
验签 -> 解析商品/金额/币种/账号 -> 落单(唯一索引) -> ACK -> 发奖
```

- 验签在**任何持久化之前**：未通过验签的请求不留痕迹，也不 ACK；
- 同单号换金额/币种/账号 → `409`（伪造或串单），不"以最新一次为准"；
- 存储不可用 → `500`，让渠道重推，不谎称已接收；
- 落单成功后**先**把订单 CAS 到 `GRANTING` 再发奖：不先落这一步，发奖中途崩溃的
  单子对账永远扫不到；
- 发奖 `COMMITTED` → 订单 `GRANTED` + ACK；`UNKNOWN` / `IN_PROGRESS` / 容量不足 →
  留在 `GRANTING` + ACK，由对账收尾；业务拒绝 → 留在 `GRANTING` + 记 `last_error` +
  ACK（人工补偿）；cap 绑定/同 op 换参数这类契约失败 → **不 ACK**，回 5xx；
- 订单状态的权威在订单集合（回调层持有），实体进程只回 decision；
- 渠道允许先 ACK 时（`ack_before_grant`）发奖排到后台，订单停在 `VERIFIED_RECEIVED`。

路由：`http_server` 的路由表是精确路径匹配，所以按配置为每个渠道注册
`/pay/<provider>/callback`，另注册 `/pay/callback?provider=<name>` 给只允许固定
回调地址的渠道。渠道实现由配置 `pay_callback.providers[<name>].module` 指定，
模块只需暴露 `verify(req, body)` 与 `parse(req, body)`。

## 6. 对账 worker

```text
GRANTING --(角色文档里该 op 已 COMMITTED)--> GRANTED --> RECONCILED
GRANTED  --(同上)--> RECONCILED
```

- 唯一可信的证明是 `_critical_ops_v1[service_op_id].status`，不是"回调返回过 200"；
- 查询失败 ≠ 没发：保持 `GRANTING` 等下一轮，绝不标成未发奖；
- `NOT_STARTED` 才重新投递发奖（同一个 `service_op_id`，幂等）；
- `BUSINESS_REJECTED` 是"钱收了、东西没给"，只记错误与指标，不改写订单状态——
  这是要人工补偿的单子；
- `GRANTING` 的扫描带宽限期（默认 60s），避免抢正在飞的发奖；
- 业务拒绝的单子打 `reconcile_blocked_at` 后不再自动扫（转人工），否则它会永远占住
  结果集把新单饿死；扫描不排序，避免一张卡住的单长期占住队头。

## 7. 未覆盖

- 真实支付渠道的签名算法与重放窗口需要按渠道单独实现并测试（本框架只定义
  `verify` / `parse` 契约）。
- 退款/拒付只提供了独立操作键与状态位，具体渠道的退款接口与对账未实现。
- 订单历史归档（已完成订单的冷存储）未实现。
