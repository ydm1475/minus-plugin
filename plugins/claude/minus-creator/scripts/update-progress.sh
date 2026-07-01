#!/usr/bin/env bash
# update-progress.sh
# .minus/progress.json 的唯一写入入口。Agent 对 progress.json 只读不手写。
# 用法:
#   update-progress.sh init-design                  — 初始化（phase=designing, designStage=input_done）
#   update-progress.sh design-done <名1> <名2> ...  — 写入步骤列表，phase=developing
#   update-progress.sh append-steps <名1> ...       — 追加新步骤（pending）
#   update-progress.sh rename-step <N> <新名称>     — 重命名步骤 N
#   update-progress.sh swap-steps <A> <B>           — 交换步骤 A 和 B 的名称与状态
#   update-progress.sh step-done <N>                — 标记步骤 N 完成并推进；最后一步自动 phase=testing
#   update-progress.sh confirm-test                 — 记录 Creator 已确认最后一步测试通过（结果设计的前置门禁）
#   update-progress.sh set-phase <phase>            — 设置 phase（designing|developing|testing|ready）
#   update-progress.sh touch                        — 仅刷新 updatedAt
#   update-progress.sh show                         — 输出当前 progress.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

PROGRESS_FILE=".minus/progress.json"

if [ ! -f ".minus/skill.json" ]; then
  echo "错误：未找到 .minus/skill.json，不在 Minus Skill 项目目录中" >&2
  exit 1
fi

ACTION="${1:-}"
shift || true

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# 读改写 progress.json。改动逻辑由 PROGRESS_OP 环境变量指定，
# 步骤名等数据一律走环境变量传入 node，避免 shell 内插破坏 JSON。
apply() {
  PROGRESS_TS="$TIMESTAMP" PROGRESS_FILE="$PROGRESS_FILE" node -e '
    const fs = require("fs");
    const file = process.env.PROGRESS_FILE;
    let p = {};
    try { p = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}
    p.currentStep = p.currentStep ?? 0;
    p.steps = p.steps ?? {};
    const op = process.env.PROGRESS_OP;
    const names = (process.env.STEP_NAMES || "").split("\n").filter(Boolean);

    if (op === "init-design") {
      p = { currentStep: 0, steps: {}, phase: "designing", designStage: "input_done" };
    } else if (op === "design-done") {
      p.steps = {};
      names.forEach((name, i) => {
        p.steps[String(i + 1)] = { name, status: i === 0 ? "in_progress" : "pending" };
      });
      p.currentStep = 1;
      p.phase = "developing";
      delete p.designStage;
    } else if (op === "append-steps") {
      let max = Math.max(0, ...Object.keys(p.steps).map(Number));
      names.forEach((name) => {
        max += 1;
        p.steps[String(max)] = { name, status: "pending" };
      });
    } else if (op === "rename-step") {
      const n = process.env.STEP_NUM;
      const newName = names[0];
      if (p.steps[n]) p.steps[n].name = newName;
      else p.steps[n] = { name: newName, status: "pending" };
    } else if (op === "swap-steps") {
      const a = process.env.STEP_A, b = process.env.STEP_B;
      const tmp = p.steps[a];
      p.steps[a] = p.steps[b] || { name: "步骤" + a, status: "pending" };
      p.steps[b] = tmp || { name: "步骤" + b, status: "pending" };
    } else if (op === "step-done") {
      const n = Number(process.env.STEP_NUM);
      const total = Number(process.env.TOTAL_STEPS);
      if (!p.steps[String(n)]) p.steps[String(n)] = { name: "步骤" + n, status: "pending" };
      p.steps[String(n)].status = "completed";
      if (n >= total) {
        p.currentStep = total;
        p.phase = "testing";
      } else {
        const next = String(n + 1);
        if (!p.steps[next]) p.steps[next] = { name: "步骤" + (n + 1), status: "pending" };
        if (p.steps[next].status !== "completed") p.steps[next].status = "in_progress";
        p.currentStep = n + 1;
        p.phase = "developing";
      }
    } else if (op === "set-phase") {
      p.phase = process.env.PHASE;
    } else if (op === "touch") {
      // 仅刷新 updatedAt
    }

    p.updatedAt = process.env.PROGRESS_TS;
    fs.writeFileSync(file, JSON.stringify(p, null, 2) + "\n");
  '
}

# 取总步骤数：.minus/total-steps 优先，缺失时回退统计 pipeline.py
total_steps() {
  if [ -f ".minus/total-steps" ]; then
    cat .minus/total-steps
  elif [ -f "pipeline.py" ]; then
    grep -c 'async def step_[0-9]' pipeline.py 2>/dev/null || echo 0
  else
    echo 0
  fi
}

case "$ACTION" in
  init-design)
    PROGRESS_OP=init-design apply
    echo "✓ 进度已初始化（结构设计中，输入定义完成）"
    ;;

  design-done)
    if [ $# -eq 0 ]; then
      echo "用法: update-progress.sh design-done <步骤1名称> <步骤2名称> ..." >&2
      exit 1
    fi
    STEP_NAMES=$(printf '%s\n' "$@")
    PROGRESS_OP=design-done STEP_NAMES="$STEP_NAMES" apply
    echo "✓ 进度已更新：$# 个步骤，进入节点开发阶段（步骤 1 进行中）"
    ;;

  append-steps)
    if [ $# -eq 0 ]; then
      echo "用法: update-progress.sh append-steps <新步骤名称> ..." >&2
      exit 1
    fi
    STEP_NAMES=$(printf '%s\n' "$@")
    PROGRESS_OP=append-steps STEP_NAMES="$STEP_NAMES" apply
    echo "✓ 进度已追加 $# 个步骤"
    ;;

  rename-step)
    STEP_NUM="${1:?rename-step requires step_number and name}"
    NEW_NAME="${2:?rename-step requires step_number and name}"
    STEP_NAMES="$NEW_NAME"
    PROGRESS_OP=rename-step STEP_NUM="$STEP_NUM" STEP_NAMES="$STEP_NAMES" apply
    echo "✓ 步骤 ${STEP_NUM} 已重命名为 ${NEW_NAME}"
    ;;

  swap-steps)
    STEP_A="${1:?用法: update-progress.sh swap-steps <step_a> <step_b>}"
    STEP_B="${2:?用法: update-progress.sh swap-steps <step_a> <step_b>}"
    PROGRESS_OP=swap-steps STEP_A="$STEP_A" STEP_B="$STEP_B" apply
    echo "✓ 步骤 $STEP_A 和步骤 $STEP_B 已交换"
    ;;

  step-done)
    STEP="${1:?用法: update-progress.sh step-done <step_number>}"

    # 硬门禁：pipeline.py 中 step_N 不能仍是骨架占位（# TODO: 实现「）
    if [ ! -f "pipeline.py" ]; then
      echo "错误：未找到 pipeline.py" >&2
      exit 1
    fi
    if awk -v step="$STEP" '
      $0 ~ "async def step_" step "\\(" { inside = 1; next }
      inside && /async def step_[0-9]/ { inside = 0 }
      inside && /# TODO: 实现「/ { found = 1 }
      END { exit found ? 0 : 1 }
    ' pipeline.py; then
      echo "错误：pipeline.py 的 step_${STEP} 仍是未实现的骨架占位（# TODO），先完成代码再标记" >&2
      exit 1
    fi

    TOTAL=$(total_steps)
    PROGRESS_OP=step-done STEP_NUM="$STEP" TOTAL_STEPS="$TOTAL" apply

    # 测试邀请话术单源在此（node-dev.md 只引用，不复制）。
    # 设计原因（CLAUDE.md #1 能硬编码的别靠 Agent 自觉）：人工测试 612 中
    # Agent 把 step-done 和结果设计脚本串在一条命令执行，跳过了测试邀请。
    step_name() {
      cat ".minus/dev-progress/step_${1}_name" 2>/dev/null && return
      node -e "try{const p=JSON.parse(require('fs').readFileSync('$PROGRESS_FILE','utf8'));const s=p.steps&&p.steps['$1'];if(s&&s.name)process.stdout.write(s.name);else process.stdout.write('步骤$1')}catch(e){process.stdout.write('步骤$1')}" 2>/dev/null
    }
    STEP_NAME=$(step_name "$STEP")
    if [ "$STEP" -ge "$TOTAL" ]; then
      # 标记最后一步测试待确认：结果设计门禁靠它拦截
      rm -f .minus/dev-progress/final_test_confirmed
      echo "✓ 步骤 ${STEP} 已完成。全部 ${TOTAL} 个步骤开发完毕，进入待测试阶段（phase=testing）"
      echo "NEXT=WAIT_FOR_CREATOR_TEST"
      echo "── 原样转达给 Creator（每行独立）──"
      echo "「步骤 ${STEP}「${STEP_NAME}」已开发完成，所有步骤都开发完了。」"
      echo "「测试前先刷新一下页面，确保加载的是最新代码。」"
      echo "「刷新后你可以输入测试数据，把整个流程从头到尾跑一遍，检查每一步的展示和数据是否符合预期。」"
      echo "「看完如果没问题，告诉我，我们就进入结果呈现设计（结果摘要和下载内容）。」"
      echo "── 转达后停止，等 Creator 确认 ──"
      echo "Creator 确认测试通过后，先执行 minus-lib update-progress confirm-test，再执行结果设计脚本。"
      echo "⛔ 禁止把本命令与 generate-result-design 串在一条命令里执行；Creator 未确认前禁止进入结果设计。"
    else
      NEXT_STEP=$((STEP + 1))
      NEXT_NAME=$(step_name "$NEXT_STEP")
      echo "✓ 步骤 ${STEP} 已完成，当前进行步骤 ${NEXT_STEP}"
      echo "── 原样转达给 Creator（每行独立）──"
      echo "「步骤 ${STEP}「${STEP_NAME}」已开发完成。」"
      echo "「测试前先刷新一下页面，确保加载的是最新代码。」"
      echo "「刷新后你可以重新输入测试数据开始一次新的流程，检查这个步骤的展示和数据是否符合预期。」"
      echo "「也可以在已有执行页面点击【重新执行】按钮，直接再跑一遍。」"
      echo "「看完如果没问题，我们继续开发步骤 ${NEXT_STEP}「${NEXT_NAME}」吗？」"
      echo "── 转达后停止，等 Creator 回复 ──"
    fi
    ;;

  confirm-test)
    if [ ! -f ".minus/total-steps" ]; then
      echo "错误：步骤骨架尚未生成，无法确认测试" >&2
      exit 1
    fi
    mkdir -p .minus/dev-progress
    date -u '+%Y-%m-%dT%H:%M:%SZ' > .minus/dev-progress/final_test_confirmed
    echo "✓ 已记录 Creator 确认整体测试通过，可以进入结果呈现设计"
    ;;

  set-phase)
    PHASE="${1:?用法: update-progress.sh set-phase <designing|developing|testing|ready>}"
    case "$PHASE" in
      designing|developing|testing|ready) ;;
      *) echo "错误：无效的 phase '$PHASE'，可选：designing|developing|testing|ready" >&2; exit 1 ;;
    esac
    PROGRESS_OP=set-phase PHASE="$PHASE" apply
    echo "✓ phase 已设置为 $PHASE"
    ;;

  touch)
    PROGRESS_OP=touch apply
    echo "✓ 进度时间戳已刷新"
    ;;

  show)
    if [ -f "$PROGRESS_FILE" ]; then
      cat "$PROGRESS_FILE"
    else
      echo "（progress.json 不存在）"
    fi
    ;;

  *)
    echo "用法: update-progress.sh <init-design|design-done|append-steps|rename-step|swap-steps|step-done|confirm-test|set-phase|touch|show> [args]" >&2
    exit 1
    ;;
esac
