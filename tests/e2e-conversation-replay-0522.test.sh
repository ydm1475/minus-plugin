#!/bin/bash
# E2E 对话还原验证测试 — 2026-05-22 手动测试项目
# 按 conversation-2026-05-22-102051.txt 的用户输入流程一比一还原
# 着重验证该对话中暴露的 8 个问题是否被修复
#
# 问题清单（按归属分类）：
#   Plugin 侧：
#     P1. API 发现选错接口 — 维度①流程应要求对比多个候选
#     P7. CLI 版没有自动打开浏览器 — open-preview.sh 存在且被引用
#   SDK 侧（验证 Plugin 指令不再触发这些问题）：
#     S1. SelectableTableWidget auto-complete 显示空 — 纯展示应用 display widget
#     S2. upload_file biz_type 猜错 — 查 SDK 文档而非凭记忆
#     S3. ctx.previous_outputs 取数据失败 — 查 SDK 文档
#     S4. 弹框回车焦点问题 — SDK 侧修复，Plugin 不补偿
#   Agent 行为：
#     A1. 重构后遗留变量引用 — 一次性生成代码减少此类问题
#     A2. 摘要和下载按钮分开放 — CompletionPanel 统一渲染
#
# Usage: bash tests/e2e-conversation-replay-0522.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
LIB_DIR="$PLUGIN_DIR/lib"
AGENTS_DIR="$PLUGIN_DIR/agents"
SKILLS_DIR="$PLUGIN_DIR/skills"
NODE_DEV="$AGENTS_DIR/node-dev.md"
SKILL_MD="$SKILLS_DIR/minus/SKILL.md"

# ── Test Framework ──

RESULTS_FILE=$(mktemp)
echo "0 0 0" > "$RESULTS_FILE"

pass() {
  echo "  ✓ $1"
  read P F S < "$RESULTS_FILE"
  echo "$((P + 1)) $F $S" > "$RESULTS_FILE"
}

fail() {
  echo "  ✗ $1"
  echo "    $2"
  read P F S < "$RESULTS_FILE"
  echo "$P $((F + 1)) $S" > "$RESULTS_FILE"
}

skip() {
  echo "  ⊘ $1 (SKIP: $2)"
  read P F S < "$RESULTS_FILE"
  echo "$P $F $((S + 1))" > "$RESULTS_FILE"
}

# ── 准备测试项目 ──

TEST_DIR=$(mktemp -d)
echo "测试目录: $TEST_DIR"
echo ""

mkdir -p "$TEST_DIR/.minus" "$TEST_DIR/frontend/src"
echo '{"skillId":"skl_test_0522","version":"1.0.0"}' > "$TEST_DIR/.minus/skill.json"

cat > "$TEST_DIR/pipeline.py" << 'PYEOF'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome

class TestPipeline(Pipeline):
    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={})

    async def step_2(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={})
PYEOF

cat > "$TEST_DIR/frontend/src/main.tsx" << 'TSEOF'
function buildSteps(t) {
  return [];
}
TSEOF

cd "$TEST_DIR"

# ══════════════════════════════════════════════════════════════
# Phase 1: 两步法 — 用户说"分两步"后生成步骤骨架
# 对话 line 170: "分两步吧，第一步拿到关键词的拓词，第二步拿到这些词的热销ASIN"
# ══════════════════════════════════════════════════════════════

echo "═══ Phase 1: 步骤骨架生成 ═══"

RESULT=$(bash "$LIB_DIR/generate-steps.sh" "关键词拓词" "热销ASIN查询" 2>&1)

if echo "$RESULT" | grep -q "2 个步骤"; then
  pass "generate-steps.sh 生成 2 步骨架"
else
  fail "generate-steps.sh 应生成 2 步" "实际: $RESULT"
fi

if grep -q "async def step_1" pipeline.py && grep -q "async def step_2" pipeline.py; then
  pass "pipeline.py 包含 step_1 和 step_2"
else
  fail "pipeline.py 应包含两个 step 方法" "$(grep 'async def step_' pipeline.py)"
fi

# ══════════════════════════════════════════════════════════════
# Phase 2: 开发步骤 1「关键词拓词」— 非最后一步
# 对话 line 232-298: 四维度问答
# ══════════════════════════════════════════════════════════════

echo ""
echo "═══ Phase 2: 步骤 1 四维度收集（非最后一步）═══"

# --- P1: API 发现应对比多个候选，不选第一个就用 ---
# 对话 line 308: 用错了 keywordByCategory 接口
echo ""
echo "── P1: 维度①数据接口发现流程 ──"

if grep -q "多个候选" "$NODE_DEV" || grep -q "逐个查看参数" "$NODE_DEV"; then
  pass "P1: 维度①要求对比多个候选接口，不选第一个就用"
else
  fail "P1: 维度①应要求对比多个候选接口" "检查 node-dev.md 维度①发现流程"
fi

if grep -q "最简单.*最匹配\|最匹配.*最简单" "$NODE_DEV"; then
  pass "P1: 维度①选择标准：参数最简单、最匹配当前场景"
else
  fail "P1: 维度①应有明确的接口选择标准" "检查 node-dev.md 维度①"
fi

# --- 模拟四维度收集 ---
echo ""
echo "── 步骤 1 四维度状态管理 ──"

# 维度① data: 对话 line 246 用户确认拓词接口
bash "$LIB_DIR/step-tracker.sh" complete 1 data > /dev/null 2>&1
# 维度② logic: 对话 line 260 "按搜索量排序,只展示前200个"
bash "$LIB_DIR/step-tracker.sh" complete 1 logic > /dev/null 2>&1

# is-last 检查
IS_LAST_1=$(bash "$LIB_DIR/step-tracker.sh" is-last 1)
if [ "$IS_LAST_1" = "NO" ]; then
  pass "步骤 1 is-last → NO"
else
  fail "步骤 1 is-last 应为 NO" "实际: $IS_LAST_1"
fi

# 维度③ output: 对话 line 278 "表格列出关键词和搜索量"
bash "$LIB_DIR/step-tracker.sh" complete 1 output > /dev/null 2>&1

# 维度④ confirm: 非最后一步也允许 auto（最终用户不用确认）
AUTO_RESULT=$(bash "$LIB_DIR/step-tracker.sh" complete 1 confirm auto 2>&1 || true)
if echo "$AUTO_RESULT" | grep -q "✓ 步骤 1 — confirm 已确认"; then
  pass "非最后一步 confirm auto 被允许"
else
  fail "非最后一步 confirm auto 应允许" "实际: $AUTO_RESULT"
fi

CHECK_1=$(bash "$LIB_DIR/step-tracker.sh" check 1 2>&1)
if echo "$CHECK_1" | grep -q "COMPLETE"; then
  pass "步骤 1 四维度全部完成"
else
  fail "步骤 1 四维度应全部完成" "实际: $CHECK_1"
fi

# --- 门禁检查 ---
echo ""
echo "── 步骤 1 代码生成门禁 ──"

GATE_1=$(bash "$LIB_DIR/generate-node-code.sh" 1 2>&1)
if echo "$GATE_1" | grep -q "GATE_PASSED" && echo "$GATE_1" | grep -q "CONFIRM_MODE=auto"; then
  pass "步骤 1 门禁通过，CONFIRM_MODE=auto"
else
  fail "步骤 1 门禁应通过且为 auto" "实际: $GATE_1"
fi

# ══════════════════════════════════════════════════════════════
# Phase 3: 开发步骤 2「热销 ASIN 查询」— 最后一步
# 对话 line 512-545: 步骤 2 四维度
# ══════════════════════════════════════════════════════════════

echo ""
echo "═══ Phase 3: 步骤 2 四维度收集（最后一步）═══"

# 维度① data
bash "$LIB_DIR/step-tracker.sh" complete 2 data > /dev/null 2>&1
# 维度② logic: 对话 line 524 "Top 3, 所有 ASIN 汇总一张表，去重，按销量排名"
bash "$LIB_DIR/step-tracker.sh" complete 2 logic > /dev/null 2>&1

IS_LAST_2=$(bash "$LIB_DIR/step-tracker.sh" is-last 2)
if [ "$IS_LAST_2" = "YES" ]; then
  pass "步骤 2 is-last → YES"
else
  fail "步骤 2 is-last 应为 YES" "实际: $IS_LAST_2"
fi

# 维度③ output: 对话 line 524 "展示销量，价格，按照销量排名"
bash "$LIB_DIR/step-tracker.sh" complete 2 output > /dev/null 2>&1

# 最后一步 → 维度④自动跳过，用 auto 模式
bash "$LIB_DIR/step-tracker.sh" complete 2 confirm auto > /dev/null 2>&1
CHECK_2=$(bash "$LIB_DIR/step-tracker.sh" check 2 2>&1)
if echo "$CHECK_2" | grep -q "COMPLETE"; then
  pass "步骤 2 四维度全部完成（维度④自动跳过）"
else
  fail "步骤 2 四维度应全部完成" "实际: $CHECK_2"
fi

GATE_2=$(bash "$LIB_DIR/generate-node-code.sh" 2 2>&1)
if echo "$GATE_2" | grep -q "GATE_PASSED" && echo "$GATE_2" | grep -q "CONFIRM_MODE=auto"; then
  pass "步骤 2 门禁通过，CONFIRM_MODE=auto"
else
  fail "步骤 2 门禁应通过且为 auto" "实际: $GATE_2"
fi

# ══════════════════════════════════════════════════════════════
# Phase 4: 验证对话中 8 个问题的修复
# ══════════════════════════════════════════════════════════════

echo ""
echo "═══ Phase 4: 对话问题修复验证 ═══"

# --- S1: 纯展示表格不用 interactive widget ---
# 对话 line 548: 步骤 2 用 SelectableTableWidget 导致 auto-complete 显示空
echo ""
echo "── S1: 纯展示表格用 display widget ──"

if grep -q "禁止用 interactive widget 做纯展示" "$NODE_DEV"; then
  pass "S1: node-dev.md 禁止用 interactive widget 做纯展示"
else
  fail "S1: 应禁止用 interactive widget 做纯展示" "检查 node-dev.md 前端代码章节"
fi

if grep -q "auto-complete 步骤会显示空" "$NODE_DEV"; then
  pass "S1: node-dev.md 说明了 auto-complete 显示空的原因"
else
  fail "S1: 应说明 auto-complete 步骤用 interactive widget 会显示空" "检查 node-dev.md"
fi

# --- S2: upload_file biz_type 应查文档 ---
# 对话 line 940: agent 猜了 biz_type="report"
echo ""
echo "── S2: 代码生成应查 SDK 文档而非凭记忆 ──"

if grep -q "查项目 CLAUDE.md 里列出的 SDK 开发手册" "$NODE_DEV" || grep -q "查.*SDK.*文档\|查.*开发手册" "$NODE_DEV"; then
  pass "S2: node-dev.md 要求查 SDK 文档获取具体用法"
else
  fail "S2: 应要求查 SDK 文档而非凭记忆写代码" "检查 node-dev.md 前端代码章节"
fi

# 验证 node-dev.md 不再硬编码具体组件代码模板（避免过时）
if ! grep -q "defineWidgetStep<SelectableTableProps" "$NODE_DEV"; then
  pass "S2: node-dev.md 不再硬编码 SelectableTableWidget 代码模板"
else
  fail "S2: node-dev.md 不应硬编码具体组件代码模板" "应引导查 SDK 文档"
fi

# --- A2 + CompletionPanel: 最后一步摘要+下载统一用 CompletionPanel ---
# 对话 line 993: 摘要和下载分开、手写 inline HTML
echo ""
echo "── A2: 最后一步用 CompletionPanel 统一渲染 ──"

if grep -q "CompletionPanel" "$NODE_DEV"; then
  pass "A2: node-dev.md 引用 CompletionPanel"
else
  fail "A2: node-dev.md 应引用 CompletionPanel" "检查前端代码章节"
fi

if grep -q "不需要前端代码.*后端 payload" "$NODE_DEV" || grep -q "后端 payload 返回对应字段" "$NODE_DEV"; then
  pass "A2: CompletionPanel 通过后端 payload 驱动，无需前端代码"
else
  fail "A2: 应说明 CompletionPanel 通过后端 payload 驱动" "检查 node-dev.md"
fi

if grep -q "禁止手写 inline HTML/JSX" "$NODE_DEV"; then
  pass "A2: 禁止手写 inline HTML/JSX 实现摘要或下载"
else
  fail "A2: 应禁止手写 inline HTML/JSX" "检查 node-dev.md"
fi

# --- SDK 文档验证：CompletionPanel 文档存在 ---
echo ""
echo "── SDK 文档可达性验证 ──"

SDK_WIDGETS_DOC=$(find ~/minus-platform-develop/minus-platform/runtime/platform-widgets -name "docs.md" 2>/dev/null | head -1)
if [ -n "$SDK_WIDGETS_DOC" ]; then
  pass "SDK platform-widgets docs.md 存在"

  if grep -q "CompletionPanel" "$SDK_WIDGETS_DOC"; then
    pass "SDK 文档包含 CompletionPanel"
  else
    fail "SDK 文档应包含 CompletionPanel" "路径: $SDK_WIDGETS_DOC"
  fi

  if grep -q "TableWidget" "$SDK_WIDGETS_DOC"; then
    pass "SDK 文档包含 TableWidget"
  else
    fail "SDK 文档应包含 TableWidget" "路径: $SDK_WIDGETS_DOC"
  fi

  if grep -q "SelectableTableWidget" "$SDK_WIDGETS_DOC" && grep -q "DisplayWidget" "$SDK_WIDGETS_DOC"; then
    pass "SDK 文档同时包含 SelectableTableWidget 和 DisplayWidget（分界线可推断）"
  else
    fail "SDK 文档应同时包含 SelectableTableWidget 和 DisplayWidget" "路径: $SDK_WIDGETS_DOC"
  fi
else
  fail "SDK platform-widgets docs.md 不存在" "期望在 runtime/platform-widgets/*/docs.md"
fi

# --- P7: open-preview.sh 存在且可执行 ---
# 对话 line 40-44: dev server 启动后没有自动打开浏览器
echo ""
echo "── P7: 浏览器自动打开 ──"

OPEN_PREVIEW="$LIB_DIR/open-preview.sh"
if [ -f "$OPEN_PREVIEW" ]; then
  pass "P7: open-preview.sh 存在"
  if [ -x "$OPEN_PREVIEW" ]; then
    pass "P7: open-preview.sh 可执行"
  else
    fail "P7: open-preview.sh 应有执行权限" "当前无执行权限"
  fi
else
  fail "P7: open-preview.sh 应存在" "路径: $OPEN_PREVIEW"
fi

# --- A1: 一次性生成代码减少遗留变量问题 ---
# 对话 line 1070: 改了 step1_rows 但 Excel 代码里忘了改
echo ""
echo "── A1: 一次性代码生成（减少遗留变量风险）──"

if grep -q "四个维度的问答阶段只收集意图，不写任何代码" "$NODE_DEV"; then
  pass "A1: 问答阶段不写代码（减少分步修改导致的遗留变量）"
else
  fail "A1: 应声明问答阶段不写代码" "检查 node-dev.md 核心规则"
fi

if grep -q "所有维度全部确认后，一次性生成" "$NODE_DEV"; then
  pass "A1: 全部确认后一次性生成代码"
else
  fail "A1: 应声明一次性生成代码" "检查 node-dev.md 核心规则"
fi

# --- 验证 node-dev.md 不再硬编码具体组件的代码模板 ---
echo ""
echo "── 指令单源化：Plugin 不复制 SDK 的组件用法 ──"

# 不应包含 SelectableTableWidget 的完整代码模板
if ! grep -q "widget: SelectableTableWidget" "$NODE_DEV"; then
  pass "node-dev.md 不含 SelectableTableWidget 代码模板"
else
  fail "node-dev.md 不应含具体组件代码模板" "应引导查 SDK 文档"
fi

# 不应包含 TableWidget 的完整代码模板
if ! grep -q "widget: TableWidget" "$NODE_DEV"; then
  pass "node-dev.md 不含 TableWidget 代码模板"
else
  fail "node-dev.md 不应含具体组件代码模板" "应引导查 SDK 文档"
fi

# CompletionPanel 后端 payload 示例也不应硬编码
if ! grep -q '"filename": "报告.xlsx"' "$NODE_DEV"; then
  pass "node-dev.md 不含 CompletionPanel payload 硬编码示例"
else
  fail "node-dev.md 不应硬编码 CompletionPanel payload 示例" "应引导查 SDK 文档"
fi

# ── 清理 ──

cd /
rm -rf "$TEST_DIR"

# ── Summary ──

echo ""
echo "════════════════════════════════════════"
read PASSED FAILED SKIPPED < "$RESULTS_FILE"
TOTAL=$((PASSED + FAILED + SKIPPED))
echo "E2E 对话还原 (0522): $TOTAL tests, $PASSED passed, $FAILED failed, $SKIPPED skipped"

rm -f "$RESULTS_FILE"

if [ "$FAILED" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
  exit 0
fi
