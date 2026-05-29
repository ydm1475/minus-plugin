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

# MCP Server — 同步到所有缓存目录
MCP_SRC="$PLUGIN_SRC/mcp-servers/minus-platform"
MCP_SYNCED=0
find "$CLAUDE_DIR/plugins/cache" -path "*/mcp-servers/minus-platform/index.js" -not -path "*/node_modules/*" 2>/dev/null | while read -r cached_index; do
  CACHE_DIR="$(dirname "$cached_index")"
  cp "$MCP_SRC/index.js" "$CACHE_DIR/index.js"
  cp "$MCP_SRC/package.json" "$CACHE_DIR/package.json"
  if [ -f "$MCP_SRC/pnpm-lock.yaml" ]; then
    cp "$MCP_SRC/pnpm-lock.yaml" "$CACHE_DIR/pnpm-lock.yaml"
  fi
  # 自包含 bundle —— .mcp.json 经 launch.sh 指向它，必须一起同步
  if [ -f "$MCP_SRC/dist/minus-platform.cjs" ]; then
    mkdir -p "$CACHE_DIR/dist"
    cp "$MCP_SRC/dist/minus-platform.cjs" "$CACHE_DIR/dist/minus-platform.cjs"
  fi
  # launcher —— .mcp.json 的 command 实际跑的是它（探测 >=18 node 再跑 bundle）
  if [ -f "$MCP_SRC/launch.sh" ]; then
    cp "$MCP_SRC/launch.sh" "$CACHE_DIR/launch.sh"
    chmod +x "$CACHE_DIR/launch.sh"
  fi
  echo "  ✓ mcp-server: $CACHE_DIR"
done
if ! find "$CLAUDE_DIR/plugins/cache" -path "*/mcp-servers/minus-platform/index.js" -not -path "*/node_modules/*" 2>/dev/null | grep -q .; then
  echo "  ⚠ mcp-server 缓存目录未找到，跳过"
fi

# Lib scripts — 同步到所有缓存目录
find "$CLAUDE_DIR/plugins/cache" -path "*/minus-creator/*/lib" -type d -not -path "*/node_modules/*" 2>/dev/null | while read -r LIB_CACHE; do
  cp "$PLUGIN_SRC"/lib/*.sh "$LIB_CACHE/"
  echo "  ✓ lib scripts: $LIB_CACHE"
done

echo ""
echo "同步完成。重启 Claude Code 生效。"
