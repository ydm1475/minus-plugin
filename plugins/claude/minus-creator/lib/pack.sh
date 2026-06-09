#!/bin/bash
# pack.sh
# 打一个可分发的插件 zip：先重建自包含 MCP bundle，再把 marketplace 根目录 claude/ 打包。
# 用法: bash lib/pack.sh [输出目录]   （默认输出到 ~/Desktop）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # .../claude/minus-creator/lib
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"                # .../claude/minus-creator
MARKETPLACE_DIR="$(dirname "$PLUGIN_DIR")"           # .../claude （含 .claude-plugin/marketplace.json）
MCP_DIR="$PLUGIN_DIR/mcp-servers/minus-platform"
OUT_DIR="${1:-$HOME/Desktop}"

GREEN='\033[0;32m'
NC='\033[0m'

# 0. 解析一个 >=20 的 node（build.mjs 是 ESM，老 node 跑不了）。
# 终端 PATH 上可能是被遮挡的老 node（实测 /usr/local/bin/node v13），优先用它，
# 不够新则回退 Volta shim。
node_major_of() { "$1" -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0; }
NODE_BIN="node"
if [ "$(node_major_of node)" -lt 20 ] 2>/dev/null; then
  VOLTA_NODE="${VOLTA_HOME:-$HOME/.volta}/bin/node"
  if [ -x "$VOLTA_NODE" ] && [ "$(node_major_of "$VOLTA_NODE")" -ge 20 ] 2>/dev/null; then
    NODE_BIN="$VOLTA_NODE"
  else
    echo "❌ 未找到 Node >=20（build.mjs 需要）。当前 node $(node -v 2>/dev/null || echo 缺失)。请安装 Node 24（推荐 https://volta.sh）。"
    exit 1
  fi
fi

# 1. 重建自包含 bundle（依赖内联，分发包无需 node_modules）
echo "→ 重建 MCP bundle（$("$NODE_BIN" -v)）..."
( cd "$MCP_DIR" && "$NODE_BIN" build.mjs )

# 2. 取版本号
VER="$("$NODE_BIN" -e "console.log(require('$PLUGIN_DIR/.claude-plugin/plugin.json').version)")"
OUT="$OUT_DIR/minus-creator-v${VER}.zip"

# 3. 打包插件目录（以 minus-creator/ 为根，Claude Code 要求 .claude-plugin/plugin.json 在顶层子目录下）
echo "→ 打包 $OUT ..."
rm -f "$OUT"
( cd "$(dirname "$PLUGIN_DIR")" \
  && zip -rq "$OUT" "$(basename "$PLUGIN_DIR")" \
       -x "*/node_modules/*" -x "*.DS_Store" -x "*/.git/*" )

# 4. 校验：bundle 进包了、node_modules 没进包
if ! unzip -l "$OUT" | grep -q "dist/minus-platform.cjs"; then
  echo "❌ 打包失败：zip 内缺 dist/minus-platform.cjs"
  exit 1
fi
if [ "$(unzip -l "$OUT" | grep -c node_modules)" -ne 0 ]; then
  echo "❌ 打包失败：zip 内混入了 node_modules"
  exit 1
fi

echo -e "${GREEN}✓${NC} 打包完成：$OUT （$(du -h "$OUT" | cut -f1)）"
