#!/bin/sh
# resolve-node.sh
#
# 打印一个主版本 >=18 的 node 可执行文件绝对路径（找到 → stdout + exit 0；
# 找不到 → 无输出 + exit 1）。
#
# 为什么需要：客户端/终端 PATH 上常有老 node 排在前面（实测 /usr/local/bin/node
# 有 v12/v13）。任何「在环境 bootstrap 之前就要跑」的 node CLI（如 create-skill，
# 它带 #!/usr/bin/env node，裸调会落到老 node 上崩在 ?? 语法）都该先用本脚本解析出
# 一个够新的 node，再把它的目录前置到 PATH 后调用。
#
# 候选顺序与 mcp-servers/minus-platform/launch.cjs 保持一致：
#   PATH → Volta image 真身 → Volta shim → nvm 最新 → Homebrew → /usr/local
# install.sh 一定会用 Volta 装好 Node 24，故 $HOME/.volta 这条几乎必中。

# 运行时下限单源于 toolchain.sh（同目录）。找不到则兜底 18（与清单一致的安全值）；
# 兜底是为这个「客户端 spawn 时跑、环境未知」的脚本兜底，不靠它常态生效。
RN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -f "$RN_DIR/toolchain.sh" ] && . "$RN_DIR/toolchain.sh"
MIN_MAJOR="${NODE_RUNTIME_FLOOR:-18}"

node_major() {
  "$1" -p "process.versions.node.split('.')[0]" 2>/dev/null
}

CANDIDATES="
$(command -v node 2>/dev/null)
$(ls -t "$HOME"/.volta/tools/image/node/*/bin/node 2>/dev/null | head -1)
$HOME/.volta/bin/node
$(ls -t "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | head -1)
/opt/homebrew/bin/node
/usr/local/bin/node
"

for c in $CANDIDATES; do
  [ -n "$c" ] && [ -x "$c" ] || continue
  m=$(node_major "$c")
  [ -n "$m" ] || continue
  if [ "$m" -ge "$MIN_MAJOR" ] 2>/dev/null; then
    echo "$c"
    exit 0
  fi
done

exit 1
