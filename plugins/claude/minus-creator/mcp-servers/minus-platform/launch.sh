#!/bin/sh
# minus-platform MCP launcher
#
# 为什么需要它：客户端 spawn MCP 时用的是 launchd/login PATH，老 node 可能排在新
# node 前面遮挡它（实测有人 /usr/local/bin/node 是 v13，压过 Volta 的 24）。直接
# command:"node" 会被老 node 接管 → bundle 自检退出 → 工具不可用。
#
# 这里不依赖 PATH 顺序：按已知位置主动探测一个 >=18 的 node 来跑 bundle。install.sh
# 一定会用 Volta 装好 Node 24，所以 $HOME/.volta 这条几乎必中，用户装完即用。
#
# 只用 /bin/sh（系统永远有）。文案口径与 build.mjs banner 一致：以「建议 Node 24」
# 为主，18 仅技术兜底（global fetch 需要 18）。

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUNDLE="$DIR/dist/minus-platform.cjs"

# 版本下限/推荐口径单源于 lib/toolchain.sh（相对本脚本固定为 ../../lib，源码与缓存
# 布局一致）。找不到则兜底——本脚本在客户端 spawn 时跑、环境未知，兜底保证不致崩。
TOOLCHAIN="$DIR/../../lib/toolchain.sh"
[ -f "$TOOLCHAIN" ] && . "$TOOLCHAIN"
MIN_MAJOR="${NODE_RUNTIME_FLOOR:-18}"
NODE_RECO="${NODE_TARGET:-24}"

# 取某个 node 可执行文件的主版本号（取不到则空）
node_major() {
  "$1" -p "process.versions.node.split('.')[0]" 2>/dev/null
}

# 候选 node，按优先级：
#   1. PATH 上的 node（尊重用户自己装的，够新就用）
#   2. Volta image 真身二进制（不依赖 VOLTA_HOME/shim，最稳）
#   3. Volta shim
#   4. nvm 最新
#   5. Homebrew / /usr/local
CANDIDATES="
$(command -v node 2>/dev/null)
$(ls -t "$HOME"/.volta/tools/image/node/*/bin/node 2>/dev/null | head -1)
$HOME/.volta/bin/node
$(ls -t "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | head -1)
/opt/homebrew/bin/node
/usr/local/bin/node
"

PICKED=""
for c in $CANDIDATES; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  m=$(node_major "$c")
  [ -n "$m" ] || continue
  if [ "$m" -ge "$MIN_MAJOR" ] 2>/dev/null; then
    PICKED="$c"
    break
  fi
done

if [ -z "$PICKED" ]; then
  echo "[minus-platform] 建议使用 Node ${NODE_RECO}（最低 $MIN_MAJOR）。未在常见位置找到符合要求的 node，请安装 Node ${NODE_RECO}（推荐 https://volta.sh）后重启 Claude Code。" >&2
  exit 1
fi

exec "$PICKED" "$BUNDLE"
