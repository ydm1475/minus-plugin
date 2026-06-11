#!/bin/bash
# 场景 01：用户机器上完全没有 node
# 断言：resolve-node.sh 无输出 exit 1；launch.cjs（老解释器跑）stderr 含安装指引 exit 1
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
scenario_setup

if hide_abs_nodes; then
  OUT="$(in_env sh "$RESOLVE_NODE")"; RC=$?
  if [ $RC -eq 1 ] && [ -z "$OUT" ]; then
    pass "resolve-node.sh：无 node → 无输出 exit 1"
  else
    fail "resolve-node.sh：无 node 行为" "rc=$RC out=[$OUT]"
  fi
else
  skip "resolve-node.sh：无 node 行为" "本机 /usr/local 或 /opt/homebrew 有 node，不可屏蔽"
fi

# launch.cjs 的候选链第一位是 process.execPath：必须用 < floor 的老 node 跑它，
# 才能验证「全部候选不达标 → 明确报错」的失败路径。
if [ -n "$MATRIX_OLD_NODE" ] && hide_abs_nodes; then
  ERR="$(printf '' | in_env "$MATRIX_OLD_NODE" "$LAUNCH_CJS" 2>&1 >/dev/null)"; RC=$?
  if [ $RC -eq 1 ]; then pass "launch.cjs：无可用 node → exit 1"; else fail "launch.cjs：退出码" "rc=$RC"; fi
  assert_contains "$ERR" "volta.sh" "launch.cjs：报错含安装指引（volta.sh）"
else
  skip "launch.cjs：无可用 node 失败路径" "需要 MATRIX_OLD_NODE（CI 由 setup-node 提供）"
fi

scenario_summary
