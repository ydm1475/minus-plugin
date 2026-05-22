#!/bin/bash
# detect-preview-port.sh
# 检测当前项目的前端预览端口（Vite dev server）
#
# npm run dev 同时启动后端（uvicorn）和前端（vite）。
# 预览地址是前端 Vite 的端口，不是后端的。
# 此脚本从运行中的 Vite 进程中检测实际监听端口。
#
# 用法: detect-preview-port.sh [fallback_port]
# 输出: 端口号（纯数字）

FALLBACK="${1:-5173}"
PROJECT_DIR="$(pwd)"

# 方法 1：从 lsof 找当前项目的 vite 进程监听的端口
VITE_PID=$(pgrep -f "vite.*${PROJECT_DIR}/frontend" 2>/dev/null | head -1 || true)
if [ -n "$VITE_PID" ]; then
  PORT=$(lsof -iTCP -sTCP:LISTEN -p "$VITE_PID" -Fn 2>/dev/null | grep '^n' | grep -oE ':[0-9]+$' | tr -d ':' | head -1 || true)
  if [ -n "$PORT" ]; then
    echo "$PORT"
    exit 0
  fi
fi

# 方法 2：扫描常见 Vite 端口（5173-5180），找到属于当前项目的
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

# 方法 3：fallback
echo "$FALLBACK"
