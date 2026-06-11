#!/bin/sh
# gate.sh — 子 skill 直达入口的前置门禁（单源，被 minus-step / minus-structure 调用）
# 输出：
#   GATE=ok
#   GATE=fail reason=NOT_LOGGED_IN|NO_PROJECT|ENV_NOT_READY
#   HINT=<给 Agent 转达/执行的中文提示>
# 检查顺序：登录 → 项目 → 环境，命中第一个失败原因即返回。

CRED="$HOME/.minus/credentials.json"
if [ ! -s "$CRED" ] || ! grep -q '"session_id"' "$CRED" 2>/dev/null; then
  echo "GATE=fail reason=NOT_LOGGED_IN"
  echo "HINT=尚未登录 Minus。请用 Skill tool 调用 minus-auth 完成登录，登录后继续当前任务。"
  exit 0
fi

if [ ! -f .minus/skill.json ]; then
  echo "GATE=fail reason=NO_PROJECT"
  echo "HINT=当前目录不是 Minus 项目。请 Read ../minus/project-setup.md 引导选择或创建项目，完成后继续当前任务。"
  exit 0
fi

if [ ! -d node_modules ] || [ ! -d .venv ]; then
  echo "GATE=fail reason=ENV_NOT_READY"
  echo "HINT=项目环境未就绪（依赖未安装或未初始化）。请 Read ../minus/env-init.md 完成环境初始化，完成后继续当前任务。"
  exit 0
fi

echo "GATE=ok"
