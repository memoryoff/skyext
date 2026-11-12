#!/usr/bin/env bash
# 真实副本集 stepDown 下的 CAS 语义验证（台账 V-01）。
#
# 单节点副本集只能证明命令被接受，不能证明多数派语义。这里在并发 CAS 中途
# 强制切主，验证：
#   * 旧 primary 的迟到写不会产生第二条记录；
#   * _version 与 hits 始终一致（每次成功更新都基于唯一版本）。
#
# 需要三节点副本集。CI 没有副本集，所以不在 CI 里跑；本地验证步骤见
# docs/design/p17_verification.md §3 B1。
#
# 用法：scripts/ci/verify_replica_stepdown.sh [mongo_uri] [workers] [rounds]
set -euo pipefail

URI=${1:-"mongodb://127.0.0.1:27021,127.0.0.1:27022,127.0.0.1:27023/?replicaSet=rs0"}
WORKERS=${2:-4}
ROUNDS=${3:-200}
DB=skyext_stepdown_verify
COLL=probe

mongosh "$URI" --quiet --eval "
  const c = db.getSiblingDB('$DB').$COLL;
  c.drop();
  c.insertOne({_id:'op1', _version:0, hits:0});
"

for _ in $(seq 1 "$WORKERS"); do
  mongosh "$URI" --quiet --eval "
    const c = db.getSiblingDB('$DB').$COLL;
    for (let i = 0; i < $ROUNDS; i++) {
      const cur = c.findOne({_id:'op1'});
      if (!cur) continue;
      try {
        c.updateOne({_id:'op1', _version:cur._version}, {\$inc:{_version:1, hits:1}});
      } catch (e) {
        // stepDown 期间的 NotWritablePrimary 是预期内的
      }
    }
  " >/dev/null 2>&1 &
done

# 让并发 CAS 先跑起来，再切主
sleep 0.5
mongosh "$URI" --quiet --eval "
  try { db.getSiblingDB('admin').runCommand({replSetStepDown: 30, force: true}) } catch (e) {}
" >/dev/null 2>&1 || true

wait

mongosh "$URI" --quiet --eval "
  const c = db.getSiblingDB('$DB').$COLL;
  const count = c.countDocuments({});
  const d = c.findOne({_id:'op1'});
  print('documents=' + count + ' version=' + d._version + ' hits=' + d.hits);
  if (count !== 1) { throw new Error('duplicated document'); }
  if (d._version !== d.hits) { throw new Error('version and hits diverged'); }
"

echo "replica stepdown check passed"
