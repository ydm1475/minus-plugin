---
name: minus-step
description: >
  在 Minus Skill 项目中开发或修改某一个指定步骤的具体实现
  （数据需求、处理逻辑、输出定义、界面）。用户指明了步骤编号或名称时触发，
  例如"开发步骤 2"、"改下第二步"、"第三步的界面调一下"、
  "第 1 步的数据来源换成 XX 接口"、"第 2 步有 bug"、"第三步有问题"。
when_to_use: >
  用户在 Minus 项目中明确指向某个 pipeline 步骤的实现开发或修改时
allowed-tools: Read Write Edit Bash Skill mcp__*
model: inherit
effort: high
---

## 执行

Read [node-dev.md](node-dev.md)。

先判断用户指定的步骤是**新开发**还是**修改已完成步骤**：

```bash
minus-lib step-tracker status <step_number>
```

- **四维度均未完成** → 新开发：先跑门禁（`minus-lib gate`，`GATE=fail` 时按 HINT 补救后重跑），然后按 node-dev.md 四维度流程执行
- **四维度已全部或部分完成** → 修改场景：跳过门禁，按 node-dev.md「修改已完成步骤的处理逻辑」执行
