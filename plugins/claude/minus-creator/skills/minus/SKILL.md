---
name: minus
description: >
  Minus Skill 开发环境的总入口与状态路由。用户说"打开 Minus"、"进入 Minus"、
  "我要开发一个 Skill"、"minus"时触发；在 Minus 项目目录（存在 .minus/skill.json）中，
  用户说"开始"、"继续"、"接着做"等开工意图而未指明具体对象时也由本 skill
  接管——读取进度状态后路由到对应阶段。也适用于用户想了解项目当前进度的场景。
  指定步骤的实现修改由 minus-step 处理；结构调整由 minus-structure 处理。
when_to_use: >
  用户提到 Minus、想开发 Skill；或当前目录是 Minus Skill 项目
  且用户表达未指明具体对象的"开始/继续"意图时
allowed-tools: Read Write Edit Bash Agent mcp__*
model: inherit
effort: high
---

根据当前状态 Read 同目录下对应的 .md 文件，按其中指令执行。

## 路由

调用 `mcp__minus-platform__auth_status` 检查登录态，然后分发：

| 状态 | Read |
|------|------|
| 未登录 | 用 Skill tool 调用 `minus-auth` 完成登录，成功后按下两行继续分发 |
| 已登录 + 无项目（.minus/skill.json 不存在） | [project-setup.md](project-setup.md) |
| 已登录 + 有项目 | [env-init.md](env-init.md) |

auth_status 不可用时，运行诊断脚本并原样输出 stdout，然后终止：
!`minus-lib diagnose-mcp 2>/dev/null || echo "Minus 服务未就绪，请完全退出并重启 Claude Code 会话后再用 /minus。"`

