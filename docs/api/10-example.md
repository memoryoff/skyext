# 05 · `example/` 示例游戏层：文件与方法

> 本册覆盖 `example/` 下的 Lua 代码（配置、节点、业务模块、登录/运营服务）。`example/tools/phaser-game`、`example/tools/gamepass` 是独立 submodule，代码由各自仓库维护，这里只记「是什么、怎么被调用」，不逐方法展开。
>
> 第二列是**源码起始行号**，用编辑器按行跳转即可对照实现；方法名中没有 `M:` 的即普通函数（`M.foo(...)`），有 `self` 的写成 `M:foo(...)`。

## `example/etc/` 节点配置

这些文件是 skynet 启动配置（`return { ... }` 表字面量），没有函数，只有键。

| 文件 | 行 | 作用 |
| --- | --- | --- |
| `account1.conf.lua` | 3 | account1 节点启动配置：`start = "account"`、`app_config_path`、`include "core.conf.lua"` |
| `account2.conf.lua` | 3 | account2 节点启动配置，结构同上 |
| `role1.conf.lua` / `role2.conf.lua` | 3 | role1 / role2 节点启动配置，`start = "role"` |
| `gate1.conf.lua` | 3 | 独立网关节点启动配置，`start = "gateway"` |
| `robot.conf.lua` | 3 | 机器人节点启动配置，`start = "robot"` |
| `core.conf.lua` | 12 | 所有节点共用：`root = "./"`、`skyext_root`、`game_root`、`include "paths.conf.lua"`、`thread = 8`、`bootstrap = "snlua bootstrap"`、`logservice`、`logger` |
| `paths.conf.lua` | 42 | `lua_path` / `luaservice` / `lualoader` / `lua_cpath` / `cpath` 的拼装，注释写明「节点目录名不能与服务名撞车」 |
| `nodes/common.app.lua` | 300 | 应用公共配置：日志桶、etcd/mongo 连接、`entity_types`、会话上限、配表、JWT、HTTP 上限、指标、区服种子 |
| `nodes/account1.app.lua` | 25 | account1 业务配置：集群名/端口、HTTP、GM、指标端口 |
| `nodes/account2.app.lua` | 25 | account2 业务配置，端口整体 +1 |
| `nodes/role1.app.lua` / `role2.app.lua` | 27 | role 节点配置：集群端口、gate 端口、GM、指标 |
| `nodes/gate1.app.lua` | 27 | 独立网关配置：bare TCP 端口、WS 端口、GM、指标 |
| `nodes/robot.app.lua` | 23 | 机器人：数量、account 地址、`robot_transports`（tcp/ws）、日志 |

配置项的取值口径见 `docs/getting-started.md`；键名以文件里的注释为准。

## `example/hotfix/20260120-patch1/`

| 文件 | 方法 / 键 | 行 | 作用 |
| --- | --- | --- | --- |
| `hotfix.conf.lua` | `desc` / `checksum` / `gitsha_base` / `gitsha_update` / `time` | 2-6 | 热更包元信息；`checksum` 与 `time` 由 `skyext hotfix refresh` 回写 |
| | `update_files` | 9 | 要注入的代码文件，**相对工程根**（与 `hotfix_dir` 同基准） |
| | `reload_res` / `reload_sproto` / `reload_orm_schema` / `clearcache` | 12-15 | 执行时需要重载的子系统开关 |
| | `code_files` | 16 | 需要清 Lua 缓存的模块名 |
| `code1.lua` | `patcher.run()` | 9 | 注入脚本示例：读一次 `res.hotfix_demo.version` 并返回，用于验证 `reload_res` 生效 |

## `example/lualib/entity_handler/`

| 文件 / 方法 | 行 | 作用 | 返回与边界 |
| --- | --- | --- | --- |
| `rank.lua` · `cache_of(entity)` | 22 | 取（或初始化）该实体的排名缓存表，挂在实体上 | 缓存表 |
| `better(a, b)` | 31 | 排名比较器：分高优先，同分比时间早，再比 `rid` | 布尔 |
| `refresh(entity)` | 42 | 重排并只保留前 `MAX_ENTRIES` 名，结果写回缓存供 `top` 直接读 | 无返回；由实体的 `every("refresh", …)` 周期调用 |
| `M.handlers.submit(entity, rid, name, score)` | 58 | 只接受更高的分，命中就更新记录并触发刷新 | 是否刷新了成绩（布尔） |
| `M.handlers.top(entity, count)` | 68 | 从缓存取前 `count` 名 | 结果数组 |
| `M.on_load(entity)` | 78 | 生命周期钩子占位 | — |
| `role.lua` · `handlers.get_online_info(entity)` | 7 | 返回在线信息 | `{ rid, name }`，实体未就绪返回 `nil` |
| `handlers.kick(entity)` | 14 | GM 踢人：交给会话层断开 | `true` |
| `handlers.recv_mail(entity, mail, msg_id)` | 24 | 可靠消息的收件 handler：**至少一次投递**，拿 `msg_id` 当邮件 id，重复投递由 mail 模块去重 | 无返回 |
| `on_load` / `on_unload` | 31 / 35 | 加载、卸载时各打一条日志 | — |
| `on_bind_client(entity, session_key)` | 40 | 客户端绑定成功：只放业务上下线逻辑（会话本身由 `skyext.entity.session` 维护） | — |
| `on_unbind_client(entity)` | 44 | 解绑 | — |
| `on_resume_client(entity, session_key)` | 51 | **续接成功不等于上线**：不触发 bind/unbind，在线时长、上线奖励、好友在线状态不要写在这里 | — |

## `example/lualib/errcode.lua`

| 内容 | 行 | 说明 |
| --- | --- | --- |
| 常量表 | 1-12 | 游戏层错误码：`ROLE_NOT_EXIST=100`、`TOKEN_ERROR=101`、`NAME_TAKEN=102`、`ROLE_TOO_MANY=103`、`PROTO_CHECKSUM=104`、`SERVER_NOT_EXIST=105`、`MAIL_NOT_FOUND=110`、`RANK_UNAVAILABLE=120` |

## `example/lualib/jwt.lua`（HS256 / RS256 登录 token）

内部辅助：

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `key_family(key)` | 49 | 判定密钥族：字符串 → `hmac`；`{ alg="RS256", public|private }` → `pkey`；形状不认识返回 `nil` |
| `resolve_public_pem(key, kid)` | 63 | 从密钥描述取公钥 PEM；配了多把公钥时按 `kid` 选，缺失/未知 `kid` 各有独立错误串 |
| `decode_segment(segment)` | 81 | base64url 解码 + JSON 解码一段 JWT；失败返回 `nil`（不抛错） |
| `audience_matches(aud, expected)` | 95 | `aud` 允许字符串或数组，任一命中即通过 |
| `check_signature(spec, alg, key, header, signing_input, signature)` | 113 | 验签；失败时第三个返回值 `kind="config"` 表示是服务端密钥配置错，不是 token 坏 |
| `read_pem_config(inline_key, path_key)` | 283 | 二选一读 PEM：同时配置两个键直接报错；文件读不到返回 `nil, "cannot read …"` |
| `resolve_login_key(usage)` | 332 | 按 `login_jwt_alg` 组装登录密钥；不安全默认值会返回「可用但告警」的 `reason` |

导出方法：

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.verify(token, key, opts)` | 134 | 校验 JWT：拆段、校验 header/`typ`/`alg`、验签、校验 `iss`/`aud`/`exp`/`nbf`（含 `leeway`） | `payload` 或 `nil, reason, kind` |
| `M.sign(claims, key, opts)` | 221 | 签发 JWT：`iss`/`aud`/`ttl` 必填，`alg` 与密钥族不匹配直接拒绝 | `token` 或 `nil, reason` |
| `M.login_options()` | 312 | 从配置读登录 JWT 参数（alg/iss/aud/ttl/leeway）并缓存 | 选项表 |
| `M.login_key(usage)` | 376 | 取登录密钥，`usage` 为 `"verify"`（默认）或 `"sign"` | `key` 或 `nil, reason`；`reason` 在返回 key 时是「可用但不安全」的告警 |
| `M.sign_login(claims)` | 400 | 用配置里的密钥/iss/aud/ttl 签发登录 token，调用方只管业务 claim | `token` 或 `nil, reason` |
| `M.verify_login(token)` | 413 | 校验登录 token | `payload` 或 `nil, reason, kind`；`kind="config"` 该告警而不是当坏 token |

关键边界：`verify`/`sign` 都 `assert` 了 `opts.iss`/`opts.aud`（`sign` 还有 `ttl`），漏传是调用方 bug，不会被静默当成「不校验」。

## `example/lualib/launcher.lua`

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.launcher_node()` | 8 | 节点公共启动：起 `metrics`、`gm`、`hotfix`，起 `realm`（`uniqueservice`），起 `mongo_index` 并 `call "create_indexes"` | 建索引失败直接 `assert` 中断启动 |
| `M.launcher_gate()` | 32 | 建 `login` 服务，按 `gate_host`/`gate_port`/`maxclient` 开 TCP 网关（浏览器/小程序走 `gate_ws`，共用同一个 login），并向 realm 上报对外地址 | 必须在实体就绪后调用——端口一开就有玩家进来；缺 `gate_port` 直接断言失败 |

## `example/lualib/role_db_api.lua`（角色文档）

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `with_field(tbl, key, value)` | 13 | 复制查询/投影表再改字段，避免调用方复用同一张表被就地污染 | 新表 |
| `M.get_roles(account, query, projection)` | 26 | 按账号查角色列表；`query.rid` 可选，指定则只查该角色（仍限本账号） | 角色数组；查不到打 info 日志 |
| `M.has_role(rid, account, server)` | 71 | 校验「rid 属于该账号且属于该区服」——JWT 只证明账号，不查这一步就能登别人角色 | 布尔 |
| `M.exists(rid)` | 76 | 角色是否存在 | 布尔 |
| `M.create(rid, account, data)` | 82 | **先写角色文档、再把 rid 挂到账号**：中途失败只会留下看不见的角色文档，不会留下指向空气的 rid | `true` / `false`（失败已记日志） |

## `example/lualib/role_name_api.lua`（角色名占用）

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.reserve(server, name, rid)` | 16 | 以 `(server, name)` 唯一键占名 | `true`；或 `false, "taken"`；数据库错返回 `false, err` |
| `M.release(server, name)` | 30 | 建角失败时还名（`safe_delete`，`single=true`） | 无 |
| `M.display(server, name)` | 38 | 跨服显示名：`[S3]张三`；本服直接返回 `name` | 字符串 |

## `example/lualib/user_db_api.lua`（账号文档）

| 方法 | 行 | 作用 | 返回 |
| --- | --- | --- | --- |
| `M.get(account, projection)` | 12 | 取账号文档 | 文档或 `nil`；`account` 为空直接断言 |
| `M.get_rids(account)` | 19 | 取账号下的 rid 列表 | 数组或 `nil` |
| `M.add_rid(account, rid)` | 28 | 把 rid 追加进账号 | `safe_update` 结果 |
| `M.remove_rid(account, rid)` | 37 | 从账号移除 rid | `safe_update` 结果 |
| `M.reserve_role_slot(account, server, max)` | 50 | 单区服建角名额：把「判断未满」和「计数 +1」压进一条 update，避免先读后写的 TOCTOU | `true`（占到）、`false`（已满）、`nil, err` |
| `M.release_role_slot(account, server)` | 73 | 建角失败还名额 | 无；**占用后进程崩溃名额会泄漏**，需按 role 集合重算修正 |
| `M.create(account)` | 81 | 建账号文档（`ensure_get_user` 的底层） | 文档 / `false, err, r` |
| `M.ensure_get_user(account)` | 95 | 取账号，不存在就建（并发下靠 upsert 收敛） | 账号文档 |

## `example/nodes/`

| 文件 / 方法 | 行 | 作用 |
| --- | --- | --- |
| `account/lualib/account_router.lua` · `max_role_count()` | 16 | 读 `max_role_count`（默认 5）并缓存 |
| · `bearer_token(req)` | 25 | 只从 `Authorization: Bearer` 取 token（不读 query，避免凭据进日志/Referer） |
| · `read_body(res, req)` | 36 | 解析 JSON body；空 body/坏 JSON/标量统一返回 `nil` 并记日志 |
| · `verify_token(res, token)` | 47 | 校验登录 token，失败时**已经把应答写回**，调用方直接 `return` |
| · `valid_role_name(name)` | 66 | 非空、不超 `res.param.NameLimit`、不含控制字符；上限每次现读，`reload_res` 后立即生效 |
| · `get_roles(account, query)` | 136 | `/roles` 的实现体：查角色并投影出 `rid/server/name` |
| · 其余 5 个路由函数 | 81/104/132/140/167 | `/dev_login`、`/servers`、`/gates`、`/roles`、`/create_role` 的注册与处理 |
| `account/main.lua` · `launcher_accountnode()` | 7 | Account 节点入口：起 launcher、按 `account_http_port`/`account_agent_count` 开 HTTP 服务、注册 `account_router`，然后 `skynet.exit()` |
| `gateway/main.lua` | 12 | 独立网关入口：只起 launcher 与 gate，不承载实体（无命名函数） |
| `robot/main.lua` | 22 | 机器人节点入口：按 `robot_count` 起若干 `robot/robotagent`（无命名函数） |
| `robot/robotagent/main.lua` · `play(s, rid)` | 17 | 跑一遍业务：`role.login_info` → `bag.get_bag` → 自寄邮件 → 等可靠消息 → `mail.list` → `rank.submit` → `rank.top` |
| · `check_resume(s)` | 31 | 续接验收：断线重连后检查「还是同一会话、凭据已轮换、下行计数没倒退」 |
| · `run(transport, gate, role, token)` | 56 | 单条传输上跑完整链路；网关没有 WS 端口时跳过 ws 那轮 |
| · `CMD.start(conf)` | 99 | 机器人服务入口：建 Account 客户端、登录、选服、建角/选角、按 `robot_transports` 逐种传输跑 `run` |
| · 回调表 | 69-79 | `token`/`rid`/`server`（出生服）/`proto_checksum`/`on_push`/`on_state` 由 SDK 回调使用 |
| `role/main.lua` · `launcher_entities()` | 8 | Role 节点入口：为 `role`、`rank` 各起 `entity_agentmgr` 并 `call "start"`，起 `admin`，`gate_port` 存在时同进程再起 gate |
| `role/modules/bag/init.lua` · `M.new(entity, data)` | 7 | 绑定实体与存档，返回模块对象 |
| · `M:add_item(res_type, res_id, count)` | 24 | 加道具；`count` 必须是正整数，否则断言失败 |
| · `M:count(res_type, res_id)` | 39 | 查某道具数量（`res_size`），没有返回 0 |
| · `M:snapshot()` | 46 | 转协议用数组：先按 `res_id` 再按 `res_type` 排序 |
| `bag/request.lua` · `M.get_bag(request, fd, ctx)` | 5 | `bag.get_bag` 协议入口，回 `{ code = OK, bags = snapshot() }` |
| `mail/init.lua` · `max_mails()` | 9 | 读 `mail_max_count` 上限 |
| · `M.new(entity, data)` | 13 | 绑定实体与存档 |
| · `older(a, b)` | 20 | 邮件排序：`send_time` 升序，同时间比 `mail_id` |
| · `M:receive(mail)` | 29 | 收信：按 `mail_id` 去重（可靠消息至少一次），超上限按 `older` 淘汰最旧 | 是否真的收下 |
| · `M:list()` | 50 | 列表，新邮件在前 |
| · `M:claim(mail_id)` | 67 | 领附件并删信 | 是否找到该邮件 |
| `mail/request.lua` · `valid_text(s, max_len)` | 12 | 非空字符串且不超长 |
| · `M.list(request, fd, ctx)` | 16 | `mail.list` 入口 |
| · `M.send(request, fd, ctx)` | 23 | `mail.send` 入口：**校验参数后发可靠消息**，不直接改别人数据，由对方 `recv_mail` 在自身串行队列里收下 | 参数错/角色不存在各有错误码 |
| · `M.claim(request, fd, ctx)` | 47 | `mail.claim` 入口 |
| `rank/request.lua` · `my_game(entity)` | 11 | 角色只记出生服，所属 game 每次现查区服目录（合服后自动切到新 game 榜） |
| · `M.submit(request, fd, ctx)` | 17 | `rank.submit`：按 `game` 做 `scoped_call`；rank 不反向 call 角色，所以不会互等死锁 |
| · `M.top(request, fd, ctx)` | 34 | `rank.top`：`count` 限上限 |
| `role/request.lua` · `M.login_info(request, fd, ctx)` | 6 | `role.login_info` 入口，回 `{ code, info, rid, name }` |

## `example/res/`

| 文件 | 行 | 作用 |
| --- | --- | --- |
| `hero.lua` | 24 | 英雄配表（数值与名称），由 `res` 模块加载 |
| `lazy/param.lua` | 16 | 全局参数表（`NameLimit=32`、`InitItem` 等）；首次读取时懒加载 |
| `lazy/hotfix_demo.lua` | 6 | 热更示例专用配表（只有 `version`） |

## `example/schema/schema.lock.lua`

`skyext schema` 的基线文件，结构为 `{ types = {...}, retired = { fields = {...}, types = {...} } }`（153 行）。`retired[结构名][字段名] = 类型` 记录不能再用的名字，`check` 用它与当前 `schema_define.lua` 做 diff。

## `example/service/`

| 文件 / 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `admin/main.lua` | 52 | 非实体服务示例：经可靠消息给角色发系统邮件（无命名函数） | — |
| `login/client.lua` · `M.new(conf)` | 18 | 为一条待登录连接建跟踪对象，起 `login_timeout` 定时器 | 到点未登录：记日志并 `gate:kick(fd)` |
| · `M.unbind(fd)` | 37 | 停止跟踪（登录成功移交实体时也会调） | — |
| · `M.closed(fd)` | 44 | 连接已断开（比 `unbind` 更彻底） | — |
| · `M.sender(fd, pack)` | 52 | 登录期回包一律**经网关** `push`：服务不知道连接是 TCP 还是 WS，直接写 socket 在 WS 上会是乱码 | 连接已不在跟踪表里就丢弃并告警 |
| · `M.get_obj(fd)` | 66 | 给 `sproto_api` 取协议 handler 的 `obj` | 跟踪对象或 `nil` |
| `login/login_request.lua` · `self_node()` | 16 | 读并缓存 `cluster_node_name` |
| · `proto_checksum_enable()` | 24 | 读 `proto_checksum_enable`（默认 false） |
| · `load_bind_role(fd, rid, gate_service, session_mode)` | 32 | 调 `router.bind_session` 把会话绑到角色实体，回 `{ code, rid, nonce, session_mode, session_epoch }` | 绑定失败按错误码回包 |
| · `M:login(fd, obj)` | 50 | 验 token → 校验 `proto_checksum` → 查角色 → 绑会话 | 各失败分支回不同错误码 |
| · `M:resume(fd, obj)` | 113 | 断线续接：**只认 nonce、不验 token、不查库**，实体不在内存直接失败，绝不触发实体加载 | 任何错误客户端都退化成走 login |
| · `M.ping()` | 134 | 登录阶段心跳，回 `{ sent = 0 }`（此时还没有会话计数） |
| `login/main.lua` · `CMD.open(fd, addr, gate_service)` | 18 | 网关把未绑定连接交给登录服务，建 client 对象 | `gate_service` 缺失直接断言 |
| · `CMD.client_msg(fd, data)` | 22 | 协议分发到 `login`/`resume`/`ping` |
| · `CMD.disconnect(fd)` | 26 | 清理连接状态 |

## `example/tools/`

| 文件 / 方法 | 行 | 作用 |
| --- | --- | --- |
| `proto2spb.lua` · `_gen_trunk_list(sproto_file, namespace)` | 4 | 递归展开 `include` 的 sproto 依赖，收集出待编译的 trunk 列表 |
| `browser_e2e.mjs` | — | Phaser 浏览器全链路 E2E；不进游戏部署包 |
| `etcd/docker-compose.yml` | — | 三节点 etcd（客户端 2379/2378/2377，peer 2380/2376/2374） |
| `mongodb/docker-compose.yml` | — | 单节点 MongoDB 6，27017 |
| `gamepass/` | — | 第三方 OAuth 鉴权服务（submodule，Go），签发 JWT 供联调 |
| `phaser-game/` | — | 示例 Phaser 客户端（submodule），登录/选服/建角/游戏场景 + TS SDK 接入 |
