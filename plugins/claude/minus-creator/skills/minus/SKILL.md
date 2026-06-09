---
name: minus
description: >
  Minus Skill 开发环境入口。当用户说"打开 Minus"、"进入开发"、
  "继续开发 Skill"、"我要开发"、"minus"等意图时自动触发。
  当检测到当前目录包含 .minus/skill.json（即处于 Minus Skill 项目目录）时，
  用户说"开始"、"继续"、"接着做"等表示开工的意图也应触发。
when_to_use: >
  用户提到 Minus、Skill 开发；或当前目录是 Minus Skill 项目
  且用户表达"开始/继续"开发的意图时
allowed-tools: Read Write Edit Bash Agent mcp__*
model: inherit
effort: high
---

根据当前状态 Read 同目录下对应的 .md 文件，按其中指令执行。

## 路由

调用 `mcp__minus-platform__auth_status` 检查登录态，然后分发：

| 状态 | Read |
|------|------|
| 未登录 | [auth-flow.md](auth-flow.md) |
| 已登录 + 无项目（.minus/skill.json 不存在） | [project-setup.md](project-setup.md) |
| 已登录 + 有项目 | [env-init.md](env-init.md) |

auth_status 不可用时，运行诊断脚本并原样输出 stdout，然后终止：
!`PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/diagnose-mcp.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname); bash "$PLUGIN_ROOT/lib/diagnose-mcp.sh" 2>/dev/null || echo "Minus 服务未就绪，请完全退出并重启 Claude Code 会话后再用 /minus。"`

