---
name: minus
description: >
  Minus Skill 开发环境的总入口。用户说"打开 Minus"、"进入 Minus"、
  "我要开发一个 Skill"、"minus"时触发；在 Minus 项目目录（存在 .minus/skill.json）中，
  用户说"开始"、"继续"、"接着做"、"做到哪了"、"现在什么状态"等开工或查看进度的意图
  而未指明具体对象时也触发。
  用户指定了具体步骤要开发或修改（"开发第 2 步"、"改一下步骤 3"）由 minus-step 处理；
  涉及增删步骤、改输入定义等结构调整由 minus-structure 处理。
when_to_use: >
  用户提到 Minus、想开发 Skill；或当前目录是 Minus Skill 项目
  且用户表达未指明具体对象的"开始/继续"意图时
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

