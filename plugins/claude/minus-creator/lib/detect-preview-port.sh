#!/bin/bash
# detect-preview-port.sh
# 检测当前项目的前端预览端口（Vite dev server）
#
# 优先从 SDK 写入的 .minus/dev-ports.json 读取，
# fallback 到进程扫描。
#
# 用法: detect-preview-port.sh [fallback_port]
# 输出: 端口号（纯数字）

FALLBACK="${1:-5173}"
PROJECT_DIR="$(pwd)"

# 方法 1：从 SDK 的 dev-ports.json 读取
DEV_PORTS_FILE="$PROJECT_DIR/.minus/dev-ports.json"
if [ -f "$DEV_PORTS_FILE" ]; then
  PORT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$DEV_PORTS_FILE','utf8')).frontend||'')" 2>/dev/null)
  if [ -n "$PORT" ]; then
    echo "$PORT"
    exit 0
  fi
fi

# 方法 2：从 lsof 找当前项目的 vite 进程监听的端口
VITE_PID=$(pgrep -f "vite.*${PROJECT_DIR}/frontend" 2>/dev/null | head -1 || true)
if [ -n "$VITE_PID" ]; then
  PORT=$(lsof -iTCP -sTCP:LISTEN -p "$VITE_PID" -Fn 2>/dev/null | grep '^n' | grep -oE ':[0-9]+$' | tr -d ':' | head -1 || true)
  if [ -n "$PORT" ]; then
    echo "$PORT"
    exit 0
  fi
fi

# 方法 3：扫描常见 Vite 端口（5173-5180），找到属于当前项目的
for P in $(seq 5173 5180); do
  PID=$(lsof -i :"$P" -t 2>/dev/null | head -1 || true)
  if [ -n "$PID" ]; then
    CMD=$(ps -p "$PID" -o command= 2>/dev/null || true)
    if echo "$CMD" | grep -q "vite" 2>/dev/null; then
      echo "$P"
      exit 0
    fi
  fi
done

# 方法 4：fallback
echo "$FALLBACK"
