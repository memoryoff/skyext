# 待环境验证项执行手册（V-02 ~ V-05、V-07）

> **这份文档解决什么**：`docs/review-2026-11-12-defect-register.md` §4 里剩下的 5 项，
> **没有一行是待写的代码**——代码已改完、单测与契约测试都已通过，缺的是"在真实多节点
> 环境里跑一遍并采集数值"。本文给出可直接照做的步骤、观察点与通过标准。
>
> **前置阅读**：V-06 容量压测与 V-01 三节点副本集切主均已跑过；本文主体覆盖其余四项
> + 一项本机做不了的硬件基准。
>
> **重要**：本文的命令按仓库当前配置（`example/etc/`）推导，
> 作者**没有**在完整多节点环境里跑过这些步骤。首次执行时请按实际报错调整，
> 并把踩到的坑补回本文——不要因为"文档这么写"就认为一定对。

---

## 0. 为什么这些不能靠单测

单测能证明"代码路径正确"，不能证明"真实故障下行为正确"。这四项的共同点是
**故障来自进程外部**：

| 项 | 外部故障 | 单测为什么覆盖不了 |
| --- | --- | --- |
| V-02 | 实体从一个进程搬到另一个进程 | 单测里两个节点是同一个 Lua VM，没有真实的跨节点 RPC、没有独立锁租约 |
| V-03 | Mongo 少数派不可用 | 单测的 fake CAS 是同步函数，不会真的阻塞、不会真的返回 `NotPrimary` |
| V-04 | etcd 租约过期 | 单测里租约是桩，不会真的因为 TTL 到期而消失 |
| V-05 | 真实 WebSocket 连接 | 单测里 transport 是内存管道，没有握手、没有 TCP 半开、没有内核缓冲 |

---

## 1. 环境准备

### 1.1 机器与依赖

- Linux（x86_64），4 核 / 8G 起步；容量基准（V-07）建议直接用目标机型
- `gcc`、`make`、`git`、`curl`、`jq`
- MongoDB 6.0+（要副本集，不是单机）
- etcd 3.5+（**三个实例**，配置里写死了 2377/2378/2379 三个端点）
- 不需要 Node.js，除非要额外写 WS 压测脚本（V-05 用仓库自带的 robot 即可）

```bash
# Debian/Ubuntu 示例
sudo apt-get update
sudo apt-get install -y build-essential git curl jq
# mongodb / etcd 按官方源安装，或用二进制解压
```

### 1.2 构建

```bash
git submodule update --init --recursive
make build                 # 等价于 make -C example build，会编译 skynet 并生成 bin/skynet
ls bin/skynet              # 必须存在，否则 ./bin/skyext serve 会直接报错
```

`make build` 之后 `logs/` 目录会自动创建。**构建失败时不要往下走**——
`./bin/skyext serve` 的第一件事就是断言 `bin/skynet` 存在。

### 1.3 MongoDB 副本集

`example/etc/nodes/common.app.lua` 里 `mongo_config` 指向 `127.0.0.1:27017`，
所以把副本集的主节点放在 27017（其余节点用别的端口）。

```bash
for i in 1 2 3; do
  mkdir -p /data/mongo$i
  mongod --replSet rs0 --port 2701$i --dbpath /data/mongo$i \
         --bind_ip 127.0.0.1 --fork --logpath /data/mongo$i.log
done

mongosh --port 27011 --eval 'rs.initiate({_id:"rs0",members:[
  {_id:0,host:"127.0.0.1:27011"},
  {_id:1,host:"127.0.0.1:27012"},
  {_id:2,host:"127.0.0.1:27013"}]})'

# 等 primary 选出来
mongosh --port 27011 --eval 'db.hello().isWritablePrimary'
```

若希望 27017 就是主节点，改 `--port` 或改配置里的 `port`，**两边必须一致**。

### 1.4 etcd 三节点

`distributed_lock`、`node_lease`、snowflake 机器号槽位、区服目录都依赖 etcd。
**没有 etcd 节点起不来**，不要试图跳过。

```bash
for i in 7 8 9; do
  mkdir -p /data/etcd$i
  nohup etcd \
    --name etcd$i \
    --data-dir /data/etcd$i \
    --listen-client-urls  http://127.0.0.1:237$i \
    --advertise-client-urls http://127.0.0.1:237$i \
    --listen-peer-urls   http://127.0.0.1:238$i \
    --initial-advertise-peer-urls http://127.0.0.1:238$i \
    --initial-cluster 'etcd7=http://127.0.0.1:2387,etcd8=http://127.0.0.1:2388,etcd9=http://127.0.0.1:2389' \
    --initial-cluster-token skyext \
    --initial-cluster-state new \
    > /data/etcd$i.log 2>&1 &
done

sleep 3
etcdctl --endpoints=http://127.0.0.1:2377,http://127.0.0.1:2378,http://127.0.0.1:2379 endpoint health
```

端口映射要与配置对齐：`common.app.lua` 的 `etcd_config.http_host` 是
`2379 / 2378 / 2377`，即 etcd9→2379、etcd8→2378、etcd7→2377。

### 1.5 必须改的配置

只改这三处，其余用仓库默认值。

**① GM token（必须改，否则 GM 接口直接禁用）**

`gm_auth_token` 需要 **≥16 字符**且不能是占位符（`secret.MIN_LENGTH = 16`，
黑名单含 `changeme` / `password` / `test` 等）。在 `example/etc/nodes/common.app.lua`
或各节点 `.app.lua` 里加一行：

```lua
gm_auth_token = "local-verify-7f3a9c1e5b2d"   -- 自己换，别用仓库里的值
```

**② 开启计划内迁移（V-02 必须）**

在 `example/etc/nodes/role1.app.lua` 和 `role2.app.lua` 里加（`common.app.lua`
的默认值是 `enabled = false`，且 `with_defaults` 会补齐 `adapter` / `type_name` /
`concurrency`，所以只写 `enabled` 就够）：

```lua
migration = { enabled = true }
```

启动时会校验 adapter 的必需方法（`list_entities / quiesce / freeze /
export / transfer / handoff / activate / fallback`），缺一个就启动失败——这是有意的，
不要为了"先起来"去删阶段。

**③ 关键经济链路服务（V-03 相关）**

要观察 Outbox 与归档行为，建议同时开启：

```lua
outbox_worker = { enabled = true }
critical_maintenance = { enabled = true }
```

这两个服务的 `CMD.start` 里有索引门禁，索引建不起来会让**节点启动失败**
（不降级成全表扫描）。索引缺失时先看 §6 的定位表。

### 1.6 启动顺序

必须按依赖顺序起，否则前一个还没 READY，后一个只会拿到"找不到 owner"。

```bash
./bin/skyext serve account1 &     # 7031 集群 / 8080 HTTP / 9090 GM / 9190 metrics
./bin/skyext serve gate1    &     # 7051 集群 / 7052 tcp / 7053 ws / 9094 GM / 9194 metrics
./bin/skyext serve role1    &     # 7011 集群 / 7012 tcp / 7013 ws / 9092 GM / 9192 metrics
./bin/skyext serve role2    &     # 7021 集群 / 7022 tcp / 7023 ws / 9093 GM / 9193 metrics

sleep 5
for p in 9190 9192 9193 9194; do
  curl -sf "http://127.0.0.1:$p/metrics" >/dev/null && echo "metrics $p ok" || echo "metrics $p DOWN"
done
```

四个 `/metrics` 都能抓到才算起来了。GM 口（9090/9092/9093/9094）默认只监听
`127.0.0.1`，需要远程访问时配 `gm_http_host`——**验证环境不要配成 0.0.0.0**。

---

## 2. V-02 · 双节点迁移回环

### 目的

证明一个**在线**角色能从 `rolenode1` 迁到 `rolenode2`，客户端不断线、不丢请求、
不重复执行。

### 步骤

```bash
TOKEN="local-verify-7f3a9c1e5b2d"

# 1) 先确认角色落在哪个节点：连 gate1，看 role1/role2 谁在加载
#    起 robot（它会走 account 的 /gates 发现网关，tcp 与 ws 各跑一遍）
./bin/skyext serve robot &

# 2) 角色上线后，在 role1 的 GM 口触发停服（timeout 是等实体卸载的秒数）
curl -s "http://127.0.0.1:9092/gm/execute?cmd=shutdown&timeout=60&token=$TOKEN" | jq .

# 3) 观察迁移各阶段
for i in $(seq 1 30); do
  echo "--- $i ---"
  curl -s "http://127.0.0.1:9192/metrics" | grep -E "migration_(phase_seconds|fallback_total)" || true
  sleep 1
done
```

> 迁移由 `node_shutdown` 的 `migrate` 阶段驱动，钩子命令就是
> `migration_coordinator` 的 `run`。所以触发入口是 GM 的 `shutdown`，
> 不是单独一条 "migrate" 命令。

### 观察点

| 看什么 | 在哪看 | 通过标准 |
| --- | --- | --- |
| 各阶段耗时 | `skyext_migration_phase_seconds{phase=...}`（9192） | 每阶段 P95 有数值，没有长时间挂在单一 phase |
| 降级率 | `skyext_migration_fallback_total{reason=...}` | 降级率 < 1%，且没有 `CRITICAL_UNKNOWN` 之外的 reason |
| 客户端是否断线 | robot 日志 `logs/robot.log` | 无重连、无 `req_id` 重传风暴 |
| 实体最终归属 | role2 的日志出现 `entity loaded`，role1 出现 unload | 只有一个节点持有该实体 |
| 网关屏障是否解除 | `skyext_gate_frozen_upstreams_total`（9194） | 迁移结束后不再增长 |

### 失败时的重点怀疑对象

- **卡在 `freeze`**：网关没确认屏障 → 看 9194 的 `skyext_gate_frozen_upstreams_total`
- **卡在 `handoff`**：目标抢不到锁 → 看 role2 日志里的 fence 报错
- **`fallback` 且 reason 是 `stage failed`**：`migration_stage` 被拒 →
  可能是上一轮的 abort 标记还在（见 A-07：现在每轮 barrier 唯一，正常情况下不该发生；
  真发生了说明 barrier 生成有问题，要抓日志里的 `barrier` 字段）

### 记录

```
V-02 结果：□ 通过  □ 失败
迁移实体数：____   耗时：____s
各阶段 P95：quiesce=____ freeze=____ export=____ transfer=____ handoff=____ activate=____
降级数/原因：____
客户端是否断线：____
```

---

## 3. V-03 · Mongo 网络分区

### 目的

证明多数派不可用时，关键操作**不会**重复扣资产，恢复后能归位。

### 注入方式（两种，任选）

**方式 A：SIGSTOP 挂住一个 mongod（最简单，不需要 root）**

```bash
PID=$(pgrep -f "mongod --replSet rs0 --port 27013")
kill -STOP $PID          # 模拟该节点失联
# 观察 30~60 秒
kill -CONT $PID          # 恢复
```

注意：三节点里挂掉一个还剩两个，**多数派仍然可用**，写入不会失败。
要真正制造"少数派"，需要挂掉**两个**：

```bash
kill -STOP $(pgrep -f "port 27012")
kill -STOP $(pgrep -f "port 27013")
```

**方式 B：iptables 丢弃（更接近真实分区，需要 root）**

```bash
sudo iptables -A INPUT  -p tcp --dport 27012 -j DROP
sudo iptables -A OUTPUT -p tcp --dport 27012 -j DROP
# 恢复
sudo iptables -D INPUT  -p tcp --dport 27012 -j DROP
sudo iptables -D OUTPUT -p tcp --dport 27012 -j DROP
```

### 步骤

1. 让 robot 持续打关键操作（`shop.buy` 之类会走 `critical.execute_client`）
2. 注入分区，持续 30~60 秒
3. 解除分区
4. 等 2 分钟让恢复流程跑完

```bash
# 全程盯这几个指标
watch -n 2 'curl -s http://127.0.0.1:9192/metrics | \
  grep -E "critical_(decisions_total|quarantined_total|same_owner_resume_total)|outbox_cas_retry_total"'
```

### 观察点

| 看什么 | 通过标准 |
| --- | --- |
| `skyext_critical_decisions_total{status="UNKNOWN"}` | 分区期间上升是**预期**的；恢复后应停止增长 |
| `skyext_critical_quarantined_total` | **必须为 0**。非 0 说明内存与库不一致，是严重问题 |
| 资产守恒 | 分区前后把角色 `gold` 与订单条数对一遍，**扣款次数 == 成功订单数** |
| `_critical_ops_v1` 唯一性 | 同一 `op_id` 只有一条（见下方核对命令） |
| `skyext_critical_same_owner_resume_total` | 恢复后同 owner 续做率上升是正常的（说明 PREPARED 被正确续做） |

分区结束后核对账本：

```bash
mongosh --port 27011 --eval '
  const d = db.getSiblingDB("role").role.findOne({ rid: <角色ID> });
  const ops = d._critical_ops_v1 || {};
  const seen = {};
  let dup = 0;
  for (const [id, op] of Object.entries(ops)) {
    if (seen[op.op_id]) dup++;
    seen[op.op_id] = true;
  }
  print("ops=" + Object.keys(ops).length + " dup=" + dup +
        " intent=" + (d._critical_intent_v1 ? "STILL_PREPARED" : "none"));
  if (dup > 0) throw new Error("duplicated op_id");
'
```

### 记录

```
V-03 结果：□ 通过  □ 失败
注入方式：□ SIGSTOP  □ iptables      持续时长：____s
分区期间 UNKNOWN 增量：____
quarantined 增量：____（必须 0）
资产核对：扣款____次 / 成功订单____条   □ 相等  □ 不等
op_id 重复数：____（必须 0）
残留 PREPARED：____（恢复后应为 0）
```

---

## 4. V-04 · etcd 租约抖动

### 目的

证明节点失锁后 **fence 严格前进**，旧持有者的写入会被拒绝（不会出现双主写）。

### 注入方式

**方式 A：挂住 etcd 让它无法续租（推荐，最贴近"网络抖动"）**

```bash
kill -STOP $(pgrep -f "name etcd7") $(pgrep -f "name etcd8")   # 挂两个，破坏多数派
# 等超过 lease TTL（看 distributed_lock 的租约时长配置）
sleep 30
kill -CONT $(pgrep -f "name etcd7") $(pgrep -f "name etcd8")
```

**方式 B：直接吊销租约（更确定，但需要知道 lease id）**

```bash
etcdctl --endpoints=http://127.0.0.1:2379 lease list
etcdctl --endpoints=http://127.0.0.1:2379 lease revoke <LEASE_ID>
```

### 观察点

| 看什么 | 通过标准 |
| --- | --- |
| 失锁后旧持有者的写入 | 被拒绝（日志里是 fence / lease 相关拒绝），**不能**成功写入 |
| 新持有者的 fence | 严格大于旧值 |
| 数据 | 同一实体的 `_version` 单调，没有回退 |
| `skyext_critical_quarantined_total` | 仍为 0（租约抖动不该导致隔离） |

**最容易漏的一条**：租约抖动期间如果进程还在跑，它可能"以为自己还持锁"。
要确认的是**库层面的 fence 校验**生效，而不是"日志没报错"。核对方法：
在抖动期间对同一实体发写请求，看被拒的那次是否留下 `_critical_ops_v1` 记录
（**不应该**留下）。

### 记录

```
V-04 结果：□ 通过  □ 失败
注入方式：□ SIGSTOP  □ lease revoke      TTL：____s
旧持有者写入结果：□ 被拒  □ 竟然成功（失败）
新 fence / 旧 fence：____ / ____
抖动期间是否产生 op 记录：□ 否  □ 是（失败）
```

---

## 5. V-05 · 真实 WebSocket 回环

### 目的

证明真实 WS 连接下的握手、迁移重放、上行幂等（`req_id` 去重）都成立。
**这一项 robot 已经覆盖了一半**：`robot.app.lua` 里 `robot_transports = { "tcp", "ws" }`，
同一套用例会在两种传输上各跑一遍。

### 步骤

```bash
./bin/skyext serve robot &          # 需要 account1 已在 8080
tail -f logs/robot.log
```

要单独压 WS，把 `robot.app.lua` 改成：

```lua
robot_transports = { "ws" }
```

### 观察点

| 看什么 | 通过标准 |
| --- | --- |
| 握手 | robot 日志无 `ws handshake` 失败 |
| 请求-应答 | 无超时、无 `INTERNAL_ERROR` |
| `req_id` 去重 | `skyext_session_dedup_hit_total{mode=...}` 在客户端重传时有命中，且**业务只执行一次** |
| 迁移期间的上行 | 屏障期被丢弃的上行，客户端重传后由新 owner 幂等回应（`skyext_gate_frozen_upstreams_total` 有增长但业务无重复执行） |

### 记录

```
V-05 结果：□ 通过  □ 失败
传输：□ tcp  □ ws  □ 两者
请求数/失败数：____ / ____
dedup 命中：____
迁移期间上行丢弃：____  重传后是否重复执行：□ 否  □ 是（失败）
```

---

## 6. V-07 · 容量基准（必须用目标机型）

### 目的

把 `MAX_OPS = 512`、保留期 7d、`CAPACITY_WARN_RATIO = 0.8` 这三个**初始配置**
换成有数据支撑的取值。

### 已有数据（不能当生产基准）

本机（macOS，单机三进程 mongod，`wiredTigerCacheSizeGB=0.25`）跑过一轮：

| 指标 | 数值 |
| --- | --- |
| Outbox 满载 512 事件文档 | ~190KB |
| 热账本满载 512 操作文档 | ~105KB |
| 触顶提交（腾 1 + 新增 1） | p50 66ms / p95 139ms |
| 归档一轮（64 upsert + 1 unset）有索引 | p50 104ms / p95 123ms |
| 归档一轮 **无索引** | p95 **4226ms** |

这组数字的用途只有两个：判断数量级、证明索引门禁不可省（34 倍差异）。
**生产容量必须重测。**

### 步骤

```bash
# 在目标机型上，对着真实副本集跑
scripts/ci/bench_critical_capacity.sh \
  "mongodb://<host1>:27017,<host2>:27017,<host3>:27017/?replicaSet=rs0" 40
```

脚本会输出文档体积、触顶提交延迟、有/无索引的归档延迟，并在文档体积超过
4MB 时直接失败（离 16MB 上限的告警线）。

### 怎么用这组数字调参

1. **`CAPACITY_WARN_RATIO`**：不要等撞顶。如果触顶提交的 P95 已经明显高于
   普通提交（本机是 66ms vs 普通提交的个位数毫秒），就把预警线往下调
   （0.8 → 0.6），给运维留出反应时间。
2. **`MAX_OUTBOX`**：真实约束是"每次提交要重写整份文档"。如果 P95 不可接受，
   降低上限比换硬件有效得多。
3. **`archive_limit`**：按 `archive_ops_per_sec` 与单角色每小时关键操作数算。
   本机 615 op/s、每轮 64 条，远快于产生速度；若目标机型慢一个数量级仍够用。
4. **保留期**：`_critical_ops_v1` 与冷账本的磁盘增长速率要用压测数据外推。

### 记录

```
V-07 结果：□ 通过  □ 失败
机型：____  CPU：____  RAM：____  磁盘：____  Mongo 版本：____
文档体积：outbox=____  ops=____
触顶提交 P50/P95/P99：____ / ____ / ____
归档（有索引）P50/P95：____ / ____   op/s：____
归档（无索引）P95：____
调整建议：MAX_OPS=____  WARN_RATIO=____  archive_limit=____  保留期=____
```

---

## 7. 结果回填

跑完后把结果贴回 `docs/review-2026-11-12-defect-register.md` §4 对应行，
状态从「待环境」改成「已通过」或「失败（附现象）」。

**只有实际跑过才能改状态。** 没跑就写"已通过"，等于把假绿又造一遍——
A-13 那两条假绿门禁就是这么来的。

---

## 8. 失败时的定位顺序

按这个顺序查，能覆盖绝大多数情况：

| 症状 | 先看 | 大概率原因 |
| --- | --- | --- |
| 节点起不来 | 启动日志第一屏 | ① etcd 没起 / 端口不对 ② `gm_auth_token` 没配或太短 ③ 索引门禁失败 ④ migration 开了但 adapter 缺阶段 |
| 索引门禁失败 | 日志里的 `create_index` 报错 | 权限不足 / 集合不存在 / 已有同名不同定义索引 |
| robot 连不上 | account 的 `/gates` 返回 | gate 没起，或 gate 没在 etcd 注册 |
| 迁移一直 fallback | `migration_fallback_total{reason}` | 逐个 reason 查：`stage failed` → barrier/暂存；`handoff refused` → 抢锁；`attach refused` → 网关 |
| 关键操作大量 UNKNOWN | `critical_decisions_total` + Mongo 日志 | 多数派不可用（预期）vs 真的有节点挂了（看 `rs.status()`） |
| Outbox 积压不降 | `skyext_outbox_pending_age_seconds` | 接收方不在线 / 投递器报错（看 `failed_reason`）/ 事件已 FAILED 等人工处理 |
| 文档体积异常大 | `bench` 输出 / `db.role.stats()` | Outbox 长期贴上限，或归档没跑（`skyext_critical_archive_lag_seconds`） |

---

## 9. 与代码层的对应关系

跑这些验证时，如果命中失败，先对照这张表确认是不是**已知的设计权衡**：

| 现象 | 是不是 bug | 依据 |
| --- | --- | --- |
| 同一角色的事件乱序到达 | **不是**，是主动取舍 | 毒事件隔离后放弃保序，见台账 §5 |
| 补偿 handler 被调用两次 | **不是**，补偿是至少一次 | 台账 §5、`saga.lua` 注释 |
| 迁移冻结期上行被丢弃 | **不是** | 协议无对应 errcode，客户端按超时重传，见台账 §5 |
| 容量触顶时 DELIVERED 被提前删 | **不是**，是有意放弃保留期 | 台账 §5 |
| FAILED 事件 1 小时后被腾挪 | **不是**，有最小保留期下限 | `OUTBOX_FAILED_MIN_RETENTION` |
| `quarantined_total` 非 0 | **是** | 内存与库不一致，必须查 |
| 同一 `op_id` 两条记录 | **是** | 资产可能重复执行 |
| 旧持有者在失锁后仍写入成功 | **是** | fence 失效 |
