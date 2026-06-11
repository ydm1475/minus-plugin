#!/bin/bash
# 场景 02：PATH 上只有老 node（v12 类），无任何新候选
# 断言：resolve-node.sh 拒绝老版本 → 无输出 exit 1
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
scenario_setup

plant_old_node_stub "$SCENARIO_TMP/oldbin/node" 12

if hide_abs_nodes; then
  OUT="$(in_env PATH="$SCENARIO_TMP/oldbin:$CLEAN_PATH" sh "$RESOLVE_NODE")"; RC=$?
  if [ $RC -eq 1 ] && [ -z "$OUT" ]; then
    pass "resolve-node.sh：仅老 node(12) → 拒绝，exit 1"
  else
    fail "resolve-node.sh：仅老 node 行为" "rc=$RC out=[$OUT]"
  fi
else
  skip "resolve-node.sh：仅老 node 行为" "本机绝对路径有 node，不可屏蔽"
fi

scenario_summary
