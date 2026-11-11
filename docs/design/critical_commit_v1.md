# 关键操作双入口与提交内核（v1）

> **状态：已实现（P08）。** 代码：`lualib/skyext/critical.lua`；
> 依赖：`skyext.dbmgr`（状态机与多数派 CAS，P07）、`skyext.capability`（内部凭证）、
> `skyext.grant`（客户端授权）、`skyext.fingerprint`（参数摘要）。
> 用例：`lualib/skyext/critical.test.lua`。

## 1. 两个入口，一个内核

| 入口 | 适用 | 凭证 |
|---|---|---|
| `critical.execute_client(entity, grant, seq, op_type, params, handlers, opts)` | 客户端已认证请求 | Grant 签名 + rid + 有效期 + seq 范围 |
| `critical.execute_internal(entity, service_op_id, op_type, params, handlers, opts)` | 支付回调 / Outbox 接收方 / Saga 步骤 | `capability`（进程内不可序列化对象） |

两者都进入 `commit_core`：

```text
实体队列 -> dbmgr 行锁
  -> 已结算操作查重（COMMITTED / BUSINESS_REJECTED / ABORTED）
  -> 意图互斥检查（另一 op 在飞则 IN_PROGRESS）
  -> 纯读预检 validate（拒绝 -> PRECHECK_REJECTED，不写任何东西）
  -> PREPARE：只写 _critical_intent_v1 + _version（majority）
  -> COMMIT：apply（纯内存）-> snapshot_mongo + _critical_ops_v1[op_id] + 清意图（majority）
```

`entity` 只需提供 db 坐标：`{ rid, dbname, dbcoll, key, unique_id, handle, doc }`
（或 `entity.db_coords`）。测试可以直接给 `db_coords`。

## 2. 操作键

| 来源 | 格式 | 生成 |
|---|---|---|
| 客户端 | `<32 hex grant_id>_<4 hex seq>` | `grant.op_id` |
| 内部 | `srv_<64 hex>` | 来源记录首次持久化时确定 |
| 事件 | `evt_<64 hex>` | 源角色 Outbox 记录 |

`service_op_id_from_event` 是**字节级一一映射**（`evt_` → `srv_`），不依赖 HMAC、
密钥、进程或时间：同一事件在任何节点、任何进程、任何测试工具上结果完全相同。
重试时重新随机生成 ID 会让去重彻底失效，因此格式被严格校验（长度、前缀、小写 hex）。

`op_id` 会直接拼进 `$set` 的路径（`_critical_ops_v1.<op_id>`），因此必须是安全的
Mongo 字段名：不含 NUL、不含 `.`、不以 `$` 开头。`field_name_safe` 在写入前拦截。

## 3. 参数摘要

`param_hash = hex(HMAC(canonical_encode_request(op_type, params)))`，与上行幂等用同一条
规范化通道。同一 `op_id` 换参数会被 `OP_CONFLICT` 挡住，而不是当成重放回历史结果。

摘要函数必须由调用方**单独注入** `opts.hash_fn`。`grant` 的 `hmac_fn(key_id, bytes)`
是按 `key_id` 选密钥的两参函数，直接拿来当摘要函数会让每个请求都算不出 hash，
进而把所有客户端请求都变成 UNKNOWN。

## 4. 状态与缓存处置

| 决策 | 是否写库 | `cache_policy` |
|---|---|---|
| `COMMITTED` | 是（COMMIT CAS） | `CACHEABLE` |
| `BUSINESS_REJECTED` | 是（只写拒绝结果，不改 ORM） | `CACHEABLE` |
| `PRECHECK_REJECTED` | **否** | `NO_CACHE` |
| `OP_CONFLICT` / `EXPIRED` / `INTERNAL_AUTH_DENIED` | 否 | `CACHEABLE` / `NO_CACHE` |
| `UNKNOWN` | 可能已写 | `NO_CACHE` |
| `IN_PROGRESS` | 否 | `NO_CACHE` |
| `CAPACITY_EXCEEDED` | 否（`_critical_ops_v1` 已达硬阈值） | `NO_CACHE` |

`PRECHECK_REJECTED` 是"这次条件不满足"，**不是该 op_id 的持久化终态**：不写意图、
不声明持久化拒绝、不进 L1。条件变化后同一 `op_id` 可以重新预检。

`BUSINESS_REJECTED` 是持久化终态：`apply` 在 PREPARE 之后判定拒绝时，必须在同一个
CAS 里写下拒绝结果并清掉意图，否则后续操作会永远被 `IN_PROGRESS` 挡住。

**`apply` 返回 false 时不得改动 ORM。** 框架在 `apply` 前后各取一次
`orm.snapshot_mongo` 做比较；发现内存被改过就隔离并返回 UNKNOWN——否则脏字段会留在
回存轮上，下一次普通回存就把"被拒绝的操作"写进库。

## 5. UNKNOWN 的三条来源

| 来源 | 处理 |
|---|---|
| PREPARE 的 majority 写未确认 | 缓存进 `CRITICAL_QUARANTINED`，返回 `recovery_id = op_id`；**绝不执行 apply** |
| `apply` 抛错 | 内存可能已被污染，直接隔离；COMMIT 从未发出 |
| COMMIT 的 majority 写未确认或 CAS 未命中 | 隔离；内存已被 apply 改过，不能回存也不能继续用 |

三种情况都不重试成"没写"，也不声称成功。恢复由 `critical_reconcile_jobs` 驱动。

## 6. 同 owner 快速续做

`_critical_intent_v1` 存在且 `op_id` 相同时，跳过 PREPARE 直接进 COMMIT，但**仍然
重新进入 `PREPARING`**：否则普通回存会在 COMMIT 之前插进来推进 `_version`，
COMMIT 的 CAS 条件立刻失效。

这个捷径有四个前置条件，全部满足才成立：

1. `intent.op_id` 相同；
2. `intent.op_type` 与 `intent.param_hash` 相同（否则是拿旧意图当新操作的通行证，
   返回 `OP_CONFLICT`）；
3. `intent.owner_fence` 与当前 fence 相同（进程重启/换 owner 后不再相等，
   返回 `UNKNOWN` + `recovery_id`）；
4. 同一进程、同一实体实例，且能证明 COMMIT 从未发出。

第 3 条是关键：进程重启或多节点接管后，即使库里仍是 PREPARED，也必须走多数派 Fence
屏障（`abort_intent` + 重新 PREPARE），不能凭"同 fence"推断没有迟到的 COMMIT。

## 6.1 内部凭证的核销时机

`capability.verify` 在入口处做一次无副作用核验；真正的 `capability.consume` 放在
**第一个写入点之前**（PREPARE 的 CAS 前）。这样：

- 明显伪造/过期/绑定不符的 cap 在读取任何状态之前就被拒绝；
- 纯读预检拒绝（`PRECHECK_REJECTED`）**不消耗凭证**，同一枚 cap 在条件变化后可以重试；
- 已提交的重放、`OP_CONFLICT`、`IN_PROGRESS` 会消耗凭证（它们暴露了持久化状态）。

## 7. 取消未决意图

`abort_intent` 用**一次 CAS** 同时写 `_critical_ops_v1[op_id] = {status="ABORTED"}`
与 `$unset _critical_intent_v1`。

只做 `$unset` 的话，ACK 丢失后无法区分"取消成功"和"根本没取消"。`ABORTED` 也不等于
已消费：`query` 对它返回 `NOT_STARTED`，后续 PREPARE 仍要重新做参数一致性检查。

## 8. 恢复任务

`critical_reconcile_jobs` 唯一键 `(rid, op_id)`，状态
`PENDING → CLAIMING_FENCE → READING → RESOLVING → COMPLETED_*`，任何步骤可转
`RETRY_WAIT` / `MANUAL_REVIEW`。

- `reconcile` 幂等补建/唤醒：`$setOnInsert` 写不可变字段，`$set` 只更新 `updated_at`。
- `claim_job` 用 `(job_version, state ∈ {PENDING, CLAIMING_FENCE, RETRY_WAIT}, lease_until <= now)`
  做原子抢占，`$inc job_version`。`job_version` 与 `lease_until` 都必须是整数：
  缺省的 `job_version` 根本不进 BSON，query 就退化成"没有版本条件"，任何协调者都能
  抢走正在处理的任务。`state` 过滤是必须的——`finish_job` 会 `$unset lease_until`，
  只按"租约过期"匹配的话已终结的任务会重新变成可认领。
- `finish_job` 用 `job_version` 做 CAS，避免过期租约写回终态。

**任务表只负责调度与观察，不是资产状态权威。** 资产结果永远取角色文档的
`_critical_*` 与多数派 Fence 认领结果。

## 9. 索引门禁

| 集合 | 索引 | 目的 |
|---|---|---|
| 角色 | `{_critical_intent_v1.state:1, rid:1}`（partial: `state="PREPARED"`） | 无全表扫描地枚举未决角色 |
| jobs | `{rid:1, op_id:1}` **unique** | 多协调者/补建只对应一份逻辑任务 |
| jobs | `{state:1, lease_until:1}` | 到期接管、按状态检索 |
| ledger | `{rid:1, op_id:1}` **unique** | 冷账本业务去重 |

`ensure_indexes` 任一索引建失败就返回 `nil, err`，调用方必须**禁止启用该业务模块**。
没有唯一索引，多协调者会为同一 op 建出多份任务；没有 partial 索引，恢复扫描就是全表扫描。

驱动把 `createIndex` 的 `runCommand` 原始回复直接返回，失败形态是 `{ok=0, errmsg=...}`
的表而不是 `nil/false`——只看 `nil/false` 会让门禁在最需要它的时候放行。

## 10. 未覆盖

- 支付回调的验签与 `charge_order` 落单属于 P09；本模块只提供被它调用的
  `execute_internal` 内核。
- Outbox 的 `PENDING→ENQUEUED` 状态 CAS、Saga 补偿属于 P13。
- 真实副本集上的 majority 行为仍需按 B1 门禁实测。
- `_critical_ops_v1` 的归档 worker 属于 P13；本模块只提供硬阈值
  （`M.MAX_OPS`，默认 512）与 `CAPACITY_EXCEEDED`，靠归档吞吐保证平时不触达。
- 冷账本 `op_ledger` 的唯一索引已建，但写入方（归档）属于 P13。
