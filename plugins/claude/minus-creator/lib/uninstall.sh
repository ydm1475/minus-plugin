#!/bin/bash
# uninstall.sh
# 卸载 Minus Creator Plugin 并清理所有缓存

set -e

echo "Minus Creator Plugin 卸载工具"
echo ""

# 1. 卸载插件（通过 CLI）
echo "→ 卸载插件..."
claude plugin uninstall minus-creator@minus-plugin 2>/dev/null && echo "✓ 插件已卸载" || echo "⚠ 插件未安装或已卸载"

# 2. 清理插件缓存
echo "→ 清理缓存..."
rm -rf "$HOME/.claude/plugins/cache/minus-plugin"
rm -rf "$HOME/.claude/plugins/data/minus-creator-inline"
echo "✓ 缓存已清理"

# 3. 移除 marketplace 注册
if [ -f "$HOME/.claude/plugins/known_marketplaces.json" ]; then
  node -e "
    const fs = require('fs');
    const f = '$HOME/.claude/plugins/known_marketplaces.json'.replace('\$HOME', require('os').homedir());
    const d = JSON.parse(fs.readFileSync(f, 'utf8'));
    if (d['minus-plugin']) { delete d['minus-plugin']; fs.writeFileSync(f, JSON.stringify(d, null, 2)); console.log('✓ Marketplace 注册已移除'); }
    else { console.log('⚠ Marketplace 无注册记录'); }
  " 2>/dev/null || echo "⚠ Marketplace 清理跳过"
fi

# 4. 清理旧版 skills/agents 副本
rm -rf "$HOME/.claude/skills/minus" 2>/dev/null
rm -rf "$HOME/.claude/skills/minus-publish" 2>/dev/null
rm -rf "$HOME/.claude/agents/skill-guide.md" 2>/dev/null
rm -rf "$HOME/.claude/agents/node-dev.md" 2>/dev/null
echo "✓ Skills/Agents 副本已清理"

echo ""
echo "卸载完成。如需同时清理登录凭证，运行: rm -rf ~/.minus"
