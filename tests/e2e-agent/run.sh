#!/bin/bash
# E2E Agent 剧本测试入口
# 真实 claude -p 驱动 Creator Agent + LLM 模拟用户 + 剧本化断言。
#
# 用法：
#   bash tests/e2e-agent/run.sh <scenario>           # 如 keyword-to-asin
#   E2E_KEEP=1 bash tests/e2e-agent/run.sh <scenario>   # 保留临时项目
#   E2E_SKIP_RUN=1 ...                                # 跳过真实运行（只测对话流程）
#   E2E_MAX_ROUNDS=80 E2E_AGENT_MODEL=opus ...        # 覆盖默认参数
#
# 注意：会消耗真实 token（一次全流程可能数十万），不进 run-all.sh。

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
WORKSPACE="${E2E_WORKSPACE:-$HOME/minus}"
KEEP="${E2E_KEEP:-0}"

SCENARIO_NAME="${1:?用法: run.sh <scenario>（scenarios/ 下的文件名，不带扩展名）}"
SCENARIO_FILE="$SCRIPT_DIR/scenarios/$SCENARIO_NAME.yaml"
if [ ! -f "$SCENARIO_FILE" ]; then
  echo "✗ 剧本不存在: $SCENARIO_FILE" >&2
  echo "  可用剧本: $(ls "$SCRIPT_DIR/scenarios" | sed 's/\.yaml$//' | tr '\n' ' ')" >&2
  exit 2
fi

# ── 环境检查 ──
for cmd in claude node uv npm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "✗ 缺少命令: $cmd" >&2
    exit 2
  fi
done
if [ ! -f "$HOME/.minus/credentials.json" ]; then
  echo "✗ 未登录 Minus 平台（~/.minus/credentials.json 不存在），真实运行验证需要登录态" >&2
  echo "  可用 E2E_SKIP_RUN=1 跳过真实运行，只测对话流程" >&2
  [ "${E2E_SKIP_RUN:-0}" = "1" ] || exit 2
fi

# ── 日志目录 ──
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$SCRIPT_DIR/logs/$SCENARIO_NAME-$RUN_ID"
mkdir -p "$LOG_DIR"
echo "→ 日志目录: $LOG_DIR"

# ── 创建临时 skill 项目 ──
PROJECT_NAME="e2e-agent-$RUN_ID"
mkdir -p "$WORKSPACE"

CREATE_SKILL_LOCAL="$REPO_DIR/../minus-platform/packages/create-skill/index.mjs"
echo "→ 创建临时项目: $PROJECT_NAME"
if [ -f "$CREATE_SKILL_LOCAL" ]; then
  CREATE_OUTPUT=$(cd "$WORKSPACE" && node "$CREATE_SKILL_LOCAL" "$PROJECT_NAME" --non-interactive 2>&1 || true)
else
  CREATE_OUTPUT=$(cd "$WORKSPACE" && npx -y @minus-ai/create-skill "$PROJECT_NAME" --non-interactive 2>&1 || true)
fi
echo "$CREATE_OUTPUT" > "$LOG_DIR/create-skill.log"

PROJECT_DIR=$(echo "$CREATE_OUTPUT" | grep '__CREATE_RESULT__' | sed 's/.*"targetDir":"\([^"]*\)".*/\1/')
[ -z "$PROJECT_DIR" ] && PROJECT_DIR="$WORKSPACE/$PROJECT_NAME"

if [ ! -f "$PROJECT_DIR/.minus/skill.json" ]; then
  echo "✗ 项目创建失败（$PROJECT_DIR/.minus/skill.json 不存在），日志: $LOG_DIR/create-skill.log" >&2
  exit 1
fi
echo "→ 项目已创建: $PROJECT_DIR"

cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo "→ E2E_KEEP=1，保留项目: $PROJECT_DIR"
  else
    rm -rf "$PROJECT_DIR" 2>/dev/null || true
    echo "→ 已清理临时项目"
  fi
}
trap cleanup EXIT

# ── 安装依赖（真实运行验证需要）──
if [ "${E2E_SKIP_RUN:-0}" != "1" ]; then
  echo "→ npm install..."
  (cd "$PROJECT_DIR" && npm install) > "$LOG_DIR/npm-install.log" 2>&1 || {
    echo "✗ npm install 失败，日志: $LOG_DIR/npm-install.log" >&2
    exit 1
  }
  echo "→ uv venv + pip install -e ..."
  (cd "$PROJECT_DIR" && uv venv -p 3.12 && uv pip install -e .) > "$LOG_DIR/uv-install.log" 2>&1 || {
    echo "✗ Python 环境安装失败，日志: $LOG_DIR/uv-install.log" >&2
    exit 1
  }
fi

# ── 启动驱动器 ──
export E2E_PROJECT_DIR="$PROJECT_DIR"
export E2E_PLUGIN_DIR="$PLUGIN_DIR"
export E2E_LOG_DIR="$LOG_DIR"
export E2E_SCENARIO="$SCENARIO_FILE"

node "$SCRIPT_DIR/driver.mjs"
EXIT_CODE=$?

echo ""
echo "→ 完整日志: $LOG_DIR"
exit $EXIT_CODE
