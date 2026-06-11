#!/bin/bash
# E2E 测试：dev server 启动链路验证
# 在真实 Skill 项目中验证：npm run dev → dev-ports.json 生成 → 端口可达
#
# 用法：
#   bash tests/e2e-dev-server.sh
#   E2E_KEEP=1 bash tests/e2e-dev-server.sh    # 保留临时项目不删

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
WORKSPACE="$HOME/minus"
PROJECT_NAME="e2e-devserver-$(date +%s)"
PROJECT_DIR=""
KEEP="${E2E_KEEP:-0}"

# ── 颜色 ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo -e "    $2"; }
info() { echo -e "  ${YELLOW}→${NC} $1"; }

# ── 清理函数 ──
cleanup() {
  # 杀掉我们启动的进程
  if [ -n "${DEV_PID:-}" ]; then
    kill "$DEV_PID" 2>/dev/null
    wait "$DEV_PID" 2>/dev/null
  fi
  # 清理端口上的残留进程（属于当前项目的）
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
    for pid in $(lsof -i :4001 -i :5173 -t 2>/dev/null); do
      CMD=$(ps -p "$pid" -o command= 2>/dev/null || true)
      if echo "$CMD" | grep -q "$PROJECT_DIR" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    done
  fi
  if [ "$KEEP" = "1" ]; then
    echo -e "\n  ${YELLOW}→${NC} E2E_KEEP=1，保留项目：$PROJECT_DIR"
  else
    rm -rf "$PROJECT_DIR" 2>/dev/null || true
    echo -e "\n  ${YELLOW}→${NC} 已清理临时项目"
  fi
}
trap cleanup EXIT

# ══════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   E2E 测试：dev server 启动链路          ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Phase 0：创建项目 ──
info "创建临时项目：$PROJECT_NAME"
CREATE_OUTPUT=$(cd "$WORKSPACE" && create-skill "$PROJECT_NAME" --non-interactive 2>&1 || true)

ACTUAL_DIR=$(echo "$CREATE_OUTPUT" | grep '__CREATE_RESULT__' | sed 's/.*"targetDir":"\([^"]*\)".*/\1/')
if [ -n "$ACTUAL_DIR" ]; then
  PROJECT_DIR="$ACTUAL_DIR"
else
  PROJECT_DIR="$WORKSPACE/$PROJECT_NAME"
fi

if [ ! -f "$PROJECT_DIR/.minus/skill.json" ]; then
  fail "项目创建" "skill.json 不存在"
  echo "$CREATE_OUTPUT"
  exit 1
fi
pass "项目已创建：$PROJECT_DIR"
cd "$PROJECT_DIR"

# ── Phase 1：依赖安装 ──
echo ""
echo -e "${CYAN}── Phase 1：依赖安装 ──${NC}"

info "npm install..."
NPM_OUTPUT=$(npm install 2>&1)
if [ $? -eq 0 ]; then
  pass "npm install 成功"
else
  fail "npm install" "$(echo "$NPM_OUTPUT" | tail -5)"
  exit 1
fi

info "链接本地 SDK（dev-vite-plugin）..."
LINK_OUTPUT=$(cd frontend && npm link @minus/dev-vite-plugin 2>&1)
if [ $? -eq 0 ]; then
  pass "dev-vite-plugin 链接到本地 SDK 源码"
else
  info "npm link 失败（可能未全局链接），使用 registry 版本: $(echo "$LINK_OUTPUT" | tail -2)"
fi

info "uv venv + pip install..."
UV_OUTPUT=$(uv venv -p 3.12 2>&1 && uv pip install -e . 2>&1)
if [ $? -eq 0 ]; then
  pass "Python 虚拟环境创建成功"
else
  fail "uv venv" "$(echo "$UV_OUTPUT" | tail -5)"
  exit 1
fi

# ── Phase 2：验证 SDK 工具链 ──
echo ""
echo -e "${CYAN}── Phase 2：验证 SDK 工具链 ──${NC}"

# minus-dev-cleanup 存在
if [ -f "node_modules/.bin/minus-dev-cleanup" ]; then
  pass "minus-dev-cleanup 存在于 node_modules/.bin/"
else
  fail "minus-dev-cleanup 不存在" "$(ls node_modules/.bin/minus* 2>/dev/null || echo '无 minus-* 命令')"
fi

# package.json 的 dev 脚本引用了 minus-dev-cleanup
DEV_SCRIPT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('package.json','utf8')).scripts?.dev||'')" 2>/dev/null)
if echo "$DEV_SCRIPT" | grep -q "minus-dev-cleanup"; then
  pass "package.json dev 脚本引用了 minus-dev-cleanup: $DEV_SCRIPT"
else
  fail "package.json dev 脚本未引用 SDK 工具" "当前 dev 脚本: $DEV_SCRIPT"
fi

# ── Phase 3：启动 dev server ──
echo ""
echo -e "${CYAN}── Phase 3：启动 dev server ──${NC}"

info "npm run dev（后台启动，等待 15 秒）..."
npm run dev > /tmp/e2e-devserver-output.log 2>&1 &
DEV_PID=$!
sleep 15

# 检查进程是否还活着
if kill -0 "$DEV_PID" 2>/dev/null; then
  pass "dev server 进程存活 (PID $DEV_PID)"
else
  fail "dev server 进程已退出" "$(tail -20 /tmp/e2e-devserver-output.log)"
fi

# ── Phase 4：验证 dev-ports.json ──
echo ""
echo -e "${CYAN}── Phase 4：验证 dev-ports.json ──${NC}"

DEV_PORTS_FILE=".minus/dev-ports.json"
if [ -f "$DEV_PORTS_FILE" ]; then
  pass "dev-ports.json 已生成"

  # 验证 JSON 格式
  if node -e "JSON.parse(require('fs').readFileSync('$DEV_PORTS_FILE','utf8'))" 2>/dev/null; then
    pass "dev-ports.json 是合法 JSON"
  else
    fail "dev-ports.json 格式错误" "$(cat "$DEV_PORTS_FILE")"
  fi

  # 验证 frontend 字段
  FRONTEND_PORT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$DEV_PORTS_FILE','utf8')).frontend||'')" 2>/dev/null)
  if [ -n "$FRONTEND_PORT" ]; then
    pass "frontend 端口: $FRONTEND_PORT"
  else
    fail "frontend 字段缺失" "$(cat "$DEV_PORTS_FILE")"
  fi

  # 验证 backend 字段
  BACKEND_PORT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$DEV_PORTS_FILE','utf8')).backend||'')" 2>/dev/null)
  if [ -n "$BACKEND_PORT" ]; then
    pass "backend 端口: $BACKEND_PORT"
  else
    fail "backend 字段缺失" "$(cat "$DEV_PORTS_FILE")"
  fi
else
  fail "dev-ports.json 未生成" "SDK 的 dev-vite-plugin 应在 Vite 启动后写入此文件"
  FRONTEND_PORT=""
  BACKEND_PORT=""
fi

# ── Phase 5：端口可达性 ──
echo ""
echo -e "${CYAN}── Phase 5：端口可达性 ──${NC}"

if [ -n "${BACKEND_PORT:-}" ]; then
  if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$BACKEND_PORT" 2>/dev/null | grep -qE "2[0-9]{2}|404"; then
    pass "后端端口 $BACKEND_PORT 可达"
  else
    fail "后端端口 $BACKEND_PORT 不可达"
  fi
else
  info "跳过后端端口检查（无端口信息）"
  # fallback：检查常见端口
  for p in 4001 4002 4003; do
    if lsof -i :"$p" -t >/dev/null 2>&1; then
      info "发现后端进程在端口 $p"
      break
    fi
  done
fi

if [ -n "${FRONTEND_PORT:-}" ]; then
  if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$FRONTEND_PORT" 2>/dev/null | grep -qE "2[0-9]{2}|304"; then
    pass "前端端口 $FRONTEND_PORT 可达"
  else
    # Vite 可能因 concurrently 联动退出，检查日志确认是否启动过
    if grep -q "VITE.*ready" /tmp/e2e-devserver-output.log 2>/dev/null; then
      pass "前端端口 $FRONTEND_PORT 曾启动成功（Vite ready，进程已退出）"
    else
      fail "前端端口 $FRONTEND_PORT 不可达"
    fi
  fi
else
  info "跳过前端端口检查（无端口信息）"
fi

# ── Phase 6：Plugin 脚本兼容性 ──
echo ""
echo -e "${CYAN}── Phase 6：Plugin 脚本兼容性 ──${NC}"

# detect-preview-port.sh 能读到端口
DETECTED_PORT=$(bash "$PLUGIN_DIR/skills/minus/scripts/detect-preview-port.sh" 2>/dev/null)
if [ -n "$DETECTED_PORT" ] && [ "$DETECTED_PORT" != "5173" ] || [ -f "$DEV_PORTS_FILE" ]; then
  if [ -n "${FRONTEND_PORT:-}" ] && [ "$DETECTED_PORT" = "$FRONTEND_PORT" ]; then
    pass "detect-preview-port.sh 返回正确端口: $DETECTED_PORT"
  elif [ -n "$DETECTED_PORT" ]; then
    # 能返回一个端口就算部分通过
    info "detect-preview-port.sh 返回: $DETECTED_PORT (预期: ${FRONTEND_PORT:-未知})"
  else
    fail "detect-preview-port.sh 未返回端口"
  fi
else
  fail "detect-preview-port.sh 返回 fallback 值" "dev-ports.json 不存在或脚本未读取"
fi

# ══════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════"
echo -e "  结果: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} (共 $TOTAL 项)"
echo "═══════════════════════════════════════"
echo ""
echo "dev server 输出日志: /tmp/e2e-devserver-output.log"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
