# 04 · 指标、Mongo、节点租约、区服目录、配表与工具库

> 覆盖 `lualib/skyext/` 下的 `metrics*.lua`、`mongo_conn.lua`、`node_lease.lua`、`node_shutdown_api.lua`、`orm_compat.lua`、`profiler.lua`、`ptype.lua`、`realm.lua`、`res.lua`、`save_wheel.lua`、`secret.lua`、`snowflake.lua`。
> 第二列是源码起始行号。

## `metrics.lua`（223 行，Prometheus 指标原语）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.counter(name, help, label_names)` | 165 | 声明计数器（约定以 `_total` 结尾） | 同名重复声明、同名不同类型、同名不同标签都直接 `error` |
| `M.gauge(name, help, label_names)` | 169 | 声明瞬时值 | 同上 |
| `M.histogram(name, help, label_names, buckets)` | 174 | 声明直方图，`buckets` 必须非空且升序 | 校验失败 `error` |
| `M.collect()` | 191 | 导出本服务全部指标快照（普通表，可直接 `skynet.pack`） | — |
| `M._reset()` | 219 | 仅测试用：清空当前 VM 的全部指标 | — |
| `counter:inc(value, labels)` | 113 | 计数器加值，默认 1 | **不能为负**：减了下游算出的速率就是错的 |
| `gauge:set/inc/dec(value, labels)` | 125-134 | 瞬时值置位 / 加减 | — |
| `histogram:observe(value, labels)` | 142 | 落一个观测值到对应桶 | — |
| `check_name` / `check_labels` / `label_key` / `label_table` / `new_metric` / `get_series` / `zero` | 19-108 | 名字/标签合法性、标签拼 key（按声明顺序，不排序也稳定）、按 key 建/取 series、零值初化 | 缺标签 `error("metric 'x' is missing label 'y'")` |

## `metrics_api.lua`（75 行，把本服务挂到 `.metrics`）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.ensure_registered()` | 59 | 幂等注册：已注册直接返回；否则 `skynet.timeout(0, register)` |
| `M.registered()` | 71 | 是否已注册 |
| `collect_metrics()` | 19 | `.metrics` 扇出调用时执行：返回 `{ metrics = 本服务快照, runtime = skynet 运行时数据 }` |
| `register(attempt)` | 34 | 找 `.metrics` 并 `register_service(skynet.self())`；找不到就按 `RETRY_INTERVAL` 重试，最终放弃并告警 |
| `metrics` / `runtime` / `mqlen` / `cpu` / `message` / `memory` | 22-29 | 快照字段；`runtime` 顺手带上 `mqlen`/`cpu`/`message`/`memory`（抓取时反正要和每个服务通一次消息，比让 `.metrics` 再扇一轮 `STAT` 便宜） |

## `metrics_merge.lua`（163 行，多服务样本合并）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.new()` | 33 | 建累加器 `{ metrics, conflicts }` |
| `acc:add_snapshot(snapshot)` | 121 | 吃掉一个服务的整份快照 |
| `acc:result()` | 145 | 返回 `snapshot, conflicts`，`snapshot` 可直接交给 `metrics_text.render` |
| `acc:add(name, help, kind, labels, value)` | 69 | counter/gauge 累加（同名同标签求和） |
| `acc:max(name, help, labels, value)` | 79 | 取最大值（「队列里最长的那个有多长」这类问题） |
| `acc:add_histogram(...)` | 90 | 直方图桶合并 |
| `acc:_metric(name, help, kind, buckets)` | 38 | 建/取指标；**同名不同类型返回 `nil` 并记 conflict**，不静默混用 |
| `series_key` / `copy_labels` / `get_series` | 12-58 | 标签排序拼 key、标签拷贝、series 取用 |

## `metrics_text.lua`（125 行，Prometheus 文本格式）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.render(snapshot)` | 96 | 输出 `# HELP` / `# TYPE` / 样本行，指标按名排序、样本按标签排序 |
| `format_number(value)` | 7 | 整数不写小数点；浮点 `%.17g` 保证往返不丢精度；`NaN`/`+Inf`/`-Inf` 按规范输出 |
| `escape(value)` | 25 | 转义 `\`、`"`、换行 |
| `format_labels(labels, extra_name, extra_value)` | 30 | 标签按名字排序输出——同一条曲线每次抓取的文本必须一样，否则 diff 和缓存都没法用 |
| `render_histogram` / `sorted_samples` / `sample_order` | 49-72 | 直方图 `_bucket`/`_sum`/`_count` 三组行；样本稳定排序 |
| `CONTENT_TYPE` | — | `text/plain; version=0.0.4` |

## `metrics_router.lua`（28 行）

只注册一个 `GET /metrics`：**每次现查** `skynet.localname(".metrics")`（缓存住一个重启过的服务会让端点一直 500），转发 `render` 并把 `content-type` 带上；服务不在回 `503`，渲染失败回 `500`。合并与渲染都在 `.metrics` 里做——HTTP agent 有多个实例，谁抓都该看到同一份数据。

## `mongo_conn.lua`（215 行，Mongo 连接池）

结构：`M.get_collection(db, coll)` → `db` 对象（`connections` 条连接，随机路由）→ `collection` 对象（把方法名透传给 `.mongo_conn` 服务）。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.get_collection(name, coll)` | 207 | 取集合对象（对外唯一入口） | 库未配置直接断言失败 |
| `db.new(name)` / `db_mt:init()` | 169 / 160 | 按 `mongo_config[name].connections` 建连接 | — |
| `db_mt:get_collection(coll)` | 146 | 建/取集合代理 | — |
| `db_mt:_route()` | 155 | **随机挑一条连接**（把并发摊到多条 socket） | — |
| `conn.new(name, index)` | 63 | `uniqueservice("mongo_conn:<db>:<i>")`，每库每连接一个服务 | — |
| `conn_mt:call(cmd, ...)` | 49 | 透传调用，顺带记延迟与错误：`skyext_mongo_call_seconds`（histogram，标签 `op`）、`skyext_mongo_call_errors_total`（counter） | 被调方抛错原样抛出 |
| `coll:find_and_modify(doc)` | 73 | 原子改并返回 | — |
| `coll:find(doc, projection)` | 78 | 查询（游标） | — |
| `coll:find_many(doc, opts)` | 88 | 带 `projection`/`sort`/`skip`/`limit` 的查询；**多字段排序必须用数组形式** `{ {a=1}, {b=1} }`，Lua 表 `pairs` 无序 | 返回文档数组 |
| `coll:find_one(doc, projection)` | 93 | 查一条 | — |
| `coll:safe_insert(doc)` | 99 | 插入；**在本服务内先 `bson_encode`** 再传 `lightuserdata`，避免跨服务传大表 | — |
| `coll:safe_update(query, update, upsert, multi)` | 107 | 更新（带 upsert/multi 开关） | — |
| `coll:safe_delete(query, single)` | 121 | 删除，`single` 为真最多删一条 | — |
| `coll:create_index(keys, options)` | 130 | 建索引，幂等；推荐单参数复合写法 `create_index { {a=1}, {b=1}, name="a_b", unique=true }` | — |
| `mongo_config` / `bson_encode` / `op_labels` / `new_collection` / `_get_db` / `get_db` | 16-192 | 懒读配置；ORM 文档先 `orm.to_bson` 再编码；操作名标签；建库对象时用 `queue()` 串行化（并发首次访问只建一次） | — |

## `node_lease.lua`（105 行，节点级 etcd 租约）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.valid()` | 59 | 租约是否可用；**到期即就地判失效并触发回调**（不等心跳发现） | 布尔 |
| `M.id()` | 71 | etcd 租约 ID，**字符串原样透传**（转数字会丢 int64 精度） | — |
| `M.epoch()` | 76 | 租约世代，每批新租约 +1，用来判断手里的东西是否还挂在同一个租约上 | 数字 |
| `M.on_lost(name, fn)` | 82 | 注册失效回调 `fn(epoch, reason)`，按注册顺序各调一次 | `name` 只用于定位，不去重 |
| `M.shutdown()` | 88 | 停服主动撤租约：锁键、服务发现键立刻消失，别的节点马上看到本节点下线（不触发失效回调） | — |
| `fire_lost` / `clear` / `on_lease_alive` / `on_lease_lost` | 24-51 | 回调分发（单个回调失败只记日志）；清状态；新世代到来时先清旧世代；事件通道订阅入口 |

## `node_shutdown_api.lua`（22 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.start()` | 11 | 起 `node_shutdown` 编排服务（同时注册 GM `shutdown`），节点启动时调一次 |
| `M.add_hook(phase, cmd, status_cmd)` | 19 | 注册停服钩子。`phase` 支持 `stop_accepting`（卸载实体之前，关掉 gate/HTTP 入口）、`migrate`（卸载前的计划内迁移）和 `release`（实体全部落库之后，释放其余资源）。`status_cmd` 可选：迁移钩子用它查询 Abort 是否清理完成 |

## `orm_compat.lua`（332 行，schema 兼容性检查）

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.diff(baseline, current)` | 162 | 比较基线与当前 schema，产出按级别排序的变更列表 | `{ level, scope, field, message }` 数组；基线没有 `types` 直接断言失败 |
| `M.build_lock(baseline, current)` | 211 | 生成新基线：记当前结构，把这次删掉的名字追加进墓碑（只增不减；名字重新出现时清掉，否则之后每次检查都失败） | `{ types, retired = { fields, types } }` |
| `M.retired(baseline, scope)` | 255 | 列出退休名字（`scope` 给了就只列该结构） | `{ scope, field, signature }` |
| `M.encode(lock)` | 313 | 序列化成 Lua 源码，**键按字典序**，同一份基线每次输出都一样 | 字符串 |
| `M.count(changes)` | 318 | 各级别数量统计 | 表 |
| `M.format(change)` | 327 | 一条变更渲染成一行 | 字符串 |
| `signature(field)` | 21 | 字段签名：`map<k,v>` / `array<t>` / 基本类型；**容器键值类型也算结构的一部分** | 字符串 |
| `pair_renames(removed, added)` | 48 | 同一结构里既删又增且类型相同 → 多半是改名。改名在运行期表现为「旧字段丢弃、新字段补零」，数据就这么没了，必须单独报出来 | `{ 旧名 = 新名 }` |
| `diff_struct` / `retired_of` / `sorted_keys` / `add` / `encode_key` / `encode_value` | 32-153 | 逐结构比对、取墓碑、键排序、收集变更、Lua 字面量编码（关键字用 `[%q]` 包） | — |

## `profiler.lua`（164 行，Lua 采样）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.start(target_service, duration, freq)` | 51 | 起一次采样会话，返回 `session_id` | 采样协程异常只记日志 |
| `M.status(session_id)` | 86 | 查会话状态（`id`/`target`/`duration`/`status`/`sample_count`） | 未知会话返回 `nil` |
| `M.result(session_id)` | 113 | 取结果：`"栈 次数"` 每行一条，按行排序 | `nil, "session not found"` / `nil, "sampling not completed, status: …"` |
| `new_session_id` / `lua_sampler` / `hook` | 9-18 | 会话号自增；`debug.sethook` 按 `freq` 采栈，栈帧格式 `源:函数:行`，按 `;` 拼 key 计数 | — |

全仓没有任何 `require "skyext.profiler"`——**默认不加载**，要用得显式引。

## `ptype.lua`（11 行）

协议号常量：`PTYPE_LOG = 128` / `PTYPE_LOG_NAME = "log"`、`PTYPE_LOG_ERR = 129` / `PTYPE_LOG_ERR_NAME = "log-err"`。`[0,128)` 留给 skynet 自身。

## `realm.lua`（141 行，区服目录）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.server(server)` | 57 | 区服信息 `{ game, name, tag, status, open_time }` | 不存在返回 `nil`；**返回的表不要改** |
| `M.game_of(server)` / `M.zone_of(game)` | 61 / 66 | 服 → game / game → zone | 查不到返回 `nil` |
| `M.servers()` / `M.games()` / `M.zones()` | 71-79 | 排序后的键列表 | — |
| `M.tag_of(server)` | 84 | 跨服显示服号（`"S3"`）；查不到时退回服名本身 | 字符串 |
| `M.scope_value(scope, server)` | 90 | 出生服在某个 scope 层属于哪个值（`global`/`server`/`game`/`zone`） | 未知 scope 断言失败；目录查不到返回 `nil` |
| `M.scope_values(scope)` | 105 | 该层当前全部取值，作用域实体按它预加载 | 数组 |
| `M.gates()` | 120 | 在线网关列表 `{ node, tcp_addr, ws_url, weight }`，按节点名排序。**网关挂在节点租约上**，节点挂掉或停服就自动消失，所以前面不需要再挂一层会话保持型的负载均衡 | 数组 |
| `M.subscribe(fn)` | 136 | 目录变化（开服、调战区、网关上下线）回调 `fn(dir)` | — |
| `apply(dir)` / `dir()` / `sorted_keys` | 18-47 | 应用新目录（**revision 比当前旧就丢弃**，回调失败只记日志）；懒取 `.realm` 快照 | — |

## `res.lua`（216 行，配表热加载）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `CMD.open(source)` | 24 | 某服务开始使用配表：加载（首次）并把表通过 `sharetable` 共享给该服务 | 返回 `preload_loaded, lazy_loaded` |
| `CMD.close(source)` | 31 | 某服务停止使用 | — |
| `res_service()` | 1 | 服务侧实现：扫 `res_path`、按 md5 判断是否变化、`sharetable.loadstring` 发布 | — |
| `fetch_res_files(path)` | 37 | 递归列 `.lua` 配表 | 文件数组 |
| `load_file(name, filepath)` | 52 | 读文件 → md5 → 发布；**同名重复加载断言失败** | — |
| `load_res()` | 64 | 首次全量加载（预加载表 + 懒加载表） | — |
| `do_reload_res(res_files)` | 78 | 热更：只重载 md5 变化的文件，全无变化时返回 `"no diff res file need to reload"` | `true, msg` / `false, reason` |
| `on_res_reload(res_list)` | 183 | 重载完成回调：把新表重新 `sharetable.query` 到 `res_table` | — |

## `save_wheel.lua`（118 行，回存轮）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.new(name, period, on_entry)` | 23 | 建轮；`period` 是同一 entry 两次处理的间隔（秒），槽位数 = `period / TICK_SEC` | `period > 0`、`on_entry` 必须函数 |
| `wheel:add(entry)` | 96 | 加入条目（entry 同时是键，不能重复加入），随机落槽 | 重复加入断言失败 |
| `wheel:remove(entry)` | 107 | 移除 | 是否真在轮上 |
| `_tick` / `_flush` / `_ensure_timer` | 45-85 | 每 tick 推进指针；到期的槽 `fork` 出去跑（单个 entry 异常只记日志）；落后/追上各有日志；**第一个条目加入时才真正起定时器** | — |

## `secret.lua`（81 行）

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.check(value, opts)` | 49 | 校验密钥可用性：未配置、长度不足、命中占位符表都拒绝 | `ok, reason`；`ok = true` 时 `reason` 是「可用但不安全」的告警 |
| `M.assert_valid(value, name, opts)` | 73 | 校验失败直接抛错，用于「拿不到可用密钥就没法继续」的启动路径 | 原值 |
| `M.is_placeholder(value)` | 35 | 是否已知的占位/示例值（去空格、转小写后比对） | 布尔 |
| `normalize` | 30 | 去首尾空白并转小写 | — |

`opts.allow_insecure = true` 只在本地开发用：不拒绝弱密钥，但一定会在第二个返回值里给出原因。

## `snowflake.lua`（200 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.newid()` | 191 | 取一个 ID（跨服务调用 `snowflake` 服务） | — |
| `M.newids(count)` | 196 | 批量取 | — |
| `CMD.newid()` / `CMD.newids(count)` | 119 / 125 | 服务侧实现；批量上限有断言 | `count` 过大会 `error` |
| `CMD.shutdown()` | 112 | 停服 `release` 阶段：实体都已落库、不会再要号，归还机器号 | 同一节点马上重启能拿回原号 |
| `generate_one()` | 76 | 时钟回拨直接 `error("clock moved backwards")`；同一秒内序号溢出 `sleep 0.5s` 等下一秒；相对时间超 174 年断言失败 | — |
| `machine_id_held()` / `wait_machine_id()` | 53 / 60 | **号不在手上就绝不发 ID**（接手的进程可能正用同一个 `(时间, 机器号)`）；启动时等号 | — |
| `parse_date` / `get_cur_timestamp` / `current_machine_id` / `snowflake_service` | 1-72 | 起始日期（默认 `2025-10-09`）；秒级时间戳；固定/租约机器号 | 位宽断言：`MACHINE_BIT + SEQUENCE_BIT <= 21`（不超 JS 安全整数）、总位数 `< 64` |
