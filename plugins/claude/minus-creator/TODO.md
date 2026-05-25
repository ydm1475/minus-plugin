# Minus Creator Plugin — TODO

> 对照最终版本 Creator Journey Flowchart (2026-05-18) 整理
> 最后更新：2026-05-21

---

## 已完成

### Phase 2: 登录
- [x] API Key 登录模式（auth_dev_session MCP tool）
- [x] `credentials.json` 支持 `auth_type` 字段区分 `api_key` / `oauth`

### Phase 3: 创建 Skill 项目
- [x] Plugin 通过 Bash 调用 `create-skill` 完成 scaffold
- [x] scaffold 产物完整：`.minus/skill.json` + `CLAUDE.md` + `pipeline.py` + `server.py` + `frontend/` + `.env.local` + `git init`
- [x] `~/.minus/projects.json` 项目注册表（增删查 + last_opened 排序 + 自动清理已删除目录）
- [x] scaffold 完成后自动注册到 projects.json

### Phase 4: 进入开发环境
- [x] 首次进入项目时自动 `npm install` + `uv pip install`
- [x] 首次进入生成 Skill 初始页面 + 自动打开预览
- [x] 就绪报告对接后端 API（skill_list 读取 Skill 信息）
- [x] 端口检查：先检测再决定是否启动 dev server

### Phase 5: Skill 开发
- [x] 三步法结构设计（输入→步骤→输出）
- [x] 逐节点四维度开发（数据需求→处理逻辑→输出定义→用户确认）
- [x] 智能合并维度（Creator 一句话覆盖多个维度时合并推进）
- [x] 最后一步自动跳过第④维度
- [x] 数据需求自动查 MCP，不先问 Creator
- [x] 指令单源化：project-detector 只放即时动作，对话逻辑统一由 SKILL.md 驱动

### 平台功能
- [x] 数据服务商 MCP 集成（sif-api-mcp，type: http）
- [x] create-skill npm 脚手架包（已 npm link）

### 其他
- [x] detect-client.sh 用 CLAUDE_CODE_ENTRYPOINT 检测客户端类型
- [x] generate-steps.sh 正则修复（支持函数体有额外变量）
- [x] validateAsins / validateKeywords 支持 min/max 参数
- [x] keyword 模板默认用 textarea + 回车提交

---

## 待完成

### Phase 5: Skill 开发
- [ ] 5.3 结果呈现设计（四维确认：结果数据 / 摘要 / 预览 / 下载）
- [ ] 5.4 生成 output_schema 写入后端（v1 预留，低优先级）

### Phase 6: 发布上线
- [ ] 8 项发布前校验（skill.json 格式 / 必填字段 / 输入定义 / 步骤完整性 / 结果呈现 / 依赖一致性 / 端到端验证 / 版本号）
- [ ] 打包为 `.skill` 文件
- [ ] 上传到平台 + 审核状态查询
- [ ] 预览版测试 → 正式发布的完整流程

### 守护能力
- [ ] #2 自动环境管理：PostToolUse hook 集成文件变更检测 → 自动 npm install + 重启 dev server
- [ ] #3 上下文窗口管理：与 progress-saver 联动，通过平台 API 获取步骤状态
- [ ] #4 Git 无感管理：自动 commit（完成步骤时）、自动 tag（发布前）、保存点展示、回退能力
- [ ] #5 依赖与环境自动修复：npm install 失败重试、版本冲突处理、错误信息转译
- [ ] #6 错误诊断与恢复：白屏检测、构建错误自动修复、端口冲突自动处理

### 平台功能
- [ ] OAuth 2.0 PKCE 流程（Skill 本地调试时的 OAuth 认证）
- [ ] widget-framework URL 回退 bug（FlowApp pushState 丢 query 参数）
- [ ] sif-api-mcp 自动激活：HTTP 类型 MCP 不会随插件自动安装，用户需手动点 Install。改为本地 stdio proxy 包装远程 HTTP 端点，使其与 minus-platform 一样自动生效

### 技术债
- [ ] MCP Server `server.tool()` 迁移到新签名（当前使用已弃用 API）
- [ ] `file_upload` tool 的 FormData 处理在 Node.js 环境验证
- [ ] 错误处理细化（区分网络错误 vs API 错误）
- [ ] 请求重试机制（网络抖动场景）
