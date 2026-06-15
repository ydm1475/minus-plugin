#!/bin/bash
# generate-node-code.sh
# 在四维度全部确认后，一次性生成单个节点的代码
# 用法: generate-node-code.sh <step_number>
#
# 前置条件：step-tracker.sh check <step_number> 必须返回 COMPLETE
# 生成内容：根据 logic_mode 决定处理方式，根据 confirm_mode 决定前端交互方式
#
# 此脚本只做「门禁检查 + 读取 logic_mode / confirm_mode」，
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

# ── 读取 logic_mode / confirm_mode ──

LOGIC_MODE_FILE="$TRACKER_DIR/step_${STEP}_logic_mode"
if [ -f "$LOGIC_MODE_FILE" ]; then
  LOGIC_MODE=$(cat "$LOGIC_MODE_FILE")
else
  # 兼容旧项目：历史节点只有 step_N_logic 完成标记，没有细分模式。
  LOGIC_MODE="deterministic"
fi

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
echo "LOGIC_MODE=$LOGIC_MODE"
echo "CONFIRM_MODE=$CONFIRM_MODE"
echo "IS_LAST=$IS_LAST"
echo ""
echo "⛔ 代码写完并通过依赖检查后，必须执行：minus-lib update-progress step-done $STEP"
echo "   （自动标记本步骤完成并推进进度；最后一步会自动进入待测试阶段）"

# ── logic_mode 与代码一致性检查 ──

if [ "$LOGIC_MODE" = "deterministic" ] && [ -f "pipeline.py" ]; then
  # 检查该步骤函数体里是否已有 LLM 调用
  STEP_HAS_LLM=$(python3 -c "
import re, sys
code = open('pipeline.py').read()
m = re.search(r'async def step_${STEP}\b.*?(?=\n    async def step_|\Z)', code, re.DOTALL)
if m and re.search(r'ctx\.llm\.', m.group(0)):
    print('YES')
else:
    print('NO')
" 2>/dev/null || echo "NO")
  if [ "$STEP_HAS_LLM" = "YES" ]; then
    echo "⛔ 步骤 $STEP 的 logic_mode 是 deterministic，但代码中已有 ctx.llm 调用。" >&2
    echo "   必须先重过 logic 维度：minus-lib step-tracker ask $STEP logic → complete $STEP logic llm" >&2
    echo "   然后重新执行本门禁。" >&2
    exit 1
  fi
fi

# ── LLM 处理约束 ──

if [ "$LOGIC_MODE" = "llm" ]; then
  cat << 'LLM_GUIDANCE'
LLM_REQUIRED=YES
必须读取项目后端 SDK 开发手册，使用 SDK 内置 LLM 能力。
禁止自行拼接第三方模型调用，禁止猜测 SDK 方法名。
LLM_GUIDANCE
else
  echo "LLM_REQUIRED=NO"
fi

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
#
# 如果本步骤摘要依赖用户最终确认的数据，查前端 SDK 开发手册（frontend-guide.md）
# 使用“确认后隐藏 finalize 摘要”这条平台能力。Plugin 只负责触发条件，不在这里重复定义 UI 契约。
# 禁止在确认前提前生成摘要，禁止只在前端临时拼接摘要，禁止修改 Python SDK。
TEMPLATE
elif [ "$CONFIRM_MODE" = "auto" ]; then
  cat << 'TEMPLATE'
FRONTEND_TEMPLATE=display
# 纯展示步骤（auto-complete）使用普通 render 函数：
#
# {
#   render: ({ data }) => (
#     <组件 props={...} />
#   ),
# },
#
# 只渲染 Creator 在输出定义阶段明确确认的展示内容。
# 接口返回字段、计算中间值、排序依据、调试信息，都不是默认展示内容。
# Creator 未明确要求概览、摘要、统计卡片或顶部汇总时，禁止生成这类 UI。
#
# 查 SDK 文档了解可用的 display widget。
# 后端使用 StepOutcome.complete(payload={...})
TEMPLATE
fi

# ── 前端组件源码查阅提醒 ──

cat << 'WIDGET_DOC'

═══ @minus/* 能力：必须先读源码注释 ═══
使用 @minus/widget-framework 或 @minus/platform-widgets 的任何能力前，
先读对应源码 interface + JSDoc：
  widget-framework → platform 仓库 packages/widget-framework/src/
  platform-widgets → platform 仓库 packages/platform-widgets/src/
⛔ 禁止凭记忆写 props 或假设框架行为。

⚠️ 高频陷阱：data.summary 由 widget-framework 的 Timeline 自动渲染。
  后端 payload 里有 summary 字段时，框架会自动展示。
  ⛔ 禁止在前端 render 里再手动渲染 data.summary，否则摘要出现两份。
WIDGET_DOC

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
  echo "  4. Creator 已确认展示的每个字段 → 是否都有真实接口或计算来源"
  echo "  5. 是否存在尚未接入真实数据来源，却用 \"-\" / \"—\" / \"N/A\" 伪装完成的字段"
  echo "  6. 切换接口后 → 是否重新核对全部展示字段"
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

# ── 最后一步：提示调用 generate-result-design.sh ──

if [ "$IS_LAST" = "YES" ]; then
  cat << RESULT_DESIGN

═══════════════════════════════════════════════════════
  ⛔ 这是最后一步。代码生成完毕后，必须进入「结果呈现设计」。
  不要直接告诉 Creator "开发完成"，还有最后一个环节。

  代码写完后立即执行：
  bash "$SCRIPT_DIR/../../minus-structure/scripts/generate-result-design.sh"
═══════════════════════════════════════════════════════

RESULT_DESIGN
fi
