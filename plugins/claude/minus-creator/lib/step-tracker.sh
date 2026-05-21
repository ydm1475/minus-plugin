#!/bin/bash
# step-tracker.sh
# 跟踪节点开发四维度的完成状态
# 用法:
#   step-tracker.sh status <step_number>          — 查看某步骤四维度状态
#   step-tracker.sh complete <step_number> <dim>   — 标记某维度完成（dim: data|logic|output|confirm）
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

case "${1:-}" in
  status)
    STEP="${2:?用法: step-tracker.sh status <step_number>}"
    ensure_dir
    echo "步骤 $STEP 四维度状态："
    for i in "${!DIMS[@]}"; do
      dim="${DIMS[$i]}"
      name="${DIM_NAMES[$i]}"
      if [ -f "$TRACKER_DIR/step_${STEP}_${dim}" ]; then
        echo "  ✓ ${name}"
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
      # 非最后一步不允许 auto（必须问 Creator）
      PIPELINE_FILE="pipeline.py"
      if [ -f "$PIPELINE_FILE" ] && [ "$MODE" = "auto" ]; then
        TOTAL_STEPS=$(grep -c 'async def step_[0-9]' "$PIPELINE_FILE" 2>/dev/null || echo 0)
        if [ "$STEP" -lt "$TOTAL_STEPS" ]; then
          echo "错误：步骤 $STEP 不是最后一步（共 $TOTAL_STEPS 步），不能用 auto 模式，必须问 Creator 确认后用 interactive" >&2
          exit 1
        fi
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
    # confirm 维度保存模式信息
    if [ "$DIM" = "confirm" ]; then
      echo "$MODE" > "$TRACKER_DIR/step_${STEP}_confirm_mode"
    fi
    echo "✓ 步骤 $STEP — ${DIM} 已确认${MODE:+ (模式: $MODE)}"
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
    # 从 pipeline.py 中检测总步骤数
    PIPELINE_FILE="pipeline.py"
    if [ ! -f "$PIPELINE_FILE" ]; then
      echo "ERROR: $PIPELINE_FILE 不存在" >&2
      exit 1
    fi
    TOTAL_STEPS=$(grep -c 'async def step_[0-9]' "$PIPELINE_FILE" 2>/dev/null || echo 0)
    if [ "$STEP" -eq "$TOTAL_STEPS" ]; then
      echo "YES"
    else
      echo "NO"
    fi
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
