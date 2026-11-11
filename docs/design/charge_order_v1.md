# 支付订单与发奖（v1）

> **状态：订单与发奖适配层已实现（P09）。** 代码：`lualib/skyext/charge_order.lua`；
> 用例：`lualib/skyext/charge_order.test.lua`。
> **HTTP 回调服务本身未实现**，见 §5。

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

## 5. 未覆盖

- **HTTP 回调服务**（验签、商品/金额校验、ACK 响应）不在本模块：本模块只提供
  被它调用的落单、状态机与发奖内核。
- `GRANTED -> RECONCILED` 的对账 worker 属于后续工作。
- 真实支付渠道的签名算法与重放窗口需要按渠道单独实现并测试。
