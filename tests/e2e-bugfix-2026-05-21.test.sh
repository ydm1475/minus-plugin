#!/bin/bash
# E2E Bugfix 验证测试 — 2026-05-21 报告
# 专项验证 8 个 BUG 的修复，独立于已有测试
# Usage: bash tests/e2e-bugfix-2026-05-21.test.sh

set -euo pipefail

# 测试不开浏览器：detect-preview-port 检测成功后会自动 open-preview，测试环境一律抑制
export AUTO_OPEN=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$REPO_DIR/plugins/claude/minus-creator/skills/minus/scripts"
STEP_LIB="$(dirname "$(dirname "$LIB_DIR")")/minus-step/scripts"
STRUCT_LIB="$(dirname "$(dirname "$LIB_DIR")")/minus-structure/scripts"
AGENTS_DIR="$REPO_DIR/plugins/claude/minus-creator/agents"
SKILLS_DIR="$REPO_DIR/plugins/claude/minus-creator/skills"

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

assert_contains() {
  echo "$1" | grep -q "$2"
}

assert_not_contains() {
  ! echo "$1" | grep -q "$2"
}

assert_file_contains() {
  grep -q "$2" "$1"
}

assert_file_not_contains() {
  ! grep -q "$2" "$1"
}

# ── TC-01: step-tracker.sh is-last 对最后一步返回正确标记 ──

echo ""
echo "TC-01: step-tracker.sh is-last（BUG-1/BUG-3 基础设施）"

TMPDIR_01=$(mktemp -d)
cat > "$TMPDIR_01/pipeline.py" << 'PYEOF'
import asyncio
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome

class TestPipeline(Pipeline):
    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={})

    async def step_2(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={})
PYEOF

pushd "$TMPDIR_01" > /dev/null

RESULT_1=$(bash "$STEP_LIB/step-tracker.sh" is-last 1)
if assert_contains "$RESULT_1" "NO"; then
  pass "step 1 of 2 → is-last returns NO"
else
  fail "step 1 of 2 → is-last should return NO" "got: $RESULT_1"
fi

RESULT_2=$(bash "$STEP_LIB/step-tracker.sh" is-last 2)
if assert_contains "$RESULT_2" "YES"; then
  pass "step 2 of 2 → is-last returns YES"
else
  fail "step 2 of 2 → is-last should return YES" "got: $RESULT_2"
fi

popd > /dev/null
rm -rf "$TMPDIR_01"

# ── TC-02: node-dev.md 维度②→③提问模板包含换行分隔 ──

echo ""
echo "TC-02: 维度提问模板换行分隔（BUG-2）"

NODE_DEV="$SKILLS_DIR/minus-step/node-dev.md"

# 检查维度②→③的提问是多行独立的（每个问题前后有空行）
if grep -A1 '下一个问题：这一步要展示什么给用户看？' "$NODE_DEV" | grep -q '^$'; then
  pass "维度③提问模板各行之间有空行分隔"
else
  fail "维度③提问模板各行应有空行分隔" "检查 node-dev.md 中提问模板格式"
fi

# 检查"比如一个数据表格"和"还有，需要传什么数据"是独立的行
if grep -c '「比如一个数据表格' "$NODE_DEV" | grep -q '[1-9]'; then
  pass "展示类型选项独立成行"
else
  fail "展示类型选项应独立成行" "不应与其他问题合并在一行"
fi

# ── TC-03: node-dev.md 最后一步维度③不含"传什么数据给下一步" ──

echo ""
echo "TC-03: 最后一步维度③不问下一步（BUG-3）"

# 检查有两个版本的维度③提问：最后一步版本不含"传什么数据给下一步"
LAST_STEP_SECTION=$(sed -n '/如果是最后一步（返回 YES）/,/如果不是最后一步/p' "$NODE_DEV" | head -20)

if assert_not_contains "$LAST_STEP_SECTION" "传什么数据给下一步"; then
  pass "最后一步的维度③提问不含「传什么数据给下一步」"
else
  fail "最后一步的维度③提问不应包含「传什么数据给下一步」" "在 is-last=YES 分支中仍出现"
fi

# 非最后一步版本应该包含
NON_LAST_SECTION=$(sed -n '/如果不是最后一步（返回 NO）/,/### ③/p' "$NODE_DEV" | head -20)

if assert_contains "$NON_LAST_SECTION" "传什么数据给下一步"; then
  pass "非最后一步的维度③提问包含「传什么数据给下一步」"
else
  fail "非最后一步的维度③提问应包含「传什么数据给下一步」" "在 is-last=NO 分支中缺失"
fi

# ── TC-04: node-dev.md 最后一步维度④硬性跳过 ──

echo ""
echo "TC-04: 最后一步维度④跳过（BUG-3 延伸）"

# 检查维度③结束时，最后一步直接标记 confirm 完成
if assert_file_contains "$NODE_DEV" "如果是最后一步.*跳过维度④"; then
  pass "维度③结束时最后一步直接跳过维度④"
else
  fail "应在维度③结束时对最后一步跳过维度④" "检查 node-dev.md 维度③末尾逻辑"
fi

# 检查维度④开头有硬性跳过声明
if assert_file_contains "$NODE_DEV" "最后一步硬性跳过"; then
  pass "维度④开头声明最后一步硬性跳过"
else
  fail "维度④应在开头声明最后一步硬性跳过" "检查 node-dev.md 维度④"
fi

# 检查使用 step-tracker.sh is-last 做判断
if assert_file_contains "$NODE_DEV" "step-tracker.*is-last"; then
  pass "使用 step-tracker is-last 做硬编码判断"
else
  fail "应使用 step-tracker is-last 做判断" "不应靠 agent 自行判断"
fi

# ── TC-05: 刷新数据丢失（SDK 层问题，标记 SKIP）──

echo ""
echo "TC-05: 确认后刷新数据恢复（BUG-4）"

skip "数据持久化验证" "需要在 SDK + widget-framework 层验证，非指令层面修复"

# ── TC-06: node-dev.md 禁止手写 HTML table ──

echo ""
echo "TC-06: 禁止手写 HTML table（BUG-5）"

if assert_file_contains "$NODE_DEV" "禁止手写 inline HTML/JSX"; then
  pass "node-dev.md 包含禁止手写 inline HTML/JSX 规范"
else
  fail "node-dev.md 应包含禁止手写 inline HTML/JSX 规范" "检查前端代码章节"
fi

if assert_file_contains "$NODE_DEV" "display widget\|interactive widget"; then
  pass "node-dev.md 区分 display widget 和 interactive widget"
else
  fail "node-dev.md 应区分 display 和 interactive widget" "检查前端代码章节"
fi

# ── TC-07: node-dev.md 维度④代码模板包含 modal: true ──

echo ""
echo "TC-07: 交互确认默认弹框（BUG-6）"

if assert_file_contains "$NODE_DEV" "查.*SDK.*文档\|查项目 CLAUDE.md\|查.*开发手册"; then
  pass "node-dev.md 引导查 SDK 文档获取组件用法（含弹框行为）"
else
  fail "node-dev.md 应引导查 SDK 文档" "检查前端代码章节"
fi

if assert_file_contains "$NODE_DEV" "interactive widget"; then
  pass "node-dev.md 提及 interactive widget（用户勾选确认场景）"
else
  fail "应提及 interactive widget" "检查前端代码章节"
fi

# ── TC-08: node-dev.md 四维度流程为"先收集意图再写码" ──

echo ""
echo "TC-08: 先收集意图再一次性写码（BUG-7 + BUG-8）"

# 检查阶段一只收集意图
if assert_file_contains "$NODE_DEV" "四个维度的问答阶段只收集意图，不写任何代码"; then
  pass "明确声明问答阶段不写代码"
else
  fail "应明确声明问答阶段不写代码" "检查核心规则部分"
fi

# 检查阶段二一次性生成
if assert_file_contains "$NODE_DEV" "一次性生成代码"; then
  pass "包含「一次性生成代码」阶段"
else
  fail "应包含「一次性生成代码」阶段" "检查阶段二部分"
fi

# 检查维度①不再有"编写数据获取代码"
if assert_file_not_contains "$NODE_DEV" "然后编写数据获取代码"; then
  pass "维度①不再包含写代码指令"
else
  fail "维度①不应包含写代码指令" "应只收集意图"
fi

# 检查维度②不再有"编写处理逻辑代码"
if assert_file_not_contains "$NODE_DEV" "然后编写处理逻辑代码"; then
  pass "维度②不再包含写代码指令"
else
  fail "维度②不应包含写代码指令" "应只收集意图"
fi

# ── TC-09: node-dev.md 支持 SDK 内置 LLM 能力 ──

echo ""
echo "TC-09: 处理逻辑支持 SDK 内置 LLM 能力"

if assert_file_not_contains "$NODE_DEV" "SDK 不支持 LLM 调用"; then
  pass "node-dev.md 不再保留旧的 LLM 禁令"
else
  fail "node-dev.md 不应再声明 SDK 不支持 LLM" "当前 SDK 已支持大模型调用"
fi

if assert_file_contains "$NODE_DEV" "可使用 SDK 内置 LLM 能力"; then
  pass "维度②允许摘要/洞察等场景使用 SDK LLM"
else
  fail "维度②应说明可使用 SDK 内置 LLM 能力" "检查处理逻辑章节"
fi

if assert_file_contains "$NODE_DEV" "Creator 明确说\"用大模型自动生成\""; then
  pass "维度②识别 Creator 明确的大模型自动生成意图"
else
  fail "维度②应识别用户明确的大模型生成意图" "检查处理逻辑章节"
fi

if assert_file_contains "$NODE_DEV" "直接透传原始数据？做聚合/排序？用大模型做分析总结？"; then
  pass "维度②提问展示完整处理方式选项"
else
  fail "维度②提问应包含大模型分析总结选项" "检查维度②提问模板"
fi

if assert_file_contains "$NODE_DEV" "动态生成需要确认的问题" \
   && assert_file_contains "$NODE_DEV" "禁止照搬固定问题清单" \
   && assert_file_contains "$NODE_DEV" "只有 Creator 明确确认后，才能记录"; then
  pass "维度②使用 LLM 前要求动态生成确认内容并获得明确确认"
else
  fail "维度②使用 LLM 前应动态确认" "检查处理逻辑章节"
fi

# ── TC-10: 用户确认后的摘要使用隐藏 finalize 持久化 ──

echo ""
echo "TC-10: 用户确认后的摘要使用隐藏 finalize 持久化"

if assert_file_contains "$NODE_DEV" "追加一个隐藏 finalize 步骤" \
   && assert_file_contains "$NODE_DEV" "frontend-guide.md" \
   && assert_file_contains "$NODE_DEV" "供选择 n 个关键词" \
   && assert_file_contains "$NODE_DEV" "禁止修改 Python SDK"; then
  pass "node-dev.md 覆盖模板摘要和 LLM 摘要的隐藏 finalize 规则"
else
  fail "node-dev.md 应明确隐藏 finalize 摘要规则" "检查步骤摘要与 finalize 规则"
fi

if assert_file_contains "$NODE_DEV" "必须在后端 SDK 开发手册中查到 SDK 内置 LLM 调用方式"; then
  pass "LLM 代码生成前要求查后端 SDK 文档"
else
  fail "LLM 代码生成前应查 SDK 文档" "避免在 Plugin 中硬编码 LLM API 形态"
fi

# ── Summary ──

echo ""
echo "════════════════════════════════════════"
read PASSED FAILED SKIPPED < "$RESULTS_FILE"
TOTAL=$((PASSED + FAILED + SKIPPED))
echo "E2E Bugfix 2026-05-21: $TOTAL tests, $PASSED passed, $FAILED failed, $SKIPPED skipped"

rm -f "$RESULTS_FILE"

if [ "$FAILED" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
  exit 0
fi
