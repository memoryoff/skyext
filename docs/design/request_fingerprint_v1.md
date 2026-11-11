# request_fingerprint_v1（请求指纹输入契约）

> **状态：§1 规范化编码、§2 指纹接口、P00-A 运行时探针（含真实 sproto 解码与
> RFC 4231 HMAC 向量）以及会话层接入（P03）均已实现。`resp_cache` 条目为
> `{fingerprint_version, name, hash, pack}`；没有 version/hash 的旧条目按
> `REQUEST_EXPIRED` 处理。**
> 本文件定义服务器内部如何把一个**已解码**的请求表变成确定性字节流，供会话层做
> `req_id` 参数摘要比对。它不改变客户端 wire 格式，客户端 SDK 不参与计算。

## 0. 为什么不用 Sproto schema 反射

当前 Skynet `lualib/sproto.lua` 暴露 `queryproto`、`querytype` 与 `core.default()`。
`core.default()` 实际能给出：字段名、标量粗类型（integer / 带 scale 的 integer / double /
boolean / string）、struct 的 `__type` 与 array 的 `__array` 标记（`lsproto.c` 的
`push_default` / `encode_default`）。**仍然拿不到**：字段 tag 顺序、map 的 key 类型、
map 与 struct 的区分。

即使如此，本契约仍选择**对解码后的 Lua 表做类型化递归编码**，理由是：

1. 不依赖类型名反射，schema 增删字段不会改变已有指纹的语义；
2. 不需要解析 `.sproto`，不改 `skynet/` 与 `3rd/sprotodump`；
3. 规则可以用纯 Lua 完整测试，不需要真实 sproto 运行时。

代价是"同一语义不同 Lua 表形状"无法归一（例如缺失字段与显式零值）；这一层由 §4 的等价规则约束。

## 1. `canonical_lua_v1` 编码规范（已实现）

### 1.1 帧格式

字符串与整数用 `frame := decimal_length ":" payload` 分帧；长度是 payload 的**字节数**，
十进制 ASCII、无前导零（`0` 除外）。table 的项数直接写成 `count ":"`，后面没有 payload。

```
value :=
    "N"                          -- 仅顶层 nil
  | "B" ("0" | "1")              -- boolean，固定 2 字节
  | "I" frame(signed_decimal)    -- Lua integer
  | "F" 8_bytes                  -- IEEE-754 double，大端（string.pack(">d")）
  | "S" frame(bytes)             -- string，二进制安全
  | "T" count ":" (key value){count}      -- table，按键排序后逐对拼接
```

`key` 只用 `B` / `I` / `F` / `S` 四种帧（table 不能作键）。

示例：

| 值 | 编码 |
| --- | --- |
| `nil` | `N` |
| `true` | `B1` |
| `42` | `I2:42` |
| `-7` | `I2:-7` |
| `"hi"` | `S2:hi` |
| `""` | `S0:` |
| `{}` | `T0:` |
| `{ "a", "b" }` | `T2:I1:1S1:aI1:2S1:b` |

### 1.2 数字归一

- `math.type(v) == "integer"` → `I` 帧，内容为 `tostring(v)`（十进制、无前导零）。
- `math.type(v) == "float"` 且 `math.tointeger(v)` 非 nil → **按 integer 编码**，
  所以 `2.0` 与 `2` 编码相同、`-0.0` 与 `0` 相同。
- 其余 float → `F` + `string.pack(">d", v)`，恰好 8 字节。
- `NaN`、`+Inf`、`-Inf` → 拒绝（fail-closed）。

### 1.3 表与排序

- `count` 是键值对数量；空表编码为 `T0:`。
- 键的排序是**全序**，依次比较：
  1. 类型序：`boolean(0) < number(1) < string(2)`；
  2. 同类型内：boolean `false < true`；number 按数值升序；string 按字节序升序。
- 因此整数 `2` 排在 `10` 前，数字 `1` 与字符串 `"1"` 是不同键且顺序固定。
- 数组（自然数键）与 map 使用同一套规则，不依赖运行时推断"这是 array 还是 map"。
- 同一张表的插入顺序不影响输出；同一子表可以出现在多个兄弟位置（DAG 允许），
  但**祖先链上重复**（环）拒绝。

### 1.4 上限与失败

| 限制 | 值 | 超限行为 |
| --- | --- | --- |
| 最大递归深度 | `MAX_DEPTH = 32` | 拒绝 |
| 最大节点数（表本身、键、值各计 1） | `MAX_NODES = 16384` | 拒绝 |
| 最大输出字节 | `MAX_BYTES = 256 * 1024` | 拒绝 |
| 协议名长度 | `MAX_PROTOCOL_LEN = 128` | 拒绝 |

节点口径等价于"最多 8191 对键值"。上限在**收集键时**增量判断，宽表不会先排完序再被拒绝；
长度帧也先算长度再拼接，不对大 payload 做整串拷贝。
`MAX_DEPTH = 32` 有意比 sproto 的编码深度上限（64）更严：游戏协议不应逼近任一上限。
`err` 文案仅供诊断，调用方应把非 nil 的 `err` 当作整体失败，不要依赖其内容。

拒绝一律返回 `nil, err`，`err` 是可读分类信息，**不含请求内容**。
任何拒绝都必须让调用方放弃执行非幂等 handler，不能降级成"不比对指纹"。

不接受的输入：function、coroutine、userdata/thread、带 metatable 的表、
NaN/Inf、环、table 作为键。

### 1.5 API

```lua
local canonical = require "skyext.canonical_lua"

-- 只编码值。成功返回 bytes；失败返回 nil, err。
canonical.encode(value)

-- 指纹输入：版本域 + 协议名帧 + encode(value)。
-- 版本域是 "F1"，协议名必须是非空、≤128 字节的 string。
canonical.encode_request(protocol_name, value)
```

`encode_request` 输出以 `ENCODING_DOMAIN = "F1"` 开头，与 `fingerprint_version=1` 一起构成
摘要域；两者任一变化都要整体提升，旧缓存按 `REQUEST_EXPIRED` 处理，否则新旧输入会混在一起。
协议名限定为 `[A-Za-z0-9._-]+`，最多 128 字节：它来自 `proto.name`，出现别的字节一定是上游拼错了。

## 2. 指纹计算（接口已实现，P00-A 已验证）

`lualib/skyext/fingerprint.lua` 提供：

```lua
fingerprint.compute(protocol_name, request, hash_fn)   -- -> 32 字节 digest | nil, err
fingerprint.entry_from_digest(digest, protocol_name, pack)
fingerprint.new_entry(protocol_name, request, pack, hash_fn)
fingerprint.matches(entry, protocol_name, request, hash_fn, equal_fn)
fingerprint.matches_digest(entry, protocol_name, digest, equal_fn)
```

`matches_digest` 用于摘要已经算好的路径：会话层在 handler 执行前算一次摘要，执行后
用同一个摘要写缓存，命中时也只比对摘要，避免对同一请求二次编码。

`hash_fn(domain, framed_bytes)` 由调用方注入，**两个参数**。生产直接把
`crypto.hmac_sha256` 当 `hash_fn` 传入（key 第一、msg 第二、输出 32 字节二进制），
或写成 `function(domain, input) return crypto.hmac_sha256(domain, input) end`。
**禁止预绑定第一个参数**（例如 `function(input) return crypto.hmac_sha256(DOMAIN, input) end`）：
那样 `domain` 会占住形参、真实输入被丢掉，摘要与请求无关，`matches` 会对同协议任意请求恒真。
固定域串是**非保密的用途分离键**，HMAC 在这里只作抗碰撞摘要，不用于验签；
Grant 使用独立的服务端保密密钥与 `G1` 域，两者不能互换。`equal_fn` 生产必须传
`crypto.const_equals`，默认的 `==` 仅供测试。

- 编码失败整体拒绝，不能把 `nil` 传给 HMAC。
- **摘要必须在业务 handler 执行之前、对解码后的请求表计算**。handler 可能修改入参，
  执行后再算会与重传请求对不上，全部落到 `REQUEST_CONFLICT`。`entry_from_digest`
  用于"先算摘要、执行完拿到 pack 再组装条目"。
- `new_entry` / `entry_from_digest` 要求 `pack` 是 string：`resp_cache` 的淘汰路径会取
  `#entry.pack`，`nil` 会让会话服务报错。
- `matches` 返回 `true` 或 `false, reason, kind`。调用方按 `kind` 映射错误码，
  **不要比较 reason 文案**：

  | kind | 含义 | 建议处理 |
  | --- | --- | --- |
  | `stale_version` | 条目缺版本或版本不符 | `REQUEST_EXPIRED` |
  | `protocol_mismatch` | 同 req_id 换了协议 | `REQUEST_CONFLICT` |
  | `invalid_hash` | 条目缺 hash 或长度不对 | `REQUEST_EXPIRED` |
  | `mismatch` | 参数不同 | `REQUEST_CONFLICT` |
  | `internal` | 编码/摘要/比较函数故障 | 整体失败，不回业务错误码 |

- `matches` 为 true **只说明参数相同，不代表业务已提交**；条目只能在 handler 产出 pack
  之后写入，不能为了"预热"提前写。
- `resp_cache` 条目格式是 `{fingerprint_version=1, name, hash, pack}`；缺版本或 hash 的
  旧条目一律按不可用处理，调用方返回 `REQUEST_EXPIRED`，不能猜测重放。
- 快照传输时 `hash` 用 `crypto.base64urlencode` 编码、安装时 `base64urldecode` 还原；
  `matches` 收的是**解码后的 32 字节原始值**，漏解码会让续接后的所有重传变成
  `invalid_hash`。`SessionSnapshotV1` 是方案中拟新增的契约，当前仓库尚未实现。
- 日志只打印指纹前 8 字节的 hex 与编码后长度；**禁止打印编码字节本身**——
  编码里的 `S` 帧就是请求明文，打印它等于绕过脱敏。

P00-A 探针必须先固定并验证：

1. `crypto.hmac_sha256(key, msg)` 的参数顺序与输出长度（当前实现是 key 第一、msg 第二、
   输出 32 字节二进制）；
2. 同一语义、不同插入顺序的表在 1000 次规范化后输出完全一致；
3. 不同语义（含混合键、64-bit 边界、空容器、缺省字段）产生不同摘要；
4. 环、非法类型、超限输入 fail-closed；
5. **接线正确**：同一协议下两个不同 request 经 `fingerprint.compute` 的 digest 必须不同；
   改 `fingerprint.DOMAIN` 后同一请求的 digest 必须变化。这条专门拦截"预绑定第一个参数"
   或忽略输入的实现——它们仍会返回合法的 32 字节长度。

**P00-A 已通过**：见 `docs/design/p00_gate_evidence.md` 的命令与输出。

## 3. 与 L1/L2 幂等的关系

- L1（`session.resp_cache`）用 `req_id + fingerprint_version + protocol + hash` 判重，
  解决同一存活会话内的重传；
- L2（`critical.execute_client` 的 `grant_id + seq`）解决跨登录、跨重启、跨节点的业务去重；
- 两者不可互相替代。L1 命中不代表资产已持久化，L2 命中也不再依赖 L1 是否还在。

## 4. 等价规则（必须由 P00-A 用真实解码结果确认）

sproto 解码器对**缺失字段**与**显式默认值**的实际表现决定了哪些请求会得到相同指纹。
本契约不预设二者等价：

- 若解码器补零值，则"缺失"与"显式 0"天然同形，属于同一语义；
- 若解码器保留缺失，则二者形状不同、指纹不同，调用方必须接受"同一业务意图可能有两个指纹"，
  或在上层把可选字段显式补全后再计算。

**实测结论（P00-A）**：当前 Skynet 解码器**不补零值**——缺失字段不出现在解码结果里，
显式空 map 会解码成空表，二者指纹不同。因此同一业务意图的"字段缺省"与"显式零值"
会产生两个指纹；服务端不替客户端补全可选字段，客户端重传时必须原样重发同一组字段。
用例：`lualib/skyext/p00a_sproto_fingerprint.test.lua` 的
"leaves absent optional fields absent" 与 "keeps an explicitly empty map distinct from a missing one"。
