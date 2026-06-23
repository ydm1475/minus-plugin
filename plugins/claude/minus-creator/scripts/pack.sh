#!/bin/bash
# pack.sh
# 打一个可分发的插件 zip：先重建自包含 MCP bundle，再把 marketplace 根目录 claude/ 打包。
# 用法: minus-lib pack [输出目录]   （默认输出到 ~/Desktop）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # .../claude/minus-creator/scripts
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"                # .../claude/minus-creator

# 优先从源码目录打包：如果当前工作目录在源码 git 仓库内且结构正确，用源码而非 marketplace 安装目录
if ! git -C "$PLUGIN_DIR" rev-parse --git-dir &>/dev/null; then
  SOURCE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  SOURCE_PLUGIN="${SOURCE_ROOT}/plugins/claude/minus-creator"
  if [ -n "$SOURCE_ROOT" ] && [ -d "$SOURCE_PLUGIN/scripts" ]; then
    echo "→ 检测到源码目录，从源码打包：$SOURCE_PLUGIN"
    PLUGIN_DIR="$SOURCE_PLUGIN"
  fi
fi

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

# 3. 打包 marketplace 布局：.claude-plugin/marketplace.json + minus-creator/。
# install.sh 解压后以解压根为 MARKETPLACE_DIR 执行 marketplace add，
# 缺 marketplace.json 注册必失败——所以它必须进包。
echo "→ 打包 $OUT ..."
rm -f "$OUT"
( cd "$MARKETPLACE_DIR" \
  && zip -rq "$OUT" ".claude-plugin" "$(basename "$PLUGIN_DIR")" \
       -x "*/node_modules/*" -x "*.DS_Store" -x "*/.git/*" -x "*/.minus/*" )

# 4. 校验：marketplace.json、bundle 进包了，node_modules 没进包
if ! unzip -l "$OUT" | grep -q ".claude-plugin/marketplace.json"; then
  echo "❌ 打包失败：zip 内缺 .claude-plugin/marketplace.json（install.sh 注册必需）"
  exit 1
fi
if ! unzip -l "$OUT" | grep -q "dist/minus-platform.cjs"; then
  echo "❌ 打包失败：zip 内缺 dist/minus-platform.cjs"
  exit 1
fi
if [ "$(unzip -l "$OUT" | grep -c node_modules)" -ne 0 ]; then
  echo "❌ 打包失败：zip 内混入了 node_modules"
  exit 1
fi

echo -e "${GREEN}✓${NC} 打包完成：$OUT （$(du -h "$OUT" | cut -f1)）"
