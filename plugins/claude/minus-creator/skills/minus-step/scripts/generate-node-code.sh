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
只渲染 Creator 在输出定义阶段明确确认的展示内容。
TEMPLATE
elif [ "$CONFIRM_MODE" = "auto" ]; then
  cat << 'TEMPLATE'
FRONTEND_TEMPLATE=display
纯展示步骤（auto-complete）使用普通 render 函数。
后端使用 StepOutcome.complete(payload={...})
只渲染 Creator 在输出定义阶段明确确认的展示内容。
Creator 未明确要求概览、摘要、统计卡片或顶部汇总时，禁止生成这类 UI。
TEMPLATE
fi

# ── 前端开发手册（按本步特征列出必读子文档，对齐后端 SDK_DOC_PATH 模式）──
# 设计原因：劝告式提醒（"重新查阅 CLAUDE.md 索引"）已实测无效——判断留给 Agent 的每一步
# 都是逃逸口。这里把"读哪份"的判断收回脚本，只给 Agent 留"执行 curl"一个动作。

DOC_BASE=$(grep -oE "https?://[a-zA-Z0-9.:/_-]+/runtime/frontend-guide/doc\.md" CLAUDE.md 2>/dev/null | head -1 | sed 's|/doc\.md$||')
echo ""
if [ -n "$DOC_BASE" ]; then
  FRONTEND_DOCS="$DOC_BASE/frontend/contract.md"
  if [ "$LOGIC_MODE" = "llm" ]; then
    FRONTEND_DOCS="$FRONTEND_DOCS $DOC_BASE/frontend/step-summary.md"
  fi
  DOC_COUNT=$(echo "$FRONTEND_DOCS" | wc -w | tr -d ' ')
  echo "FRONTEND_DOC_URLS=$DOC_COUNT"
  echo "⛔ 写前端代码前必须通读以下文档，禁止凭记忆写组件 props、确认机制或摘要时序。"
  echo "   某份文档本会话已 curl 过且全文仍在上下文中（未被压缩成摘要）→ 可跳过该条；"
  echo "   只记得结论、原文已不在 → 必须重新 curl。拿不准 → 重新 curl。"
  for DOC_URL in $FRONTEND_DOCS; do
    echo "  curl -sSL '$DOC_URL'"
  done
else
  echo "FRONTEND_DOC_URLS=0"
  echo "⚠️ 未能从项目 CLAUDE.md 解析平台文档地址。写前端代码前按 CLAUDE.md「开发手册（索引）」"
  echo "   的 curl 命令取索引，再按本步需求取对应子文档；文档不可达时停止写前端代码并告知 Creator。"
fi

cat << 'WIDGET_TRAP'

⚠️ 高频陷阱——步骤摘要会出现两份：
  后端 payload 带 summary 字段时，框架自动在步骤卡片上展示该摘要。
  ⛔ 禁止在 StepConfig.render 里再手动渲染步骤摘要，否则同一段摘要出现两份。
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