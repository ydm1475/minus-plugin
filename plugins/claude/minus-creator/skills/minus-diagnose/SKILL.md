---
name: minus-diagnose
description: >
  Minus Skill 项目的故障诊断。用户报告报错、出错、坏了、打不开、预览不对、
  白屏、卡住、怎么不动了、跑不起来等问题症状时触发。
when_to_use: >
  Minus 项目中用户描述故障症状（报错/坏了/打不开/白屏/卡住/跑不起来）
  而未指明具体步骤时
allowed-tools: Read Write Edit Bash Skill mcp__*
model: inherit
effort: high
---

## 0. 适用性判断

先确认当前目录存在 `.minus/skill.json`，或本次对话此前确实在进行 Minus 开发（创建项目、设计结构、开发步骤等）。

两者都不满足（如用户在开发其他项目时说"报错了"）→ 本 skill 不适用：不执行下面任何步骤，直接按普通对话处理用户的报障。**禁止**在此场景引导创建 Minus 项目。

## 1. 结合上下文初判

听用户描述，结合当前对话上下文（刚才在做哪一步、刚执行过什么）形成初步怀疑方向。初判只影响后续修复时先看哪份日志，不替代体检。

特殊分支——平台 MCP 工具（auth_status 等）不可用：执行 `minus-lib diagnose-mcp`，将其输出**原样**展示给 Creator，结束本流程。

## 2. 确定性体检

执行：`minus-lib diagnose`

输出最后一行是机器可读结论 `DIAGNOSE=<code>`，其余行是底层检查脚本的原始输出（含 `HINT=` 补救提示），按下表行动。

## 3. 按结论路由

| DIAGNOSE | 含义 | 行动 |
|----------|------|------|
| `NOT_LOGGED_IN` / `NO_PROJECT` / `ENV_NOT_READY` | 前置条件缺失 | 按透传的 HINT 行执行补救（指引单源于 gate.sh）。例外：`NO_PROJECT` 仅当确认用户在做 Minus 开发才补救，否则回到第 0 步的不适用处理 |
| `DEV_SERVER_DOWN` | dev server 未运行 | 自动执行 `minus-lib resume-env restart`；仍失败则读尾部日志自行修复 |
| `BACKEND_DOWN` | 前端在跑、后端无响应 | 同上：固定重启脚本，仍失败读后端日志自行修复 |
| `PYTHON_DEPS_MISSING` | pipeline 依赖缺失 | 自动修：把缺失包写进 pyproject.toml 并用项目 venv 安装（`uv pip install -e .`），不用系统 python |
| `clean` | 环境全部正常 | 问题在业务代码层：读后端/前端日志定位到具体步骤，路由到 minus-step（指明步骤号）；若是结构层问题路由到 minus-structure |

补救完成后重跑 `minus-lib diagnose` 确认 `DIAGNOSE=clean`，再回到用户原本想做的事。

## 3.5 日志行号不匹配 = 运行时代码过期

dev.log 报错指向某文件第 N 行，但磁盘上该文件第 N 行内容不匹配（已修改或行数偏移）——说明运行中的进程加载的是旧代码，hot reload 未生效。此时：
- **不能以"旧日志"为由忽略**——行号不匹配是 stale runtime 的确定性信号
- 必须确认 reload 成功（日志中出现 "WatchFiles detected changes" + 新 server process started 且无报错），或执行 `minus-lib resume-env restart` 重启
- 确认新代码已加载后再判断问题是否仍存在

## 4. 交互原则

Creator 是非程序员：不展示命令、代码、报错原文；能自动修的直接说"我来修"，修完用业务语言汇报修了什么、现在能不能继续。
