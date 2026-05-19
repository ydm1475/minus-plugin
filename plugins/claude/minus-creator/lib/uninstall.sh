#!/bin/bash
# uninstall.sh
# 卸载 Minus Creator Plugin 及可选清理用户数据

echo "Minus Creator Plugin 卸载工具"
echo ""

# 1. 卸载插件
echo "正在卸载插件..."
claude plugin uninstall minus-creator@minus-plugin 2>/dev/null
echo "✓ 插件已卸载"

# 2. 清理 Claude skills 副本
rm -rf "$HOME/.claude/skills/minus" 2>/dev/null
rm -rf "$HOME/.claude/skills/minus-publish" 2>/dev/null
rm -rf "$HOME/.claude/agents/skill-guide.md" 2>/dev/null
rm -rf "$HOME/.claude/agents/node-dev.md" 2>/dev/null
echo "✓ Skills 和 Agents 副本已清理"

# 3. 可选：清理用户数据
echo ""
read -p "是否删除登录凭证和配置？(~/.minus/) [y/N] " CLEAN_CONFIG
if [ "$CLEAN_CONFIG" = "y" ] || [ "$CLEAN_CONFIG" = "Y" ]; then
  rm -rf "$HOME/.minus"
  echo "✓ ~/.minus/ 已删除"
fi

echo ""
read -p "是否删除所有 Skill 项目？(~/minus/) ⚠️ 不可恢复 [y/N] " CLEAN_PROJECTS
if [ "$CLEAN_PROJECTS" = "y" ] || [ "$CLEAN_PROJECTS" = "Y" ]; then
  rm -rf "$HOME/minus"
  echo "✓ ~/minus/ 已删除"
else
  echo "已保留 ~/minus/ 项目文件"
fi

echo ""
echo "卸载完成。"
