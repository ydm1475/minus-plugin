#!/bin/bash
# detect-preview-port.sh
# 检测当前项目的前端预览端口（Vite dev server）
#
# 优先从 SDK 写入的 .minus/dev-ports.json 读取，
# fallback 到进程扫描。读到端口后验证归属和可达性。
# 检测成功后自动调用 open-preview.sh 打开预览（CLI 开浏览器，Desktop 只输出 URL）。
#
# 用法: detect-preview-port.sh [fallback_port]
# 环境变量: AUTO_OPEN=0 可禁用自动打开（测试用）
# 输出: 端口号（纯数字），验证失败输出 DETECT_FAILED

FALLBACK="${1:-5173}"
PROJECT_DIR="$(realpath "$(pwd)" 2>/dev/null || pwd -P)"
MAX_WAIT="${DETECT_PORT_MAX_WAIT:-15}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

found_port() {
  local port=$1
  echo "$port"
  if [ "${AUTO_OPEN:-1}" = "1" ]; then
    bash "$SCRIPT_DIR/open-preview.sh" "$port" 2>/dev/null || true
  fi
  exit 0
}

is_windows() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# 找监听该端口的进程 PID（跨平台）。Unix 用 lsof；Windows Git Bash 没有 lsof，用 netstat -ano。
port_pid() {
  local port=$1
  if is_windows; then
    # netstat -ano 的 LISTENING 行：本地地址以 :port 结尾，末列是 PID（状态恒为英文 LISTENING）。
    netstat -ano 2>/dev/null \
      | grep -i 'LISTENING' \
      | grep -E "[:.]${port}[[:space:]]" \
      | awk '{print $NF}' | head -1
  else
    # 必须只取「监听者」：lsof -i :port 会连同与该端口建立连接的客户端进程一起返回
    # （如用户打开预览后浏览器/iframe 对 vite 建的连接）。若 head -1 抓到客户端进程，
    # 其 cwd 不在本项目 → verify_port 的归属校验误判失败 → 门禁把活着的 server 误报为没起。
    # 加 -sTCP:LISTEN 过滤，只认监听进程。
    lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1
  fi
}

verify_port() {
  local port=$1
  local pid
  pid=$(port_pid "$port")
  if [ -z "$pid" ]; then
    return 1
  fi
  # 归属校验（CLAUDE.md #5：存在≠属于我）。Windows Git Bash 拿不到进程 cwd（需 wmic/PowerShell，
  # 慢且不稳），故 Windows 跳过 cwd 校验：方法1 的端口取自本项目 .minus/dev-ports.json，归属由
  # 文件位置保证；方法3 扫描为最后兜底，仅靠可达性。Unix 仍做严格 cwd 校验。
  if ! is_windows; then
    local cwd
    cwd=$(lsof -p "$pid" -Fn 2>/dev/null | grep -A1 '^fcwd' | grep '^n' | sed 's/^n//' || true)
    if [ -z "$cwd" ]; then
      cwd=$(ls -l /proc/"$pid"/cwd 2>/dev/null | awk '{print $NF}' || true)
    fi
    # realpath 规范化：消除 symlink 差异（如 /tmp vs /private/tmp）和潜在的转义字符
    if [ -n "$cwd" ] && command -v realpath >/dev/null 2>&1; then
      cwd=$(realpath "$cwd" 2>/dev/null || echo "$cwd")
    fi
    if [ -n "$cwd" ] && [ "$cwd" != "$PROJECT_DIR" ] && [[ "$cwd" != "$PROJECT_DIR"/* ]]; then
      return 1
    fi
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
      found_port "$PORT"
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
    found_port "$P"
  fi
done

# 所有方法均未找到属于当前项目的前端端口
echo "DETECT_FAILED"
exit 1
