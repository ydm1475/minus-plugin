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
    open "$URL" 2>/dev/null || echo "OPEN_FAILED"
    ;;
esac
