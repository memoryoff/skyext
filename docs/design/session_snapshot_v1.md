# 会话快照 v1 与迁移不变量（P15）

> **状态：快照编码/校验/恢复已实现；六阶段迁移编排未接线。**
> 代码：`lualib/skyext/session_snapshot.lua`；用例：`lualib/skyext/session_snapshot.test.lua`。

## 1. 为什么不能重编码

迁移的硬约束是：`session_epoch`、`sent`、`acked`、`out_buf` 必须**原样**过去。
客户端按 `(session_epoch, seq)` 去重，任何"重新编码"都可能改变字节长度或序号，
让客户端把同一会话当成两次。

因此快照只做搬运：`out_buf` 里已经是完整的 DownlinkV2 字节，编码时逐包写入，
解码时逐包取出，**不解码 payload**。

## 2. 格式

```text
"SKXS" | version u8 | mode u8 | epoch[32] ascii
| sent u64 | acked u64
| nonce_len u16 | nonce
| out_count u32 | (seq u64 | len u32 | bytes)*
| resp_count u32 | (req_id u32 | name_len u16 | name | len u32 | pack)*
| min_cached_req_id u32 | checksum u32
```

`checksum` 是 FNV-1a 32 位，只用于发现截断/错位，**不承担防篡改**：快照走的是
内部可信通道（同节点进程间或集群 RPC）。

## 3. 校验规则

| 检查 | 失败结果 |
|---|---|
| magic / version / mode | `BAD_MAGIC` / `BAD_VERSION` / `BAD_MODE` |
| epoch 是 32 位小写 hex | `BAD_EPOCH` |
| `acked <= sent` | `BAD_COUNTERS` |
| `out_count == sent - acked` 且 seq 连续 | `GAP` |
| 长度字段不越界、尾部无多余字节 | `TRUNCATED` |
| 包数/字节数/响应条目数上限 | `TOO_LARGE` |
| 校验和 | `CHECKSUM` |

**任何一条失败都拒绝迁移。** 宁可让客户端重连重新登录，也不能带着断掉的 `out_buf`
宣称"无感迁移"——那会把缺口变成客户端的永久失同步，而且客户端不会报错。

`restore` 还额外校验目标会话的 `session_epoch` 与快照一致：装错会话比迁移失败严重得多。

## 4. 迁移不变量

- `session_epoch` 不变（快照与目标会话必须相等）；
- `sent` / `acked` / `out_buf` 原编号保留，`out_buf` 原样重放；
- 只推进网关内部的 `owner_epoch`（`restore` 的 `opts.owner_epoch`），
  网关据此拒绝旧 owner 的迟到下行（见 `docs/design/session_downlink_v2.md` §5.1）；
- 新 owner 必须先 `freeze_owner` 再 `resume_owner`，屏障之前写出的包数以
  `freeze_owner` 返回的 `sent` 为准。

## 5. 未覆盖

- **六阶段迁移编排**（`DRAINING → QUIESCING → GATE_BARRIER → TRANSFER →
  RESUME → CLEANUP`）尚未接入 `node_shutdown`。当前只有快照的编解码与恢复原语。
- Role 停止所有入口（客户端/定时器/可靠消息/跨实体调用）并排空实体队列的
  `QUIESCING` 状态没有实现。
- 快照传输通道（集群 RPC 还是共享存储）与传输中的完整性校验尚未确定。
- `resp_cache` 的 `fingerprint_version/hash` 没有进快照：迁移后这些条目会退化成
  旧格式，`with_request` 会按 `REQUEST_EXPIRED` 处理（安全但会让在途请求重走流程）。
  这是有意的取舍——把 fingerprint 也搬过去需要同步 `fingerprint` 的版本演进。
