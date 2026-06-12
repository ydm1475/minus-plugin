#!/bin/bash
# step-tracker.sh
# 跟踪节点开发四维度的完成状态
# 用法:
#   step-tracker.sh status <step_number>          — 查看某步骤四维度状态
#   step-tracker.sh complete <step_number> <dim> [mode] — 标记某维度完成（logic: deterministic|llm；confirm: auto|interactive）
#   step-tracker.sh check <step_number>            — 检查四维度是否全部完成
#   step-tracker.sh reset <step_number>            — 重置某步骤的状态
#   step-tracker.sh is-last <step_number>            — 判断是否为最后一步（YES/NO）
#   step-tracker.sh list                           — 列出所有步骤状态

set -euo pipefail

TRACKER_DIR=".minus/dev-progress"

ensure_dir() {
  mkdir -p "$TRACKER_DIR" 2>/dev/null
}

DIMS=("data" "logic" "output" "confirm")
DIM_NAMES=("数据需求" "处理逻辑" "输出定义" "用户确认")

# 总步骤数：优先 .minus/total-steps，其次扫 pipeline.py；都没有返回空
total_steps() {
  if [ -f ".minus/total-steps" ]; then
    cat ".minus/total-steps"
  elif [ -f "pipeline.py" ]; then
    # grep -c 无匹配时自己输出 0 且退出码 1，用 || true 防 set -e，不能再 echo 0（会输出两行）
    grep -c 'async def step_[0-9]' "pipeline.py" 2>/dev/null || true
  else
    echo ""
  fi
}

# is_last_step <step> → YES / NO / UNKNOWN
is_last_step() {
  local t
  t=$(total_steps)
  if [ -z "$t" ] || [ "$t" -eq 0 ]; then
    echo "UNKNOWN"
  elif [ "$1" -eq "$t" ]; then
    echo "YES"
  else
    echo "NO"
  fi
}

# 维度完成后输出下一步引导话术（Agent 原样转达「」内的行，每行独立）
emit_next_prompt() {
  local STEP="$1" DIM="$2"
  case "$DIM" in
    data)
      echo "NEXT_DIM=logic"
      echo "── 原样转达给 Creator（每行独立；若 Creator 已表达过处理意图，跳过转达直接标记 logic）──"
      echo "「数据获取确认完毕。」"
      echo ""
      echo "「下一个问题：拿到这些数据之后，怎么处理？」"
      echo ""
      echo "「比如：直接透传原始数据？做聚合/排序？用大模型做分析总结？」"
      ;;
    logic)
      echo "NEXT_DIM=output"
      echo "── 原样转达给 Creator（每行独立；若 Creator 已表达过展示意图，跳过转达直接标记 output）──"
      echo "「处理逻辑确认完毕。」"
      echo ""
      echo "「下一个问题：这一步要展示什么给用户看？」"
      echo ""
      echo "「比如一个数据表格、一段文字摘要、一个评分卡片……」"
      ;;
    output)
      if [ "$(is_last_step "$STEP")" = "YES" ]; then
        # 最后一步没有"用户确认后传给下一步"，硬编码跳过维度④
        touch "$TRACKER_DIR/step_${STEP}_confirm"
        echo "auto" > "$TRACKER_DIR/step_${STEP}_confirm_mode"
        echo "✓ 最后一步无需用户确认设置，已自动标记 confirm (auto)"
        echo "NEXT=GENERATE"
        echo "四维度已全部确认。接下来执行：minus-lib generate-node-code ${STEP}"
      else
        echo "NEXT_DIM=confirm"
        echo "── 原样转达给 Creator（每行独立）──"
        echo "「展示内容确认完毕。」"
        echo ""
        echo "「下一个问题：用户运行到这一步后，需要暂停让用户确认数据再继续吗？」"
        echo ""
        echo "「还是自动往下走？」"
      fi
      ;;
    confirm)
      echo "NEXT=GENERATE"
      echo "四维度已全部确认。接下来执行：minus-lib generate-node-code ${STEP}"
      ;;
  esac
}

case "${1:-}" in
  status)
    STEP="${2:?用法: step-tracker.sh status <step_number>}"
    ensure_dir
    echo "步骤 $STEP 四维度状态："
    for i in "${!DIMS[@]}"; do
      dim="${DIMS[$i]}"
      name="${DIM_NAMES[$i]}"
      if [ -f "$TRACKER_DIR/step_${STEP}_${dim}" ]; then
        if [ "$dim" = "logic" ] && [ -f "$TRACKER_DIR/step_${STEP}_logic_mode" ]; then
          echo "  ✓ ${name}（模式: $(cat "$TRACKER_DIR/step_${STEP}_logic_mode")）"
        else
          echo "  ✓ ${name}"
        fi
      else
        echo "  ○ ${name}（未完成）"
      fi
    done
    ;;

  complete)
    STEP="${2:?用法: step-tracker.sh complete <step_number> <dim>}"
    DIM="${3:?用法: step-tracker.sh complete <step_number> <dim>（dim: data|logic|output|confirm）}"
    ensure_dir

    VALID=false
    for d in "${DIMS[@]}"; do
      if [ "$DIM" = "$d" ]; then VALID=true; fi
    done
    if [ "$VALID" = false ]; then
      echo "错误：无效的维度 '$DIM'，可选：data|logic|output|confirm" >&2
      exit 1
    fi

    # logic 维度保存处理模式。旧调用不带参数时默认 deterministic，保持已有项目兼容。
    if [ "$DIM" = "logic" ]; then
      MODE="${4:-deterministic}"
      if [ "$MODE" != "deterministic" ] && [ "$MODE" != "llm" ]; then
        echo "错误：logic 模式必须是 deterministic 或 llm，收到: '$MODE'" >&2
        exit 1
      fi
    fi

    # confirm 维度必须指定模式（auto 或 interactive）
    if [ "$DIM" = "confirm" ]; then
      MODE="${4:-}"
      if [ -z "$MODE" ]; then
        echo "错误：confirm 维度必须指定模式: step-tracker.sh complete $STEP confirm <auto|interactive>" >&2
        exit 1
      fi
      if [ "$MODE" != "auto" ] && [ "$MODE" != "interactive" ]; then
        echo "错误：confirm 模式必须是 auto 或 interactive，收到: '$MODE'" >&2
        exit 1
      fi
    fi

    # 检查前置维度是否完成
    for i in "${!DIMS[@]}"; do
      if [ "${DIMS[$i]}" = "$DIM" ]; then
        break
      fi
      if [ ! -f "$TRACKER_DIR/step_${STEP}_${DIMS[$i]}" ]; then
        echo "错误：维度 '${DIM_NAMES[$i]}' 还未完成，必须按顺序完成" >&2
        exit 1
      fi
    done

    touch "$TRACKER_DIR/step_${STEP}_${DIM}"
    # logic / confirm 维度保存模式信息
    if [ "$DIM" = "logic" ]; then
      echo "$MODE" > "$TRACKER_DIR/step_${STEP}_logic_mode"
    elif [ "$DIM" = "confirm" ]; then
      echo "$MODE" > "$TRACKER_DIR/step_${STEP}_confirm_mode"
    fi
    echo "✓ 步骤 $STEP — ${DIM} 已确认${MODE:+ (模式: $MODE)}"
    emit_next_prompt "$STEP" "$DIM"
    ;;

  check)
    STEP="${2:?用法: step-tracker.sh check <step_number>}"
    ensure_dir
    ALL_DONE=true
    MISSING=""
    for i in "${!DIMS[@]}"; do
      dim="${DIMS[$i]}"
      name="${DIM_NAMES[$i]}"
      if [ ! -f "$TRACKER_DIR/step_${STEP}_${dim}" ]; then
        ALL_DONE=false
        MISSING="${MISSING} ${name}"
      fi
    done

    if [ "$ALL_DONE" = true ]; then
      echo "COMPLETE"
    else
      echo "INCOMPLETE:${MISSING}"
      exit 1
    fi
    ;;

  reset)
    STEP="${2:?用法: step-tracker.sh reset <step_number>}"
    ensure_dir
    rm -f "$TRACKER_DIR/step_${STEP}_"*
    echo "步骤 $STEP 状态已重置"
    ;;

  is-last)
    STEP="${2:?用法: step-tracker.sh is-last <step_number>}"
    RESULT=$(is_last_step "$STEP")
    if [ "$RESULT" = "UNKNOWN" ]; then
      echo "ERROR: pipeline.py 不存在且 .minus/total-steps 不存在" >&2
      exit 1
    fi
    echo "$RESULT"
    ;;

  list)
    ensure_dir
    if [ ! -d "$TRACKER_DIR" ] || [ -z "$(ls -A "$TRACKER_DIR" 2>/dev/null)" ]; then
      echo "暂无开发进度"
      exit 0
    fi

    # 找出所有步骤编号
    STEPS=$(ls "$TRACKER_DIR" 2>/dev/null | grep -o 'step_[0-9]*' | sort -u | sed 's/step_//')
    for STEP in $STEPS; do
      DONE=0
      TOTAL=${#DIMS[@]}
      for dim in "${DIMS[@]}"; do
        if [ -f "$TRACKER_DIR/step_${STEP}_${dim}" ]; then
          DONE=$((DONE + 1))
        fi
      done
      if [ "$DONE" -eq "$TOTAL" ]; then
        echo "  ✓ 步骤 $STEP — 四维度全部完成"
      else
        echo "  ◐ 步骤 $STEP — $DONE/$TOTAL 维度完成"
      fi
    done
    ;;

  *)
    echo "用法: step-tracker.sh <status|complete|check|reset|is-last|list> [args]"
    exit 1
    ;;
esac
