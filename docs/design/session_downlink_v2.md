# 下行协议 V2（DownlinkV2 / ClientAckV2）契约 v1

> 状态：P14 开工前冻结的 wire 契约。服务端与 Lua SDK 已实现并有单测；TypeScript SDK 与
> Gateway 内部 `owner_epoch` RPC 属于 P14/P15 的后续工作。基线 commit 以实际工作区为准。

## 1. 为什么需要这一层

现有下行是**隐式计数**：序号不在包里，两端各自数收到的包，只在 `resume` / `ping` 时对账。
这套机制无法支撑计划内 Role 迁移，因为网关无法证明"客户端实际收到并去重了哪个包"。
V2 把 `(session_epoch, seq)` 放进下行包，让客户端可以按序号去重、补缺口和连续确认。

**旧客户端不受影响**：`session_mode` 缺省为 `LEGACY(0)`，行为与改造前完全一致；
V2 必须在登录时显式协商。

## 2. 协商与生命周期

| 概念 | 生成时机 | 是否随 Role 迁移变化 |
| --- | --- | --- |
| `session_mode` | 完整登录时由客户端请求、服务端确认 | 否，会话终身锁定 |
| `session_epoch` | 创建 `session_io` 时（完整登录/顶号）随机生成 16 字节，编码为 32 位小写 hex | **否**，断线续接与计划内迁移都不变 |
| `seq` | 就是 `session_io.sent`，每发一个计数内下行 +1 | 否，原序号继续用 |
| `owner_epoch` | Role 每次取得新 Fence 后确定 | 是，但只在 Gateway 内部 RPC 中使用 |

- 服务端只接受 `session_mode ∈ {0,1}`，其它值返回 `PARAM_ERROR`，**不能**悄悄退回 LEGACY。
- 同一会话不允许半新半旧：`resume` 携带 `session_mode`，与现有会话不一致直接
  `RESUME_UNAVAILABLE`，客户端退化为完整登录。
- 客户端发现不同 `session_epoch` 时视为**另一次完整逻辑会话**，必须走登录/续接校验，
  绝不能把包当成同一会话的迁移重放。

## 3. wire 格式

### 3.1 登录/续接响应

`login(100)` 与 `resume(101)` 的 response 增加：

```text
session_mode  3 : integer   # 0=LEGACY, 1=V2
session_epoch 4 : string    # 32 位小写 hex
```

`resume` 的 request 也增加 `session_mode 3` 与 `session_epoch 4`（空串表示旧客户端不校验）。
登录响应**不套信封、不计数**（由登录服务直写网关），但必须携带 `session_epoch`；
绑定后立即产生的推送才是第一个计数内下行（seq=1）。续接响应同样不套信封，
是客户端在重放开始前的对账锚点。

### 3.2 DownlinkV2

固定 45 字节头 + 原始 sproto 包，Role 编码、Gateway 原样转发、不解码：

```text
magic           4 字节   "SKX2"
version         1 字节   2
session_epoch  32 字节   小写 hex
seq             8 字节   大端无符号，等于 session_io.sent
payload        剩余      sproto 编码的原始下行包
```

- `out_buf[seq]` 存**完整信封字节**。计划内迁移时原样重放，禁止 decode→换 epoch→re-encode。
- 网关只比较内部 RPC 的 `owner_epoch`，绝不解析客户端 sproto，也不解析信封里的 epoch。
- 三个传输层握手响应（`login.login` / `login.resume` / `login.ping`）都不套信封、不计数。

### 3.3 ClientAckV2

复用 `ping(102)`，不新开协议：

```text
ping.request  { recv, session_epoch, last_contiguous_seq }
ping.response { sent, acked, session_epoch }
```

- V2 会话只认 `(session_epoch, last_contiguous_seq)`；epoch 不匹配时**不推进 acked**，
  响应回显服务端当前 epoch，客户端据此发现串会话并重登。
- `last_contiguous_seq` 越界（小于 acked 或大于 sent）按计数失同步处理，标记会话不可续接。
- 只有连续确认才能裁剪 `out_buf`；乱序包由客户端缓存，重复 seq 不再交付业务层。

## 4. 客户端拿到 epoch 之前的行为

1. 登录请求前不得发送 ClientAckV2；LEGACY 的 `ping.recv` 在 V2 会话里被忽略。
2. 收到第一个 DownlinkV2 时可以从中采纳 epoch（登录响应就是这种情况），也可以等
   `login` / `resume` 响应体。两者必须一致。
3. 在 epoch 未知期间收到的计数内下行照常交付业务、照常缓存，但**不发送 ACK**；
   服务端不会因为没有 ACK 而丢包（`out_buf` 只增不减，除非溢出降级）。
4. epoch 已知后，`recv` 直接取信封 seq；不需要额外加一，也不存在"包括我自己吗"的差一错误。

## 5. 迁移不变量（P14/P15 共用）

- 同一逻辑会话 `session_epoch` 不变；Role 迁移只推进 Gateway 内部 `owner_epoch`。
- `sent` / `acked` / `out_buf` 原编号保留，`out_buf` 里已是完整信封，直接重放。
- 新 owner 用新 `owner_epoch` 调 `push(conn_id, owner_epoch, pack)`；旧 owner 的迟到 RPC
  被 Gateway 拒绝。

### 5.1 Gateway 内部 RPC（P14 已实现）

`lualib/skyext/gate_owner.lua` 是纯函数实现，`gate_tcp` / `gate_ws` 共用同一份语义：

| RPC | 语义 | 失败 |
|---|---|---|
| `bind(conn_id, owner_node, owner_service, owner_epoch)` | 绑定所有权；`epoch <= 当前` 一律拒绝（相等是重复投递，小于是迟到 RPC） | `false` |
| `push(conn_id, pack, owner_epoch)` | 只写 `epoch == 当前 owner_epoch` 且未越过屏障的包 | 静默丢弃 + `stale_pushes` 计数 |
| `freeze_owner(conn_id, owner_epoch, barrier_id)` | 从这一刻起丢弃 `epoch <= owner_epoch` 的下行；返回**网关本次所有权期间受理的下行数**（含写失败尝试），**不是**客户端已收包数 | `nil, reason` |
| `resume_owner(conn_id, new_epoch, owner_node, owner_service)` | 解冻并交出所有权；`new_epoch` 必须**严格更大**；受理计数归零 | `false` |
| `owner_state(conn_id)` / `stats()` | 只读观测 | — |

`owner_epoch` 的推进点：

- 完整登录创建新 `session_io` → `owner_epoch = 1`；
- 断线续接（`session.resume`）→ `owner_epoch + 1`，**wire 上的 `session_epoch` 与 `seq` 不变**；
- 计划内 Role 迁移（P15）→ 同样只推进 `owner_epoch`。

`epoch` 为 `nil` 的调用按"无版本信息"放行，保证升级期旧调用方不断流；生产路径必须带
`owner_epoch`。网关只比较这个整数，**绝不解码客户端 sproto**。
- 快照里的 `session_epoch` 与当前会话不一致、编码损坏、`out_buf` 断裂或超限时，
  拒绝无感迁移并安全退化为重连/完整登录，不能丢单个包后仍宣称成功。

## 6. 验收映射

| 用例 | 断言 | 落点 |
| --- | --- | --- |
| T27 | 客户端已收 seq 101、ACK 丢，新 Role 重放 101，客户端只交付一次 | `session.test.lua` 的 V2 ack/去重用例；SDK 的 `handle_v2` |
| T30 | 跨 TCP/WS 续接后首次 ACK 携带正确 epoch | `session.test.lua` 的 resume + epoch 不变用例；`session.ts` 对等实现 |
| 网关迟到旧 epoch | Gateway 只看内部 RPC `owner_epoch`，不解码 sproto | `gate_owner.test.lua`（纯函数）、`gate_ws.test.lua` 的 "ws owner epoch" |

## 7. 已知边界

- 服务端、Lua SDK、TypeScript SDK 的 V2 解码与 ACK 已实现；TS 侧只跑了 `tsc --noEmit`，
  bun 测试与真机 E2E 仍需在 P14 的 CI 里执行。
- `SessionSnapshotV1` 的编码/校验与恢复已交付（见 `session_snapshot_v1.md`），但六阶段迁移编排尚未接线，
  属于 P15/P14 的后续工作。
- 登录链路新增了 `session_mode` / `session_epoch` 参数与返回值，属于跨服务内部 RPC
  变更：部署时登录服务、网关与实体节点必须同版本；旧客户端不填新字段，仍按 LEGACY 工作。
- `seq` 使用 8 字节大端；JS 侧必须用 `BigInt` 读取后校验不超过 `Number.MAX_SAFE_INTEGER`，
  不能直接按 32 位截断。
- 本契约不改变 `resp_cache` 的语义：`req_id` 幂等仍按协议名 + 指纹判定，与 wire.seq 无关。
