#!/bin/bash
# generate-result-design.sh
# 结果呈现设计（Step 4.3）的门禁 + 引导脚本
# 用法: generate-result-design.sh
#
# 前置条件：所有 pipeline 步骤的四维度必须全部完成
# 输出：数据全景 + 两维度引导（结果摘要 / 下载内容）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACKER_DIR=".minus/dev-progress"

# ── 门禁：所有步骤必须完成 ──

TOTAL_STEPS_FILE=".minus/total-steps"
if [ ! -f "$TOTAL_STEPS_FILE" ]; then
  echo "错误：.minus/total-steps 不存在，步骤骨架尚未生成" >&2
  exit 1
fi
TOTAL_STEPS=$(cat "$TOTAL_STEPS_FILE")

if [ "$TOTAL_STEPS" -lt 1 ]; then
  echo "错误：总步骤数为 0" >&2
  exit 1
fi

ALL_COMPLETE=true
INCOMPLETE_STEPS=""
for i in $(seq 1 "$TOTAL_STEPS"); do
  CHECK_RESULT=$(bash "$SCRIPT_DIR/step-tracker.sh" check "$i" 2>&1) || true
  if ! echo "$CHECK_RESULT" | grep -q "^COMPLETE$"; then
    ALL_COMPLETE=false
    INCOMPLETE_STEPS="${INCOMPLETE_STEPS} 步骤$i"
  fi
done

if [ "$ALL_COMPLETE" = false ]; then
  echo "错误：以下步骤四维度未全部完成，不能进入结果呈现设计：${INCOMPLETE_STEPS}" >&2
  exit 1
fi

# ── 门禁通过 ──
set +e

echo "GATE_PASSED"
echo "TOTAL_STEPS=$TOTAL_STEPS"

# ── 步骤名称 ──

echo ""
for i in $(seq 1 "$TOTAL_STEPS"); do
  NAME_FILE="$TRACKER_DIR/step_${i}_name"
  if [ -f "$NAME_FILE" ]; then
    echo "步骤 $i: $(cat "$NAME_FILE")"
  fi
done

# ── 两维度引导 ──

cat << 'GUIDE'

═══════════════════════════════════════════════════════
  所有步骤开发完成，进入「结果呈现设计」。
  按以下两个维度逐一引导 Creator 确认：
═══════════════════════════════════════════════════════

① 结果摘要
  先读 pipeline.py 中各步骤的 API 调用和 payload，
  结合接口文档（用 get_endpoint_details 查看响应字段），
  用通俗语言向 Creator 描述每步产出了什么数据。
  不要展示代码变量名（如 rows、country），要说明白数据含义。
  示例提问（原样输出，不要改写）：

  「所有步骤开发完成。各步骤产出的数据：」
  「 · 步骤 1：{步骤名} — {用通俗语言描述产出数据，如"相似关键词列表，包含搜索量、竞争度等"}」
  「 · 步骤 2：...」
  「」
  「Skill 运行结束后，结果页顶部会有一段摘要来总结分析结论。」
  「你想怎么定义这段摘要？由大模型自动生成还是你定义模板？要重点突出哪些数据？」

② 下载内容
  Creator 确认摘要后，问：

  「用户可以下载哪些内容？比如 Excel、HTML 报告……」
  「你想提供什么下载格式？」

  如果 Creator 选了 HTML 报告，追问报告具体包含哪些内容：
  「HTML 报告里你想呈现哪些信息？比如哪些数据表格、图表、分析结论……」

注意：Excel 默认用 .xlsx 格式（openpyxl），不要用 CSV，除非 Creator 明确指定 CSV。

两项确认完成后：
  1. 生成结果页面代码（查 SDK 文档了解 CompletionPanel 用法）
  2. 用 skill_update 将结果配置写入后端
  3. 告诉 Creator：开发完成，可以端到端测试了

GUIDE
