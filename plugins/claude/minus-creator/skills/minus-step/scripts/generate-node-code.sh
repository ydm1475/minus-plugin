#!/bin/bash
# generate-node-code.sh
# 在四维度全部确认后，一次性生成单个节点的代码
# 用法: generate-node-code.sh <step_number> <logic_mode> <confirm_mode>
#
# 生成内容：根据 logic_mode 决定处理方式，根据 confirm_mode 决定前端交互方式
# 实际代码由 Agent 在门禁通过后编写（脚本输出指导信息）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

STEP="${1:?用法: generate-node-code.sh <step_number> <logic_mode> <confirm_mode>}"
LOGIC_MODE="${2:?用法: generate-node-code.sh <step_number> <logic_mode> <confirm_mode>}"
CONFIRM_MODE="${3:?用法: generate-node-code.sh <step_number> <logic_mode> <confirm_mode>}"

case "$LOGIC_MODE" in
  deterministic|llm) ;;
  *) echo "错误：logic_mode 必须是 deterministic 或 llm，收到: '$LOGIC_MODE'" >&2; exit 1 ;;
esac
case "$CONFIRM_MODE" in
  auto|interactive) ;;
  *) echo "错误：confirm_mode 必须是 auto 或 interactive，收到: '$CONFIRM_MODE'" >&2; exit 1 ;;
esac

# ── 判断是否最后一步 ──

if [ -f ".minus/total-steps" ]; then
  TOTAL=$(cat ".minus/total-steps")
elif [ -f "pipeline.py" ]; then
  TOTAL=$(grep -c 'async def step_[0-9]' pipeline.py 2>/dev/null || echo 0)
else
  TOTAL=0
fi
if [ "$TOTAL" -gt 0 ] && [ "$STEP" -ge "$TOTAL" ]; then
  IS_LAST="YES"
elif [ "$TOTAL" -gt 0 ]; then
  IS_LAST="NO"
else
  echo "ERROR: pipeline.py 不存在且 .minus/total-steps 不存在" >&2
  exit 1
fi

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
    echo "   重新确认处理逻辑为 LLM 模式后，执行：minus-lib generate-node-code $STEP llm $CONFIRM_MODE" >&2
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
后端使用 StepOutcome.input_required(payload={...})
前端代码模式见前端 SDK 手册（frontend-guide.md）「通用确认机制：defineWidgetStep」章节。
只渲染 Creator 在输出定义阶段明确确认的展示内容。
TEMPLATE
elif [ "$CONFIRM_MODE" = "auto" ]; then
  cat << 'TEMPLATE'
FRONTEND_TEMPLATE=display
纯展示步骤（auto-complete）使用普通 render 函数。
后端使用 StepOutcome.complete(payload={...})
前端代码模式见前端 SDK 手册（frontend-guide.md）。
只渲染 Creator 在输出定义阶段明确确认的展示内容。
Creator 未明确要求概览、摘要、统计卡片或顶部汇总时，禁止生成这类 UI。
TEMPLATE
fi

cat << 'WIDGET_TRAP'

⚠️ 高频陷阱——步骤摘要会出现两份：
  后端 payload 带 summary 字段时，框架自动在步骤卡片上展示该摘要。
  ⛔ 禁止在 StepConfig.render 里再手动渲染步骤摘要，否则同一段摘要出现两份。
  详见前端 SDK 手册（frontend-guide.md）的「用户确认后的步骤摘要」章节。
WIDGET_TRAP

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

# ── SDK 后端开发手册 ──

echo ""
echo "═══ SDK 后端开发手册 ═══"

SDK_README=$(find .venv -path "*/minus_ai_sdk/README.md" 2>/dev/null | head -1)
if [ -n "$SDK_README" ] && [ -f "$SDK_README" ]; then
  echo "⛔ 写后端代码前必须阅读以下 SDK 文档，禁止凭记忆写 ctx.* 调用："
  echo "SDK_DOC_PATH=$SDK_README"
else
  # SDK 尚未附带 README，要求 agent 直接读源码
  CTX_FILE=$(find .venv -path "*/minus_ai_sdk/pipeline/context.py" 2>/dev/null | head -1)
  SIF_FILE=$(find .venv -path "*/minus_ai_sdk/sif/client.py" 2>/dev/null | head -1)
  if [ -n "$CTX_FILE" ] && [ -f "$CTX_FILE" ]; then
    echo "⛔ SDK 未附带开发文档。写后端代码前必须 Read 以下源码，确认 ctx.* 属性名和方法签名："
    echo "  1. Read $CTX_FILE — PipelineContext 属性（entry_params / last_user_input / previous_outputs 等）"
    [ -n "$SIF_FILE" ] && [ -f "$SIF_FILE" ] && \
    echo "  2. Read $SIF_FILE — ctx.sif.request() 的参数签名"
    echo "禁止凭记忆猜属性名或参数名。"
  else
    echo "⛔ 未找到 SDK 源码（.venv/minus_ai_sdk/），请先 uv pip install -e . 安装 SDK"
  fi
fi