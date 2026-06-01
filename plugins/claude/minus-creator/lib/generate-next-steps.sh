#!/bin/bash
# generate-next-steps.sh
# scaffold 成功后，输出"接下来请"引导文案。按客户端类型分支（依 detect-client.sh）：
#   - cli：cd 进项目目录启动 claude + /minus（终端无法渲染图片，纯文案）。
#   - desktop：引导文案 + 两张操作截图的外链（markdown 图片，postimg 不强制下载，
#     用户点一次 Show Image 即可预览）。
# 用法: generate-next-steps.sh "项目文件夹名"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_NAME="${1:-}"
if [ -z "$PROJECT_NAME" ]; then
  echo "错误：缺少项目名称参数" >&2
  echo "用法: generate-next-steps.sh \"项目文件夹名\"" >&2
  exit 1
fi

# 引导截图外链（postimg：不强制下载，桌面端可预览）。
START_IMG="https://i.postimg.cc/vBBxtGWW/start.png"
GUIDE_IMG="https://i.postimg.cc/sxrZtqqq/guide.png"

CLIENT="$(bash "$SCRIPT_DIR/detect-client.sh" 2>/dev/null || echo cli)"

if [ "$CLIENT" = "desktop" ]; then
  cat << EOF
项目已创建！接下来请：

1. 新开一个对话（点击下图可查看操作示意）

![新开对话](${START_IMG})

2. 选择 \`~/minus/${PROJECT_NAME}\` 文件夹作为工作目录（点击下图可查看操作示意）

![选择工作目录](${GUIDE_IMG})

3. 打开后说一句 **「开始」**（或输入 \`/minus\`）即可进入开发
EOF
else
  cat << EOF
项目已创建！接下来请在命令行运行：

\`\`\`bash
cd ~/minus/${PROJECT_NAME} && claude
\`\`\`

启动后说一句 **「开始」**（或输入 \`/minus\`）即可进入开发。
EOF
fi
