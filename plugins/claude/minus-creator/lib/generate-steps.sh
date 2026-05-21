#!/bin/bash
# generate-steps.sh
# 根据步骤列表自动生成 pipeline.py 和 main.tsx 的骨架代码
# 用法: generate-steps.sh "步骤1名称" "步骤2名称" "步骤3名称" ...
# 必须在 Skill 项目根目录下执行

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "用法: generate-steps.sh \"步骤1名称\" \"步骤2名称\" ..." >&2
  exit 1
fi

if [ ! -f ".minus/skill.json" ]; then
  echo "错误：当前目录不是 Minus Skill 项目（未找到 .minus/skill.json）" >&2
  exit 1
fi

if [ ! -f "pipeline.py" ]; then
  echo "错误：未找到 pipeline.py" >&2
  exit 1
fi

STEP_COUNT=$#
STEP_NAMES=("$@")

# ── 读取 pipeline.py 的 class 名 ──
CLASS_NAME=$(grep 'class.*Pipeline' pipeline.py 2>/dev/null | sed 's/class \([A-Za-z0-9_]*\)(Pipeline).*/\1/' | head -1)
if [ -z "$CLASS_NAME" ]; then
  CLASS_NAME="SkillPipeline"
fi

# ── 生成 pipeline.py ──
{
  echo "from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome"
  echo ""
  echo ""
  echo "class ${CLASS_NAME}(Pipeline):"

  for i in $(seq 1 $STEP_COUNT); do
    idx=$((i - 1))
    name="${STEP_NAMES[$idx]}"
    echo ""
    echo "    async def step_${i}(self, ctx: PipelineContext) -> StepOutcome:"
    echo "        # TODO: 实现「${name}」的逻辑"
    echo "        return StepOutcome.complete(payload={\"text\": \"${name}完成\"})"
  done
} > pipeline.py

echo "✓ pipeline.py 已生成 ${STEP_COUNT} 个步骤"

# ── 生成 main.tsx 的 buildSteps 部分 ──
MAIN_TSX="frontend/src/main.tsx"
if [ ! -f "$MAIN_TSX" ]; then
  echo "⚠ 未找到 ${MAIN_TSX}，跳过前端更新" >&2
  exit 0
fi

# 生成步骤渲染配置
STEPS_CODE=""
for i in $(seq 1 $STEP_COUNT); do
  idx=$((i - 1))
  name="${STEP_NAMES[$idx]}"
  if [ $i -gt 1 ]; then
    STEPS_CODE="${STEPS_CODE}
    "
  fi
  STEPS_CODE="${STEPS_CODE}{
      render: ({ data }) => (
        <div style={{ marginTop: 24, padding: '32px 24px', borderRadius: 12, background: 'var(--minus-step-bg, #f9fafb)', border: '1px solid var(--minus-step-border, #e5e7eb)', textAlign: 'center', fontSize: 18, fontWeight: 600 }}>
          {(data.text as string) ?? '${name}'}
        </div>
      ),
    },"
done

# 用 node 替换 buildSteps 函数体
node -e "
const fs = require('fs');
let code = fs.readFileSync('${MAIN_TSX}', 'utf8');
const pattern = /(function buildSteps\([^)]*\)[^{]*\{[\s\S]*?return\s*\[)([\s\S]*?)(\];\s*\n\})/m;
const match = code.match(pattern);
if (!match) {
  console.error('⚠ 未找到 buildSteps 函数，跳过');
  process.exit(0);
}
const newSteps = \`
    ${STEPS_CODE}
  \`;
code = code.replace(pattern, '\$1' + newSteps + '\$3');
fs.writeFileSync('${MAIN_TSX}', code);
console.log('✓ ${MAIN_TSX} 已更新 ${STEP_COUNT} 个步骤渲染');
" 2>&1
