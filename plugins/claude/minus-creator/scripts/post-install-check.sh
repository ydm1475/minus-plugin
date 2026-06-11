#!/bin/bash
# 装后自检（单源）：MCP 产物校验 + 安装缓存残留清理。
# 两个调用方共享同一份逻辑（指令单源化）：
#   1) SessionStart hook（默认模式）：缺产物时输出补救指引，exit 0 不阻塞会话
#   2) install.sh --strict：缺产物视为安装失败，exit 1 中止
# 用法: post-install-check.sh [--strict] [PLUGIN_ROOT]

STRICT=0
if [ "${1:-}" = "--strict" ]; then
  STRICT=1
  shift
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${1:-$(dirname "$SCRIPT_DIR")}"

# OS 探测：Windows（Git Bash/MSYS）与 mac/linux 分支用
case "$(uname -s)" in
  Darwin) OS=mac ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) OS=linux ;;
esac

# ── 1. 清理安装缓存残留，为下次 install/update 铺平 rename 落点 ──
# claude plugin install 先解压到 cache/temp_local_* 再 rename 到目标目录；
# Windows 的 fs.rename 撞上残留目录会 EPERM。旧版本插件的 SessionStart 提前清掉
# 陈旧残留（>60 分钟，避开正在进行的安装），覆盖"升级"场景；
# "首次安装失败后重试"场景由 install.sh 装前清理兜底。
CACHE_ROOT="${MINUS_CACHE_ROOT:-$HOME/.claude/plugins/cache}"
if [ -d "$CACHE_ROOT" ]; then
  find "$CACHE_ROOT" -maxdepth 1 -name 'temp_local_*' -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true
fi

# ── 2. MCP 产物校验（自包含 bundle + launcher，缺任一 MCP 起不来）──
MCP_DIR="$PLUGIN_ROOT/mcp-servers/minus-platform"
MISSING=""
[ -f "$MCP_DIR/dist/minus-platform.cjs" ] || MISSING="$MISSING dist/minus-platform.cjs"
[ -f "$MCP_DIR/launch.cjs" ] || MISSING="$MISSING launch.cjs"

if [ -n "$MISSING" ]; then
  # 注：bash 3.2 解析 "$VAR" 后紧跟全角字符会吞掉多字节首字节，必须用 ${VAR}
  echo "[minus-creator] MCP Server 产物缺失:${MISSING}（位置: ${MCP_DIR}，OS: ${OS}）"
  echo "MCP 是必需项。补救：重新安装插件——"
  echo "  claude plugin uninstall minus-creator && claude plugin install minus-creator@minus-plugin"
  if [ "$OS" = "windows" ]; then
    echo "  若 install 报 EPERM：先执行 rm -rf ~/.claude/plugins/cache/temp_local_* 再重装"
  fi
  [ "$STRICT" = "1" ] && exit 1
  exit 0
fi

exit 0
