#!/bin/bash
# port-detector.sh
# 检测可用端口，从 9100 开始递增

START_PORT=${1:-9100}
MAX_PORT=$((START_PORT + 100))

for port in $(seq $START_PORT $MAX_PORT); do
  if ! lsof -i :"$port" >/dev/null 2>&1; then
    echo "$port"
    exit 0
  fi
done

echo "ERROR: 未找到可用端口（$START_PORT-$MAX_PORT 均被占用）" >&2
exit 1
