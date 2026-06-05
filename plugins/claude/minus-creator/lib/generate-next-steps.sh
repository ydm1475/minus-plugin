#!/bin/bash
# generate-next-steps.sh
# scaffold 成功后，输出"接下来请"引导文案。按客户端类型分支（依 detect-client.sh）：
#   - cli：cd 进项目目录启动 claude + /minus（终端无法渲染图片，纯文案）。
#   - desktop：引导文案 + 两张操作截图的外链（markdown 图片，postimg 不强制下载，
#     用户点一次 Show Image 即可预览）。
# 用法: generate-next-steps.sh "项目文件夹名" ["项目真实绝对路径"]
#   第 2 参数 = create-skill 输出的 __CREATE_RESULT__.targetDir（项目真实落地路径）。
#   项目建在 create-skill 运行时的 cwd 下（index.mjs: join(process.cwd(), folder)），
#   不恒等于 ~/minus；自定义目录 / Windows 下 ~/minus 都是错的。缺省才回退 ~/minus/{folder}。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROJECT_NAME="${1:-}"
PROJECT_PATH="${2:-}"
if [ -z "$PROJECT_NAME" ]; then
  echo "错误：缺少项目名称参数" >&2
  echo "用法: generate-next-steps.sh \"项目文件夹名\" [\"项目真实绝对路径\"]" >&2
  exit 1
fi

# 展示路径：优先真实 targetDir，原样显示完整绝对路径（不折叠成 ~）。
# 给用户完整路径，避免 ~ 简写造成歧义、与 CLI 分支的 cd 命令显示不一致。
if [ -n "$PROJECT_PATH" ]; then
  DISPLAY_PATH="$PROJECT_PATH"
else
  DISPLAY_PATH="$HOME/minus/${PROJECT_NAME}"
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

2. 选择 \`${DISPLAY_PATH}\` 文件夹作为工作目录（点击下图可查看操作示意）

![选择工作目录](${GUIDE_IMG})

3. 打开后说一句 **「开始」**（或输入 \`/minus\`）即可进入开发
EOF
else
  # cd 用真实路径并加引号（含空格也安全）；缺省回退 ~/minus（~ 不能加引号，名字单独引）。
  if [ -n "$PROJECT_PATH" ]; then
    CD_CMD="cd \"$PROJECT_PATH\""
  else
    CD_CMD="cd ~/minus/\"${PROJECT_NAME}\""
  fi
  cat << EOF
项目已创建！接下来请在命令行运行：

\`\`\`bash
${CD_CMD} && claude
\`\`\`

启动后说一句 **「开始」**（或输入 \`/minus\`）即可进入开发。
EOF
fi
