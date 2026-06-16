# Minus Creator Plugin

Claude Code 插件，帮助 Creator 开发和发布 Minus Skill。

## 目标用户

使用本插件的 Creator 大部分是文字工作者，不是程序员。所有面向用户的交互都要以此为前提：

- 不给用户看命令、代码、报错原文；补救操作由 Agent 自动执行
- 提问和说明用业务语言（"收集哪些信息"），不用技术术语（"定义输入 schema"）
- 出问题时直接说"我来修"，而不是让用户做技术判断

## 设计原则

### 1. 能硬编码的别靠 Agent 自觉

自然语言指令 Agent 遵守率不可控。规则越多越分散，遗漏率越高。能用代码/脚本/模板约束的逻辑，不要写在 .md 里等 Agent 自觉执行。

- 流程分支（如"最后一步跳过维度 ④"）→ 在 step-tracker.sh 或流程控制层硬编码
- 代码默认值（如 `confirmedKey` 命名规则）→ 写进代码模板或 SDK 默认值，不靠 Agent 记得加
- 格式约束（如"必须换行"）→ 用结构化模板而非自然语言描述

### 2. 能一次性做的别分步做了再推翻

把"确认意图"和"写代码"分成两个阶段。所有维度的问答只收集意图（不写代码），全部确认完毕后一次性生成代码。避免后面的决策推翻前面的代码。

### 3. 指令单源化：同一规则只定义一次

同一条指令/规则/模板只能有一个权威定义位置，其他文件引用它，不能复制粘贴。否则修改时必然遗漏，多个 agent 各自持有的"副本"逐渐分裂。

- 流程规则 → 定义在一个地方（如 SKILL.md），agent 文件只写"按 SKILL.md 的 XX 章节执行"
- 代码模板 → 定义在 scripts/（或 skill 私有的 skills/\*/scripts/）脚本或模板文件中，agent 调用脚本而非自己拼代码
- 提问话术 → 定义在统一的话术表中，agent 引用 key 而非内联文本

### 4. Plugin 不补偿 Platform（SDK）的职责

遇到问题时先判断该谁修，不要在 Plugin 里打补丁绕过 Platform 的问题。判断标准：**一个修复如果需要"被记住"才能生效，它就放错了位置。**

- 默认值 / 防御性校验 / 类型约束 → Platform（SDK）的职责
- 需要上下文判断的决策（用什么 widget、怎么拆步骤、数据结构选择）→ Plugin 的职责
- Platform 默认行为已经正确的事 → Plugin 里连提都不要提，提了反而诱导 Agent 画蛇添足

归属判定和协商流程详见项目根目录 `CONTRACT.md`。

反模式：在 agent 指令里写"记得加 XX 参数"、"默认值是 XX 别忘了"——这是在用提示词补偿代码缺陷，会积累提示词债务。

### 5. 状态检测必须验证归属

检查状态时不能只看"是否存在"，必须验证"是否属于我"。

- 端口检查 → 验证占用进程的 cwd 是否是当前项目
- 数据恢复 → 验证 userInput 是否已持久化到后端
- 存在 ≠ 属于我

### 6. 系统化工程化解决问题

遇到环境、兼容性、运行时等问题时，**用代码解决，不用文档提醒**。写一个脚本自动探测和适配，比写一段"请确保你的 XX 版本 >= YY"强一百倍。

- 环境差异（Node 版本、PATH 顺序）→ 写脚本自动探测可用版本（如 `scripts/resolve-node.sh`、`launch.cjs`）
- 配置不一致 → 启动时检测并修正，不靠用户手动改 `~/.zshrc`
- 运行时依赖 → 缺什么报明确错误和安装命令，不是静默失败

判断标准：**如果解决方案需要用户读一段文档才能生效，那就不是工程化方案。**

### 7. 前端类型门禁（check-frontend）暂不接成硬门禁

`@minus/*` 的真实类型目前到不了编译期（运行时 JS 由平台动态下发、无本地 `.d.ts`），导致 `check-frontend` / `tsc --noEmit` 在任何真实生成项目上都过不了。因此：

- ⛔ **不要**把 `check-frontend` 接成 `step-done` 的硬门禁——会死锁每一个项目（没有一步能标记完成）。
- 工具保留，等 Platform 侧"类型与运行时 JS 同源、同版本、动态下发"落地、tsc 能拿到真实类型之后，再把它接成硬门禁。
- 原因、Platform 修复方向与判断标准（为什么本地钉死的类型快照都会漂移）→ 详见项目根目录 `CONTRACT.md` 的「`@minus/*` SDK 类型契约」章节，本处不复制。

### 8. 跨平台兼容（Windows + macOS）

插件必须同时在 Windows（MSYS2/Git Bash）和 macOS 上正常工作。所有 Shell 脚本和代码生成都要遵守：

- **路径分隔符**：Shell 脚本中用 `/`（两个系统都认）；Node.js 代码用 `path.join()`，不要硬编码分隔符
- **Shell 语法**：避免 Bash 4+ 特性（关联数组、`${var,,}` 等），Windows Git Bash 只有 Bash 3.2；用 `$(command)` 不用反引号
- **行尾符**：生成的脚本文件用 LF（`\n`），不要 CRLF——MSYS2 的 bash 不认 `\r`
- **命令差异**：`sed -i` 在 macOS 需要 `sed -i ''`，在 Linux/MSYS 不需要；优先用 Node.js 脚本替代 sed 操作
- **路径长度**：Windows 有 260 字符路径限制，避免深嵌套目录结构
- **大小写敏感**：Windows 文件系统不区分大小写，不要靠文件名大小写区分不同文件
- **shebang**：用 `#!/usr/bin/env bash`，不要 `#!/bin/bash`——Windows MSYS2 的 bash 不在 `/bin/`

## 开发规范

### 测试要求

- 每个新需求必须编写对应的测试用例
- MCP Server 新增 tool 时：更新 `tests/mcp-server.test.js` 的 tool 列表断言，并添加网络错误处理测试
- Shell 脚本改动时：更新 `tests/shell-scripts.test.sh`
- 集成流程改动时：更新 `tests/integration.test.js`
- 提交前运行 `bash tests/run-all.sh` 确保全部通过

### 文档要求

- 新增可执行命令时，同步更新 `README.md` 对应段落
- 新增 MCP tool 时，同步更新 `.claude/api/openapi-bundled.yaml`

## 运行测试

```bash
bash tests/run-all.sh                           # 全部测试
node --test tests/mcp-server.test.js             # MCP Server 测试
node --test tests/integration.test.js            # 集成测试
bash tests/shell-scripts.test.sh                 # Shell 脚本测试
```

## 打包可分发安装包

用户要"插件安装包"时，**必须用现成脚本 `minus-lib pack`（即 `plugins/claude/minus-creator/scripts/pack.sh`），不要手搓 tar/zip**。

```bash
minus-lib pack [输出目录]    # 默认输出 ~/Desktop/minus-creator-v<版本>.zip
```

脚本已封装全部正确逻辑：解析 Node>=20 → 重建自包含 MCP bundle（依赖内联，包内无需 node_modules）→ 按 `.claude-plugin/plugin.json` 版本号命名 → 打 marketplace 布局（`.claude-plugin/marketplace.json` + `minus-creator/`，排除 node_modules/.git/.DS_Store/.minus）→ 三道打包后自检（marketplace.json 进包、dist/minus-platform.cjs 进包、node_modules 没混入）。产物是 **.zip**，不是 tgz。

## 项目结构

- `plugins/claude/minus-creator/` — 插件主目录
  - `mcp-servers/minus-platform/index.js` — MCP Server（auth、skill、session、file tools）
  - `skills/minus/` — 总入口 + 状态路由（auth_status 分发、project-setup/env-init/dev-phase 等阶段 .md）
  - `skills/minus-structure/` — 结构设计 skill（structure-design.md、result-design.md）
  - `skills/minus-step/` — 单步骤四维度开发 skill（node-dev.md）
  - `skills/minus-auth/` — 账号会话 skill（auth-flow.md；登录/登出/切号/查状态）
  - `skills/minus-publish/SKILL.md` — /minus publish skill
  - 阶段 .md 单源归属各自 skill，跨 skill 衔接用跨目录 Read 或 Skill tool 调用（不复制内容）
  - `scripts/` — 跨 skill 共享与 hooks/运维 Shell 脚本（含 gate.sh 子 skill 前置门禁）
  - `skills/*/scripts/` — 各 skill 私有脚本（minus-lib 按 glob 统一分发）
  - `bin/minus-lib` — 脚本统一分发器（bin/ 在 Bash PATH 上）
- `tests/` — 测试用例
- `References/` — 设计文档
