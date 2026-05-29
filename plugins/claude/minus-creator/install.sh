#!/bin/bash
# Minus Creator Plugin 安装脚本
# 用法: bash install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MARKETPLACE_DIR="$SCRIPT_DIR/plugins/claude"
PLUGIN_NAME="minus-creator"
MARKETPLACE_NAME="minus-plugin"

GREEN='\033[0;32m'
NC='\033[0m'
PLUGIN_ID="${PLUGIN_NAME}@${MARKETPLACE_NAME}"

# 查询插件状态：echo "enabled" / "disabled" / "missing"
plugin_state() {
  claude plugin list --json 2>/dev/null | node -e '
    let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      let arr=[]; try{arr=JSON.parse(s||"[]")}catch{}
      const p=arr.find(x=>x.id===process.argv[1]);
      console.log(!p?"missing":(p.enabled?"enabled":"disabled"));
    });
  ' "$PLUGIN_ID"
}

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Minus Creator Plugin Installer     ║"
echo "╚══════════════════════════════════════╝"
echo ""

# 1. 检测 Claude Code
if ! command -v claude &>/dev/null; then
  echo "❌ 未检测到 Claude Code CLI，请先安装。"
  exit 1
fi
echo -e "${GREEN}✓${NC} 检测到 Claude Code: $(claude --version 2>/dev/null || echo 'unknown')"

# 2. 注册 marketplace（指向解压后的持久目录）
echo ""
echo "→ 注册 marketplace..."
if claude plugin marketplace list 2>/dev/null | grep -q "$MARKETPLACE_NAME"; then
  echo -e "${GREEN}✓${NC} Marketplace 已注册，刷新中..."
  claude plugin marketplace update "$MARKETPLACE_NAME"
else
  claude plugin marketplace add "$MARKETPLACE_DIR"
  echo -e "${GREEN}✓${NC} Marketplace 注册成功"
fi

# 3. 安装并启用插件（区分 未装 / 已装未启用 / 已启用）
echo ""
echo "→ 安装插件..."
case "$(plugin_state)" in
  enabled)
    echo -e "${GREEN}✓${NC} 插件已安装并启用" ;;
  disabled)
    echo "  插件已安装但未启用，启用中..."
    claude plugin enable "$PLUGIN_ID"
    echo -e "${GREEN}✓${NC} 插件已启用" ;;
  *)
    claude plugin install "$PLUGIN_ID"
    echo -e "${GREEN}✓${NC} 插件安装成功" ;;
esac

# 4. 安装 MCP Server 依赖（从插件真实 installPath 推导，而非写死 cache 路径）
echo ""
echo "→ 安装 MCP Server 依赖..."
INSTALL_PATH="$(claude plugin list --json 2>/dev/null | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const p=JSON.parse(s||"[]").find(x=>x.id===process.argv[1]);
    process.stdout.write(p?p.installPath:"");
  });' "$PLUGIN_ID")"
MCP_DIR="$INSTALL_PATH/mcp-servers/minus-platform"
if [ -z "$INSTALL_PATH" ] || [ ! -f "$MCP_DIR/package.json" ]; then
  echo "❌ 未找到 MCP Server 目录（installPath=[$INSTALL_PATH]）。MCP 依赖是必需项，安装中止。"
  exit 1
fi
( cd "$MCP_DIR" && npm install --omit=dev )
echo -e "${GREEN}✓${NC} MCP Server 依赖已安装"

# 5. 校验：插件是否真的被启用（凭实际状态判定，不凭"没报错"）
echo ""
echo "→ 校验安装结果..."
STATE="$(plugin_state)"
if [ "$STATE" != "enabled" ]; then
  echo "❌ 校验失败：${PLUGIN_ID} 当前状态为 [${STATE}]，未处于 enabled。"
  echo "   请检查上面的报错；marketplace 来源目录：$MARKETPLACE_DIR"
  exit 1
fi
echo -e "${GREEN}✓${NC} 已确认插件安装并启用（enabled）"

# 6. 完成
echo ""
echo "══════════════════════════════════════"
echo -e "${GREEN}安装完成！${NC}"
echo ""
echo "使用方法："
echo "  1. 重启 Claude Code 会话"
echo "  2. 输入 /minus 开始开发 Skill"
echo "══════════════════════════════════════"
echo ""
