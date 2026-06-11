#!/bin/bash
# E2E 测试：验证进入 Skill 项目时自动启动 dev server 并输出预览地址
#
# 用法：bash tests/e2e-autostart.sh
# 前提：已登录（~/.minus/credentials.json 存在）

set -o pipefail

# 测试不开浏览器：detect-preview-port 检测成功后会自动 open-preview，测试环境一律抑制
export AUTO_OPEN=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="$HOME/minus"
PROJECT_NAME="e2e-autostart-$(date +%s)"
PROJECT_DIR="$WORKSPACE/$PROJECT_NAME"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; echo -e "    $2"; FAIL=$((FAIL + 1)); }
info() { echo -e "  ${YELLOW}→${NC} $1"; }

PASS=0
FAIL=0
LOG_FILE="/tmp/e2e-autostart.txt"

cleanup() {
  pkill -f "uvicorn server:app" 2>/dev/null
  pkill -f "npx vite" 2>/dev/null
  pkill -f "concurrently" 2>/dev/null
  rm -rf "$PROJECT_DIR" 2>/dev/null || true
  info "已清理"
}
trap cleanup EXIT

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   E2E 测试：自动启动 dev server          ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Step 1: 创建临时项目 ──
info "创建临时项目：$PROJECT_NAME"
CREATE_OUTPUT=$(cd "$WORKSPACE" && create-skill "$PROJECT_NAME" --non-interactive 2>&1 || true)

ACTUAL_DIR=$(echo "$CREATE_OUTPUT" | grep '__CREATE_RESULT__' | sed 's/.*"targetDir":"\([^"]*\)".*/\1/')
if [ -n "$ACTUAL_DIR" ]; then
  PROJECT_DIR="$ACTUAL_DIR"
fi

if [ ! -f "$PROJECT_DIR/.minus/skill.json" ]; then
  fail "项目创建失败" "$PROJECT_DIR/.minus/skill.json 不存在"
  echo "$CREATE_OUTPUT"
  exit 1
fi
pass "项目已创建：$PROJECT_DIR"

# ── Step 2: 确保所有 dev server 没在跑 ──
pkill -f "uvicorn server:app" 2>/dev/null
pkill -f "npx vite" 2>/dev/null
pkill -f "concurrently" 2>/dev/null
pkill -f "node.*vite" 2>/dev/null
lsof -ti:5173,5174,5175,4001 2>/dev/null | xargs kill -9 2>/dev/null
sleep 2

# ── Step 3: 用 claude -p 进入项目，验证自动启动 ──
info "进入项目，验证自动启动..."
OUTPUT=$(cd "$PROJECT_DIR" && claude -p "hi" \
  --model sonnet \
  --dangerously-skip-permissions \
  --max-turns 10 \
  2>&1)

echo "$OUTPUT" > "$LOG_FILE"
info "输出已保存到 $LOG_FILE"

# ── Step 4: 检查 dev server 是否启动 ──
if lsof -i :5173 2>/dev/null | grep -q LISTEN || \
   lsof -i :5174 2>/dev/null | grep -q LISTEN || \
   lsof -i :5175 2>/dev/null | grep -q LISTEN; then
  pass "dev server 已启动（端口在监听）"
else
  fail "dev server 未启动" "5173-5175 端口均无监听"
fi

# ── Step 5: 检查输出中包含预览地址 ──
if echo "$OUTPUT" | grep -qE "localhost:[0-9]+"; then
  PREVIEW_URL=$(echo "$OUTPUT" | grep -oE "http://localhost:[0-9]+" | head -1)
  pass "输出包含预览地址：$PREVIEW_URL"
else
  fail "输出不包含预览地址" "未找到 localhost:端口"
fi

# ── Step 6: 检查输出中包含开发引导（首次进入） ──
if echo "$OUTPUT" | grep -qE "设计|需要提供什么信息|第一个问题|开始开发|你想做什么|SKILL.md"; then
  pass "首次进入包含开发引导"
else
  fail "首次进入未包含开发引导" "未找到引导相关提问"
fi

# ── 结果 ──
echo ""
echo "═══════════════════════════════════════"
echo -e "  结果: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} (共 $((PASS + FAIL)) 项)"
echo "═══════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
