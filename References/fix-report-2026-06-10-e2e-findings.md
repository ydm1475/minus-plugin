# 修复报告：e2e-agent 首跑暴露的 Platform/SIF 侧问题（R1-R4）

> 来源：`tests/e2e-agent/run.sh keyword-to-asin` 首跑（2026-06-10），真实 Agent 驱动全流程 + 真实运行产出 skill。
> Plugin 侧已修项（不在本报告）：MCP `session_create` 端点修正、e2e 模拟用户阶段上下文。
> 本报告为 Plugin 侧单方评估，待 platform-agent 按 CONTRACT 流程做事实对齐与对侧评估。

---

## R1：SIF 接口文档与实现不一致（keywordByCategory 响应字段）

### 问题现象

`get_endpoint_details(keywordByCategory)` 文档声明响应为 `data.keywords[]`；真实调用返回的是 `data.list[]`。Agent 按文档写 `kw_data.get("keywords")` → 永远取空 → 节点运行时报"该类目下未查到相关关键词"。

复现（2026-06-10 实测，经平台网关 `/skill-api/sif` 透传代理；脱离网关可直连 www.sif.com 同路径自行认证）：

```bash
curl -s -X POST "$PLATFORM/skill-api/sif/api/search/external/v2/relevanceScreen/keywordByCategory?country=US" \
  -H "Content-Type: application/json" \
  -H "X-Skill-Api-Key: ska_xxx" -H "X-Workspace-Mode: live" \
  -d '{"categoryId":"18682062011","pageSize":5,"pageNum":1}'
```

实际返回 `data` 下的键为 `total / globalKeywordNum / list`——`data.keywords` 不存在，数据在 `data.list[]`（内层 `keyword`/`topAsin[]` 结构与文档一致，仅外层字段名不符）。而 `get_endpoint_details("keywordByCategory")` 的官方响应示例声明为 `data.keywords[]`。

待 SIF 确认收敛方向：以 `list` 为准修文档，或以 `keywords` 为准修实现。

### Plugin 侧评估

- **结论**：不该我改
- **理由**：接口文档是数据面契约的一部分，由 SIF 侧生成与维护；Plugin 的职责是引导 Agent 按文档写代码（node-dev.md 已要求"禁止凭记忆写"），文档错则按文档写也错。在 Plugin 里教 Agent "keywords 和 list 都试一下"属于用提示词补偿契约缺陷（CLAUDE.md 反模式）
- **对对方的事实假设**：
  1. sif-api-mcp 的端点文档由 SIF 平台侧生成/同步，Plugin 仓库无法修改其内容
  2. 实现以 `data.list[]` 为准，不打算改回 `keywords[]`（若相反，则改实现而非文档）

---

## R2：SDK sif client 缺参数约束防御校验

### 问题现象

Agent 生成代码传 `pageSize: 200`（文档明确上限 100），请求直接打到远端，运行时报 `SifBusinessError: pageSizemust be less than or equal to 100`。问题在开发期完全不可见，到用户真实运行才炸。

### Plugin 侧评估

- **结论**：不该我改
- **理由**：归属判定表第 4 行——防御性校验/类型约束是 Platform（SDK）的职责。"一个修复如果需要被记住才能生效，它就放错了位置"：在 node-dev.md 写"记得 pageSize≤100"正是反模式表第一行
- **方案建议**（供 platform 评估）：sif client 在发请求前按端点参数 schema 校验/钳制，违反时抛带明确字段名和上限的本地错误（fail fast，开发期即可见）
- **对对方的事实假设**：
  1. sif client 源码在 minus_ai_sdk 包内（`minus_ai_sdk/sif/`），platform 可改
  2. SIF 侧可提供（或已有）端点参数约束的机器可读 schema

---

## R3：create-skill 模板 pin 的 SDK wheel 过期（无 LLM 能力）+ 生成项目缺后端 SDK 开发手册

### 问题现象

e2e transcript 中 Agent 明确说"SDK 没有内置 LLM，我会加 anthropic 包调用 Claude"，违反门禁指导（generate-node-code.sh：`LLM_REQUIRED=YES` 时"禁止自行拼接第三方模型调用"）。但 Agent 没说错：

1. 模板 `packages/create-skill/templates/pyproject.toml.tpl:7` pin 的 `minus_ai_sdk_python-0.1.0`（OSS wheel，当日新装即此版本）grep 全包无任何 LLM 能力
2. 生成项目内无后端 SDK 开发手册文件，项目 CLAUDE.md 也未引用——而 plugin 的 node-dev.md:227 要求"必须在后端 SDK 开发手册中查到 SDK 内置 LLM 调用方式后再写代码"，Agent 无手册可查

规则要求用 SDK 内置 LLM ←→ 装出来的 SDK 没有 LLM 且无文档，Agent 被夹在中间必然违规。

### Plugin 侧评估

- **结论**：不该我改（plugin 规则本身正确且已单源化）
- **方案建议**（供 platform 评估，均为配置级改动）：
  1. `pyproject.toml.tpl` 的 wheel 指向含 LLM 能力的新版
  2. 模板携带后端 SDK 开发手册（如 THIRD_PARTY_SKILL_GUIDE.md）并在生成项目 CLAUDE.md 中引用
- **对对方的事实假设**：
  1. 含 LLM 能力的新版 SDK wheel 已发布（需 platform 给出版本号与 OSS 地址；若未发布，本项阻塞在 SDK 发版）
  2. 后端 SDK 开发手册已存在于 platform 侧文档体系，只差随模板分发

---

## R4：GET-only 路由收到 POST 返回 500 而非 405

### 问题现象

`POST /api/me/skills/{skillId}/sessions`（契约中该路径只有 GET）返回 `500 INTERNAL_ERROR`。500 误导调用方以为服务端故障；规范行为是 405 Method Not Allowed，一眼可知"方法用错了"。本次排查 MCP session_create bug 时即被该 500 误导。

复现（2026-06-10 实测，同一路径 GET 返回 200，POST 返回 500，trace id：`AbrumzM2PB0j9w8KN8l9QW`）：

```bash
# 1. 换会话 cookie
SID=$(curl -s -i -X POST "$API_BASE/api/auth/dev-session" \
  -H "Content-Type: application/json" -d '{"apiKey":"mdk_xxx"}' \
  | grep -i 'set-cookie' | sed 's/.*MINUS_AI_SID=\([^;]*\).*/\1/')

# 2. POST 到 GET-only 路径 → 实际 500，预期 405
curl -i -X POST "$API_BASE/api/me/skills/{skillId}/sessions" \
  -H "Content-Type: application/json" -H "Cookie: MINUS_AI_SID=$SID" \
  -d '{"entryParams":{"keyword":"test"}}'

# 对照：同一路径 GET → 200
curl -s -o /dev/null -w "%{http_code}\n" \
  "$API_BASE/api/me/skills/{skillId}/sessions" -H "Cookie: MINUS_AI_SID=$SID"
```

### Plugin 侧评估

- **结论**：不该我改
- **理由**：host 行为异常 → Platform 职责（归属判定表第 1 行）
- **方案建议**：Web 框架路由层全局处理（路径存在但方法不匹配 → 405），预计一处改动
- **对对方的事实假设**：路由框架支持全局 method-not-allowed 处理，无需逐接口修改
- **优先级**：最低（体验问题，不阻塞功能）

---

## 验证方式（R1/R2 落地后）

```bash
bash tests/e2e-agent/run.sh keyword-to-asin
```

预期：H4 逐节点真实执行与 H6 终验不再出现字段名/参数约束类运行时错误（首跑这两类各导致一次 pipeline_error）。
