#!/bin/bash
# 场景 05：node 装在 nvm 布局（~/.nvm/versions/node/vX/bin/node），PATH 上没有
# 断言：resolve-node.sh 命中 nvm 候选
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
scenario_setup

if is_windows; then
  skip "resolve-node.sh：nvm 候选" "nvm 布局为 unix-only 候选"
  scenario_summary; exit $?
fi

plant_node "$FAKE_HOME/.nvm/versions/node/v24.0.0/bin/node" || { fail "布局" "plant_node 失败"; scenario_summary; exit $?; }

if hide_abs_nodes; then
  OUT="$(in_env sh "$RESOLVE_NODE")"; RC=$?
  if [ $RC -eq 0 ]; then pass "resolve-node.sh：nvm 布局 exit 0"; else fail "resolve-node.sh：nvm 布局" "rc=$RC out=[$OUT]"; fi
  assert_contains "$OUT" ".nvm/versions/node" "resolve-node.sh：命中 nvm 候选"
else
  skip "resolve-node.sh：nvm 候选" "本机绝对路径有 node，会先于 nvm 命中"
fi

scenario_summary
