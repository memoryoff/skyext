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
| `critical_probe()` | `hello` 命令 | `true` / `nil, err` |

三态的定义：

- **CONFIRMED**：mongod 返回 `ok=1`，没有 `writeErrors` / `writeConcernError` / `errmsg`。
  对 update 而言 `n` 是匹配数；`n=0` 是**已确认未匹配**，不是失败。
- **REJECTED**：`writeErrors`，或命令级 `ok~=1`（参数错、权限不足等）。写入确定没有
  生效，调用方可以按业务失败处理。
- **UNKNOWN**：`writeConcernError`、网络异常/超时、`ok=1` 但仍带 `errmsg`。**写入可能
  已经生效**，调用方必须按未决处理：不能重试成"没写"，也不能当成"已提交"。

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
