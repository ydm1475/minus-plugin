#!/bin/bash
# generate-node-code.sh
# 在四维度全部确认后，一次性生成单个节点的代码
# 用法: generate-node-code.sh <step_number>
#
# 前置条件：step-tracker.sh check <step_number> 必须返回 COMPLETE
# 生成内容：根据 confirm_mode 决定前端交互方式
#
# 此脚本只做「门禁检查 + 读取 confirm_mode」，
# 实际代码由 Agent 在门禁通过后编写（脚本输出指导信息）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACKER_DIR=".minus/dev-progress"

STEP="${1:?用法: generate-node-code.sh <step_number>}"

# ── 门禁：四维度必须全部完成 ──

CHECK_RESULT=$(bash "$SCRIPT_DIR/step-tracker.sh" check "$STEP" 2>&1) || true
if ! echo "$CHECK_RESULT" | grep -q "^COMPLETE$"; then
  echo "错误：步骤 $STEP 四维度未全部完成，不能生成代码" >&2
  echo "$CHECK_RESULT" >&2
  exit 1
fi

# ── 读取 confirm_mode ──

MODE_FILE="$TRACKER_DIR/step_${STEP}_confirm_mode"
if [ -f "$MODE_FILE" ]; then
  CONFIRM_MODE=$(cat "$MODE_FILE")
else
  CONFIRM_MODE="auto"
fi

# ── 判断是否最后一步 ──

IS_LAST=$(bash "$SCRIPT_DIR/step-tracker.sh" is-last "$STEP" 2>&1)

# ── 门禁通过，后续全部是信息性输出，不应因解析失败而中断脚本 ──
set +e

echo "GATE_PASSED"
echo "STEP_NUMBER=$STEP"
echo "CONFIRM_MODE=$CONFIRM_MODE"
echo "IS_LAST=$IS_LAST"

# ── 输出前端代码模板 ──

if [ "$CONFIRM_MODE" = "interactive" ]; then
  cat << 'TEMPLATE'
FRONTEND_TEMPLATE=interactive
# defineWidgetStep<SelectableTableProps, SelectableRow[]>({
#   widget: SelectableTableWidget,
#   props: ({ data }) => ({
#     dataSource: (data.xxx as SelectableRow[]) ?? [],
#     columns: [...],
#   }),
#   interactiveProps: () => ({
#     primaryAction: { label: t('...confirm...') },
#   }),
#   confirmedKey: 'selectedXxx',
# }),
#
# 后端必须使用 StepOutcome.input_required(payload={...})
TEMPLATE
elif [ "$CONFIRM_MODE" = "auto" ]; then
  cat << 'TEMPLATE'
FRONTEND_TEMPLATE=readonly
# 前端使用 readonly 模式（无 interactiveProps）：
#
# defineWidgetStep<SelectableTableProps, SelectableRow[]>({
#   widget: SelectableTableWidget,
#   props: ({ data }) => ({
#     dataSource: (data.xxx as SelectableRow[]) ?? [],
#     columns: [...],
#   }),
#   confirmedKey: 'xxx',
# }),
#
# 后端使用 StepOutcome.complete(payload={...})
TEMPLATE
fi

# ── 数据契约：各步骤的 payload 字段 ──

echo ""
echo "═══ 数据契约（前后步骤联动检查）═══"

if [ -f "pipeline.py" ]; then
  # 提取每个步骤的 payload 字段
  node -e "
const fs = require('fs');
const code = fs.readFileSync('pipeline.py', 'utf8');
const stepPattern = /async def step_(\d+)\([\s\S]*?(?=async def step_|\Z)/g;
const steps = [...code.matchAll(/async def step_(\d+)\([^)]*\)[\s\S]*?(?=\n    async def step_|\$)/gm)];

// 提取 entry_params 使用的字段
const entryParams = [...code.matchAll(/ctx\.entry_params\.get\(['\"](\w+)['\"]/g)].map(m => m[1]);
if (entryParams.length > 0) {
  console.log('输入字段(entry_params): ' + [...new Set(entryParams)].join(', '));
}

// 提取每个步骤的 payload 输出字段
const payloads = [...code.matchAll(/step_(\d+)[\s\S]*?payload=\{([^}]*)\}/g)];
for (const m of payloads) {
  const stepNum = m[1];
  const fields = [...m[2].matchAll(/['\"](\w+)['\"]\s*:/g)].map(f => f[1]);
  if (fields.length > 0) {
    console.log('步骤 ' + stepNum + ' 输出: { ' + fields.join(', ') + ' }');
  }
}

// 提取 previous_payload / previous_outputs 的引用
const prevRefs = [...code.matchAll(/ctx\.(previous_payload|previous_outputs)[\s\S]*?\.get\(['\"]?(\w+)['\"]?/g)];
for (const m of prevRefs) {
  console.log('跨步骤引用: ctx.' + m[1] + ' → ' + m[2]);
}
" 2>/dev/null || echo "(pipeline.py 解析失败，请手动检查数据契约)"

  echo ""
  echo "⚠️ 生成代码后，必须检查："
  echo "  1. 当前步骤的 payload 字段名 → 下一步是否正确读取"
  echo "  2. 上一步的 payload 字段名 → 当前步骤是否正确引用"
  echo "  3. 多值输入字段（如 keywords）→ 是否做了 split 遍历"
fi

# ── SDK PipelineContext 可用属性 ──

echo ""
echo "═══ SDK PipelineContext 可用属性 ═══"

CTX_FILE=$(find .venv -path "*/minus_ai_sdk/pipeline/context.py" 2>/dev/null | head -1)
if [ -n "$CTX_FILE" ] && [ -f "$CTX_FILE" ]; then
  # 提取类属性和方法签名
  node -e "
const fs = require('fs');
const code = fs.readFileSync('$CTX_FILE', 'utf8');
const attrs = [...code.matchAll(/^\s{4}(\w+)\s*[:=]/gm)].map(m => m[1]).filter(a => !a.startsWith('_'));
const methods = [...code.matchAll(/^\s{4}(?:async )?def (\w+)\(/gm)].map(m => m[1]).filter(m => !m.startsWith('_'));
const props = [...code.matchAll(/@property[\s\S]*?def (\w+)\(/gm)].map(m => m[1]);
if (props.length > 0) console.log('属性: ' + props.join(', '));
if (methods.length > 0) console.log('方法: ' + methods.join(', '));
" 2>/dev/null || echo "(SDK context.py 解析失败)"
else
  echo "(未找到 SDK PipelineContext 源码，请先 uv pip install -e .)"
fi

# ── 最后一步：代码生成完毕后触发结果呈现设计 ──

if [ "$IS_LAST" = "YES" ]; then
  cat << 'RESULT_DESIGN'

═══════════════════════════════════════════════════════
  ⛔ 这是最后一步。代码生成完毕后，必须进入「结果呈现设计」。
  不要直接告诉 Creator "开发完成"，还有最后一个环节。
═══════════════════════════════════════════════════════

按 SKILL.md 的「结果呈现设计（Step 4.3）」两维度引导 Creator：
① 结果摘要 — 展示各步骤数据全景，问 Creator 摘要风格
② 下载内容 — 问需要哪些可下载的文件

RESULT_DESIGN
fi
