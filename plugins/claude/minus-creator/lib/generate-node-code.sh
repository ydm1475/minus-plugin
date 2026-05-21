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

# ── 输出代码生成指令 ──

echo "GATE_PASSED"
echo "STEP_NUMBER=$STEP"
echo "CONFIRM_MODE=$CONFIRM_MODE"
echo "IS_LAST=$IS_LAST"

# ── 输出前端代码模板 ──

if [ "$CONFIRM_MODE" = "interactive" ]; then
  cat << 'TEMPLATE'
FRONTEND_TEMPLATE=interactive
# SDK 默认 interactive widget 使用弹框（不写 modal = 弹框，写 modal: false 才 inline）
#
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
