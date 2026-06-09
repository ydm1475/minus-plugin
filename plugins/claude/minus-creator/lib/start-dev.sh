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
# restart 场景请先 rm -f .minus/dev-ports.json 再调用本脚本。

MODE="${1:-full}"

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
