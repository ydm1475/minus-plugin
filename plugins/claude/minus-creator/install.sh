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
claude marketplace add "$MARKETPLACE_DIR" --name "$MARKETPLACE_NAME" 2>/dev/null && \
  echo -e "${GREEN}✓${NC} Marketplace 注册成功" || \
  echo "⚠ Marketplace 注册跳过（可能已存在）"

# 3. 安装插件
echo ""
echo "→ 安装插件..."
claude plugin install "${PLUGIN_NAME}@${MARKETPLACE_NAME}" 2>/dev/null && \
  echo -e "${GREEN}✓${NC} 插件安装成功" || \
  echo "⚠ 插件安装跳过（可能已存在）"

# 4. 安装 MCP Server 依赖
echo ""
echo "→ 安装 MCP Server 依赖..."
PLUGIN_CACHE="$HOME/.claude/plugins/cache/$MARKETPLACE_NAME/$PLUGIN_NAME"
MCP_DIR=$(find "$PLUGIN_CACHE" -path "*/mcp-servers/minus-platform/package.json" -exec dirname {} \; 2>/dev/null | head -1)
if [ -n "$MCP_DIR" ]; then
  cd "$MCP_DIR" && npm install --omit=dev 2>/dev/null && echo -e "${GREEN}✓${NC} MCP Server 依赖已安装"
else
  echo "⚠ MCP Server 目录未找到，跳过依赖安装"
fi

# 5. 完成
echo ""
echo "══════════════════════════════════════"
echo -e "${GREEN}安装完成！${NC}"
echo ""
echo "使用方法："
echo "  1. 重启 Claude Code 会话"
echo "  2. 输入 /minus 开始开发 Skill"
echo "══════════════════════════════════════"
echo ""
