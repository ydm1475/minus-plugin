#!/bin/bash
# open-preview.sh
# 根据客户端类型决定是否打开浏览器预览
# 用法: open-preview.sh <port>
#
# Desktop 版：只输出 URL（Desktop 自动弹预览面板）
# CLI 版：用 open 命令打开浏览器

set -euo pipefail

PORT="${1:?用法: open-preview.sh <port>}"
URL="http://localhost:${PORT}"

# 同端口去重：同一项目对同一端口只自动开一次浏览器（标记在 .minus/.preview-opened）。
# 否则每次进会话/每次检测成功都新开一个标签页，反复进出和测试时标签页堆积。
# 端口变化（server 重启换端口）会重新打开；用户手动关掉标签页后同端口不再自动重开（URL 已输出，可手动访问）。
MARKER=""
[ -d "$PWD/.minus" ] && MARKER="$PWD/.minus/.preview-opened"

case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  claude-desktop|vscode|jetbrains)
    echo "PREVIEW_URL=$URL"
    echo "CLIENT=desktop"
    ;;
  *)
    echo "PREVIEW_URL=$URL"
    echo "CLIENT=cli"
    if [ -n "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null || true)" = "$PORT" ]; then
      echo "OPEN_SKIPPED_ALREADY"
      exit 0
    fi
    # 打开浏览器的命令按平台选：mac=open，Windows=start（cmd 内建，需经 cmd.exe），Linux=xdg-open。
    case "$(uname -s 2>/dev/null)" in
      Darwin*) open "$URL" 2>/dev/null || echo "OPEN_FAILED" ;;
      MINGW*|MSYS*|CYGWIN*) start "" "$URL" 2>/dev/null || cmd.exe /c start "" "$URL" 2>/dev/null || echo "OPEN_FAILED" ;;
      *) xdg-open "$URL" 2>/dev/null || echo "OPEN_FAILED" ;;
    esac
    [ -z "$MARKER" ] || echo "$PORT" > "$MARKER"
    ;;
esac
