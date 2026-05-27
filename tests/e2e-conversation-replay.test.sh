#!/bin/bash
# E2E 对话还原验证测试
# 按 conversation-2026-05-21-194400.txt 的用户输入流程，一比一还原关键节点
# 验证框架层操作（step-tracker、generate-steps、is-last）在每个节点的行为是否正确
#
# Usage: bash tests/e2e-conversation-replay.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
LIB_DIR="$PLUGIN_DIR/lib"
AGENTS_DIR="$PLUGIN_DIR/agents"
NODE_DEV="$AGENTS_DIR/node-dev.md"

# ── Test Framework ──

RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"

pass() {
  echo "  ✓ $1"
  read P F < "$RESULTS_FILE"
  echo "$((P + 1)) $F" > "$RESULTS_FILE"
}

fail() {
  echo "  ✗ $1"
  echo "    期望: $2"
  echo "    实际: $3"
  read P F < "$RESULTS_FILE"
  echo "$P $((F + 1))" > "$RESULTS_FILE"
}

# ── 准备测试项目 ──

TEST_DIR=$(mktemp -d)
echo "测试目录: $TEST_DIR"
echo ""

# 模拟一个 2 步 pipeline 项目（和对话一致：关键词拓词 → 热销ASIN查询）
mkdir -p "$TEST_DIR/.minus"
echo '{"skillId":"skl_test_replay","version":"1.0.0"}' > "$TEST_DIR/.minus/skill.json"

cat > "$TEST_DIR/pipeline.py" << 'PYEOF'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome

class TestPipeline(Pipeline):
    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={"text": "关键词拓词"})

    async def step_2(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={"text": "热销ASIN查询"})
PYEOF

cd "$TEST_DIR"

# ══════════════════════════════════════════════════════════════
# 对话还原：两步法 → 步骤确认后生成骨架
# 对应 conversation 第 213-232 行
# 用户说"两步吧，需要第一步拿到关键词后拓词，第二步拿到拓词的词去查询热销的ASIN"
# ══════════════════════════════════════════════════════════════

echo "═══ Phase 1: 两步法 — 步骤结构确认 + 骨架生成 ═══"

# 模拟 generate-steps.sh 生成骨架
mkdir -p frontend/src
cat > frontend/src/main.tsx << 'TSEOF'
function buildSteps(t) {
  return [];
}
TSEOF

RESULT=$(bash "$LIB_DIR/generate-steps.sh" "关键词拓词" "热销ASIN查询" 2>&1)

if echo "$RESULT" | grep -q "pipeline.py 已生成 2 个步骤"; then
  pass "generate-steps.sh 生成 2 步骨架"
else
  fail "generate-steps.sh 应生成 2 步骨架" "包含 '2 个步骤'" "$RESULT"
fi

# 验证 pipeline.py 包含 step_1 和 step_2
if grep -q "async def step_1" pipeline.py && grep -q "async def step_2" pipeline.py; then
  pass "pipeline.py 包含 step_1 和 step_2"
else
  fail "pipeline.py 应包含 step_1 和 step_2" "两个 step 方法" "$(grep 'async def step_' pipeline.py)"
fi

# ══════════════════════════════════════════════════════════════
# 对话还原：开发第 1 步「关键词拓词」— 非最后一步
# 对应 conversation 第 236-658 行
# ══════════════════════════════════════════════════════════════

echo ""
echo "═══ Phase 2: 开发第 1 步（非最后一步）═══"

# TC-R01: is-last 判断第 1 步不是最后一步
IS_LAST_1=$(bash "$LIB_DIR/step-tracker.sh" is-last 1)
if [ "$IS_LAST_1" = "YES" ]; then
  fail "第 1 步 is-last 应返回 NO" "NO" "$IS_LAST_1"
else
  pass "第 1 步 is-last → NO（非最后一步）"
fi

# TC-R02: 维度① — Creator 确认数据接口后标记 data 完成
# 对应 conversation 第 260 行：用户说"可以了"确认以词拓词接口
bash "$LIB_DIR/step-tracker.sh" complete 1 data > /dev/null 2>&1
STATUS_1=$(bash "$LIB_DIR/step-tracker.sh" status 1 2>&1)
if echo "$STATUS_1" | grep -q "✓ 数据需求"; then
  pass "维度① data 标记完成"
else
  fail "维度① data 应标记完成" "✓ 数据需求" "$STATUS_1"
fi

# TC-R03: 维度② — Creator 说"做聚合排序按照搜索量对词进行排序"
# 对应 conversation 第 338 行
bash "$LIB_DIR/step-tracker.sh" complete 1 logic > /dev/null 2>&1

# 按新流程，维度②完成后 Agent 应调 is-last 判断是否最后一步
# 传递数据的问题已移到维度④之后，维度③只问展示内容
if echo "$IS_LAST_1" | grep -q "NO"; then
  # 维度③→④过渡提问不应包含传递数据
  NON_LAST_BLOCK=$(sed -n '/如果不是最后一步（返回 NO）/,/### ④/p' "$NODE_DEV" | head -20)
  if echo "$NON_LAST_BLOCK" | grep -q "传什么数据给下一步"; then
    fail "非最后一步：③→④过渡不应问「传什么数据给下一步」" "已移到④之后" "仍在过渡中"
  else
    pass "非最后一步：③→④过渡不含传递数据问题（已移到④确认后）"
  fi
  # 维度④中应包含传递数据的提问
  DIM4_BLOCK=$(sed -n '/### ④/,/## 阶段二/p' "$NODE_DEV")
  if echo "$DIM4_BLOCK" | grep -q "什么数据传给下一步"; then
    pass "非最后一步：维度④确认后追问传递数据"
  else
    fail "非最后一步：维度④应在确认模式后追问传递数据" "包含" "未找到"
  fi
fi

# TC-R04: 维度③ — Creator 说"一个数据表格"
# 对应 conversation 第 349 行
bash "$LIB_DIR/step-tracker.sh" complete 1 output > /dev/null 2>&1

# TC-R05: 维度④ — Creator 说"需要暂停让用户确认数据再继续"
# 对应 conversation 第 492 行
# 第 1 步不是最后一步 → 维度④不应跳过
CHECK_BEFORE_CONFIRM=$(bash "$LIB_DIR/step-tracker.sh" check 1 2>&1 || true)
if echo "$CHECK_BEFORE_CONFIRM" | grep -q "INCOMPLETE"; then
  pass "维度④未完成前 check 返回 INCOMPLETE"
else
  fail "维度④未完成前应 INCOMPLETE" "INCOMPLETE" "$CHECK_BEFORE_CONFIRM"
fi

bash "$LIB_DIR/step-tracker.sh" complete 1 confirm interactive > /dev/null 2>&1
CHECK_AFTER_CONFIRM=$(bash "$LIB_DIR/step-tracker.sh" check 1 2>&1)
if echo "$CHECK_AFTER_CONFIRM" | grep -q "COMPLETE"; then
  pass "第 1 步四维度全部完成 → COMPLETE"
else
  fail "第 1 步四维度全部完成应 COMPLETE" "COMPLETE" "$CHECK_AFTER_CONFIRM"
fi

# TC-R06: 维度④确认"需要确认" → 验证 node-dev.md 引导查 SDK 文档
# 具体组件行为（如弹框默认值）由 SDK 文档定义，Plugin 不复制
if grep -q "查.*SDK.*文档\|查项目 CLAUDE.md\|查.*开发手册" "$NODE_DEV"; then
  pass "node-dev.md 引导查 SDK 文档获取组件用法"
else
  fail "node-dev.md 应引导查 SDK 文档" "包含查文档引导" "未找到"
fi

# ══════════════════════════════════════════════════════════════
# 对话还原：开发第 2 步「热销 ASIN 查询」— 最后一步
# 对应 conversation 第 661-913 行
# ══════════════════════════════════════════════════════════════

echo ""
echo "═══ Phase 3: 开发第 2 步（最后一步）═══"

# TC-R07: is-last 判断第 2 步是最后一步
IS_LAST_2=$(bash "$LIB_DIR/step-tracker.sh" is-last 2)
if [ "$IS_LAST_2" = "YES" ]; then
  pass "第 2 步 is-last → YES（最后一步）"
else
  fail "第 2 步 is-last 应返回 YES" "YES" "$IS_LAST_2"
fi

# TC-R08: 维度① — Creator 确认接口
bash "$LIB_DIR/step-tracker.sh" complete 2 data > /dev/null 2>&1

# TC-R09: 维度② — Creator 说"做聚合排"
bash "$LIB_DIR/step-tracker.sh" complete 2 logic > /dev/null 2>&1

# 按新流程，维度②完成后 Agent 应调 is-last → YES
# 维度③提问不应包含"需要传什么数据给下一步"
LAST_STEP_BLOCK=$(sed -n '/如果是最后一步（返回 YES）/,/如果不是最后一步/p' "$NODE_DEV" | head -20)
if echo "$LAST_STEP_BLOCK" | grep -q "传什么数据给下一步"; then
  fail "最后一步：维度③不应问下一步数据" "不包含该问题" "仍然包含"
else
  pass "最后一步：维度③提问不含「传什么数据给下一步」"
fi

# TC-R10: 维度③ — Creator 说"一个表格列出热销"（最后一步展示）
# 对应 conversation 第 782 行
bash "$LIB_DIR/step-tracker.sh" complete 2 output > /dev/null 2>&1

# TC-R11: 最后一步 → 维度④应自动跳过
# 新流程：is-last=YES → 维度③完成后直接标记 confirm，不问 Creator
# 验证 node-dev.md 指令：维度③结束时最后一步跳过维度④
SKIP_BLOCK=$(sed -n '/如果是最后一步.*跳过维度④/,/step-tracker.sh.*confirm/p' "$NODE_DEV")
if echo "$SKIP_BLOCK" | grep -q "step-tracker.sh.*complete.*confirm"; then
  pass "最后一步：维度③后直接 complete confirm（跳过维度④）"
else
  fail "最后一步：应在维度③后直接 complete confirm" "包含自动 complete confirm" "未找到"
fi

# 模拟自动跳过：最后一步用 auto 模式
bash "$LIB_DIR/step-tracker.sh" complete 2 confirm auto > /dev/null 2>&1
CHECK_STEP2=$(bash "$LIB_DIR/step-tracker.sh" check 2 2>&1)
if echo "$CHECK_STEP2" | grep -q "COMPLETE"; then
  pass "第 2 步四维度全部完成 → COMPLETE"
else
  fail "第 2 步四维度全部完成应 COMPLETE" "COMPLETE" "$CHECK_STEP2"
fi

# TC-R12: 维度④没有被问到（对比旧流程：conversation 第 896 行 Agent 错误地问了）
# 在新流程中，用户说"没有下一步了啊"（第 768 行）这种情况不应该发生
# 因为 is-last=YES → Agent 根本不会问维度④
echo ""
echo "═══ Phase 4: 回归验证 — 旧对话中的 BUG 场景 ═══"

if [ "$IS_LAST_2" = "YES" ]; then
  pass "BUG-3 修复验证：最后一步被正确识别，维度④不会被问到"
else
  fail "BUG-3 修复验证：最后一步应被正确识别" "YES" "$IS_LAST_2"
fi

# TC-R13: 验证维度②到③的提问模板是多行独立的（BUG-2）
# 旧对话中三行合成一段，现在应该空行分隔
LINE_COUNT=$(grep -c '^$' <<< "$(sed -n '/下一个问题：这一步要展示什么给用户看/,/### ③/p' "$NODE_DEV")")
if [ "$LINE_COUNT" -gt 0 ]; then
  pass "BUG-2 修复验证：维度③提问模板行间有空行分隔"
else
  fail "BUG-2 修复验证：提问模板应有空行分隔" ">0 空行" "$LINE_COUNT 空行"
fi

# TC-R14: 验证纯展示禁止手写 HTML/JSX（BUG-5）
# 旧对话中第 2 步用了手写 HotAsinTable，新规范应禁止
if grep -q "禁止手写 inline HTML/JSX" "$NODE_DEV"; then
  pass "BUG-5 修复验证：node-dev.md 禁止手写 inline HTML/JSX"
else
  fail "BUG-5 修复验证：应禁止手写 inline HTML/JSX" "包含禁止规则" "未找到"
fi

# TC-R15: 验证代码只在所有维度确认后一次性生成（BUG-7 + BUG-8）
# 旧对话中维度①就写了 sort 代码（BUG-7），维度③写了组件后维度④又推翻（BUG-8）
if grep -q "四个维度的问答阶段只收集意图，不写任何代码" "$NODE_DEV"; then
  pass "BUG-7/8 修复验证：问答阶段只收集意图不写代码"
else
  fail "BUG-7/8 修复验证：应声明问答阶段不写代码" "包含声明" "未找到"
fi

if grep -q "一次性生成代码" "$NODE_DEV"; then
  pass "BUG-7/8 修复验证：所有维度确认后一次性生成代码"
else
  fail "BUG-7/8 修复验证：应包含一次性生成代码阶段" "包含声明" "未找到"
fi

# TC-R17: step-tracker 拒绝非最后一步使用 auto 模式
REJECT_AUTO=$(bash "$LIB_DIR/step-tracker.sh" complete 1 confirm auto 2>&1 || true)
if echo "$REJECT_AUTO" | grep -q "不能用 auto 模式"; then
  pass "硬编码门禁：非最后一步 confirm auto 被拒绝"
else
  fail "硬编码门禁：非最后一步 confirm auto 应被拒绝" "包含拒绝信息" "$REJECT_AUTO"
fi

# TC-R18: generate-node-code.sh 门禁 — 维度未全部完成时拒绝生成
bash "$LIB_DIR/step-tracker.sh" reset 1 > /dev/null 2>&1
bash "$LIB_DIR/step-tracker.sh" complete 1 data > /dev/null 2>&1
GATE_RESULT=$(bash "$LIB_DIR/generate-node-code.sh" 1 2>&1 || true)
if echo "$GATE_RESULT" | grep -q "四维度未全部完成"; then
  pass "硬编码门禁：维度未完成时 generate-node-code.sh 拒绝生成"
else
  fail "硬编码门禁：维度未完成时应拒绝" "包含拒绝信息" "$GATE_RESULT"
fi

# TC-R19: generate-node-code.sh 门禁 — 全部完成时输出 GATE_PASSED + 模板
bash "$LIB_DIR/step-tracker.sh" complete 1 logic > /dev/null 2>&1
bash "$LIB_DIR/step-tracker.sh" complete 1 output > /dev/null 2>&1
bash "$LIB_DIR/step-tracker.sh" complete 1 confirm interactive > /dev/null 2>&1
GATE_RESULT2=$(bash "$LIB_DIR/generate-node-code.sh" 1 2>&1)
if echo "$GATE_RESULT2" | grep -q "GATE_PASSED" && echo "$GATE_RESULT2" | grep -q "CONFIRM_MODE=interactive"; then
  pass "硬编码门禁：全部完成 → GATE_PASSED + CONFIRM_MODE=interactive"
else
  fail "硬编码门禁：全部完成应输出 GATE_PASSED" "GATE_PASSED + interactive" "$GATE_RESULT2"
fi

# TC-R20: generate-node-code.sh 输出的 interactive 模板引导查 SDK 文档
if echo "$GATE_RESULT2" | grep -q "CONFIRM_MODE=interactive"; then
  pass "硬编码模板：interactive 模式正确标记 CONFIRM_MODE"
else
  fail "硬编码模板：应输出 CONFIRM_MODE=interactive" "包含 CONFIRM_MODE" "未找到"
fi

# TC-R16: 验证整个流程的 step-tracker 状态正确
echo ""
echo "═══ Phase 5: 最终状态检查 ═══"

LIST_OUTPUT=$(bash "$LIB_DIR/step-tracker.sh" list 2>&1)
if echo "$LIST_OUTPUT" | grep -q "✓ 步骤 1" && echo "$LIST_OUTPUT" | grep -q "✓ 步骤 2"; then
  pass "step-tracker list：两个步骤都标记为全部完成"
else
  fail "step-tracker list 应显示两个步骤全部完成" "✓ 步骤 1 + ✓ 步骤 2" "$LIST_OUTPUT"
fi

# ── 清理 ──

cd /
rm -rf "$TEST_DIR"

# ── Summary ──

echo ""
echo "════════════════════════════════════════"
read PASSED FAILED < "$RESULTS_FILE"
TOTAL=$((PASSED + FAILED))
echo "对话还原验证: $TOTAL tests, $PASSED passed, $FAILED failed"

rm -f "$RESULTS_FILE"

if [ "$FAILED" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
  exit 0
fi
