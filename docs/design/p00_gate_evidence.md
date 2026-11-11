# P00 门禁证据（v4.3 实施记录）

本文件记录 P00-A/B/C/D 四项门禁的**实际运行证据**：固定版本、真实命令与输出、每项证明的
合同、以及仍未覆盖的边界。方案要求 P00 保存代码 commit、Skynet 子模块 commit 和 Lua 版本，
这里逐项固定。

## 0. 环境

| 项 | 值 |
| --- | --- |
| 仓库 | `hanxi/skyext`，本地 `main` |
| 代码基线 | `071d701c4edcee8ee895bb5cf573bbe63ed280d6`（P00 探针在其之上） |
| `skynet/` 子模块 | `abc11d7b6ae0c79f940a5cd3dd3393dcb338277e` |
| Lua | `Lua 5.5.0  Copyright (C) 1994-2025 Lua.org, PUC-Rio` |
| 运行方式 | `./bin/skyext test <file>`，每个测试文件在独立 skynet 进程中执行 |

门禁结论：**P00-A、P00-B、P00-D 通过；P00-C 的协议级/调度级合同通过，真实网络 WS 回环
留待 P02 的集成环境执行**（见 §3 的边界说明）。`extract_critical_fields` 与
`advance_persisted_version` 目前是已冻结、已验证但**尚未接入生产加载/保存路径**的接口，
接线属于 P07。

## 1. P00-A：Sproto 解码 + 规范化 + HMAC

文件：`lualib/skyext/p00a_sproto_fingerprint.test.lua`（17 用例）

```text
$ ./bin/skyext test lualib/skyext/p00a_sproto_fingerprint.test.lua
  17 passing (230ms)
1 files, 1 passed, 0 failed, 0 errors
```

证明的事实：

1. **解码语义**（真实 `sproto.parse` / `request_encode` / `request_decode`）：
   - 嵌套 struct、`*Struct(key)` 形式的 map（解码为以 key 字段为索引的 Lua 表）、数组、
     二进制字符串、负数与 `9007199254740991` 均按原值解出；
   - 缺省字段**不出现**在解码结果里，不会被补成零值；
   - 显式空 map（`{}`）与缺失字段解码后不同，规范化后也是不同字节串；
   - `sproto:default()` 返回的 `__array` / `__type` 占位表**不能**当请求参与指纹，
     用例证明它与真实空请求的摘要不同。
2. **规范化稳定性**：同一语义、1000 种字段与 map 条目插入顺序，`canonical_lua_v1` 输出
   逐字节相同；整数 `2` 排在 `10` 前；数字 `1` 与字符串 `"1"` 不同；`2.0` 归一为 `2`，
   `-0.0` 归一为 `0`；数组顺序参与语义。
3. **指纹域**：同语义同摘要；不同值、不同协议名、不同数组顺序摘要不同。
4. **fail-closed**：环、函数、metatable、NaN、Infinity、超深、超宽、超大输入、非法协议名
   全部拒绝，不降级为"跳过指纹"。
5. **HMAC**：`crypto.hmac_sha256(key, msg)` 对 RFC 4231 Test Case 1/2 的输出逐字节匹配
   （`b0344c61...cff7`、`5bdcc146...3843`），输出 32 字节，参数顺序不可交换；用途分离域
   `skyext:fingerprint:v1` 与 `skyext:grant:v1` 不同。

**已知边界**：用例同时证明"常量 hash 函数会让不同输入得到同一摘要"——指纹模块只保证
32 字节摘要，hash 实现是否正确由上面的固定向量保证。生产接入时必须传
`crypto.hmac_sha256` 本身，不能传预绑定第一个参数的闭包。

## 2. P00-B：ORM 保留字段

文件：`lualib/skyext/critical_fields.test.lua`（9 用例）+ `lualib/skyext/critical_fields.lua`

```text
$ ./bin/skyext test lualib/skyext/critical_fields.test.lua
  9 passing (10ms)
1 files, 1 passed, 0 failed, 0 errors
```

用**真实 bson 编解码**（`bson.encode` / `bson.decode`）构造带
`_critical_intent_v1` / `_critical_ops_v1` / `_critical_outbox_v1` 的角色文档，证明：

1. 不提取直接 `orm.decode`：三个字段被原地删除，`dropped` 恰好是这三个名字——
   这就是"未决意图被当垃圾删掉"的证据；
2. `extract` 后：`clean` 里没有保留字段，`orm.decode` 的 `dropped` 为空，普通字段完整；
3. `extract` 不修改原始 BSON 表；`critical` 是深拷贝，改任一侧不影响另一侧；
4. 普通 `orm.snapshot_mongo` 的 `$set` / `$unset` 里**没有任何** `_critical_` 路径；
5. 未知版本字段（`_critical_intent_v2`）返回错误和字段名，**拒绝加载为可写实体**，
   不允许 ORM 静默丢弃；
6. 结构校验：intent 的 `op_id` / `op_type` / 32 字节 `param_hash` / `state="PREPARED"`；
   ops/outbox 的每个条目必须是带 `status` 的表；key 不允许 `.`、NUL、`$` 前缀；
7. 限制：深度 16、节点 4096、字节 512 KiB，**三个字段共享同一份预算**（不能各自
   512 KiB 把单文档上限放大成 1.5 MiB）；userdata/thread、环、超大值一律拒绝。

**已知边界**：`extract` 返回的 `clean` 只做浅拷贝（与原始文档共享普通字段的引用），
因为 `orm.decode` 之后原始表即丢弃；关键元数据本身是深拷贝。`dbmgr.load` 目前仍直接
`orm.decode`，**尚未接入 `extract`**——这是 P07 的改动项，本阶段只冻结并验证合同。

## 3. P00-C：WS 握手同步注册

文件：`service/gate_ws.test.lua`（31 用例）+ `example/service/login/client.test.lua`（6 用例）

```text
$ ./bin/skyext test service/gate_ws.test.lua
  31 passing (10ms)
1 files, 1 passed, 0 failed, 0 errors

$ ./bin/skyext test example/service/login/client.test.lua
  6 passing (10ms)
1 files, 1 passed, 0 failed, 0 errors
```

`service/gate_ws.lua` 已按 `RESERVED → HANDSHAKING → REGISTERING → ACTIVE → CLOSING → CLOSED`
实现，探针证明：

1. **配额无 yield 预占**：两次 accept 回调不让出，`maxclient=1` 时第二条在预占阶段被
   `close_fd`，计数保持 1（旧实现 fork 后自增，突发会超限）；
2. **可确认注册**：`handler.handshake` 用 `skynet.call` 等登录服务 `open` 返回 `true`；
   成功才进入 `ACTIVE`；登录报错或超时则 `websocket.close(1011)` + 幂等 `close_session`；
3. **不丢帧**：`http.websocket` 的 `read_handshake` 先写 101、再调用 `handshake`、最后
   才进读帧循环（`skynet/lualib/http/websocket.lua:176-186, 296-300`）。同步注册期间
   客户端发来的字节留在 socket 缓冲，由 TCP 窗口背压，不存在"已 ACTIVE 但帧被丢"的窗口；
   若状态机被绕过（未 ACTIVE 收到帧），直接 1011 断开而不是转发；
4. **超时补偿**：注册超时后关闭连接并通知登录端 `disconnect`；迟到的成功 ACK 会再补一次
   `disconnect`（登录端 `open` 已幂等），不会留下孤儿登录记录；
5. **fd 复用保护**：迟到 ACK 到达时如果 fd 已被新连接占用（token 不同），不再按 fd 补偿，
   避免踢掉新连接；
6. **登录端幂等**：同一 fd 重复 `open` 复用原记录、不重复挂登录超时定时器；`unbind`
   取消定时器；`open` / `disconnect` 任意顺序都不抛错；
7. **调度不互等**：`call_with_timeout` 用真实的 `skynet.fork` / `wait` / `wakeup`
   在 skynet 调度器上跑，连接协程等待期间其它连接协程继续执行；`skynet.timeout` 在测试里
   被替换成可手动触发的定时器，用例同时断言 5000ms → 500（1/100 秒）的单位换算。

**边界（必须记住）**：以上是**协议级 + 调度级**探针，使用真实的 `service/gate_ws.lua`、
真实的 skynet 调度器和真实的 `http.websocket` 调用顺序，但没有起真实端口做 WS 帧回环。
真实网络回环（含 TLS、分片帧、ACK 丢失）需要在 P02 的集成环境补一条
`SKYTEST_INTEGRATION=1` 用例；它不改变本节的合同结论，只是把传输层也纳入验证。

## 4. P00-D：只推进 `_version` 的持久化版本接口

文件：`lualib/orm/init.test.lua`（23 用例，新增 5 条）

```text
$ ./bin/skyext test lualib/orm/init.test.lua
  23 passing (0ms)
1 files, 1 passed, 0 failed, 0 errors
```

`orm.advance_persisted_version(doc, expected, next_version)`：

1. 只 `rawset` `_version`，**不清** `__dirty`、不动 `__revision` / `__changed_keys`；
2. 之后 `snapshot_mongo` 仍能提交原来的脏字段（嵌套 dirty 也在），且 `$set` 里**不含**
   `_version`（版本是 CAS 的 query 条件，不是被写的字段）；
3. `expected` 与当前版本不符时返回 `false` 且不改文档；
4. 非整数、负数、不前进（`next <= current`）的版本拒绝，不做截断；
5. 调用方之前通过 ORM 接口改过 `_version` 时，`__changed_keys._version` 会被清掉，
   下一次 `snapshot_mongo` 不会把 CAS 条件写回文档；
6. 与 `ack_mongo` 的差异被用例固定：`ack_mongo` 会清 dirty，`advance` 不会。

## 5. 复现命令

```bash
./bin/skyext test lualib/skyext/p00a_sproto_fingerprint.test.lua
./bin/skyext test lualib/skyext/critical_fields.test.lua
./bin/skyext test lualib/orm/init.test.lua
./bin/skyext test service/gate_ws.test.lua
./bin/skyext test example/service/login/client.test.lua
stylua --check .
luacheck .
lua scripts/ci/check_paths.lua .
```
