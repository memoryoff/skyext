# 关键写入状态机与专用 CAS（v1）

> **状态：已实现（P07）。** 代码：`lualib/skyext/dbmgr.lua`；
> 用例：`lualib/skyext/dbmgr.test.lua` 的「dbmgr 关键状态机」。
> 上层入口（`critical.execute_client` / `execute_internal`）属于 P08，本文只冻结
> 它们依赖的持久化原语。

## 1. 为什么需要两条写入通道

`dbmgr` 原来的唯一写入路径是「ORM 脏字段 → `orm.snapshot_mongo` → `safe_update`（w=1）」。
关键经济操作用不了它：

- PREPARE 阶段**只能**写 `_critical_intent_v1` 和 `_version`。如果顺手调用
  `snapshot_mongo`，PREPARE 之前的普通脏字段会跟着落库，等于把还没 COMMIT 的
  资产变化提前提交，COMMIT 失败后再也回不去。
- 关键写入必须 `writeConcern={w:"majority", j:true}`；`safe_update` 用的是默认写关注。
- 关键写入的 query 必须同时带 `_version` 与 `_fence`，否则旧持有者的迟到写能越过屏障。

因此新增**独立通道** `M.critical_update`，两条通道共用同一把行锁和同一个 cache entry，
`_version` 只有一个推进者。

## 2. 缓存状态

`cache entry.state`：

| 状态 | 含义 | 普通回存 | 关键 CAS | 重新加载 |
|---|---|---|---|---|
| `NORMAL` | 正常 | 允许 | 允许 | 返回缓存 |
| `PREPARING` | 关键事务进行中 | **拒绝** | 允许 | 拒绝 `critical write in progress` |
| `CRITICAL_QUARANTINED` | 关键结果未决，内存可能被污染 | **拒绝** | **拒绝** | 拒绝 `critical state unknown` |
| `DISCARDED` | 确定作废 | 拒绝 | 拒绝 | 丢弃后重新读库 |

`PREPARING` 拒绝普通回存是必须的：回存会推进 `_version`，COMMIT 的 CAS 条件
（PREPARE 之后的版本）立刻失配，事务就永远提交不了。回存轮在这一状态下**静默跳过**
（返回成功、不记错误），否则事务期间每一轮都会刷一条 "sweep save failed"。

`end_critical(ok=true)` 只接受 `PREPARING → NORMAL`。隔离条目已被摘出回存轮，
无条件放回 `NORMAL` 会造出一个"状态正常但不在轮上"的条目，下一次 `M.save` 就能把
被 `apply` 污染的内存写回库。

`CRITICAL_QUARANTINED` 会同时从回存轮上摘除。留在轮上只会每轮刷一条
"refusing save in a non-normal state"，而且给了未来某次改动静默恢复写入的机会。

`M.recover`（失租后把脏缓存接回去）**明确拒绝**非 `NORMAL` 条目：它做的正是
"重新拿锁再存一遍"，对可能被 `apply` 污染的内存就是拿污染状态盖掉库里的真值。
这类条目只能由恢复任务按持久化事实判定后重载。

## 3. 专用 CAS

```lua
dbmgr.critical_update(dbname, dbcoll, key, unique_id, expected_version, update, opts)
  -> "CONFIRMED", { version, n, nModified }
  -> "REJECTED",  reason      -- 确定没写
  -> "UNKNOWN",   reason      -- 可能已写，entry 已进入 CRITICAL_QUARANTINED
```

函数内部补齐三个 CAS 条件，调用方只提供 update：

```text
query = { <key> = unique_id, _version = expected_version, _fence = handle.fence }
```

### 3.1 调用方不能做的事

以下 update 一律 `REJECTED`，不发送请求。校验覆盖**所有算子**（`$set` / `$unset` /
`$inc` / `$rename` …），只看 `$set` 会漏掉 `$unset:{rid:true}` 这种删掉身份字段的写法：

- 改写或删除身份字段；
- 改写 `_fence`；
- 自己指定 `_version`（只能由函数写成 `expected_version + 1`，且必须恰好 +1，
  跳号会让 PREPARE 与 COMMIT 之间的版本推导失效）；
- 本地租约已失效（`lease_valid(handle)` 为假）。fence 条件挡不住"同一个 fence
  但租约已过期"的迟到写，这一层必须在本地拦。

函数不会就地修改调用方的 `update` 表：注入的 `_version` 写在内部浅拷贝里，
同一张表可以复用于下一步 CAS。

### 3.2 三态的判定

| 结果 | 条件 | 处理 |
|---|---|---|
| `CONFIRMED` | 驱动返回 `CONFIRMED` 且 `n == 1` | 用 `orm.advance_persisted_version` 推进内存版本（**不清 dirty**） |
| `REJECTED` | 命令级拒绝，或 `n == 0`（版本/fence 未命中） | 确定没写，可按业务失败处理；不改状态 |
| `UNKNOWN` | `writeConcernError`、网络异常、`ok=1` 仍带 `errmsg`、内存版本推进失败 | 立即进入 `CRITICAL_QUARANTINED`，交恢复任务 |

`n == 0` 明确**不是** UNKNOWN。把它当 UNKNOWN 会让每一次正常的版本竞争都触发隔离，
而把它当成功则会伪造一次资产变动。

「数据库写成功但内存版本推不动」也归 UNKNOWN：这时既不能说成功（内存是旧的），
也不能说失败（库里已经写了），只能隔离重载。

### 3.3 读后像

`M.critical_read` 用 `critical_find`（majority 读）拿原始文档，供恢复任务核对
`_fence`/`_version`/`_critical_*`。**读失败不能降级成 `not found`**：恢复任务把
"不存在"当成"未提交"就会重放，等于二次扣费。因此返回
`nil, "read failed", err` 与 `nil, "not found"` 两个不同的结果。

### 3.4 没有多数派通道时

collection 上没有 `critical_update`（老驱动/测试桩）时返回
`REJECTED, "majority update unavailable"`。降级成 `w=1` 等于放弃"已提交"语义，
比拒绝更危险。

## 4. 与普通回存的关系

- `save_doc` 的签名从「doc + handle」改为「entry」，状态永远取 entry 的，
  不能用传入的 handle 绕过状态检查。
- `M.save` / `M.unload` / 回存轮 / `M.recover` 全部走同一个 `save_doc`，因此状态检查
  只有一处。
- `M.load` 命中隔离缓存时返回 `nil, "critical state unknown"`，而不是把可能被污染的
  文档交回去。实体因此拒绝加载，重登也清不掉冻结状态（符合 I11）。

## 5. 未覆盖

- `critical.execute_client` / `execute_internal`、PREPARED/COMMITTED 状态、恢复任务
  `critical_reconcile_jobs`、索引 DDL 属于 P08。
- 真实副本集上的 majority 行为仍需按 B1 门禁实测；本文的三态只是对驱动返回值的
  分类合同，不代表已在副本集上验证过。
