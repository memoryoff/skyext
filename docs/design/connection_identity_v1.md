# ConnectionIdentity v1（服务器内部连接标识契约）

> **状态：设计契约（P00），由 `lualib/skyext/connection_id.lua` 实现。**
> 本文件定义的是服务器内部 RPC 的身份，不是客户端协议字段；客户端 sproto 格式不变。
> 对应方案：`docs/review-2026-11-10-hardening-plan.md` 与后续 v4.3 §1.1。

## 1. 解决的问题

当前登录服务用裸 `fd` 作 `g_clients` / `g_gates` 的键（`example/service/login/client.lua:12-16`），
而 `main.lua:3-4` 明确 `gate_tcp`、`gate_ws` 与独立 gate 节点共用同一个登录服务。
因此两类冲突都存在：

- 同一 fd 关闭后被复用，迟到的 `open` / `disconnect` / `push` 作用到新连接；
- 两个网关（或两个网关节点）各自产生 fd=9，`assert(not g_clients[fd])` 误报、
  `g_gates[fd]` 被后到者覆盖，登录响应被推到错误的网关。

`gate_tcp` 与 `gate_ws` 的帧格式不同，回包走错网关会直接变成乱码，所以身份必须携带来源网关。

## 2. 字符串格式

```
v1|<enc_node>|<enc_service>|<boot_id>|<seq>
```

| 字段 | 内容 | 约束 |
| --- | --- | --- |
| 前缀 | 固定 `v1` | 大小写敏感；未知版本一律拒绝 |
| `enc_node` | `cluster_node_name` 的编码 | 原始长度 ≤ 64 字节 |
| `enc_service` | 网关注册名的编码 | 原始长度 ≤ 64 字节（如 `.gate_ws`） |
| `boot_id` | 16 字节 CSPRNG 的小写 hex | 恰好 32 个 `[0-9a-f]`，每次进程启动生成一次 |
| `seq` | 该网关进程内的单调递增序号 | 正整数，十进制无前导零，`1 <= seq <= MAX_SEQ` |

分隔符固定为 `|`。整串长度上限 `MAX_CID_LEN = 438` 字节，来自最坏情况：
`v1`(2) + 4 个分隔符 + 两个 64 字节字段全部转义（2 × 192）+ `boot_id`(32) + `seq`(16)。
这样契约允许的任意合法字段组合都不会被长度检查静默拒绝。

## 3. 编码规则（规范性）

`enc_node` / `enc_service` 用百分号编码，保证分隔符不歧义、输出唯一：

- 保留字节：`A-Z a-z 0-9 . _ -`，原样输出；
- 其余每个字节编码为 `%` + 两位**大写** hex（例如 `|` → `%7C`，空格 → `%20`，`%` → `%25`）；
- UTF-8 多字节字符按字节逐个编码；
- 解析时拒绝：小写 hex 转义、不完整转义、对保留字节的多余转义（如 `%41` 代替 `A`）、
  以及字段中未转义的字面 `|`（它本身就是分隔符，会让字段数失配）。
  注意"原始字段含 `|`"是合法的：编码为 `%7C` 后可正常往返。

**输出必须是规范形式**：同一组输入永远生成同一字符串；`parse` 只接受规范形式，
不接受"语义相同但写法不同"的变体，从而保证 `cid` 可直接作为表键比较，无需先归一化。

## 4. API

```lua
local connection_id = require "skyext.connection_id"

-- 生成进程级 boot_id。random_bytes 可注入以便测试；
-- 省略时惰性 require("crypto").random_bytes(16)。
-- 成功返回 32 位小写 hex；随机源失败返回 nil, err（不向外抛异常）。
connection_id.new_boot_id(random_bytes)

-- 生成 conn_id。local_seq 必须是 Lua integer 子类型（7 可以，7.0 不行），
-- 避免 JSON/跨语言传来的浮点值静默变成不同身份。失败返回 nil, err。
connection_id.new(gate_node, gate_service, boot_id, local_seq)

-- 解析规范形式。失败返回 nil, err；不修改任何状态、不生成新 ID。
connection_id.parse(cid)

-- 校验（等价于 parse 成功），返回 true 或 false, err。
connection_id.validate(cid)

-- 两个规范字符串的身份比较（都是 nil/非法时返回 false）。
connection_id.equal(a, b)
```

`parse` 成功返回 `{ version, gate_node, gate_service, boot_id, local_seq }`，
其中 `local_seq` 是 Lua integer。

## 5. 失败策略

- **随机源不可用**：返回 `nil, err`；网关必须拒绝启动，不得用时间、PID 或固定值兜底。
- **计数器回绕**：`local_seq > MAX_SEQ` 时 `new` 返回 `nil, err`。**不回绕**；
  网关应停止接入并重启进程以更换 `boot_id`。`MAX_SEQ = 9007199254740991`（2^53-1）：
  `conn_id` 虽不进客户端协议，但会出现在日志、指标标签与运维工具中，取这个保守上界可避免
  任何用双精度解析的链路丢精度。
- **随机源错误信息**：固定文案，不回显注入异常的内容（可能含随机字节或本地文件路径）。
  `crypto` 模块缺失时明确报 `rng unavailable`，不与"随机源输出非法"混淆。
- **超长 / 非法字符 / 非规范形式**：一律 `nil, err`，不做静默截断或替换。
- 所有 `err` 是不含原始随机字节与敏感值的可读字符串。

## 6. 安全边界

- `conn_id` **只能由可信网关生成**，客户端不能自报；`parse` 只是解析工具，不构成授权。
- `conn_id` **不含 fd，也不能从 `parse` 反解出 fd**。`local_seq` 是网关进程内序号，与 socket fd 无关。
  下行路由仍需要一张 `conn_id -> 当前 fd` 的映射，且**三方都要维护**：网关的 `g_sessions`、
  登录服务的 `g_clients/g_gates`、实体侧连接的 `conn.fd`。用 `conn_id` 直接去查现有按数字 fd
  索引的表会静默丢包，P01 必须先建映射再切换身份参数。
- `boot_id` 解决"进程重启后 fd 与本地序号复用"；`gate_node` + `gate_service` 解决跨网关冲突。
- 登录服务仍须维护 `disconnect` 的短期 tombstone 与 `open` 的可确认注册（见方案 §1.1，不在本模块范围）。
- 本模块是纯 Lua、无 IO、无 yield、无全局可变状态，可在实体队列与 accept 回调内安全调用。

## 7. 兼容与发布

属于服务器内部 RPC 变更，`conn_id` 与裸 `fd` 不允许在同一登录服务中混用。
发布顺序：协议版本门禁 → 兼容读路径 → 所有网关/登录/Role 同版本切换 → 删除旧写路径。
详见方案 §1.1、§11.2。
