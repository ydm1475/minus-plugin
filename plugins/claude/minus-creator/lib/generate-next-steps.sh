#!/bin/bash
# generate-next-steps.sh
# scaffold 成功后，输出【命令行(cli)客户端】的"接下来请"引导文案。
# 用法: generate-next-steps.sh "项目文件夹名"
#
# 仅 cli：cd 进项目目录启动 claude + /minus。
# desktop 的引导（含操作截图）改由 MCP 工具 show_onboarding_images 一次性返回，
# 不走本脚本——终端无法内联渲染图片，且要避免引导文案两处重复。
# 客户端分支判定在 SKILL.md（依 detect-client.sh），本脚本只负责 cli 文案。

set -euo pipefail

PROJECT_NAME="${1:-}"
if [ -z "$PROJECT_NAME" ]; then
  echo "错误：缺少项目名称参数" >&2
  echo "用法: generate-next-steps.sh \"项目文件夹名\"" >&2
  exit 1
fi

cat << EOF
项目已创建！接下来请在命令行运行：

\`\`\`bash
cd ~/minus/${PROJECT_NAME} && claude
\`\`\`

启动后说一句 **「开始」**（或输入 **\`/minus\`**）即可进入开发。
EOF
