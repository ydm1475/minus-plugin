#!/bin/bash
# 场景 03：老 node 排在 PATH 前面，但假 HOME 的 Volta image 里有合规 node
# （复现 resolve-node.sh 注释里的真实案例：/usr/local/bin/node v12 遮挡 Volta 24）
# 断言：resolve-node.sh 跳过老 node、命中 Volta image；launch.cjs（老解释器）也命中
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
scenario_setup

plant_old_node_stub "$SCENARIO_TMP/oldbin/node" 12
plant_node "$FAKE_HOME/.volta/tools/image/node/24.0.0/bin/node" || { fail "布局" "plant_node 失败"; scenario_summary; exit $?; }

OUT="$(in_env PATH="$SCENARIO_TMP/oldbin:$CLEAN_PATH" sh "$RESOLVE_NODE")"; RC=$?
if [ $RC -eq 0 ]; then pass "resolve-node.sh：老 node 在前仍 exit 0"; else fail "resolve-node.sh：退出码" "rc=$RC out=[$OUT]"; fi
assert_contains "$OUT" ".volta/tools/image/node" "resolve-node.sh：命中 Volta image 真身"

# launch.cjs 的 Volta image 候选：必须用老解释器跑（execPath 第一位，新 node 会自荐）
if [ -n "$MATRIX_OLD_NODE" ]; then
  if is_windows; then
    # Windows 分支的 launch.cjs 找 %LOCALAPPDATA%/Volta image（场景 06 覆盖），unix 假 HOME 布局对它无效
    skip "launch.cjs：Volta image 候选" "Windows 走 LOCALAPPDATA 分支，见场景 06"
  else
    mcp_handshake "$MATRIX_OLD_NODE"
    assert_contains "$MCP_OUT" '"tools"' "launch.cjs：老解释器下命中 Volta image 并完成 MCP 握手"
  fi
else
  skip "launch.cjs：Volta image 候选" "需要 MATRIX_OLD_NODE（CI 由 setup-node 提供）"
fi

scenario_summary
