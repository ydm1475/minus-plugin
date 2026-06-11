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
# restart 场景请先 rm -f .minus/dev-ports.json，再以 MINUS_DEV_RESTART=1 调用本脚本。

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

# 重启场景（MINUS_DEV_RESTART=1）：先趁 dev-ports.json 还在时跑 Platform 的
# minus-dev-cleanup（它按该文件解析后端端口、清掉归属本项目的孤儿监听），再删端口
# 记录。顺序硬编码在这里——此前 md 指令是「先 rm 再启动」，cleanup 读不到端口记录
# 只能回退默认 4001，非默认端口项目会漏清（能硬编码的别靠 Agent 自觉）。
if [ "${MINUS_DEV_RESTART:-0}" = "1" ]; then
  if [ -x node_modules/.bin/minus-dev-cleanup ]; then
    node_modules/.bin/minus-dev-cleanup || true
  fi
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
