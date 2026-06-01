#!/bin/bash
# uninstall.sh
# 卸载 Minus Creator Plugin 并清理所有缓存

set -e

echo "Minus Creator Plugin 卸载工具"
echo ""

# 1. 卸载插件（通过 CLI）
echo "→ 卸载插件..."
claude plugin uninstall minus-creator@minus-plugin 2>/dev/null && echo "✓ 插件已卸载" || echo "⚠ 插件未安装或已卸载"

# 2. 清理插件缓存（cache + data）
# data 目录命名随版本变过：旧版 minus-creator-inline，新版 minus-creator-minus-plugin。
# 用 glob 一并覆盖，避免漏掉新命名。
echo "→ 清理缓存..."
rm -rf "$HOME/.claude/plugins/cache/minus-plugin"
rm -rf "$HOME"/.claude/plugins/data/minus-creator*
echo "✓ 缓存已清理"

# 3. 移除 marketplace 注册（优先 CLI，CLI 不可用再手动改 known_marketplaces.json）
echo "→ 移除 marketplace 注册..."
if command -v claude >/dev/null 2>&1 && claude plugin marketplace remove minus-plugin >/dev/null 2>&1; then
  echo "✓ Marketplace 注册已移除"
elif [ -f "$HOME/.claude/plugins/known_marketplaces.json" ]; then
  node -e "
    const fs = require('fs'), os = require('os');
    const f = os.homedir() + '/.claude/plugins/known_marketplaces.json';
    const d = JSON.parse(fs.readFileSync(f, 'utf8'));
    if (d['minus-plugin']) { delete d['minus-plugin']; fs.writeFileSync(f, JSON.stringify(d, null, 2)); console.log('✓ Marketplace 注册已移除'); }
    else { console.log('⚠ Marketplace 无注册记录'); }
  " 2>/dev/null || echo "⚠ Marketplace 清理跳过"
else
  echo "⚠ Marketplace 无注册记录"
fi

# 4. 清理旧版 skills/agents 副本
rm -rf "$HOME/.claude/skills/minus" 2>/dev/null
rm -rf "$HOME/.claude/skills/minus-publish" 2>/dev/null
rm -rf "$HOME/.claude/agents/skill-guide.md" 2>/dev/null
rm -rf "$HOME/.claude/agents/node-dev.md" 2>/dev/null
echo "✓ Skills/Agents 副本已清理"

# 5. 清理散落的插件副本 / 解压目录（手动安装或测试时留下的，非正常安装产物）
rm -rf "$HOME/.claude/claude/minus-creator" 2>/dev/null
rmdir "$HOME/.claude/claude" 2>/dev/null || true   # 仅当空时删掉空壳父目录
rm -rf "$HOME/.claude/minus-installer" 2>/dev/null
rm -rf "$HOME/.minus-creator-plugin" 2>/dev/null
# install.sh 把 zip 解压到 ~/.claude-plugins/claude/ 当 marketplace 源（含 minus-creator/
# 与 .claude-plugin/marketplace.json）。子目录名是通用的 "claude"，理论上可能和别处手动
# 解压的内容同居一处，故只删确属 minus 的部分：minus-creator/ 子目录，以及确认 name 为
# minus-plugin 的 marketplace 清单；其余一概不碰，空了才 rmdir。
rm -rf "$HOME/.claude-plugins/claude/minus-creator" 2>/dev/null
MP_JSON="$HOME/.claude-plugins/claude/.claude-plugin/marketplace.json"
if [ -f "$MP_JSON" ] && grep -q '"minus-plugin"' "$MP_JSON"; then
  rm -rf "$HOME/.claude-plugins/claude/.claude-plugin" 2>/dev/null
fi
rmdir "$HOME/.claude-plugins/claude" "$HOME/.claude-plugins" 2>/dev/null || true   # 仅当空时删空壳
echo "✓ 散落副本/解压目录已清理"

echo ""
echo "卸载完成。如需同时清理登录凭证，运行: rm -rf ~/.minus"
