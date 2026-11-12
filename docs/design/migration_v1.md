# 计划内 Role 迁移（P15）

> **状态：编排、快照、停服阶段、启动门禁、实体侧枚举/冻结/释放、网关双向屏障、
> 目标侧接管与示例适配器均已实现；尚未做真实双节点回环验证。**
> 代码：`lualib/skyext/migration.lua`、`lualib/skyext/session_snapshot.lua`、
> `lualib/skyext/entity/entitymgr.lua`（`list_loaded` / `quiesce` / `release_for_migration`）、
> `lualib/skyext/entity/session.lua`（`attach`）、
> `lualib/skyext/gate_owner.lua`（`freeze` / `upstream_allowed`）、
> `service/entity_agent.lua`（`session_export` / `session_import` / `session_attach` /
> `migration_*`）、`service/migration_coordinator.lua`、`service/node_shutdown.lua`、
> `example/lualib/migration_adapter.lua`（示例适配器）。
> 用例：`migration.test.lua`、`session_snapshot.test.lua`、`entitymgr.test.lua`、
> `session.test.lua`、`entity_agent.test.lua`、`entity_agentmgr.test.lua`、
> `gate_owner.test.lua`、`gate_ws.test.lua`、`migration_coordinator.test.lua`、
> `migration_adapter.test.lua`。
>
> **开启 `migration.enabled = true` 需要同时配 `migration.adapter`（模块名），
> 该模块必须实现全部六个阶段，否则节点启动失败。** 仓库目前没有内置适配器，
> 见 §6「未覆盖」。这是有意为之：空适配器会让停服"成功"地什么都不做。

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

`export` 的实现是 `cluster.call(源节点, agent_service, "session_export", barrier_id)`，
`transfer` / `handoff` 的实现是 `cluster.call(目标节点, agent_service, "session_import", snapshot)`。
**不能用 `router.call`**：它按 HRW 选节点，迁移期间实体还在源节点上，路由会把它转回源端。
`session_export` / `session_import` 是 `entity_agent` 的 `FRAMEWORK` 命令。

## 2.2 实体侧命令（已实现）

| 命令 | 语义 | 失败 |
|---|---|---|
| `migration_list` | 枚举本 agent 已加载实体：`id` / `conn_id` / `owner_epoch` / `session_epoch` / `critical_unknown` / `busy` / `persistent` | 返回 `{}`（agent 未就绪） |
| `migration_quiesce` | 在实体队列里冻结上行入口（`entity.migrating`），取消空闲卸载计时器 | `not loaded` / `unloading` / `ephemeral` / `no session` / `lease lost` |
| `migration_unquiesce` | 撤销冻结，把卸载窗口还回去 | `snapshot already exported` |
| `migration_release` | 落库 + 释放锁 + 解除绑定，**不踢客户端** | `not quiesced` / `snapshot not exported` |
| `migration_stage` | 目标暂存快照（TTL 60s，上限 64 条） | `snapshot is required` / `too many staged snapshots` |
| `migration_commit` | 目标抢锁（Fence 认领）并安装快照，成功后清暂存 | `no staged snapshot` / 抢锁失败原因 |
| `session_attach` | 网关 `resume_owner` → 挂连接 → 重放未确认下行 | `gate rejected the new owner` / `replay gap` |

`entity_agentmgr.migration_list` 聚合各 agent 的结果并补上 `agent_index`，供适配器显式寻址。

三条不可协商的性质：

1. **QUIESCING 之后的上行不执行**：`entity_agent.CMD.client_msg` 在分发前检查
   `entity.migrating`，命中即静默丢弃。这里不能回错误码——没有 `errcode` 字段的协议
   会走断连兜底，把"无感迁移"变成一次掉线。客户端按超时重传同一个 `req_id`，
   重传落到新 owner 上会命中随快照迁过去的幂等缓存。
2. **下行的冻结点是 export，不是 quiesce**：`session_export` 编码前才置 `io_.migrating`。
   提前在 quiesce 冻上的话，QUIESCING 到 TRANSFER 之间业务推送（定时器、邮件）会被
   静默丢弃，既没进 out_buf 也没送到客户端。
3. **屏障是两个方向的**：`gate_owner.upstream_allowed` 让 `freeze` 同时停上行与下行。
   只停下行的话，屏障到 `resume` 之间的包会落到一个已经交出所有权的实体上。
4. **释放不踢人**：`release_for_migration` 走 `_release_lock` 的 `detach` 分支，
   只 `session.unbind`，不 `unbind_kick`；`release_detach` 会带到卸载重试上，
   失败重试也不会变成踢人。
5. **接管先问网关**：`session.attach` 先 `resume_owner`（严格更大的 `owner_epoch`），
   网关认账之后才改本地 `owner_epoch` 并挂连接。反过来的话网关拒绝时本地已推进，
   之后所有下行都被当迟到包丢掉，且没有回滚路径。
6. **目标必须显式寻址**：`transfer` / `handoff` / `activate` 都用
   `cluster.call(target_node, agent_service, ...)`。`router.call` 按 HRW 选节点，
   迁移期间实体还在源节点上，会被转回源端。
7. **释放后失败必须踢客户端**：源端已经交还锁，客户端不能再挂在旧 owner 上；
   `fallback` 对 `_released` 的实体调网关 `kick`，让它立刻重连而不是重试到空闲超时。

## 2.3 示例适配器（`example/lualib/migration_adapter.lua`）

| 阶段 | 实际动作 |
|---|---|
| `list_entities` | 本地 `entity_agentmgr.migration_list`，只留"有连接 + 持久化 + 未在迁移"的实体 |
| `quiesce` | 源端 `migration_quiesce` |
| `freeze` | 按 `conn_id` 解析网关，`freeze_owner(conn_id, owner_epoch, barrier_id)` |
| `export` | 源端 `session_export(barrier_id, owner_epoch + 1)` |
| `transfer` | 源端 `migration_release` → 选目标 → 目标 `migration_stage` |
| `handoff` | 目标 `migration_commit`（抢锁 + 装快照） |
| `activate` | 目标 `session_attach(conn_id)`（`resume_owner` + 挂连接 + 重放） |
| `fallback` | 已冻结未释放 → 源端 `migration_unquiesce`；已释放 → 只能重连 |

目标选择：先看 HRW（`types.calc_node`）；指回本节点（停服期间成员视图还没更新）时
从 `cluster_discovery.state("entity:role").nodes` 里另选一个存活节点；没有别的节点就
`FALLBACK`——单节点部署本来就没有"无感迁移"可言。

## 2.4 启动门禁

`migration_coordinator` 由 launcher 以 `start(conf)` 启动，门禁顺序是：

1. `conf.enabled == true`；
2. 取适配器：`CMD.set_adapter` 注入的优先，否则 `require(conf.adapter)`；
3. 六个必需阶段（`list_entities` / `quiesce` / `freeze` / `export` / `transfer` /
   `handoff` / `activate`）必须都是函数，缺一个就拒绝；
4. 可选阶段 `probe`（BUSY 限时等待）与 `fallback`（降级通知）缺失只影响行为细节；
5. `adapter.init(conf)` 可选，用于拿实体类型等配置；
6. 注册 `migrate` 停服钩子——注册失败同样拒绝启动。

任何一步失败都让节点启动失败，`CMD.run` 在未启动时也明确返回失败：
"配了迁移却静默退化成全员重登"是运维最不该遇到的那种成功。

节点侧顺序：`launcher_node` → `launcher_entities`（等每个类型 READY）→
`launch_optional_services`（含本服务）→ `launcher_gate`。

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

### 4.1 取消令牌

截止时间到达后，`node_shutdown` 会给 `migrate` 钩子发 `cancel`；协调器置位，
`migration.migrate_entity` 在**每个阶段边界**检查并返回 `FALLBACK`。

只停止等待是不够的：迁移协程会和卸载并行跑，源实体被卸掉之后迁移还在写。
`migrate` 阶段的钩子必须实现 `cancel` 命令。

### 4.2 并发

实体之间互不依赖（各自的实体锁、各自的 `conn_id` 屏障），`migration.run` 支持
`opts.concurrency` + `deps.parallel(tasks)`：协调器用 `skynet.fork` 起 N 条流水线，
每条从共享下标取下一个实体。默认 4（`migration.concurrency`）。

串行时每个实体约 8 次跨节点 RPC，停服预算 `timeout / 2` 会被在线人数吃满；
并发度不是越大越好——它直接放大 Mongo 与网关的瞬时压力，压测之后再定值。

## 5. 快照 v2

`SessionSnapshotV1` 的载荷格式升到 v2，相比 v1 只加两处：

- `flags`：保真 `unresumable`。源已经丢弃重放缓冲时，目标不能假装可续接。
- 每条 L1 条目带 `fingerprint_version + 32 字节摘要`。缺摘要，迁移后重传的在途请求
  无法证明"参数相同"，`matches_digest` 会判 `INVALID_HASH`，非幂等操作就被重新执行
  一遍。恢复时同时重建 `resp_order` 与 `resp_bytes`，否则这些条目永不淘汰、
  count/bytes 上限对它们失效。

版本不匹配一律 fail-closed：快照只活一次迁移，猜一个不认识的格式比让客户端重登危险。

## 6. 未覆盖

- **真实双节点回环没有自动化用例**：两个 skynet 节点 + 一个真实客户端，GM shutdown 源节点，
  验证连接不断、`session_epoch` 不变、`owner_epoch` 严格前进、下行不重不漏、
  在途上行不重复执行。这是"能不能上生产"的判据，见 P17 的故障注入清单。
- **并发度没有压测依据**：默认 4 是保守取值，需要按"停服预算 / 单实体耗时 / 在线人数"
  实测调整。
- **目标节点选择策略**：示例按 HRW + 服务发现第一个存活节点，没有权重/负载/亲和性。
- **`handoff` 的 Fence 认领用的是 etcd 实体锁**（`entitymgr:_ensure_loaded` 抢锁，
  `handle.fence` 严格前进）。没有额外的多数派 `findAndModify`；如果以后把锁换成
  Mongo Fence，认领点仍在这里，不需要动编排。
- **`migration_stage` 暂存不持久化**：源节点崩溃后目标重启会丢掉暂存，退化为一次重连。

已具备：实体枚举 / 冻结 / 撤销冻结 / 释放（不踢人）、快照导出与安装、目标侧暂存与接管、
网关双向屏障与重指向、启动门禁、取消令牌、并发流水、示例适配器。
