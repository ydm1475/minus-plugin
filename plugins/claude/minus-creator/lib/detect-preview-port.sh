#!/bin/bash
# detect-preview-port.sh
# 检测当前项目的前端预览端口（Vite dev server）
#
# 优先从 SDK 写入的 .minus/dev-ports.json 读取，
# fallback 到进程扫描。读到端口后验证归属和可达性。
#
# 用法: detect-preview-port.sh [fallback_port]
# 输出: 端口号（纯数字），验证失败输出空

FALLBACK="${1:-5173}"
PROJECT_DIR="$(pwd)"
MAX_WAIT="${DETECT_PORT_MAX_WAIT:-15}"

verify_port() {
  local port=$1
  local pid
  pid=$(lsof -i :"$port" -t 2>/dev/null | head -1 || true)
  if [ -z "$pid" ]; then
    return 1
  fi
  local cwd
  cwd=$(lsof -p "$pid" -Fn 2>/dev/null | grep -A1 '^fcwd' | grep '^n' | sed 's/^n//' || true)
  if [ -z "$cwd" ]; then
    cwd=$(ls -l /proc/"$pid"/cwd 2>/dev/null | awk '{print $NF}' || true)
  fi
  if [ -n "$cwd" ] && [ "$cwd" != "$PROJECT_DIR" ] && [[ "$cwd" != "$PROJECT_DIR"/* ]]; then
    return 1
  fi
  curl -s -o /dev/null -w '' --max-time 2 "http://localhost:$port/" 2>/dev/null
}

# 方法 1：从 SDK 的 dev-ports.json 读取（带轮询等待）
DEV_PORTS_FILE="$PROJECT_DIR/.minus/dev-ports.json"
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  if [ -f "$DEV_PORTS_FILE" ]; then
    PORT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$DEV_PORTS_FILE','utf8')).frontend||'')" 2>/dev/null)
    if [ -n "$PORT" ] && verify_port "$PORT"; then
      echo "$PORT"
      exit 0
    fi
  fi
  sleep 1
  WAITED=$((WAITED + 1))
done

# 方法 2：从 lsof 找当前项目的 vite 进程监听的端口
VITE_PID=$(pgrep -f "vite.*${PROJECT_DIR}/frontend" 2>/dev/null | head -1 || true)
if [ -n "$VITE_PID" ]; then
  PORT=$(lsof -iTCP -sTCP:LISTEN -p "$VITE_PID" -Fn 2>/dev/null | grep '^n' | grep -oE ':[0-9]+$' | tr -d ':' | head -1 || true)
  if [ -n "$PORT" ] && verify_port "$PORT"; then
    echo "$PORT"
    exit 0
  fi
fi

# 方法 3：扫描常见 Vite 端口（5173-5180），找到属于当前项目的
for P in $(seq 5173 5180); do
  if verify_port "$P"; then
    echo "$P"
    exit 0
  fi
done

# 所有方法均未找到属于当前项目的前端端口
echo "DETECT_FAILED"
exit 1
