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

case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  claude-desktop|vscode|jetbrains)
    echo "PREVIEW_URL=$URL"
    echo "CLIENT=desktop"
    ;;
  *)
    echo "PREVIEW_URL=$URL"
    echo "CLIENT=cli"
    # 打开浏览器的命令按平台选：mac=open，Windows=start（cmd 内建，需经 cmd.exe），Linux=xdg-open。
    case "$(uname -s 2>/dev/null)" in
      Darwin*) open "$URL" 2>/dev/null || echo "OPEN_FAILED" ;;
      MINGW*|MSYS*|CYGWIN*) start "" "$URL" 2>/dev/null || cmd.exe /c start "" "$URL" 2>/dev/null || echo "OPEN_FAILED" ;;
      *) xdg-open "$URL" 2>/dev/null || echo "OPEN_FAILED" ;;
    esac
    ;;
esac
