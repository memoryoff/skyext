# 内部经济操作 capability 契约 v1

> 状态：P08/P09/P13 的前置契约。`lualib/skyext/capability.lua` 已实现并有单测；
> `critical.execute_internal` 本身属于 P08，本契约先冻结鉴权边界与签发点。

## 1. 要解决的问题

`execute_internal(entity, service_op_id, op_type, params, {source="payment"})` 里的
`source` 是任意调用者都能填的字符串，**不构成鉴权**。支付回调、Outbox 接收方和 Saga
步骤都走内部入口，但它们可能由不同服务触发，不能靠"调用者说自己是 payment"。

## 2. 冻结设计

```lua
local capability = require "skyext.capability"
local issuer = capability.new_issuer("payment", { "grant_coin" })   -- 受信任适配层持有
local cap = assert(capability.issue(issuer, {
    rid = rid,
    service_op_id = service_op_id,
    op_type = "grant_coin",
    payload_hash = param_hash,
    source_id = provider .. ":" .. order_id,
}))

-- 实体进程内，提交内核之前
local ok, err = capability.consume(cap, {
    rid = rid,
    service_op_id = service_op_id,
    op_type = "grant_coin",
    payload_hash = param_hash,
})
if not ok then return err end
```

- `cap` 是**空表 + 私有 metatable**，字段全部在模块私有的弱键注册表里。复制、深拷贝、
  重设 metatable、跨进程序列化后都拿不到同一身份，`verify` 一律返回 `INVALID`。
- 绑定 `{rid, namespace, source_id, service_op_id, op_type, payload_hash}`，签发时带
  `ttl`（默认 30 秒）；`consume` 校验后立即吊销，一次分发只能进一次 PREPARE。
- `issuer` 同样不暴露字段；`new_issuer` 只给受信任模块调用，不通过 `sproto_api`、
  RPC 或 GM 接口导出。
- 业务函数若要异步延后执行，必须重新核验持久化来源并重新签发 cap，不能保存/传递旧 cap。

## 3. 三个签发点必须都在 entity_agent 进程内

cap 是不可序列化的 Lua 对象，跨进程传过去只会变成无效表。因此：

| 签发点 | 允许做的事 | 禁止做的事 |
| --- | --- | --- |
| 可靠消息 `_deliver_one` | 从持久化 `entity_msg` / Outbox 记录校验信封、目标、cmd/op_type 后，为**这一条实际投递**签发 | 让任意 `router.reliable_send` 调用者直接拿到 cap；用 `msg_id` 代替 `event_id` |
| 支付回调 | HTTP 服务验签、落 `charge_order`（唯一索引）后 `router.call` 到 entity_agent；entity_agent 读**持久化订单记录**后签发 | 在 HTTP 服务里签发 cap 再试图传给实体；凭 `{verified=true}` 的 Lua table 签发 |
| Saga | 协调者只经可靠消息投递步骤；entity_agent 读持久化步骤记录后签发 | 协调者进程内签发 cap 跨进程传递；客户端协议直接选择 Saga 步骤 |

`_deliver_one` 是实体串行队列里的入口，但**不能**用模块级 `current_cap` 保存当前 cap：
队列串行只保证队列内不并发，其它协程仍可能同时调用 `execute_internal`，模块级变量会串号。
本实现用 **per-coroutine 上下文**（`capability.run_with` / `capability.current`），
协程结束自动消失，嵌套调用会恢复上一层。

## 4. 验收（T23B）

| 输入 | 期望 |
| --- | --- |
| 客户端伪造 `{source="payment"}` | `INVALID`，不进入 PREPARE |
| Lua table 仿造 cap / 偷 metatable 重建 | `INVALID`，不进入 PREPARE |
| 跨 rid、跨 op_type、换 payload、换 service_op_id 重放 | `BINDING_MISMATCH` |
| cap 过期 / 已 consume / 已 revoke | `EXPIRED` / `REVOKED` |
| 伪造 Outbox envelope、非法 Saga 步骤 | 签发点校验失败，不签发 |
| 真实已验签支付 / 已持久化 Outbox / Saga | 三个入口都能完成同一个 `critical_commit_core` |

## 5. 边界说明

同一 Skynet VM 里能执行任意恶意 Lua 代码的攻击者**不是**本模块的防御对象。cap 证明的是
"这次调用来自受信任分发链"，不是进程内安全沙箱。真正的隔离依赖服务边界、来源记录的
持久化校验和 op_type 白名单。
