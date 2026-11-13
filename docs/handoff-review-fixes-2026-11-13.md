# skyext 评审修复 · 交接文档（2026-11-13）

> **文档性质**：本文件从“外部实施审查（memoryoff/skyext，2026-11-12）所点 7 个问题”的交接规格演化而来。§1~§9 保留历史规格与当时的执行状态；**当前状态、第二轮落地与对抗审查修复以 §10 为准**。
> **基准**：原稿 HEAD = `ea59e5c`；当前 HEAD = `7f9d007`，其上还有 §10.2 记录的本轮改动（未提交）。

---

## 1. 环境与硬约束（必读，违反会被打回）

- **路径**：`/Users/hanxiaolong/Documents/skyext`。Lua 5.5 + skynet。
- **测试命令**：`./bin/skyext test <文件1> <文件2> ...`（可一次传多个文件）。单跑一个用例用 `t.it`。
- **门禁**（见 §7，必须全过才能算完成）：`./bin/skyext test`、`luacheck .`、`stylua --check .`（二进制在 `/usr/local/bin/stylua`，仓库根有 `stylua.toml`）、`lua scripts/ci/check_paths.lua .`、`make -C example lint`、sdk/ts `npx tsc --noEmit`。
- **代码风格**：4 空格缩进；`local M = {} ... return M`；日志统一 `skyext.log`；测试文件与源码相邻、命名 `*.test.lua`。
- **不要 `git commit` / `git add`**：除非被明确授权。当前改动都在工作区，提交由人决定。
- **不要改 `docs/` 下的设计文档**（如 `outbox_saga_v1.md`、`session_snapshot_v1.md`），但 `docs/review-2026-11-12-defect-register.md` 的**状态更新**是本次明确允许的（见 §6）。
- **验收口径（来自台账头部）**：只有"新增/改写自动化测试通过 + 全量门禁通过"才能把状态改成"已修"。需要真实副本集/双节点/真实客户端的项，只能标"待环境"，不得写"已验证"。

---

## 2. 评审 7 项的核实结论（避免接手者重新辩论）

主代理用真实 `config.init()` 实跑 + 逐文件回源码核实。结论：**只有 P0 是真正的新发现且发布阻塞；其余基本能在 `defect-register.md` 找到编号，并有几处机制描述与代码不符。**

| 评审项 | 是否属实 | 与代码不符处 / 关键出入 | 对应台账 | 本次状态 |
| --- | --- | --- | --- | --- |
| P0 配置执行环境回归 | **属实，唯一新 P0，发布阻塞** | 实跑复现；文件里没有 `next`，只有 `type`/`pairs` | 无（重新引入，见 §6 新增） | **已修** |
| 普通回存 UNKNOWN | 属实 | "永久卡死"夸大——有 `load`/`recover` 脱困出口；`_fence` 仅 handle 存在时才进 query | B-03 残留 | **已修（dbmgr）** |
| 迁移 Gateway 屏障 | 属实 | barrier token + 目标端校验**已落地**（R-01），仅 fallback 解屏障缺失 | D-12 | **已修** |
| Critical Maintenance 配置 | 风险真 | "两边用不同集合"是误读——两处读同一键 `entity_types.<type>.critical_ledger/jobs`；真问题是缺配置时行为不对称 | D-16 + 静默回退 | **已修** |
| Outbox 三点 | 都成立 | A：3600s 是容量腾挪下限，非超时即删；B：DLQ 已存在（reliable_msg status=2），缺的是把"永久无效"送进去 | D-23 + A-09 | **已修** |
| 支付状态机三点 | 都成立 | 3 处误读：action 已在 `service_op_id` 编码；scan 注释被读反；`transition`/`mark_reconciled` 已查 CAS | D-19 / D-20 / D-10 | **已修（c00bb4a / c782924 / 3e075bc）** |
| 生产验收缺口 | 判断对 | 完全是已登记门禁（V-02~V-05 等），非新发现 | V-02~V-05 | 文档化（见 §7 门禁） |

> 注：评审还点了"停服 RPC 无 deadline"——那是 `R-01` 已记录的**设计取舍**（deadline 必须与迁移代际校验一起设计）。**本轮已按这个前提把两者一并落地**：`bounded_call` 给每个阶段 RPC 加了 deadline，登记改为 `(entity_id, barrier_id)` 键控并带轮次，`abort` 有界并发。详见 §8，不再按"未做"处理。

---

## 3. 修复顺序与执行状态

| 批次 | 内容 | 改动文件 | 状态 | 验证 |
| --- | --- | --- | --- | --- |
| 1 | P0 配置执行环境 + `config.init()` 集成测试 | `lualib/skyext/config.lua`, `config.test.lua` | **已完成** | 36 passing |
| 2 | 迁移 fallback 网关屏障（D-12） | `example/lualib/migration_adapter.lua`, `.test.lua` | **已完成** | 34 passing |
| 3 | 支付状态机（D-19/D-20/D-10）+ D-11 | `charge_order.lua`, `charge_reconcile.lua`, `pay_webhook.lua` + 测试 | **已完成（c00bb4a / c782924 / 3e075bc）** | 支付三组测试全绿；§5 保留为历史规格 |
| 4 | Critical Maintenance 配置闭合（D-16 + 去静默回退） | `service/critical_maintenance.lua`, `example/lualib/launcher.lua`, `launcher.test.lua` | **已完成** | 18 passing |
| 5 | 普通回存 UNKNOWN 读后对齐 | `lualib/skyext/dbmgr.lua`, `dbmgr.test.lua` | **已完成** | 82 passing |
| 6 | Outbox 失败证据保留 + 永久无效进死信（D-23/A-09） | `lualib/skyext/outbox.lua`, `critical_fields.lua`, `critical.lua`, `example/lualib/entity_handler/role.lua` + 测试 | **已完成** | 68 passing（跨 3 文件） |
| 7 | 缺陷台账更新 + 部署约束文档 | `docs/review-2026-11-12-defect-register.md`, `docs/design/outbox_saga_v1.md` | **部分**（outbox_saga 已加副本集约束；台账未更新） | — |
| 8 | 全量门禁 | — | **待跑** | — |

> 生产故障验收（V-02~V-05：三节点切主真实 Critical Commit、etcd 分区、双节点迁移、停服强杀 RPC、支付故障回放、真实压测）需要真实双节点 + 三节点 Mongo + 真实客户端，**本地补不了**，只更新门禁说明，不写假脚本冒充（§7）。

---

## 4. 已完成批次（接手者勿重做，仅作对照）

### 批次 1 · P0 配置执行环境（`lualib/skyext/config.lua`）
- **根因**：`config.lua` 的加载器用隔离环境（`setmetatable(result, {__index = {include = include}})`），而 `example/etc/nodes/common.app.lua` 的 `merge_table`/`with_defaults` 调用了全局 `type`/`pairs`。引入点是 `66e6afa` 的 A-06「递归合并」修复；旧测试（`common.app.test.lua` 用 `setmetatable({}, {__index=_G})` + `loadfile`、`config.test.lua` 只加载临时小文件）**绕开了生产隔离环境**，形成假绿。
- **修法**：给配置执行环境注入一个受限基础函数白名单（`type`/`pairs`/`ipairs`/`next`/`tostring`/`tonumber`/`assert`/`error`/`select`/`pcall`/`string`/`table`/`math`/`os` 等安全子集），而非只补 `type`；同时新增一条真正走 `config.init()` 加载真实 `example/etc/nodes/*.app.lua` 的集成测试，覆盖 `include` 链与默认值合并。
- **验证**：`./bin/lua` 实跑 `config.init()` 已从 `attempt to call a nil value (global 'type')` 变为成功；`./bin/skyext test example/etc/nodes/common.app.test.lua lualib/skyext/config.test.lua` → 36 passing。
- **提醒**：别退回"假绿"测试——根因是测试与生产配置环境不一致。

### 批次 2 · 迁移 fallback 网关屏障（D-12，`example/lualib/migration_adapter.lua`）
- **修法**：删 `M.fallback` 首行无条件 `g_inflight[id]=nil`；新增 `barrier_pending = entity._barrier~=nil and g_inflight[id]~=nil`，把"屏障建立过且本轮没 activate 成功"纳入必踢（`need_kick = released or unquiesce_refused or barrier_pending`）；kick 接 pcall 三返回值，失败/抛错都算没踢成；只在 `not need_kick or kicked` 时清 `g_inflight`，失败保留供 `M.abort()` 重试。未用 `resume_owner`（会造成旧 owner 本节点状态不一致）。保留 C-07/A-11 既有语义。
- **测试**：新增 4 例（回归：quiesce+freeze 成功/export 失败/unquiesce 成功→必踢；无 `_barrier`→不踢；kick 失败/抛错时 `g_inflight` 保留、abort 再踢）；修正原"fallback 完全不踢"断言。`./bin/skyext test example/lualib/migration_adapter.test.lua` → 34 passing。

### 批次 4 · Critical Maintenance 配置闭合（D-16 + 去静默回退）
- `service/critical_maintenance.lua`（`CMD.start`）：缺/非法 `critical_ledger`、`critical_jobs`（非表或缺 `db`/`coll`）时 **fail-fast**，`return false, msg`，绝不再静默回退 `op_ledger`/`critical_reconcile_jobs` 默认集合名。entity_agent 的 fail-closed 语义（那侧是对的）不动。
- `example/lualib/launcher.lua`：`self_check` 增加跨服务依赖（D-16）——`pay_callback`/`outbox_worker` 启用而 `critical_maintenance` 未启用 → 报 problem；维护服务启用但实体类型缺 `critical_ledger/jobs` → 报 problem。`log_self_check` 改为 `assert_self_check`：有 problem 直接 `error` **阻断启动**，但保证示例默认四个服务全关时自检零 problem、节点照常起。
- **测试**：`launcher.test.lua` 扩到 18 例，覆盖默认零 problem、缺 ledger/jobs 报 problem、pay 启用而维护未启用报 problem、启用但缺字段启动被阻断。`./bin/skyext test example/lualib/launcher.test.lua` → 18 passing。
- **台账映射**：对应 **D-16**（启动依赖检查）。"维护服务静默回退默认集合"本身无独立 D 编号，建议登记到 D-16 或在 §12 新增一条（见 §6）。

### 批次 5 · 普通回存 UNKNOWN 读后对齐（`lualib/skyext/dbmgr.lua`）
- **修法**：`save_doc` 在 `safe_update` 未确认（异常/返回非 `{n=1,nModified=1}`）时，复用已有的 `read_claim_doc`（多数派读优先）读回库里真实 `_version`：若已推进到 `old_version+1` 且与本快照一致 → 视为已落库，`orm.ack_mongo` 对齐内存版本、清 dirty；若被其他版本推进（`db_version > old_version` 或 fence 不符）→ 标记 `entry.state = DISCARDED`，交给 `load`/`unload` 重读，禁止无限用旧版本 CAS（那会永远 `n=0`）。`sweep_save` 本就跳过非 NORMAL 状态，故不在保存路径摘轮。
- **测试**：`dbmgr.test.lua` 新增"写入生效但响应丢失"用例——DB 已写、驱动返回失败 → 读回对齐、不丢数据、不无限重试；并断言缓存作废后 `load` 重读拿到库里真实版本。`./bin/skyext test lualib/skyext/dbmgr.test.lua` → 82 passing。
- **台账映射**：属 B-03 残留的健壮性增强，建议登记到 B-03 或 §12 新增条目（见 §6）。

### 批次 6 · Outbox 失败证据保留 + 永久无效进死信（D-23 / A-09）
- `lualib/skyext/critical_fields.lua`：`OUTBOX_FAILED_MIN_RETENTION` 从 `3600`（1h）改为 `604800`（7d），与 DELIVERED 一致——避免陈年 FAILED 在容量压力下被过早腾挪，保住"资产已扣但业务未生效"的唯一记录。
- `lualib/skyext/outbox.lua`：① 容量腾挪删除分支补 `log.error`（记录 `event_id` + `failed_reason`），不再无声抹掉；② `RECEIVER_MT:handle` 对"信封目标不匹配 / 参数摘要不一致 / hash_fn 缺失"由原来 `return nil, err`（被 `role.lua` 当永久无效 ACK）改为 `error(...)`，与同文件已有的 `PRECHECK_REJECTED` 处理口径统一——抛错进入投递失败/死信路径，而非静默 ACK。
- `example/lualib/entity_handler/role.lua`：`__apply_outbox_event` 在 handler 返回 nil（即抛错）时不再 ACK，交给 `_deliver_one` 的失败/死信路径。
- **测试**：`outbox.test.lua` / `role.test.lua` 相应调整断言（"不再 ACK 永久无效信封"改判为进入重试/死信；receiver 测试从"返回 nil"改为"抛错"）。`./bin/skyext test lualib/skyext/outbox.test.lua lualib/skyext/critical.test.lua example/lualib/entity_handler/role.test.lua` → 68 passing。
- **台账映射**：D-23 的"直接 ACK"部分已修；**子问题**"outbox.event 只校验 param_hash 长度不校验 hex"未触及，建议一并确认是否修（见 §5 备注）。A-09 描述需从"1h"更新为"7d"。

---

## 5. 历史规格 · 支付状态机（D-19 / D-20 / D-10）+ D-11（已落地，勿按本节重新实现）

> 这三个文件已在后续提交 `c00bb4a` / `c782924` / `3e075bc` 落地；本节保留为历史规格，行号基于 `ea59e5c`，只用于追溯，不代表当前实现。

### D-20 · 重复回调冲突校验漏 `action`
- **文件**：`lualib/skyext/charge_order.lua`
- **现状**：订单唯一索引是 `(provider, order_id)`（`:378-382` `provider_order_id` unique）。`record`（`:137`）的 upsert query 仅 `{provider, order_id}`（`:177`），`action` 只在 `$setOnInsert` 写入（`:185`）。冲突比较在 `find_one` 命中 existing（`:201`）后进行（约 `:203-209`，比较 `amount`/`currency`/`normalize_rid(rid)`），**不含 action**。
- **Bug**：同一 `(provider, order_id)` 的第二次 `record`（不同 action，如 compensate）被当成重复订单——`find_one` 命中、冲突比较通过、直接返回 existing → 沉默 ACK，漏补偿。
- **修复约束**（重要）：
  - 不能破坏**同 action 重复回调的幂等**（服务方重推不应重复发奖；幂等由 `service_op_id`（`:76-96`，已编码 `action`）保证）。
  - 不能破坏**补偿链路**：退款/拒付走 `compensation_op_id`（`:399` 起）独立 op id、不经 `record`——别把它改坏。
  - 唯一索引目前是 `(provider, order_id)`，**不同 action 同 order_id 无法通过 insert 新建行**。因此真正的修法二选一（让接手者结合数据兼容定）：(a) 把唯一索引扩成 `(provider, order_id, action)`（需评估现有数据/查询影响）；(b) 在冲突路径检测 action 不一致时**显式拒绝/告警/分流**，而非静默返回 existing。
- **测试**：同 provider/order_id 不同 action 不被当重复吞掉；相同 action 重复回调仍幂等。

### D-19 · `VERIFIED_RECEIVED + COMMITTED` 永远无法结案
- **文件**：`lualib/skyext/charge_reconcile.lua` + `lualib/skyext/charge_order.lua`
- **现状**：COMMITTED 分支（`:94-126`）仅当 `order.status == GRANTING`（`:101`）时先 `transition → GRANTED`（`:106-118`），其余状态 `:120` 直接 `mark_reconciled`。而 `charge_order.lua` 的 `mark_reconciled` CAS 只认 `status = GRANTED`（约 `:451-482`，实现前确认）。订单停在 `VERIFIED_RECEIVED` 时直接 `mark_reconciled` → CAS 落空 → 回 PENDING，`run_once`（`:187`）又扫 `VERIFIED_RECEIVED`（`:216`）→ 永久卡。
- **修复**：`VERIFIED_RECEIVED` 且证明 `COMMITTED` 时，安全、幂等地 `transition` 到 `GRANTED` 再 `RECONCILED`。复用 `transition`（`:250`，按 `status=from` 做 CAS）或 `grant` 能力；**所有状态推进必须检查 CAS 结果**，失败不能伪称成功；不要对已经 COMMITTED 的发奖重复执行一次（`service_op_id` 幂等）。
- **测试**：`VERIFIED_RECEIVED + COMMITTED` 能结案到 `RECONCILED`，且不会重复发奖；CAS 落空时安全返回失败（不伪称成功）。

### D-10 · 对账扫描被毒单饿死
- **文件**：`lualib/skyext/charge_reconcile.lua`
- **现状**：`scan_orders`（`:37-66`）只有 `projection` + `limit`，无 sort/游标；query（`:45-50`）`{status, updated_at $lte now-grace, reconcile_blocked_at $exists false}`。索引 `{status, updated_at}`（`:242`）。注释 `:63-64` 原意"不排序避免卡单永远占队头"是**误判**——无 sort 时走索引即 `updated_at` 升序，某分支不写 `updated_at` 的毒单永远最老占位。
- **修复**：用 `(updated_at, provider, order_id)` 稳定 keyset / 轮转游标（或等效机制），保证长期卡住单据不永久占每页候选；同时不漏更新过的单。
- **注意**：`charge_reconcile.test.lua` 的 fake `find_many`（约 `:105-107`）会自行排序，需同步调整 fake 以真实反映新查询语义（断言 `query`/`opts` 含 sort 或 keyset 字段）。
- **测试**：`scan_orders` 有稳定排序/游标，毒单不会永久占位（用 fake 记录 query/opts 断言）。

### D-11 · `pay_webhook` 在 `CAPACITY_EXCEEDED` 时回 200 + ACK（建议一并处理）
- **文件**：`lualib/skyext/pay_webhook.lua`（约 `:232-246`）
- **现状**：容量超限时 webhook 回 200 + ACK，渠道不再重推，订单留 `GRANTING`；对账重投仍是 `CAPACITY_EXCEEDED`，永远 RETRY、不 block、不告警；唯一出路 `critical_maintenance` 在示例配置默认关闭（D-16 已修启动门禁，但运行期仍需正确处理）。
- **修复**：不要静默 ACK，应让渠道重试（返回非 2xx 或明确 retry 语义），订单不卡在 `GRANTING` 无解；与 D-16（维护服务开启）联动验证。
- **测试**：`pay_webhook.test.lua` 补 `CAPACITY_EXCEEDED` 不静默 ACK 的用例。

### 支付批次验证
`./bin/skyext test lualib/skyext/charge_order.test.lua lualib/skyext/charge_reconcile.test.lua lualib/skyext/pay_webhook.test.lua`
必须全绿。

---

## 6. 待办 2 · 缺陷台账更新（`docs/review-2026-11-12-defect-register.md`）

> 这是唯一允许改的 `docs/` 文件。不要重写，只在对应条目改状态/补描述。

1. **新增一个 P0 条目**（§12 或单独"回归"小节）：说明 `66e6afa`（A-06 递归合并）引入的配置执行环境回归，本会话已修（`config.lua` 注入白名单 + `config.test.lua` 真实 `config.init()` 集成测试）。**现状 §1 写"阻塞生产的 P0 = 0"已不准确**，需加注"本次发现并修复一个 P0 回归"。
2. **D-12 → 已修 + 已验证**：`migration_adapter.lua` fallback 解网关屏障；补 `migration_adapter.test.lua` 4 例。
3. **D-16 → 已修 + 已验证**：`launcher.lua` 自检阻断启动 + 跨服务依赖；补 `launcher.test.lua` 用例。把"维护服务静默回退默认集合"作为 D-16 的子项或新增一条（无独立编号）。
4. **D-23 → 已修（部分）**："永久无效直接 ACK"已改为抛错进失败/死信路径（`outbox.lua` RECEIVER_MT + `role.lua`）；**子问题**"outbox.event 只校验 param_hash 长度不校验 hex"仍待处理，标"部分修"。
5. **A-09 → 更新描述**：保留期下限从 `1h` 改为 `7d`（`critical_fields.lua`），并在容量腾挪删除分支补 `log.error` 证据记录。
6. **普通回存 UNKNOWN 读后对齐**（批次 5）：登记到 B-03 残留或 §12 新增条目，说明 `dbmgr.save_doc` 增加多数派读回对齐。
7. 若 D-10/D-19/D-20/D-11 在本会话之后被接手者修掉，相应把状态从"待修"改为"已修 + 已验证"并补验证用例引用。

---

## 7. 全量门禁（收口命令，当前结果见 §10.4）

接手者在完成 §5 代码 + §6 台账更新后，跑以下命令，必须全绿：

```
cd /Users/hanxiaolong/Documents/skyext
./bin/skyext test                      # 全量单测
luacheck .                             # 静态检查
stylua --check .                       # 格式化（/usr/local/bin/stylua，仓库有 stylua.toml）
lua scripts/ci/check_paths.lua .       # 路径/裸 require 检查
make -C example lint                   # 示例 lint
# sdk/ts: npx tsc --noEmit            # 仅当改了 TS SDK 才需要
```

当前（§10.4 已实测）：`./bin/skyext test` 129 files 全过；`luacheck .` 0 warnings；`stylua --check .` 通过；`git diff --check` 干净。

---

## 8. 给接手 Agent 的提醒（踩坑已验证）

- **不要推翻 R-01 的已记录取舍**：停服 RPC deadline 不做（必须与迁移代际校验一起设计），当前靠目标端拒绝迟到 barrier 堵住竞态。评审把它当"新发现"是误读。
- **non-goals 第三条**：不要为 Outbox 新建第二套 DLQ 集合——复用现有 `reliable_msg` 死信（status=2 / dead_time + GM `dlq_list/replay/discard`）。批次 6 的修法正是"复用现有设施"。
- **支付补偿链路本就没接线**：`compensation_op_id`（charge_order.lua `:399` 起）是独立 op id、不经 `record`，别误当成 bug 去"修"。D-20 的修复重点在 `record` 的冲突路径，不是补偿路径。
- **配置执行环境修复要点**：注入受限白名单，别退回假绿测试（见批次 1）。
- **部署约束（已写入 `docs/design/outbox_saga_v1.md`）**：Reliable Message 用 entity 库、角色 Outbox 用 role 库；生产若把两者指向不同 MongoDB 副本集，队列 `safe_insert` 与源端 ENQUEUED 多数派提交无跨集群原子性。建议在部署文档强化此约束优先于改代码（示例同指 `127.0.0.1:27017`）。

---

## 9. 上一轮工作区改动清单（历史，已提交，勿按此核对现状）

```
M docs/design/outbox_saga_v1.md
M example/lualib/entity_handler/role.lua
M example/lualib/entity_handler/role.test.lua
M example/lualib/launcher.lua
M example/lualib/launcher.test.lua
M example/lualib/migration_adapter.lua
M example/lualib/migration_adapter.test.lua
M lualib/skyext/config.lua
M lualib/skyext/config.test.lua
M lualib/skyext/critical.lua
M lualib/skyext/critical_fields.lua
M lualib/skyext/dbmgr.lua
M lualib/skyext/dbmgr.test.lua
M lualib/skyext/outbox.lua
M lualib/skyext/outbox.test.lua
M service/critical_maintenance.lua
```
（共 16 文件，+682 / -80；均通过 stylua 与对应测试。）

## 10. 第二轮落地与对抗审查修复（2026-11-13 晚）

> 说明：原稿有两个 §8，本节把追加记录改为 §10；§8 保留为“给接手 Agent 的提醒”。
> 独立对抗审查报告与证据链见 `docs/review-2026-11-13-adversarial.md`，本节只记录修复与复验结果。

### 10.1 第二轮外部评审 P1/P2 落地（提交 `7f9d007`）

| 项 | 结论 | 落点 |
| --- | --- | --- |
| P1-01 重复订单普通读 | 属实。E11000 与其它 REJECTED 混在一起，且回读走 `find_one`（主节点可见≠多数派确认） | `charge_order.record` 只对真正 E11000 走回读，回读改 `critical_find`；读不到/读失败/无通道一律 `UNKNOWN`；`check_write_channel` 同时要求多数派写与多数派读通道 |
| P1-02 迁移 RPC 无 deadline | 属实 | `migration_adapter.bounded_call`：fork + timeout，超时返回 `TIMEOUT`（按“结果未知”处理）；阶段调用与 abort 两腿均改用 |
| P1-03 begin_round 丢待清理 | 属实 | `begin_round` 先重试清理，清不掉的保留登记并返回 pending，绝不 `g_inflight = {}` |
| P1-04 迟到回包越代际 | 属实 | 登记键改 `(entity_id, barrier_id)` + `round`；回包比对轮次，旧轮次只允许清自己那条 |
| P2-01 类型缓存串味 | 属实 | `config` 拆分 `raw/bool/number/table` 四张缓存，双向交叉测试 |
| P2-02 启动门禁只是接口检查 | 属实 | `pay_callback.start` 调 `critical_probe()`，探针未确认/抛错直接拒绝启动 |
| P2-03 人工阻断可被回调绕过 | 属实 | `pay_webhook` 对 `reconcile_blocked_at` 订单只 ACK、不回发奖；grant/webhook 均不再自动清阻断 |
| P2-04 索引执行计划 | 已用真实 explain 核验 | 见 10.3 |

### 10.2 对抗审查发现的问题与修复（本轮改动，未提交）

审查结论是 `changes_required`：P0 = 0，但存在 1 条本轮引入的 P1 行为回归，以及 4 条 P2。

| 项 | 问题 | 修复 |
| --- | --- | --- |
| P1（回归） | `mongo_conn.classify_write` 对非 CONFIRMED 只透传 `first.errmsg`（字符串），而 `is_duplicate_key` 首行要求 `detail` 是表，E11000 分支在生产不可达；重复回调全部 500，幂等被打回原形 | `is_duplicate_key` 只按字符串判定 `E11000`；测试桩全部改成生产真实形状（`"REJECTED", "E11000 duplicate key ..."`）；补“多数派读返回 nil, err”和“读抛错”两个 `UNKNOWN` 用例 |
| P2-1 | 阻断单无生产解封入口，也无清单端点；阻断后永久停在 GRANTING | `charge_order.list_blocked`（复合 Keyset，limit 默认 50/上限 200，含 blocked/last_error 投影）；`charge_reconcile` 增偏索引 `reconcile_blocked`；`pay_callback` 增 `pay_unblock`（先 `critical_find` 多数派读，再 `unblock_reconcile`）与 `pay_blocked` 两个 GM 命令；`mark_reconciled` 去掉自动 `$unset reconcile_blocked_at`（原被状态门挡住，属 latent 的静默绕过入口） |
| P2-2 | Critical Reconciler 的“无阻塞排序”只是带 `limit=64` 时优化器选了 `rid_op_id`；去掉 limit 会切成 `SORT→FETCH→IXSCAN(state_lease)` | 不加索引（生产查询恒带 limit，加 `{state:1,rid:1,op_id:1}` 会给每次任务写多维护一条索引）；改为在 10.3 如实记录条件与退化路径，未来若改无 limit 查询，先补该索引（临时 mongod 实测可消除 SORT） |
| P2-3 | 超时后 fork 子协程仍卡在 `yield_call`，静默黑洞目标下逐轮累积孤儿 | 超时分支用 `skynet.killthread` 回收本地协程与 session 映射；远端 RPC 没有取消语义仍是残留，但结果已不会被采用。测试断言超时会调用回收 |
| P2-4 | `begin_round` 只重试 kick，不重试陈旧 target 的 `migration_abort` | `begin_round` 分两批补发：先 kick 后 abort 通知，各自受 `g_abort_budget` 约束；两批后仍清不掉的保留登记。新增“上一轮 target 通知失败、下一轮补发成功”用例 |
| P2-5 | 交接文档 §8 两处推断不成立；章节编号重复；§3/§5/§9 过期 | 本节即修订：排序复杂度改为 O(n log n)；补 100 MiB 阻塞排序硬上限与“超限直接报错”；去掉缺前提的“5 ms 可接受”；合并重复编号并标注历史章节 |

### 10.3 扫描器执行计划（临时单机 mongod v7.0.35，10 万级数据，非生产库）

| 扫描器 | 计划 | keys/docs/returned | 阻塞排序 | 耗时 |
| --- | --- | --- | --- | --- |
| Critical Reconciler（jobs 100k，1k 到期，`limit=64`） | `LIMIT→FETCH→SORT_MERGE→IXSCAN` | 64 / 64 / 64 | 否 | 3–5 ms |
| Charge Reconciler（orders 100k，500 GRANTING） | `SORT_MERGE(FETCH(IXSCAN))` | 65 / 64 / 64 | 否 | 15 ms |
| Outbox Worker（roles 100k，1k 待发 + 300 到期清理） | `SORT(FETCH(OR(IXSCAN)))` | 1300 / 1300 / 64 | **是** | 5 ms |

补充与更正：

- **Critical 不是无条件无阻塞排序。** 同一查询去掉 `limit`，只保留现有 `rid_op_id` / `state_lease` 时，计划退化为 `SORT→FETCH→IXSCAN(state_lease)`，keys = 99499、returned = 499、约 253 ms。临时加 `{state:1,rid:1,op_id:1}` 后无 limit 也走 `SORT_MERGE`（无 SORT），但该索引不在本轮落地范围，理由见 P2-2。
- **Outbox 的排序成本是 O(n log n)**，不是线性上升；内存排序受 100 MiB 硬上限约束，候选集超限时 MongoDB 直接报错（`Sort exceeded memory limit`），不是“变慢”。`1.3k 候选 / 5 ms` 只是单机、小数据、无并发压力下的一次观察，不能当作 SLA；待发角色数到万级前应加监控阈值或拆分扫描。
- 以上均不是生产副本集实测；切主、真实双节点迁移、TS SDK E2E 仍属“待环境”，未宣称已验证。

### 10.4 门禁

`./bin/skyext test`：129 files / 129 passed / 0 failed / 0 errors；`luacheck .`：0 warnings / 0 errors（316 files）；`stylua --check .`：通过；`git diff --check`：干净。真实副本集切主、双节点迁移、TS SDK E2E 仍未验证，因此不宣布 P0/P1 清零。
