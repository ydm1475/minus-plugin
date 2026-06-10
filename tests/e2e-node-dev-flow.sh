#!/bin/bash
# E2E 验证：node-dev 四维度流程是否完整可达
# 模拟真实项目环境，验证从 SKILL.md → node-dev.md → step-tracker.sh 的完整链路

set -euo pipefail

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
NODE_DEV="$PLUGIN_ROOT/agents/node-dev.md"

# --- 1. SKILL.md 不再指示启动子 agent ---
if grep -q "启动 node-dev agent" "$SKILL_MD"; then
  fail "SKILL.md 仍包含'启动 node-dev agent'" "子 agent 无法多轮对话"
else
  pass "SKILL.md 不再启动子 agent"
fi

# --- 2. SKILL.md 指示用 Read 读取 node-dev.md ---
if grep -q "Read.*node-dev.md" "$SKILL_MD"; then
  pass "SKILL.md 指示用 Read 工具读取 node-dev.md"
else
  fail "SKILL.md 没有指示读取 node-dev.md" ""
fi

# --- 3. SKILL.md 明确禁止 Agent 工具 ---
if grep -q "禁止启动子 agent\|禁止.*Agent.*工具" "$SKILL_MD"; then
  pass "SKILL.md 明确禁止使用 Agent 工具"
else
  fail "SKILL.md 没有禁止 Agent 工具" ""
fi

# --- 4. node-dev.md 存在且可读 ---
if [ -f "$NODE_DEV" ]; then
  pass "node-dev.md 存在于插件根目录/agents/"
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
if grep -q 'PLUGIN_ROOT' "$NODE_DEV"; then
  pass "node-dev.md 使用 \$PLUGIN_ROOT"
else
  fail "node-dev.md 没有 \$PLUGIN_ROOT" ""
fi

# --- 7. 模拟真实项目：step-tracker.sh 完整链路 ---
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

TRACKER="$PLUGIN_ROOT/skills/minus/scripts/step-tracker.sh"

echo ""
echo "--- 模拟步骤 1（非最后一步）四维度流程 ---"

bash "$TRACKER" complete 1 data 2>&1
bash "$TRACKER" complete 1 logic 2>&1

IS_LAST=$(bash "$TRACKER" is-last 1 2>&1)
if [ "$IS_LAST" = "NO" ]; then
  pass "is-last 步骤1 返回 NO（共2步）"
else
  fail "is-last 步骤1 应返回 NO" "got: $IS_LAST"
fi

bash "$TRACKER" complete 1 output 2>&1

# 非最后一步，Creator 可以选择自动往下走（最终用户不用确认）
if bash "$TRACKER" complete 1 confirm auto 2>/dev/null; then
  pass "step-tracker 允许非最后一步使用 confirm auto"
else
  fail "step-tracker 应允许非最后一步 confirm auto" "不应拒绝"
fi

CHECK=$(bash "$TRACKER" check 1 2>&1)
if echo "$CHECK" | grep -q "COMPLETE"; then
  pass "步骤 1 四维度全部 COMPLETE（含维度④）"
else
  fail "步骤 1 四维度未全部完成" "$CHECK"
fi

echo ""
echo "--- 模拟步骤 2（最后一步）四维度流程 ---"
bash "$TRACKER" complete 2 data 2>&1
bash "$TRACKER" complete 2 logic 2>&1

IS_LAST=$(bash "$TRACKER" is-last 2 2>&1)
if [ "$IS_LAST" = "YES" ]; then
  pass "is-last 步骤2 返回 YES（最后一步）"
else
  fail "is-last 步骤2 应返回 YES" "got: $IS_LAST"
fi

bash "$TRACKER" complete 2 output 2>&1
bash "$TRACKER" complete 2 confirm auto 2>&1
CHECK=$(bash "$TRACKER" check 2 2>&1)
if echo "$CHECK" | grep -q "COMPLETE"; then
  pass "步骤 2 最后一步 confirm auto，自动 COMPLETE"
else
  fail "步骤 2 未完成" "$CHECK"
fi

# 清理
rm -rf "$TMP"

echo ""
echo "═══════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (total: $((PASS+FAIL)))"
echo "═══════════════════════════════"
[ "$FAIL" -eq 0 ] || exit 1
