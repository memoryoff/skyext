# 对抗审查报告 · 第二轮评审修复（2026-11-13）

- **审查范围**：`git diff 3e075bc..7f9d007`，HEAD = `7f9d007`（`fix(payment,migration): 收口多数派读与迁移取消安全出口`），13 files / +999 / −171，含新增 `docs/handoff-review-fixes-2026-11-13.md`。行号一律为 HEAD 当前文件行号。
- **性质**：对抗审查（adversarial review）。不对"7 项是否存在"重新辩论，只审"修得对不对、风险是否被挪到别处、测试是否假绿、代码与 §8 声明是否一致"。
- **方法**：分 5 个互斥域并行审查（支付写入链 / 支付门禁与阻断 / 迁移 deadline / 迁移代际与运行锁 / config 与索引执行计划），再由主代理交叉核对与定级仲裁。explain 用临时单机 mongod（v7.0.35，独立 dbPath，已关闭）复跑；门禁由主代理实跑。
- **门禁实测（本机）**：`./bin/skyext test` → **129 files / 129 passed / 0 failed / 0 errors**；`luacheck .` → **0 warnings / 0 errors (316 files)**；`stylua --check .` → 通过。§8 的门禁声明属实。

## 结论摘要

| 级别 | 数量 | 要点 |
| --- | --- | --- |
| P0 | 0 | 未发现 |
| P1 | **1** | P1-01 的 E11000 回读判定在生产链路**不可达**，重复回调由"幂等 ACK"退化为"永久 500"（对基线是行为回归） |
| P2 | 5 | 阻断单无解封入口；Critical 执行计划依赖优化器；超时孤儿协程不回收；begin_round 不重试 target 通知；§8 两处规模推断不成立 |
| P3 | 8 | 契约文档真空、latent 清阻断路径、注释口径、键未转义、清理缺 round 守卫、注释误称无 killthread、config 测试盲区、交付文档内部不一致 |

**一句话**：**资金安全目标达成、迁移取消/超时目标达成，但 P1-01 只闭合了"安全"侧、"幂等"侧不仅没闭合、还比基线更差**——因此"无新增 P0/P1"这条验收标准不成立，不能按"已修"收口。

---

## P1

### [P1] 重复回调的 E11000 判定在生产契约下不可达：幂等 ACK 退化为永久 500（相对基线是行为回归）

- **位置**：`lualib/skyext/charge_order.lua:85-110`（`is_duplicate_key`）、`:275`（`if not is_duplicate_key(detail)`）；依赖侧 `service/mongo_conn.lua:120-123`（`classify_write`）、`:172-176`（`CMD.critical_find_and_modify`）。
- **触发条件**：渠道重推同一 `(provider, order_id)` 回调（首次应答丢失、渠道主动重试、双投递均会触发），`findAndModify` 撞唯一索引返回 REJECTED。
- **证据链（闭环）**：
  1. `service/mongo_conn.lua:120-123`：`writeErrors` 分支 `err = first.errmsg`（**字符串**）；`:124-126` 写关注错误、`:127-130` `ok ~= 1`、`:131-134` `ok=1 带 errmsg` 的 `err` 同为字符串。
  2. `service/mongo_conn.lua:172-176`：非 CONFIRMED 时 `return state, err`——完整回复表 `detail` 被丢弃，**第二返回值恒为字符串**。
  3. `charge_order.lua:61-67`：`local state, ret = orders_coll:critical_find_and_modify(doc)`；非 CONFIRMED → `return nil, state or "UNKNOWN", ret`，即 `detail` = 该字符串。
  4. `charge_order.lua:86-88`：`is_duplicate_key` 首行 `if type(detail) ~= "table" then return false end` → 字符串直接判否；`:93`（`err.code`）、`:96`（`err.errmsg`）、`:101-108`（`writeErrors`）三处表结构分支在真实链路上**全部不可达**。
  5. 旁证：其他生产消费方（`saga.lua:159/225/264/282`、`critical.lua:1459/1484`、`dbmgr.lua:248-260`）都按"非确认时第二返回值是 err 标量"使用，`charge_order` 的表期望是唯一离群点。子代理另用 `./bin/lua` 复刻判定逻辑做了执行探针：字符串 → `false`，表 → `true`。
- **影响**：`record` 在 `:277-284` 走"非重复键 REJECTED"分支返回 `nil, <errmsg>`；`pay_webhook.lua:147-159` 归入 `storage_unavailable` → **HTTP 500（retryable）**。后果：① 重复回调永远无法幂等收口，形成无限重试环；② 换金额/币种/`action` 的串单也拿不到 409 `order_conflict`，只能 500；③ 监控把冲突计成存储故障。**资金侧不重复发奖、不会"未确认写入被 ACK"**（fail-closed 成立）。
- **回归判定**：基线 `3e075bc:lualib/skyext/charge_order.lua:223` 在**任何** REJECTED 上无条件 `find_one` 回读并返回已有单（幂等 ACK）。本轮把回读收窄为"仅 E11000"，但收窄实现失效 → 生产上**回读分支被整体移除**。即：安全风险（普通读把未确认数据当已确认）被消除，代价是幂等能力被清零。这正是"风险挪到别处"。
- **定级说明**：资金不重复入账，故不是 P0；但"每次重复回调都必然 500"在主支付路径 100% 可达、直接消费者（渠道）收到错误语义、且是本次变更引入的回归，属严重功能后果 → P1。若后续证明渠道在 5xx 后停止重推并自动停用 endpoint，影响还会上浮。
- **最小修复方向**（二选一，均需评审）：① `is_duplicate_key` 增加标量判定：`type(detail) == "string" and detail:find("E11000", 1, true) ~= nil`（可复用 `errcode.MONGO_DUPLICATE_KEY = 11000`，`lualib/skyext/errcode.lua:25`）；② 服务层非确认分支透传回复表（改动面更大，会波及所有既有消费方）。
- **建议验证（能真的失败的用例 C1）**：桩改成真实形状
  ```lua
  h.orders.critical_find_and_modify = function()
      return "REJECTED", "E11000 duplicate key error collection: db.orders index: provider_order_id dup key: {...}"
  end
  local reads = 0
  h.orders.critical_find = function() reads = reads + 1; return EXISTING end
  local order, created = h.record()
  -- 断言 reads == 1、type(order) == "table"、created == false
  ```
  现实现下该用例必然失败（`reads == 0`、`order == nil`）。补 C2：`critical_find` 返回 `nil, "timeout"`（2 元组读失败，替代现有"抛错"桩）。

---

## P2

### [P2-1] 人工阻断订单在运行系统内没有解封入口；且无阻断单清单端点

- **位置**：`lualib/skyext/charge_order.lua:595-614`（`unblock_reconcile` 定义）；`:621-653`（`mark_reconciled`）；`lualib/skyext/charge_reconcile.lua:50`（扫描排除阻断单）；`lualib/skyext/pay_webhook.lua:165-181`（阻断分支只 ACK 不推进）。
- **触发条件**：订单因 `BUSINESS_REJECTED` / `PRECHECK_REJECTED` 被打上 `reconcile_blocked_at`（写入点：`charge_order.lua:577-586`、`charge_reconcile.lua:174/228`、`pay_webhook.lua:293`），人工核对/补偿完成后需要放回自动对账。
- **影响**：全仓 `grep unblock_reconcile` 生产代码**仅定义处一处**，无 GM 命令、无服务命令调用；GM 为显式命令表（`service/gm.lua:103` `register_commands`），不存在通用 eval。阻断单永久退出对账候选集（`charge_reconcile.lua:50`），webhook 阻断分支不 transition → 订单停在 `GRANTING`，渠道因 200 不再重推 → **付了钱、永不发奖，且系统内无出口**；仓库也没有阻断单清单/巡检端点（只有 counter 指标），不盯指标就看不见。唯一逃生是 debug `inject` 或直连 Mongo 写。本次变更把"旧版自动 unblock"删除后，缺口被放大。
- **解除后能否接管**：能。`unblock_reconcile` 后扫描 query 除 `$exists=false` 外无额外排除，`updated_at` 过 60s grace 即重新纳入（`charge_reconcile.lua:42-51,305`），可按 `NOT_STARTED` 重投或 `COMMITTED` 推进。
- **建议验证（T-5）**：阻断单（GRANTING、`updated_at` 早于 grace）→ `unblock_reconcile` → `run_once` → 断言进入 `reconcile_order`；未解封前 `scan_orders` 结果集不含该单。修复方向：补业务 `GM_CMD`（provider+order_id）或在运维文档写明直连库解封步骤 + 阻断单巡检查询。

### [P2-2] Critical Reconciler "无阻塞排序"是优化器选择结果，不是索引结构性保证

- **位置**：`lualib/skyext/critical_reconciler.lua:41-60`（query）、`:103-108`（`limit`/`sort {rid,op_id}`/`projection`）；索引 `lualib/skyext/critical.lua:1712-1713`（`rid_op_id {rid,op_id}` 与 `state_lease {state,lease_until}` 前缀互不包含）。
- **触发条件**：`due` 任务在 rid 顺序上稀疏，或查询不带 `limit`。
- **影响**：100k 种子、`limit=64` 时 winning plan 为 `LIMIT→FETCH→IXSCAN(rid_op_id)`（无 SORT，64/64/64）；**同一查询去掉 limit 复跑，winning plan 切到 `SORT→FETCH→IXSCAN(state_lease)`**，且 2 条 rejected plans 均含 SORT。即 §8 "无阻塞排序"依赖规划器选择一个当前优的计划，换数据分布/换 limit 就会退化为阻塞排序。
- **建议验证**：在生产镜像分布上跑带/不带 limit 的 `explain("executionStats")`；若 `state_lease` 计划胜出，评估阻塞排序成本（见 P2-5 的内存上限），或设计覆盖"过滤+排序"的复合索引（注意不要违反 `docs/non-goals.md`）。

### [P2-3] 超时后的孤儿协程/会话在"静默黑洞"目标上不回收

- **位置**：`example/lualib/migration_adapter.lua:56-91`（`bounded_call`），超时分支 `:81-88`。
- **触发条件**：RPC 已发出，目标端既不回包也不退出（分区、目标假死、连接被静默丢弃且无 RST）。
- **影响**：`finished=true` 让主协程按 TIMEOUT 返回，但 fork 出去的子协程仍阻塞在 `yield_call`，`session_id_coroutine[session]` / `watching_session[session]` 与挂起协程一直存活到服务退出；跨轮迁移且目标持续黑洞时逐轮累积（单轮上限与在线实体数同阶）。已核实孤儿**不会产生二次副作用**（迟到回包时 `finished` 已真，`:70-72` 直接 return）；目标退出/PTYPE_ERROR 时会正常解套（`skynet.lua:336-343,345-365`），只有"静默黑洞"不回收。
- **建议验证**：双节点用 iptables DROP（不关机）制造黑洞，观测超时后 `session_id_coroutine` / `watching_session` 残留数。列入缺口，未升格 P1。

### [P2-4] `begin_round` 只重试踢人，不重试对陈旧 target 的 `migration_abort`

- **位置**：`example/lualib/migration_adapter.lua:177-200`（`begin_round` 循环 `:180-188`、保留判定 `:189`）；对照 `abort` 的两条腿 `:596-617`（kick）与 `:626-649`（notify）。
- **触发条件**：上一轮 `abort` 踢人成功（`conn_id` 已置 nil）但 `migration_abort` 通知失败（`target` 保留）。下一轮 `begin_round` 只对 `conn_id` 重发 kick，`target` 非空条目被计入 `carried` 保留却从不重发通知。
- **影响**：陈旧目标上的暂存快照/取消标记要等下一次 `M.abort()` 才解除，期间条目一直占 `g_inflight`。当前迁移只挂在停服序列上，滞留窗口有限 → P2。
- **建议验证（用例 4）**：构造"netify 失败保留 target"条目 → `begin_round()` → 断言是否重发 `migration_abort`。

### [P2-5] §8 的两处规模推断不成立：排序不是线性，且存在内存硬上限（超限报错而非变慢）

- **位置**：`docs/handoff-review-fixes-2026-11-13.md` 末尾 §8 的 P2-04 小节（约 207-215 行）；Outbox 扫描器 `lualib/skyext/outbox_worker.lua:114-129`。
- **问题**：① "万级时每轮排序成本线性上升"——比较排序是 O(n log n)，渐近刻画错误；② 阻塞排序有内存硬上限，实测本机 MongoDB 7.0.35 `internalQueryMaxBlockingSortMemoryUsageBytes = 104857600`（100 MiB），超限是**查询直接报错**（sort exceeded memory limit），不是"变慢"——§8 完全没提这个失败模式；③ "1.3k 候选 / 5ms 可接受"缺硬件/并发/SLA 前提，属判断而非可复核事实。
- **证据**：Outbox 复跑 `SUBPLAN→SORT→FETCH→OR→IXSCAN×2`、`memLimit=104857600, spilled=0`、keys/docs/returned=1300/1300/64 —— 计数与 §8 一致，**只有推断部分错**。
- **建议**：监控阈值与 100 MiB 上限挂钩（记录 `sortMemoryBytes` / `spilled`），而不是只看候选数；压测到万级候选确认不触发上限。

---

## P3

| # | 问题 | 位置 | 说明 |
| --- | --- | --- | --- |
| P3-1 | `critical_find` 返回契约未文档化 | `lualib/skyext/mongo_conn.lua:143-147` | 实际形状：失败/抛错 2 元组 `(nil, err)`，成功 **1 元组**（文档或单个 `nil`；查不到 ≠ `({}, nil)`）。调用方两种都能接住，但后续消费方无法从注释得知，易写出"把 nil 当失败/把失败当查不到"。`critical_update`/`critical_find_and_modify` 都有契约注释，唯它没有 |
| P3-2 | `mark_reconciled` 仍保留清阻断的 `$unset`（latent 第三条自动清除路径） | `charge_order.lua:640` | query 要求 `status=GRANTED`，阻断单为 GRANTING，**当前不可达**；但一旦出现"GRANTED 后被阻断"即会静默抹掉人工阻断，与"人工终态不得被自动解除"契约冲突。建议移除该 unset 并补断言用例 |
| P3-3 | 探针两处注释口径不一致 | `lualib/skyext/mongo_conn.lua:155-156` vs `service/mongo_conn.lua:221-269`、`service/critical_maintenance.lua:274-276` | 包装层注释仍写成"连通性检查"，实现是真写+majority 读回+清理。行为以实现为准，P2-02 门禁确实达到 §8 效果 |
| P3-4 | 登记键分隔符 `|` 未转义 | `migration_adapter.lua:49-51` | `tostring(id).."|"..tostring(barrier)`；当前 uid 为数字、`barrier_id` 由 `migration.lua:98-101` 生成为 `mig_%s_%d_%d`（无 `|`）、停服钩子不传 barrier，**不可达**；`barrier=nil` → `<id>|nil` 不报错。建议转义或改嵌套表 |
| P3-5 | `activate`/`fallback`/`transfer` 的登记写入与清理未做 round 守卫 | `migration_adapter.lua:394-398, 436-437, 557` | freeze 三条回包分支（`:298/:306/:316`）都比了 round，这三处没比；运行锁 + barrier 键隔离下**跨轮不可达**。建议对齐 freeze 写法 |
| P3-6 | 注释称"skynet 没有中止协程的能力"，与源码不符 | `migration_adapter.lua:55` | `skynet/lualib/skynet.lua:543-599` 存在 `skynet.killthread`，只是 `bounded_call` 未保留子协程句柄。若要回收孤儿（P2-3），先验证 kill 后会话映射是否清干净 |
| P3-7 | config 测试盲区（代码正确，覆盖不足） | `config.test.lua:374-429` | 数字 `0` 缓存边界无用例；布尔↔数字交叉只用 `"30"`，未测 `"1"`/`"true"`；table-first 顺序未测；缺失键的"不缓存"调用次数断言只在 `get` 路径有。另：config 缓存无失效入口，GM `setenv`（`service/gm_sys.lua:445`）改已缓存键会被静默忽略（**既有设计**，非本轮引入） |
| P3-8 | 交付文档内部不一致，且 §8 措辞多处高估/过宽 | `docs/handoff-review-fixes-2026-11-13.md` | 见下表 |

### §8 声明逐条裁定

| §8 声明 | 裁定 | 证据 |
| --- | --- | --- |
| "`record` 只对真正 E11000 走回读" | **不成立** | 判定分支在生产不可达（P1） |
| "回读改 `critical_find`" | 成立 | `charge_order.lua:117-120`；`readConcern: {level="majority"}`（`service/mongo_conn.lua:181-195`，runCommand 透传到 BSON） |
| "读不到/读失败/无通道一律 UNKNOWN" | 成立 | `:117-118,124-129,288-299,330-334` 全 fail-closed |
| "`check_write_channel` 同时要求多数派写与多数派读" | 成立 | `:537-542` |
| "`bounded_call` fork+timeout，TIMEOUT 按结果未知" | 成立 | `migration_adapter.lua:56-91`；8 阶段无一把 TIMEOUT 当"肯定没成功" |
| "全部阶段调用改用 deadline" | 基本成立，一处漏 | 枚举 RPC `list_entities`→`migration_list`（`:219`）无 deadline，基线既有、同节点，风险低 |
| "回包比对轮次，旧轮次只允许清自己那条" | **部分成立** | 只清自己那条（按 barrier 键）成立；"回包比对轮次"仅 freeze 三支落地，清理路径（P3-5）未比 |
| "grant/webhook 均不再自动清阻断" | 成立但不完整 | 未提 `mark_reconciled` 残留 `$unset`（P3-2），也未提解封无运营入口（P2-1） |
| "P2-02 探针未确认/抛错直接拒绝启动" | 成立 | `pay_callback.lua:149-157`；探针为真写+majority 读回+清理 |
| "前两个扫描器…无阻塞排序"（Critical / Charge） | Charge 成立；**Critical 附条件** | Charge 索引前缀与排序完全对齐（`charge_reconcile.lua:84` ↔ `:342-346`）；Critical 无 limit 复跑走 `state_lease`+SORT（P2-2） |
| "sort(rid) 无法由任一索引提供 ⇒ 内存排序"（Outbox） | 成立 | 两条偏索引前缀为 pending 计数/cleanup 时间，均不含 `rid`；全仓无其他角色表 rid 索引 |
| "1.3k 候选 / 5ms 可接受"；"万级线性上升" | **不成立（判断越界 / 刻画错误）** | P2-5 |
| "129 files 全过、luacheck 0、stylua 通过" | 成立 | 主代理实跑复核 |
| 文档结构 | 内部不一致 | **两个章节都编号 §8**（约 160 行与约 192 行）；§3 批次 3 仍写"待修（未触碰）"、§5 写"完全未触碰"、§9 的 16 文件清单均已过期；实际支付状态机在更早提交（`c00bb4a`/`c782924`/`3e075bc`）落地 |

---

## 验收标准裁决

| # | 标准 | 裁定 | 依据 |
| --- | --- | --- | --- |
| 1 | 支付不出现 ACK 后凭证回滚 | **成立** | `record` 只有 15 条返回分支中的 #13（多数派读可见、参数一致）与 #15（多数派写 CONFIRMED）会返回订单文档；#9/#11/#14 三个未知分支一律 `nil, "UNKNOWN"`。多数派读经源码 + runCommand 透传确认真实生效。ACK 写失败走 503 `retryable`（`pay_webhook.lua:166-169,331-337`），不会"未落库却回 200"。阻断分支只 ACK 不发奖、不清标记。 |
| 2 | 迁移超时/取消/失联有安全出口 | **成立（附残留）** | 8 阶段 × {TIMEOUT,RAISED,明确拒绝} 无一把"结果未知"当"肯定没成功"；失败必进 fallback（`skyext/migration.lua:258`）；踢失败一律保留登记，由 abort / `begin_round` 二次重试；abort 有整批预算封顶不会被失联目标卡死；`g_run_active` 布尔锁有 `pcall`+无条件复位（`migration_coordinator.lua:225-227`），无遗留死锁；cancel 不碰锁。残留 = P2-3、P2-4。 |
| 3 | 无新增 P0/P1 | **不成立** | 新增 1 条 P1（重复回调幂等回归）。P0 = 0。 |

**整体裁决：`changes_required`。** 不能把本轮按"7 项全部已修"收口；P1-1 修掉之前，支付侧应视为"安全已加固、幂等已回退"。

---

## 测试有效性复核（跨域汇总）

| 哪个测试在骗人 | 位置 | 为什么 |
| --- | --- | --- |
| 重复键幂等用例（最核心） | `charge_order.test.lua:502-517` | 桩返回 `"REJECTED", {code=11000,...}`（表），真实服务只回字符串；换成真实形状该用例必失败 → **正是它掩盖了 P1-1** |
| `ok=1 + writeErrors` 判定用例 | `charge_order.test.lua:558-572` | `writeErrors` 在服务层已被压成 errmsg 字符串、回复表被丢弃，该分支生产不可达 |
| "多数派读失败"用例 | `charge_order.test.lua:543-554` | 用 `error(...)` 覆盖抛错路径；真实读失败是返回 `nil, err` 不抛错，`charge_order.lua:127-129` 分支从未被触达 |
| 迁移三个超时用例 | `migration_adapter.test.lua:722-763` | fake 把 `fork/timeout/wait/wakeup` 同步内联（`hang=true` 时 timeout 立即同步回调、被保存的 fn 永不执行）→ **真实 skynet 定时器/协程调度/迟到回包一次都没跑**；适配器 TIMEOUT 决策分支确被真断言，但机制层零覆盖 |
| 迁移代际用例 | `migration_adapter.test.lua:750-763` | 从未断言条目的 `round` 值；`298/316` 的"迟到成功回包撞新一轮"分支无任何用例触达 |
| 探针门禁用例 | `service/pay_callback.test.lua:151-160` | 断言匹配的错误串由 stub 的 `h.probe_err` 自己提供（自指），无法发现真实 CMD 各失败分支的文案差异 |

补测设计已在各条下给出（C1/C2、T-4/T-5、迟到回包撞轮、run 抛错后锁复位、`begin_round` 重试 target）。

---

## 无法复核的缺口（未升格为 finding）

1. **真实副本集行为**：`findAndModify` 唯一冲突在副本集上究竟走 `writeErrors` 还是顶层 `code/errmsg`、驱动是否直接抛 Lua 错——本轮未接活体副本集。注意：**无论哪种形状，服务层对外都只给"非 CONFIRMED + 字符串 err"**，故 P1-1 结论不依赖此未知项。
2. **渠道应答契约**：仓库无 provider 模块（`common.app.lua:173` `providers = {}`），"渠道是否接受 200 + `manual_review` body"无任何证据；`pay_callback_router.lua:88-90` 只做原样透传。
3. **网关对失效 conn_id 的行为**：是否 no-op、会不会误踢同 fd 新会话，需网关侧源码。
4. **目标端 fence/epoch 拦截迟到 commit/attach**、**源端 unquiesce 在已释放态是否必拒**：决定 fallback 的"已释放"反推是否正确，属 handler 层。
5. **双节点分区/黑洞**：P2-3 的残留量与 `skynet.killthread` 的清理效果。
6. **时序绝对值**（3/15/5ms）与生产分布下的优化器选择：单机模拟数据，不可引用。
7. **DBA 外置索引**：结论以仓库内 `create_index` 为准，未直连生产 `listIndexes`。

---

## 附：各域裁决

| 域 | 文件 | 裁决 |
| --- | --- | --- |
| 支付写入与确认链（P1-01） | `charge_order.lua`(+test) | 安全侧成立；**幂等侧 P1**；E11000 判定不可达 |
| 支付门禁与人工阻断（P2-02/P2-03） | `pay_webhook.lua`、`service/pay_callback.lua`(+tests) | P2-02 已闭合（真探针）；P2-03 绕过路径已闭合，**解封侧漏接线**（P2-1） |
| 迁移 deadline（P1-02） | `migration_adapter.lua`、`migration_coordinator.lua`(+tests) | 通过（P2-3 + P3-6） |
| 迁移代际与运行锁（P1-03/P1-04） | 同上 | 通过（P2-4 + P3-4/P3-5） |
| config 与索引执行计划（P2-01/P2-04） | `config.lua`(+test)、三扫描器索引 | P2-01 代码正确；P2-04 Charge/Outbox 成立、Critical 附条件、**两处推断不成立** |
</content>
