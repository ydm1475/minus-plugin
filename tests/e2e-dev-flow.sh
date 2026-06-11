#!/bin/bash
# E2E 测试：验证完整开发流程（两步法 + 逐节点四维度 + 结果呈现）
# 用 claude -p 多轮对话，检查每轮输出是否包含预期的问题
#
# 用法：
#   bash tests/e2e-dev-flow.sh              # 跑全流程
#   bash tests/e2e-dev-flow.sh --phase 1    # 只跑两步法
#   bash tests/e2e-dev-flow.sh --phase 2    # 只跑逐节点开发
#   bash tests/e2e-dev-flow.sh --phase 3    # 只跑结果呈现
#   E2E_KEEP=1 bash tests/e2e-dev-flow.sh  # 保留临时项目不删

set -o pipefail

# 测试不开浏览器：detect-preview-port 检测成功后会自动 open-preview，测试环境一律抑制
export AUTO_OPEN=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
WORKSPACE="$HOME/minus"
PROJECT_NAME="e2e-test-$(date +%s)"
PROJECT_DIR="$WORKSPACE/$PROJECT_NAME"
KEEP="${E2E_KEEP:-0}"
PHASE="${2:-all}"  # all, 1, 2, 3

# 解析参数
if [ "${1:-}" = "--phase" ]; then
  PHASE="$2"
fi

# ── 颜色 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; echo -e "    $2"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }
phase_header() { echo -e "\n${CYAN}══ $1 ══${NC}"; }

PASS=0
FAIL=0
ROUND=0
LOG_DIR="/tmp/e2e-dev-flow"
mkdir -p "$LOG_DIR"

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
  shift
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

# 检查输出中不包含某些关键词（没跳步写代码）
check_no_skip() {
  local output="$1" label="$2"
  if echo "$output" | grep -qE "pipeline\.py|开始开发|先从后端|import minus|async def step|generate-steps"; then
    fail "$label" "agent 跳步直接写代码了"
    FAIL=$((FAIL + 1))
    return 1
  else
    pass "$label"
    PASS=$((PASS + 1))
    return 0
  fi
}

# ── 清理函数 ──
cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo -e "\n  ${YELLOW}→${NC} E2E_KEEP=1，保留项目：$PROJECT_DIR"
  else
    rm -rf "$PROJECT_DIR" 2>/dev/null || true
    echo -e "\n  ${YELLOW}→${NC} 已清理临时项目"
  fi
}
trap cleanup EXIT

# ── Claude CLI ──
CLAUDE_ARGS=(
  --print
  --plugin-dir "$PLUGIN_DIR"
  --model sonnet
  --dangerously-skip-permissions
  --output-format json
  --max-budget-usd 3
)

_send_impl() {
  local prompt="$1"
  shift
  local result=""
  result=$(cd "$PROJECT_DIR" && claude "${CLAUDE_ARGS[@]}" "$@" "$prompt" 2>/dev/null) || true
  local parsed=""
  parsed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])" 2>/dev/null) || true
  if [ -n "$parsed" ]; then
    echo "$parsed"
  else
    echo "$result"
  fi
}

send() {
  ROUND=$((ROUND + 1))
  local output
  output=$(_send_impl "$@")
  echo "$output" > "$LOG_DIR/r${ROUND}.txt"
  info "Round $ROUND 输出 → $LOG_DIR/r${ROUND}.txt"
  LAST_OUTPUT="$output"
}

send_continue() {
  send "$1" --continue
}

send_continue() {
  send "$1" --continue
}

# ══════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   E2E 测试：Skill 开发全流程             ║"
echo "╚══════════════════════════════════════════╝"
echo ""
info "测试阶段：$( [ "$PHASE" = "all" ] && echo "全部" || echo "Phase $PHASE" )"

# ── 创建临时项目 ──
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


# ╔══════════════════════════════════════════╗
# ║  Phase 1：结构设计                        ║
# ╚══════════════════════════════════════════╝

if [ "$PHASE" = "all" ] || [ "$PHASE" = "1" ]; then

phase_header "Phase 1：结构设计（输入 → 步骤）"

# ── 1.0 首次进入 ──
echo ""
info "发送：hi"
send "hi"
check_contains_any "$LAST_OUTPUT" "设计" "需要提供什么信息" "第一个问题" -- "提到设计流程"
check_contains "$LAST_OUTPUT" "需要提供什么信息" "问第一步：输入是什么"

# ── 1.1 回答输入 → 应问步骤 ──
echo ""
info "发送：关键词，支持多个"
send_continue "关键词，支持多个"
check_contains_any "$LAST_OUTPUT" "分几步" "每一步做什么" "步骤" -- "问第二步：拆解步骤"
check_no_skip "$LAST_OUTPUT" "没有跳步写代码"

# ── 1.2 回答步骤 → 应进入骨架生成/节点开发 ──
echo ""
info "发送：先查搜索量，再分析竞争度"
send_continue "先查搜索量，再分析竞争度"
check_contains_any "$LAST_OUTPUT" "确认" "逐个节点" "开始开发" "步骤 1" "步骤1" "数据" "从哪" "骨架" "generate" -- "两步法完成，进入节点开发"

fi  # Phase 1


# ╔══════════════════════════════════════════╗
# ║  Phase 2：逐节点开发（四维度）             ║
# ╚══════════════════════════════════════════╝

if [ "$PHASE" = "all" ] || [ "$PHASE" = "2" ]; then

phase_header "Phase 2：逐节点开发 — 步骤 1 四维度"

# 如果只跑 Phase 2，需要先走完结构设计
if [ "$PHASE" = "2" ]; then
  info "快速走完结构设计..."
  send "hi"
  send_continue "关键词，支持多个"
  send_continue "先查搜索量，再分析竞争度"
  info "结构设计已完成，开始测试四维度"
fi

# ── 2.1 进入步骤1开发，应该问数据需求 ──
echo ""
info "发送：开始开发第一个步骤"
send_continue "开始开发第一个步骤"
check_contains_any "$LAST_OUTPUT" "数据" "API" "接口" "需要什么数据" "从哪" -- "① 问数据需求"

# ── 2.2 回答数据需求（给明确答案，避免追问）→ 应问处理逻辑 ──
echo ""
info "发送：用 SDK 的 ctx.sif.keyword_metrics 查，不用额外授权，直接写代码"
send_continue "用 SDK 的 ctx.sif.keyword_metrics 查，不用额外授权，直接写代码"
# 如果 agent 还在追问数据相关问题，多给一轮
if ! echo "$LAST_OUTPUT" | grep -qE "怎么处理|处理逻辑|拿到.*之后|透传|聚合"; then
  info "追加回答：就用这个接口，确认"
  send_continue "就用这个接口，数据需求确认了，下一个问题是什么？"
fi
check_contains_any "$LAST_OUTPUT" "怎么处理" "处理逻辑" "拿到" "透传" "聚合" "排序" "做什么" -- "② 问处理逻辑"

# ── 2.3 回答处理逻辑 → 应问输出定义 ──
echo ""
info "发送：直接透传原始数据，不做额外处理"
send_continue "直接透传原始数据，不做额外处理"
check_contains_any "$LAST_OUTPUT" "展示什么给用户" "传什么数据给下一步" "输出" "展示" "用户看" "给用户" -- "③ 问输出定义"

# ── 2.4 回答输出 → 应问用户确认 ──
echo ""
info "发送：表格显示关键词和搜索量"
send_continue "表格显示关键词和搜索量"
check_contains_any "$LAST_OUTPUT" "暂停确认" "自动往下走" "暂停" "确认再继续" -- "④ 问用户确认"

# ── 2.5 完成步骤 1，快速走完步骤 2 ──
echo ""
info "快速走完步骤 2（回答④后逐步推进）"
send_continue "自动继续，不用暂停"
send_continue "步骤2也用 ctx.sif 接口查数据，直接写代码"
send_continue "直接透传，不做额外处理"
send_continue "表格展示就行"
send_continue "这是最后一步了，自动完成就行"

fi  # Phase 2


# ╔══════════════════════════════════════════╗
# ║  Phase 3：结果呈现设计（两维度）           ║
# ╚══════════════════════════════════════════╝

if [ "$PHASE" = "all" ] || [ "$PHASE" = "3" ]; then

phase_header "Phase 3：结果呈现设计"

# 如果只跑 Phase 3，需要先走完前面的流程
if [ "$PHASE" = "3" ]; then
  info "快速走完前置流程..."
  send "hi"
  send_continue "关键词，支持多个"
  send_continue "先查搜索量，再分析竞争度"
  send_continue "开始开发第一个步骤"
  send_continue "用 keyword_metrics 接口查搜索量"
  send_continue "直接把原始数据整理成表格"
  send_continue "表格显示关键词、搜索量、点击份额"
  send_continue "自动继续，不用暂停"
  send_continue "步骤2也用同样的模式，直接帮我完成"
  info "前置流程已完成，开始测试结果呈现"
fi

# ── 3.1 所有节点完成，应该问结果摘要 ──
echo ""
info "发送：所有步骤都开发好了，现在定义最终结果"
send_continue "所有步骤都开发好了，现在定义最终结果"
check_contains_any "$LAST_OUTPUT" "摘要" "总结" "数据" "结果" "步骤" -- "① 问结果摘要"

# ── 3.2 回答摘要 → 应问下载 ──
echo ""
info "发送：大模型自动生成，突出关键数字和结论"
send_continue "大模型自动生成，突出关键数字和结论"
check_contains_any "$LAST_OUTPUT" "下载" "导出" "Excel" "文件" "报告" -- "② 问下载内容"

fi  # Phase 3


# ══════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════"
echo -e "  结果: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} (共 $((PASS + FAIL)) 项)"
echo "═══════════════════════════════════════"
echo ""
echo "所有输出保存在 $LOG_DIR/r*.txt"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
