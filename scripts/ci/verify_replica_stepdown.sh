#!/usr/bin/env bash
# 真实副本集 stepDown 下的 CAS 语义验证（台账 V-01）。
#
# 单节点副本集只能证明命令被接受，不能证明多数派语义。这里在并发 CAS 中途
# 强制切主，验证：
#   * 旧 primary 的迟到写不会产生第二条记录；
#   * _version 与 hits 始终一致（每次成功更新都基于唯一版本）。
#
# 这个脚本必须**能失败**。曾经它把 stepDown 包在 try/catch + `|| true` 里、
# 只断言 `_version == hits`，于是：没有副本集、stepDown 没真的发生、
# 甚至一条更新都没成功（0 == 0），都会打印 "passed"——那就是假绿。
# 现在三条硬门禁：必须是 >=3 节点的副本集、必须真的换了 primary、必须真的写进去过。
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

fail() {
    echo "replica stepdown check FAILED: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 门禁 1：必须是 >= 3 节点的副本集。standalone / 单节点副本集下
# replSetStepDown 要么报错要么没有多数派语义，跑出来的绿毫无意义
# ---------------------------------------------------------------------------
TOPOLOGY=$(mongosh "$URI" --quiet --eval "
  const h = db.hello();
  print(JSON.stringify({
    setName: h.setName || null,
    primary: h.primary || null,
    writable: h.isWritablePrimary === true,
    members: h.hosts ? h.hosts.length : 0
  }));
" 2>/dev/null) || fail "无法连接到 $URI"

SET_NAME=$(printf '%s' "$TOPOLOGY" | sed -n 's/.*"setName":"\([^"]*\)".*/\1/p')
MEMBER_COUNT=$(printf '%s' "$TOPOLOGY" | sed -n 's/.*"members":\([0-9]*\).*/\1/p')
PRIMARY_BEFORE=$(printf '%s' "$TOPOLOGY" | sed -n 's/.*"primary":"\([^"]*\)".*/\1/p')

[ -n "$SET_NAME" ] || fail "目标不是副本集（setName 为空），stepDown 语义无从谈起"
[ "${MEMBER_COUNT:-0}" -ge 3 ] || fail "副本集只有 ${MEMBER_COUNT:-0} 个节点，无法验证多数派切主"

echo "topology: set=$SET_NAME members=$MEMBER_COUNT primary=$PRIMARY_BEFORE"

mongosh "$URI" --quiet --eval "
  const c = db.getSiblingDB('$DB').$COLL;
  c.drop();
  c.insertOne({_id:'op1', _version:0, hits:0});
" >/dev/null || fail "初始化探针文档失败"

# ---------------------------------------------------------------------------
# 并发 CAS：每轮读当前版本、按版本条件自增。切主期间的 NotWritablePrimary
# 是预期内的，吞掉；但"一条都没成功"必须被下面的 hits 断言抓住
# ---------------------------------------------------------------------------
PIDS=()
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
    PIDS+=($!)
done

sleep 0.5

# ---------------------------------------------------------------------------
# 门禁 2：真的切主。这里**不吞** stepDown 的结果，并且要求 primary 换人
# ---------------------------------------------------------------------------
STEPDOWN_RESULT=$(mongosh "$URI" --quiet --eval "
  try {
    const r = db.getSiblingDB('admin').runCommand({replSetStepDown: 30, force: true});
    print('ok=' + (r.ok === 1));
  } catch (e) {
    // 切主成功时驱动常常因为连接断开而抛错，这本身是"切了"的证据；
    // 但要把它和"命令根本没被接受"区分开，所以下面仍以 primary 是否换人为准
    print('threw=' + e.code);
  }
" 2>&1) || true

PRIMARY_AFTER=""
for _ in $(seq 1 30); do
    PRIMARY_AFTER=$(mongosh "$URI" --quiet --eval "print(db.hello().primary || '')" 2>/dev/null || true)
    if [ -n "$PRIMARY_AFTER" ] && [ "$PRIMARY_AFTER" != "$PRIMARY_BEFORE" ]; then
        break
    fi
    sleep 1
done

for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

[ -n "$PRIMARY_AFTER" ] || fail "切主后读不到新的 primary（stepDown 结果: $STEPDOWN_RESULT）"
[ "$PRIMARY_AFTER" != "$PRIMARY_BEFORE" ] || fail "primary 仍是 $PRIMARY_BEFORE，stepDown 没有真的发生（结果: $STEPDOWN_RESULT）"

echo "primary moved: $PRIMARY_BEFORE -> $PRIMARY_AFTER"

# ---------------------------------------------------------------------------
# 门禁 3：结果断言。hits >= 1 排除"全程没写成功"的空跑
# ---------------------------------------------------------------------------
mongosh "$URI" --quiet --eval "
  const c = db.getSiblingDB('$DB').$COLL;
  const count = c.countDocuments({});
  const d = c.findOne({_id:'op1'});
  if (!d) { throw new Error('probe document disappeared'); }
  print('documents=' + count + ' version=' + d._version + ' hits=' + d.hits);
  if (count !== 1) { throw new Error('duplicated document: ' + count); }
  if (d.hits < 1) { throw new Error('no successful update at all, the run proves nothing'); }
  if (d._version !== d.hits) { throw new Error('version and hits diverged'); }
" || fail "结果断言未通过"

echo "replica stepdown check passed"
