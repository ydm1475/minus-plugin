#!/bin/bash
# generate-steps.sh
# 根据步骤列表自动生成 pipeline.py 和 main.tsx 的骨架代码
# 用法: generate-steps.sh [--input-type keyword|asin|file|default] "步骤1名称" ...
#       generate-steps.sh --append "新步骤名称" ...
# 必须在 Skill 项目根目录下执行
#
# ⚠ 骨架占位标记「# TODO: 实现「」被 update-progress.sh（step-done 门禁）和
#   progress-check.sh（自愈重建）依赖，修改此模板需同步两处。

set -euo pipefail

GS_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_PROGRESS="$GS_SCRIPT_DIR/../../../scripts/update-progress.sh"

APPEND_MODE=false
INPUT_TYPE=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --append) APPEND_MODE=true; shift ;;
    --input-type) INPUT_TYPE="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [ $# -eq 0 ]; then
  echo "用法: generate-steps.sh [--input-type keyword|asin|file|default] \"步骤1名称\" ..." >&2
  echo "       generate-steps.sh --append \"新步骤名称\" ..." >&2
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

# ── --append 模式：在已有代码后追加新步骤 ──
if [ "$APPEND_MODE" = true ]; then
  if [ -f ".minus/total-steps" ]; then
    CURRENT_STEPS=$(cat .minus/total-steps)
  else
    CURRENT_STEPS=$(grep -c 'async def step_[0-9]' pipeline.py 2>/dev/null || echo 0)
  fi

  NEW_STEP_NAMES=("$@")
  NEW_STEP_COUNT=${#NEW_STEP_NAMES[@]}
  NEW_TOTAL=$((CURRENT_STEPS + NEW_STEP_COUNT))

  # 追加 pipeline.py（在文件末尾、class 内部添加新方法）
  for i in $(seq 1 "$NEW_STEP_COUNT"); do
    idx=$((i - 1))
    step_num=$((CURRENT_STEPS + i))
    name="${NEW_STEP_NAMES[$idx]}"
    {
      echo ""
      echo "    async def step_${step_num}(self, ctx: PipelineContext) -> StepOutcome:"
      echo "        # TODO: 实现「${name}」的逻辑"
      echo "        return StepOutcome.complete(payload={\"text\": \"${name}完成\"})"
    } >> pipeline.py
  done

  echo "✓ pipeline.py 追加了 ${NEW_STEP_COUNT} 个步骤（step_$((CURRENT_STEPS + 1)) ~ step_${NEW_TOTAL}）"

  # 追加 main.tsx buildSteps
  MAIN_TSX="frontend/src/main.tsx"
  if [ -f "$MAIN_TSX" ]; then
    NEW_ENTRIES=""
    for i in $(seq 1 "$NEW_STEP_COUNT"); do
      idx=$((i - 1))
      name="${NEW_STEP_NAMES[$idx]}"
      NEW_ENTRIES="${NEW_ENTRIES}    {\n      render: ({ data }) => (\n        <div style={{ marginTop: 24, padding: '32px 24px', borderRadius: 12, background: 'var(--minus-step-bg, #f9fafb)', border: '1px solid var(--minus-step-border, #e5e7eb)', textAlign: 'center', fontSize: 18, fontWeight: 600 }}>\n          {(data.text as string) ?? '${name}'}\n        </div>\n      ),\n    },\n"
    done

    node -e "
const fs = require('fs');
let code = fs.readFileSync('${MAIN_TSX}', 'utf8');
// 找到 buildSteps 函数的 'return [' 位置
const fnStart = code.indexOf('function buildSteps');
if (fnStart === -1) { console.error('⚠ 未找到 buildSteps 函数，跳过'); process.exit(0); }
const returnIdx = code.indexOf('return [', fnStart);
if (returnIdx === -1) { console.error('⚠ 未找到 return [，跳过'); process.exit(0); }
// 从 'return [' 开始，用括号计数找到匹配的 ']'
let depth = 0, closeIdx = -1;
for (let i = code.indexOf('[', returnIdx); i < code.length; i++) {
  if (code[i] === '[') depth++;
  else if (code[i] === ']') { depth--; if (depth === 0) { closeIdx = i; break; } }
}
if (closeIdx === -1) { console.error('⚠ 未找到匹配的 ]，跳过'); process.exit(0); }
const newEntries = \`${NEW_ENTRIES}\`;
code = code.slice(0, closeIdx) + newEntries + code.slice(closeIdx);
fs.writeFileSync('${MAIN_TSX}', code);
console.log('✓ ${MAIN_TSX} 追加了 ${NEW_STEP_COUNT} 个步骤渲染');
" 2>&1
  fi

  echo "$NEW_TOTAL" > .minus/total-steps
  echo "✓ .minus/total-steps 更新为 ${NEW_TOTAL}"

  # 进度搭载写入：追加的新步骤记入 progress.json（pending）
  bash "$UPDATE_PROGRESS" append-steps "${NEW_STEP_NAMES[@]}"
  exit 0
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

# ── 记录总步骤数（供 step-tracker.sh is-last 使用）──
echo "$STEP_COUNT" > .minus/total-steps

# ── 进度搭载写入：steps 列表 + phase=developing（Agent 不再手写 progress.json）──
bash "$UPDATE_PROGRESS" design-done "${STEP_NAMES[@]}"

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

# ── 根据输入类型更新 renderHistoryItem ──
if [ "$APPEND_MODE" = false ] && [ -n "$INPUT_TYPE" ]; then
  case "$INPUT_TYPE" in
    keyword) LABEL_FIELD="keywords" ;;
    asin)    LABEL_FIELD="asins" ;;
    file)    LABEL_FIELD="fileName" ;;
    *)       LABEL_FIELD="text" ;;
  esac

  node -e "
const fs = require('fs');
let code = fs.readFileSync('${MAIN_TSX}', 'utf8');
const pattern = /label:\s*inp\?\\.\w+\s*\?\?\s*'—'/;
if (pattern.test(code)) {
  code = code.replace(pattern, \"label: inp?.${LABEL_FIELD} ?? '—'\");
  fs.writeFileSync('${MAIN_TSX}', code);
  console.log('✓ renderHistoryItem 已更新为 inp?.${LABEL_FIELD}');
} else {
  console.log('⚠ 未找到 renderHistoryItem label 模式，跳过');
}
" 2>&1
fi

# ── 输出 node-dev.md 指令（硬编码注入，不依赖 agent 自觉去 Read）──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_DEV="$SCRIPT_DIR/../../minus-step/node-dev.md"
if [ -f "$NODE_DEV" ]; then
  echo "═══════════════════════════════════════════════════════"
  echo "  步骤骨架已生成。逐节点开发必须严格按以下流程执行："
  echo "═══════════════════════════════════════════════════════"
  echo ""
  # 去掉 frontmatter，只输出正文
  sed '1,/^---$/{ /^---$/!d; /^---$/d; }; /^---$/,/^---$/d' "$NODE_DEV"
fi
