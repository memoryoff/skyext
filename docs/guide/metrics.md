# 指标采集与导出

skyext 内置 counter / gauge / histogram 三种指标原语，节点上的 `metrics` 服务把各服务的指标合并后按 Prometheus 文本格式导出。

## 工作方式

每个 skynet 服务是独立的 Lua 虚拟机，指标先在本地累加——热路径上的自增是纯内存操作，不发消息。抓取时 `metrics` 服务才向注册过的服务各发一条 `collect_metrics`，把快照拉回来合并。

推模式每次自增都要发一条消息，热路径上扛不住，所以这里用拉模式。代价是抓取瞬间要跟每个服务通一次消息，因此抓取是并发的，并且带超时：

- 单个服务没在 `metrics_scrape_timeout` 内回包，这次抓取就不等它；
- 连续 3 次没回就把它摘掉。服务退出时不会（也不该指望它）来注销。

服务用 `skyext.cmd_api` 接管消息分发时就自动挂到 `.metrics` 上，业务代码不需要写初始化。队列积压、内存、CPU 这些运行时数据因此默认就可见，不用等业务先声明一个指标。`.metrics` 比业务服务起得晚时按每秒一次重试，10 次都找不到就打一条 WARN 并放弃，这个服务的指标不会被导出。

自己接管 `skynet.dispatch` 的服务挂不上去——它应答不了 `collect_metrics`，所以连运行时数据也没有。

## 声明和使用

```lua
local metrics = require "skyext.metrics"

-- 第三个参数是标签名数组，声明之后每次自增都必须把这些标签传全
local m_calls = metrics.counter("game_commands_total", "Commands handled", { "cmd" })
local m_online = metrics.gauge("game_online_players", "Players currently online")
local m_latency = metrics.histogram("game_command_seconds", "Command handling time", { "cmd" })

m_calls:inc(1, { cmd = "move" })
m_online:set(count)
m_latency:observe(0.012, { cmd = "move" })
```

| 原语 | 方法 | 用在哪 |
| --- | --- | --- |
| `metrics.counter(name, help, labels)` | `inc(value, labels)` | 只增不减的累计量，名字按约定以 `_total` 结尾 |
| `metrics.gauge(name, help, labels)` | `set/inc/dec(value, labels)` | 可上可下的瞬时值，比如在线数、连接数 |
| `metrics.histogram(name, help, labels, buckets)` | `observe(value, labels)` | 耗时和大小的分布，`buckets` 默认覆盖 5ms 到 10s |

几条约束是故意报错而不是容忍的：

- **漏传标签直接抛错。** 少一个标签会让两条本该分开的曲线悄悄叠在一起，这种数据错得无声无息。
- **counter 不能减。** 减了下游算出来的速率是错的。
- **同名指标类型或标签对不上会抛错。** 这说明是重名事故，不是复用。

标签的取值范围要有限。按玩家 ID、服务地址这类打标签会把时间序列数量打爆——需要区分来源时想清楚基数，默认用服务名这种收敛的维度。

## 抓取端点

`metrics` 服务监听独立端口，`GET /metrics` 返回文本格式：

```lua
metrics_http_host = "127.0.0.1" -- 默认 127.0.0.1
metrics_http_port = 9190 -- 默认 9091，按节点配，同机跑多个节点才不会撞
metrics_scrape_timeout = 300 -- 单次抓取等回包的时限，单位 1/100 秒
```

默认只听回环。这个端点**不鉴权**，暴露出去等于把内部拓扑和业务量公开，线上让 Prometheus 从同机或内网侧抓。

示例里 account1 / account2 / role1 / role2 / gate1 分别用 9190 / 9191 / 9192 / 9193 / 9194：

```sh
curl http://127.0.0.1:9190/metrics
```

也可以走 `/gm/execute?cmd=metrics` 拿同一份文本，需要 `gm_auth_token`（见 [GM HTTP API](gm_api.md#鉴权)）。

## 内置指标

节点起来就有的，不需要业务代码配合：

| 指标 | 类型 | 含义 |
| --- | --- | --- |
| `skynet_services` | gauge | 节点上运行的服务数 |
| `skynet_service_instances{service}` | gauge | 按服务名统计的实例数 |
| `skynet_service_mqlen{service}` | gauge | 消息队列积压，同名实例求和 |
| `skynet_service_mqlen_max{service}` | gauge | 积压最多的那个实例的队列长度 |
| `skynet_service_memory_bytes{service}` | gauge | Lua 堆占用 |
| `skynet_service_cpu_seconds_total{service}` | counter | 累计 CPU 时间 |
| `skynet_service_messages_total{service}` | counter | 累计处理的消息数 |
| `skyext_mongo_call_seconds{op}` | histogram | MongoDB 调用耗时，在调用方计时 |
| `skyext_mongo_call_errors_total{op}` | counter | 抛错的 MongoDB 调用数 |
| `skyext_http_connections{server}` | gauge | 正在处理的 HTTP 连接数 |
| `skyext_http_connections_rejected_total{server}` | counter | 因连接数上限被拒的连接 |
| `skyext_metrics_services` | gauge | 注册到 `.metrics` 的服务数 |
| `skyext_metrics_scrape_failures` | gauge | 本次抓取没回包的服务数 |
| `skyext_metrics_scrape_duration_seconds` | gauge | 本次抓取耗时 |
| `skyext_reliable_msg_pending{type}` | gauge | 本 VM 观察到的可靠消息 pending 条数（满页时是下界） |
| `skyext_reliable_msg_retryable_total{type}` | counter | handler 返回环境故障的转换次数 |
| `skyext_reliable_msg_retry_escalated_total{type}` | counter | 同一 `msg_id` 连续 N 次环境故障后升级人工的次数 |
| `skyext_critical_decisions_total{status}` | counter | 关键操作的决策次数，`status` 取 `COMMITTED`/`BUSINESS_REJECTED`/`PRECHECK_REJECTED`/`OP_CONFLICT`/`UNKNOWN`/`IN_PROGRESS` 等 |
| `skyext_critical_quarantined_total{reason}` | counter | 关键缓存被隔离的次数，`reason` 取 `apply_raised`/`apply_rejected_after_mutating`/`commit_rejected` |
| `skyext_channel_members{channel}` | gauge | 本 VM 上每个频道的成员数 |
| `skyext_channel_broadcast_skipped_total{channel,reason}` | counter | 频道广播被跳过的次数，`reason` 取 `slow`/`deliver_failed` |
| `skyext_gate_connections{gate}` | gauge | 网关当前连接数 |
| `skyext_gate_stale_pushes_total{gate}` | counter | 因 owner_epoch 过期被丢弃的下行包数 |
| `skyext_gate_stale_binds_total{gate}` | counter | 因 epoch 不够新被拒绝的 owner 绑定数 |
| `skyext_outbox_enqueued_total{op_type}` | counter | Outbox 事件确认入队数 |
| `skyext_outbox_pending_scanned{type}` | gauge | 最近一次 Outbox 扫描页内按索引字段汇总的 PENDING 事件数；不是全库总量 |
| `skyext_outbox_scan_candidates{type}` | gauge | 最近一次 Outbox 扫描页命中的角色数 |
| `skyext_outbox_status_unknown_total{op_type}` | counter | Outbox 状态 CAS 结果未决的次数 |
| `skyext_charge_orders_total{status}` | counter | 支付订单进入各状态的次数 |
| `skyext_charge_grant_unknown_total{provider}` | counter | 发奖结果未决的次数（订单停在 `GRANTING`） |

服务名取自 `.launcher`，并且会抹掉实例间的差异：`mongo_conn:center:1` 归到 `mongo_conn`，`http_agent_gm_2` 归到 `http_agent_gm`。不这么做的话服务一扩容时间序列就跟着涨。不是由 `.launcher` 拉起的服务（比如 skynet 自己启动的 logger）归到 `unknown`。

`mqlen` 同时给了求和与最大值：100 个服务各积 1 条和 1 个服务积 100 条，求和是一样的，但后者才是故障。

MongoDB 耗时在调用方计时，量到的是业务真正等了多久——既包含 mongo 的响应时间，也包含连接服务自身的排队。只看 mongo 侧耗时会把「连接数不够」这类问题漏掉。

## 关键路径的告警口径

| 指标 | 建议告警 |
|---|---|
| `skyext_critical_decisions_total{status="UNKNOWN"}` | 持续 > 0 说明有未决的关键写入，必须对账；配合 `quarantined` 一起看 |
| `skyext_critical_quarantined_total` | 任意增长都要人工介入，隔离不会自愈 |
| `skyext_reliable_msg_pending{type}` | 长期不降说明接收侧卡住（见 `delivery.lua` 的升级计数） |
| `skyext_gate_stale_pushes_total` | 迁移窗口内有少量正常；持续增长说明有 owner 没换 epoch |
| `skyext_channel_broadcast_skipped_total` | 突增说明大批成员离线或发送队列满，先看网关连接数 |

## 合并规则

同名同标签的曲线一律相加。counter 相加是天然的；gauge 相加也正是想要的——4 个 dbmgr 各报 3 个脏实体，关心的是全节点有 12 个。`mqlen_max` 这类取最大值的指标单独处理。

两个服务用同一个名字声明了不同类型，或者直方图的桶边界不一致，合不了：丢掉后来的那一份，并记一条 ERROR 日志，而不是让数据莫名其妙少一半。

## 标签门禁

`scripts/ci/check_metrics_labels.lua` 会完整解析 `metrics.counter/gauge/histogram` 的调用和标签表。
标签参数必须是字面量表，且每项都是字符串；变量表、拼接表或动态元素会直接让 CI 失败，因为工具
无法静态证明它们保持低基数。`--self-test` 覆盖长表、跨行调用和动态标签 fail-closed，并在
`lint.yml` 中与实仓扫描一起执行。

## Prometheus 配置

```yaml
scrape_configs:
  - job_name: skyext
    static_configs:
      - targets: ["127.0.0.1:9190"]
        labels: { node: account1 }
      - targets: ["127.0.0.1:9192"]
        labels: { node: role1 }
```

每个节点一个端点。节点名用 Prometheus 侧的 `labels` 打，不要在指标里自己拼。
