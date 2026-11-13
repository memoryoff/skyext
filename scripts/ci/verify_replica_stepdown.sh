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
# 用法：scripts/ci/verify_replica_stepdown.sh [mongo_uri] [workers] [max_iterations]
set -euo pipefail

URI=${1:-"mongodb://127.0.0.1:27021,127.0.0.1:27022,127.0.0.1:27023/?replicaSet=rs0"}
WORKERS=${2:-4}
MAX_ITERATIONS=${3:-100000}
DB=skyext_stepdown_verify
COLL=probe
CONTROL_COLL=probe_control
PIDS=()

fail() {
    echo "replica stepdown check FAILED: $*" >&2
    exit 1
}

case "$WORKERS" in
    ''|*[!0-9]*) fail "workers must be a positive integer" ;;
esac
case "$MAX_ITERATIONS" in
    ''|*[!0-9]*) fail "max_iterations must be a positive integer" ;;
esac
[ "$WORKERS" -ge 2 ] || fail "workers must be at least 2 to prove concurrent writes"
[ "$MAX_ITERATIONS" -ge 1 ] || fail "max_iterations must be at least 1"

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

wait_writers() {
    for pid in "${PIDS[@]}"; do
        local alive=0
        for _ in $(seq 1 100); do
            if ! kill -0 "$pid" 2>/dev/null; then
                alive=0
                break
            fi
            alive=1
            sleep 0.2
        done
        if [ "$alive" -eq 1 ]; then
            kill "$pid" 2>/dev/null || true
        fi
        wait "$pid" 2>/dev/null || true
    done
    PIDS=()
}

# ---------------------------------------------------------------------------
# 门禁 1：必须是 >= 3 节点的副本集。standalone / 单节点副本集下
# replSetStepDown 要么报错要么没有多数派语义，跑出来的绿毫无意义
# ---------------------------------------------------------------------------
TOPOLOGY=$(mongosh "$URI" --quiet --eval "
  const h = db.hello();
  const s = db.adminCommand({replSetGetStatus: 1});
  print(JSON.stringify({
    setName: h.setName || null,
    primary: h.primary || null,
    term: s.term ? Number(s.term) : null,
    writable: h.isWritablePrimary === true,
    members: h.hosts ? h.hosts.length : 0
  }));
" 2>/dev/null) || fail "无法连接到 $URI"

SET_NAME=$(printf '%s' "$TOPOLOGY" | sed -n 's/.*"setName":"\([^"]*\)".*/\1/p')
MEMBER_COUNT=$(printf '%s' "$TOPOLOGY" | sed -n 's/.*"members":\([0-9]*\).*/\1/p')
PRIMARY_BEFORE=$(printf '%s' "$TOPOLOGY" | sed -n 's/.*"primary":"\([^"]*\)".*/\1/p')
TERM_BEFORE=$(printf '%s' "$TOPOLOGY" | sed -n 's/.*"term":\([0-9]*\).*/\1/p')

[ -n "$SET_NAME" ] || fail "目标不是副本集（setName 为空），stepDown 语义无从谈起"
[ "${MEMBER_COUNT:-0}" -ge 3 ] || fail "副本集只有 ${MEMBER_COUNT:-0} 个节点，无法验证多数派切主"
[ -n "$TERM_BEFORE" ] || fail "无法读取切主前 term"

echo "topology: set=$SET_NAME members=$MEMBER_COUNT primary=$PRIMARY_BEFORE term=$TERM_BEFORE"

mongosh "$URI" --quiet --eval "
  const c = db.getSiblingDB('$DB').$COLL;
  const control = db.getSiblingDB('$DB').$CONTROL_COLL;
  c.drop();
  control.drop();
  c.insertOne({_id:'op1', _version:0, hits:0, pre_hits:0, post_hits:0});
  control.insertOne({_id:'run', phase:'pre', stop:false});
" >/dev/null || fail "初始化探针文档失败"

# ---------------------------------------------------------------------------
# 并发 CAS：每轮读当前版本、按版本条件自增。写入一直持续到新 primary 确认
# 并把 phase 切到 post 之后；同一个原子更新会按当时的 phase 累计成功写，
# 因此最终能证明切主前和切主后都真的发生过写入。
# 切主期间允许个别客户端连接掉线，所以门禁要求前后各有至少两个不同 worker
# 成功写入，而不是要求每个 mongosh 进程都跨越切主存活。
# ---------------------------------------------------------------------------
for worker in $(seq 1 "$WORKERS"); do
    mongosh "$URI" --quiet --eval "
      const d = db.getSiblingDB('$DB');
      const c = d.$COLL;
      const control = d.$CONTROL_COLL;
      for (let i = 0; i < $MAX_ITERATIONS; i++) {
        try {
          const run = control.findOne({_id:'run'});
          if (!run || run.stop === true) break;
          const cur = c.findOne({_id:'op1'});
          if (!cur) continue;
          const bucket = run.phase === 'post' ? 'post_hits' : 'pre_hits';
          const inc = {_version:1, hits:1};
          inc[bucket] = 1;
          inc[(run.phase === 'post' ? 'post_worker_' : 'pre_worker_') + $worker] = 1;
          c.updateOne(
            {_id:'op1', _version:cur._version},
            {\$inc:inc},
            {writeConcern:{w:'majority', j:true}}
          );
        } catch (e) {
          // stepDown 期间的 NotWritablePrimary 是预期内的
        }
      }
    " >/dev/null 2>&1 &
    PIDS+=($!)
done

# 先证明切主前已有并发写成功，避免 writer 还没启动就 stepDown 的假绿
PRE_READY=0
for _ in $(seq 1 30); do
    PRE_HITS=$(mongosh "$URI" --quiet --eval "print(db.getSiblingDB('$DB').$COLL.findOne({_id:'op1'}).pre_hits)" 2>/dev/null || echo 0)
    if [ "${PRE_HITS:-0}" -ge "$WORKERS" ]; then
        PRE_READY=1
        break
    fi
    sleep 0.2
done
[ "$PRE_READY" -eq 1 ] || fail "切主前没有形成并发成功写（pre_hits=${PRE_HITS:-0}, workers=$WORKERS）"

# 并发证明必须在 stepDown **之前**采样。writer 先读 control 里的 phase 再写，
# 切主完成到 phase 切到 post 之间成功的写仍然计进 pre_*：事后统计的
# pre_workers 会把切主后的写算成切主前，证明不了"切主前有两个 worker 并发成功"。
PRE_WORKERS=$(mongosh "$URI" --quiet --eval "
  const d = db.getSiblingDB('$DB').$COLL.findOne({_id:'op1'});
  if (!d) { print(0); quit(); }
  let n = 0;
  for (let i = 1; i <= $WORKERS; i++) { if (d['pre_worker_' + i] > 0) n++; }
  print(n);
" 2>/dev/null || echo 0)
[ "${PRE_WORKERS:-0}" -ge 2 ] || fail "切主前成功写的 worker 不足两个（pre_workers=${PRE_WORKERS:-0}, workers=$WORKERS）"

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

case "$STEPDOWN_RESULT" in
    *"ok=true"*|*"threw="*) ;;
    *) fail "replSetStepDown 没有得到明确响应（结果: $STEPDOWN_RESULT）" ;;
esac

PRIMARY_AFTER=""
TERM_AFTER=""
for _ in $(seq 1 30); do
    AFTER_TOPOLOGY=$(mongosh "$URI" --quiet --eval "
      const h = db.hello();
      const s = db.adminCommand({replSetGetStatus: 1});
      print(JSON.stringify({ primary: h.primary || null, term: s.term ? Number(s.term) : null }));
    " 2>/dev/null || true)
    PRIMARY_AFTER=$(printf '%s' "$AFTER_TOPOLOGY" | sed -n 's/.*"primary":"\([^"]*\)".*/\1/p')
    TERM_AFTER=$(printf '%s' "$AFTER_TOPOLOGY" | sed -n 's/.*"term":\([0-9]*\).*/\1/p')
    if [ -n "$PRIMARY_AFTER" ] && [ "$PRIMARY_AFTER" != "$PRIMARY_BEFORE" ] && [ -n "$TERM_AFTER" ]; then
        break
    fi
    sleep 1
done

[ -n "$PRIMARY_AFTER" ] || fail "切主后读不到新的 primary（stepDown 结果: $STEPDOWN_RESULT）"
[ "$PRIMARY_AFTER" != "$PRIMARY_BEFORE" ] || fail "primary 仍是 $PRIMARY_BEFORE，stepDown 没有真的发生（结果: $STEPDOWN_RESULT）"
[ -n "$TERM_AFTER" ] && [ "$TERM_AFTER" -gt "$TERM_BEFORE" ] || fail "term 没有前进（$TERM_BEFORE -> ${TERM_AFTER:-unknown}）"

echo "primary moved: $PRIMARY_BEFORE -> $PRIMARY_AFTER (term $TERM_BEFORE -> $TERM_AFTER)"

# ---------------------------------------------------------------------------
# 门禁 3：在新 primary 上开启 post 窗口，继续让同一批 writer 写。
# post_hits 只会在 primary 已经换人后累计，避免只看总 hits 的假绿。
# ---------------------------------------------------------------------------
PHASE_SET=0
for _ in $(seq 1 30); do
    PHASE_RESULT=$(mongosh "$URI" --quiet --eval "
      const r = db.getSiblingDB('$DB').$CONTROL_COLL.updateOne({_id:'run'}, {\$set:{phase:'post'}});
      print(r.modifiedCount);
    " 2>/dev/null || true)
    if [ "$PHASE_RESULT" = "1" ]; then
        PHASE_SET=1
        break
    fi
    sleep 1
done
[ "$PHASE_SET" -eq 1 ] || fail "无法在新 primary 上开启 post 写入窗口"

POST_READY=0
for _ in $(seq 1 30); do
    POST_HITS=$(mongosh "$URI" --quiet --eval "print(db.getSiblingDB('$DB').$COLL.findOne({_id:'op1'}).post_hits)" 2>/dev/null || echo 0)
    if [ "${POST_HITS:-0}" -ge "$WORKERS" ]; then
        POST_READY=1
        break
    fi
    sleep 0.2
done
mongosh "$URI" --quiet --eval "
  db.getSiblingDB('$DB').$CONTROL_COLL.updateOne({_id:'run'}, {\$set:{stop:true}});
" >/dev/null 2>&1 || true

wait_writers

[ "$POST_READY" -eq 1 ] || fail "切主后没有形成并发成功写（post_hits=${POST_HITS:-0}, workers=$WORKERS）"

# ---------------------------------------------------------------------------
# 门禁 4：结果断言。切主前后都必须有至少两个 worker 成功写，且版本计数没有分叉
# ---------------------------------------------------------------------------
mongosh "$URI" --quiet --eval "
  const c = db.getSiblingDB('$DB').$COLL;
  const count = c.countDocuments({});
  const d = c.findOne({_id:'op1'});
  if (!d) { throw new Error('probe document disappeared'); }
  let preWorkers = 0, postWorkers = 0;
  for (let i = 1; i <= $WORKERS; i++) {
    if (d['pre_worker_' + i] > 0) preWorkers++;
    if (d['post_worker_' + i] > 0) postWorkers++;
  }
  print('documents=' + count + ' version=' + d._version + ' hits=' + d.hits +
        ' pre=' + d.pre_hits + ' post=' + d.post_hits +
        ' pre_workers_now=' + preWorkers + ' post_workers=' + postWorkers);
  if (count !== 1) { throw new Error('duplicated document: ' + count); }
  if (d.pre_hits < $WORKERS) { throw new Error('no successful write before stepdown'); }
  if (d.post_hits < $WORKERS) { throw new Error('no successful write after stepdown'); }
  // 切主前的并发证明用 stepDown 前的采样值（见上面的 PRE_WORKERS）：
  // 这里的 preWorkers 可能包含"切主后、phase 切换前"的写，不能用来证明
  if (postWorkers < 2) { throw new Error('fewer than two workers wrote after stepdown'); }
  if (d.hits !== d.pre_hits + d.post_hits) { throw new Error('phase buckets do not add up to hits'); }
  if (d._version !== d.hits) { throw new Error('version and hits diverged'); }
" || fail "结果断言未通过"

FINAL_PRIMARY=$(mongosh "$URI" --quiet --eval "print(db.hello().primary || '')" 2>/dev/null || true)
FINAL_TERM=$(mongosh "$URI" --quiet --eval "print(Number(db.adminCommand({replSetGetStatus: 1}).term) || '')" 2>/dev/null || true)
[ "$FINAL_PRIMARY" = "$PRIMARY_AFTER" ] || fail "post 窗口后 primary 再次变化：$PRIMARY_AFTER -> ${FINAL_PRIMARY:-unknown}"
[ "$FINAL_TERM" = "$TERM_AFTER" ] || fail "post 窗口后 term 再次变化：$TERM_AFTER -> ${FINAL_TERM:-unknown}"

echo "replica stepdown check passed"
