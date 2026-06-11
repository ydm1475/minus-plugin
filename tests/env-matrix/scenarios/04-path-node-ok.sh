#!/bin/bash
# 场景 04：PATH 上有合规 node（>= floor）——最常见的健康环境
# 断言：resolve-node.sh 命中 PATH node；launch.cjs MCP 握手返回非空工具列表
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
scenario_setup

RN="$(real_node)" || { fail "前置" "当前环境无 node"; scenario_summary; exit $?; }
RN_DIR="$(dirname "$RN")"

OUT="$(in_env PATH="$RN_DIR:$CLEAN_PATH" sh "$RESOLVE_NODE")"; RC=$?
if [ $RC -eq 0 ] && [ -n "$OUT" ]; then
  pass "resolve-node.sh：PATH 合规 node → exit 0 输出路径"
else
  fail "resolve-node.sh：PATH 合规 node" "rc=$RC out=[$OUT]"
fi

mcp_handshake "$RN" PATH="$RN_DIR:$CLEAN_PATH"
assert_contains "$MCP_OUT" '"tools"' "launch.cjs：MCP initialize + tools/list 握手成功"
assert_contains "$MCP_OUT" '"name"' "launch.cjs：工具列表非空"

scenario_summary
