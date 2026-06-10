#!/bin/bash
# E2E 修复验证测试
# 按「测试默认页」对话流程一比一还原，验证问题 1-9 的修复是否生效
#
# 验证点：
#   问题 5: minus-dev-cleanup 可从根 node_modules/.bin 找到
#   问题 7: SKILL.md 不再有 skill_update input 指引
#   问题 9a: is-last 从 .minus/total-steps 读取（而非 grep pipeline.py）
#   问题 9b: generate-steps.sh --append 增量添加不覆盖
#   问题 9 组合: 添加第 3 步后 is-last 3 → YES，最后一步跳过维度④
#
# Usage: bash tests/e2e-fixes-verification.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
LIB_DIR="$PLUGIN_DIR/skills/minus/scripts"
SKILL_MD="$PLUGIN_DIR/skills/minus/SKILL.md"

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
  [ -n "${2:-}" ] && echo "    期望: $2"
  [ -n "${3:-}" ] && echo "    实际: $3"
  read P F < "$RESULTS_FILE"
  echo "$P $((F + 1))" > "$RESULTS_FILE"
}

# ── 准备测试项目 ──

TEST_DIR=$(mktemp -d)
echo "测试目录: $TEST_DIR"
echo ""

mkdir -p "$TEST_DIR/.minus" "$TEST_DIR/frontend/src"
echo '{"skillId":"skl_test_fixes","version":"1.0-alpha.1"}' > "$TEST_DIR/.minus/skill.json"

# 初始 pipeline.py（脚手架默认）
cat > "$TEST_DIR/pipeline.py" << 'PYEOF'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome


class SklTestFixesPipeline(Pipeline):

    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={"text": "placeholder"})
PYEOF

# 初始 main.tsx（脚手架默认）
cat > "$TEST_DIR/frontend/src/main.tsx" << 'TSXEOF'
function buildSteps(t: (k: string, fb?: string) => string): StepConfig[] {
  return [
    {
      render: ({ data }) => (
        <div>{(data.text as string) ?? 'placeholder'}</div>
      ),
    },
  ];
}
TSXEOF

cd "$TEST_DIR"

# ══════════════════════════════════════════════════════════════
echo "═══ 问题 5: root-package.json.tpl 包含 @minus/dev-vite-plugin ═══"
# ══════════════════════════════════════════════════════════════

TPL_FILE="$REPO_DIR/../minus-platform/packages/create-skill/templates/root-package.json.tpl"
if [ -f "$TPL_FILE" ]; then
  if grep -q '@minus/dev-vite-plugin' "$TPL_FILE"; then
    pass "root-package.json.tpl 的 devDependencies 包含 @minus/dev-vite-plugin"
  else
    fail "root-package.json.tpl 应包含 @minus/dev-vite-plugin" "devDependencies 中有该包" "未找到"
  fi

  # 验证 create-skill index.mjs 也处理了根 package.json 的 file: 替换
  IDX_FILE="$REPO_DIR/../minus-platform/packages/create-skill/index.mjs"
  if [ -f "$IDX_FILE" ] && grep -q 'rootPkg.devDependencies.*dev-vite-plugin' "$IDX_FILE"; then
    pass "create-skill index.mjs 对 rootPkg 也做了 file: 路径替换"
  else
    fail "create-skill index.mjs 应对 rootPkg 做 file: 替换" "包含 rootPkg devDependencies 处理" "未找到"
  fi
else
  echo "  ⚠ 跳过问题 5 验证（未找到模板文件）"
fi

# ══════════════════════════════════════════════════════════════
echo ""
echo "═══ 问题 7: SKILL.md 不再有 skill_update input 指引 ═══"
# ══════════════════════════════════════════════════════════════

if grep -q 'skill_update.*input\|只传 input' "$SKILL_MD"; then
  fail "SKILL.md 不应包含 skill_update input 指引" "无匹配" "仍有匹配"
else
  pass "SKILL.md 无 skill_update input 指引"
fi

# 确认 "确认后做两件事" 已改为 "确认后更新前端代码"
if grep -q '确认后更新前端代码' "$SKILL_MD"; then
  pass "SKILL.md 已改为「确认后更新前端代码」"
else
  fail "SKILL.md 应包含「确认后更新前端代码」" "包含" "未找到"
fi

# 确认 b) 前缀已去掉
if grep -q '\*\*b)' "$SKILL_MD"; then
  fail "SKILL.md 不应有 **b) 前缀" "无 b) 前缀" "仍有"
else
  pass "SKILL.md 的输入指引无 b) 前缀"
fi

# ══════════════════════════════════════════════════════════════
echo ""
echo "═══ 问题 9a: is-last 优先读 .minus/total-steps ═══"
# ══════════════════════════════════════════════════════════════

# 场景：pipeline.py 有 1 个 step，但 .minus/total-steps 说有 3 个
echo "3" > .minus/total-steps

IS_LAST_3=$(bash "$LIB_DIR/step-tracker.sh" is-last 3 2>&1)
if [ "$IS_LAST_3" = "YES" ]; then
  pass "is-last 3：从 .minus/total-steps 读取 → YES"
else
  fail "is-last 3 应返回 YES（.minus/total-steps=3）" "YES" "$IS_LAST_3"
fi

IS_LAST_1=$(bash "$LIB_DIR/step-tracker.sh" is-last 1 2>&1)
if [ "$IS_LAST_1" = "NO" ]; then
  pass "is-last 1：3 步中的第 1 步 → NO"
else
  fail "is-last 1 应返回 NO" "NO" "$IS_LAST_1"
fi

# 场景：没有 .minus/total-steps → fallback 到 grep pipeline.py
rm -f .minus/total-steps
IS_LAST_FALLBACK=$(bash "$LIB_DIR/step-tracker.sh" is-last 1 2>&1)
if [ "$IS_LAST_FALLBACK" = "YES" ]; then
  pass "is-last fallback：pipeline.py 只有 1 个 step → step 1 = YES"
else
  fail "is-last fallback 应返回 YES（pipeline.py 1 step）" "YES" "$IS_LAST_FALLBACK"
fi

# confirm auto 不受是否最后一步限制；它表示最终用户不用暂停确认
echo "3" > .minus/total-steps
mkdir -p .minus/dev-progress
touch .minus/dev-progress/step_1_data
touch .minus/dev-progress/step_1_logic
touch .minus/dev-progress/step_1_output
AUTO_RESULT=$(bash "$LIB_DIR/step-tracker.sh" complete 1 confirm auto 2>&1 || true)
if echo "$AUTO_RESULT" | grep -q "✓ 步骤 1 — confirm 已确认"; then
  pass "confirm auto 校验：非最后一步也允许 auto"
else
  fail "confirm auto 应允许非最后一步" "confirm 已确认" "$AUTO_RESULT"
fi

# ══════════════════════════════════════════════════════════════
echo ""
echo "═══ 问题 9b: generate-steps.sh --append 增量添加 ═══"
# ══════════════════════════════════════════════════════════════

# 先重置：用 generate-steps.sh 全量生成 2 步
rm -rf .minus/dev-progress
cat > frontend/src/main.tsx << 'TSXEOF'
function buildSteps(t: (k: string, fb?: string) => string): StepConfig[] {
  return [];
}
TSXEOF

RESULT_GEN=$(bash "$LIB_DIR/generate-steps.sh" "热销 ASIN 采集" "ASIN 销量查询" 2>&1)
if echo "$RESULT_GEN" | grep -q "pipeline.py 已生成 2 个步骤"; then
  pass "generate-steps.sh 全量生成 2 步"
else
  fail "generate-steps.sh 应生成 2 步" "2 个步骤" "$RESULT_GEN"
fi

# 模拟已实现的 step_1（加入自定义代码）
cat > pipeline.py << 'PYEOF'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome


class SklTestFixesPipeline(Pipeline):

    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        keyword = ctx.entry_params.get("keywords", "")
        country = ctx.entry_params.get("country", "US")
        result = await ctx.sif.request("POST", "/api/search/external/v2/competePatternFlexibleGroupByWeekly", json={"keywords": [keyword]}, params={"country": country})
        rows = [{"asin": item.get("asin", "")} for item in (result.get("list") or [])]
        return StepOutcome.input_required(payload={"rows": rows, "keyword": keyword, "country": country})

    async def step_2(self, ctx: PipelineContext) -> StepOutcome:
        selected = ctx.last_user_input.get("selected_asins") or []
        asin_list = [row["asin"] for row in selected if row.get("asin")]
        rows = [{"asin": a, "totalSales6m": 0} for a in asin_list]
        rows.sort(key=lambda r: r["totalSales6m"], reverse=True)
        return StepOutcome.complete(payload={"rows": rows})
PYEOF

# 保存 step_1 的签名供后续验证
STEP1_BEFORE=$(grep -A2 'async def step_1' pipeline.py)

# 对话还原：用户说"我现在再添加一个步骤"→"找相似词"→"最后面"
RESULT_APPEND=$(bash "$LIB_DIR/generate-steps.sh" --append "相似词拓展" 2>&1)

if echo "$RESULT_APPEND" | grep -q "追加了 1 个步骤"; then
  pass "--append 输出确认追加 1 个步骤"
else
  fail "--append 应输出追加确认" "追加了 1 个步骤" "$RESULT_APPEND"
fi

# 验证已有代码未被覆盖
STEP1_AFTER=$(grep -A2 'async def step_1' pipeline.py)
if [ "$STEP1_BEFORE" = "$STEP1_AFTER" ]; then
  pass "--append 未覆盖 step_1 的已有代码"
else
  fail "--append 不应修改 step_1" "代码不变" "代码被改了"
fi

# 验证 step_2 也未被覆盖
if grep -q 'selected_asins' pipeline.py; then
  pass "--append 未覆盖 step_2 的已有代码"
else
  fail "--append 不应修改 step_2" "包含 selected_asins" "未找到"
fi

# 验证 step_3 已追加
if grep -q 'async def step_3' pipeline.py; then
  pass "--append 追加了 step_3 方法"
else
  fail "--append 应追加 step_3" "包含 async def step_3" "未找到"
fi

if grep -q '相似词拓展' pipeline.py; then
  pass "--append 的 step_3 包含步骤名称"
else
  fail "--append step_3 应包含步骤名称" "相似词拓展" "未找到"
fi

# 验证 .minus/total-steps 更新
TOTAL=$(cat .minus/total-steps)
if [ "$TOTAL" = "3" ]; then
  pass "--append 后 .minus/total-steps = 3"
else
  fail ".minus/total-steps 应为 3" "3" "$TOTAL"
fi

# 验证 main.tsx 有 3 个 render 条目
RENDER_COUNT=$(grep -c 'render:' frontend/src/main.tsx)
if [ "$RENDER_COUNT" = "3" ]; then
  pass "--append 后 main.tsx 有 3 个 render 条目"
else
  fail "main.tsx 应有 3 个 render" "3" "$RENDER_COUNT"
fi

# ══════════════════════════════════════════════════════════════
echo ""
echo "═══ 问题 9 组合: 添加第 3 步后 is-last + 最后一步跳过维度④ ═══"
# ══════════════════════════════════════════════════════════════

# 核心场景：之前对话中 Agent 在最后一步（步骤 3）仍然问了"确认/继续"
# 根因是 is-last 从 pipeline.py grep（当时只有 2 个 step），返回 NO
# 修复后 is-last 从 .minus/total-steps 读取（值为 3），step 3 = YES

IS_LAST_STEP3=$(bash "$LIB_DIR/step-tracker.sh" is-last 3 2>&1)
if [ "$IS_LAST_STEP3" = "YES" ]; then
  pass "添加第 3 步后：is-last 3 → YES"
else
  fail "is-last 3 应返回 YES" "YES" "$IS_LAST_STEP3"
fi

# 模拟第 3 步的四维度流程
mkdir -p .minus/dev-progress
bash "$LIB_DIR/step-tracker.sh" complete 3 data > /dev/null 2>&1
bash "$LIB_DIR/step-tracker.sh" complete 3 logic > /dev/null 2>&1
bash "$LIB_DIR/step-tracker.sh" complete 3 output > /dev/null 2>&1

# 最后一步：维度③完成后应直接 auto-complete confirm（不问 Creator）
AUTO_RESULT=$(bash "$LIB_DIR/step-tracker.sh" complete 3 confirm auto 2>&1)
if echo "$AUTO_RESULT" | grep -q "✓ 步骤 3 — confirm 已确认"; then
  pass "最后一步（步骤 3）confirm auto 成功——不再问 Creator「确认/继续」"
else
  fail "最后一步 confirm auto 应成功" "步骤 3 confirm 已确认" "$AUTO_RESULT"
fi

CHECK_STEP3=$(bash "$LIB_DIR/step-tracker.sh" check 3 2>&1)
if echo "$CHECK_STEP3" | grep -q "COMPLETE"; then
  pass "步骤 3 四维度全部完成 → COMPLETE"
else
  fail "步骤 3 应 COMPLETE" "COMPLETE" "$CHECK_STEP3"
fi

# 对比：非最后一步（步骤 1）也可以用 auto
bash "$LIB_DIR/step-tracker.sh" reset 1 > /dev/null 2>&1
touch .minus/dev-progress/step_1_data
touch .minus/dev-progress/step_1_logic
touch .minus/dev-progress/step_1_output
AUTO_STEP1=$(bash "$LIB_DIR/step-tracker.sh" complete 1 confirm auto 2>&1 || true)
if echo "$AUTO_STEP1" | grep -q "✓ 步骤 1 — confirm 已确认"; then
  pass "非最后一步（步骤 1）confirm auto 成功——最终用户不用确认"
else
  fail "非最后一步 confirm auto 应成功" "步骤 1 confirm 已确认" "$AUTO_STEP1"
fi

# ══════════════════════════════════════════════════════════════
echo ""
echo "═══ SKILL.md --append 指引验证 ═══"
# ══════════════════════════════════════════════════════════════

if grep -q '\-\-append' "$SKILL_MD"; then
  pass "SKILL.md 包含 --append 使用说明"
else
  fail "SKILL.md 应包含 --append 说明" "包含 --append" "未找到"
fi

if grep -q '禁止.*不带.*--append.*generate-steps' "$SKILL_MD"; then
  pass "SKILL.md 禁止对已有步骤项目使用不带 --append 的 generate-steps.sh"
else
  fail "SKILL.md 应禁止无 --append 全量覆盖" "包含禁止规则" "未找到"
fi

# ── 清理 ──

cd /
rm -rf "$TEST_DIR"

# ── Summary ──

echo ""
echo "════════════════════════════════════════"
read PASSED FAILED < "$RESULTS_FILE"
TOTAL=$((PASSED + FAILED))
echo "修复验证: $TOTAL tests, $PASSED passed, $FAILED failed"

rm -f "$RESULTS_FILE"

if [ "$FAILED" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
  exit 0
fi
