#!/bin/bash
# E2E 测试：验证三步法流程不被跳过
# 用 claude -p 多轮对话，检查每轮输出是否包含预期的问题
#
# 用法：bash tests/e2e-three-step.sh
# 可选：E2E_KEEP=1 bash tests/e2e-three-step.sh  # 保留临时项目不删

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
WORKSPACE="$HOME/minus"
PROJECT_NAME="e2e-test-$(date +%s)"
PROJECT_DIR="$WORKSPACE/$PROJECT_NAME"
KEEP="${E2E_KEEP:-0}"

# ── 颜色 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; echo -e "    $2"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }

PASS=0
FAIL=0
check_contains() {
  local output="$1" keyword="$2" label="$3"
  if echo "$output" | grep -q "$keyword"; then
    pass "$label"
    PASS=$((PASS + 1))
    return 0
  else
    fail "$label" "输出中未找到「$keyword」"
    FAIL=$((FAIL + 1))
    return 1
  fi
}

# check_contains_any OUTPUT kw1 kw2 ... -- LABEL
check_contains_any() {
  local output="$1"; shift
  local keywords=()
  while [ "$1" != "--" ]; do keywords+=("$1"); shift; done
  shift  # skip --
  local label="$1"
  for kw in "${keywords[@]}"; do
    if echo "$output" | grep -q "$kw"; then
      pass "$label (匹配：$kw)"
      PASS=$((PASS + 1))
      return 0
    fi
  done
  fail "$label" "输出中未找到任何关键词：${keywords[*]}"
  FAIL=$((FAIL + 1))
  return 1
}

# ── 清理函数 ──
cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo -e "  ${YELLOW}→${NC} E2E_KEEP=1，保留项目：$PROJECT_DIR"
  else
    rm -rf "$PROJECT_DIR" 2>/dev/null || true
    echo -e "  ${YELLOW}→${NC} 已清理临时项目"
  fi
}
trap cleanup EXIT

# ── Claude CLI 通用参数 ──
CLAUDE_ARGS=(
  --print
  --plugin-dir "$PLUGIN_DIR"
  --model sonnet
  --dangerously-skip-permissions
  --output-format json
  --max-budget-usd 1
)

run_claude() {
  local prompt="$1"
  shift
  local result
  result=$(cd "$PROJECT_DIR" && claude "${CLAUDE_ARGS[@]}" "$@" "$prompt" 2>/dev/null) || true
  # --output-format json 返回 JSON，提取 result 字段
  local parsed
  parsed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])" 2>/dev/null) || true
  if [ -n "$parsed" ]; then
    echo "$parsed"
  else
    echo "$result"
  fi
}

run_claude_continue() {
  local prompt="$1"
  run_claude "$prompt" --continue
}

# ══════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════╗"
echo "║   E2E 测试：三步法流程完整性         ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── Step 0：创建临时项目 ──
info "创建临时项目：$PROJECT_NAME"
CREATE_OUTPUT=$(cd "$WORKSPACE" && create-skill "$PROJECT_NAME" --non-interactive 2>&1 || true)

# create-skill 可能会改名（如 - → _），从输出中解析实际路径
ACTUAL_DIR=$(echo "$CREATE_OUTPUT" | grep '__CREATE_RESULT__' | sed 's/.*"targetDir":"\([^"]*\)".*/\1/')
if [ -n "$ACTUAL_DIR" ]; then
  PROJECT_DIR="$ACTUAL_DIR"
fi

if [ ! -f "$PROJECT_DIR/.minus/skill.json" ]; then
  fail "项目创建失败" "$PROJECT_DIR/.minus/skill.json 不存在"
  echo "create-skill 输出："
  echo "$CREATE_OUTPUT"
  exit 1
fi
pass "项目已创建：$PROJECT_DIR"

# ── Round 1：首次进入，应该问第一个问题（输入）──
echo ""
echo "═══ Round 1：首次进入 ═══"
info "发送：hi"

R1=$(run_claude "hi")

echo "$R1" > /tmp/e2e-r1.txt
info "输出已保存到 /tmp/e2e-r1.txt"

check_contains "$R1" "三步法" "提到三步法"
check_contains "$R1" "需要提供什么信息" "问第一步：输入是什么"

# ── Round 2：回答第一步，应该问第二步（步骤）──
echo ""
echo "═══ Round 2：回答输入 ═══"
info "发送：关键词，支持多个"

R2=$(run_claude_continue "关键词，支持多个")

echo "$R2" > /tmp/e2e-r2.txt
info "输出已保存到 /tmp/e2e-r2.txt"

check_contains "$R2" "分几步" "问第二步：分几步完成"

# 关键断言：不能直接开始写代码
if echo "$R2" | grep -qE "pipeline\.py|开始开发|先从后端|import|async def"; then
  fail "第二轮不应该出现写代码的迹象" "agent 跳过了第二步直接写代码"
  FAIL=$((FAIL + 1))
else
  pass "第二轮没有跳步写代码"
  PASS=$((PASS + 1))
fi

# ── Round 3：回答第二步，应该问第三步（输出）──
echo ""
echo "═══ Round 3：回答步骤 ═══"
info "发送：先查搜索量，再分析竞争度"

R3=$(run_claude_continue "先查搜索量，再分析竞争度")

echo "$R3" > /tmp/e2e-r3.txt
info "输出已保存到 /tmp/e2e-r3.txt"

check_contains_any "$R3" "给用户看什么结果" "最后一个问题" "最终输出" "输出定义" -- "问第三步：输出是什么"

# 关键断言：不能直接开始写代码
if echo "$R3" | grep -qE "pipeline\.py|开始开发|先从后端|generate-steps"; then
  fail "第三轮不应该出现写代码的迹象" "agent 跳过了第三步直接写代码"
  FAIL=$((FAIL + 1))
else
  pass "第三轮没有跳步写代码"
  PASS=$((PASS + 1))
fi

# ══════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════"
echo -e "  结果: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "═══════════════════════════════"
echo ""
echo "完整输出保存在 /tmp/e2e-r1.txt, /tmp/e2e-r2.txt, /tmp/e2e-r3.txt"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
