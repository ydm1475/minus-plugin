#!/bin/bash
# context-manager.sh
# PostToolUse hook: 上下文容量检查 + 环境管理触发

ACTION="${1:-check}"
COUNTER_FILE=".minus/session-counter"

case "$ACTION" in
  check)
    mkdir -p .minus 2>/dev/null

    # 递增对话计数器
    if [ -f "$COUNTER_FILE" ]; then
      COUNT=$(cat "$COUNTER_FILE")
      COUNT=$((COUNT + 1))
    else
      COUNT=1
    fi
    echo "$COUNT" > "$COUNTER_FILE"

    # 超过 40 轮 Edit/Write 操作时提醒
    if [ "$COUNT" -ge 40 ]; then
      echo "<context>"
      echo "[上下文检查] 当前 session 已进行较长时间（$COUNT 次文件操作）。"
      echo "如果即将完成一个主要任务节点，建议保存进度并提示 Creator 开启新对话。"
      echo "保存进度命令：PLUGIN_ROOT=\$(find ~/.claude/plugins/cache -path '*/minus-creator/*/lib/progress-saver.sh' -exec dirname {} \\; 2>/dev/null | head -1 | xargs dirname); bash \"\$PLUGIN_ROOT/lib/progress-saver.sh\""
      echo "</context>"
    fi
    ;;

  reset)
    rm -f "$COUNTER_FILE"
    echo "计数器已重置"
    ;;
esac
