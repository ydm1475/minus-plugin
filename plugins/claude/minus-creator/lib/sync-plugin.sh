#!/bin/bash
# sync-plugin.sh
# 将插件源文件同步到 Claude Code 安装目录

PLUGIN_SRC="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "同步插件: $PLUGIN_SRC → $CLAUDE_DIR"

# Skills
for skill_dir in "$PLUGIN_SRC"/skills/*/; do
  skill_name=$(basename "$skill_dir")
  mkdir -p "$CLAUDE_DIR/skills/$skill_name"
  cp "$skill_dir"SKILL.md "$CLAUDE_DIR/skills/$skill_name/SKILL.md"
  echo "  ✓ skill: $skill_name"
done

# Agents
if [ -d "$PLUGIN_SRC/agents" ]; then
  mkdir -p "$CLAUDE_DIR/agents"
  for agent_file in "$PLUGIN_SRC"/agents/*.md; do
    cp "$agent_file" "$CLAUDE_DIR/agents/"
    echo "  ✓ agent: $(basename "$agent_file")"
  done
fi

# Hooks — 不覆盖 settings.json，只提示
echo ""
echo "  ⚠ hooks 和 settings.json 需要手动检查是否同步"

# MCP Server
CACHE_DIR=$(find "$CLAUDE_DIR/plugins/cache" -path "*/minus-creator/*/mcp-servers/minus-platform" -type d 2>/dev/null | head -1)
if [ -n "$CACHE_DIR" ]; then
  cp "$PLUGIN_SRC/mcp-servers/minus-platform/index.js" "$CACHE_DIR/index.js"
  echo "  ✓ mcp-server: minus-platform"
else
  echo "  ⚠ mcp-server 缓存目录未找到，跳过"
fi

# Lib scripts
if [ -n "$CACHE_DIR" ]; then
  LIB_CACHE="$(dirname "$(dirname "$CACHE_DIR")")/lib"
  if [ -d "$LIB_CACHE" ]; then
    cp "$PLUGIN_SRC"/lib/*.sh "$LIB_CACHE/"
    echo "  ✓ lib scripts"
  fi
fi

echo ""
echo "同步完成。重启 Claude Code 生效。"
