# 频道订阅与广播（v1）

> **状态：已实现（P16）。** 代码：`lualib/skyext/channel.lua`；
> 用例：`lualib/skyext/channel.test.lua`。

## 1. 边界

频道状态**在 Role 进程内**，不由网关持有。广播最终走 `session.push` /
`record_and_send`，因此仍由 Role 计数、写重放缓冲。

这不是实现偏好，是正确性要求：网关直接计数广播会让 `sent`/`out_buf` 出现两个
写入者，迁移时 seq 会被撕成两半，客户端重放立刻错位。

本模块只做**目录 + 鉴权 + 背压**，不碰网络。投递函数由调用方注入，因此它能跑在
实体队列里，也能在测试里换成纯函数。

## 2. 接口

```lua
local c = channel.new({ name = "world", max_members = 5000, batch_size = 256, max_failures = 3,
                        authorize = function(rid, name) return true end })
c:join(rid)      -- 幂等；已订阅会清掉 slow 标记（成员主动回来就算恢复）
c:leave(rid)
c:broadcast(payload, deliver, on_batch)  -- deliver 必须返回布尔 true；on_batch 用来 yield
c:size() / c:has(rid) / c:stats()
```

`channel.get_or_create(opts)` / `get` / `remove` / `list` 是进程内目录；跨节点广播由
调用方经 `router` 扇出，本模块不持有跨节点成员表（那会变成第二个一致性问题）。

## 3. 背压

| 策略 | 原因 |
|---|---|
| 单次广播按 `batch_size` 分批，每批结束回调 `on_batch` | 本模块是纯 Lua，不能自己 yield；调用方必须在 `on_batch` 里让出，否则一次 fanout 会长时间占住实体队列 |
| 投递失败只计 `skipped`，不重试 | 频道消息**可丢**；重试会把慢消费者拖成雪崩 |
| 连续 `max_failures` 次失败标记 `slow`，后续广播跳过 | 保护大多数，而不是保证每个都收到 |
| 成员重新 `join` 清除 `slow` | 没有额外的心跳机制，join 就是"我回来了"的信号 |
| 成员上限 `max_members` | 拒绝订阅比让单次广播无限增长安全 |

广播前先对成员列表做快照：投递过程中有人 `join`/`leave` 时，直接遍历内部数组
会跳过元素（Lua 的 `ipairs` 在 `table.remove` 之后会漏项）。

## 4. 观测

`skyext_channel_members{channel}`、`skyext_channel_broadcast_skipped_total{channel,reason}`。
`reason` 区分 `slow`（被摘掉的慢成员）与 `deliver_failed`（本次投递失败），
两者的处理方式不同：前者要查为什么一直失败，后者多半是离线。

## 5. 未覆盖

- 跨节点频道扇出与成员一致性属于后续工作；当前只提供单进程目录。
- 频道消息的可靠投递不在本模块范围内（可丢是设计选择，不是缺口）。
