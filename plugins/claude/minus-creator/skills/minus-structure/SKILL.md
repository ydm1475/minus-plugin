---
name: minus-structure
description: >
  在 Minus Skill 项目中设计或调整 Skill 的结构：输入定义、步骤结构（增删/合并/重排）、
  结果呈现页。例如"我想重新拆一下步骤"、"帮我加一个步骤"、
  "第 2 步和第 3 步合并"、"输入项多收集一个城市"、"结果页加个图表"、
  "改一下结果页的摘要"。
when_to_use: >
  用户在 Minus 项目中明确谈论输入定义、步骤结构（拆/增/删/合并/重排）
  或结果呈现页等结构层面的调整时
allowed-tools: Read Write Edit Bash Skill mcp__*
model: inherit
effort: high
---

## 门禁

先执行：`minus-lib gate`

- `GATE=ok` → 继续下方路由
- `GATE=fail` → 按输出的 HINT 行执行补救（补救指引单源于 gate.sh），完成后重跑 gate，再继续下方路由

## 路由

| 用户意图 | Read |
|------|------|
| 输入定义、步骤结构的设计或调整（拆/增/删/合并/重排） | [structure-design.md](structure-design.md) |
| 结果呈现页（摘要、下载内容） | [result-design.md](result-design.md) |
