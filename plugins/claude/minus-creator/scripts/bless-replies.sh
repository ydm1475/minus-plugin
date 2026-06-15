#!/bin/bash
# bless-replies.sh — Stop hook 盖章脚本
# 每次 Agent 让渡轮次（Stop 事件）时，把所有 _asked 标记升级为 _replied。
# _replied 存在 = "ask 之后发生过真实用户轮次"，complete 子命令凭此放行。
# 无 .minus/dev-progress 时静默退出，不影响非 Minus 项目会话。

set -euo pipefail

TRACKER_DIR=".minus/dev-progress"

[ -d "$TRACKER_DIR" ] || exit 0

for asked_file in "$TRACKER_DIR"/step_*_*_asked; do
  [ -f "$asked_file" ] || continue
  replied_file="${asked_file%_asked}_replied"
  touch "$replied_file"
done
