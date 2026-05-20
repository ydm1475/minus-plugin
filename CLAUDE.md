# Minus Creator Plugin

Claude Code 插件，帮助 Creator 开发和发布 Minus Skill。

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
