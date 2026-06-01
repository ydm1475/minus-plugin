#!/bin/bash
# generate-next-steps.sh
# scaffold 成功后，按客户端类型输出"接下来请"的引导文案。
# 用法: generate-next-steps.sh "项目名称"
#
# desktop → 新开对话 + 选择文件夹（带操作图）+ /minus
# cli     → cd 进项目目录启动 claude + /minus
# 两套互斥，只输出与当前客户端匹配的一套。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_NAME="${1:-}"
if [ -z "$PROJECT_NAME" ]; then
  echo "错误：缺少项目名称参数" >&2
  echo "用法: generate-next-steps.sh \"项目名称\"" >&2
  exit 1
fi

CLIENT=$(bash "$SCRIPT_DIR/detect-client.sh")

if [ "$CLIENT" = "desktop" ]; then
  cat << EOF
项目已创建！接下来请：

1. 新开一个对话（操作见下方截图）

2. 选择 **\`~/minus/${PROJECT_NAME}\`** 文件夹作为工作目录（操作见下方截图）

3. 打开后说一句 **「开始」**（或输入 **\`/minus\`**）即可进入开发
EOF
else
  cat << EOF
项目已创建！接下来请在命令行运行：

\`\`\`bash
cd ~/minus/${PROJECT_NAME} && claude
\`\`\`

启动后说一句 **「开始」**（或输入 **\`/minus\`**）即可进入开发。
EOF
fi
