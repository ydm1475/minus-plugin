#!/bin/bash
# 场景 06（仅 Windows）：node 在 %LOCALAPPDATA%\Volta\bin\node.exe
# 断言：resolve-node.sh 经 win_path 转换命中；launch.cjs（老解释器）命中 LOCALAPPDATA Volta image
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
scenario_setup

if ! is_windows; then
  skip "resolve-node.sh：LOCALAPPDATA Volta" "Windows-only 场景"
  scenario_summary; exit $?
fi

plant_node "$FAKE_LOCALAPPDATA/Volta/bin/node.exe" || { fail "布局" "plant_node 失败"; scenario_summary; exit $?; }

OUT="$(in_env sh "$RESOLVE_NODE")"; RC=$?
if [ $RC -eq 0 ]; then pass "resolve-node.sh：LOCALAPPDATA Volta exit 0"; else fail "resolve-node.sh：LOCALAPPDATA Volta" "rc=$RC out=[$OUT]"; fi
assert_contains "$OUT" "/Volta/bin/node.exe" "resolve-node.sh：win_path 转换后命中 node.exe"

# launch.cjs 的 Windows 分支找 %LOCALAPPDATA%/Volta/tools/image/node/*/node.exe
if [ -n "$MATRIX_OLD_NODE" ]; then
  plant_node "$FAKE_LOCALAPPDATA/Volta/tools/image/node/24.0.0/node.exe"
  mcp_handshake "$MATRIX_OLD_NODE"
  assert_contains "$MCP_OUT" '"tools"' "launch.cjs：LOCALAPPDATA Volta image 候选 + MCP 握手"
else
  skip "launch.cjs：LOCALAPPDATA Volta image 候选" "需要 MATRIX_OLD_NODE"
fi

scenario_summary
