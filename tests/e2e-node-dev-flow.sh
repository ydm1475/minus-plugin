#!/bin/bash
# E2E 验证：node-dev 四维度流程是否完整可达
# 模拟真实项目环境，验证 SKILL.md → node-dev.md → generate-node-code.sh 的完整链路

set -euo pipefail

# 测试不开浏览器：detect-preview-port 检测成功后会自动 open-preview，测试环境一律抑制
export AUTO_OPEN=0

PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1 — $2"; FAIL=$((FAIL+1)); }

echo "═══ 四维度流程完整性验证 ═══"

# --- 准备 ---
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)/plugins/claude/minus-creator"
if [ -z "$PLUGIN_ROOT" ]; then
  echo "FATAL: 插件未安装"; exit 1
fi

SKILL_MD="$PLUGIN_ROOT/skills/minus/SKILL.md"
DEV_PHASE="$PLUGIN_ROOT/skills/minus/dev-phase.md"
NODE_DEV="$PLUGIN_ROOT/skills/minus-step/node-dev.md"

# --- 1. SKILL.md 不再指示启动子 agent ---
if grep -q "启动 node-dev agent" "$SKILL_MD"; then
  fail "SKILL.md 仍包含'启动 node-dev agent'" "子 agent 无法多轮对话"
else
  pass "SKILL.md 不再启动子 agent"
fi

# --- 2. SKILL.md 指示用 Read 读取 node-dev.md ---
if grep -q "Read.*node-dev.md" "$DEV_PHASE"; then
  pass "dev-phase.md 指示用 Read 工具读取 node-dev.md"
else
  fail "dev-phase.md 没有指示读取 node-dev.md" ""
fi

# --- 4. node-dev.md 存在且可读 ---
if [ -f "$NODE_DEV" ]; then
  pass "node-dev.md 存在于 skills/minus-step/"
else
  fail "node-dev.md 不存在" "$NODE_DEV"
fi

# --- 5. node-dev.md 包含四个维度 ---
for dim in "① 数据需求" "② 处理逻辑" "③ 输出定义" "④ 用户确认"; do
  if grep -q "$dim" "$NODE_DEV"; then
    pass "node-dev.md 包含维度 $dim"
  else
    fail "node-dev.md 缺少维度 $dim" ""
  fi
done

# --- 6. node-dev.md 使用 PLUGIN_ROOT（非 PLUGIN_DIR）---
if grep -q 'PLUGIN_DIR' "$NODE_DEV"; then
  fail "node-dev.md 仍引用未定义的 \$PLUGIN_DIR" ""
else
  pass "node-dev.md 不包含 \$PLUGIN_DIR"
fi

# --- 7. 模拟真实项目：generate-node-code.sh 三参数链路 ---
TMP=$(mktemp -d)
cd "$TMP"
mkdir -p .minus

echo '{"skillId":"test-skill","version":"1.0"}' > .minus/skill.json

cat > pipeline.py << 'PY'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome
class TestPipeline(Pipeline):
    async def step_1(self, ctx):
        return StepOutcome.complete(payload={})
    async def step_2(self, ctx):
        return StepOutcome.complete(payload={})
PY

GNC="$PLUGIN_ROOT/skills/minus-step/scripts/generate-node-code.sh"

echo ""
echo "--- generate-node-code.sh 三参数接口验证 ---"

# 7a. 合法参数应输出 GATE_PASSED
RESULT=$(bash "$GNC" 1 deterministic auto 2>&1)
if echo "$RESULT" | grep -q "GATE_PASSED"; then
  pass "generate-node-code 合法参数 → GATE_PASSED"
else
  fail "generate-node-code 合法参数应输出 GATE_PASSED" "$RESULT"
fi

# 7b. 非法 logic_mode 应拒绝
RESULT=$(bash "$GNC" 1 badmode auto 2>&1 || true)
if echo "$RESULT" | grep -q "错误"; then
  pass "generate-node-code 非法 logic_mode → 拒绝"
else
  fail "generate-node-code 非法 logic_mode 应拒绝" "$RESULT"
fi

# 7c. 非法 confirm_mode 应拒绝
RESULT=$(bash "$GNC" 1 deterministic badmode 2>&1 || true)
if echo "$RESULT" | grep -q "错误"; then
  pass "generate-node-code 非法 confirm_mode → 拒绝"
else
  fail "generate-node-code 非法 confirm_mode 应拒绝" "$RESULT"
fi

# 7d. is-last: 步骤 1（共2步）→ IS_LAST=NO
RESULT=$(bash "$GNC" 1 deterministic auto 2>&1)
if echo "$RESULT" | grep -q "IS_LAST=NO"; then
  pass "is-last 步骤1 → NO（共2步）"
else
  fail "is-last 步骤1 应为 NO" "$RESULT"
fi

# 7e. is-last: 步骤 2（共2步）→ IS_LAST=YES
RESULT=$(bash "$GNC" 2 deterministic auto 2>&1)
if echo "$RESULT" | grep -q "IS_LAST=YES"; then
  pass "is-last 步骤2 → YES（最后一步）"
else
  fail "is-last 步骤2 应为 YES" "$RESULT"
fi

# 7f. llm 模式输出 LLM_REQUIRED=YES
RESULT=$(bash "$GNC" 1 llm interactive 2>&1)
if echo "$RESULT" | grep -q "LLM_REQUIRED=YES"; then
  pass "llm 模式 → LLM_REQUIRED=YES"
else
  fail "llm 模式应输出 LLM_REQUIRED=YES" "$RESULT"
fi

# 7g. interactive 模式输出 FRONTEND_TEMPLATE=interactive
RESULT=$(bash "$GNC" 1 deterministic interactive 2>&1)
if echo "$RESULT" | grep -q "FRONTEND_TEMPLATE=interactive"; then
  pass "interactive 模式 → FRONTEND_TEMPLATE=interactive"
else
  fail "interactive 模式应输出 FRONTEND_TEMPLATE=interactive" "$RESULT"
fi

# 7h. auto 模式输出 FRONTEND_TEMPLATE=display
RESULT=$(bash "$GNC" 1 deterministic auto 2>&1)
if echo "$RESULT" | grep -q "FRONTEND_TEMPLATE=display"; then
  pass "auto 模式 → FRONTEND_TEMPLATE=display"
else
  fail "auto 模式应输出 FRONTEND_TEMPLATE=display" "$RESULT"
fi

# 清理
rm -rf "$TMP"

echo ""
echo "═══════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (total: $((PASS+FAIL)))"
echo "═══════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
