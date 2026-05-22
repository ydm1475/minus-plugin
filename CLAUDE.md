# Minus Creator Plugin

Claude Code 插件，帮助 Creator 开发和发布 Minus Skill。

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
- 代码模板 → 定义在 lib/ 的脚本或模板文件中，agent 调用脚本而非自己拼代码
- 提问话术 → 定义在统一的话术表中，agent 引用 key 而非内联文本

### 4. 状态检测必须验证归属

检查状态时不能只看"是否存在"，必须验证"是否属于我"。

- 端口检查 → 验证占用进程的 cwd 是否是当前项目
- 数据恢复 → 验证 userInput 是否已持久化到后端
- 存在 ≠ 属于我

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

## 项目结构

- `plugins/claude/minus-creator/` — 插件主目录
  - `mcp-servers/minus-platform/index.js` — MCP Server（auth、skill、session、file tools）
  - `skills/minus/SKILL.md` — /minus 入口 skill（开发流程指令）
  - `skills/minus-publish/SKILL.md` — /minus publish skill
  - `agents/node-dev.md` — 逐节点开发 agent
  - `agents/skill-guide.md` — 结构设计 agent
  - `lib/` — Shell 工具脚本
  - `bin/minus.sh` — 启动器
- `tests/` — 测试用例
- `References/` — 设计文档
