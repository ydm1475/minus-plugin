#!/bin/bash
# record-preview-port.sh
# 把 Claude Preview（Desktop 分支 A）返回的前端端口记录到项目 .minus/dev-ports.json。
#
# Preview 托管的 vite 进程对 Bash 环境的 lsof 不可见，且 autoPort 分配的高位端口
# 不在 detect-preview-port.sh 的扫描范围内。把 preview_start 返回的端口写进
# dev-ports.json 后，门禁走方法 1（trusted 来源）即可识别。
#
# 用法: record-preview-port.sh <port>
# 输出: RECORDED frontend=<port>；参数非法时 exit 2

PORT="${1:-}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "用法: record-preview-port.sh <port>（1-65535 的端口号）" >&2
  exit 2
fi

PROJECT_DIR="$(realpath "$(pwd)" 2>/dev/null || pwd -P)"
MINUS_DIR="$PROJECT_DIR/.minus"
mkdir -p "$MINUS_DIR"

# JSON 合并：只更新 frontend 字段，保留 backend 等已有字段
node -e '
const fs = require("fs");
const file = process.argv[1];
const port = parseInt(process.argv[2], 10);
let data = {};
try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
if (typeof data !== "object" || data === null || Array.isArray(data)) data = {};
data.frontend = port;
fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
' "$MINUS_DIR/dev-ports.json" "$PORT" || {
  echo "写入 $MINUS_DIR/dev-ports.json 失败" >&2
  exit 1
}

echo "RECORDED frontend=$PORT"
