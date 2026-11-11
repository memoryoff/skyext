# 09 · `service/` 引擎服务

> 覆盖 `service/` 下 25 个非测试服务（`logger/` 目录 8 个文件里含 2 个 `*.test.lua`，测试文件不逐条展开）。
> 第二列是源码起始行号。「CMD.xxx」表示服务协议里的命令，调用方是 `skynet.call(addr, "lua", "xxx", ...)`。

## `cluster_discovery.lua`（693 行，节点与服务发现）

**核心约定：节点键与服务键都挂在 `node_lease` 的节点级租约上，本服务不再自己申请租约。** 从前锁和服务发现各有一个租约时，锁的没了而发现服务还在，本节点会留在 etcd 的服务列表里继续被路由进来、但每个实体都加不上锁——对外存活、对内全拒，还不会自动摘除。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.register(services)` | 628 | 把本节点登记为若干服务的提供者 | — |
| `CMD.unregister(services)` | 640 | 摘掉 | — |
| `CMD.query_service(service)` | 665 | 返回该服务当前在线节点列表（按节点名排序） | — |
| `CMD.shutdown()` | 656 | 停心跳，之后不再注册。**不撤租约**：租约是节点级的，本节点别的服务还挂在上面；真正的键消失发生在 `node_shutdown` 最后撤销节点租约时 | — |
| `leaseid()` | 58 | 取当前租约；`g_closed` 或租约无效时返回 `nil` | — |
| `etcd_register_node` / `etcd_do_register_node` | 138 / 88 | `setnx` 写节点键（带租约），成功记 `mod_revision` | 返回 `revision` |
| `claim_existing_node(node_info)` | 112 | `setnx` 失败（键已存在）的两种处理：**键是本节点上一次注册写的**（写成功但响应丢在路上）→ 认领它的 `mod_revision`；**键属于本节点上一个进程实例、但租约未过期** → 撤销它腾位置；地址不同则记 `node address conflict` 失败 | `revision, revoked` |
| `etcd_update_node(node_info, node_revision)` | 164 | 带 `mod_revision` 的条件更新（CAS） | 失败返 `nil, err` |
| `init_node_revision()` | 265 | 有 revision 就 update，否则 register | — |
| `sync_service()` | 285 | 按 `services` 表决定注册还是摘除 | — |
| `on_lease_lost(_, reason)` | 250 | 租约丢了：节点键与服务键已被 etcd 删掉，本地「已同步」记账全作废，下一拍心跳用新租约从头注册 | — |
| `watch_node()` / `ensure_watch_node()` | 362 / 411 | 从 `revision + 1` 起 `watchdir` 增量更新节点表；watch 循环异常/结束时退避重连 | — |
| `etcd_query_all_nodes` / `first_query_nodes` / `cluster_reload_nodes` | 308-348 | 全量读 `readdir`，记 etcd revision 作为 watch 起点 | — |
| `service_mt:ensure_init/init/first_query/watch/update_node/delete_node/update_revision/get_nodes` | 453-623 | 每个被查询的服务懒初始化：`queue()` 串行化首次访问、先全量再 watch；`update_node` 拒绝 `node_revision` 比本地旧的更新（乱序事件） | `init` 置位 `inited`，否则每次 `ensure_init` 都会重复 fork watch 循环、每条都持有 1 条 etcd watch 长连接不释放 |
| `cluster_listen` / `node_name` / `get_self_node_info` / `etcd_make_service_key` | 46-256 | 监听端口/地址、节点名（`cluster_node_name` 必须配置）、服务键格式 `prefix/service/node` | — |

## `entity_agent.lua`（353 行，实体执行单元）

一个 `entity_agent:<类型>:<序号>` 服务持有该类型的若干实体；实体归属由 `distributed_lock` 决定。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.entity_call(entity_id, cmd, ...)` | 116 | 调用实体方法：先本地执行，锁在别的节点时转发过去 | 返回 `true, 返回值...` 或 `false, reason`（handler 没执行）；**handler 抛错照常抛给调用方** |
| `CMD.entity_call_loaded(entity_id, cmd, ...)` | 134 | 持锁节点上执行转发来的请求：**只用已加载的实体，绝不为它加载** | — |
| `CMD.entity_send(entity_id, cmd, ...)` | 142 | 同 `entity_call` 但不需要结果（handler 错误只记日志） | 未知命令记 error 后返回 |
| `CMD.__deliver_reliable(entity_id)` | 163 | 补投可靠消息（本地或转发） | — |
| `CMD.deliver_reliable_loaded(entity_id)` | 183 | 只在已加载实体上补投 | — |
| `CMD.activate(entity_id)` | 188 | 主动加载（常驻实体预加载用） | `true` / `false, reason` |
| `CMD.unload_entity(entity_id)` | 193 | 卸载 | — |
| `CMD.bind_session(entity_id, conn_id, session_mode)` | 211 | 登录：绑定会话并返回续接凭据 `nonce`、`session_epoch`、模式。`conn_id` 必须是合法的 ConnectionIdentity v1，非法值返回 `PARAM_ERROR` | 实体被别的节点持有时**向它要一次**（`unload_entity` 顺带踢掉旧连接）；错误码区分 `ENTITY_NOT_FOUND` / `LOCK_FAILED` / `IN_OTHER_NODE` / `SESSION_CLOSED` |
| `CMD.resume_session(entity_id, conn_id, nonce, recv, session_mode, session_epoch)` | 253 | 断线续接 | **绝不加载实体**：续接不验 token、不查库，能触发加载就等于开放一个无认证接口。返回 `RESUME_UNAVAILABLE` 表示状态已不存在 |
| `CMD.client_msg(conn_id, data)` | 281 | gate 转来的上行包；`conn_id` 非法时丢弃 | — |
| `CMD.session_closed(conn_id)` | 289 | gate 上的连接断开；`conn_id` 非法时丢弃 | — |
| `CMD.shutdown()` | 200 | 停服：不再加载、卸载全部；返回没卸掉的数量（可再调一次） | 卸干净后本服务不再加锁；锁键消失同样推迟到撤节点租约 |
| `CMD.start(conf)` | 308 | 起服务、注册名字、按 `client_enabled` 装协议模块 | 模块 `request` 必须返回表，否则断言失败 |
| `sticky(entity_id, run_local, forward_cmd, args)` | 84 | 本地失败且锁在别处 → 转发；转发回来 `NOT_LOADED` 表示对方没执行，可回本地再试 | **转发本身抛错时不能重试**：分不清是没送到还是对方执行到一半出错 |
| `request_handoff` / `remote_holder` / `agent_name` / `self_service_name` / `handler_of` | 38-116 | 要回实体（只试一次，成员视图分歧时无限重试会变成互抢）；取持锁节点（是本节点名说明租约未过期，只能等）；名字格式；命令表 | 未知命令 `error` |

## `entity_agentmgr.lua`（260 行，实体类型管理器）

每类型一个 `.entity_agentmgr:<type>`，负责拉起 N 个 `entity_agent` 并管预加载。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.start()` | 140 | 按 `agent_count` 建全部 agent、起 `entity_dlq`、触发预加载 | 返回成功即本节点该类型就绪；失败 `error` |
| `CMD.shutdown(timeout_sec)` | 215 | 先从服务发现摘自己（路由移走）→ 卸载全部实体（落库、释放锁、断客户端）→ 失败每秒重试到超时 | 返回剩余数，`0` 表示可安全退出进程 |
| `CMD.is_ready()` / `CMD.agents()` | 241 / 245 | 就绪标志 / agent 地址列表（拷贝） | — |
| `discover_modules(modules_path, start_name)` | 23 | 扫模块目录：有 `init.lua` 或 `request.lua` 的子目录即为模块，按名排序 | 路径按 `game_root` 解析 |
| `reconcile_preload()` | 112 | 预加载：`scope` 类型按作用域取值批量、`preload` 列出单个；逐个 `activate` | 失败 `lock held` 记 warn 延后，其它记 error |
| `create_agents` / `shutdown_agents` / `wakeup_waiters` / `wait_starting` | 71-187 | 建 agent 并串行 `start`；停服时并行卸载并收集剩余数 | agent 之间并行，主协程等全部回 | 

## `entity_dlq.lua`（173 行，死信队列查询）

GM 侧只读接口，读 `entity_dlq` 集合里的死信记录。

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `brief(doc)` | 53 | 列表项：`msg_id`/`seq`/`target_type`/`target_id`/`cmd`/`attempts`/`create_time`/`dead_time`/`dead_reason` |
| `desc` / `params` / `handler` | 70-77 | 单条详情视图（含 `params`、`target_*`、`limit`） |
| `to_msg_id` / `to_target_id` / `to_limit` | 22-41 | 参数来自 HTTP query/body，**全是字符串**：`msg_id` 必须能转整数，`target_id` 能转整数就当数字 ID、否则按字符串 key 处理 |

列表视图**不回 `args`**：那是业务负载，可能含玩家数据，不该经 GM 接口整份吐出来。

## `gate_tcp.lua`（152 行） / `gate_ws.lua`（202 行）

两者结构一致，只是传输不同。会话未绑定时上行包交给登录服务，绑上之后原样转给 owner。

| 方法 | 行（tcp / ws） | 作用 |
| --- | --- | --- |
| `handler.open(_, conf)` / `CMD.open(conf)` | 49 / 120 | 起监听；`conf.login` 必填。WS 侧还要校验 `protocol` 是 `ws`/`wss`，`wss` 需要 `enablessl = true` 且证书/私钥可配 |
| `handler.connect(fd, addr)` / `serve` | 54 / 105 | 新连接 → `login.open(fd, addr, gate名)` |
| `handler.message` | 60 / 72 | 拆包后 `login.client_msg`；WS 侧只收二进制帧（文本帧记 warn 丢弃） |
| `handler.disconnect` / `handler.close` | 87 / 91 | 通知 `login.disconnect(fd)` |
| `CMD.bind(fd, owner_node, owner_service)` | 103 / 154 | 绑定到实体；会话已断开返回 `false` |
| `CMD.push(fd, pack)` | 113 / 164 | 发已编码的包。TCP 加长度头，**WS 帧自带边界不加头** |
| `CMD.kick(fd)` | 122 / 176 | 断开；断开回调照常走（未绑定通知登录服务，已绑定通知 owner） |
| `CMD.count()` | 128 / 182 | 在线连接数 |
| `CMD.close()` | — / 187 | 停服第一步：关监听、不再接新连接，已建连接继续服务到实体卸载 |
| `send_owner` | 34 / 42 | 本节点直接 `send`，跨节点 `cluster.send`（失败只 warn——断线由另一侧感知） |
| `handler.warning` | 96 / 101 | 发送缓冲积压告警；**WS 这个回调第一个参数是 ws 对象而不是 fd**（`websocket.lua` 历史遗留） |

## `gm.lua`（386 行，GM 指令总线）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.register_commands(service_address, commands)` | 103 | 批量注册：`{ {cmd_name, handler_name, desc, params}, … }`；同名命令追加服务、描述/参数变更记 warn | 返回 `success_count`、`failed_commands` |
| `CMD.unregister_service(service_address)` | 136 | 摘掉该服务的全部命令 | — |
| `CMD.list_commands(cred)` | 215 | 列出全部命令（名、描述、参数、所在服务） | 先 `authenticate` |
| `CMD.execute_command(cred, cmd_name, params, target_services)` | 273 | 执行；`target_services` 可指定服务（整数地址 / 名字 / `":01000002"` 十六进制） | 命令不存在回 `{code, error, cmd}`；多服务结果汇总成功/失败 |
| `authenticate(cred)` | 196 | `cred` 为 `nil` 表示进程内调用直接放行；否则按 `gm_auth_token` 校验 | 失败返回 `nil, {code = AUTH_FAILED, error}` |
| `secure_equal(a, b)` | 183 | **定长比较**：逐字节比完再判等，不让对方从「第几个字节开始不一样」试出 token | — |
| `gm_token()` | 170 | token 不可用（未配置/占位/过弱）时**整个 GM 接口禁用**并记 error | — |
| `parse_service_address(service)` | 243 | 整数直接返回；字符串按名字（补前导点）/十六进制解析 | 失败 `nil` |

## `gm_sys.lua`（460 行，系统级 GM 命令）

在 skynet 自带 GM 命令（`LIST`/`STAT`/`KILL`/`TRACELOG` 等）基础上补引擎侧命令，并把 `.launcher` 的统计转成可读形式。

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `adjust_address(address)` | 12 | 名字 → 地址；十六进制 + 当前 harbor 拼完整地址 |
| `bytes(size)` / `time(t)` / `timeout(ti)` | 22-47 | 统计格式化（`K`/`M`、`1/100 秒`、`h:mm:ss`）；`timeout` 默认 300（3 秒） |
| `convert_stat(info)` | 47 | `.launcher` LIST/STAT 转可读结构 |
| `toboolean(x)` | 378 / 421 | `"true"`/`"on"` 为真（两处同名内部函数，各管一组合令） |

命令覆盖：`dumpheap`（`memory.dumpheap`）、heap profiling 开关、`getenv`/`setenv`、`TRACELOG` 透传等。

## `hotfix.lua`（778 行，热更执行器）

**本册最大的文件。** 流程：加锁 → 读配置 → 校验 checksum → 按步骤执行（清缓存 / 重载配表 / 重载协议 / 重载 ORM schema / 注入代码）→ 清理。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `execute_hotfix(hotfix_dir)` | 486 | 主流程 | 已有热更在跑时拒绝（锁超过阈值视为陈旧锁，强制释放并 warn）；`build_version` 与 `gitsha_base` 不一致只 warn |
| `dry_run_hotfix(hotfix_dir)` | 647 | 只演练：读配置、校验、列出将执行的步骤，不真跑 | 失败返回 `step` 与 `error` |
| `load_hotfix_config(hotfix_dir)` | 156 | 读并执行 `hotfix.conf.lua` | 读不到/编不过/没返回表都返 `false, 原因` |
| `verify_checksum(config, hotfix_dir, root_dir)` | 192 | 校验文件 checksum | `ok, err` |
| `clear_lua_cache()` / `reload_res()` / `reload_sproto()` / `reload_orm_schema()` | 201-243 | 四个可选步骤，各自调对应服务 | 失败带原因 |
| `inject_code_files(code_files, hotfix_dir, fail_fast)` | 403 | 逐个补丁文件注入 | `fail_fast`（配置 `fail_fast ~= false` 才有）控制遇错是否继续；结果逐条记录 |
| `inject_to_service(service_addr, hotfix_code, filename)` | 384 | 把代码包进模板，走 `debug` 的 `RUN` 执行 | `true, output` / `false, 原因` |
| `call_with_timeout(addr, protocol, cmd, timeout_sec, ...)` | 352 | 带超时的调用（`INJECT_TIMEOUT`） | 超时后不再等待该结果 |
| `parse_patcher_targets(code_file_path)` | 282 | 读补丁文件里的 `targets`（服务名列表） | 没 `targets` 字段即失败 |
| `make_patcher_sandbox()` | 270 | 补丁文件执行用的沙箱环境：**顶层访问全局变量直接报错** | — |
| `find_service_address` / `find_service_addresses` | 101 / 116 | 服务名 → 地址；通配符**只支持 `.entity_agent:<类型>:*`**，按该类型的 `agent_count` 展开成 `:1…:N` | 任意前缀匹配做不到（skynet 没有枚举注册名的接口）；**任何一个 agent 查不到就整条失败**，不能只给一部分打补丁 |
| `record_step` / `persist_history` / `load_history` / `cleanup` | 503-514 | 步骤记录；`hotfix_history.jsonl` 追加与加载（最多保留 `MAX_HISTORY` 条）；释放锁 | 历史文件读/写失败只 warn |

## `metrics.lua`（189 行，指标聚合服务）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.register_service(addr)` / `CMD.unregister_service(addr)` | 141 / 149 | 服务注册/注销（各服务在 `metrics_api.ensure_registered` 里调） | — |
| `CMD.gather()` | 155 | 合并后的快照，给要自己处理数据的调用方 | — |
| `CMD.render()` | 160 | Prometheus 文本；同时注册成 GM 命令 `metrics` | — |
| `scrape()` | 79 | 拍一轮：用 `skynet.request` **并发**扇出所有已注册服务的 `collect_metrics`，超时（`metrics_scrape_timeout`，默认 300 = 3 秒）的服务丢弃并 warn，累加 `skyext_metrics_services` gauge | — |
| `service_names()` | 49 | 地址 → 服务名：读 `.launcher` 的 `LIST`（只读它自己的表，不扇出，很便宜） | 失败回空表 |
| `parse_service_name(desc)` | 36 | 从描述取服务名并**抹掉实例编号**（`mongo_conn:center:1`、`http_agent_gm_2` → 归一名）。不归一的话 8 个 mongo_conn 就是 8 条曲线，一扩容时间序列就跟着涨 | — |
| `collect_runtime(acc, name, runtime)` | 64 | 把 `mqlen`/`cpu`/`message`/`memory` 记成 `skyext_service_*` | — |
| HTTP 监听 | — | `metrics_http_host` 默认 `127.0.0.1`、`metrics_http_port` 默认 `9091` | — |

## `mongo_conn.lua`（109 行，Mongo 存储服务）

`mongo_conn:<db>:<i>` 每个连接一个服务，`lualib/skyext/mongo_conn.lua` 的客户端对象把调用透传过来。

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `CMD.find_one` / `CMD.find` | 82 / 36 | 查一条 / 查游标全部 |
| `CMD.find_many(coll, doc, opts)` | 48 | `opts = { projection, sort, skip, limit }`；`sort` 支持单表与数组两种写法 |
| `CMD.find_and_modify` | 31 | 原子改并返回 |
| `CMD.create_index` | 74 | 建索引（`options` 可选） |
| `CMD.raw_safe_insert` / `CMD.raw_safe_update` | 90 / 95 | 接收**已编码好的 bson 串**（客户端侧先 `bson_encode`，避免跨服务传大表） |
| `CMD.safe_delete(coll, query, single)` | 101 | 删除 |
| `init_db(dbname)` | 21 | 按 `mongo_config[dbname].cfg` 建 mongo client | 未配置直接断言失败 |

## `mongo_index.lua`（39 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `CMD.create_indexes()` | 9 | 遍历 `mongo_config` 里每个库的 `collections[x].indexes` 逐个 `createIndex`，幂等；失败记 error 继续下一条 |

## `node_lease.lua`（179 行，节点租约服务）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.get()` | 141 | 租约快照 `{leaseid, epoch, deadline}`；消费者在自己 `skynet.init` 里同步取一次，之后靠事件更新 | 无效返回 `nil` |
| `CMD.shutdown()` | 151 | 主动撤销租约：锁键、节点键、服务键立刻从 etcd 消失 | **不发 `lease_lost`**：那个事件语义是「失租」，`machine_id` 会据此重新抢号 |
| `grant_lease()` | 66 | `grant(TTL)` 新建租约，`epoch + 1` | 失败返回 `false` 下拍重试 |
| `keepalive()` | 84 | 续租，成功把 `deadline` 往后推 | `ok=false, fatal=true` 表示 etcd 明确说租约没了，不必等宽限期 |
| `heartbeat()` | 118 | 心跳循环：fatal 或超宽限期 → `lose_lease`；否则容忍瞬时失败（deadline 未到）；无租约时重 grant | — |
| `lease_valid()` | 55 | 有效？**被问到时就地判超时**（宽限期已过立刻判失效并触发 `lose_lease`） | 布尔 |
| `publish_alive()` / `lose_lease(reason)` | 43 / 47 | 通过 `event_channel_api` 发 `lease_alive` / `lease_lost`（带 `epoch`） | — |

## `node_shutdown.lua`（141 行，停服编排）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.shutdown(timeout_sec)` | 119 | 开始停服：立即返回、`fork` 后台跑 | 已在停服中返回 `false, "already shutting down"`；GM 命令 `shutdown` 默认 60 秒 |
| `shutdown(timeout_sec)` | 79 | 顺序：`stop_accepting` 钩子 → 卸载全部实体（并行、带超时）→ `release` 钩子 → `cluster_discovery.shutdown` → `node_lease.shutdown`（撤租约，键随之消失） | 实体没卸干净就**不继续**，记 error 并保进程存活 |
| `CMD.add_hook(phase, addr, cmd)` | 106 | 注册钩子；同一 `(phase, addr, cmd)` 只记一次，按注册顺序执行 | 未知 phase 断言失败；`cmd` 必须非空串 |
| `run_hooks(phase)` / `entity_managers()` / `unload_entities` / `count` | 25-64 | 逐个 `pcall` 调钩子（失败只 warn）；只查本节点真的起了的 `entity_agentmgr`；并行卸载并汇总剩余数；**不知道剩多少时至少算一个**，免得误以为卸干净 | — |

两个阶段的分工：`stop_accepting` 在卸载实体**之前**（先关 gate/HTTP 入口），`release` 在实体全部落库**之后**。

## `realm.lua`（313 行，区服目录服务）

etcd 里的目录树（`server` / `game` / `zone` / `gate` 四类键），其余节点靠 watch 得到同一份视图。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.snapshot()` | 153 | 当前目录（含 `revision`），`lualib/skyext/realm.lua` 的懒加载取的就是它 | — |
| `CMD.register_gate(info)` / `CMD.unregister_gate()` | 185 / 202 | 网关节点上报/撤销自己的客户端接入地址。`gate_tcp` 与 `gate_ws` 合成**一条节点级记录**，所以是增量合并而不是整体覆盖 | — |
| `load_all()` / `watch()` / `ensure_watch()` / `apply_events(events)` | 62-141 | 全量读 `readdir` 记 revision → 从 `revision + 1` watch 增量；watch 断开退避重试；未知键只 warn | — |
| `apply_seed()` | 85 | 目录空且配置有 `realm_seed` 时写种子：**逐条 `setnx`**，多节点同时启动也不互相覆盖；目录已有数据就完全不碰 | — |
| `sync_gate()` | 163 | 网关键挂在节点租约上：进程没了键跟着没，客户端不会被引导到死网关。代价是**租约换代后键也没了**，所以这是「没同步上就重试」的定时任务而不是写一次了事 | — |
| `on_lease_lost` | 178 | 租约丢了，网关键已被 etcd 删掉，下一拍重注册 | — |
| `put(kind, name, value)` / `valid_name(name)` | 219 / 227 | 写目录项；名字只允许 `[%w_-]` | 失败返 `false, 原因` |
| `parse_key(key)` / `empty_dir()` / `publish` | 34-58 | 键拆成 `字段/名字`；空目录；变更通知 | — |

开服/建游戏类 GM 命令的校验：`server` 与 `game` 必填、`server` 不能已存在、**新 `game` 需要已存在的 `zone`**。

## `skytest_cov.lua`（279 行，覆盖率汇总服务）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `CMD.REPORT(source_stats)` | 151 | 各服务退出前把统计送上来 |
| `CMD.DUMP()` | 155 | 集中统计 + 覆盖率百分比（`%.1f%%`，无数据 `N/A`） |
| `CMD.STATUS()` | 192 | 文件数、行数、明细 |
| `CMD.RESET()` / `CMD.FLUSH()` | 207 / 212 | 清零 / 立即落盘 |
| `collect_from_all()` | 40 | 向所有 snlua 服务发 `debug` 的 `SKYTEST_COV_DUMP`（`list_snlua_services` 用 `.launcher` LIST 枚举） | 单个服务失败只记 error |
| `apply_filters(stats)` / `build_report_stats()` | 61 / 76 | 按 include/exclude 过滤；**有命中但不在基线的文件/行只 warn 并忽略**（分母不由命中决定） | 诊断输出 `unknown_sources` / `orphan_lines` |
| `save_stats()` | 112 | 写 `coverage_<时间戳>_<随机>.info`（lcov 格式），返回路径 | 写不进记 error |
| `auto_flush()` / `__gc` | 260 / 221 | 定时落盘；进程回收时兜底落一次 | — |

## `skytest_runner.lua`（24 行）

测试子进程的入口壳：初始化环境后调 `lualib/skytest/runner.lua` 的 `run_file`，用返回码退出。

## `sproto_loader.lua`（86 行，协议 schema 加载）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.load_proto(schema_path, proto_index)` | 61 | 加载/重载 spb：读文件 → `md5.sumhexa` 与当前比对，变了才重解析 | `false, errmsg` |
| `load_sproto_schema(proto, reload)` | 19 | 实际加载：`sproto` 解析后按 `proto_index` 存 | 读不到/解析失败带原因 |
| `readfile(path)` | 12 | 读整个文件 | — |

## `logger/`（8 个文件）

日志服务的分层：`main` 是入口壳，`start` 换掉消息分发把 log 协议的消息直接投进 bucket，`global` 存全局对象，`bucket` 管写入后端，`checker` 做过载保护，`cmd` 是对外命令。

| 文件 | 行 | 关键点 |
| --- | --- | --- |
| `logger/main.lua` | 17 | 服务入口，起 `start` |
| `logger/start.lua` | 83 | `logger_dispatch_callback(prototype, msg, sz, session, source)`(52)：**拦下 `log` 与 `log-err` 两个协议号**（`skyext.ptype`），解包后 `global.bucket:put(record)`，其它协议照常 `skynet.dispatch_message`；`start_func()`(68)：读 `log_config`、注册 `.logger`、`skynet.init_service` 初始化 bucket |
| `logger/global.lua` | 6 | 全局对象（`bucket` 的挂载点） |
| `logger/bucket.lua` | 73 | `bucket_mt:put(record)`(8)：写一条，过载时直接丢；`init(config)`(30)：按配置 `bucket.new`（默认 bucket = `console`，见 `lualib/skyext/log/bucket/init.lua:25`），重复 init 断言失败；`reload()`(47) / `close()`(55)；`M.new(config)`(65) |
| `logger/checker.lua` | 49 | `check_mqlen()`(18)：`skynet.mqlen()` 超过 `log_overload_mqlen`（默认 `1000000`）就打开过载开关；`check_bucket()`(33)：bucket 报错时重载；`skynet.init` 里起 `HEARTBEAT_INTERVAL` 周期心跳 |
| `logger/cmd.lua` | 20 | `M.put(record)`(6) / `M.close()`(10) / `M.reload()`(15)：返回 `skynet.self()`，供外部 `skynet.call` 到 `.logger` |
| `logger/bucket.test.lua`、`logger/checker.test.lua` | — | 单测，跑在独立 skynet 进程里 |
