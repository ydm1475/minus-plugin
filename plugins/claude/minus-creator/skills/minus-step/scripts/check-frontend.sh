#!/bin/bash
# check-frontend.sh
# 前端类型检查硬门禁：在 frontend/ 跑 tsc --noEmit，任何非零退出都算失败。
#
# 用法: check-frontend.sh
# 输出:
#   FRONTEND_OK  — 类型检查通过（退出码 0）
#   GATE_FAILED  — 类型检查失败或没跑成（退出码 1），附原始错误（给 Agent 修，不给 Creator 看）
#
# 设计原因（人工测试 612）：tsc 因 TS6046（tsconfig 与 tsc 版本不兼容）根本没跑成，
# Agent 当作"有点小报错"放行，后续三轮 UI 问题全靠 Creator 肉眼发现。
# 配置错误（TS6053/TS6046 等）≠ 可忽略——它意味着类型检查整体失效，必须修。

set -uo pipefail

if [ ! -d frontend ]; then
  echo "GATE_FAILED"
  echo "错误：frontend/ 目录不存在" >&2
  exit 1
fi

export VOLTA_FEATURE_PNPM=1
VOLTA_HOME="${VOLTA_HOME:-$HOME/.volta}"
if [ -d "$VOLTA_HOME/bin" ] && [[ ":$PATH:" != *":$VOLTA_HOME/bin:"* ]]; then
  export PATH="$VOLTA_HOME/bin:$PATH"
fi
if [ -x "$VOLTA_HOME/bin/pnpm" ]; then
  PNPM_CMD="$VOLTA_HOME/bin/pnpm"
elif command -v pnpm >/dev/null 2>&1; then
  PNPM_CMD="$(command -v pnpm)"
else
  echo "GATE_FAILED"
  echo "错误：未找到 pnpm" >&2
  exit 1
fi

TSC_OUT=$(cd frontend && "$PNPM_CMD" exec tsc --noEmit 2>&1)
TSC_EXIT=$?

if [ $TSC_EXIT -eq 0 ]; then
  echo "FRONTEND_OK"
  exit 0
fi

echo "GATE_FAILED"
echo "$TSC_OUT" >&2
if printf '%s' "$TSC_OUT" | grep -qE 'TS6046|TS6053|TS5023|TS5024'; then
  echo "──" >&2
  echo "上述是 tsconfig 配置/版本不兼容错误：类型检查整体没有生效，不是普通的类型报错。" >&2
  echo "Agent 必须修复 tsconfig 与本地 tsc 版本的不匹配（如调整 moduleResolution 取值或对齐 typescript 版本）后重跑本门禁。" >&2
fi
echo "⛔ 门禁未通过前禁止告知 Creator 开发完成。" >&2
exit 1
