# Minus Creator Plugin — TODO

> 对照最终版本 Creator Journey Flowchart (2026-05-18) 整理

---

## 与最终版本的差距（按 Phase 排序）

### Phase 2: 登录
- [ ] 新增 API Key 登录模式（Founding Creator 阶段，粘贴 API Key 即可）
- [ ] `credentials.json` 支持 `auth_type` 字段区分 `api_key` / `oauth`
- [ ] MCP Server 新增 `auth_apikey` tool（验证 API Key → 写入凭证）

### Phase 3: 创建 Skill 项目
- [ ] Plugin 内部通过 Bash 调用 `npx create-skill` 完成 scaffold（体验连贯，Creator 无感知）
- [ ] scaffold 产物：`.minus.json` + `CLAUDE.md` + `package.json` + `.gitignore` + `assets/` + `tests/` + `git init`
- [ ] 实现 `~/.minus/projects.json` 项目注册表（增删查 + last_opened 排序）
- [ ] scaffold 完成后自动注册到 projects.json

### Phase 4: 进入开发环境
- [ ] 首次进入项目时自动 `npm install`（检测无 node_modules/）
- [ ] 首次进入生成 Skill 初始页面 + 自动打开预览
- [ ] 就绪报告对接后端 API（读取 Skill 信息 + 步骤状态）

### Phase 5: Skill 开发
- [ ] 5.3 结果呈现设计（四维确认：结果数据 / 摘要 / 预览 / 下载）— 需加入 node-dev Agent 或新增 Agent
- [ ] 5.4 生成 output_schema 写入后端（v1 预留，低优先级）

### Phase 6: 发布上线
- [ ] 8 项发布前校验（.minus.json 格式 / 必填字段 / 输入定义 / 步骤完整性 / 结果呈现 / 依赖一致性 / 端到端验证 / 版本号）
- [ ] 打包为 `.skill` 文件
- [ ] 上传到平台 + 审核状态查询
- [ ] 预览版测试 → 正式发布的完整流程

---

## 阶段 D：守护能力精细化

### 守护能力 #2：自动环境管理（部分完成）
- [ ] PostToolUse hook 集成文件变更检测（拿到实际被修改的文件路径 → 传给 env-manager.sh）
- [ ] 自动 `npm install` + 重启 dev server 完整流程
- [ ] 服务就绪检测（轮询健康检查端点）

### 守护能力 #3：上下文窗口管理（部分完成）
- [ ] 与 `progress-saver.sh` 联动，通过平台 API 获取步骤状态
- [ ] 更智能的切换时机判断（任务完成度 + 轮次）

### 守护能力 #4：Git 无感管理（未实现）
- [ ] 自动 commit（完成步骤时静默保存）
- [ ] 自动 tag（发布前）
- [ ] "保存点"展示（业务语言，非 Git 术语）
- [ ] 回退能力（Creator 说"恢复到之前的版本"）

### 守护能力 #5：依赖与环境自动修复（未实现）
- [ ] npm install 失败自动重试和修复（--legacy-peer-deps 等）
- [ ] 版本冲突自动处理
- [ ] 通俗语言错误信息转译

### 守护能力 #6：错误诊断与恢复（未实现）
- [ ] 预览监控（白屏检测）
- [ ] 构建错误自动修复（语法错误、导入错误）
- [ ] 端口冲突自动处理
- [ ] 与 Git 无感管理联动的回退兜底

---

## 平台功能

### 数据服务商 MCP 集成
- [ ] 开发阶段通过 MCP 查询数据服务商 API 目录
- [ ] 帮 Creator 发现可用 API → 生成确定性调用代码
- [ ] 参考 Technical Architecture.md §3.3

### OAuth 2.0 PKCE 流程
- [ ] Skill 本地调试时的 OAuth 认证（client_id = skill_id, client_secret = api_key）
- [ ] 对接 `/oauth/authorize` 和 `/oauth/token` 端点

### Codex 适配层
- [ ] 业务逻辑与平台能力分离的 Adapter 模式
- [ ] 等 Codex 能力明确后再做

### create-skill npm 脚手架包
- [ ] 独立 npm 包（`npx create-skill`）
- [ ] 生成 .minus.json、CLAUDE.md、package.json、.gitignore、assets/、tests/、git init
- [ ] Plugin 通过 Bash tool 内部调用 `npx create-skill`，Creator 无感知（方案 1）

---

## 技术债

- [ ] MCP Server `server.tool()` 迁移到新签名（当前使用已弃用 API）
- [ ] `file_upload` tool 的 FormData 处理在 Node.js 环境验证
- [ ] 错误处理细化（区分网络错误 vs API 错误）
- [ ] 请求重试机制（网络抖动场景）
