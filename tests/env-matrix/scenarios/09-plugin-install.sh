#!/bin/bash
# 场景 09（CI-only，层 2）：真实跑 install.sh，验证 Claude Code 识别插件
# 前置（由 workflow 保证）：PATH 上有合规 node + claude CLI（npm i -g @anthropic-ai/claude-code）
# 用真实 HOME（claude 配置/marketplace 固化目录都在 ~），runner 一次性，无污染顾虑。
# 零 API key：只用 claude plugin 子命令，不启动会话。
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
scenario_setup

if ! is_ci; then
  skip "install.sh 真实安装" "CI-only"
  scenario_summary; exit $?
fi

if ! command -v claude >/dev/null 2>&1; then
  fail "前置" "claude CLI 不在 PATH（workflow 应先 npm i -g @anthropic-ai/claude-code）"
  scenario_summary; exit $?
fi
pass "前置：claude CLI 可用（$(claude --version 2>&1 | head -1)）"

# install.sh 已全程非交互（node gate 自动 provision）；</dev/null 仅防御性兜底
INSTALL_OUT="$(bash "$PLUGIN_DIR/install.sh" </dev/null 2>&1)"; RC=$?
if [ $RC -eq 0 ]; then
  pass "install.sh：退出码 0"
else
  fail "install.sh：执行失败" "rc=$RC; 输出尾部：$(echo "$INSTALL_OUT" | tail -10)"
fi

LIST_OUT="$(claude plugin list 2>&1)"
assert_contains "$LIST_OUT" "minus-creator" "claude plugin list：插件被识别"

if [ -d "$HOME/.claude/minus-creator-marketplace" ]; then
  pass "marketplace 固化目录存在"
else
  fail "marketplace 固化目录" "$HOME/.claude/minus-creator-marketplace 不存在"
fi

# MCP 产物校验：固化目录里的 launch.cjs 能拉起 bundle 完成握手
FIXED_LAUNCH="$(find "$HOME/.claude/minus-creator-marketplace" -name launch.cjs 2>/dev/null | head -1)"
if [ -n "$FIXED_LAUNCH" ]; then
  RPC='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"env-matrix","version":"0.0.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  HS_OUT="$(printf '%s\n' "$RPC" | node "$FIXED_LAUNCH" 2>&1)"
  assert_contains "$HS_OUT" '"tools"' "固化目录 MCP 产物：握手成功"
else
  fail "MCP 产物" "固化目录中找不到 launch.cjs"
fi

scenario_summary
