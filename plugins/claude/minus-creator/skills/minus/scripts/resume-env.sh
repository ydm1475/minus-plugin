#!/bin/bash
# resume-env.sh
# 开发环境一键恢复：把 env-init.md 里所有「确定性步骤」串成一次执行
# （CLAUDE.md #1 能硬编码的别靠 Agent 自觉——实测散步执行产生 20+ 次工具往返，
# 每步白付一次模型延迟；本脚本把开机链压缩到一次调用）。
#
# 用法: resume-env.sh <desktop|cli|restart>
#   desktop  Desktop + Claude_Preview 可用：后台起后端 + 生成 launch.json，
#            前端交给 preview_start（agent 层调用），输出 NEED_PREVIEW_START=1
#   cli      CLI 或 Preview 不可用：后台起前后端 + 检测预览端口
#   restart  重启：自动检测 Desktop/CLI + 探测哪个挂了，只重启挂的组件
#
# 输出（一行一个 KEY=VALUE，供 agent 直接路由）:
#   NEED_BOOTSTRAP=1                  依赖缺失，需先跑 minus-lib bootstrap-env（脚本就此停止）
#   ENV=ready|failed                  dev server 就绪状态
#   PREVIEW_PORT= / BACKEND_PORT=     端口（拿到才输出）
#   NEED_PREVIEW_START=1              desktop 分支：等 agent 调 preview_start + record-preview-port
#   CLIENT=cli|desktop                cli 分支：detect-preview-port 判定的客户端（决定预览文案）
#   INITIALIZED=0|1                   .minus/initialized 存在性（0=首次进入，需 skill_version_get）
#   PHASE= / DESIGN_STAGE= / CURRENT_STEP= / STEPS_TOTAL= / STEPS_DONE=   progress.json 摘要
#   STEP_STATUS=COMPLETE|INCOMPLETE: ...   当前步骤四维度状态（step-tracker check）
#   FAIL_REASON= + 诊断行              ENV=failed 时

set -u

BRANCH="${1:-auto}"
if [ "$BRANCH" = "auto" ]; then
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    claude-desktop|vscode|jetbrains) BRANCH=desktop ;;
    *) BRANCH=cli ;;
  esac
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${MINUS_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
STEP_TRACKER="$PLUGIN_ROOT/skills/minus-step/scripts/step-tracker.sh"

# ── 1. 本地状态 ──────────────────────────────────────────
STATE="$(sh "$SCRIPT_DIR/check-project-state.sh")"
printf '%s\n' "$STATE" | grep '^INITIALIZED='
if printf '%s\n' "$STATE" | grep -q 'NODE_MODULES=0' || printf '%s\n' "$STATE" | grep -q 'VENV=0'; then
  # bootstrap 耗时长且可能要用户处理（NO_NODE/RESTART_NEEDED），留给 agent 决策
  echo "NEED_BOOTSTRAP=1"
  exit 0
fi

# ── 2. 启动 dev server（后台）──────────────────────────────
mkdir -p .minus
PREVIEW_PORT=""
BACKEND_PORT=""
CLIENT=""

backend_port_from_file() {
  [ -f .minus/dev-ports.json ] || { echo ""; return; }
  node -e "const p=JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).backend;console.log(p>0?p:'')" 2>/dev/null
}

case "$BRANCH" in
  restart)
    # 重启模式：探测哪个组件挂了，设好清理标志，exec 自己走 desktop/cli 链路。
    # 所有启动→探测→输出逻辑复用 desktop/cli 分支，不另写一套。
    case "${CLAUDE_CODE_ENTRYPOINT:-}" in
      claude-desktop|vscode|jetbrains) RESOLVED_BRANCH=desktop ;;
      *) RESOLVED_BRANCH=cli ;;
    esac

    BE_PORT="" FE_PORT=""
    if [ -f .minus/dev-ports.json ]; then
      BE_PORT=$(node -e "const p=JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).backend;console.log(p>0?p:'')" 2>/dev/null)
      FE_PORT=$(node -e "const p=JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).frontend;console.log(p>0?p:'')" 2>/dev/null)
    fi
    BE_OK=false; FE_OK=false
    [ -n "$BE_PORT" ] && curl -s -o /dev/null --max-time 2 "http://localhost:$BE_PORT/" 2>/dev/null && BE_OK=true
    [ -n "$FE_PORT" ] && curl -s -o /dev/null --max-time 2 "http://localhost:$FE_PORT/" 2>/dev/null && FE_OK=true

    if [ "$BE_OK" = true ] && [ "$FE_OK" = true ]; then
      echo "ALREADY_RUNNING"
      [ -n "$BE_PORT" ] && echo "BACKEND_PORT=$BE_PORT"
      [ -n "$FE_PORT" ] && echo "FRONTEND_PORT=$FE_PORT"
      exit 0
    fi

    export MINUS_DEV_RESTART=1
    # 前端还活着 → 只清理后端，Desktop 跳过 NEED_PREVIEW_START
    if [ "$FE_OK" = true ]; then
      export MINUS_RESTART_SCOPE=backend
      export MINUS_SKIP_PREVIEW_START=1
    fi

    exec bash "$0" "$RESOLVED_BRANCH"
    ;;
  desktop)
    # 后端：start-dev 自带「健康且归属本项目 → ALREADY_RUNNING 复用」自检
    nohup bash "$SCRIPT_DIR/start-dev.sh" backend > .minus/backend-dev.log 2>&1 &
    bash "$SCRIPT_DIR/generate-launch-json.sh" >/dev/null 2>&1 || true
    # 等后端健康（最多 30s）
    BP="$(backend_port_from_file)"; BP="${BP:-4001}"
    i=0
    while [ $i -lt 30 ]; do
      if curl -s -o /dev/null --max-time 2 "http://localhost:$BP/" 2>/dev/null; then
        BACKEND_PORT="$BP"
        break
      fi
      sleep 1; i=$((i+1))
    done
    if [ -z "$BACKEND_PORT" ]; then
      echo "ENV=failed"
      echo "FAIL_REASON=BACKEND_START_TIMEOUT"
      tail -20 .minus/backend-dev.log 2>/dev/null | sed 's/^/LOG: /'
      exit 1
    fi
    echo "ENV=ready"
    echo "BACKEND_PORT=$BACKEND_PORT"
    [ "${MINUS_SKIP_PREVIEW_START:-}" != "1" ] && echo "NEED_PREVIEW_START=1"
    ;;
  cli)
    nohup bash "$SCRIPT_DIR/start-dev.sh" full > .minus/dev.log 2>&1 &
    # detect-preview-port 自带等待（最多 15s）+ 归属校验 + 自动打开预览
    DETECT_OUT="$(bash "$SCRIPT_DIR/detect-preview-port.sh" 2>/dev/null)"
    PREVIEW_PORT="$(printf '%s\n' "$DETECT_OUT" | head -1)"
    CLIENT="$(printf '%s\n' "$DETECT_OUT" | grep '^CLIENT=' | head -1 | cut -d= -f2)"
    if [ -z "$PREVIEW_PORT" ] || [ "$PREVIEW_PORT" = "DETECT_FAILED" ]; then
      echo "ENV=failed"
      echo "FAIL_REASON=PREVIEW_DETECT_FAILED"
      tail -20 .minus/dev.log 2>/dev/null | sed 's/^/LOG: /'
      exit 1
    fi
    # 硬门禁复检（含后端健康检查），失败原样透传
    GATE_OUT="$(AUTO_OPEN=0 bash "$SCRIPT_DIR/check-dev-server.sh" 2>&1)" || {
      echo "ENV=failed"
      echo "FAIL_REASON=GATE_FAILED"
      printf '%s\n' "$GATE_OUT" | sed 's/^/LOG: /'
      exit 1
    }
    BACKEND_PORT="$(printf '%s\n' "$GATE_OUT" | sed -n 's/^BACKEND_PORT=//p')"
    echo "ENV=ready"
    echo "PREVIEW_PORT=$PREVIEW_PORT"
    [ -n "$BACKEND_PORT" ] && echo "BACKEND_PORT=$BACKEND_PORT"
    echo "CLIENT=${CLIENT:-cli}"
    ;;
  *)
    echo "用法: resume-env.sh <desktop|cli>" >&2
    exit 2
    ;;
esac

# ── 3. 进度摘要（供 dev-phase 路由，免去 agent 逐文件 Read）────
if [ -f .minus/progress.json ]; then
  node -e '
    const p = JSON.parse(require("fs").readFileSync(".minus/progress.json", "utf8"));
    console.log("PHASE=" + (p.phase || ""));
    if (p.designStage) console.log("DESIGN_STAGE=" + p.designStage);
    console.log("CURRENT_STEP=" + (p.currentStep || 0));
    const totalFile = ".minus/total-steps";
    const fs = require("fs");
    const visibleTotal = fs.existsSync(totalFile) ? parseInt(fs.readFileSync(totalFile, "utf8").trim(), 10) || 0 : 0;
    const steps = p.steps || {};
    const visibleDone = Object.entries(steps).filter(([k, s]) => parseInt(k, 10) <= visibleTotal && s.status === "completed").length;
    console.log("STEPS_TOTAL=" + visibleTotal);
    console.log("STEPS_DONE=" + visibleDone);
  ' 2>/dev/null || echo "PHASE="
else
  echo "PHASE="
fi

CURRENT_STEP="$(node -e 'const p=JSON.parse(require("fs").readFileSync(".minus/progress.json","utf8"));console.log(p.currentStep||0)' 2>/dev/null || echo 0)"
if [ "$CURRENT_STEP" -gt 0 ] 2>/dev/null && [ -f "$STEP_TRACKER" ]; then
  STEP_OUT="$(bash "$STEP_TRACKER" check "$CURRENT_STEP" 2>/dev/null || true)"
  [ -n "$STEP_OUT" ] && echo "STEP_STATUS=$STEP_OUT"
fi

# ── 4. 结果设计状态 ──────────────────────────────────────────
DEV_PROGRESS=".minus/dev-progress"
if [ -f "$DEV_PROGRESS/result_design_done" ]; then
  echo "RESULT_DESIGN=done"
elif [ -f "$DEV_PROGRESS/result_summary_confirmed" ] || [ -f "$DEV_PROGRESS/result_download_confirmed" ]; then
  echo "RESULT_DESIGN=designing"
fi
[ -f "$DEV_PROGRESS/final_test_confirmed" ] && echo "TEST_CONFIRMED=1"

exit 0
