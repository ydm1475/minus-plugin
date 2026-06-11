#!/bin/bash
# start-dev.sh
# 统一的 dev server 启动脚本（单源化 SKILL.md 里 4 处重复的 PNPM 启动块）。
# 负责解析 pnpm 绝对路径、带上 VOLTA_FEATURE_PNPM、按平台选对应 pnpm script。
#
# 用法: start-dev.sh [full|backend]
#   full    （默认）启动前后端：mac/Linux=pnpm dev；Windows=pnpm run dev:win
#   backend 只启动后端：    mac/Linux=pnpm dev:backend；Windows=pnpm run dev:win:backend
#
# 注意：本脚本会前台启动 dev server（长驻进程）。调用方应以后台方式运行
# （Bash 工具 run_in_background），不要在这里 fork/nohup。
# restart 场景直接以 MINUS_DEV_RESTART=1 调用本脚本即可——旧进程清理与
# dev-ports.json 删除都在脚本内按正确顺序处理，调用方不要自己 rm/kill。

MODE="${1:-full}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 启动前自检（CLAUDE.md #5 存在≠属于我 / #1 能硬编码的别靠 Agent 自觉）：
# 上一个 session 的 dev server 可能还活着；此时再起一个必撞端口冲突，
# 新进程被 concurrently SIGTERM（实测后台任务报 exit 143，英文报错直怼用户）。
# 已有归属本项目的 server 在跑 → 输出 ALREADY_RUNNING 并成功退出，复用旧 server。
# restart 场景（版本恢复/用户要求重启）用 MINUS_DEV_RESTART=1 跳过自检。
if [ "${MINUS_DEV_RESTART:-0}" != "1" ] && [ "$MODE" != "backend" ]; then
  GATE_OUT="$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=2 bash "$SCRIPT_DIR/check-dev-server.sh" 2>/dev/null || true)"
  if printf '%s\n' "$GATE_OUT" | grep -q '^GATE_PASSED$'; then
    echo "ALREADY_RUNNING"
    printf '%s\n' "$GATE_OUT" | grep '^PREVIEW_PORT=' || true
    exit 0
  fi
fi

# 重启场景（MINUS_DEV_RESTART=1）：先趁 dev-ports.json 还在时清旧进程，再删端口
# 记录。顺序硬编码在这里——此前 md 指令是「先 rm 再启动」，cleanup 读不到端口记录
# 只能回退默认 4001，非默认端口项目会漏清（能硬编码的别靠 Agent 自觉）。
# 清理分两层：
#   后端 → Platform 的 minus-dev-cleanup（按 dev-ports.json 解析后端端口）
#   前端 → 本脚本杀归属本项目的旧 vite 监听（2026-06-11 拍板：重启场景允许脚本
#          kill 归属校验通过的旧进程；否则旧 vite 占着端口变僵尸累积。
#          Agent 手动 kill 仍被 env-init.md 禁止——只有这段硬编码可以杀）。
if [ "${MINUS_DEV_RESTART:-0}" = "1" ]; then
  if [ -x node_modules/.bin/minus-dev-cleanup ]; then
    node_modules/.bin/minus-dev-cleanup || true
  fi
  # 杀归属本项目的旧前端监听。归属校验（CLAUDE.md #5 存在≠属于我）：
  #   Unix    → lsof 验证监听进程 cwd 在本项目内才杀
  #   Windows → 拿不到 cwd，只杀 dev-ports.json（文件在本项目，来源可信）记录的端口
  RESTART_FE_PORTS=""
  if [ -f .minus/dev-ports.json ]; then
    RESTART_FE_PORTS=$(node -e "const p=JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).frontend;console.log(p>0?p:'')" 2>/dev/null)
  fi
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      for P in $RESTART_FE_PORTS; do
        OLD_PID=$(netstat -ano 2>/dev/null | grep -i 'LISTENING' | grep -E "[:.]${P}[[:space:]]" | awk '{print $NF}' | head -1)
        [ -n "$OLD_PID" ] && taskkill //PID "$OLD_PID" //F >/dev/null 2>&1 || true
      done
      ;;
    *)
      # Unix 可验归属，扫描兜底端口段（dev-ports.json 可能缺失/过期）
      RESTART_PROJ="$(pwd -P)"
      for P in $RESTART_FE_PORTS $(seq 5173 5180); do
        OLD_PID=$(lsof -iTCP:"$P" -sTCP:LISTEN -t 2>/dev/null | head -1)
        [ -n "$OLD_PID" ] || continue
        OLD_CWD=$(lsof -a -p "$OLD_PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
        # lsof 对非 ASCII 路径输出 \xHH 转义（中文项目名），还原后再比较
        case "$OLD_CWD" in *'\'*) OLD_CWD=$(printf '%b' "$OLD_CWD" 2>/dev/null || echo "$OLD_CWD") ;; esac
        case "$OLD_CWD" in
          "$RESTART_PROJ"|"$RESTART_PROJ"/*)
            kill "$OLD_PID" 2>/dev/null || true
            I=0
            while [ $I -lt 5 ] && kill -0 "$OLD_PID" 2>/dev/null; do sleep 1; I=$((I+1)); done
            kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID" 2>/dev/null || true
            ;;
        esac
      done
      ;;
  esac
  rm -f .minus/dev-ports.json
fi

# backend 模式同款自检：上一个 session 的后端可能还健康地活着（实测 2026-06-11：
# 旧 uvicorn 占 4001，新启动撞端口失败）。健康且归属本项目 → 复用；
# 端口被占但不健康/不归属 → 不在这里杀（清理是 Platform minus-dev-cleanup 的职责，
# pnpm dev:backend 模板自带），照常启动让 cleanup 接手。
if [ "${MINUS_DEV_RESTART:-0}" != "1" ] && [ "$MODE" = "backend" ]; then
  BACKEND_PORT=""
  if [ -f .minus/dev-ports.json ]; then
    BACKEND_PORT=$(node -e "const p=JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).backend;console.log(p>0?p:'')" 2>/dev/null)
  fi
  BACKEND_PORT="${BACKEND_PORT:-4001}"
  if curl -s -o /dev/null --max-time 2 "http://localhost:$BACKEND_PORT/" 2>/dev/null; then
    # 健康 ≠ 归属（CLAUDE.md #5）：验证监听进程的 cwd 是当前项目才复用
    OWNER_PID=$(lsof -nP -iTCP:"$BACKEND_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)
    if [ -n "$OWNER_PID" ]; then
      OWNER_CWD=$(lsof -a -p "$OWNER_PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
      if [ "$OWNER_CWD" = "$(pwd)" ]; then
        echo "ALREADY_RUNNING"
        echo "BACKEND_PORT=$BACKEND_PORT"
        exit 0
      fi
    fi
  fi
fi

# 若 pnpm 当年用实验 flag 装的，运行时也必须带此开关，否则报 Could not find
# executable "pnpm"；新版 Volta 下为 no-op，加了无害。
export VOLTA_FEATURE_PNPM=1
VOLTA_HOME="${VOLTA_HOME:-$HOME/.volta}"

# 确保 Volta bin 在 PATH 最前面：pnpm 的子进程（concurrently、vite 等）
# 需要通过 PATH 找到正确版本的 node，否则会被系统旧 node 抢先。
if [ -d "$VOLTA_HOME/bin" ] && [[ ":$PATH:" != *":$VOLTA_HOME/bin:"* ]]; then
  export PATH="$VOLTA_HOME/bin:$PATH"
fi

# 解析 pnpm：优先 Volta shim，其次 PATH 上的 pnpm，最后兜底裸 pnpm。
if [ -x "$VOLTA_HOME/bin/pnpm" ]; then
  PNPM_CMD="$VOLTA_HOME/bin/pnpm"
elif command -v pnpm >/dev/null 2>&1; then
  PNPM_CMD="$(command -v pnpm)"
else
  PNPM_CMD="pnpm"
fi

OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
is_windows=false
case "$OS_NAME" in
  MINGW*|MSYS*|CYGWIN*) is_windows=true ;;
esac

case "$MODE" in
  backend)
    if [ "$is_windows" = true ]; then
      exec "$PNPM_CMD" run dev:win:backend
    else
      exec "$PNPM_CMD" dev:backend
    fi
    ;;
  full)
    if [ "$is_windows" = true ]; then
      exec "$PNPM_CMD" run dev:win
    else
      exec "$PNPM_CMD" dev
    fi
    ;;
  *)
    echo "用法: start-dev.sh [full|backend]" >&2
    exit 2
    ;;
esac
