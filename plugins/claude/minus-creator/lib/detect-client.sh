#!/bin/bash
# detect-client.sh
# 检测当前运行在 Desktop 还是 CLI
# Claude Code 暴露 CLAUDE_CODE_ENTRYPOINT 环境变量：cli / claude-desktop / vscode / jetbrains

case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  claude-desktop) echo "desktop" ;;
  vscode|jetbrains) echo "desktop" ;;
  cli) echo "cli" ;;
  *) echo "cli" ;;
esac
