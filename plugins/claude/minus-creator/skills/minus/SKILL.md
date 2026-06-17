---
name: minus
description: >
  Minus Skill 项目的会话入口与进度调度。
  "打开 Minus"、"minus"、"进入 Minus"、"我要做一个 Skill"；
  在 Minus 项目目录中："继续"、"接着做"、"做到哪了"、"开始"、
  "现在什么状态"、"帮我启动下"、"启动项目"、"预览一下"、"看看效果"。
when_to_use: >
  用户说"minus"或"打开 Minus"；或在 Minus 项目中表达
  "继续"、"开始"、"做到哪了"等恢复或查看进度意图；
  或在 Minus 项目中要求启动、预览项目。
allowed-tools: Read Write Edit Bash Agent mcp__*
model: inherit
effort: high
---

根据当前状态 Read 同目录下对应的 .md 文件，按其中指令执行。

!`minus-lib project-detector persona`

## 路由

登录态优先复用 SessionStart hook 注入的上下文（形如「登录状态：true」）——会话开头已有就**不要再调 auth_status**（省一次网络往返）。上下文里没有（如 hook 被禁用或长会话已截断）才调用 `mcp__minus-platform__auth_status`。拿到登录态后分发：

| 状态 | Read |
|------|------|
| 未登录 | 用 Skill tool 调用 `minus-auth` 完成登录，成功后按下两行继续分发 |
| 已登录 + 无项目（.minus/skill.json 不存在） | [project-setup.md](project-setup.md) |
| 已登录 + 有项目 | [env-init.md](env-init.md) |

auth_status 不可用时，运行诊断脚本并原样输出 stdout，然后终止：
!`minus-lib diagnose-mcp 2>/dev/null || echo "Minus 服务未就绪，请完全退出并重启 Claude Code 会话后再用 /minus。"`

