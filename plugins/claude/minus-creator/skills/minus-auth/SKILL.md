---
name: minus-auth
description: >
  管理 Minus 平台的账号会话：登录、退出登录、切换账号、查看当前登录状态。
  例如"登录 Minus"、"Minus 登录"、"退出登录"、"换个账号"、
  "我现在登录的是哪个账号"、"我登录了吗"、"Minus 账号"。
when_to_use: >
  用户意图涉及登录、登出、切换账号或查看登录状态时
allowed-tools: Read Bash mcp__*
model: inherit
effort: medium
---

先调用 `mcp__minus-platform__auth_status` 获取当前登录状态，再按用户意图分支：

| 意图 | 执行 |
|------|------|
| 登录 | 已登录 → 告知当前账号，询问是否切换；未登录 → Read [auth-flow.md](auth-flow.md) |
| 退出登录 | 调用 `mcp__minus-platform__auth_logout`，告知结果 |
| 切换账号 | 先 `auth_logout`，再 Read [auth-flow.md](auth-flow.md) 重新登录 |
| 查登录状态 | 直接输出 auth_status 结果（账号、登录态），不做多余动作 |
| 注册账号 | 告知 Creator：注册请到 Minus 官网完成，这里只能登录已有账号 |

auth_status 不可用时，运行诊断脚本并原样输出 stdout，然后终止：
!`minus-lib diagnose-mcp 2>/dev/null || echo "Minus 服务未就绪，请完全退出并重启 Claude Code 会话后再试。"`
