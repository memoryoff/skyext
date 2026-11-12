#!/usr/bin/env bash
# 关键账本 / Outbox 的容量压测（台账 V-06）。
#
# 为什么要有这个脚本：`critical` 的热账本有 512 条操作上限、Outbox 有 512 条事件上限，
# 归档每轮最多搬 64 条。这些数字此前只是"初始配置"，没有任何实测支撑——
# 没人知道 512 条事件的文档有多大、一次触顶提交要多久、归档一轮要多久。
# 没有这些数值，"容量够不够"就只能靠猜。
#
# 测的三件事：
#   1. 文档体积：512 条事件 / 512 条操作时的 BSON 大小（16MB 上限还有多少余量）
#   2. 触顶提交：容量腾挪 + 新增事件在同一次 CAS 里的耗时（P50/P95/P99）
#   3. 归档吞吐：一轮搬 64 条操作到冷账本 + 一次 $unset 的耗时
#
# 用法：scripts/ci/bench_critical_capacity.sh [mongo_uri] [rounds]
# 需要副本集（要 majority 写关注）。CI 不跑；本地步骤见 docs/design/p17_verification.md。
set -euo pipefail

URI=${1:-"mongodb://127.0.0.1:27021,127.0.0.1:27022,127.0.0.1:27023/?replicaSet=rs0"}
ROUNDS=${2:-40}
DB=skyext_capacity_bench
OUTBOX_MAX=512
OPS_MAX=512
ARCHIVE_BATCH=64

fail() {
    echo "capacity bench FAILED: $*" >&2
    exit 1
}

TOPOLOGY=$(mongosh "$URI" --quiet --eval 'print(db.hello().setName || "")' 2>/dev/null) || fail "无法连接到 $URI"
[ -n "$TOPOLOGY" ] || fail "目标不是副本集，majority 写关注无从验证"

echo "topology: set=$TOPOLOGY rounds=$ROUNDS outbox_max=$OUTBOX_MAX ops_max=$OPS_MAX archive_batch=$ARCHIVE_BATCH"

mongosh "$URI" --quiet --eval "
  const db_ = db.getSiblingDB('$DB');
  db_.dropDatabase();
  print('database reset');
" >/dev/null || fail "重置数据库失败"

# ---------------------------------------------------------------------------
# 1 + 2：Outbox 容量。构造一个"已满 512 条事件"的角色，然后反复做
# "腾掉一条 + 新增一条"的触顶提交，测量单次 CAS 的耗时
# ---------------------------------------------------------------------------
mongosh "$URI" --quiet --eval "
  const OUTBOX_MAX = $OUTBOX_MAX;
  const ROUNDS = $ROUNDS;
  const coll = db.getSiblingDB('$DB').role;

  function evt(i, status, at) {
    return {
      event_id: 'evt_' + i.toString(16).padStart(64, '0'),
      status: status,
      causal_seq: i,
      target_type: 'role',
      target_id: 1000 + i,
      op_type: 'mail.send',
      param_hash: 'a'.repeat(64),
      created_at: at,
      updated_at: at
    };
  }

  // 满容量：一半 DELIVERED（可立即腾），一半 ENQUEUED（未到期）
  const box = {};
  const now = Math.floor(Date.now() / 1000);
  for (let i = 1; i <= OUTBOX_MAX; i++) {
    box['evt_' + i.toString(16).padStart(64, '0')] = evt(i, i % 2 === 0 ? 'DELIVERED' : 'ENQUEUED', now - 100);
  }
  const doc = {
    _id: 'rid1', rid: 1, _version: 0, gold: 100,
    _critical_outbox_v1: box,
    _critical_outbox_pending_count: 0,
    _critical_outbox_seq: OUTBOX_MAX,
    _critical_ops_oldest_at: now
  };
  coll.insertOne(doc);

  const after = coll.findOne({ _id: 'rid1' });
  // mongosh 没有 Object.bsonsize；EJSON 长度是 BSON 的**上界**（JSON 更冗长），
  // 用它做体积断言是保守的
  const size = EJSON.stringify(after).length;
  print('outbox_doc_json_bytes=' + size + ' events=' + OUTBOX_MAX);

  // 触顶提交：一次写入里 set 新事件 + unset 一条旧事件 + 推进水位与计数
  const lat = [];
  let version = after._version;
  for (let r = 1; r <= ROUNDS; r++) {
    const victimId = 'evt_' + ((r * 2) % OUTBOX_MAX + 1).toString(16).padStart(64, '0');
    const newId = 'evt_' + (OUTBOX_MAX + r).toString(16).padStart(64, '0');
    const set = {};
    set['_critical_outbox_v1.' + newId] = evt(OUTBOX_MAX + r, 'PENDING', now);
    set['_critical_outbox_seq'] = OUTBOX_MAX + r;
    set['_critical_outbox_pending_count'] = 1;
    const unset = {};
    unset['_critical_outbox_v1.' + victimId] = true;

    const t0 = Date.now();
    const res = coll.updateOne(
      { _id: 'rid1', _version: version },
      { \$set: set, \$unset: unset, \$inc: { _version: 1 } }
    );
    lat.push(Date.now() - t0);
    if (res.modifiedCount !== 1) {
      throw new Error('capacity commit CAS missed at round ' + r);
    }
    version = version + 1;
  }
  lat.sort((a, b) => a - b);
  const pick = (p) => lat[Math.min(lat.length - 1, Math.floor(lat.length * p))];
  print('capacity_commit_ms p50=' + pick(0.5) + ' p95=' + pick(0.95) + ' p99=' + pick(0.99) + ' max=' + lat[lat.length - 1]);
" || fail "Outbox 容量压测失败"

# ---------------------------------------------------------------------------
# 3：归档吞吐。512 条操作的热账本，每轮搬 64 条到冷账本，再一次性 unset。
#
# 这里测两遍：先在没有索引的冷账本上测（模拟索引门禁被绕过），
# 再建好 `rid + op_id` 唯一索引测一遍。两组数字的差距就是门禁的价值——
# 没有索引时 upsert 是 COLLSCAN，延迟会随账本增长一路涨到秒级。
# ---------------------------------------------------------------------------
run_archive() {
    local label=$1
    mongosh "$URI" --quiet --eval "
      const OPS_MAX = $OPS_MAX;
      const BATCH = $ARCHIVE_BATCH;
      const ROUNDS = $ROUNDS;
      const db_ = db.getSiblingDB('$DB');
      const role = db_.role;
      const ledger = db_.critical_ledger;
      const now = Math.floor(Date.now() / 1000);

      role.deleteOne({ _id: 'rid2' });
      const ops = {};
      for (let i = 1; i <= OPS_MAX; i++) {
        ops['srv_' + i.toString(16).padStart(64, '0')] = {
          status: 'COMMITTED', op_type: 'shop.buy',
          param_hash: 'b'.repeat(64), at: now - 1000 + i
        };
      }
      role.insertOne({
        _id: 'rid2', rid: 2, _version: 0, gold: 100,
        _critical_ops_v1: ops,
        _critical_ops_oldest_at: now - 1000
      });
      const size = EJSON.stringify(role.findOne({ _id: 'rid2' })).length;

      const lat = [];
      for (let r = 0; r < ROUNDS; r++) {
        const base = (r * BATCH) % (OPS_MAX - BATCH);
        const t0 = Date.now();
        for (let i = 0; i < BATCH; i++) {
          const opId = 'srv_' + (base + i + 1).toString(16).padStart(64, '0');
          ledger.updateOne(
            { rid: 2, op_id: opId },
            { \$setOnInsert: { rid: 2, op_id: opId, status: 'COMMITTED', at: now, archived_at: now } },
            { upsert: true }
          );
        }
        const unset = {};
        for (let i = 0; i < BATCH; i++) {
          unset['_critical_ops_v1.srv_' + (base + i + 1).toString(16).padStart(64, '0')] = true;
        }
        role.updateOne({ _id: 'rid2' }, { \$unset: unset, \$inc: { _version: 1 } });
        lat.push(Date.now() - t0);
      }
      lat.sort((a, b) => a - b);
      const pick = (p) => lat[Math.min(lat.length - 1, Math.floor(lat.length * p))];
      print('archive_' + '$label' + '_ms p50=' + pick(0.5) + ' p95=' + pick(0.95) + ' p99=' + pick(0.99));
      print('archive_' + '$label' + '_ops_per_sec_p50=' + Math.round(BATCH * 1000 / Math.max(1, pick(0.5))));
      print('ops_doc_json_bytes=' + size + ' ops=' + OPS_MAX);
    " || fail "归档压测（$label）失败"
}

# 先清掉索引，测"门禁被绕过"的情况
mongosh "$URI" --quiet --eval "db.getSiblingDB('$DB').critical_ledger.dropIndexes()" >/dev/null 2>&1 || true
run_archive no_index

# 建好索引（与 critical.index_specs 里 colls.ledger 的定义一致）
mongosh "$URI" --quiet --eval "
  db.getSiblingDB('$DB').critical_ledger.createIndex(
    { rid: 1, op_id: 1 }, { name: 'rid_op_id', unique: true }
  );
" >/dev/null || fail "建索引失败"
run_archive indexed

# 结论断言：文档体积必须离 16MB 上限有足够余量，否则 512 条上限本身就危险
mongosh "$URI" --quiet --eval "
  const db_ = db.getSiblingDB('$DB');
  const role = db_.role;
  for (const id of ['rid1', 'rid2']) {
    const d = role.findOne({ _id: id });
    if (!d) { throw new Error('probe document ' + id + ' disappeared'); }
    const size = EJSON.stringify(d).length;
    // 16MB 上限；512 条事件占满时也必须留出一个数量级的余量
    if (size > 4 * 1024 * 1024) {
      throw new Error('document ' + id + ' is ' + size + ' bytes, too close to the 16MB limit');
    }
  }
  print('document size check passed');
" || fail "文档体积断言未通过"

mongosh "$URI" --quiet --eval "db.getSiblingDB('$DB').dropDatabase()" >/dev/null 2>&1 || true
echo "capacity bench passed"
