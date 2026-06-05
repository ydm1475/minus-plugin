#!/bin/sh
# diagnose-mcp.sh — Minus 平台 MCP 连不上时的「引导式自救」诊断器
#
# 为什么需要它：.mcp.json 用 command:"node" 跑 launch.cjs，若 PATH 上第一个 node 是
# 坏的（典型：Homebrew node@22 被 simdjson 升级搞坏，加载 libsimdjson.31 时 dyld 崩），
# launch.cjs 在执行第一行前就崩了 → 平台 MCP 永远连不上 → auth_status 工具缺失 →
# SKILL.md 走「工具不可用」分支。此刻 skill 仍以 Claude+Bash 身份运行，故用本脚本
# （不依赖 node）诊断 PATH 上 node 的健康度，给出具体可操作指引，替代那句无指引的
# 「服务未就绪，请重启」。
#
# 契约：始终 exit 0，向 stdout 打印一段给人看的指引（SKILL.md 原样展示）。
# 文案单源于本脚本——SKILL.md 不再内联任何修复话术。
# 版本下限/推荐口径单源于同目录 toolchain.sh（与 launch.cjs/bootstrap-env.sh 一致）。

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# ── 版本常量：单源 toolchain.sh，读不到则兜底（本脚本在 node 坏的环境也要能跑）──
NODE_FLOOR=24
NODE_TARGET=24
if [ -f "$DIR/toolchain.sh" ]; then
  # toolchain.sh 是纯 KEY=value 的可 source shell；source 失败也不致命（已有兜底）
  # shellcheck disable=SC1091
  . "$DIR/toolchain.sh" 2>/dev/null || true
fi

# ── 平台粗分（仅用于 install 脚本文案；Windows 不会有 homebrew/simdjson 坏法）──
IS_WIN=0
case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) IS_WIN=1 ;;
esac

install_hint() {
  if [ "$IS_WIN" -eq 1 ]; then
    echo "运行本插件的 install.ps1（或安装 Node ${NODE_TARGET}：https://volta.sh）"
  else
    echo "运行本插件的 install.sh（或安装 Node ${NODE_TARGET}：https://volta.sh）"
  fi
}

# ── 探测 PATH 之外的「好 node」：仿 launch.cjs candidates 的 Volta/nvm 位置 ──
# 返回 0 表示找到一个 >= NODE_FLOOR 的 node。
has_offpath_good_node() {
  for c in \
    "$HOME"/.volta/tools/image/node/*/bin/node \
    "$HOME"/.volta/bin/node \
    "$HOME"/.nvm/versions/node/*/bin/node \
    /opt/homebrew/bin/node \
    /usr/local/bin/node; do
    [ -x "$c" ] || continue
    m=$("$c" -p "process.versions.node.split('.')[0]" 2>/dev/null) || continue
    [ -n "$m" ] && [ "$m" -ge "$NODE_FLOOR" ] 2>/dev/null && return 0
  done
  return 1
}

RESTART_LINE="修复后请完全退出并重启 Claude Code 会话，再用 /minus。"

NODE_PATH=$(command -v node 2>/dev/null || true)

# ── 分支 1：PATH 上无 node ──
if [ -z "$NODE_PATH" ]; then
  if has_offpath_good_node; then
    # 终端 PATH 没有 node，但 Volta/nvm 里有好的 → 多半是 PATH 没带上 Volta
    cat <<EOF
Minus 服务未就绪：当前 PATH 上找不到 node 命令，但检测到你已装有合格的 Node（Volta/nvm）。
很可能是 shell 的 PATH 没带上 Volta（~/.volta/bin）。请：
  1. 确认 ~/.volta/bin 在 PATH 前（重开终端，或重新执行 Volta 安装脚本）；
  2. 终端里 \`node -v\` 能打印 v${NODE_TARGET}.x 后，重启 Claude Code。
$RESTART_LINE
EOF
  else
    cat <<EOF
Minus 服务未就绪：未检测到 Node。Minus 平台服务需要 Node ${NODE_TARGET}。
请 $(install_hint)，安装完成后重启 Claude Code。
$RESTART_LINE
EOF
  fi
  exit 0
fi

# ── 跑一次 node -v，分离 stdout/stderr 与退出码 ──
ERRF=$(mktemp 2>/dev/null || echo "/tmp/diag-node-err.$$")
VER_OUT=$("$NODE_PATH" -v 2>"$ERRF"); NODE_RC=$?
ERR_OUT=$(cat "$ERRF" 2>/dev/null)
rm -f "$ERRF" 2>/dev/null || true
ERR_FIRST=$(printf '%s\n' "$ERR_OUT" | head -1)

# ── 分支 2：node 坏了（崩溃 / dyld / simdjson）──
# 退出非 0，或 stderr 命中动态库加载失败特征 → 判定为坏 node。
if [ "$NODE_RC" -ne 0 ] || printf '%s' "$ERR_OUT" | grep -Eq 'Library not loaded|dyld|simdjson|image not found'; then
  cat <<EOF
Minus 服务未就绪：检测到 PATH 上的 node 已损坏，无法运行。
  损坏的 node：$NODE_PATH
  错误：${ERR_FIRST:-（node 启动即失败，退出码 $NODE_RC）}

这通常是 Homebrew 的 node 依赖的动态库（如 simdjson）被升级后版本不匹配所致。修复任选其一：
  • 若该 node 来自 Homebrew：\`brew reinstall node@22\`（或对应的 node 公式）重装以重新链接动态库；
  • 推荐改用 Volta 管理 Node ${NODE_TARGET}：\`volta install node@${NODE_TARGET}\`，并确保 ~/.volta/bin 排在 PATH 前，让它压过损坏的 node。
$RESTART_LINE
EOF
  exit 0
fi

# ── node 正常，取主版本 ──
MAJOR=$(printf '%s' "$VER_OUT" | sed -n 's/^v\([0-9][0-9]*\).*/\1/p')

# ── 分支 3：node 过旧 ──
if [ -n "$MAJOR" ] && [ "$MAJOR" -lt "$NODE_FLOOR" ] 2>/dev/null; then
  cat <<EOF
Minus 服务未就绪：当前 node（${NODE_PATH}，${VER_OUT}）版本过旧。Minus 平台服务需要 Node ${NODE_TARGET}。
请升级：$(install_hint)，或 \`volta install node@${NODE_TARGET}\` 并确保它在 PATH 前。
$RESTART_LINE
EOF
  exit 0
fi

# ── 分支 4：node 看似正常 ──
# 终端 node 没问题，但 MCP 仍未就绪——多半是「客户端启动 MCP 用的 PATH ≠ 终端 PATH」。
cat <<EOF
Minus 服务未就绪：当前终端的 node（${NODE_PATH}，${VER_OUT}）看起来正常。请先尝试：
  1. 完全退出 Claude Code（不是新开窗口，是彻底退出进程），再重新打开并用 /minus。

若重启后仍未就绪，可能是客户端启动 MCP 用的 PATH 与终端不同：客户端常以 launchd/login PATH 启动，
那条 PATH 上可能排着一个损坏或过旧的 node（如 /usr/local/bin/node）压过了你终端里的好 node。可：
  • 检查并替换/移除那些系统路径下的旧 node（如 /usr/local/bin/node、/opt/homebrew/bin/node）；
  • 或重跑本插件的 install 脚本，让 Volta 的 Node ${NODE_TARGET} 成为系统级首选。

仍不行，请把上面这段输出发给支持以便排查。
$RESTART_LINE
EOF
exit 0
