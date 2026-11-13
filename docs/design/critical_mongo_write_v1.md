# 关键 Mongo 写入与 fence 认领（P06）

> **状态：已实现。** 真实副本集的 majority/切主故障注入仍需 `SKYTEST_INTEGRATION=1`
> 环境验证；本文件记录接口契约与三态语义，单元测试用假 `runCommand` 覆盖分类逻辑。

## 1. 为什么不能沿用 `safe_update`

Skynet Mongo 驱动的 `safe_update` / `findAndModify` 只带默认写关注（`w=1`）：主节点写入
内存即 ACK，切主或主节点宕机时这次写入可能被回滚，而调用方已经把它当成"已提交"。
经济操作、未决意图、已提交账本都不能建立在这种 ACK 上。

## 2. 接口

`lualib/skyext/mongo_conn.lua` 的 collection 包装新增：

| 方法 | 写/读关注 | 返回 |
| --- | --- | --- |
| `critical_update(query, update, upsert)` | `{w="majority", j=true}` | `"CONFIRMED", {n, nModified}` / `"REJECTED", err` / `"UNKNOWN", err` |
| `critical_find(query, projection)` | `readConcern={level="majority"}` | 文档 / `nil, err` |
| `critical_find_and_modify(doc)` | `{w="majority", j=true}` | `"CONFIRMED", ret` / `"REJECTED", err` / `"UNKNOWN", err` |
| `critical_probe(coll)` | 真实 `{w="majority", j=true}` 写入 + 多数派读回 + 清理 | `true` / `nil, err` |

三态的定义：

- **CONFIRMED**：mongod 返回 `ok=1`，没有 `writeErrors` / `writeConcernError` / `errmsg`。
  对 update 而言 `n` 是匹配数；`n=0` 是**已确认未匹配**，不是失败。
- **REJECTED**：`writeErrors`，或命令级 `ok~=1`（参数错、权限不足等）。写入确定没有
  生效，调用方可以按业务失败处理。
- **UNKNOWN**：`writeConcernError`、网络异常/超时、`ok=1` 但仍带 `errmsg`。**写入可能
  已经生效**，调用方必须按未决处理：不能重试成"没写"，也不能当成"已提交"。

## 2.1 `critical_update` 的输入约束

`dbmgr.critical_update` 是框架唯一的多数派 CAS 入口，身份字段（`rid`）、`_fence`、
`_version` 由框架独占。校验分三层：

1. **更新操作符白名单**：只允许 `$set` / `$unset`。`$rename` 的 key 是**源路径**、
   value 才是目标路径，逐个特判操作符一定会漏掉下一种写法——`{ ["$rename"] = { gold = "rid" } }`
   能把身份字段改名成 gold 的值。`$inc` / `$currentDate` 会让库里的值偏离内存副本，
   而 CAS 之后内存仍是普通字段的权威副本，下一次回存就把旧值写回去。
2. **字段级保护**：任何操作符的**键**都不允许是身份字段、`_fence`、`_version`
   （`_version` 只允许 `$set` 且必须恰好 +1）。
3. **`extra_query` 只允许等值条件**：拒绝表值（范围/正则），也拒绝 `$` 前缀的键
   （`$where` 的值是字符串，能绕过"不许 table"的类型检查，把 CAS 变成任意服务端表达式）。

拒绝时返回 `state, detail, code`，`code` 见 `dbmgr.REASON`——上层不能靠 detail
字符串分流，"CAS 没打中"（缓存已过期）和"更新格式非法"（缓存仍可信）的处置完全不同。

## 3. fence 认领

`dbmgr.claim_with_fence` 优先调用 `critical_find_and_modify`：

- `CONFIRMED` + `value` 是表 → 认领成功；
- `CONFIRMED` + 没有 value → 已确认未匹配，走 `resolve_unclaimed`（存在性检查、
  更高 fence 判断、或 `$setOnInsert` 创建）；
- `REJECTED` → `fence claim failed`，不重试；
- `UNKNOWN` → `fence claim unknown`，**直接返回**。不能继续走 `$setOnInsert`：
  第一次写入可能已经成功，只是 ACK 丢了，再插一次会产生重复文档。

`resolve_unclaimed` 的存在性检查也优先用 `critical_find`（majority 读），避免读到
尚未被多数派确认、可能回滚的旧值。**读失败不能降级成 `not found`**：上层会把
`not found` 当成"实体不存在"，把待投可靠消息整批移进死信；这里返回
`fence claim failed` + 具体错误。

## 4. 测试与边界

- `service/mongo_conn.test.lua`：验证 `runCommand` 的命令名、集合名、`writeConcern`
  与 `readConcern` 参数，以及三种结果分类（含 pcall 异常）。
- `lualib/skyext/mongo_conn.test.lua`：验证包装层只整形参数、透传返回值。
- `lualib/skyext/dbmgr.test.lua`：验证 `CONFIRMED/REJECTED/UNKNOWN` 在认领路径上的
  分支，UNKNOWN 不产生重复文档。
- **未覆盖**：真实副本集的多数派写、切主回滚、`writeConcernError` 的真实形态。
  这些需要 `*.integration.test.lua` + 真实 Mongo 副本集，属于 P17 的故障注入范围。

## 5. 热账本归档（P17）

`_critical_ops_v1` 会随操作次数一直涨，最终撞上 512 KiB 的关键字段预算。
归档把它搬到冷账本 `op_ledger`：

```text
扫 _critical_ops_oldest_at <= now - retention
  -> 经 owner 实体队列：critical.archive_ops
     1) 每条已结算操作 majority upsert 到 op_ledger（唯一索引 rid+op_id）
     2) **全部确认后**，一次 CAS 从热账本 $unset，并重算 _critical_ops_oldest_at
```

- **顺序是硬约束**：先删后写会留下"热里没有、冷里也没有"的窗口，那个操作记录
  永久消失。冷账本写没确认时，热条目原样保留（重复归档靠 `$setOnInsert` 幂等）。
- 只有 `COMMITTED / BUSINESS_REJECTED / ABORTED` 能被归档。`PREPARED` 或中间态
  搬走等于丢掉未决证据。
- `critical.query(entity, op_id, { ledger = coll })` 在热条目缺失时回落到冷账本；
  读失败返回 `UNKNOWN`，**不**报"没执行"——那会让调用方重放一次本该只执行一次的操作。
- 扫描字段 `_critical_ops_oldest_at` 在每次提交时取最小值维护，归档后按剩余条目
  重算（或 `$unset`）。偏索引 `critical_ops_oldest` 是启用门禁。
- 调度：`service/critical_maintenance.lua`（同时负责补建 PREPARED 的恢复任务），
  实体侧命令是 `critical_archive` / `critical_ensure_job`，集合来自实体类型配置的
  `critical_ledger` / `critical_jobs`。
