# critical_grant_v1（关键经济操作授权契约）

> **状态：格式层与签名接口已实现（`lualib/skyext/grant.lua`）；密钥设施与 P08 接入待实现。**
> 本文件定义客户端关键经济操作的**授权批次**，以及业务侧使用的稳定操作键。
> 它是 L2 业务幂等的入口，不替代 L1 的 `req_id` 会话缓存。

## 1. 目标与非目标

目标：

- 客户端不能自签授权；`grant` 只能由服务端签发。
- 同一个 `(rid, grant_id, seq)` 至多产生一次经济效果；同键换业务类型或参数必须拒绝。
- 热记录被归档、进程重启、换节点后，仍能判断某个操作是否执行过。
- 授权过期后**永不执行**，只能查询历史结果。

非目标：

- 不做跨实体事务（见 Outbox / Saga）。
- 不把 HMAC 当作消费去重：签名只证明"这张 grant 是服务端签发、字段未被篡改"，
  既不证明"未过期"，也不证明"这个 seq 没被用过"。过期判断与去重必须由调用方/落库保证。

## 2. 结构与字段

```text
OperationGrantV1 {
  version          = 1,            -- integer
  rid,                             -- integer，必须 > 0
  grant_id,                        -- 32 位小写 hex（16 字节 CSPRNG）
  issued_at,                       -- integer，服务端时间
  expires_at,                      -- integer，必须 > issued_at
  max_seq,                         -- integer，1..65535
  key_id,                          -- string，[A-Za-z0-9._-]+，≤64 字节
  mac                              -- 二进制，HMAC(key_id 对应密钥, canonical_fields)
}

CriticalRequestV1 {
  grant,                           -- 上面整份结构
  seq,                             -- integer，1..max_seq
  op_type,                         -- string
  business_parameters              -- 协议解码后的表
}
```

`seq` 是**可尝试使用的序号**，不是购买资格；业务条件（余额、限购、商品状态）每次仍由服务端校验。
同一个 grant 的多个 seq 可以乱序并发提交，不同 grant 之间互不影响。

`mac` 是信封字段：`sign` / `verify` 接受包含它的整表，但**永远不把它计入签名域**，
否则从 wire 解出的完整结构会因为多了 `mac` 而被拒。

## 3. 操作键 `op_id`

```
op_id = grant_id .. "_" .. four_digit_hex(seq)
例：  "0123456789abcdef0123456789abcdef" .. "_" .. "000a"
```

- `four_digit_hex(seq)` 固定 4 位小写 hex，`seq` 必须是 `1..65535` 的 Lua integer。
- **不是截断器**：`seq = 65536`、`0`、`-1`、`1.5`、`"1"` 一律拒绝，不能回绕或裁剪成 4 位，
  否则不同 seq 会碰撞成同一个去重键。
- `op_id` 只允许 `[0-9a-f]{32}_[0-9a-f]{4}`：不含 `.`、NUL、`$` 前缀，可直接作为 Mongo 字段名；
  它作为 `_critical_ops_v1` 的 map 键和 `op_ledger` 的唯一键。
- 解析只接受规范形式：大写 hex、`0000`、长度不符、多余字符一律拒绝。**不做归一化**，
  保证 `op_id` 可以直接做表键比较。

## 4. 字段规范化与签名

`canonical_fields(fields)` 用 `skyext.canonical_lua` 对字段表做确定性编码（键排序、类型标记、
长度帧），得到 `mac` 的输入。输出以 `SIGNING_DOMAIN = "G1"` 开头，与请求指纹的 `F1` 分开：
同一把密钥签不同用途的数据不能互换。因此：

- 字段顺序、表的插入顺序不影响签名；
- 整数值浮点（`rid = 1001.0`、`version = 1.0` 等）统一归一为 integer；`1.5` 这类非整数值仍拒绝；
- `mac` 可以出现在入参里，但不参与签名域；
- 缺字段与类型错误在编码前就被拒绝，不会签出一张字段不全的 grant。

**密钥不进本模块。** 签名接口由调用方注入：

```lua
grant.sign(fields, hmac_fn)          -- hmac_fn(key_id, canonical_bytes) -> mac
grant.verify(fields, mac, hmac_fn, equal_fn)
```

- `hmac_fn` 默认不存在，必须显式传入；服务端直接把 `crypto.hmac_sha256` 当 `hmac_fn`
  （key 第一、msg 第二），或写成
  `function(key_id, input) return crypto.hmac_sha256(resolve(key_id), input) end`。
  **禁止预绑定第一个参数**（例如 `function(input) return crypto.hmac_sha256("k1", input) end`）：
  那样 `key_id` 会占住形参、真实签名输入被丢弃，mac 与字段无关，篡改任意字段都能验签通过。
  这与请求指纹 `hash_fn` 的约束是同一条，P08 接入时必须用真实 crypto 跑一次"篡改必失败"的探针。
- `verify` 的 `equal_fn` 生产必须传 `crypto.const_equals`；默认的 `==` 仅供测试。
  这一点写在接口注释里，不靠调用方自觉。
- 密钥轮换：旧 `key_id` 在所有未到期 grant 的最大有效期 + 时钟偏差窗口内仍可验签；
  失效密钥不得再签新 grant。`key_id` 只标识对称密钥版本，HMAC 没有公钥。

## 5. 失败策略

| 情况 | 返回 |
| --- | --- |
| `grant_id` 不是 32 位小写 hex | `nil, err` |
| `seq` 越界/非 integer | `nil, err` |
| `op_id` 非规范形式 | `nil, err` |
| `fields` 缺字段、类型错、`expires_at <= issued_at` | `nil, err` |
| `hmac_fn` 缺失/抛错/返回空串 | `nil, err`（错误信息不回显密钥或 mac） |
| 验签不匹配 | `false, "mac mismatch"` |

所有 `err` 是可读分类信息，不含密钥、mac 或业务参数。

**`verify` 不做的事**（必须由调用方校验，否则会把"验签通过"误当成"授权有效"）：

- `expires_at` 与当前服务端时间；
- `seq` 是否落在 `1..max_seq`；
- `rid` 是否等于当前会话的角色。

模块本身没有时钟、没有会话上下文，这三条只能由 `critical.execute_client` 在进入 PREPARE 前完成。

## 6. 过期与查询

- 授权过期后**绝不执行业务**；`critical.query(grant_id, seq)` 只报告持久化事实：
  `COMMITTED` / `BUSINESS_REJECTED` / `PREPARED`(不确定) / `EXPIRED_NOT_EXECUTED` / `NOT_STARTED`。
- `rid` 必须来自已认证会话，查询接口不得接受客户端自报的 `rid`。
- 客户端不得在"不知道结果"时自动换 seq 重试；换 seq 等于发起一笔新操作，必须重新走业务流程。

## 7. 与 L1 / L2 的分工

| 层 | 键 | 覆盖范围 | 失效点 |
| --- | --- | --- | --- |
| L1 `session.resp_cache` | `req_id + fingerprint_version + hash` | 同一存活会话内的重传 | 进程重启、顶号、缓存淘汰 |
| L2 `_critical_ops_v1` / `op_ledger` | `(rid, op_id)` | 跨重启、跨节点、跨连接 | 仅受保留期限制 |

L1 命中不代表资产已持久化；L2 命中不依赖 L1 是否还在。两者都必须实现，不能互相替代。
