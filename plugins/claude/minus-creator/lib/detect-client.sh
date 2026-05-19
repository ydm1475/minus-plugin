#!/bin/bash
# detect-client.sh
# 检测当前运行在 Desktop 还是 CLI

if [ -n "$CLAUDE_DESKTOP" ] || [ "$TERM_PROGRAM" = "claude-desktop" ]; then
  echo "desktop"
else
  echo "cli"
fi
