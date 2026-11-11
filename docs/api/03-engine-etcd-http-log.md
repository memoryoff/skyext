# 03 · etcd 客户端、HTTP 服务、日志、机器号

> 覆盖 `lualib/skyext/` 下的 `etcd/`、`event_channel_api.lua`、`gm_api.lua`、`gm_router.lua`、`hotfix_checksum.lua`、`http_server/`、`httpc.lua`、`id_generator.lua`、`init.lua`、`log/`、`machine_id.lua`。
> 第二列是源码起始行号。

## `init.lua`（13 行，每个服务都会加载的入口）

`require "skyext"` 落到这个文件。它只做两件事（L8-13）：注册 `skynet.init` 回调，依次执行 `skyext.config.init()`（读应用配置）和 `skyext.log.init()`（按配置建默认 logger）。失败直接抛，靠 `snlua` 的 traceback 处理器打完整堆栈。

文件头两条注释是硬约定：**不覆盖 `_G.next` / `table.unpack` / `table.concat` / `table.insert` / `table.remove`**，ORM 文档的遍历与数组操作改用 `orm.*` 显式接口，保持标准库原生语义。

## `etcd/`（HTTP gateway 客户端）

全部走 etcd v3 的 `/v3/*` HTTP 接口（JSON + base64 编解码），没有一个方法直接发包给 etcd 集群之外的地址。

### `etcd/init.lua`（61 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.new(opts)` | 36 | 建客户端：`http_host`（字符串或数组）、`user`/`password`、`timeout`（默认 5 秒）、`key_prefix`；把 `kv`/`lease`/`watch` 的方法混入返回对象 |

### `etcd/codec.lua`（75 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.verify_key(key)` | 18 | 键合法性检查（必须是字符串、非空） | `false, reason` |
| `M.real_key(prefix, key)` | 28 | 拼完整键（`key_prefix .. key`） | 字符串 |
| `M.encode_key(prefix, key)` | 32 | 键 → base64 | — |
| `M.encode_value(val)` | 36 | 值 → JSON → base64 | `nil, err` |
| `M.decode_value(data)` | 44 | 反解：base64 → JSON | `nil` 表示不是本库写的值 |
| `M.range_end(key)` | 55 | 前缀扫描转区间扫描的上界：从末尾找第一个 `< 0xff` 的字节加一后截断（直接给末字节加一会溢出）；全 `0xff`/空键返回 `"\0"` 表示扫到 keyspace 末尾 | 字符串 |
| `M.decode_kvs(kvs)` | 65 | 批量解码 etcd 的 kv 数组 | 解码后的数组 |

### `etcd/kv.lua`（297 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.methods.get(self, key, opts)` | 139 | 取单键（`revision` 可指定历史版本） | `res, err` |
| `M.methods.readdir(self, key, opts)` | 150 | 按前缀列目录（`range_end` 区间扫描） | `res, err` |
| `M.methods.set(self, key, val, opts)` | 168 | 写入（`lease`/`ignore_lease`） | `res, err` |
| `M.methods.setnx(self, key, val, opts)` | 193 | **不存在才写**：`CREATE` 比较 + `create_revision = 0` 的事务 | 原子创建 |
| `M.methods.setx(self, key, val, opts)` | 212 | **已存在才写**：同上，put 放到 failure 分支 | 原子更新 |
| `M.methods.mod(self, key, val, opts)` | 231 | 乐观锁写入：`mod_revision` 必须与预期一致 | 缺 `mod_revision` 直接返回 `nil, "mod needs mod_revision"` |
| `M.methods.txn(self, compare, success, failure, opts)` | 253 | 通用事务：自动给三方都编码 key/value | `nil, err` 当 compare 为空或 success/failure 同时为空 |
| `M.methods.delete(self, key, opts)` | 274 | 删单键 | — |
| `M.methods.rmdir(self, key, opts)` | 285 | 按前缀删（区间删除） | — |
| `full_key` / `range` / `delete_range` / `txn` / `shallow_copy` / `encode_compare` / `encode_op` / `encode_branch` | 32-124 | 内部：拼键、三种请求的编码（compare/op/branch） | — |

### `etcd/lease.lua`（59 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.methods.grant(self, ttl, id)` | 19 | 申请租约，`id = 0` 表示服务端分配 | `ttl` 必须数字 |
| `M.methods.revoke(self, id)` | 26 | 撤销租约 | 缺 `id` 返回 `nil, …` |
| `M.methods.keepalive(self, id)` | 33 | 续租（单次） | 同上 |
| `M.methods.timetolive(self, id, keys)` | 41 | 查剩余 TTL；`keys = true` 时连绑定键一起返回 | 同上 |
| `M.methods.leases(self)` | 55 | 列全部租约 | — |

### `etcd/transport.lua`（261 行，负载均衡与重试）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.parse_endpoints(http_host)` | 42 | 解析 `http://host:port` 列表 | `http_host` 缺失/非法返回 `nil, err` |
| `M.report_failure(self, http_host)` | 73 | 记录端点失败并进入摘除期 | — |
| `M.post(self, uri, body, timeout, ignore_auth)` | 216 | 单次逻辑请求：**网络异常与 5xx 都摘除该端点换下一个**，把 `MAX_ATTEMPTS` 个候选试完才算失败 | `res, err`（err 可能带 `retriable`） |
| `M.post_stream(self, uri, body, timeout)` | 240 | 流式请求（watch 用），返回 `{ cli, stream, endpoint }` | `nil, err` |
| `parse_endpoint` / `ring_balancer` / `is_healthy` / `choose_endpoint` / `working_endpoint` / `candidate_endpoints` | 23-104 | 解析单个地址；轮询挑端点；摘除期内跳过；候选顺序 = 当前常用 → 其它健康 → 摘除期内的（可能已恢复，好过整个请求失败） | — |
| `prepare` / `loggable` / `with_timeout` / `request` / `request_stream` | 142-204 | 认证头与 body 组装；**认证 body 不进日志**（`AUTH_BODY_OMITTED`）；`httpc.timeout` 是模块级变量，只在请求开始读一次，所以「赋值→请求→还原」不会被别的协程读到错值 | — |

### `etcd/auth.lua`（63 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.methods.authorize(self, timeout)` | 23 | 取 token：仍在有效期内直接返回；否则 `POST /v3/auth/authenticate`，失败重试一次（先 `sleep` 一个 timeout） | `true` / `nil, err` |
| `token_fresh(self)` | 18 | 有效期判断（提前 `REFRESH_AHEAD` + 0-60 秒随机，避免所有节点同时刷新） |

### `etcd/watch.lua`（111 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.methods.watch(self, key, opts)` | 102 | 监听单键 | 流对象或 `nil, err` |
| `M.methods.watchdir(self, key, opts)` | 106 | 监听整个前缀（`range_end`） | 同上 |
| `watch(self, key, opts, range_end)` | 78 | 建 `create_request` 并发起流式请求，把流包成 `watch_mt` 对象 | 键必须字符串 |
| `decode_events(events)` | 17 | 逐条解码事件（`PUT`/`DELETE`），流报错/解 JSON 失败各有日志 | `nil, reason` |

## `event_channel_api.lua`（57 行，进程内事件通道）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.subscribe(service, cmd, func)` | 29 | 向目标服务订阅事件：建通道（`GET_EVENT_CHANNEL`）并把 `cmd` 注册到本地分发 |
| `M.publish(cmd, ...)` | 47 | 把事件发给所有订阅者 |
| `M.init()` | 51 | 建本服务的上行通道（懒初始化） |
| `CMD.GET_EVENT_CHANNEL()` | 42 | 应答别的服务的订阅请求，返回本服务的通道地址 |
| `channel_new(service, subscribe_cmd)` | 9 | 建通道并登记订阅命令；收到未知命令打 error 日志 | — |

## GM

### `gm_api.lua`（143 行，服务侧注册）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.register(GM_CMD)` | 47 | 批量注册指令：每条必须有 `desc` 和 `handler`，`params` 是参数说明表；服务里生成 `GM_<大写指令名>` 分发包 | 缺 `desc`/`handler` 直接 `error`；GM 服务未起只告警并返回 `false` |
| `M.unregister()` | 18 | 注销本服务注册的全部指令（按 `skynet.self()`） | 布尔 |
| `M.execute_command(cmd_name, params, target_services)` | 121 | 进程内直接执行（不带凭证），返回 `{ code, error, result }` | GM 服务未起返回错误码 |
| `get_gm_service()` | 9 | `skynet.localname(".gm")` | 地址或 `nil` |

### `gm_router.lua`（127 行，HTTP 侧转发）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `credential(req, params)` | 22 | 只从请求里取凭证（`token` + `peer`）；**鉴权与审计都在 `.gm` 服务里做**，因为 HTTP agent 有多个实例，分散做既难对齐也难查 |
| `forward(res, cmd, ...)` | 35 | 把请求转给 `.gm`，应答原样返回；服务不在时回错误 JSON |
| `get_gm_service()` | 13 | 同上的本地名解析 |

## `hotfix_checksum.lua`（49 行）

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.compute(config, hotfix_dir, root_dir)` | 7 | 把 `update_files`（相对工程根，逐个读内容）与自身文件拼起来算校验和 | 校验和字符串；文件读不到返回 `nil, "Update file not readable: …"` |
| `M.verify(config, hotfix_dir, root_dir)` | 36 | 与包内 `checksum` 比对 | `true` / `false, "Checksum mismatch: expected …, got …"` |

## `http_server/`（自带 HTTP 服务，不依赖 skynet 的 httpd）

结构：`init`（对外 API）→ `watchdog`（监听与连接额度）→ `agent`（每连接的处理协程）→ `deadline`（读/写/keepalive 三段超时守卫）→ `limits`（上限解析）。

### `http_server/init.lua`（71 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.new(name)` | 23 | 建（或取回）命名服务器实例，服务名 `http_watchdog_<name>` | 名字非法 `error` |
| `server:start(conf)` | 42 | 起监听：`host`/`port`（0 = 系统分配）/`agent_count`（默认 8），其余上限字段回落到节点配置 `http_<字段>` 再回落内置默认 | 已启动过断言失败；返回实际监听信息 |
| `server:register_router(router_name)` | 55 | 注册路由模块，**必须在 `start` 之后**；返回时所有 agent 都已注册完 | 未启动断言失败 |
| `server:address()` | 61 | 监听服务地址 | — |
| `server:stats()` | 66 | 当前连接数与累计拒绝数 | 表 |
| `check_name(name)` | 16 | 名字合法性 | 非法 `error`（level 3） |

### `http_server/watchdog.lua`（171 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `CMD.start(conf)` | 85 | 建 listen socket、按 `agent_count` 起 `http_agent_<server>_<id>`、把监听 fd 交给 agent；校验端口与 agent 数 |
| `CMD.conn_closed()` | 136 | agent 处理完（含异常收尾）归还连接额度；减到负数会打 error |
| `CMD.register_router(router_name)` | 147 | 同步注册到**所有** agent，返回即全部生效 |
| `CMD.info()` / `CMD.stats()` | 156 / 160 | 监听信息；`{ active, rejected, max_connections }` |
| `on_accept(id, addr, balance)` | 47 | 接入：超 `max_connections` 直接拒绝（`rejected` 计数） |
| `config_defaults()` | 26 | 节点级默认值（`http_max_connections` 等）；**只能在 `start` 时读**——服务 chunk 早于 `config.init()` 执行 |

### `http_server/agent.lua`（300 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `SOCKET.request(id, addr)` | 255 | 一个连接的主循环：读请求 → 交路由 → 应答 → 决定是否 keep-alive | — |
| `CMD.register_router(router_name)` | 279 | 校验路由模块并挂上；每个 agent 各持一份 | 非表直接断言 |
| `serve_once(conn)` | 149 | 处理一个请求，返回「连接能否继续」；读/keepalive 超时、对端关闭、读失败各有日志与返回值 | 布尔 |
| `serve_connection(conn)` | 240 | `xpcall` 包住 `serve_once`，异常只记日志 | — |
| `send_response(conn, status, body, header)` | 44 | 唯一写应答处；**第二次写应答会被拒绝并记 error**（防 handler 双写） | 布尔 |
| `bodiless(statuscode)` | 40 | 204/304/1xx 不带 body，也不能带 `content-length` | — |
| `keepalive_allowed(conn, header)` | 76 | keep-alive 判定：`keepalive_timeout <= 0`、请求/应答要求关闭、已达 `keepalive_requests` 上限都返回 `false` | — |
| `build_request` / `build_response` / `make_read` | 93 / 124 / 226 | 请求/应答对象构造；读函数每次读都重置读超时 | — |
| `req.id/addr/url/method/path/query` / `req.header(k)` / `req.body()` / `req.parse_query()` | 96-104 | 请求对象访问器 | — |
| `req.read_json()` | 110 | 解析 JSON body | **空 body、坏 JSON、JSON 标量都返回 `nil, reason`**——直接索引解析结果是历史崩溃点 |
| `res.write(status, body, header)` | 126 | 原始应答 | — |
| `res.write_json(data, header)` | 130 | `200` + JSON | — |
| `res.write_file(filename, header)` | 135 | 文件应答，读不到回 `404` | — |

### `http_server/deadline.lua`（86 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.new(fd, deps)` | 23 | 建守卫；`deps = { now, sleep, wakeup, fork, shutdown }` 全部注入，便于单测 |
| `guard:set(seconds, reason)` | 62 | 设定/延长截止时间；`0` 等价 `cancel` |
| `guard:cancel()` | 75 | 取消并立刻结束守卫协程 |
| `guard:expired_reason()` | 82 | 已超时返回原因，否则 `nil` |
| `watch(self)` | 38 | 守卫协程：到点 `shutdown` 连接 |

### `http_server/limits.lua`（72 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.parse(conf, defaults)` | 42 | 解析上限：实例配置 > 节点配置 > 内置默认 | **任何字段非法直接报错，不静默回退**（拼错的配置名会让上限悄悄变回默认） |
| `M.defaults()` | 64 | 内置默认值的只读副本 | — |

### `http_server/fixtures/`（仅测试用）

`public_router.lua`（25 行）、`admin_router.lua`（10 行）：给 `http_server` 测试提供最小路由与鉴权样例，不进部署包。

## `httpc.lua`（15 行）

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.post_json(host, url, data, recvheader)` | 4 | POST JSON 并解析回包 | `status, table`；解析失败回 `status, 原始 body` |

## `id_generator.lua`（156 行，snowflake + 本地批量缓存）

为什么要缓存：`snowflake.newid` 每次都走一次跨服务调用，高频发号（物品 uid）扛不住；这里一次取一批。

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.newid()` / `M.newids(count)` | 133 / 137 | 公开接口，先吃缓存 |
| `M.raw_newid()` / `M.raw_newids(count)` | 124 / 128 | 直连 `snowflake`，绕过缓存 |
| `M.get_cache_status()` | 142 | `{ size, capacity, is_refilling, should_refill }`，供监控 |
| `get_cached_id()` | 62 | 缓存空则回退 `raw_newid()` |
| `get_cached_ids(count)` | 84 | 批量取；不足部分直连补 |
| `should_refill()` / `refill_cache()` / `do_refill()` | 25 / 30 / 38 | 低于阈值就 `fork` 一个协程补货（补货失败只记日志，不影响已有缓存） |

## `log/`

### `log/log_level.lua`（10 行）

纯常量：`DEBUG=4`、`INFO=3`、`WARN=2`、`ERROR=1`、`FATAL=0`（**数值越小越严重**）。

### `log/util.lua`（24 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.parse_level(input)` | 9 | 解析 `"INFO-DEBUG"` 这类区间，也接受单级别（单级别时另一端取默认） | 名字非法断言失败；`lower > upper` 报 `invalid log level setting` |
| `M.should_log(level, record_level)` | 20 | 区间判定 | — |

### `log/formatter.lua`（135 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `M.get_formatter(format, color, style)` | 119 | 取 `text`/`json` 格式化函数；`color` 为真时套 ANSI 色（`FATAL` 亮红、`ERROR` 红、`WARN` 黄、`DEBUG` 青） |
| `F.json(record)` | 81 | `cjson.safe.encode`，字段顺序与 `default_logmt` 对齐 |
| `F.text(record, style)` | 101 | 默认 `[时间 级别] 模块:行: msg:…`；`style` 可换成自定义函数 |
| `default_logmt` / `format_time` / `level_to_string` / `colorify` / `json_format_record` / `color_seq` | 22-108 | 时间戳（毫秒 3 位）、级别名、ANSI 包裹、JSON 组装 |

### `log/logger.lua`（302 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.new()` | 275 | 建 logger 对象 | — |
| `logger:config(t)` | 261 | 按字段白名单校验并应用配置（`level`/`format`/`style`/`color`/`log_src`/`log_table`…） | 未知字段或类型不符直接 `error` |
| `logger:debug/info/warn/error(...)` | 147-159 | 分级入口；`error` 支持 `"fmt"` 风格参数 | 写日志自身出错只吞掉（`pcall`） |
| `logger:is_enabled(level)` | 129 | 该级别是否会输出，调用方可用它跳过昂贵的参数准备（堆栈回溯、序列化） | 布尔 |
| `logger:sys_assert(v, ...)` / `logger:sys_error(message, level)` / `logger:xpcall_msgh(msg)` | 203 / 212 / 222 | **显式版**的 assert/error/xpcall：报错同时打堆栈。`_G.assert`/`_G.error`/`_G.pcall`/`_G.xpcall` 不再被覆盖 | — |
| `logger:_log` / `_raw_log` / `_serialize` / `_pack_events` | 73-133 | 级别过滤、结构化 `key-value` 参数（**必须偶数个**，否则断言失败）、表序列化（按 `log_print_table` 决定） | — |
| `get_bucket()` / `save_to_bucket(...)` / `get_log_src(level)` | 29-54 | 选桶（优先 `.logger` 服务桶，退回默认桶）；组记录；`log_src` 打开时取调用点的 `source:line` | — |
| `coerce_level(v)` / `log_traceback` / `do_error` | 235-192 | 配置级别归一化（数值或名字都接受）；堆栈收集 | — |

### `log/init.lua`（63 行）

`M.config/debug/info/warn/error/xpcall_msgh/sys_assert/sys_error/is_enabled`（L9-41）全部转发给默认 logger；`M.init()`（L48）按 `log_level`/`log_src`/`log_print_table` 配置默认 logger，**配置非法时退回默认并打 error**。

### `log/bucket/`（日志落点）

| 文件 / 方法 | 行 | 作用 |
| --- | --- | --- |
| `init.lua` · `M.new(conf)` | 5 | 按 `conf.name` 动态 `require "skyext.log.bucket.<name>"` 建桶；名字不存在/构造失败都 `error` |
| `init.lua` · `M.get_default()` | 26 | 默认桶（全仓无显式配置时是 `console`） |
| `console.lua` · `M.new(params)` | 22 | 写 `io.stdout`；`put` 直接输出 |
| `console.lua` · `console_mt:put(record)` | 13 | 无句柄返回 `nil`，否则写一行 |
| `service.lua` · `M.new(conf)` | 33 | 把记录发给 `.logger` 服务（`PTYPE_LOG_NAME`；`ERROR` 级别走高优先级 `PTYPE_LOG_ERR_NAME`） |
| `service.lua` · `bucket:put(record)` | 24 | 同上；若 `.logger` 就是自己则直接用 `global` 桶，避免自调用死锁 |
| `file.lua` · `M.new(params)` | 224 | 文件桶：`filename` 必填；`split=line/hour/day`、`maxline`、`format=json|text`、`color`、`style`、`level=INFO-DEBUG`、`flush_period`（0 = 每条都刷） |
| `file.lua` · `file_mt:put(record)` | 119 | 写一行；按 `flush_period` 决定是否立刻 `flush` |
| `file.lua` · `file_mt:split()` | 89 | 切分：`line` 按行数、`time` 按小时/天、`size` 按字节；重命名旧文件后重开 |
| `file.lua` · `file_mt:reload/init/flush/check_error/close` | 77-152 | 重开句柄、初始化、刷盘、错误检测（`flush_ok ~= true`）、关闭 |
| `file.lua` · `need_split` / `parse_bytes` / `new_split_mgr` | 31-169 | 三种切分策略的判定；`"10MB"` 一类单位解析（`assert` 非法格式） |

## `machine_id.lua`（124 行，节点号段）

用途：给 snowflake 之外的序号段（如 worker id）按节点分配不冲突的号，号用分布式锁占位。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.new(name, count)` | 27 | 建一个号段槽位（**尚未抢号**） | `name` 非空、`count` 正整数 |
| `slot:acquire(exclude)` | 81 | 循环抢号：从节点名散列出的位置开始探测（重启大概率拿回原号、不同节点不会一起从 0 抢）；抢不到就指数退避重试，期间 `valid()` 为 `false`，**调用方必须停下** | — |
| `slot:release()` | 102 | 停服主动归还，同一节点马上重启能拿回原号；归还后 `valid()` 恒 `false` 且不再抢 | 布尔 |
| `slot:valid()` | 119 | 号此刻是否仍归本节点 | 布尔 |
| `slot_mt:_on_lost(id)` | 44 | 锁丢失回调：标记失效并异步重抢 | — |
| `slot_mt:_try_claim(exclude)` | 57 | 逐个号 `distributed_lock.try_lock`；`"lock held"` 表示被别人占，换下一个；其它错误直接返回 | `true` / `false, reason` / `false, "no free slot"` |
| `probe_start(self)` | 35 | 节点名散列起点 | `0..count-1` |
