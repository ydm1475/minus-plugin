#!/bin/bash
# sync-plugin.sh
# 将插件源文件同步到 Claude Code 已安装位置。
#
# 安装位置不硬编码：不同安装通道落盘不同——
#   - 桌面客户端上传 zip → ~/.claude/plugins/marketplaces/local-desktop-app-uploads/<plugin>（无 cache 副本）
#   - claude plugin install → ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>
# 唯一可靠来源是注册表 installed_plugins.json 的 installPath，从那里读。
#
# 注意：不复制 skills/agents 到 ~/.claude/skills、~/.claude/agents ——
# 那会和插件自带的注册形成双份定义（违反指令单源化）。

set -euo pipefail

if [ -n "${1:-}" ] && [ -d "$1/.claude-plugin" ]; then
  PLUGIN_SRC="$(cd "$1" && pwd)"
  shift
else
  PLUGIN_SRC="$(cd "$(dirname "$0")/.." && pwd)"
fi
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REGISTRY="$CLAUDE_DIR/plugins/installed_plugins.json"

# Windows Git Bash 下 node 是原生二进制，读不了嵌在 JS 字符串里的 MSYS 路径
# （/d/a/…）。cygpath -m 转成 D:/… 正斜杠形式，两边通吃。
js_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}
PLUGIN_SRC_JS="$(js_path "$PLUGIN_SRC")"
REGISTRY_JS="$(js_path "$REGISTRY")"

PLUGIN_NAME="$(node -e "console.log(require('$PLUGIN_SRC_JS/.claude-plugin/plugin.json').name)")"

if [ ! -f "$REGISTRY" ]; then
  echo "❌ 未找到插件注册表：${REGISTRY}（Claude Code 是否安装过插件？）"
  exit 1
fi

# 从注册表取本插件所有安装实例的 installPath（可能多通道各装了一份）
INSTALL_PATHS="$(node -e "
  const reg = require('$REGISTRY_JS');
  const paths = Object.entries(reg.plugins || {})
    .filter(([k]) => k.startsWith('$PLUGIN_NAME@'))
    .flatMap(([, v]) => v.map(i => i.installPath))
    .filter(Boolean);
  console.log(paths.join('\n'));
")"

if [ -z "$INSTALL_PATHS" ]; then
  echo "⚠ 注册表中没有 $PLUGIN_NAME 的安装记录，无处可同步。"
  echo "  先安装插件（桌面端上传 zip 或 claude plugin install）后再运行本脚本。"
  exit 1
fi

echo "同步插件: $PLUGIN_SRC"
SYNCED=0
while IFS= read -r DEST; do
  [ -n "$DEST" ] || continue
  if [ ! -d "$DEST" ]; then
    echo "  ⚠ 注册表指向的目录不存在，跳过: $DEST"
    continue
  fi
  # --delete 同步删除源里已移除的文件；node_modules/.minus 是安装侧运行产物，排除且不删
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude=node_modules --exclude=.git --exclude=.minus --exclude=.DS_Store \
      "$PLUGIN_SRC/" "$DEST/"
  else
    # Windows Git Bash 无 rsync：先清掉目标里非运行产物的旧内容（等效 --delete），再 tar 复制
    find "$DEST" -mindepth 1 -maxdepth 1 \
      ! -name node_modules ! -name .minus -exec rm -rf {} +
    (cd "$PLUGIN_SRC" && tar -cf - \
      --exclude=node_modules --exclude=.git --exclude=.minus --exclude=.DS_Store \
      .) | (cd "$DEST" && tar -xf -)
  fi
  echo "  ✓ $DEST"
  SYNCED=$((SYNCED + 1))
done <<< "$INSTALL_PATHS"

if [ "$SYNCED" -eq 0 ]; then
  echo "❌ 没有任何安装位置同步成功。"
  exit 1
fi

echo ""
echo "同步完成（$SYNCED 处）。重启 Claude Code 生效。"
