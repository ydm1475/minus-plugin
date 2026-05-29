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

# 1.5 Node 版本 gate（建议 Node 24）
# MCP server（bundle）与后续 installPath 解析都依赖 node；缺/旧则询问后用 Volta 装 24。
# 复用 bootstrap-env.sh 的 provision_node_via_volta / node_major_ok（NODE_FLOOR=24）。
# ⚠️ 局限：此检查走的是终端 PATH；客户端 spawn MCP 用的是 launchd PATH，二者可能不一致。
#    若装了新 node 但 skill_update 仍连不上，需把客户端 PATH 上的旧 node（如
#    /usr/local/bin/node）也替换/升级掉——那是系统层操作，不在本脚本范围。
source "$SCRIPT_DIR/lib/bootstrap-env.sh"
NODE_MIN=18  # 技术硬下限：MCP server 用到 global fetch，需 Node 18；但对外一律建议 24

node_major() {
  command -v node >/dev/null 2>&1 || { echo ""; return; }
  node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo ""
}

echo ""
echo "→ 检查 Node 版本（建议 Node 24）..."
NMAJ="$(node_major)"
if [ -z "$NMAJ" ] || [ "$NMAJ" -lt "$NODE_MIN" ] 2>/dev/null; then
  if [ -z "$NMAJ" ]; then
    echo "  未检测到 Node.js，建议安装 Node 24（最低 ${NODE_MIN}）。"
  else
    echo "  当前 Node $(node -v 2>/dev/null) 过旧，建议升级到 Node 24（最低 ${NODE_MIN}）。"
  fi
  printf "  是否现在帮你安装 Node 24？[Y/n] "
  read -r ans
  case "$ans" in
    [Nn]*)
      echo "❌ 已取消。请自行安装 Node 24（最低 ${NODE_MIN}，推荐 https://volta.sh）后重跑 install.sh。"
      exit 1 ;;
    *)
      if provision_node_via_volta; then
        echo -e "${GREEN}✓${NC} Node 已就绪（$(node -v 2>/dev/null)，Volta 管理 Node 24）"
      else
        echo "❌ Node 24 自动安装失败。请手动安装 Node 24（推荐 https://volta.sh）后重跑 install.sh。"
        exit 1
      fi ;;
  esac
elif [ "$NMAJ" -lt "$NODE_FLOOR" ] 2>/dev/null; then
  echo -e "${GREEN}✓${NC} Node $(node -v 2>/dev/null) 可用；建议升级到 Node 24 以获得最佳体验。"
else
  echo -e "${GREEN}✓${NC} Node 已就绪（$(node -v 2>/dev/null)）"
fi

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

# 4. 校验 MCP Server 产物（自包含 bundle，依赖已内联，无需 npm install）
echo ""
echo "→ 校验 MCP Server 产物..."
INSTALL_PATH="$(claude plugin list --json 2>/dev/null | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const p=JSON.parse(s||"[]").find(x=>x.id===process.argv[1]);
    process.stdout.write(p?p.installPath:"");
  });' "$PLUGIN_ID")"
MCP_DIR="$INSTALL_PATH/mcp-servers/minus-platform"
if [ -z "$INSTALL_PATH" ] || [ ! -f "$MCP_DIR/dist/minus-platform.cjs" ]; then
  echo "❌ 未找到 MCP Server 产物 dist/minus-platform.cjs（installPath=[$INSTALL_PATH]）。MCP 是必需项，安装中止。"
  exit 1
fi
echo -e "${GREEN}✓${NC} MCP Server 产物就绪"

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
