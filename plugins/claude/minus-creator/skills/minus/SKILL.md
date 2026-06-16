---
name: minus
description: >
  Minus Skill 开发环境的总入口。仅当用户意图是开发 Minus Skill 时触发。
  触发场景：用户说"打开 Minus"、"进入 Minus"、"我要开发一个 Skill"、"minus"；
  或在 Minus 项目目录（存在 .minus/skill.json）中说"开始"、"继续"、"接着做"、
  "做到哪了"、"现在什么状态"等开工或查看进度的意图而未指明具体对象。
  不触发：通用编程（写 Python、解释代码、git 操作）、
  与 Minus Skill 开发无关的任何请求（天气、部署、注册等）。
  登录登出、查看账号状态由 minus-auth 处理；
  用户指定了具体步骤（"开发第 2 步"）由 minus-step 处理；
  增删步骤、改输入定义等结构调整由 minus-structure 处理。
when_to_use: >
  用户明确提到 Minus 或 Skill 开发；或当前目录是 Minus Skill 项目
  且用户表达未指明具体对象的"开始/继续"意图时。
  不适用于通用编程、登录登出、与 Minus 无关的请求。
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

