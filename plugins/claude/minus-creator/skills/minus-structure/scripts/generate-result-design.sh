#!/bin/bash
# generate-result-design.sh
# 结果呈现设计（Step 4.3）的门禁 + 引导脚本
# 用法:
#   generate-result-design.sh                      — 门禁 + 两维度引导
#   generate-result-design.sh confirm <summary|download> — 记录某维度已获 Creator 确认
#   generate-result-design.sh check                — 写结果页代码前的门禁（两维度必须全部确认）
#
# 前置条件：所有 pipeline 步骤的四维度必须全部完成，且 Creator 已确认整体测试通过
# 输出：数据全景 + 两维度引导（结果摘要 / 下载内容）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STEP_TRACKER="$SCRIPT_DIR/../../minus-step/scripts/step-tracker.sh"
TRACKER_DIR=".minus/dev-progress"

ACTION="${1:-}"

case "$ACTION" in
  confirm)
    DIM="${2:?用法: generate-result-design.sh confirm <summary|download>}"
    case "$DIM" in
      summary|download) ;;
      *) echo "错误：维度只能是 summary 或 download" >&2; exit 1 ;;
    esac
    mkdir -p "$TRACKER_DIR"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TRACKER_DIR/result_${DIM}_confirmed"
    echo "✓ 结果设计维度 ${DIM} 已确认"
    if [ -f "$TRACKER_DIR/result_summary_confirmed" ] && [ -f "$TRACKER_DIR/result_download_confirmed" ]; then
      echo "NEXT=GENERATE"
      echo "两维度已全部确认，可以生成结果页代码（先执行 generate-result-design.sh check 过门禁）。"
    elif [ "$DIM" = "summary" ]; then
      echo "NEXT_DIM=download"
      echo "── 原样转达给 Creator（每行独立）──"
      echo "「用户可以下载哪些内容？比如 Excel、HTML 报告……」"
      echo "「你想提供什么下载格式？」"
    fi
    exit 0
    ;;
  check)
    MISSING=""
    [ -f "$TRACKER_DIR/result_summary_confirmed" ] || MISSING="${MISSING} 结果摘要"
    [ -f "$TRACKER_DIR/result_download_confirmed" ] || MISSING="${MISSING} 下载内容"
    if [ -n "$MISSING" ]; then
      echo "GATE_FAILED"
      echo "以下维度未经 Creator 确认，不能生成结果页代码：${MISSING}" >&2
      echo "回到对应维度提问，Creator 确认后执行 generate-result-design.sh confirm <summary|download> 记录。" >&2
      exit 1
    fi
    echo "RESULT_DESIGN_COMPLETE"
    exit 0
    ;;
  "") ;;
  *)
    echo "用法: generate-result-design.sh [confirm <summary|download> | check]" >&2
    exit 1
    ;;
esac

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
  CHECK_RESULT=$(bash "$STEP_TRACKER" check "$i" 2>&1) || true
  if ! echo "$CHECK_RESULT" | grep -q "^COMPLETE$"; then
    ALL_COMPLETE=false
    INCOMPLETE_STEPS="${INCOMPLETE_STEPS} 步骤$i"
  fi
done

if [ "$ALL_COMPLETE" = false ]; then
  echo "错误：以下步骤四维度未全部完成，不能进入结果呈现设计：${INCOMPLETE_STEPS}" >&2
  exit 1
fi

# ── 门禁：Creator 必须已确认整体测试通过 ──
# 设计原因：人工测试 612 中 Agent 在最后一步 step-done 后直接串接本脚本，
# Creator 没有任何机会在浏览器验证最后一步。
if [ ! -f "$TRACKER_DIR/final_test_confirmed" ]; then
  echo "GATE_FAILED"
  echo "Creator 尚未确认整体测试通过，不能进入结果呈现设计。" >&2
  echo "补救：转达测试邀请（见 update-progress step-done 的输出话术），等 Creator 在预览页完整跑一遍并确认后，" >&2
  echo "执行 minus-lib update-progress confirm-test，再重跑本脚本。" >&2
  exit 1
fi

# ── 门禁通过 ──
set +e

# 开启新一轮结果设计：清掉上一轮的维度确认标记，防止重设计时 check 凭旧标记放行
rm -f "$TRACKER_DIR/result_summary_confirmed" "$TRACKER_DIR/result_download_confirmed"

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

⛔ 回答归属规则：Creator 的回复只有在你已经原样输出某维度的问题之后，才能算作
   该维度的回答。Creator 主动谈论的若是某个步骤的展示样式（卡片、图表、颜色、
   布局等），那是 minus-step 的修改需求——先处理它，再回到本流程重新提问当前维度。
   不确定 Creator 在回答哪个问题时，先复述你的理解请 Creator 确认，禁止抢答。

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
  「Skill 运行结束后，结果页底部会有一段摘要来总结分析结论。」
  「这段摘要由大模型在运行时基于实际数据自动生成，还是你来定义模板？」

  如果 Creator 选择大模型自动生成，⛔ 禁止直接进入下载内容。必须先完成一次动态确认：
  1. 根据各步骤实际产出的数据、Creator 已表达的业务目标和上下文，动态生成需要确认的问题。⛔ 禁止照搬固定问题清单。
  2. Creator 回答后，用通俗语言归纳大模型摘要将重点包含什么、忽略什么、采用什么表达方式，并询问「这样可以吗？」
  3. 只有 Creator 明确确认后，才能继续进入下载内容。

  示例（内容必须按当前 Skill 动态生成，不要照抄）：
  「好的。结合这个 Skill 的实际数据，你希望摘要重点关注哪些内容？」
  「明白了。摘要会重点包含：{根据 Creator 回答动态归纳的内容}。这样可以吗？」

  Creator 确认摘要后，执行（脚本会输出维度 ② 的提问话术，原样转达）：
  minus-lib generate-result-design confirm summary

② 下载内容
  维度 ① 确认完成后，问：

  「用户可以下载哪些内容？比如 Excel、HTML 报告……」
  「你想提供什么下载格式？」

  如果 Creator 选了 Excel，追问导出数据内容：
  「默认会将最后一步的数据导出为 Excel（包含所有列）。」
  「这样可以吗？还是你想自定义每个 Sheet 放哪些步骤的数据、包含哪些列？」

  如果 Creator 选了 HTML 报告，追问报告具体包含哪些内容：
  「HTML 报告里你想呈现哪些信息？比如哪些数据表格、图表、分析结论……」

注意：Excel 默认用 .xlsx 格式（openpyxl），不要用 CSV，除非 Creator 明确指定 CSV。
⛔ 禁止不问 Creator 就自行决定 Excel 包含哪些数据。必须先确认再生成代码。

文件名命名规范：{Skill名称}-{country}-{主要输入}-{时间戳}.{后缀}
  示例：竞品分析-US-B01NBNDC1T-2026-05-27 11点09分.xlsx
  时间戳格式固定为 datetime.now().strftime("%Y-%m-%d %H点%M分")
  Skill 名称从 skill.json 的 name 字段取，不要硬编码。
  主要输入根据业务逻辑决定（如 ASIN、关键词），由 Creator 确认的 entry_params 中的关键字段。

Creator 确认下载内容后，执行：
  minus-lib generate-result-design confirm download

两项确认完成后：
  0. 执行写代码门禁（输出 RESULT_DESIGN_COMPLETE 才能动代码）：
     minus-lib generate-result-design check
  1. 生成结果页面代码（查 SDK 文档了解 CompletionPanel 用法）
  2. 执行 Python 依赖一致性检查：minus-lib check-python-deps
     - 如果输出 DEPENDENCIES_OK → 继续
     - 如果报缺失依赖 → Agent 必须自己更新 pyproject.toml，执行 uv pip install -e .，然后重新检查；通过前不要让 Creator 测试
     - 禁止把依赖修复交给 Creator 手动处理
     - 禁止只对 .venv 临时安装某个包而不更新 pyproject.toml
     - 禁止用系统 python3 验证依赖，必须使用项目 venv 的 python（Unix：.venv/bin/python；Windows：.venv/Scripts/python.exe）
  3. 用 skill_update 将结果配置写入后端
  4. 告诉 Creator：开发完成，可以端到端测试了

GUIDE
