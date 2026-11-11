# skyext 生产化补强方案 v2 —— 经审核修订

> **状态：方案，未实施。本版取代 2026-11-10 v1，v1 的核心经济提交、无感迁移、频道广播三节已作废。**
> **核实基准：** 2026-11-10/11 工作区快照（`E:/CODE/skynet/code/old_skyext`）。行号均指该快照，动手前以实际文件为准。
> **核实方式：** 逐行阅读报告与审核意见点名的实现、完整调用链、现有测试、`docs/non-goals.md`、`docs/plan/architecture_refactor.md`。**未运行多节点动态故障复现**，因此所有新增问题均为源码级确认或有明确前提的风险分析。
> **当前可实施范围：B0、B1。B2 经济提交、B5 会话迁移与频道广播必须先按本版重新设计，不得按 v1 实施。**

---

## v1 → v2 变更摘要

| 章节 | 变更 |
| --- | --- |
| §3 核心经济持久化 | **整节重写**。撤回 `critical.commit()` 示例；改为「由 `dbmgr` 参与的三态原子提交协议 + 结果未知即隔离丢弃实体」，补齐自动回存行锁、BSON key 规范、去重有效期、订单状态机、write/read concern |
| §2 会话幂等 | **撤回**「正常顶号后旧连接残留并确定重复扣费」的结论（核实：正常链路会 `unbind_kick`）；保留身份校验作为防御；新增 `request_hash` 参数摘要冲突检测 |
| §6.2 无感迁移 | **整节重写**。v1 的「复用 `session.resume`」不成立；改为六阶段状态转移 + 会话快照导出/安装 + Gateway 独立部署前提 |
| §6.3 频道广播 | **整节重写**。v1 由 Gateway 直投会破坏下行计数；改为两阶段，第一阶段统一走 `session.push()` |
| §4 / §5 / §6.4 / §6.5 / §7 | 补齐异常安全单元、RPC 编码保护与连接校验、临时实体完整生命周期、实际 owner 定位、降级状态机统一、各项小修 |
| §9 | 按审核建议重排 B0~B6，验收标准改为「按持久化/迁移边界注入故障 + 三方一致性核对」 |
| §0 | 新增逐条审核意见处理表 |

---

## 0. 审核意见处理表

「核实」列是本次独立回源码验证的结果，与审核表述有差异处已如实标注。

| # | 审核意见 | 核实 | 处置 |
| --- | --- | --- | --- |
| 1 | `critical.commit()` 落库失败未回滚 `fn(entity)`，同一 `op_id` 重试可重复扣费 | **成立**（v1 §3.3 代码缺陷） | 撤回，§3.2/§3.4 重写 |
| 2 | `dbmgr.save()` 返回 false 不等于「库里一定没写」 | **成立**：`save_doc`（`dbmgr.lua:237-240`）在 `safe_update` 成功后二次校验租约，失租即返回 false 但写入已生效；`safe_update` 响应丢失同理 | §3.2 / §3.4 三态协议 |
| 3 | 自动回存与实体队列不是同一把锁，可保存中间态 | **成立**：`sweep_save` 用 `with_row_lock`，实体队列用 `skynet.queue`；`save_wheel.lua:22` 注明回调可让出；`orm.snapshot_mongo`（`orm/init.lua:373-393`）直接从共享 `__changed_keys` 采增量 | §3.4 全程持有行锁 |
| 4 | 原始随机字节不能作 BSON Map key | **成立**：`copy_bson`（`orm/init.lua:185`）对 map 键直接 `tostring(k)` 用作 BSON 字段名 | §3.5 改为 32 位 hex + 强校验 |
| 5 | 64 条淘汰无法区分「新操作」与「已淘汰旧操作」 | **成立** | §3.5 账本优先、水印、先归档后删除 |
| 6 | 充值订单原子占用缺故障恢复 | **成立** | §3.6 四态订单状态机 |
| 7 | 正常顶号链路会先清理旧连接 | **成立，v1 判断错误**：`entity_agent.CMD.bind_session`（`:211-246`）在 `entitymgr:with_entity()` 队列内先 `session.unbind_kick(old.key, entity)`（`:229`）再 `session.bind()`；跨节点还有 `request_handoff` → `unload_entity` → `_kick_client` | §2.1 撤回结论，保留防御校验，§2.4 调整测试目标 |
| 8 | 同一 `req_id` 携不同参数会被误判成功 | **成立**：`session.lua:407-429` 只比 `cached.name` | §2.2 / §2.4 增加 `request_hash` |
| 9 | `websocket.accept()` 可能返回 `nil, err`，`accepted == false` 覆盖不全 | **部分成立**：当前 `skynet/lualib/http/websocket.lua:429-469` 的签名是 `true` / `false, err`，未发现 `nil` 返回；但 `_new_server_ws`、`socket.start` 等路径不在其内部 `xpcall` 保护内，**会抛异常**。仍采纳「非 true 即失败」 | §4.2 全非成功返回 + 异常安全单元 |
| 10 | `skynet.send(g_login, ...)` 不在异常保护内，异常会漏计数 | **成立** | §4.2 |
| 11 | `g_sessions` 应区分 HANDSHAKING / ACTIVE / CLOSING | **成立**（工程建议） | §4.2 |
| 12 | `pcall` 参数求值使 `g_send_request()` 不受保护，pending 泄漏 | **成立**（Lua 求值语义） | §5.2 `xpcall` 包裹编码与发送 |
| 13 | `raw_dispatch` 响应未校验连接，`pending.fd` 形同虚设 | **成立**：`sproto_api.lua:242-248` 只按 session 查表 | §5.2 |
| 14 | `abort_fd()` 需用会话键而非数字 fd | **成立**：实体侧 conn 是 `"<gate_node>/<fd>"`（`session.lua:55-57`） | §5.2 |
| 15 | `session.resume` 不支持跨实体实例恢复，`session_io` 绑在内存实体上 | **成立**：`bind` 无条件 `new_session_io()`（`session.lua:215`），`_forget_entity` 后对象被丢弃 | §6.2 快照导出/安装 |
| 16 | 迁移失败不能简单「绑回旧节点」 | **成立**：新 fence 生效后旧 owner 已无权 | §6.2 |
| 17 | Gateway 与 Role 同进程时重启必然断连 | **成立** | §6.2 明确独立部署前提 |
| 18 | 频道由 Gateway 直投会绕过 `record_and_send`，导致 sent/recv 失配 | **成立**：`session.lua:142-143` 注释明确「下行的唯一收口」 | §6.3 两阶段 |
| 19 | 临时实体仅跳过 `dbmgr.load/unload` 不够 | **成立**：`_ensure_loaded` 依赖 `entity.data`；`_recover_dirty` / `_release_lock` 全链路依赖持久化组件 | §6.4 |
| 20 | `call_loaded` 用 HRW 目标节点会漏掉旧节点已加载实体 | **成立**：`entity_agent.lua:84-104` 的 `sticky()` 才有「lock held → 转发持锁节点」 | §6.4 |
| 21 | `updated_at` 应区分「最后变更」与「最后成功同步」 | **成立**：`cluster_discovery.lua:63-65` 只在 `update` 里存 nodes | §6.5 |
| 22 | §6.5 正文允许陈旧缓存回退、验收却禁止，自相矛盾 | **成立**（v1 缺陷） | §6.5 统一为「优先快速失败」的降级状态机 |
| 23 | `_init_modules()` 的 `mod.new()` 也可能有依赖 | **成立**：`entitymgr.lua:71` 传入 `entity` 与数据子表 | §7.1 构造也用确定性顺序 |
| 24 | `10000/freq` 不等于真实 Hz 采样 | **成立** | §7.2 区分指令采样与时间采样 |
| 25 | HRW 缓存 `(type_name, entity_id)` 无界增长 | **成立** | §7.3 有限容量 + 成员版本失效 |
| 26 | `save_wheel` 无优先级接口，B 级持久化不能「复用优先级」 | **成立**：`save_wheel.lua` 只有 `add/remove` 与槽轮转 | §3.8 / §7.3 改为受控提前落库 |
| 27 | 验收门槛「100 次零重复」不能证明无竞态 | **成立** | §9.2 |
| 28 | 三种状态所有权需统一设计 | **采纳为全文结论** | §11 |
| — | **本次新发现（审核未提）** | `mongo_conn._route()`（`mongo_conn.lua:155-157`）用 `math.random` 选连接，`find_one`（`:93-96`）无 readConcern / readPreference，`safe_update`（`:107-118`）无 writeConcern 参数。**「primary read 对账」在现有接口上根本不成立** | §3.7 必须先补专用接口 |

---

## 1. 总体原则与可复用的既有设施

保留 v1 的「用现成的、成本留在框架里」原则，并补上审核指出的架构主线：**业务状态、会话状态、实体所有权三条状态链必须分别确定归属与一致性边界**（§11）。

| 设施 | 位置 | 用途 |
| --- | --- | --- |
| 实体串行队列 `skynet.queue()` | `entitymgr.lua:442-458` | P0-1 合并幂等临界区 |
| `dbmgr` 行锁 `with_row_lock` | `dbmgr.lua:420, 431` | **关键**：自动回存与关键提交必须用同一把锁 |
| `save_doc` 的 CAS | `dbmgr.lua:225-243`（`_version` + `_fence` + `safe_update`） | 关键操作的原子提交原语 |
| `orm.snapshot_mongo` / `ack_mongo` | `orm/init.lua:373-404` | 增量提取与脏标记清理 |
| 失租隔离 / 脏数据接回 | `entitymgr.lua:460-475, 710-789` | 「结果未知即隔离」的现成骨架 |
| `find_and_modify` 状态迁移 | `reliable_msg.lua:258-290` | 订单状态机模板 |
| 下行唯一收口 `record_and_send` | `session.lua:142-165` | 频道与迁移都不得绕过 |
| 粘性路由 `sticky()` | `entity_agent.lua:84-104` | `call_loaded` 定位实际 owner |
| `metrics` / 集成测试 / 停服编排 | `metrics.lua:165-174`、`*.integration.test.lua`、`node_shutdown.lua` | 可观测与验收 |

实施纪律（来自 `AGENTS.md` / CI）不变：引擎模块用 `skyext.*` 全命名空间、测试与源码相邻 `*.test.lua`、改 schema 跑 `generate schema` + `schema check`、改 API 同步文档与测试、CI 跑 `check_paths.lua` / `luacheck` / `stylua --check`；提交走 `main`、Conventional Commits、无 `Co-Authored-By`、未经明确要求不提交。

`docs/non-goals.md` 的边界继续遵守：框架内**不做** GM 权限分级 / RBAC、独立审计文件、ORM 版本化迁移链、日志脱敏；管理后台与热更灰度回滚属外部系统。

---

## 2. P0-1：会话幂等（修订版）

### 2.1 撤回 v1 的一处结论

v1 称「正常顶号后旧连接残留、确定重复扣费」，**这个结论撤回**。完整调用链是：

```
entity_agent.CMD.bind_session        entity_agent.lua:211
  → entitymgr:try_ensure_loaded     （实体串行队列）
  → entitymgr:with_entity           entity_agent.lua:226（同一实体队列内）
      → session.unbind_kick(old.key, entity)   :229（old.key ~= key 时）
      → session.bind(...)           :231
```

`unbind_kick` 会清 `g_conns[old.key]` 并置 `entity.session = nil`（`session.lua:315-350`）；跨节点顶号还有 `request_handoff → unload_entity → _kick_client`（`entity_agent.lua:49-60, 388-410`）。整段在实体队列内，与在途请求串行。若顶号复用同一 key，`session.bind` 的 `install_conn` 会覆盖 `g_conns[key]`，队列内 `g_conns[key] ~= conn` 也能拦住。

**但 `entity.session == conn` 校验仍保留**，理由是防御性而非已确认缺陷：直接调用 `session.bind()` 的模块级行为（单测替身、未来新增调用方）确实不清理旧 conn；跨网关迟到的 `client_msg`、旧 owner 被转发来的消息也需要身份校验。v1 的并发幂等竞态（查缓存/写缓存都在队列外）**依然成立，仍是 P0**。

### 2.2 修复（改 `lualib/skyext/entity/session.lua`）

在 v1 的「查重/执行/写缓存全进 `with_loaded_entity`」基础上，增加**请求参数摘要**。下面是设计草图，`encode_canonical` / `crypto.hash` 需复用仓库现有编码与摘要能力或新增辅助函数，不能直接粘贴：

```lua
-- 请求摘要：协议名相同但参数不同时，不能复用同一 req_id 的响应。
-- 用规范化编码（字段按 schema 顺序、不含易变字段、定长输出）后取哈希；
-- 编码入口复用现有 sproto_host，实施时确认具体可用函数。
local function request_fingerprint(request_name, request, op_id)
    local canonical = encode_canonical(request)   -- 不含 req_id 本身
    return request_name .. "|" .. crypto.hash(canonical) .. "|" .. tostring(op_id or "")
end

-- resp_cache 条目从 { pack, name } 扩为 { pack, name, hash }
local function cache_response(io_, req_id, pack, request_name, hash)
    io_.resp_cache[req_id] = { pack = pack, name = request_name, hash = hash }
    ...
end

-- with_request 队列内（其余部分同 v1 §2.2）
local fingerprint = req_id and request_fingerprint(request_name, request, op_id)
local cached = io_.resp_cache[req_id]
if cached then
    if cached.name ~= request_name or cached.hash ~= fingerprint then
        log.warn("request id reused for a different request", ...)
        return { rejected = "...", code = errcode.REQUEST_CONFLICT }
    end
    return { pack = cached.pack }
end
```

要点：

- `with_request` 现有签名是 `(key, f, req_id, request_name)`，**没有 request 参数**。需要在 `sproto_api.dispatch_request`（`:168-186`）把 `request` 一起传入，或在 `register_module` 时由 `dispatch_request_unlocked`  closure 携带；推荐前者，改动集中且不影响旧连接模块（用可选第五参数保持兼容）。
- 对关键经济操作，摘要必须包含 `op_id`、玩家标识（`rid`）、操作类型与参数摘要；`op_id` 与玩家的绑定由服务端校验，不信任客户端自报。
- 摘要计算在进入实体队列**之前**完成（纯计算、无 IO），或在队列内但不 yield；不能把摘要编码做成会切换协程的操作。
- `resp_cache` 的 `min_cached_req_id` 淘汰语义不变；淘汰后同一 id 仍返回 `REQUEST_EXPIRED`。

### 2.3 保留的其它校验

`active ~= entity`、`g_conns[key] ~= conn`、`entity.session ~= conn`、队列内重取 `io_ = entity.session_io`、`last_seen` 队列内更新、缓存写入队列内、`handler` 抛错不写缓存 —— 全部沿用 v1 §2.2。`sweep_idle` 只处理 `conn.entity.session == conn` 的连接。

**残留窗口**：`with_loaded_entity`（`entitymgr.lua:604-620`）在 `f` 执行后才检查租约，失租时返回 false 但业务可能已执行。L1 缓存不能作为成功依据，必须靠 §3 的 L2 业务幂等兜底。

### 2.4 测试目标（按审核意见重划）

| 用例组 | 覆盖内容 |
| --- | --- |
| 并发幂等 | 真实 `skynet.queue` + 两个 fork 协程交错，同 `req_id` 只执行一次；缓存写入在临界区内 |
| **正常顶号调用链** | 从 `CMD.bind_session` 进入（用 `entity_agent.test.lua` 的 harness），断言旧连接被 `unbind_kick`、旧请求被拒、无重复执行 |
| **模块级 `session.bind()`** | 绕过 `CMD.bind_session` 直接调 `bind`，断言 `entity.session ~= conn` 校验拦住旧 conn 的在途请求 |
| **排队先后** | 旧请求先入队 / 登录请求先入队两种交错，分别断言 |
| **跨网关迟到消息** | 旧 gate 的 `client_msg` 在解绑后到达；旧 owner 转发来的 `entity_call_loaded` 迟到 |
| 参数摘要 | 同 `req_id` + 同协议名 + 不同 `item_id` → `REQUEST_CONFLICT`；同 `req_id` + 不同 `op_id` → 冲突；相同参数 → 命中缓存 |
| 回归 | v1 列出的淘汰、协议名冲突、handler 抛错、续接换连接等用例全部保留 |

harness 改造：`session.test.lua:24-40` 的 `fake_mgr:with_loaded_entity` 增加可排队模式；新增 `entity_agent.bind_session` 交错用例。新增用例要求「在旧实现上失败、新实现上通过」，红测记录留档。

---

## 3. P0-2：核心经济系统（整节重写）

### 3.1 三个必须分开的问题

| 问题 | 本质 | 解决手段 |
| --- | --- | --- |
| 进程被 kill 后 180s 回存周期内的内存改动丢失 | 持久化时机 | 回包前确认提交（§3.4） |
| 节点异常死亡后单实体约 30s 不可用 | etcd 租约 TTL / 单活所有权 | 缩短 TTL、快速检测、客户端可重试；根治靠 §6.2 迁移。**同步落库解决不了可用性** |
| 重传、顶号、缓存淘汰、跨重启导致重复执行 | 幂等层次 | L1 会话缓存（§2）+ L2 业务 `op_id`（本节） |

### 3.2 v1 `critical.commit()` 的三个致命缺陷

1. **只删去重键、不回滚业务状态**：`fn(entity)` 把钻石从 1000 改到 900，`dbmgr.save` 失败后仅 `ops[op_id] = nil`，内存仍是 900；客户端用同一 `op_id` 重试，再次 `fn` 变 800。审核给出的复现成立。
2. **`false` 语义不单一**：`save_doc`（`dbmgr.lua:231-243`）在 `safe_update` 返回后还会二次 `lease_valid(handle)`，失租时 `log.error("lease lost during save, retaining dirty state")` 并 `return false` —— **此时数据库已写入**；`safe_update` 响应丢失、驱动抛错同样返回 false，且 `orm.ack_mongo` 未执行会让内存保持 dirty，后续回存用旧 `_version` 反复失败。因此「false 就回滚内存」也不是修复。
3. **自动回存可插入中间态**：`sweep_save` 拿 `with_row_lock`（`dbmgr.lua:248-256`），`fn` 改共享 ORM doc 时不持锁；回存轮回调允许让出（`save_wheel.lua:22`），`orm.snapshot_mongo` 直接从 `__changed_keys` 采增量。若 `fn` 或提交过程中发生让出，自动回存可能先把「资产已改、`processed_ops` 未写」刷入库并 `_clear_dirty`，后续提交只剩去重键。v1 所谓「同一次 `dbmgr.save` 天然原子」不成立。

另外审核指出的「隔离工作副本」若实现成「克隆 `entity.data` 再整体替换」也不可行：`copy_bson`（`orm/init.lua:185-186`）对 map 子文档整块覆盖，且 `entity.modules[name]` 持有 `entity.data.modules[name]` 的引用（`entitymgr.lua:71`），替换文档对象会让已构造的模块指向旧数据。

### 3.3 设计转向

- **不做内存回滚，也不替换 `entity.data`。** 由**数据库里的操作记录**唯一决定「是否已提交」。
- 结果三态：`COMMITTED` / `NOT_COMMITTED` / `UNKNOWN`。凡是 `UNKNOWN`，**先隔离实体并用 primary read 对账，再决定回放结果或允许重试；绝不自动重试 `apply`**。
- 提交失败或结果未知时，不试图把内存改回去，而是**丢弃整个实体内存态**（隔离 + 摘掉回存轮条目 + 从库重新加载），从而避开「部分回滚」与「模块引用失效」两个难题。
- 自动回存与关键提交统一到 `dbmgr` 的**同一把行锁**内，从根上消除中间态。

### 3.4 由 `dbmgr` 参与的三态原子提交接口

新增 `dbmgr.critical_commit(dbname, dbcoll, key, unique_id, handle, op)`，其中 `op = { op_id, op_type, param_hash, apply, encode_result, decode_result }`。**不复用 `M.save` 的粗粒度 bool 语义。**

前置约定：调用方位于实体串行队列内；`apply(entity)` 是纯内存计算，**不得 yield**（不允许 `skynet.call` / DB / cluster / `session.push`）；接口内部从 `apply` 之前起全程持有 `with_row_lock`。

```
critical_commit(...) 内部：

 1 校验：op_id 格式、param_hash、lease_valid(handle)、_fence 有效
    ↓ 前置失败 → NOT_COMMITTED（跳过 2~5，直接隔离）
 2 读取判定（primary + readConcern majority）：
     查角色文档 processed_ops[op_id]
       命中               → COMMITTED：返回历史结果，不执行 apply
       未命中 → 查 op_ledger(rid, op_id)
       账本命中           → COMMITTED：返回历史结果
       两者皆无且 op_ts < op_watermark_ts
                          → EXPIRED：拒绝，走状态查询/人工流程
 3 在共享 doc 上执行 apply(entity)  （仍在行锁内，禁止 yield）
    ↓ orm.snapshot_mongo(doc) 取增量
 4 单次 CAS 写入（writeConcern majority + journal）：
     query  = { [key]=unique_id, _version=v, _fence=handle.fence }
     update = { $set = { <资产增量>, ["processed_ops.<op_id>"] = 记录,
                         _version = v+1 } }
 5 结果判定：
     nModified == 1      → COMMITTED：orm.ack_mongo(doc, revision, v+1)，回成功
     nModified == 0      → UNKNOWN（自己上次已提交 / fence 失效 / 并发改动）
     抛错 / 响应丢失 /
       写入后失租         → UNKNOWN
 6 UNKNOWN 处理（强制）：
     a 立即 entity.invalid = true、停止该实体一切业务、踢线
     b dbmgr.quarantine(...) 把条目从回存轮摘掉，防止脏内存被自动回存刷回库
       （现成设施，entitymgr._recover_dirty 已用，entitymgr.lua:713）
     c primary read 查 processed_ops[op_id] / op_ledger：
          查到            → COMMITTED（用库里的结果应答，客户端按 op_id 重查）
          查不到且 _version 仍为 v、fence 未变 → NOT_COMMITTED：丢弃内存实体，允许重试
          查不到但 _version / fence 已变      → UNKNOWN 持续，交 _recover_dirty 与人工对账
     d 任何 UNKNOWN 都不得回「成功」；回明确错误码，客户端按 op_id 走状态查询
 7 NOT_COMMITTED（含前置失败）同样隔离并摘回存轮条目，因为 apply 可能已改内存
```

**为什么不采用「隔离工作副本」的完整替换**：见 §3.2 末段。本设计用「行锁隔离时间窗口 + 失败即整体丢弃实体」达到同等效果，且不触碰 `entity.data` 的对象身份。

**必须同时处理的边界**（实施检查表）：

- `apply` 前若 doc 已有其它未保存的脏字段（普通进度等），CAS 会把它们一起写入；需要明确「关键提交是否顺带提交其它脏数据」的策略，推荐**一起提交**，避免 `__changed_keys` 残留导致后续重复写。
- `_version` 与 `_fence` 由 `save_doc` 的现有逻辑生成，不能绕过；新接口应与 `save_doc` 共用 query/update 组装，**只替换结果判定与锁范围**，不要复制一份。
- `orm.ack_mongo` 在 `doc.__revision` 变化时返回 false 但仍会写 `_version`（`orm/init.lua:395-404`）；提交成功路径要核对 `unchanged`，否则说明提交期间有并发改动，转 UNKNOWN。
- 写入完成后失租：`save_doc:237` 的二次校验会返回 false，本接口应把它归入 UNKNOWN（而非 NOT_COMMITTED），因为写入已生效。
- 所有关键路径必须能观测：`metrics.counter` 记录三态次数、UNKNOWN 持续时长、对账命中/未命中、隔离实体数。

### 3.5 `op_id` 规范与去重有效期

- **格式**：128-bit CSPRNG 编码为 **32 位小写十六进制字符串**，服务端用 `^[0-9a-f]{32}$` 强校验长度与字符集，非法直接拒绝。Lua SDK 与 TypeScript SDK 必须遵循同一规范，写入 `docs/guide/client_protocol.md` 与协议测试基线。原因：`copy_bson` 把 map 键 `tostring(k)` 直接当 BSON 字段名（`orm/init.lua:185`），BSON 字段名禁止 NUL，原始随机字节不可用。
- **两级存储**：`processed_ops` 只是角色文档内的**热缓存**；`op_ledger` 是独立集合的**权威流水**，字段 `rid, op_id, op_type, param_hash, result, ts, status`，`(rid, op_id)` unique。
- **判定顺序**：查 `processed_ops` → 查 `op_ledger` → 比对 `op_ts` 与 `op_watermark_ts`。**Map 中缺键绝不等于「新操作」**。
- **归档顺序（强制）**：先把记录写入 `op_ledger` 且 majority 确认 → 再从 `processed_ops` 删键 → 最后推进 `op_watermark_ts`。任一步失败都不删键、不推进水印。
- **有效期**：显式配置 `op_retention`（如 30 天）与 `op_cache_window`（如 7 天）；热缓存按时间窗淘汰而非固定 64 条，上限仅作防膨胀保护。超过 `op_retention` 的请求返回 `REQUEST_EXPIRED` 并进入状态查询/人工流程，**不执行业务**。客户端最长重传周期必须小于 `op_retention`，并在 SDK 文档中写明。
- 关键操作还要校验 `op_id` 绑定的玩家、操作类型与 `param_hash` 一致，防止同一 `op_id` 被挪用到别的请求（与 §2.2 的 `request_hash` 呼应）。

### 3.6 充值订单状态机

替代 v1 的「先占订单、再 `critical.commit`」：

```
RECEIVED   → 支付通知已验签、验金额/币种/商品/目标角色，订单号原子占用（unique + findAndModify）
PROCESSING → 写入 processing_owner 与 lease_until，可被超时接管
GRANTED    → 角色资产已确认持久化（critical_commit 返回 COMMITTED 或账本命中）
ACKED      → 已向支付渠道确认完成
```

- **先验签**：支付回调签名、金额、币种、商品、目标角色必须校验；`op_id` 只是客户端幂等键，**不能作为充值真实性的证明**。
- 重复回调：先按 `order_id` 查状态；`GRANTED`/`ACKED` 直接返回，`PROCESSING` 且 lease 未过期返回"处理中"，lease 过期则接管。
- `PROCESSING → GRANTED`：调 `critical_commit`；任何 UNKNOWN 都按订单号 primary read 查 `processed_ops` / `op_ledger` 的**实际发放状态**，再决定推进或重试，不重复发奖。
- 超时 / 持续 UNKNOWN → `charge_dlq` 人工对账队列，带订单号、rid、金额、最后一次状态与时间。
- 只有 `GRANTED` 之后才能推进到 `ACKED`；`PROCESSING` 就向渠道确认会永久卡单。

### 3.7 MongoDB 一致性前提（本次核实新增）

审核指出需明确 write/read concern；回源码后发现**现有接口连「读主库」都不保证**：

- `db_mt:_route()` 是 `math.random(1, #self.conns)`（`mongo_conn.lua:155-157`），读写随机分散到多个连接；
- `find_one`（`:93-96`）只有 `doc, projection` 参数，无 readConcern / readPreference；
- `safe_update`（`:107-118`）无 writeConcern 参数，走 `raw_safe_update`。

因此 §3.4 的「primary read 对账」与「majority 写入」**必须先补接口**，否则整个协议没有立足点：

| 新增接口 | 要求 |
| --- | --- |
| `mongo_conn.find_one_primary(coll, query, opts)` | 固定连接指向 primary，`readConcern: majority`（按部署可选 `linearizable`），`readPreference: primary` |
| `mongo_conn.safe_update_majority(query, update)` | `writeConcern: { w = "majority", j = true }`，返回可区分的 `n` / `nModified` / `writeErrors` / 超时错误码，而不是单一 bool |
| 配置 | 副本集、写关注、读关注、超时在节点配置里显式声明；启动时校验副本集可用 |

明确写入语义：普通 `w:1` 确认**不等于**主节点切换后不会回滚；关键写入必须 majority + journal。对账读必须 primary + majority，否则可能读到尚未复制或已回滚的旧值。

### 3.8 分级策略

| 级别 | 内容 | 落库时机 |
| --- | --- | --- |
| A 关键 | 付费货币、充值/购买、稀有道具、领奖、交易结果 | §3.4 三态原子提交，`op_id` 去重，回包前确认 |
| B 重要 | 任务进度、普通道具、邮件 | **不使用** `save_wheel` 优先级（无此接口，`save_wheel.lua` 只有 `add/remove` 与槽轮转）；改为由实体定时器或业务显式触发受控提前落库，或确需时给 `save_wheel` 新增 `touch/urgent` 能力 |
| C 普通 | 登录时间、界面状态、统计计数 | 现有 180s 回存轮 |

### 3.9 测试与验收（替代 v1 的「100 次零重复」）

**按持久化边界注入故障**，每个用例断言三方一致（数据库资产 / `op_ledger` 流水 / 客户端收到的结果）：

| 注入点 | 期望 |
| --- | --- |
| `apply` 执行前、CAS 请求发出前 | NOT_COMMITTED，实体隔离，回存轮条目已摘除，内存脏数据未入库 |
| Mongo 已执行但响应丢失 | UNKNOWN → primary read 查到 `op_id` → 按 COMMITTED 回放，不重复扣 |
| 写入完成后失租（`save_doc:237` 路径） | 同上，且 `_fence` 阻止旧 owner 继续写 |
| `orm.ack_mongo` 前崩溃 | 重新加载后按 `op_id` 判定，不重复执行 |
| 回包前崩溃、重连后同 `op_id` 重试 | 资产只变一次，客户端拿到一致结果 |
| 自动回存试图在 `apply` 中间插入 | 行锁互斥，不能刷出「资产已改、去重键未写」的中间态 |
| 同 `op_id` 换参数 / 换玩家 | 拒绝，资产不变 |
| `op_ledger` 归档成功但删键前崩溃 | 重放仍命中账本，不重复执行 |
| 超过 `op_retention` 的旧 `op_id` | `REQUEST_EXPIRED`，不执行业务 |
| 订单处于 `PROCESSING` 时进程崩溃、回调重发 | 接管后按实际发放状态推进，不重复发奖 |
| 多节点并发同 `op_id`、旧 owner 迟到写入 | `_version` + `_fence` 只有一方成功，迟到写入被拒 |
| primary 切换 | majority 写入不丢；对账读不返回未提交值 |

要求在多节点、协程交错下反复执行，并检查最终状态不变量，而不是只检查接口返回值。**统计次数不能证明不存在竞态**，只能作为回归辅助指标。

---

## 4. P1-1：WebSocket 配额（修订）

### 4.1 机理（不变）

`g_count` 在 accept 回调检查（`:142`）、`fork(serve)`（`:148`）后由 `serve`（`:107`）自增；现有测试 `h.connect()` 的 `skynet.sleep(0)`（`gate_ws.test.lua:124-127`）恰好放行 fork 协程，掩盖了窗口。检查与占用必须在同一个不 yield 的回调内完成。

### 4.2 异常安全单元（修订 v1 的 `serve`）

```lua
-- CMD.open 的 accept 回调：检查与占用原子完成
socket.start(g_listen_fd, function(fd, addr)
    if g_count >= g_maxclient then
        log.warn("ws gate is full, dropping a new connection", "addr", addr, "maxclient", g_maxclient)
        socket.close_fd(fd)
        return
    end
    g_count = g_count + 1
    g_sessions[fd] = { fd = fd, addr = addr, state = "HANDSHAKING" }
    skynet.fork(serve, fd, addr, protocol)
end)

-- 连接生命周期整体包成一个异常安全单元：无论从哪条路径退出，配额都只释放一次
local function serve(fd, addr, protocol)
    local function run()
        skynet.send(g_login, "lua", "open", fd, addr, GATE_NAME)
        local accepted, err = websocket.accept(fd, handler, protocol, addr)
        if accepted ~= true then   -- 覆盖 false、nil 及任何非成功返回
            log.warn("ws handshake failed", "fd", fd, "addr", addr, "err", err)
        else
            local session = g_sessions[fd]
            if session then session.state = "ACTIVE" end
        end
    end
    local called, err = xpcall(run, debug.traceback)
    if not called then
        log.error("ws serve crashed", "fd", fd, "err", err)
        pcall(socket.close_fd, fd)   -- 异常路径主动关闭底层 fd
    end
    close_session(fd)                -- 幂等：靠 g_sessions[fd] 判空
end
```

配套：

- `close_session`（`:55-67`）先把 `g_sessions[fd].state = "CLOSING"` 再移除；`CMD.push` / `CMD.bind` / `handler.message` 只接受 `state == "ACTIVE"`，避免握手期间被误当成可用会话。
- `skynet.send` 与 `websocket.accept` 都在 `xpcall` 内；`_new_server_ws` 等 skynet 内部未保护路径抛异常时也能兜住（审核第 9 条的实质来源）。
- `handler.close` / `handler.error` / `serve` 收尾三方都调 `close_session`，它用 `g_sessions[fd]` 判空保证计数最多减一次。
- `CMD.close`（停服）只关监听 fd；满额时 `socket.close_fd` 不动计数。

> 核实备注：当前 `skynet/lualib/http/websocket.lua:429-469` 的返回是 `true` / `false, err`，未发现 `nil, err`；采用 `accepted ~= true` 是面向未来与异常路径的防御，不依赖该版本细节。

### 4.3 测试

- harness 增加 `h.accept_burst(...)`：连续调 `h.accept_cb` 且**不** `skynet.sleep(0)`；`maxclient=1` 时断言第二个 fd 被关、`count()==1`。
- 异常路径全覆盖：`websocket.accept` 返回 `false,err` / 返回 `nil` / 抛异常、`skynet.send` 抛异常、`handler.close`/`error`、正常断开后 `serve` 收尾 —— 逐条断言 `count()` 精确归零且不为负、底层 fd 被关闭。
- 状态机：握手期间 `CMD.push` / `CMD.bind` 不生效；`ACTIVE` 后正常转发。
- 集成压测：robot 在 200ms 内发起 `maxclient*2` 条连接，断言峰值不超限、失败连接不向登录服务泄漏 `open`。

---

## 5. P1-2：Sproto 主动 RPC（修订）

### 5.1 现状（不变）

`M.call`（`sproto_api.lua:268-291`）先发送后注册；sleep 后无条件清空（ID 复用误删）；无发送失败/断连清理；全仓无调用点，属预留 API，优先级可降但一次补齐。

### 5.2 修订实现

```lua
local function wakeup_call(pending, response, fd)
    if not pending.co then return false end
    if pending.fd ~= fd then       -- 响应必须来自发出请求的同一连接
        log.warn("sproto response from a different connection",
                 "session", pending.session, "want", pending.fd, "got", fd)
        return false
    end
    pending.co = nil
    pending.response = response
    pending.done = true
    -- skynet.wakeup 只对已进入 sleep 的 token 有效；早到响应靠 done 短路
    skynet.wakeup(pending)
    return true
end

function M.call(fd, name, param, session, timeout)
    assert(type(session) == "number" and session > 0, "a positive session id is required")
    if g_sessions[session] then error("duplicate sproto session: " .. tostring(session)) end

    local pending = {
        name = name, session = session, fd = fd, co = coroutine.running(),
        response = nil, done = false,
    }
    g_sessions[session] = pending
    g_by_fd[fd] = g_by_fd[fd] or {}
    g_by_fd[fd][session] = pending

    -- 编码与发送都在保护内：Lua 先求值参数，pcall(send_package, fd, g_send_request(...))
    -- 保护不了 g_send_request 抛出的错误
    local ok, err = xpcall(function()
        local pack = g_send_request(name, param, session)
        send_package(fd, pack)
    end, debug.traceback)
    if not ok then
        M.cleanup(pending)
        error(err, 0)
    end

    if not pending.done then       -- 发送若让出协程，响应可能已经到达
        timeout = timeout or config.get_number("sproto_timeout") or 10
        skynet.sleep(timeout * 100, pending)
    end
    if g_sessions[session] == pending then g_sessions[session] = nil end  -- 只清自己
    if g_by_fd[fd] then g_by_fd[fd][session] = nil end
    if not pending.done then
        log.error("call timeout", "name", name, "fd", fd, "session", session)
        return nil
    end
    return pending.response
end
```

配套：

0. `M.cleanup(pending)` 是内部统一清理：仅当 `g_sessions[pending.session] == pending` 时删除该键，并从 `g_by_fd[pending.fd]` 表中移除；被 `abort_fd`、发送失败、超时三条路径共用，避免各写一份遗漏。
1. `raw_dispatch` 的 RESPONSE 分支改为 `wakeup_call(pending, request, fd)`；`fd` 在实体侧是 `"<gate_node>/<fd>"` 会话键，不是数字，调用链必须原样传递，不得转换。
2. `M.abort_fd(fd)` 用**同一套连接标识**遍历 `g_by_fd[fd]`，唤醒并清理所有 pending（返回超时语义）；挂点在 `entity_agent` 的 `session_closed` 路径。
3. `M.next_session()`：进程内单调、跳过 0、检测回绕。
4. 找不到 pending 时记 `log.debug`，区分「早到丢包」与「客户端乱发」。

### 5.3 测试

- 发送期间让出协程、响应提前到达 → `M.call` 立即返回（`done` 短路）。
- **编码抛错** → `g_sessions` 与 `g_by_fd` 均无残留。
- 发送抛错 → 同上。
- **响应来自另一连接**（同 session）→ 不唤醒、不误回包，最终超时。
- 实体侧会话键形式的 `fd` 能正确匹配与 `abort_fd`。
- 重复 session、超时后 ID 复用不误删、断连清理全部 pending。
- 现有 `sproto_api.test.lua` 只测 REQUEST 分发，需补这批 RESPONSE/主动调用用例。

---

## 6. P1 架构项

### 6.1 故障注入与真实多节点集成测试（增强）

分层保持 v1（单元 / 组件 / 集成）。在故障矩阵上按审核意见**增补持久化与迁移边界**：

| 类别 | 注入点 |
| --- | --- |
| 原有 | kill -9 节点、etcd 失租、Mongo 写失败/高延迟、cluster 丢包、网关并发建连、顶号/续接交错 |
| **经济边界（新增）** | 见 §3.9 全部 12 项；要求断言数据库资产 / 流水 / 客户端结果三方一致 |
| **迁移边界（新增）** | 快照导出前/后、旧锁释放前/后、新 owner 取得 fence 后、回放中断、旧 owner 迟到消息、Gateway 与 Role 分离/同进程两种拓扑 |
| **回存协调（新增）** | 自动回存与 `apply` 并发、回存轮落后、行锁等待超时 |

注入机制仍用 `lualib/skytest/fault.lua` 的 fault 表 + `SKYTEST_FAULT` 环境变量，生产代码零分支。集成测试单独 job、可重跑、失败时导出节点日志与 Mongo/etcd 状态快照。

### 6.2 无感迁移（整节重写）

**v1 的「复用 `session.resume`」不成立**：`session_io`（nonce、sent/acked、out_buf、resp_cache、resp_order、min_cached_req_id、unresumable）只存在于内存实体对象上；`bind` 无条件 `new_session_io()`（`session.lua:215`）；`resume` 只作用于已加载实体（`entity_agent.lua:248-250` 注释明确"绝不加载实体"）；实体卸载后对象随 `_forget_entity` 被丢弃（`entitymgr.lua:412-420`）。新节点加载数据库拿不到任何会话状态。

**前提与范围（按审核意见收窄）**：

- 只支持**计划内滚动更新**，`kill -9` 等异常恢复交给客户端重连 + §3 的业务幂等。
- **Gateway 必须独立部署**（`example/nodes/gateway/`）；Gateway 与 Role 同进程时进程重启必然断连，不在本阶段范围。
- 先完成「统一会话状态设计」，再实施迁移；与 §6.3 频道广播**不是两个独立功能**。

**新增会话快照能力**（`session.export_snapshot` / `session.install_snapshot`）：快照内容 = 完整 `session_io` + 会话版本 `epoch` + `owner_node` + `owner_service`，可序列化、带校验和。`install_snapshot` 在 `bind` 之前注入，禁止重新生成 nonce / 计数。`resp_cache` 条目含 §2.2 的 `hash` 字段一并迁移。

**六阶段状态转移**：

| 阶段 | 动作 | 不变量 |
| --- | --- | --- |
| 1 DRAINING | 从服务发现摘除旧逻辑节点，阻止新实体加载与新会话绑定 | 无新会话进入旧节点 |
| 2 QUIESCING | 旧实体停止接受新业务；网关缓存上行请求；等待已进入实体队列的操作跑完；设置 `epoch = epoch + 1` | 队列排空，无在途 `critical_commit` UNKNOWN |
| 3 TRANSFER | 导出会话快照（含 epoch），与角色数据一起完成持久化/可靠传输并**确认** | 快照未确认不得进入下一阶段 |
| 4 ATTACHING | 释放旧锁；新节点取得**新的 fencing token**，加载实体、安装快照、确认新 owner | 旧 owner 的 fence 立即失效；恢复不能「绑回旧节点」，一切按新 owner + epoch |
| 5 REPLAYING | 网关按序回放缓存的上行包到新 owner；新实体按计数重放下行包；用 epoch 拒绝迟到的旧 owner 消息 | 上行不丢不重；下行 `sent/acked` 连续 |
| 6 ACTIVE | 解除网关缓存，恢复正常收发，清理旧节点迁移状态 | 客户端无需重新认证 |

**失败语义**：任一阶段超时/失败，客户端退化为 `login.resume`（若快照已安装）或完整重登；**绝不回滚路由到旧节点**。所有阶段状态持久化在协调者（停服编排 `service/node_shutdown.lua` 或独立迁移服务），可重入、可查询。

**与会话状态下沉的关系**：第二阶段（§6.3）把 `session_io` 的计数与重放缓冲下沉到独立 Gateway 的连接会话层后，迁移只需迁移 Gateway 上的会话槽，实体侧不再持有会话状态 —— 这才是生产形态。本阶段先做「快照导出/安装」的过渡实现，接口设计要为下沉留出边界。

**验收**：Gateway 独立部署；验证零重复业务、零丢失已确认下行、`sent/acked` 与客户端 `recv` 一致、旧 owner 不再产生有效业务结果、客户端无需重新认证；在 TRANSFER/ATTACHING/REPLAYING 各阶段注入失败并断言不变量。

### 6.3 频道与广播（整节重写）

**v1 的 Gateway 直投不可用**：`session.lua:142-143` 明确 `record_and_send` 是下行唯一收口，维护 `session_io.sent` 与重放缓冲；绕过它会出现实体侧 `sent` 未增、客户端 `recv` +1，导致 `resume`/`ping` 对账失败与重放错位。

**第一阶段（正确性优先）**：

- 新增 `skyext.channel` 只管理**订阅关系**（`game:` / `zone:` / `global` / `guild:` / `team:`），登录时按出生服自动订阅，`realm.subscribe` 在目录变化时重订阅，断线自动退订，频道名做边界校验。
- **实际发送仍走玩家实体的 `session.push()`** → `record_and_send`，保证计数与重放一致。
- 为控制开销：按 owner 节点聚合订阅者，在实体节点内批量 `session.push`，避免每个订阅者一次跨节点调用；`metrics` 记录每频道投递量与丢弃量。
- 这一阶段不改动会话状态所有权，可与 B3 并行、早于 B5。

**第二阶段（性能优先，与迁移合流）**：把下行计数与重放缓冲下沉到独立 Gateway 的连接会话层，让 Gateway 广播与业务下行经过**同一个计数出口**。这一步与 §6.2 的会话快照/迁移共享设计，必须先完成统一会话状态模型，再同时开发迁移与高性能广播。**两项不得作为独立功能分别排期。**

### 6.4 临时实体与不唤醒调用（补强）

**临时实体：只跳过 `dbmgr.load/unload` 不够。** `entitymgr._ensure_loaded`（`:504-538`）依赖 `entity.data`；`_recover_dirty`（`:710-789`）、`_release_lock`（`:793-811`）、`_unload_entity`（`:814-864`）、`deliver_pending`（`:659-695`）整条链路都假设持久化。完整改动：

- `entity_types` 增 `persistent = false`，加载时用 `orm.new(schema, default)` 构造纯内存 `entity.data`（走 `orm.decode` 的零值补齐），不读 Mongo、不加入回存轮；
- `_init_modules` / `on_load` / 串行队列 / etcd 锁与 fence **全部保留**（"同一时刻只在一处"仍由 `distributed_lock` 保证）；
- `_unload_entity` 走独立分支：跳过 `dbmgr.unload` / `persisted` / `_recover_dirty`，只跑钩子、释放锁、踢线；
- `_on_lock_expired` 对非持久化实体直接丢弃内存对象，不做脏数据接回；
- `deliver_pending` 对非持久化目标拒绝或转内存队列，不能写 Mongo；
- 作用域 / 定时器 / `unload_delay` 语义需单独测试。

**`call_loaded` / `send_loaded`：不能用 HRW 目标节点。** `router.get_target`（`router.lua:17-25`）只算节点；集群成员变化后已加载实体仍驻留旧节点，靠 `entity_agent.sticky()`（`entity_agent.lua:84-104`）在 `lock held` 时转发到持锁节点。因此：

- 新增 `CMD.entity_call_loaded` 的公开入口必须复用同一 `sticky` 转发链，`forward_cmd` 用已有的 `entity_call_loaded`；
- `router.call_loaded` 仅当持锁节点也返回 `NOT_LOADED` 时才返回 `false, "offline"`，**绝不触发加载**；
- `send_loaded` 是异步投递，接口文档与返回值必须明确「不承诺同步返回业务成功」，避免调用方误用；
- 同步更新 `docs/guide/client_protocol.md` 与 `router` / `entity_agent` 测试。

### 6.5 服务发现与回退（统一降级状态机）

**双时间戳**（`cluster_discovery.lua:52-65`）：`last_change_at`（成员集合实际发生变化）与 `last_sync_at`（最近一次成功从 discovery 服务同步或收到 watch 心跳）。健康判据用 `last_sync_at` —— 长期无成员变化时 `last_change_at` 会一直很旧，但它不代表不健康。

**统一状态机，消除 v1 正文与验收的矛盾**：

| 状态 | 条件 | 行为 |
| --- | --- | --- |
| `INIT` | 从未成功初始化 | 允许回退配置静态名单，**仅启动期**，带有效期与 `skyext_placement_bootstrap_fallback_total` 指标；超时后转 `UNCONFIRMED` |
| `HEALTHY` | `last_sync_at` 新鲜且有存活节点 | HRW 正常选点 |
| `DEGRADED` | 曾初始化、同步新鲜、但存活集合为空 | **快速失败**，禁止回退静态名单（明确的「全挂」信号，回退只会把请求发到死节点） |
| `UNCONFIRMED` | `last_sync_at` 陈旧 / 查询失败 | 有界重试 + 失败节点短期隔离 + 指标告警；**仍不回退静态名单**，除非显式配置 `allow_bootstrap_fallback` 且处于 `INIT` |

原则：**对无法确认存活的目标优先快速失败**。v1 中「缓存陈旧时回退但打告警」与验收「只有未初始化才回退」的冲突，以此表为准。

配套：`g_fallback[type_name]` 从 bool 改成 `{ state, reason, since, count }`，恢复时输出持续时长；新增 `skyext_placement_state{type,state}`、`skyext_placement_last_sync_age_seconds`；失败节点连续 N 次超时进入冷却，`M.select` 剔除，冷却结束探测恢复。

---

## 7. P2 项（按审核意见逐条修正）

### 7.1 模块顺序

`conf.modules` 是 `ipairs` 有序数组（`entity_agent.lua:314`），装进 `g_data_modules[name]` 后丢序。最小修复：把名字数组透传给 `entitymgr.new`，**构造、`on_load`、`on_unload` 三处全部使用确定性顺序**（审核指出 `_init_modules` 的 `mod.new(entity, entity.data.modules[name])` 同样可能有依赖），卸载取逆序。增强：模块可声明 `depends_on`，`new` 阶段做拓扑排序、检测环/缺失依赖/未知模块并启动即失败。`loaded_modules` / `unloaded_modules` 的记账与 `only_loaded` 语义不变。

### 7.2 Profiler

`debug.sethook(hook, "", 10000)`（`profiler.lua:39`）是**指令计数**采样，只挂在当前协程；`target_service`、`freq` 未生效。改为「目标服务自采样」（GM 把请求发给目标服务，在业务协程/消息分发入口装钩子），采样结果按 folded stack 汇总。

**修正 v1 的表述**：指令间隔 `10000/freq` **不等于**每秒采样 `freq` 次，实际频率随服务负载变化。要么把参数明确改名为 `instruction_interval` 并在文档写清「这是指令采样，不承诺 Hz」；要么实现基于定时器的时间采样并单独标注。GM 参数 `service/duration/freq` 做校验（现在 `tonumber` 后直接用，`freq=0` 会出问题），并发采样会话数设上限。C 层全局栈采样列为长期路线，不在本阶段。

### 7.3 热路径与告警

- **告警**：`metrics.lua:165-174` 已有 `counter/gauge/histogram` 与 `/metrics`，框架不缺采集能力；缺的是部署层 Prometheus 规则，放 `example/deploy/`。新增指标见 §3.4 与 §6.5。
- **发布**：`gm_api` 增只读 `build_info`（各节点代码 checksum / 热更包版本 / 协议 checksum），供外部发布系统做灰度与一致性判断；多节点灰度与回滚不进框架。
- **HRW 缓存**：v1 的 `(type_name, entity_id) → node` 缓存会**无界增长**。改为：先压测，无数据不优化；确需缓存时用有限容量 LRU + `membership_version` 全局失效（`service_change` 事件递增），禁止按实体 ID 无限累积。
- **网关 / Mongo**：`gate_ws` 若确认 CPU 热点，按既定方向横向扩网关节点，不改成 agent 池（会让下行多一跳）；Mongo 优化只针对压测证实的瓶颈，且不得破坏 `_version` + `_fence` CAS。
- **B 级持久化**：见 §3.8，不再假设 `save_wheel` 有优先级接口。

---

## 8. 其余架构风险（保留 v1，补充边界）

- **可靠消息 ≠ 跨实体事务**：保持 At-Least-Once，不伪装 Exactly-Once。按 `docs/plan/architecture_refactor.md:130-136` 落地 `skyext.entity.saga`：单向转移「先扣 + `reliable_send` + `msg_id` 去重」；双向交易用持久化状态机的交易实体做 `reserve → commit/release` 协调者，重启后从库继续。**依赖 B2 验收**，且业务 handler 幂等必须复用 §3 的 `op_id` 帮助库，不要求玩法自己写去重。
- **`seq` 非全序**：`reliable_msg.lua:14-19` 已声明。有顺序依赖的业务改单生产者或带业务因果键；框架侧只需把约束在文档里写得更醒目。
- **合服编排 / 跨服玩法范式**：属 `architecture_refactor.md` 阶段 7 与玩法示例，不在本次 P0~P2。
- **30 秒不可用窗口**：短期暴露 lease TTL/续租参数为可调 + 客户端指数退避；中期靠 §6.2 迁移。与「崩溃丢内存改动」分开立项。
- **热更新作用域**：框架补 `build_info`；「补丁不能替代正式源码发布」写进 `docs/guide/hotfix.md`。
- **管理后台 / RBAC**：不在框架层做，见 §0.3 与 `docs/non-goals.md`。

---

## 9. 实施顺序与验收标准（重排）

### 9.1 批次

| 批次 | 工作重点 | 可否立即实施 |
| --- | --- | --- |
| **B0** | 会话幂等（§2）、WS 配额（§4）、模块初始化顺序（§7.1）、基础回归测试 | **可以** |
| **B1** | 故障注入框架、真实 Mongo/etcd 双节点测试 | **可以，与 B0 并行** |
| **B2** | 经济原子提交接口、业务去重、订单状态机、崩溃恢复（§3）、Mongo primary/majority 接口（§3.7） | **必须按本版重写设计后实施**；先出接口设计与红测，再写实现 |
| **B3** | `call_loaded`、服务发现状态机、临时实体（§6.4 / §6.5） | **拆成三个独立任务**，不要按「薄封装」估算工作量 |
| **B4** | 可靠消息 Saga、跨实体交易与补偿 | 依赖 **B2 验收** |
| **B5** | **B5a** 统一会话状态模型（计数/重放所有权）→ **B5b** 计划内无感迁移（§6.2）→ **B5c** 频道广播（§6.3） | 先完成 B5a 设计；三项不得并行独立开发 |
| **B6** | Profiler、合服、压测后优化 | 按需求与实测瓶颈推进 |

Sproto RPC（§5）因仓库内无业务调用点，可作为 B0 的低风险附带项或并入 B1，不单独占批次。

跨批次纪律不变：每项独立提交、便于回滚；每批结束更新对应指南与测试；新指标用 `skyext_*` 前缀；新引擎模块用 `skyext.*` 全命名空间。

### 9.2 验收标准（替换「N 次零重复」）

**不再把统计次数当作无竞态的证明。** 改为：

1. **经济操作**：按 §3.9 的每个持久化边界注入故障，检查最终数据库资产、`op_ledger` 流水、客户端收到的结果**三方一致**；多节点反复交错执行；额外断言状态机不变量（不存在「内存已扣、库里未扣且无流水」的状态）、UNKNOWN 必然导致隔离、回存轮条目必然被摘除。
2. **会话幂等**：按 §2.4 的四类顶号/排队/迟到场景 + `request_hash` 冲突，断言业务只执行一次；新增用例在旧代码上稳定失败。
3. **无感迁移**：Gateway 独立部署；同时验证零重复业务、零丢失已确认下行、`sent/acked` 与客户端 `recv` 一致、旧 owner 不再产生有效业务结果、客户端无需重新认证；在每个阶段注入失败并断言不变量。
4. **WS / RPC / 模块顺序**：异常路径全覆盖、计数归零、pending 无泄漏、确定性顺序与逆序卸载。
5. **通用**：`./bin/skyext test`、`make -C example lint`、`stylua --check .`、`luacheck .`、`schema check`（若改 schema）、TypeScript SDK 类型检查与测试。

---

## 10. 涉及文件清单（改动量粗估，本版上调）

| 文件 | 改动 |
| --- | --- |
| `lualib/skyext/entity/session.lua` + `session.test.lua` + 新增 `session.integration.test.lua` | `with_request` 重写、`request_hash`、快照导出/安装、并发红测 |
| `lualib/skyext/sproto_api.lua` + `session` 调用链 | `dispatch_request` 透传 request；`M.call` / `wakeup_call` / `next_session` / `abort_fd` |
| `lualib/skyext/sproto_api.call.test.lua`（新增） | 编码异常、连接校验、done 短路 |
| `service/gate_ws.lua` + `gate_ws.test.lua` | 配额预留、异常安全单元、连接状态机 |
| `lualib/skyext/mongo_conn.lua` + 测试（**新增关键路径接口**） | `find_one_primary`、`safe_update_majority`、写/读关注配置 |
| `lualib/skyext/dbmgr.lua` + `dbmgr.test.lua` | `critical_commit` 三态接口、与 `save_doc` 共用 CAS 组装、隔离与回存轮摘除 |
| `lualib/skyext/entity/critical.lua` + 测试（新增） | 业务侧薄封装（**不是提交逻辑本身**）、`op_id` 校验、账本查询 |
| `lualib/skyext/entity/charge.lua` + 测试（新增） | 订单四态状态机、超时接管、`charge_dlq` |
| `example/schema/role.sproto`、`op_ledger` / `charge_order` 集合定义、`schema.lock.lua` | 只增字段；跑生成器与 `schema check` |
| `sdk/lua/skyext/client/session.lua`、`sdk/ts/`、两份 `session.test.*` | 32 位 hex `op_id` 规范、跨重传稳定、协议基线 |
| `lualib/skyext/entity/entitymgr.lua`、`service/entity_agent.lua` | 模块顺序、临时实体完整生命周期、`_kick_client` 迁移挂点、`call_loaded` sticky 公开入口 |
| `lualib/skyext/entity/router.lua` | `call_loaded` / `send_loaded` 语义与文档 |
| `lualib/skyext/entity/placement.lua`、`lualib/skyext/cluster_discovery.lua` | 降级状态机、双时间戳、失败节点隔离 |
| `lualib/skyext/channel.lua`（新增）、`gate_tcp.lua`、`gate_ws.lua` | 订阅关系、第一阶段经 `session.push` 发送 |
| `service/node_shutdown.lua`、迁移协调者（新增） | 六阶段迁移状态机 |
| `lualib/skyext/profiler.lua` | 目标服务自采样、参数语义与校验 |
| `lualib/skytest/fault.lua`（新增）、`*.integration.test.lua` | 故障注入与边界测试 |
| `docs/guide/*`、`docs/overview.md`、`example/deploy/`（可选） | 同步文档与告警规则 |

---

## 11. 结论：先划清三种状态的所有权

审核指出的共性问题是准确的：v1「局部代码修复详细，跨组件状态一致性设计不足」。三类状态必须分别定界，再分别开发：

| 状态 | 当前所有者 | 必须建立的边界 |
| --- | --- | --- |
| **业务状态** | 实体内存 + MongoDB（`dbmgr` 回存轮） | 关键操作由**数据库里的 `op_id` 记录**唯一裁定提交结果；自动回存与关键提交共用行锁；结果未知即隔离、对账、不重试；`_version` + `_fence` + majority 写/读构成恢复基础 |
| **会话状态** | 内存实体上的 `session_io`（连接绑定、请求缓存、下行计数、重放缓冲） | 唯一收口 `record_and_send`；断线靠 `resume`，计划迁移靠**显式快照导出/安装**；长期应下沉到独立 Gateway 的连接会话层，使频道广播与迁移共用一套计数与所有权 |
| **实体所有权** | etcd 租约 + fencing token | 旧 owner 失租后不得产生有效业务结果；迁移失败按新 owner + epoch 恢复，不回滚路由；`critical_commit` 与 `save_doc` 的所有写入都带 `_fence` |

**当前可以安全推进的只有 B0 与 B1。** B2 必须先完成三态提交接口与 Mongo 一致性接口的设计评审和红测；B5 必须先完成统一会话状态模型；频道广播的第一阶段（经 `session.push`）可以先行，但不要越过计数收口。这比一次性按 v1 的 600 行方案改整个仓库，更可能得到稳定、可验证的结果。
