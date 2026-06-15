#!/bin/bash
# step-tracker.sh
# 跟踪节点开发四维度的完成状态
# 用法:
#   step-tracker.sh status <step_number>                    — 查看某步骤四维度状态
#   step-tracker.sh ask <step_number> <dim> [<dim2>...]    — 输出该维度引导话术，写 _asked 盖章前置标记
#   step-tracker.sh complete <step_number> <dim> [mode]    — 标记某维度完成（需先 ask 并等真实用户回复）
#   step-tracker.sh check <step_number>                    — 检查四维度是否全部完成
#   step-tracker.sh reset <step_number>                    — 重置某步骤的状态
#   step-tracker.sh is-last <step_number>                  — 判断是否为最后一步（YES/NO）
#   step-tracker.sh list                                   — 列出所有步骤状态

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

# 维度话术（ask 子命令的单源输出）
dim_prompt() {
  local DIM="$1"
  case "$DIM" in
    data)
      echo "「数据获取已就绪，准备确认。」"
      echo ""
      echo "「这一步能拿到以下数据——[在此填入接口发现的数据字段]。这些数据够用吗？还是需要补充？」"
      ;;
    logic)
      echo "「数据获取确认完毕。」"
      echo ""
      echo "「下一个问题：拿到这些数据之后，怎么处理？」"
      echo ""
      echo "「比如：直接透传原始数据？做聚合/排序？用大模型做分析总结？」"
      ;;
    output)
      echo "「处理逻辑确认完毕。」"
      echo ""
      echo "「下一个问题：这一步要展示什么给用户看？」"
      echo ""
      echo "「比如：一个数据表格、一段文字摘要、一个评分卡片……」"
      ;;
    confirm)
      echo "「展示内容确认完毕。」"
      echo ""
      echo "「下一个问题：用户运行到这一步后，需要暂停让用户确认数据再继续吗？还是自动往下走？」"
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

  ask)
    STEP="${2:?用法: step-tracker.sh ask <step_number> <dim> [<dim2>...]}"
    shift 2
    DIMS_TO_ASK=("$@")
    if [ "${#DIMS_TO_ASK[@]}" -eq 0 ]; then
      echo "错误：必须指定至少一个维度（data|logic|output|confirm）" >&2
      exit 1
    fi
    ensure_dir

    # 校验所有维度合法
    for DIM in "${DIMS_TO_ASK[@]}"; do
      VALID=false
      for d in "${DIMS[@]}"; do
        [ "$DIM" = "$d" ] && VALID=true
      done
      if [ "$VALID" = false ]; then
        echo "错误：无效的维度 '$DIM'，可选：data|logic|output|confirm" >&2
        exit 1
      fi
    done

    # 写 _asked 标记（盖章前置）
    for DIM in "${DIMS_TO_ASK[@]}"; do
      touch "$TRACKER_DIR/step_${STEP}_${DIM}_asked"
    done

    # 单维度：输出对应话术
    # 多维度：输出合并确认提示（Agent 基于已收集的意图动态拼合并句）
    echo "── 原样转达给 Creator（每行独立）──"
    if [ "${#DIMS_TO_ASK[@]}" -eq 1 ]; then
      dim_prompt "${DIMS_TO_ASK[0]}"
    else
      echo "「我理解这一步的意图是：[在此用通俗语言逐项复述各维度已明确表达的内容]。这样对吗？」"
    fi
    echo ""
    echo "⛔ 本轮到此结束，转达后停止，等待 Creator 回复后再执行 complete。"
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

    # 硬门禁：必须有 _replied 才能 complete（即 ask 之后发生过真实用户轮次）
    if [ ! -f "$TRACKER_DIR/step_${STEP}_${DIM}_replied" ]; then
      echo "⛔ 还没等 Creator 回复就标记完成 — 先执行 minus-lib step-tracker ask ${STEP} ${DIM}，转达后停止，等 Creator 回复后再 complete。" >&2
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

    # 清掉本维度盖章文件（避免陈旧 _replied 被后续误用）
    rm -f "$TRACKER_DIR/step_${STEP}_${DIM}_asked" \
          "$TRACKER_DIR/step_${STEP}_${DIM}_replied"

    MODE_DISPLAY="${4:-}"
    echo "✓ 步骤 $STEP — ${DIM} 已确认${MODE_DISPLAY:+ (模式: $MODE_DISPLAY)}"

    # 输出下一步操作指引（不再附带话术，话术单源在 ask 子命令）
    case "$DIM" in
      data)
        echo "NEXT_DIM=logic"
        echo "执行：minus-lib step-tracker ask ${STEP} logic，转达后停止等回复。"
        ;;
      logic)
        echo "NEXT_DIM=output"
        echo "执行：minus-lib step-tracker ask ${STEP} output，转达后停止等回复。"
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
          echo "执行：minus-lib step-tracker ask ${STEP} confirm，转达后停止等回复。"
        fi
        ;;
      confirm)
        echo "NEXT=GENERATE"
        echo "四维度已全部确认。接下来执行：minus-lib generate-node-code ${STEP}"
        ;;
    esac
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
    echo "用法: step-tracker.sh <status|ask|complete|check|reset|is-last|list> [args]"
    exit 1
    ;;
esac
