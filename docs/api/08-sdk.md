# 08 · 客户端 SDK（Lua / TypeScript）

> 覆盖 `sdk/lua/skyext/client/`（`account.lua`、`session.lua`）与 `sdk/ts/src/`（除 `sproto/sproto.ts` 这类 vendored 文件只讲对外面）。
> 第二列是源码起始行号。协议规范见 `docs/guide/client_protocol.md`，登录流程见 `docs/guide/login.md`。

两根实现是同一套语义：**account 负责 HTTP 侧的登录/选服/拿网关，session 负责长连接侧的建连、续接、重发、心跳、重连**。

## `sdk/lua/skyext/client/account.lua`（157 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.new(conf)` | 17 | 建客户端；`conf.hosts` 是 account 服务地址列表，**随机挑起点**，失败换下一台（单地址就够了） | 无 `hosts` 或空列表断言失败 |
| `Account:request(method, url, token, body)` | 29 | 从随机偏移逐台试，直到拿到有效响应 | **只有传输失败/非 200 才换台**；`code ≠ OK` 是有效应答，原样返回由调用方判断；全部失败返回 `nil`。带 token 时加 `Authorization: Bearer` |
| `Account:dev_login(name)` | 76 | `POST /dev_login` 按账号名直接签发 token，不校验身份 | 只供本地开发与机器人；正式环境必须关掉 |
| `Account:servers()` | 89 | 服务器列表（免登录），最新开的服带 `recommended = true` | 失败 `nil`，成功可能是空列表 |
| `Account:pick_recommended_server()` | 100 | `recommended` 优先，否则取第一个 | 建角只能选 `status = "open"` 的服 |
| `Account:roles(token)` | 114 | 角色列表（带 Bearer） | 失败 `nil` |
| `Account:create_role(token, server, name)` | 124 | 建角 | 失败 `nil` |
| `Account:ensure_role(token, name, server)` | 134 | 有角色取第一个，没有就在指定服建 | — |
| `Account:gates()` | 148 | 在线网关列表（免登录） | 网关不写死在客户端配置里：列表来自 `node_lease` 上的注册，只含真在线的网关，客户端自己挑、连不上换一台 |
| `ok_result(res)` | 69 | `res.code == errcode.OK` | — |

`token` 是登录凭据：日志里**只允许记长度**这类非敏感信息。

## `sdk/lua/skyext/client/session.lua`（438 行）

传输抽象：`TRANSPORTS` 有 `tcp` 与 `ws` 两套实现，各提供 `connect/send/read/close`。

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `M.new(conf)` | 135 | `conf` 键：`transport`（`"tcp"`/`"ws"`）、`host`/`port`、`url`、`login_param`（**函数**，返回 `login.login` 请求体——token 会过期）、`on_push(name, msg)`、`on_state(state)`、`handshake_timeout` | 未知 transport 断言失败 |
| `Session:start()` | 408 | 建连 + 登录，并拉起三个协程：收包、重连、心跳 | **收包协程必须先起**：握手要等响应，没人收包只能等到超时 |
| `Session:request(name, param, timeout)` | 165 | 发请求等响应；`timeout = nil` 时一直等 | 续接之后在途请求会被原样重发，**等待跨越重连正是这套机制的意义**；只有握手类请求才给超时 |
| `Session:call(name, param)` | 416 | `request` 的别名（无超时） | — |
| `Session:establish()` | 328 | 建连并让会话可用：先 `try_resume`，不行再 `do_login` | 建连失败 `false`；成功时 `wakeup` 正在等连接的收包协程 |
| `Session:try_resume()` | 287 | `login.resume`（`rid`/`nonce`/`recv`） | 被拒即 `false`，退回完整登录 |
| `Session:do_login()` | 307 | `login.login` | 失败 `false` |
| `Session:resend_pending()` | 267 | 续接后重发在途请求 | **必须用原 request id**：服务端靠它认出重复请求、回缓存响应而不是重跑一遍 |
| `Session:fail_pending()` | 280 | 续接失败：会话状态已没了，在途请求全部失败 | — |
| `Session:send(req_id, p)` | 191 | 实际发送 | 传输抛错只 `warn` 并返回 `false`（真正的断线信号来自读失败） |
| `Session:handle(bytes)` | 215 | 解包分发：`"RESPONSE"` 唤醒等待者；重复响应（`req_id <= self.recv`）直接丢 | — |
| `Session:drop(conn)` | 254 | 处理断线 | **只处理「当前」这条连接**：迟到的断开通知不能影响新连接 |
| `Session:reader()` | 347 | 收包循环 | 断线后 `drop` 并唤醒 supervisor |
| `Session:supervisor()` | 367 | 重连循环（`reconnect_delay` 秒一次） | — |
| `Session:heartbeat()` | 378 | 心跳 | **必须看响应**：单向心跳只让服务端知道客户端活着，客户端什么也得不到。连续无 pong 就丢弃连接；`resp.sent` 与本地 `recv` 不一致说明下行计数错位，记 error |
| `Session:reconnect()` / `Session:close()` | 422 / 426 | 主动丢连接走续接（切网检测、测试用）/ 关闭 | — |
| `notify_state` / `answer` | 157 / 205 | 状态通知（`"online"`/`"offline"`/`"relogin"`）；唤醒等待者 | — |
| `packer` / `take_package` / `tcp.*` / `ws.*` | 36-117 | 包头组包/拆包（2 字节长度前缀）；TCP 用 socket、WS 用 websocket | — |

## `sdk/ts/src/account.ts`（194 行）

`AccountClient` 与 Lua 版一一对应：`devLogin`(117) / `servers`(126) / `pickRecommendedServer`(138) / `roles`(152) / `createRole`(162) / `ensureRole`(171) / `gates`(187)，失败一律返回 `null`；`AccountOptions`(16) 是构造参数。`roles` 的 `rid` 超过 2^53 时是 `bigint`。

## `sdk/ts/src/session.ts`（457 行）

`SessionClient` 是 Lua `session.lua` 的移植，方法一一对应：

| 方法 | 行 | 对应 Lua |
| --- | --- | --- |
| `start()` | 122 | `Session:start` |
| `request(name, param, timeoutMs)` | 122 | `Session:request`；`timeoutMs` 省略则一直等 |
| `reconnect()` / `invalidateNonce()` / `close()` | 168-177 | `reconnect`；`invalidateNonce` 丢弃续接凭据、下次直接完整登录（服务端说凭据失效时用） |
| `send` / `handle` / `drop` | 206-258 | 同名方法 |
| `resendPending` / `failPending` | 274 / 287 | 同名方法，同样要求**沿用原 request id** |
| `tryResume` / `doLogin` / `establish` | 294-341 | 同名方法 |
| `supervisor` / `heartbeat` | 395 / 409 | 重连循环 / 心跳（同样看响应、同样比对 `sent`/`recv`） |
| `sleep(ms)` | 441 | 可被 `close()` 立刻叫醒的 sleep——避免悬挂定时器拖住事件循环 |
| `notifyState(state)` | 198 | `"online"`/`"offline"`/`relogin` |

`LoginParam`(44) / `SessionOptions`(46) 是类型定义。

## `sdk/ts/src/client.ts`（144 行）

门面 `SkyextClient`：`enterGame(opts)`(85) 走 `/gates` 拿在线网关 → 按列表轮换建连 → 有凭据先试续接否则完整登录，返回首次握手是否成功（**失败不抛错**，会话层会持续重连）；`reconnect`(136) / `close`(140) 透传会话层。`SkyextClientOptions`(19)、`EnterGameOptions`(39) 是类型。

## `sdk/ts/src/codec.ts`（179 行）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `loadCodec()` | 108 | 从 `.spb`（`./bin/skyext generate proto` 的产物）建编解码器；`checksum` = spb 的 md5，填进 `login.login` 的 `proto_checksum`；schema 损坏时抛错 |
| `pack(name, args?, session?)` | 137 | 组包，返回 `Uint8Array` |
| `dispatch(data)` | 143 | 解包，返回 `REQUEST`/`RESPONSE` 结构；`RESPONSE` 带 `session`（即 request id） |

`CodecRequest`/`CodecResponse`/`CodecResult`/`Codec`(29-51) 是接口定义。

## `sdk/ts/src/transport.ts`（102 行）

`wsTransport` 是标准 WebSocket 实现（可注入：测试或 API 兼容的适配器）。`connect` 在 `onopen` 时 resolve；此后 `onclose`/`onerror` **归一成一次 `onClosed`**。`send` 在已断时会抛错，会话层容忍它——真正的断线信号是 `onClosed`。`Endpoint`(6) 里 `ws_url` 来自 `/gates`。

## `sdk/ts/src/bin.ts`（70 行，字节串 ↔ Uint8Array）

| 方法 | 行 | 作用 |
| --- | --- | --- |
| `toBytes(s)` / `fromBytes(b)` | 17 / 26 | latin1 字节串 ↔ `Uint8Array`（每字符只取 `charCode` 低 8 位，两者互逆） |
| `toText(b)` / `fromText(s)` | 43 / 48 | UTF-8 解码/编码 |
| `textToByteString(s)` / `byteStringToText(s)` | 53 / 58 | UTF-8 文本 ↔ latin1 字节串（sproto `string` 字段编解码前后的形态） |
| `toNumberArray(b)` / `fromNumberArray(a)` | 63 / 68 | `Uint8Array` ↔ `number[]`（vendored sproto 的输入输出都是 `number[]`） |

## `sdk/ts/src/json.ts`（99 行）

| 方法 | 行 | 作用 | 边界 |
| --- | --- | --- | --- |
| `parseJson(text)` | 89 | `JSON.parse` 的 int64 安全版：超 2^53 的整数还原成 `bigint`，其余语义不变 | — |
| `quoteUnsafeIntegers(text)` | 21 | 把不安全整数字面量换成哨兵字符串；逐字符扫描并跟踪「是否在字符串内」，**不会误伤字符串里的数字样文本** | — |

## `sdk/ts/src/md5.ts`（92 行）

`md5(data)`(21) 返回 16 字节摘要；`md5Hex(data)`(85) 返回小写 hex，与服务端 `md5.sumhexa` 输出一致（`proto_checksum` 靠这个对齐）。

## `sdk/ts/src/errcode.ts`（29 行）

`ErrCode`(6) 是与服务端同名的错误码常量表，`ErrCodeValue`(29) 是取值联合类型。

## `sdk/ts/src/types.ts`（50 行）

`GateInfo`(11) / `ServerInfo`(23) / `RoleInfo`(37) / `SessionState`(44) / `ProtoValue`(47) / `ProtoArgs`(50)。会话状态机 `SessionState` 里 `relogin` 表示续接失败、正在走完整登录。

## `sdk/ts/src/sproto/`

- `index.ts`（9 行）：`createNew()`(9) 建 vendored sproto 实例。
- `sproto.ts`（**2075 行，vendored**）：上游 sproto 的 TypeScript 移植，本仓库只做两处本地补丁——**字符串按 latin1 字节串处理**（不做 UTF-8 边界推断，交给 `bin.ts` 显式编解码），**64 位整数用 `bigint`**（避免精度丢失）。对外面就是 `SprotoHost`(47) / `SprotoInstance`(133) / `SprotoAPI`(152) 三个接口与 `SprotoValue`(31)、`SprotoArgs`(118) 类型。改这里要同步考虑 `bin.ts`/`json.ts` 的约定，不建议逐函数阅读。

## 一句话对照

| 关注点 | Lua SDK | TS SDK |
| --- | --- | --- |
| 登录/选服/网关（HTTP） | `client/account.lua` | `account.ts` |
| 长连接与会话状态 | `client/session.lua` | `session.ts` |
| 门面（进游戏） | 无（直接 `Session.new` + `start`） | `client.ts` |
| 编解码 | `skynet.sproto` / `host.attach` | `codec.ts` + `sproto/` |
| 字节与 int64 | Lua 天然支持整数与字符串 | `bin.ts`（latin1）+ `json.ts`（bigint） |
| 传输 | `tcp` / `ws`（`TRANSPORTS`） | `wsTransport`（可注入） |
