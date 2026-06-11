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
# ⚠ 输出受众是 Agent 而非用户：最终用户多为非程序员，看不懂终端命令。
#   检测到问题时输出"指示 Claude 替用户执行修复"的指令，而不是给用户看的命令清单。
MCP_DIR="$PLUGIN_ROOT/mcp-servers/minus-platform"
MISSING=""
[ -f "$MCP_DIR/dist/minus-platform.cjs" ] || MISSING="$MISSING dist/minus-platform.cjs"
[ -f "$MCP_DIR/launch.cjs" ] || MISSING="$MISSING launch.cjs"

if [ -n "$MISSING" ]; then
  # 注：bash 3.2 解析 "$VAR" 后紧跟全角字符会吞掉多字节首字节，必须用 ${VAR}
  echo "[minus-creator] MCP Server 产物缺失:${MISSING}（位置: ${MCP_DIR}，OS: ${OS}）"
  echo "MCP 是必需项。给 Claude 的指令：用户不是程序员，请直接替用户执行修复（先征得一句确认即可），不要把命令展示给用户——"
  echo "  claude plugin uninstall minus-creator && claude plugin install minus-creator@minus-plugin"
  if [ "$OS" = "windows" ]; then
    echo "  若 install 报 EPERM：先执行 rm -rf ~/.claude/plugins/cache/temp_local_* 再重装"
  fi
  echo "修复后用非技术语言告知用户结果。"
  [ "$STRICT" = "1" ] && exit 1
  exit 0
fi

# ── 3. Node 运行时检查（仅 hook 模式；install.sh 有自己的交互式 Node gate）──
# MCP bundle 需 node >= NODE_RUNTIME_FLOOR。launch.cjs 会自行探测已知位置的可用 node，
# 这里只兜「机器上彻底没有合格 node」的场景：提前指示 Agent 自动配给，
# 而不是等用户撞上 MCP 故障。下限单源于 toolchain.sh。
if [ "$STRICT" != "1" ]; then
  . "$SCRIPT_DIR/toolchain.sh"
  NODE_MAJOR=""
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
  fi
  # 已知备选位置（launch.cjs 同款思路）：PATH 上没有不代表机器上没有
  if [ -z "$NODE_MAJOR" ] || [ "$NODE_MAJOR" -lt "$NODE_RUNTIME_FLOOR" ] 2>/dev/null; then
    for CAND in ${MINUS_NODE_CANDIDATES:-"$HOME/.volta/bin/node" /usr/local/bin/node /opt/homebrew/bin/node}; do
      [ -x "$CAND" ] || continue
      CAND_MAJOR="$("$CAND" -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
      if [ -n "$CAND_MAJOR" ] && [ "$CAND_MAJOR" -ge "$NODE_RUNTIME_FLOOR" ] 2>/dev/null; then
        NODE_MAJOR="$CAND_MAJOR"
        break
      fi
    done
  fi
  if [ -z "$NODE_MAJOR" ] || [ "$NODE_MAJOR" -lt "$NODE_RUNTIME_FLOOR" ] 2>/dev/null; then
    echo "[minus-creator] 未检测到 Node ${NODE_RUNTIME_FLOOR}+（当前: ${NODE_MAJOR:-无}）。MCP Server 需要它才能运行。"
    echo "给 Claude 的指令：用户不是程序员，不要展示安装命令或让用户自己装 Node。"
    echo "请直接替用户执行 minus-lib bootstrap-env 自动安装环境（Volta + Node ${NODE_TARGET}），完成后用非技术语言告知结果。"
  fi
fi

exit 0
