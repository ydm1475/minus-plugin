#!/bin/bash
# diagnose.sh — 错误诊断聚合体检（minus-diagnose skill 专用）
#
# 职责：按序调用既有检查脚本，把第一处命中的故障归类为一行机器可读结论。
# 本脚本不重写任何检查逻辑与中文话术——底层脚本的输出（含 HINT=/指引行）
# 原样透传，自己只在最后追加 DIAGNOSE=<code> 供 SKILL.md 路由。
#
# 输出（最后一行恒为 DIAGNOSE=）：
#   DIAGNOSE=NOT_LOGGED_IN|NO_PROJECT|ENV_NOT_READY    ← gate.sh
#   DIAGNOSE=BACKEND_DOWN|DEV_SERVER_DOWN              ← check-dev-server.sh
#   DIAGNOSE=PYTHON_DEPS_MISSING                       ← check-python-deps.sh
#   DIAGNOSE=clean                                      ← 环境全绿，问题在业务代码层
# 契约：始终 exit 0（结论在 stdout，不靠退出码）。
#
# MCP 连通性不在本脚本范围：工具是否可用只有 Agent 自己知道，
# 该分支由 SKILL.md 直接调 diagnose-mcp.sh。

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${MINUS_PLUGIN_ROOT:-$DIR/../../..}"

# 子脚本路径可被测试用环境变量替换为桩（参照 bootstrap-env 测试的 stub 方式）
GATE_SH="${MINUS_GATE_SH:-$PLUGIN_ROOT/scripts/gate.sh}"
CHECK_DEV_SH="${MINUS_CHECK_DEV_SH:-$PLUGIN_ROOT/skills/minus/scripts/check-dev-server.sh}"
CHECK_PY_SH="${MINUS_CHECK_PY_SH:-$PLUGIN_ROOT/skills/minus/scripts/check-python-deps.sh}"

# ── 1. 登录 → 项目 → 环境（gate.sh 始终 exit 0，结论在输出里）──
GATE_OUT="$(sh "$GATE_SH" 2>&1 || true)"
if [ "$GATE_OUT" != "GATE=ok" ]; then
  echo "$GATE_OUT"
  REASON="$(printf '%s\n' "$GATE_OUT" | sed -n 's/^GATE=fail reason=//p' | head -1)"
  echo "DIAGNOSE=${REASON:-ENV_NOT_READY}"
  exit 0
fi

# ── 2. dev server（前端归属 + 后端健康；失败 exit 1，指引在 stderr）──
DEV_OUT="$(AUTO_OPEN=0 bash "$CHECK_DEV_SH" 2>&1)" || true
if ! printf '%s\n' "$DEV_OUT" | grep -q '^GATE_PASSED$'; then
  echo "$DEV_OUT"
  if printf '%s\n' "$DEV_OUT" | grep -q '^BACKEND_DOWN$'; then
    echo "DIAGNOSE=BACKEND_DOWN"
  else
    echo "DIAGNOSE=DEV_SERVER_DOWN"
  fi
  exit 0
fi

# ── 3. Python 依赖（仅当 pipeline.py 存在；脚本失败时 exit 非零）──
if [ -f pipeline.py ]; then
  PY_OUT="$(bash "$CHECK_PY_SH" 2>&1)" || {
    echo "$PY_OUT"
    echo "DIAGNOSE=PYTHON_DEPS_MISSING"
    exit 0
  }
fi

# ── 全绿：透传端口信息，问题在业务代码层 ──
printf '%s\n' "$DEV_OUT" | grep -E '^(PREVIEW_PORT|BACKEND_PORT)=' || true
echo "DIAGNOSE=clean"
exit 0
