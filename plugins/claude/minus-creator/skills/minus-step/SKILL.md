---
name: minus-step
description: >
  在 Minus Skill 项目中开发或修改某一个指定 pipeline 步骤的具体实现
  （数据需求、处理逻辑、输出定义、界面）。例如"开发步骤 2"、
  "改一下第三步的界面"、"步骤 1 的数据来源换成 XX 接口"、
  "第 2 步的代码有 bug"。
  增删/重排步骤、改输入定义或结果页等结构调整由 minus-structure 处理；
  未指明步骤的"继续开发"由 minus 总入口按进度路由。
when_to_use: >
  用户在 Minus 项目中明确指向某个 pipeline 步骤的实现开发或修改时
allowed-tools: Read Write Edit Bash Skill mcp__*
model: inherit
effort: high
---

## 门禁

先执行：`minus-lib gate`

- `GATE=ok` → 继续
- `GATE=fail` → 按 HINT 行执行对应补救（NOT_LOGGED_IN → Skill tool 调用 minus-auth；NO_PROJECT → Read [../minus/project-setup.md](../minus/project-setup.md)；ENV_NOT_READY → Read [../minus/env-init.md](../minus/env-init.md)），补救完成后重跑 gate，再继续用户原本的意图

## 执行

Read [node-dev.md](node-dev.md)，针对用户指定的步骤，严格按其中四维度流程执行。
