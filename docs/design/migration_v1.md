# 计划内 Role 迁移（P15）

> **状态：编排状态机、快照导出/安装命令与停服阶段已实现。**
> 代码：`lualib/skyext/migration.lua`、`lualib/skyext/session_snapshot.lua`、
> `service/entity_agent.lua`（`session_export` / `session_import`）、
> `service/node_shutdown.lua`（`migrate` 阶段）。
> 用例：`migration.test.lua`、`session_snapshot.test.lua`、`entity_agent.test.lua`。

## 1. 六阶段

| 阶段 | 动作 | 屏障 |
|---|---|---|
| DRAINING | 节点不再接受新加载/新绑定 | 由 `stop_accepting` 钩子完成 |
| QUIESCING | Role 停止所有会改实体或发下行的入口，等实体队列排空 | `with_entity` 返回即队列已空 |
| GATE_BARRIER | 确认网关已切断旧 owner 的新下行 | `gate_owner.freeze(conn_id, owner_epoch, barrier_id)` |
| TRANSFER | 导出 `SessionSnapshotV1` 并送达目标 | 快照含 `out_buf` 原字节，不做重包装 |
| OWNER_HANDOFF | 目标经多数派 Fence 认领后安装 | `session_epoch` 保持不变，`owner_epoch` 推进 |
| REPLAYING | 新 owner 用新 `owner_epoch` 重放原样包 | 客户端按 `(session_epoch, seq)` 去重 |

`migrate_entity` 逐阶段调用 deps，任一步失败即 `FALLBACK`：**不能**宣称"无感迁移成功"
再把客户端留在没有下行入口的会话上。

## 2. deps 契约

```lua
migration.run({
    list_entities = function() -> { { id, conn_id, owner_epoch, critical_unknown } } end,
    quiesce  = function(entity, barrier_id) -> true | nil, err end,
    freeze   = function(entity, barrier_id) -> true | nil, err end,
    export   = function(entity, barrier_id) -> snapshot | nil, err end,
    transfer = function(entity, snapshot)   -> true | nil, err end,
    handoff  = function(entity, barrier_id) -> true | nil, err end,
    activate = function(entity, barrier_id) -> true | nil, err end,
    fallback = function(entity, status) end,
}, { barrier_id = ... })
```

`export` 的实现是 `router.call(role, id, "session_export", barrier_id)`，
`handoff` 的实现是 `router.call(target, id, "session_import", snapshot)`。
两者都是框架内部命令，注册在 `entity_agent` 的 `FRAMEWORK` 表里。

- **缺依赖 fail-closed**：六个步骤缺任何一个都按 `FALLBACK` 处理。把"没配 export"
  当成功，会得到一个宣称迁移完成、快照从未送达的会话。
- 步骤返回值只认"非 nil 非 false"：`session_import` 成功返回的是 payload 表，
  只认字面 `true` 会让每次 handoff 都失败。
- `session_export` 会**冻结源**（`io_.migrating = true`）：导出之后 `record_and_send`
  拒绝追加 `out_buf`，否则目标拿到的是一份过期的 `sent/out_buf`。
- `owner_epoch` 必须严格前进：`session_export` 默认给 `当前 + 1`，`session_import`
  拒绝等于或小于当前值——网关用严格大于来过滤旧 owner 的迟到下行。

## 3. 失败分流

| 状态 | 处理 |
|---|---|
| `READY` | 正常迁移 |
| `BUSY` | `wait_busy` 限次等待；仍忙则按 `FALLBACK`（`stats.busy` 计数） |
| `CRITICAL_UNKNOWN` | **禁止无感移交**，转 B2 安全恢复；单个玩家不能永久阻塞节点退出 |
| `FALLBACK` | 明确提示断线续接或重新登录 |

`fallback` 回调对每个非 `READY` 的实体调用一次，游戏层在这里决定"提示续接"还是
"直接踢下线"。迁移失败不会阻止实体卸载：玩家重登即可，进程不能停在半死不活的状态。

## 4. 停服顺序

```text
stop_accepting -> migrate -> unload_entities -> release -> 停注册 -> 撤租约 -> 退出
```

`migrate` 是新增的钩子阶段，不注册就跳过（退化成"卸载 + 重登"）。钩子失败只记警告，
不阻断停服。该阶段带截止时间（停服预算的一半）：迁移卡在集群 RPC 上时不能让进程
永久停在卸载之前——那时 `g_running` 已置位，再发一次 shutdown 只会得到
"already shutting down"。

## 5. 快照 v2

`SessionSnapshotV1` 的载荷格式升到 v2，相比 v1 只加两处：

- `flags`：保真 `unresumable`。源已经丢弃重放缓冲时，目标不能假装可续接。
- 每条 L1 条目带 `fingerprint_version + 32 字节摘要`。缺摘要，迁移后重传的在途请求
  无法证明"参数相同"，`matches_digest` 会判 `INVALID_HASH`，非幂等操作就被重新执行
  一遍。恢复时同时重建 `resp_order` 与 `resp_bytes`，否则这些条目永不淘汰、
  count/bytes 上限对它们失效。

版本不匹配一律 fail-closed：快照只活一次迁移，猜一个不认识的格式比让客户端重登危险。

## 6. 未覆盖

- 网关侧的 `bind_owner(conn_id, new_owner_epoch, ...)` 重指向需要由 `activate` 的
  实现完成；框架提供了 `gate_owner` 的 freeze/resume 原语，但没有内置一个完整的
  "网关 + 实体 + 集群" 迁移服务。
- 目标节点的 Fence 认领（多数派 `findAndModify` 抢占 `_fence`）由 `handoff` 的实现
  负责；本模块只保证顺序与失败语义。
- 真实跨节点回环（两个 skynet 节点 + 一个客户端）还没有自动化用例，见 P17 的
  故障注入清单。
