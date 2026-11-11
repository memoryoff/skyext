# 02 · 引擎集群与实体层

> 覆盖 `lualib/skyext/` 下的 `cluster_discovery.lua`、`cmd_api.lua`、`config.lua`、`dbmgr.lua`、`distributed_lock.lua`、`entity/`（`entitymgr`、`placement`、`reliable_msg`、`router`、`session`、`types`）、`errcode.lua`。
> 第二列是源码起始行号。

## `config.lua`（145 行，应用配置）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.get(key)` | 6 | 取字符串配置：先查 `app_config_loaded` 后的配置表，再回退 `skynet.getenv` | 不存在返回 `nil` |
| `M.get_boolean(key)` | 20 | 同上的布尔版本（接受 `true`/`"true"`） | — |
| `M.get_number(key)` | 40 | 同上的数字版本 | — |
| `M.get_table(key)` | 55 | 取表：配置值是字符串时 `load("return " .. s)` 再执行 | 加载/执行失败都直接 `error` |
| `M.serialize(t)` | 74 | 把表序列化成 Lua 字面量（数字/字符串 `%q`/布尔/嵌套），供 `setenv` 传给子服务 | 字符串 |
| `load_config(config_name)` | 89 | `dofile` 式加载应用配置，注入 `include` 与 `$ENV` 替换 | — |
| `getenv(name)` | 91 | `include` 里的 `$VAR` 展开入口 | 环境变量缺失断言失败 |
| `include(filename)` | 96 | 按**当前配置文件所在目录**解析并执行子配置（`load(code, "@"..filename, "t", result)`） | 读不到断言失败 |
| `M.init()` | 121 | 读 `app_config_path` 指向的应用配置，逐键 `serialize` + `setenv`；`app_config_loaded` 保证一个进程只读一次 | 缺路径/加载失败直接 `error` |

## `cmd_api.lua`（54 行，`skynet.dispatch("lua")` 统一封装）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `merge(CMD)` | 7 | 把外部命令表并进内部表（同名按键覆盖） |
| `join_metrics()` | 16 | 接管 lua 分发后顺手把本服务挂到 `.metrics`（延迟 `require` 断开 `cmd_api ↔ metrics_api` 的循环依赖） |
| `M.register(CMD)` | 20 | 只登记命令表，不接管分发 |
| `M.dispatch(CMD)` | 24 | 接管 `skynet.dispatch("lua")`：按 `cmd` 找函数，未知命令 `error("Unknown command: …")`，结果 `skynet.ret(pack(f(...)))` |
| `M.dispatch_socket(CMD, SOCKET)` | 36 | 带子命令的分发版本：`f(subcmd, ...)`，用于 socket 驱动的服务 |

## `cluster_discovery.lua`（100 行，服务发现客户端）

| 方法 | 行 | 作用 | 返回 / 边界 |
| --- | --- | --- | --- |
| `M.register(services)` | 11 | 把本节点注册到这些服务名下（`send`，不等回包） | 服务未初始化直接断言失败 |
| `M.unregister(services)` | 17 | 注销 | 同上 |
| `M.shutdown()` | 23 | 停服时撤销租约，节点与服务立即从 etcd 消失 | 是否撤销成功 |
| `get_service_obj(service)` | 32 | 为某个服务建本地视图（带 `queue()` 串行化 init） | 视图对象 |
| `service_mt:ensure_init()` | 46 | 首次访问时懒初始化：向服务端 `query_service` 拉当前节点列表 | — |
| `service_mt:init()` | 52 | 拉一次节点列表并缓存 | — |
| `service_mt:update(nodes)` | 63 | 变更回调更新本地节点列表 | — |
| `M.random(service)` | 68 | 随机挑一个存活节点 | 节点名；无节点返回 `nil` |
| `M.state(service)` | 82 | 阻塞查询（必要时先做首次查询），返回 `{state, nodes, last_verified_at}` | `state` 为 `UNCONFIRMED` / `EMPTY_CONFIRMED` / `VERIFIED` |
| `M.peek(service)` | 93 | 非阻塞版本；还没成功查过 etcd 时返回 `state="UNCONFIRMED", nodes={}` | 调用方不能把空表当成"确认没有节点" |
| `M.STATE` | 38 | 发现状态常量 | — |
| `M.nodes(service)` | 121 | 当前所有节点 | 数组（内部表，勿改） |
| `on_service_change(service, nodes)` | 85 | 服务端推来的变更通知入口，转给对应视图 | — |

## `distributed_lock.lua`（189 行，基于 etcd 的实体锁）

| 方法 | 行 | 作用 | 返回 / 边界 |
| --- | --- | --- | --- |
| `M.is_valid(handle)` | 44 | 锁句柄是否仍有效：非空 + 节点租约有效 + epoch 一致 + 本地表里还是同一份 | 布尔 |
| `M.try_lock(key, value, expired_cb)` | 72 | 用节点租约的事务抢锁（`/lock/<key>`，fence = 锁键的 `create_revision`）；已持有则直接复用 | `true, handle` / `false, reason`（`"lock service closed"`、`"etcd lease unavailable"`） |
| `M.unlock(key, handle)` | 137 | 带 fence 校验的事务删除：只有 `create_revision` 仍是自己那份才删 | `true` / `false, err`；删除成功会回调 `expired_cb` 让 machine_id 重抢号 |
| `M.shutdown()` | 173 | 停止加锁并丢弃句柄，**不撤租约**（租约归 node_lease，停服由 node_shutdown 最后统一撤） | `true` |
| `notify_lock_expired(key, handle)` | 25 | 调 `handle.expired_cb`，回调抛错只记日志 | — |
| `invalidate_all(reason)` | 34 | 节点失租时清空本地锁表，逐个回调 | — |
| `parse_revision(revision)` / `parse_owner(kv)` | 52 / 61 | revision 转整数；锁值先 base64 再 JSON 解出真正的持有者（**只解 base64 会拿到带引号的字符串**） | 失败返回 `nil` |

## `dbmgr.lua`（603 行，ORM 文档缓存与回存）

核心概念：每个 `(db, coll, unique_id)` 有一把**行锁**（`queue()` + 引用计数）串行化读写；文档缓存在内存，改动由回存轮周期性 `save`；带分布式锁句柄时用 `_fence` 认领文档，`_version` 做乐观锁。

### 读写入口

| 方法 | 行 | 作用 | 返回 / 边界 |
| --- | --- | --- | --- |
| `M.load(dbname, dbcoll, key, unique_id, handle, opts)` | 283 | 取文档：命中缓存直接返回；未命中则带 fence 认领（`opts.create` 为真才允许新建） | `doc`；`nil, "not found"` / `"lease expired"` / `"stale dirty cache requires recovery"` |
| `M.save(dbname, dbcoll, key, unique_id)` | 418 | 把缓存里的脏改动写回库 | `true` / `false`（租约失效或写失败，已记日志） |
| `M.unload(dbname, dbcoll, key, unique_id)` | 429 | 落库后移出缓存与回存轮 | `true` / `false` |
| `M.discard_clean(dbname, dbcoll, unique_id, handle)` | 456 | 丢弃**不脏**的缓存条目 | 布尔 |
| `M.quarantine(dbname, dbcoll, unique_id, handle)` | 474 | 失租后把条目从回存轮摘下（止血），**保留缓存**——里面可能还有没落库的改动 | 布尔 |
| `M.discard(dbname, dbcoll, unique_id, handle)` | 487 | 彻底放弃一份写不回去的缓存；调用方必须确认改动不要了并留了记录 | 布尔 |
| `M.recover(dbname, dbcoll, key, unique_id, old_handle, new_handle)` | 512 | 失租后接管：重新认领（新 fence），`_version` 未变才把内存改动接回去 | `true`（已落库并清缓存）/ `false, "superseded"`（改动作废、缓存已清）/ 其余 `false`（可重试） |

### 内部实现

| 函数 | 行 | 作用 |
| --- | --- | --- |
| `mongo_config()` / `db_save_interval()` | 23 / 31 | 懒读 `mongo_config`；回存间隔默认 180 秒 |
| `check_collection` / `get_cache_collection` / `get_collection_obj` | 38-61 | 校验库/集合是否在配置里；取（并建）缓存表与 mongo 集合对象 |
| `with_row_lock(dbname, dbcoll, unique_id, f)` | 74 | 行锁：同一条文档的读写在 `queue()` 里串行，引用计数归零后删锁 |
| `lease_valid(handle)` | 96 | 句柄为空视为「无锁模式」，否则问 `distributed_lock.is_valid` |
| `find_and_modify(coll_obj, opts)` | 101 | 统一 findAndModify 的失败形态：网络异常、`ok ~= 1` 都算失败 |
| `matched_value(ret)` / `resolve_unclaimed(...)` | 114 / 124 | BSON `null`（驱动的 `"\0"`）不算命中；未命中时区分「不存在」「已被更高 fence 认领」「并发改 fence 该重试」 |
| `claim_with_fence(...)` | 174 | **带 fence 的查询绝不开 upsert**（会把重复 key 插出来），「不存在就建」单独走等值查询 + `$setOnInsert` |
| `save_doc(...)` | 209 | 落库前校验租约；`orm.snapshot_mongo` 取增量再 `orm.ack_mongo` |
| `sweep_save(entry)` | 248 | 回存轮的落库入口：拿到行锁后确认缓存里还是同一条，再 `save_doc` |
| `save_wheel_obj()` | 260 | 懒建回存轮 |
| `drop()` / `abort(err)` | 521 / 580 | 缓存条目摘除；schema 热重载失败时打日志并回滚 |

## `entity/entitymgr.lua`（943 行，单个实体类型的运行时）

一个 `entitymgr` 管一种实体类型：加载/卸载、分布式锁、模块与 handler 生命周期、实体定时器、可靠消息投递、失租隔离与恢复。

### 对外 API

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.new(type_name, type_config, handler, data_modules)` | 37 | 建管理器：存类型配置、handler 表、数据模块 | 管理器 |
| `M:ensure_loaded(entity_id)` | 574 | 确保实体已加载（必要时抢锁、读库、跑 `on_load`），全程在该实体的 gate 内 | `true, entity` / `false, reason` |
| `M:try_ensure_loaded(entity_id)` | 580 | 同上（历史别名） | 同上 |
| `M:with_entity(entity_id, f)` | 584 | 在实体串行队列里执行 `f(entity)`；执行后再校验一次租约 | `true, ...返回值` / `false, reason` |
| `M:with_loaded_entity(entity_id, f)` | 604 | 只对**已在内存**的实体执行，不会触发加载 | `false, M.NOT_LOADED` 或 `true, ...` |
| `M:deliver_pending(entity_id, opts)` | 659 | 投递该实体的 pending 可靠消息；`opts.loaded_only` 不触发加载 | `true` / `false, reason, owner`（锁在别人手里时 `owner` 是持锁节点） |
| `M:unload(entity_id)` | 866 | 卸载：落库 → 释放锁 → 断开客户端 → 跑 `on_unload` | 布尔 |
| `M:unload_all()` | 886 | 停服用：不再加载新实体，并发（`SHUTDOWN_CONCURRENCY`）卸载全部 | 仍留在内存的实体数 |
| `M:count()` | 876 | 当前加载数 | 数字 |
| `M:touch(entity_id)` | 923 | 刷新闲置计时（有活动就不触发卸载） | — |
| `M:get(entity_id)` | 936 | 取实体对象，**不加载** | 实体或 `nil` |
| `M.NOT_LOADED` | — | `with_loaded_entity` 的失败原因常量 | — |

### 加载与解锁的关键路径

- `_ensure_loaded`（477）：先判租约，再判 `unloading`、节点停服；抢锁成功后 `dbmgr.load` 取文档、建实体、跑 `_init_modules` + `_call_modules_on_load`。
- `_with_gate`（442）：每个实体一把 `queue()`，所有入口都经它串行化，避免「加载到一半又被卸载」。
- `_release_lock`（793）：数据已落库、缓存已清，只剩放锁。**放锁失败必须保留实体**（否则没人能再放这把锁），并安排卸载重试。
- `_unload_entity`（814）：取消投递/卸载重试定时器 → `_release_lock`；若此刻失租则踢客户端并走 `_recover_dirty`；`on_unload` 用 `xpcall` 包住，失败转 `_abort_unload`。
- `_abort_unload`（699）：钩子可能已拆了一半，实体必须继续拒绝请求、断客户端、指数退避（上限 6 次翻倍）重试卸载。
- `_recover_dirty`（710）：失租且有脏改动：先 `quarantine` 止血，再重新抢锁，交给 `dbmgr.recover` 判断改动能否接回；**无论哪条路，实体最终必须离开内存**。
- `_on_lock_expired`（460）：失租回调：取消重试、踢客户端、把实体标 `invalid` 后异步卸载。
- `_kick_client`（388） / `_forget_entity`（412）：断开客户端；清实体记录并取消所有重试。

### 模块生命周期

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M:_init_modules(entity)` | 57 | 逐个 `require`/实例化数据模块，失败即中止加载 |
| `M:_call_modules_on_load(entity)` | 75 | 逐个 `on_load`，`xpcall` 包住；任一失败返回 `false, err` |
| `M:_call_modules_on_unload(entity, only_loaded)` | 95 | 卸载钩子；`only_loaded` 只拆「`on_load` 跑完过」的模块，避免初始化失败时拆不存在的状态 |

### 实体定时器

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `entity:every(name, sec, fn)` | 276 | 周期任务；同名替换旧任务；实体卸载/失租自动停；**不延长实体寿命** | `name` 必须字符串、`sec > 0` |
| `entity:after(name, sec, fn)` | 281 | 一次性任务 | 同上 |
| `entity:cancel_timer(name)` | 285 | 取消指定任务 | — |
| `M:_arm_timer(...)` | 306 | 真正挂到 `skyext.timer` 上；触发时经 `with_loaded_entity` 进串行队列，实体不在内存则跳过 | 执行异常只记日志 |
| `M:_start_unload_timer` / `_cancel_unload_timer` | 340 / 355 | 闲置卸载计时（`resident` 类型跳过，默认 600 秒） | — |
| `M:_schedule_unload_retry` / `_cancel_unload_retry` | 371 / 362 | 卸载失败重试（指数退避，上限见常量） | — |
| `M:_schedule_delivery_retry` / `_cancel_delivery_retry` | 429 / 422 | 可靠消息投递失败后 5 秒重试 | — |

### 可靠消息投递

| 方法 | 行 | 作用 | 返回 / 边界 |
| --- | --- | --- | --- |
| `M:_deliver_one(entity, msg)` | 137 | 投一条给 handler；区分 **message_fault**（消息本身坏：无 handler、handler 抛错，要计毒消息次数）、**环境问题**（失租、落库失败，换个时间能成功，不计数）与新关键 handler 显式返回的 `delivery.retryable` | `ok, reason, message_fault, retryable` |
| `M:_quarantine(entity, msg, reason)` | 169 | 累计失败次数，到上限移入死信 | `true`（已隔离可跳过）；`false`（留在队头，整批停下重试） |
| `M:_deliver_pending_msgs(entity)` | 229 | 循环投递 pending：成功就 `mark_delivered`，环境问题就 `record_failure` 并停下 | `true` / `false, reason` |
| `M:_dead_letter_missing(entity_id)` | 625 | 实体根本不存在时，把它的 pending 整批移进死信（`dlq_replay` 可重放）；调用方必须已持 gate | 移走条数 |

## `entity/placement.lua`（121 行，实体落在哪个节点）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.service_name(type_name)` | 27 | 实体类型在服务发现里的服务名（`SERVICE_PREFIX .. type`），`entity_agentmgr` 用它注册 |
| `M.score(node, entity_id)` | 57 | HRW 打分：节点名 seed 与 `entity_id * GOLDEN` 混合后再 `mix64` |
| `M.hash(entity_id)` | 63 | 节点内选 agent 用；先打散再取模——snowflake 低位是每秒归零的序号，直接取模会让建角全挤到同一个 agent |
| `M.select(nodes, entity_id)` | 68 | 取分数最高的节点；同分取节点名小的，保证各节点算出同一结果 | 候选为空返回 `nil` |
| `M.calc_node(type_name, type_config, entity_id)` | 93 | 对外的选节点入口：优先按服务发现的存活节点算，服务发现不可用时**回退到类型配置里的 `nodes`**并告警 | `entity_id` 必须是整数 |
| `node_seed` / `mix64` / `discovery` / `live_nodes` | 37-80 | FNV seed、splitmix64 收尾混合、服务发现单例、存活节点查询 |

## `entity/reliable_msg.lua`（435 行，至少一次投递）

| 方法 | 行 | 作用 | 返回 / 边界 |
| --- | --- | --- | --- |
| `M.max_attempts()` | 72 | 读 `reliable_msg_max_attempts`，非法值回退默认并告警 | 整数 |
| `M.next_seq(target_type, target_id)` | 108 | 按 `(type, id)` 维度原子分配自增序号（`$inc` + upsert） | 序号；失败 `error` |
| `M.save(target_type, target_id, cmd, args)` | 127 | 持久化一条消息（先落库再投递） | `msg_id, seq`；失败抛错，调用方不得当成已持久化 |
| `M.load_pending(target_type, target_id, opts)` | 172 | 按 `seq` 升序读 pending，用 `seq > after_seq` 的 keyset 分页（并发 ack/插入不漏读不重读） | 消息数组 |
| `M.mark_delivered(msg_id)` | 275 | ack 一条消息，只在 handler 成功后调用；**幂等** | `true`（首次）/ `false, "already_delivered"` |
| `M.record_failure(msg_id, err)` | 295 | `attempts + 1` 并记最后错误；只对 pending 生效 | 新 `attempts`；失败 `nil, reason` |
| `M.mark_dead(msg_id, reason)` | 326 | 移入死信队列 | `false, "not_pending"` 表示已是终态 |
| `M.replay(msg_id)` | 349 | 死信重放：状态回 pending、次数清零 | `doc`；`nil, "not_dead"` |
| `M.discard(msg_id, operator)` | 370 | 丢弃死信（保留文档供追查） | `false, "not_dead"` |
| `M.list_dead(opts)` | 388 | 列死信，可按 `target_type`/`target_id` 过滤 | 数组；`limit` 必须为正 |
| `M.get(msg_id)` | 408 | 取一条消息文档 | 文档或 `nil` |
| `M.ensure_indexes()` | 413 | 建索引（幂等，启动时调） | `M` |
| `modified_doc(ret)` / `transition(...)` | 244 / 259 | 统一 findAndModify 回包形态（BSON `null` = 未命中）；状态迁移只改 `from_status` 的消息，天然幂等 | — |
| `msg_coll` / `seq_coll` / `seq_key` | 94-102 | 消息集合、序号集合、序号键 |

## `entity/router.lua`（109 行，实体调用门面）

| 方法 | 行 | 作用 | 返回 / 边界 |
| --- | --- | --- | --- |
| `M.call(type_name, entity_id, cmd, ...)` | 26 | 同步调实体 handler | `true, ...返回值` / `false, reason`（实体不可用，handler 没执行）；handler 抛错或节点不可达照常抛错 |
| `M.call_loaded(type_name, entity_id, cmd, ...)` | 35 | 只对已在内存的实体执行，**绝不触发加载**；实体不在返回 `false, reason` | 非关键读/广播用 |
| `M.send(type_name, entity_id, cmd, ...)` | 48 | 单向投递，不等结果 | — |
| `M.send_loaded(type_name, entity_id, cmd, ...)` | 57 | 只对已在内存的实体**单向**发消息，实体不在直接丢弃，不加载、不阻塞 | 广播/状态推送用 |
| `M.poke_reliable(type_name, entity_id)` | 67 | 唤醒目标去读自己的 pending 消息；失败不代表丢消息（已落库） | 是否成功投出唤醒 |
| `M.bind_session(type_name, entity_id, conn_id, session_mode)` | 59 | 登录时把网关会话绑到实体；网关与实体不必同节点 | 错误码、续接凭据、`session_epoch`、模式 |
| `M.resume_session(type_name, entity_id, conn_id, nonce, recv, session_mode, session_epoch)` | 72 | 续接：**只作用于已在内存的实体**，不验 token、不查库、不抢锁 | 错误码、新凭据、已发包数、`session_epoch`、模式 |
| `M.scoped_call(type_name, value, cmd, ...)` | 80 | 作用域实体便捷入口，ID 由 `types.scoped_id` 算出 | 同 `call` |
| `M.scoped_send(type_name, value, cmd, ...)` | 84 | 同上，单向 | — |
| `M.reliable_send(type_name, entity_id, cmd, args)` | 88 | 可靠消息：落库后尝试立即投递，失败留给加载/重试定时器 | `msg_id` |
| `self_node()` / `get_target(...)` | 10 / 17 | 本节点名；目标节点 + agent 服务名 | — |

## `entity/session.lua`（484 行，实体侧会话）

概念：一个实体一份 **`session_io`**（`nonce`、下行计数 `sent`/`acked`、重放缓冲 `out_buf`、上行幂等缓存 `resp_cache`），连接（`conn`）可以换，`session_io` 跟着实体活到卸载。

### 字段（`new_session_io` 的成员）

| 字段 | 行 | 含义 |
| --- | --- | --- |
| `nonce` | 85 | 续接凭据，每次 resume 轮换 |
| `sent` / `acked` | 88 / 89 | 下行已发 / 客户端已确认；**不上线**，两端各自数，只在 resume/ping 对账 |
| `out_buf` / `out_bytes` | 90 / 91 | 重放缓冲（按 seq 存已编码的包） |
| `resp_cache` / `resp_order` / `resp_bytes` / `min_cached_req_id` | 94-97 | 上行幂等：key 是客户端 request id，value 是 `{ pack, name }`；超预算淘汰最旧 |
| `last_seen` / `unresumable` / `replaying` | 98-100 | 空闲判定、重放缓冲撑爆后的降级标记、重放中标记 |

### 绑定与续接

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.bind(gate_node, gate_service, fd, entity, owner_service)` | 210 | 完整登录：重建 `session_io`、绑连接、让网关把后续包转给本服务 | 网关侧连接已断返回 `false`；**必须无条件重建 session_io**——顶号/重登沿用旧的会让后来者继承前一个客户端的 nonce、计数和回包缓存 |
| `M.resume(gate_node, gate_service, fd, entity, owner_service, nonce, recv)` | 224 | 把会话热替换到新连接：校验 nonce、校验 `recv` 在 `[acked, sent]` 内、轮换 nonce | `errcode.RESUME_UNAVAILABLE` / `AUTH_FAILED` / `SESSION_CLOSED`；成功返回新凭据与 `sent` |
| `M.replay(entity)` | 253 | 重放客户端还没收到的包，然后解除 `replaying`；**必须在 `on_resume_client` 之前**调用（回调里业务推的新包要排在旧包后） | 缓冲有洞就踢客户端并返回 `false` |
| `M.ack(entity, recv)` | 293 | 客户端确认收到 `recv` 个包，裁剪 `out_buf` | 越界只告警不动 |
| `M.unbind(key)` | 315 | 解绑（登录成功移交、断连都走） | — |
| `M.kick(key)` | 334 | 断开连接；`on_unbind_client` 由网关的断开通知触发 | — |
| `M.unbind_kick(key, expected_entity)` | 342 | 只在会话仍属于 `expected_entity` 时解绑并踢，防止误踢换绑后的新会话 | 布尔 |
| `M.sweep_idle()` | 362 | 空闲超时：超 `session_idle_timeout`（默认 60 秒 = 4 次心跳）断开连接，`session_io` 保留可续接 | — |
| `M.get_entity(key)` / `M.get_obj(key)` / `M.is_online(entity)` | 373 / 378 / 386 | 会话键 → 实体；协议 handler 的 `obj`；是否在线 | — |

### 下发与上行

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.with_request(key, f, req_id, request_name, request_digest)` | 513 | 在实体串行队列里执行协议函数，顺带上行幂等：同 `req_id` 且协议名、32 字节参数摘要都相同才回缓存；协议名或参数不同返回 `REQUEST_CONFLICT`，旧格式条目或缓存已淘汰返回 `REQUEST_EXPIRED` | `true, ...` 或 `false, reason, code`（被拒绝时 `f` 没执行） |
| `M.push(entity, name, msg)` | 463 | 给实体自己的客户端推消息；返回「有没有写到网关」，不在线时包已进重放缓冲不算丢 | 布尔 |
| `M.reject_client(key, reason)` | 456 | 错误码无法通过协议回给客户端时的兜底：断开连接让客户端重连 | — |
| `M.cmds.ping(request, _, obj)` | 475 | `ping` 回 `{ sent = 已发包数 }` | — |
| `record_and_send(entity, pack)` | 144 | **下行唯一收口**：计数、入重放缓冲、在线才写网关；绕过它写客户端会让两端计数失同步 | — |
| `sender(key, pack, request_name)` | 168 | `sproto_api` 的发送端（会话键 + 可选协议名） | — |
| `drop_replay` / `evict_oldest_response` / `cache_response` | 105-128 | 重放缓冲撑爆后降级为不可续接；幂等缓存按预算淘汰 | — |
| `gate_send` / `gate_call` / `kick_conn` / `install_conn` | 59-190 | 网关同节点 `skynet.call/send`，跨节点 `cluster.call/send`；装连接对象 | — |
| `M.key(gate_node, fd)` | 55 | 会话键 = `节点名/fd` | 字符串 |

## `entity/types.lua`（95 行，实体类型表）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.get(type_name)` | 21 | 取类型配置 | 未知类型 `error` |
| `M.all()` | 30 | 全部类型 | 内部表 |
| `M.calc_node(type_name, entity_id)` | 35 | 委托 `placement.calc_node` | — |
| `M.calc_agent_index(type_name, entity_id)` | 39 | 节点内 agent 序号 = `placement.hash(id) % agent_count + 1` | — |
| `M.key_id(key)` | 50 | 字符串键确定性算 ID（FNV），任何节点算出同一个；给按名字寻址的实体（每 game 一份排行榜）用 | 正整数 |
| `M.scoped_id(type_name, value)` | 65 | 作用域实体在某个 scope 值上的 ID，如 `scoped_id("rank", "game1")` | 类型没配 scope 直接断言 |
| `M.preload_ids(type_name)` | 75 | 要预加载的 ID：scope 类型按区服目录这一层全部取值生成（新 game 自动加入），`preload` 列表整数原样、字符串走 `key_id` | 数组 |
| `M.format_agent_service_name(type_name, index)` | 91 | `.entity_agent:<type>:<index>` 服务名 | 字符串 |
| `ensure_loaded()` | 8 | 懒读 `entity_types` 配置并建表 | 缺配置 `error` |

## `errcode.lua`（37 行）

引擎错误码常量：`OK=0`、`IN_OTHER_NODE=2`、`LOCK_FAILED=4`、`DB_ERROR=6`、`PARAM_ERROR=10`、`AUTH_FAILED=11`；实体系统 `ENTITY_NOT_FOUND=20`、`ENTITY_LOCK_FAILED=21`、`ENTITY_LOAD_FAILED=22`、`SESSION_CLOSED=23`、`RESUME_UNAVAILABLE=24`（重放缓冲溢出/计数越界/未启用会话层，客户端应重走 login 而非重试 resume）、`REQUEST_EXPIRED=25`（幂等缓存的响应已被淘汰，不重新执行）、`REQUEST_CONFLICT=26`（同一 request id 上次是另一条协议，续接不重建会话时最容易撞上）、`MONGO_DUPLICATE_KEY=11000`。
表上挂了 `__index` 兜底：**取不存在的错误码直接 `error("Invalid error code: …")`**，避免拼错名字静默得到 `nil`。
