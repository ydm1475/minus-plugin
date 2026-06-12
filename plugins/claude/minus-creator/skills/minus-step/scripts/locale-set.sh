#!/bin/bash
# locale-set.sh
# locale JSON 文件的安全增删改入口。Agent 禁止用 Edit 直接改 locale 文件——
# 人工测试 612 中手工编辑把两个 key 挤到了同一行，格式被改坏。
#
# 用法:
#   locale-set.sh set <file> <key> <value>   — 新增或更新一个 key
#   locale-set.sh rm  <file> <key>           — 删除一个 key
#
# 始终经 JSON.parse/stringify 读写，保证格式合法、缩进统一（2 空格）。

set -euo pipefail

ACTION="${1:?用法: locale-set.sh <set|rm> <file> <key> [value]}"
FILE="${2:?缺少 locale 文件路径}"
KEY="${3:?缺少 key}"

if [ ! -f "$FILE" ]; then
  echo "错误：locale 文件不存在：${FILE}" >&2
  exit 1
fi

case "$ACTION" in
  set)
    # value 允许为空字符串，但必须显式传入
    if [ $# -lt 4 ]; then
      echo "用法: locale-set.sh set <file> <key> <value>" >&2
      exit 1
    fi
    VALUE="$4"
    # key/value 走环境变量传入 node，避免 shell 内插破坏 JSON（同 update-progress.sh 约定）
    L_FILE="$FILE" L_KEY="$KEY" L_VALUE="$VALUE" node -e '
      const fs = require("fs");
      const file = process.env.L_FILE;
      const obj = JSON.parse(fs.readFileSync(file, "utf8"));
      obj[process.env.L_KEY] = process.env.L_VALUE;
      fs.writeFileSync(file, JSON.stringify(obj, null, 2) + "\n");
    '
    echo "✓ ${KEY} 已写入 ${FILE}"
    ;;
  rm)
    L_FILE="$FILE" L_KEY="$KEY" node -e '
      const fs = require("fs");
      const file = process.env.L_FILE;
      const obj = JSON.parse(fs.readFileSync(file, "utf8"));
      if (!(process.env.L_KEY in obj)) process.exit(2);
      delete obj[process.env.L_KEY];
      fs.writeFileSync(file, JSON.stringify(obj, null, 2) + "\n");
    ' || { echo "错误：${FILE} 中不存在 key ${KEY}" >&2; exit 1; }
    echo "✓ ${KEY} 已从 ${FILE} 删除"
    ;;
  *)
    echo "用法: locale-set.sh <set|rm> <file> <key> [value]" >&2
    exit 1
    ;;
esac
