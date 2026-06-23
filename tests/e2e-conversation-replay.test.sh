#!/bin/bash
# E2E 对话还原验证测试
# 按 conversation-2026-05-21-194400.txt 的用户输入流程，一比一还原关键节点
# 验证框架层操作（generate-steps、generate-node-code）在每个节点的行为是否正确
#
# Usage: bash tests/e2e-conversation-replay.test.sh

set -euo pipefail

# 测试不开浏览器：detect-preview-port 检测成功后会自动 open-preview，测试环境一律抑制
export AUTO_OPEN=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
LIB_DIR="$PLUGIN_DIR/skills/minus/scripts"
STEP_LIB="$(dirname "$(dirname "$LIB_DIR")")/minus-step/scripts"
NODE_DEV="$PLUGIN_DIR/skills/minus-step/node-dev.md"

# 套件自身的 node 解析（pj 等 helper 用）；被测脚本统一经 bin/minus-lib 分发器
# 调用（与生产路径一致），分发器自带 node 解析。
RESOLVED_NODE="$(sh "$PLUGIN_DIR/scripts/resolve-node.sh" 2>/dev/null || true)"
[ -n "$RESOLVED_NODE" ] && export PATH="$(dirname "$RESOLVED_NODE"):$PATH"
[ -n "$RESOLVED_NODE" ] && export MINUS_NODE_BIN_DIR="$(dirname "$RESOLVED_NODE")"  # 预填分发器缓存
ML_BIN="$PLUGIN_DIR/bin/minus-lib"

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

RESULT=$(bash "$ML_BIN" generate-steps "关键词拓词" "热销ASIN查询" 2>&1)

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

# TC-R01: generate-node-code is-last 判断第 1 步不是最后一步
GNC_1=$(bash "$ML_BIN" generate-node-code 1 deterministic interactive 2>&1)
if echo "$GNC_1" | grep -q "IS_LAST=NO"; then
  IS_LAST_1="NO"
  pass "第 1 步 is-last → NO（非最后一步）"
else
  IS_LAST_1="YES"
  fail "第 1 步 is-last 应返回 NO" "NO" "$(echo "$GNC_1" | grep IS_LAST)"
fi

# TC-R02: generate-node-code 输出 GATE_PASSED
if echo "$GNC_1" | grep -q "GATE_PASSED"; then
  pass "步骤 1 generate-node-code → GATE_PASSED"
else
  fail "步骤 1 generate-node-code 应输出 GATE_PASSED" "GATE_PASSED" "$GNC_1"
fi

# TC-R03: 非最后一步 node-dev.md 流程验证
# 传递数据的问题已移到维度④之后，维度③只问展示内容
if [ "$IS_LAST_1" = "NO" ]; then
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

# TC-R05: generate-node-code 正确输出 CONFIRM_MODE=interactive
if echo "$GNC_1" | grep -q "CONFIRM_MODE=interactive"; then
  pass "步骤 1 CONFIRM_MODE=interactive"
else
  fail "步骤 1 CONFIRM_MODE 应为 interactive" "CONFIRM_MODE=interactive" "$GNC_1"
fi

# TC-R06: 维度④确认"需要确认" → 验证 node-dev.md 引导查 SDK 文档
# 具体组件行为（如弹框默认值）由 SDK 文档定义，Plugin 不复制
if grep -q "SDK 开发手册\|查.*SDK.*文档\|查.*开发手册" "$NODE_DEV"; then
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

# TC-R07: generate-node-code is-last 判断第 2 步是最后一步
GNC_2=$(bash "$ML_BIN" generate-node-code 2 deterministic auto 2>&1)
if echo "$GNC_2" | grep -q "IS_LAST=YES"; then
  IS_LAST_2="YES"
  pass "第 2 步 is-last → YES（最后一步）"
else
  IS_LAST_2="NO"
  fail "第 2 步 is-last 应返回 YES" "YES" "$(echo "$GNC_2" | grep IS_LAST)"
fi

# TC-R08: generate-node-code 输出 GATE_PASSED
if echo "$GNC_2" | grep -q "GATE_PASSED"; then
  pass "步骤 2 generate-node-code → GATE_PASSED"
else
  fail "步骤 2 generate-node-code 应输出 GATE_PASSED" "GATE_PASSED" "$GNC_2"
fi

# 按新流程，维度②完成后 Agent 应调 is-last → YES
# 维度③提问不应包含"需要传什么数据给下一步"
LAST_STEP_BLOCK=$(sed -n '/如果是最后一步（返回 YES）/,/如果不是最后一步/p' "$NODE_DEV" | head -20)
if echo "$LAST_STEP_BLOCK" | grep -q "传什么数据给下一步"; then
  fail "最后一步：维度③不应问下一步数据" "不包含该问题" "仍然包含"
else
  pass "最后一步：维度③提问不含「传什么数据给下一步」"
fi

# TC-R11: 最后一步使用 auto 模式 → CONFIRM_MODE=auto, FRONTEND_TEMPLATE=display
if echo "$GNC_2" | grep -q "CONFIRM_MODE=auto" && echo "$GNC_2" | grep -q "FRONTEND_TEMPLATE=display"; then
  pass "最后一步：CONFIRM_MODE=auto + FRONTEND_TEMPLATE=display"
else
  fail "最后一步：应输出 CONFIRM_MODE=auto + FRONTEND_TEMPLATE=display" "CONFIRM_MODE=auto + display" "$GNC_2"
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
# 规则已硬编码进 generate-node-code.sh 的 display 模板约束（只渲染已确认内容）
if grep -q "只渲染 Creator 在输出定义阶段明确确认的展示内容" "$STEP_LIB/generate-node-code.sh"; then
  pass "BUG-5 修复验证：display 模板约束承接禁止手写 inline HTML/JSX"
else
  fail "BUG-5 修复验证：应禁止手写 inline HTML/JSX" "generate-node-code.sh 缺 display 模板约束" "未找到"
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

# TC-R17: generate-node-code.sh 非最后一步 auto 模式正常通过
GNC_1_AUTO=$(bash "$ML_BIN" generate-node-code 1 deterministic auto 2>&1)
if echo "$GNC_1_AUTO" | grep -q "GATE_PASSED" && echo "$GNC_1_AUTO" | grep -q "CONFIRM_MODE=auto"; then
  pass "门禁：非最后一步 confirm auto → GATE_PASSED"
else
  fail "门禁：非最后一步 confirm auto 应输出 GATE_PASSED" "GATE_PASSED + auto" "$GNC_1_AUTO"
fi

# TC-R19: generate-node-code.sh 全部参数正确时输出 GATE_PASSED + 模板
GATE_RESULT2=$(bash "$ML_BIN" generate-node-code 1 deterministic interactive 2>&1)
if echo "$GATE_RESULT2" | grep -q "GATE_PASSED" \
   && echo "$GATE_RESULT2" | grep -q "LOGIC_MODE=deterministic" \
   && echo "$GATE_RESULT2" | grep -q "CONFIRM_MODE=interactive"; then
  pass "门禁：GATE_PASSED + LOGIC_MODE=deterministic + CONFIRM_MODE=interactive"
else
  fail "门禁：应输出 GATE_PASSED" "GATE_PASSED + deterministic + interactive" "$GATE_RESULT2"
fi

# TC-R20: generate-node-code.sh 输出的 interactive 模板引导查 SDK 文档
if echo "$GATE_RESULT2" | grep -q "FRONTEND_TEMPLATE=interactive"; then
  pass "模板：interactive 模式输出 FRONTEND_TEMPLATE=interactive"
else
  fail "模板：应输出 FRONTEND_TEMPLATE=interactive" "包含 FRONTEND_TEMPLATE" "未找到"
fi

# TC-R21: LLM 模式 → LOGIC_MODE=llm + LLM_REQUIRED=YES
GATE_RESULT3=$(bash "$ML_BIN" generate-node-code 2 llm auto 2>&1)
if echo "$GATE_RESULT3" | grep -q "LOGIC_MODE=llm" && echo "$GATE_RESULT3" | grep -q "LLM_REQUIRED=YES"; then
  pass "LLM 意图：LOGIC_MODE=llm + LLM_REQUIRED=YES"
else
  fail "LLM 意图应传递到代码生成门禁" "LOGIC_MODE=llm + LLM_REQUIRED=YES" "$GATE_RESULT3"
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
