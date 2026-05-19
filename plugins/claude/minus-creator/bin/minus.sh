#!/bin/bash
# minus.sh
# Minus Creator Plugin 启动器
# 自动启动 Claude Code 并发送初始消息触发 Plugin 流程

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 使用 expect 自动发送第一条消息
if command -v expect >/dev/null 2>&1; then
  expect -c "
    set timeout 30
    spawn claude --plugin-dir \"$PLUGIN_DIR\"
    # 等待 Claude Code 启动完成（匹配提示符或等待几秒）
    sleep 5
    send \"/minus\r\"
    interact
  "
else
  # 没有 expect，提示用户手动输入
  echo "提示：启动后输入 /minus 开始"
  claude --plugin-dir "$PLUGIN_DIR"
fi
