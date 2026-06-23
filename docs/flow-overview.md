# Minus Creator 插件全流程技术实现梳理

> 生成日期：2026-06-12。覆盖从用户进入到发布的完整链路。

## 1. 入口与路由

**总入口**：`plugins/claude/minus-creator/skills/minus/SKILL.md`

路由逻辑（按优先级）：

1. 优先读 SessionStart hook 注入的上下文（「登录状态：true」）—— 无需再调 `auth_status`
2. 否则调 MCP tool `auth_status`；诊断失败时 `minus-lib diagnose-mcp` 兜底

| 状态                                      | 路由目标                |
| ----------------------------------------- | ----------------------- |
| 未登录                                    | Skill tool → minus-auth |
| 已登录 + 无项目（无 `.minus/skill.json`） | `project-setup.md`      |
| 已登录 + 有项目                           | `env-init.md`           |

## 2. 账号体系（MCP Server 层）

**实现**：`mcp-servers/minus-platform/index.js`，凭证存 `~/.minus/credentials.json`（api_key、session_id、user_id、api_base 等）。

认证 tools：`auth_dev_session`（API Key 登录，主流程）、`auth_vcode` / `auth_register` / `auth_login`、`auth_status`、`auth_logout`。

会话自愈：API 返回 401 时 MCP Server 自动调 `/api/auth/dev-session` 刷新 session_id 并重试；刷新失败则清凭证提示重登。

登录引导流程在 `skills/minus-auth/auth-flow.md`：欢迎文案 → 等待 API Key → `auth_dev_session` 验证 → 成功保存/失败重试。禁止用 userEmail 等系统信息绕过验证。

## 3. 项目创建与选择（project-setup.md）

- 本地项目列表：`~/.minus/projects.json`（以本地文件系统为准，禁止调 `skill_list`；自动过滤已删除目录）
- 唯一创建入口：`minus-lib run-create-skill <项目名>`
  - 经 `resolve-node.sh` 找 Node >=20，经 `bootstrap-env.sh` 镜像源对齐
  - 对齐 `@minus-ai/create-skill@beta` 到官方版本，执行创建（最多 10 分钟）
  - 产物：平台注册得到 skillId + apiKey；生成项目结构；Python venv + 前端依赖
  - 输出末尾 `__CREATE_RESULT__` JSON
- 创建后自动：`skill_update` 写描述/场景/标签 → `minus-lib generate-next-steps` 输出引导文案

## 4. 环境初始化与 Dev Server（env-init.md）

**一键恢复**：`minus-lib resume-env <desktop|cli>`（`skills/minus/scripts/resume-env.sh`），串联：

1. 本地状态检查（`check-project-state.sh`）→ INITIALIZED / NODE_MODULES / VENV
2. 启动 dev server（`start-dev.sh` 后台）→ PREVIEW_PORT / BACKEND_PORT
3. 健康检查（curl 轮询）→ ENV=ready|failed
4. 进度摘要（读 `.minus/progress.json`）→ PHASE / CURRENT_STEP

缺依赖时输出 `NEED_BOOTSTRAP=1` → 先跑 `minus-lib bootstrap-env`：

- Volta 保证 Node >= 24，pnpm pin 11.4.0，uv 装 Python 3.12（版本单源在 `scripts/toolchain.sh`）
- 国内镜像默认开启（npmmirror + 清华 PyPI），`MINUS_MIRROR=off` 可关；生成项目级 `.npmrc` / `uv.toml`（managed-by: minus，不入库）

`start-dev.sh <backend|frontend|full>`：端口记入 `.minus/dev-ports.json`；复用前验证占用进程 cwd 归属本项目（存在 ≠ 属于我）。

Desktop 与 CLI 分支：Desktop 用 Preview panel（`record-preview-port.sh`）；CLI 后台启动 + 浏览器打开（`detect-preview-port.sh`）。

## 5. 状态路由（dev-phase.md）

进度文件 `.minus/progress.json`（唯一写入入口 `minus-lib update-progress`，禁止手写）：

```json
{ "phase": "designing|developing|testing|ready", "currentStep": 1, "steps": { "1": { "name": "...", "status": "in_progress|completed|pending" } } }
```

状态机：

| 状态 | 条件                          | 去向                                                                                     |
| ---- | ----------------------------- | ---------------------------------------------------------------------------------------- |
| A    | developing 且有未完成步骤     | node-dev.md 继续当前步骤                                                                 |
| B    | developing 且全完成 / testing | 端到端测试                                                                               |
| C    | 测试已通过                    | 提示发布                                                                                 |
| D    | designing                     | structure-design.md                                                                      |
| E    | 无进度                        | structure-design.md（首次：创建 `.minus/initialized` 标记 + `skill_version_get` 读草稿） |

## 6. 结构设计（minus-structure/structure-design.md）

门禁：`minus-lib gate`（登录态 / 项目 / 环境）。

**第一步：确定输入**——输入类型（keyword/asin/file/default/custom）+ 数量（固定追问话术不可改写）+ 提示语；完成后 `minus-lib update-progress init-design`。前端同步更新 main.tsx（onStart、验证函数、输入组件）+ locales + renderHistoryItem 字段。

**第二步：拆解步骤**——确认步骤列表后：

- `skill_update` 把 steps 写到后端
- `minus-lib generate-steps --input-type <type> "步骤1" ...` 生成骨架（pipeline.py 的 `step_N` + main.tsx buildSteps + progress.json 写步骤列表并置 phase=developing），禁止手写骨架

完成后立即 Read node-dev.md，禁止跳过直接改代码。

## 7. 单步骤开发（minus-step/node-dev.md）

**阶段一：四维度收集意图（不写代码）**，Agent 按顺序引导 Creator 确认：

- ① 数据需求：Read main.tsx 确认输入类型 → ToolSearch 发现 MCP → `search_api_docs` / `get_endpoint_details` 查接口 → 通俗语言向 Creator 展示
- ② 处理逻辑：确定性代码（格式化/排序/聚合）vs LLM（分析/摘要/推荐）；记住处理模式 deterministic|llm
- ③ 输出定义：只收集展示意图，禁止自动补展示；最后一步跳过维度 ④
- ④ 用户确认 + 传递数据（仅非最后一步）：confirm 模式 auto|interactive + 传给下一步的数据

**阶段二：一次性生成代码**——门禁 `minus-lib generate-node-code {N} {logic_mode} {confirm_mode}` 输出 GATE_PASSED 才能写；输出 LOGIC_MODE / CONFIRM_MODE / IS_LAST 供生成参考。

代码三层结构：数据获取（确定性 HTTP）→ 数据处理（确定性或 LLM）→ 输出渲染（display + passToNext）。硬规则：

- 每个 API 调用前必须 `get_endpoint_details` 查文档，禁止凭记忆写参数名
- 前端 confirmedKey 与后端 `ctx.last_user_input.get(...)` 字符串完全一致（camelCase）
- 摘要必须来自后端 payload；依赖用户确认结果时追加隐藏 finalize 步骤

生成后：`minus-lib check-python-deps`（缺依赖 Agent 自修）→ 输出测试引导 → `skill_update` 步骤置 completed → `minus-lib update-progress step-done {N}`（最后一步自动 phase=testing）。

## 8. 结果呈现设计（result-design.md）

所有节点开发完成后执行 `minus-lib generate-result-design`：门禁（检查 pipeline.py 中各步骤无骨架占位）→ 从 pipeline.py 提取 payload 全景 → 输出两维度引导（结果摘要 + 下载内容）。

## 9. 发布（minus-publish/SKILL.md）

1. 前置检查：skill.json 存在、已登录、代码完整、依赖完整、编译检查
2. 版本确认：读 `.minus/skill.json` → `skill_version_get` 查后端状态；pending/approved 则告知并结束
3. 打包提交：确认意图后 `skill_version_submit(skillId, projectDir)` —— 内部 zip（排除 node_modules/.git/**pycache**/.venv）+ 上传 + 自动创建 next draft 并更新本地 skill.json
4. 告知「待审核」+ 版本号 + 审核页地址；审核通过后在平台 UI 点「发布」上线

## 10. 支撑机制

- **minus-lib（bin/）**：脚本统一分发器，查找顺序 `scripts/` → `skills/*/scripts/`；自动前置合适版本 Node、处理跨平台路径
- **gate.sh（scripts/）**：子 skill 前置门禁——登录态 → 项目存在 → 环境就绪；输出 `GATE=ok|fail` + HINT 补救提示
- **progress-check.sh**：挂 SessionStart/Stop hook，从硬产物（pipeline.py 骨架占位标记）单向收敛 progress.json，兜底 Agent 漏调
- **契约**：`.claude/api/openapi-bundled.yaml`（REST）、embed-sdk types.ts（iframe）、widget-framework types.ts（Widget）

## 11. 文件系统总览

```
~/.minus/
├── credentials.json          ← 凭证
├── projects.json             ← 本地项目列表
项目目录/
├── .minus/
│   ├── skill.json            ← skillId / version / apiKey
│   ├── initialized           ← 首次进入标记
│   ├── progress.json         ← 进度（update-progress 唯一写入）
│   ├── total-steps
│   ├── dev-progress/         ← 步骤名称、测试确认等标记
│   ├── dev-ports.json        ← dev server 端口
│   └── dev.pid
├── pipeline.py               ← 后端实现（async def step_N）
├── frontend/src/main.tsx     ← 前端 Home + Steps
├── frontend/src/locales/     ← i18n
├── .venv/ + pyproject.toml
└── node_modules/ + package.json
```

## 12. 端到端时序（从零到发布）

```
/minus
 → 登录检查（hook 上下文 / auth_status）
   ├─ 未登录 → minus-auth（API Key → auth_dev_session → 存凭证）
 → 项目检查（projects.json / .minus/skill.json）
   ├─ 无项目 → project-setup（run-create-skill → skill_update → 引导文案）
   └─ 有项目 → env-init（resume-env：状态检查 → bootstrap → dev server → 健康检查）
 → dev-phase 按 progress.json 路由
   ├─ 无进度/设计中 → structure-design（输入定义 → 拆步骤 → generate-steps 骨架）
   ├─ 开发中 → node-dev（四维度收集 → generate-node-code 门禁 → 一次性生成代码
   │            → check-python-deps → skill_update → update-progress step-done）
   ├─ 全部完成 → result-design（结果摘要 + 下载内容）
   ├─ 测试 → 端到端测试通过 → 提示发布
   └─ 发布 → minus-publish（校验 → skill_version_get → skill_version_submit
              → zip 上传 → 待审核 → 平台 UI 发布上线）
```

## 13. 控制面 API 生命周期

```
POST  /api/skills                          → 创建，得 skillId + apiKey + 1.0-alpha.0
GET   /api/skills/{id}/versions/{ver}      → 版本详情（status: draft|pending|approved）
PATCH /api/skills/{id}/versions/{ver}      → 仅 draft 可编辑，否则自动建 next draft
POST  /api/skills/{id}/versions/submit     → zip 提交审核，status→pending
PUT   .../{ver} {status: published}        → 平台 UI 操作发布
```

## 14. 深挖：Dev Server 工作机制

### 14.1 进程结构

全平台统一：`pnpm dev` → `minus-dev --port {{port}}`（platform 侧 dev-vite-plugin/dist/dev.js 编排器）：

```
minus-dev
  ├── cleanupDev()          ← 清理归属本项目的残留（PID 文件 + 按端口兜底；自杀防护：不杀当前进程链）
  ├── writePid()            ← .minus/dev.pid 记录编排器自身 PID（SIGTERM 它会带走所有子进程）
  ├── python -m uvicorn server:app --port {{port}}   ← 后端 FastAPI
  └── vite                  ← 前端；插件启动前在 v4+v6 loopback 双探测选空闲端口（邻居项目占 5173 时自动让位）
```

任一子进程异常退出整体关闭。后台化由 resume-env.sh 做：`nohup bash start-dev.sh full > .minus/dev.log 2>&1 &`。
存量旧项目的 `dev` 仍是 `concurrently` unix-only 形态（Windows 回退走 `dev:win` 别名，start-dev.sh 按 package.json 实际内容判定）。

### 14.2 端口真相链

`.minus/dev-ports.json` 由 **platform 的 Vite 插件**在 `listening` 事件回调里写入真实端口（解决 autoPort 漂移）；插件侧只读。`detect-preview-port.sh` 三层降级：

1. 读 dev-ports.json（轮询 ≤15s，trusted 只验 curl 可达——Desktop Preview 托管的 vite 对 lsof 不可见）
2. `pgrep -f "vite.*$PROJECT_DIR/frontend"` + `lsof -sTCP:LISTEN` 取端口
3. 扫 5173–5180 逐个验证

### 14.3 归属验证与复用

Unix：`lsof -p $pid -d cwd` 取进程 cwd，必须在项目目录内才认/才杀（SIGTERM→5s→SIGKILL）；macOS 非 ASCII 路径需 `printf '%b'` 还原转义。Windows 跳过 cwd 校验，信任 dev-ports.json，用 netstat+taskkill。

`start-dev.sh` 启动前跑 `check-dev-server.sh`：前端口可探 + 后端 curl 2s 可达 → `ALREADY_RUNNING` 复用退出；前端活但后端死报 `BACKEND_DOWN`。resume-env 对后端 curl 轮询 ≤30s，失败输出 `ENV=failed + FAIL_REASON + 日志尾 20 行`。

### 14.4 运行时数据面（platform dev-vite-plugin）

- Vite 代理：`/skill/{skillId}/...` → 本地后端 4001；`/api/...` → Platform 网关（控制面）
- 执行流：前端 iframe 经 embed-sdk postMessage（`{minus:"v1", kind:"req|res|evt"}`）发 `flow.start` → 后端建 session → Pipeline 逐步执行 → **SSE 流**（`.../pipeline/stream`）推状态 → 前端 `state.update` 渲染 → confirm 步骤用户提交驱动下一步
- uvicorn 带 `--reload`，改 pipeline.py 热重载

### 14.5 重启与崩溃恢复

无显式 stop 脚本。重启：`MINUS_DEV_RESTART=1` → minus-dev-cleanup（死 PID 删 pidfile；活 PID SIGTERM→3s→SIGKILL）→ 杀本项目旧 vite → **删 dev-ports.json 防 stale** → 重启。

## 15. 深挖：开发状态记录机制

### 15.1 两层记录 + 自愈器

**第 1 层（事实源，硬产物）**：

- `pipeline.py`：骨架硬编码 `# TODO: 实现「步骤名」` 注释 = 机器可读的"未实现"标记（awk 扫函数体）
- `.minus/dev-progress/`：`step_N_name`（步骤名称）、`final_test_confirmed`（测试确认）、`result_*_confirmed`（结果设计确认）

**第 2 层（缓存）**：`progress.json`，唯一写入器 update-progress.sh（Node 读改写，无锁）：

- `init-design`：phase=designing + designStage=input_done
- `design-done <名>...`：建 steps 表，phase=developing，删 designStage
- `step-done <N>`：标 completed；N==total → phase=testing，否则推进 currentStep
- 硬门禁：step_N 函数体无 `# TODO` 骨架占位，否则 exit 1

**自愈器** progress-check.sh 挂 SessionStart + Stop hook（hooks/hooks.json），单向收敛只升不降：pipeline.py 步骤无骨架占位但 json 没标 → 补标；json 丢失 → 重建（testing/ready 的 phase 保留不降级）；currentStep 重算；全完成且 developing → 推 testing。

### 15.2 冲突裁决

| 场景                            | 赢家                          |
| ------------------------------- | ----------------------------- |
| json 未标完成，硬产物已完成     | 硬产物（自愈补标）            |
| json 已 testing/ready，记录不全 | json（人工确认 phase 不降级） |
| 后端步骤列表 vs 本地            | 本地（后端只存元数据）        |

### 15.3 会话恢复链（"隔天继续"）

```
SessionStart hook：project-detector.sh 注入 <context> + progress-check.sh 自愈
→ minus skill → resume-env.sh 输出：
    ENV=ready PHASE=developing CURRENT_STEP=2 STEPS_DONE=1 STEPS_TOTAL=5
→ dev-phase.md 按字段路由（不自己读 json）→ node-dev.md
→ Agent 检查 pipeline.py 中步骤 2 是否有骨架占位，判断新开发/修改
```

恢复粒度精确到步骤级别，从 pipeline.py 代码状态反推，用户无需复述进度。

### 15.4 已知弱点

update-progress.sh 读改写无文件锁，并发写后者覆盖前者；当前靠自愈器每会话兜底，单用户场景够用，若未来有并行 agent 写进度需加锁。
