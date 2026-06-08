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
  # 自包含 bundle —— .mcp.json 经 launch.cjs 指向它，必须一起同步
  if [ -f "$MCP_SRC/dist/minus-platform.cjs" ]; then
    mkdir -p "$CACHE_DIR/dist"
    cp "$MCP_SRC/dist/minus-platform.cjs" "$CACHE_DIR/dist/minus-platform.cjs"
  fi
  # launcher —— .mcp.json 的 command:"node" 实际跑的是它（跨平台，探测 >=18 node 再跑 bundle）
  if [ -f "$MCP_SRC/launch.cjs" ]; then
    cp "$MCP_SRC/launch.cjs" "$CACHE_DIR/launch.cjs"
  fi
  # 清理旧 unix-only launcher（已被 launch.cjs 取代）
  rm -f "$CACHE_DIR/launch.sh"
  # .mcp.json —— launcher 入口改名后必须同步，否则缓存仍指向旧 /bin/sh launch.sh
  if [ -f "$PLUGIN_SRC/.mcp.json" ]; then
    cp "$PLUGIN_SRC/.mcp.json" "$(dirname "$CACHE_DIR")/../.mcp.json"
  fi
  echo "  ✓ mcp-server: $CACHE_DIR"
done
if ! find "$CLAUDE_DIR/plugins/cache" -path "*/mcp-servers/minus-platform/index.js" -not -path "*/node_modules/*" 2>/dev/null | grep -q .; then
  echo "  ⚠ mcp-server 缓存目录未找到，跳过"
fi

# Plugin source files — 同步到所有缓存目录
find "$CLAUDE_DIR/plugins/cache" -path "*/minus-creator/*/lib" -type d -not -path "*/node_modules/*" 2>/dev/null | while read -r LIB_CACHE; do
  PLUGIN_CACHE="$(dirname "$LIB_CACHE")"

  if [ -d "$PLUGIN_SRC/agents" ]; then
    mkdir -p "$PLUGIN_CACHE/agents"
    cp "$PLUGIN_SRC"/agents/*.md "$PLUGIN_CACHE/agents/"
  fi

  for skill_dir in "$PLUGIN_SRC"/skills/*/; do
    skill_name=$(basename "$skill_dir")
    mkdir -p "$PLUGIN_CACHE/skills/$skill_name"
    cp "$skill_dir"SKILL.md "$PLUGIN_CACHE/skills/$skill_name/SKILL.md"
  done

  cp "$PLUGIN_SRC"/lib/*.sh "$LIB_CACHE/"
  echo "  ✓ plugin cache: $PLUGIN_CACHE"
done

echo ""
echo "同步完成。重启 Claude Code 生效。"
