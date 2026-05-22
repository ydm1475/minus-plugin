# Minus Creator Plugin — 技术架构

> Plugin 的技术实现方案。基于 Claude Code 原生 Plugin 体系，后续适配 Codex。
>
> **关联文档：**
> - 产品体验流程：[8 - Install & Init.md](8%20-%20Install%20%26%20Init.md)、[9 - Dev & Publish.md](9%20-%20Dev%20%26%20Publish.md)
> - Minus 平台 API 规格：待后端团队补充

---

## 1. 架构概览

### 1.1 Plugin 在 Claude Code 中的位置

```
┌─────────────────────────────────────────────────┐
│                  Claude Code                     │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  Skills   │  │  Hooks   │  │    Agents    │  │
│  │ /minus    │  │ Session  │  │  skill-guide │  │
│  │ /minus    │  │ Start    │  │  node-dev    │  │
│  │  publish  │  │ ToolUse  │  │              │  │
│  └──────────┘  └──────────┘  └──────────────┘  │
│        │              │              │           │
│        └──────────────┼──────────────┘           │
│                       │                          │
│              ┌────────▼────────┐                 │
│              │   MCP Server    │                 │
│              │ (Minus API 集成) │                 │
│              └────────┬────────┘                 │
│                       │                          │
└───────────────────────┼──────────────────────────┘
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
   Minus Platform   Data Provider   Data Provider
       API           MCP (dev)       MCP (dev)
   (登录/发布)       (API 发现)      (API 发现)
```

### 1.2 核心设计原则

| 原则 | 说明 |
|------|------|
| **开发阶段 MCP，运行阶段直调** | Plugin 通过 MCP 帮 Creator 发现可用 API；生成的 Skill 代码直接调用 API，不依赖 MCP |
| **确定性数据获取，可选 LLM 处理** | 数据获取和基础处理是确定性代码；数据分析和摘要可接入 LLM |
| **Claude Code 原生优先** | 基于 Claude Code Plugin 体系实现，预留 Codex 适配层 |
| **技术复杂度 Plugin 吸收** | Creator 无需理解底层技术，Plugin 封装所有技术细节 |

### 1.3 组件清单

| 组件 | 类型 | 职责 |
|------|------|------|
| `/minus` | Skill | 主入口，项目检测与引导 |
| `/minus publish` | Skill | 发布流程 |
| `SessionStart` hook | Hook | 打开项目文件夹时输出轻量提示（不自动执行流程） |
| `PostToolUse` hook | Hook | 上下文容量检查 |
| `minus-platform` | MCP Server | Minus 平台 API（登录、发布、上传） |
| `skill-guide` | Agent | 结构设计多轮引导 |
| `node-dev` | Agent | 逐节点开发引导 |

---

## 2. Plugin 目录结构

```
minus-creator-plugin/
├── .claude-plugin/
│   └── plugin.json                  # 插件元数据与身份声明
│
├── skills/
│   ├── minus/
│   │   └── SKILL.md                 # /minus 主入口（进入项目、日常引导）
│   └── minus-publish/
│       └── SKILL.md                 # /minus publish 发布流程
│
├── agents/
│   ├── skill-guide.md               # 结构设计引导（4.1 三步法）
│   └── node-dev.md                  # 逐节点开发引导（4.2 四维度）
│
├── hooks/
│   └── hooks.json                   # 生命周期事件配置
│
├── mcp-servers/
│   ├── minus-platform/              # Minus 平台 API 服务
│   │   ├── index.js                 # MCP Server 入口
│   │   └── package.json
│   └── ...
│
├── templates/
│   ├── minus-json.template           # .minus.json 初始模板
│   ├── claude-md.template           # CLAUDE.md 初始模板
│   ├── initial-page.template        # 初始页面模板
│   └── step.template                # 步骤文件模板
│
├── lib/
│   ├── context-manager.sh           # 上下文容量检查脚本
│   ├── port-detector.sh             # 可用端口检测脚本
│   ├── project-detector.sh          # 项目状态检测脚本
│   └── progress-saver.sh            # 进度保存到 Memory 脚本
│
├── .mcp.json                        # MCP Server 注册配置
├── settings.json                    # 默认权限与设置
└── README.md
```

### 2.1 plugin.json

```json
{
  "name": "minus-creator",
  "description": "Minus Skill 开发平台 — 帮助 Creator 构建、测试和发布 Skill",
  "version": "1.0.0",
  "author": {
    "name": "Minus Team",
    "url": "https://minusai.com"
  },
  "homepage": "https://developers.minusai.com",
  "repository": "https://github.com/minus-ai/creator-plugin",
  "license": "MIT"
}
```

### 2.2 .mcp.json

```json
{
  "minus-platform": {
    "command": "node",
    "args": ["./mcp-servers/minus-platform/index.js"],
    "env": {
      "MINUS_API_BASE": "https://api.minusai.com/v1"
    }
  }
}
```

### 2.3 settings.json

```json
{
  "permissions": {
    "allow": [
      "Read",
      "Write",
      "Bash(node *)",
      "Bash(npm *)",
      "Bash(curl *)",
      "Bash(lsof -i *)",
      "mcp__minus-platform__*"
    ]
  }
}
```

---

## 3. 组件详解

### 3.1 Skills — 用户入口

#### /minus 主入口

```markdown
# skills/minus/SKILL.md
---
name: minus
description: >
  打开 Minus 开发环境。当用户说"打开 Minus"、"进入开发"、
  "继续开发 Skill"、"我要开发"等意图时自动触发。
  当检测到当前目录包含 .minus.json 时也建议触发。
when_to_use: >
  用户提到 Minus、Skill 开发、或当前目录是 Minus Skill 项目时
allowed-tools: Read Write Bash(node *) Bash(npm *) mcp__minus-platform__*
model: inherit
effort: high
---

你是 Minus Creator Plugin，帮助 Creator 开发和发布 Skill。

## 进入项目检查

1. 检查当前目录是否有 `.minus.json`
   !`ls .minus.json 2>/dev/null && echo "FOUND" || echo "NOT_FOUND"`

2. 检查 Memory 中是否有未完成的进度
   !`ls .claude/memory/minus-progress.md 2>/dev/null && cat .claude/memory/minus-progress.md || echo "NO_PROGRESS"`

## 行为规则

- 如果 .minus.json 存在且有进度记录：恢复上次进度，告诉 Creator 上次做到哪了
- 如果 .minus.json 存在但无进度：进入日常开发模式
- 如果 .minus.json 不存在但在 ~/minus/ 下：引导创建新 Skill（Phase 2）
- 如果不在 ~/minus/ 下：提示 Creator 先进入 Minus 工作目录

## 交互准则

- 零技术门槛：不使用任何技术术语
- 逐步引导：一次只问一个问题，确认后再问下一个
- 双触发：告知 Creator 可以用自然语言或斜杠命令
```

#### /minus publish 发布入口

```markdown
# skills/minus-publish/SKILL.md
---
name: minus-publish
description: >
  发布 Skill 到 Minus 平台。当用户说"帮我发布"、"发布上线"、
  "publish"、"上线"等意图时触发。
when_to_use: >
  用户想要发布当前 Skill 到 Minus 平台时
allowed-tools: Read Write Bash(node *) mcp__minus-platform__*
model: inherit
effort: high
---

执行发布流程（详见 9 - Dev & Publish 的 Phase 5）：

1. 读取 .minus.json 和后端数据，执行发布前校验
2. 端到端运行 pipeline 验证
3. 询问版本号（对比已发布版本，不允许回退）
4. 打包并上传至 Minus 平台

当前项目状态：
!`cat .minus.json 2>/dev/null || echo ".minus.json NOT FOUND"`

已发布的最新版本：
!`cat .minus/published-version 2>/dev/null || echo "NEVER_PUBLISHED"`
```

#### 双触发模式实现原理

Skill 的 `description` 和 `when_to_use` 字段是自然语言触发的依据。Claude Code 在收到用户消息后，会根据这些描述判断是否需要调用该 Skill。因此：

- **斜杠命令**：用户输入 `/minus` → 直接调用 `skills/minus/SKILL.md`
- **自然语言**：用户输入"帮我发布" → Claude Code 匹配 `minus-publish` 的 description → 调用该 Skill

不需要额外的路由逻辑，Claude Code 原生支持这两种触发方式。

### 3.2 Hooks — 生命周期自动化

```json
// hooks/hooks.json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ./lib/project-detector.sh",
            "timeout": 5000
          }
        ]
      }
    ],

    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash ./lib/context-manager.sh check",
            "timeout": 3000
          }
        ]
      }
    ]
  }
}
```

#### SessionStart — 轻量环境提示

> **设计变更 [2026-05-22]：** SessionStart hook 从"自动检测并执行完整流程"改为"只输出轻量提示"。
> **原因：** 原设计在任何目录启动时都自动跑登录/项目选择/创建流程，干扰了不想使用 Plugin 的用户。
> 改为被动触发模式——SessionStart 只告知 Plugin 存在，完整流程由 `/minus` skill 承担。

```bash
# lib/project-detector.sh
# 检查当前目录状态，输出轻量提示

if [ -f ".minus/skill.json" ]; then
  # 在 Skill 项目中：输出环境状态概要，提示输入 /minus 继续开发
  echo "<context>
  Minus Creator Plugin 已加载。
  当前目录是 Minus Skill 项目。
  输入 /minus 进入开发环境。
  </context>"
else
  # 非项目目录：只输出一行存在提示
  echo "<context>
  Minus Creator Plugin 已加载。输入 /minus 开始。
  </context>"
fi
```

SessionStart hook 的输出注入到 Claude Code 的上下文中，让 Plugin 感知当前目录状态。但**不执行任何交互流程**——登录、项目选择、环境初始化等全部由 `/minus` skill 在 Creator 主动触发时执行。

#### PostToolUse — 上下文容量检查

```bash
# lib/context-manager.sh
# 参数: check | save

case "$1" in
  check)
    # 通过环境变量或 API 获取当前上下文使用量
    # 具体实现取决于 Claude Code 暴露的能力
    # 如果接近上限，输出提醒信息
    echo "<context>
    [上下文检查] 当前对话已持续较长时间。
    如果即将完成一个主要任务节点，建议保存进度并提示 Creator 开启新对话。
    </context>"
    ;;
  save)
    # 保存当前进度到 Memory
    bash ./lib/progress-saver.sh
    ;;
esac
```

> **实现说明：** Claude Code 目前未直接暴露上下文容量的精确数值。替代方案：(1) 基于对话轮次和消息长度做粗略估算；(2) 在每个主要任务节点完成后，由 Plugin 主动判断是否需要切换；(3) 等待 Claude Code 后续版本提供上下文容量 API。

### 3.3 MCP Server — 平台 API 集成

#### Minus 平台 MCP Server

这个 MCP Server 封装 Minus 平台的后端 API，供 Plugin 在以下场景调用：

| Tool | 用途 | 调用的 API |
|------|------|-----------|
| `auth_vcode` | 发送验证码 | POST /api/auth/vcode/send |
| `auth_register` | 注册账号 | POST /api/auth/register |
| `auth_login` | 手机号登录 | POST /api/auth/login |
| `auth_dev_session` | Developer API Key 登录 | POST /api/auth/dev-session |
| `auth_status` | 检查登录状态 | GET /api/me |
| `auth_logout` | 登出 | POST /api/auth/logout |
| `skill_list` | 列出已发布的 Skill（用户视角） | GET /api/me/skills |
| `skill_update` | 编辑草稿版本 | PATCH /api/skills/{skillId}/versions/{version} |
| `skill_version_get` | 获取草稿版本详情 | GET /api/skills/{skillId}/versions/{version} |
| `session_create` | 创建测试 Session | POST /api/me/skills/{skillId}/sessions |
| `session_list` | 查看 Session 历史 | GET /api/me/skills/{skillId}/sessions |
| `file_upload` | 上传文件 | POST /api/me/files |

> **已移除的 Tool：**
> - `skill_create` — 创建 Skill 通过 `create-skill` CLI 完成
> - `skill_endpoint_set` — `PUT /api/admin/skills/{skillId}/endpoint` 接口已下线

```javascript
// mcp-servers/minus-platform/index.js（伪代码）

import { McpServer } from "@anthropic-ai/mcp";

const server = new McpServer({
  name: "minus-platform",
  version: "1.0.0"
});

// 登录
server.tool("auth_login", { email: "string", password: "string" }, async (params) => {
  const response = await fetch(`${API_BASE}/auth/login`, {
    method: "POST",
    body: JSON.stringify(params)
  });
  const data = await response.json();
  // 将 token 存储到 ~/.minus/credentials.json
  await saveCredentials(data.token, data.refresh_token);
  return { success: true, creator_name: data.name };
});

// 发布 Skill
server.tool("skill_publish", { package_path: "string", version: "string" }, async (params) => {
  const token = await loadCredentials();
  const response = await fetch(`${API_BASE}/skills/publish`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: createFormData(params.package_path)
  });
  return await response.json();
});

server.start();
```

> **API 规格占位：** 上述接口的请求/响应格式待后端团队补充。MCP Server 只是 API 的封装层，接口定义变更时只需更新这里。

#### 数据服务商 MCP — 仅用于开发阶段

数据服务商（如 Sif）在 Minus 平台注册时提供自己的 MCP 接口，用于暴露其 API 目录。这个 MCP **只在开发阶段使用**——帮 Creator 发现可用的 API。

```
开发阶段（Creator 通过 Plugin 开发 Skill）:

  Creator: "这一步需要获取关键词搜索量"
      │
      ▼
  Plugin 通过 MCP 查询数据服务商的 API 目录
      │
      ▼
  Plugin: "找到以下相关 API：
           · market_get_keyword_demand — 搜索量、点击量
           · market_get_keyword_history — 12 个月趋势"
      │
      ▼
  Creator: "用第一个"
      │
      ▼
  Plugin 生成确定性代码，直接调用该 API（HTTP 请求）
```

生成的 Skill 代码示例：

```javascript
// steps/01-关键词数据采集.js
// 由 Plugin 在开发阶段生成，运行时直接执行

async function execute(input, apiKey) {
  // 确定性的 API 调用 — 不经过 MCP
  const response = await fetch("https://api.sif.com/v1/market/keyword-demand", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      keyword: input.keyword,
      market: "US"
    })
  });

  const data = await response.json();

  // 确定性的数据处理 — 格式化、排序
  return {
    search_volume: minus.format.number(data.search_volume),
    trend: data.monthly_trend,
    click_rate: minus.format.percent(data.click_rate)
  };
}
```

### 3.4 Agents — 引导式对话

Agents 用于需要多轮深度引导的场景。与 Skill 不同，Agent 是作为子代理运行的，有独立的上下文和特定的工具集。

#### skill-guide — 结构设计引导

```markdown
# agents/skill-guide.md
---
name: skill-guide
description: 引导 Creator 完成 Skill 结构设计（输入→步骤→输出三步法）
tools: Read Write Bash(ls *) mcp__minus-platform__*
model: inherit
effort: high
---

你是 Minus Skill 结构设计引导助手。

## 任务
引导 Creator 完成 Skill 的初始结构设计，采用三步法：
1. 确定输入 — 用户需要提供什么
2. 拆解步骤 — 拿到输入后分几步完成
3. 定义输出 — 最终给用户看什么

## 交互规则
- 一次只问一个问题
- 每个问题确认后再进入下一个
- 使用通俗语言，不要技术术语
- 你的角色是帮 Creator 结构化表达想法，不是替 Creator 规划

## 完成后
将结果通过平台 API 写入后端
```

#### node-dev — 逐节点开发引导

```markdown
# agents/node-dev.md
---
name: node-dev
description: 引导 Creator 开发单个 pipeline 节点（数据需求→处理逻辑→输出→确认）
tools: Read Write Edit Bash(node *) Bash(npm *) Bash(curl *)
model: inherit
effort: high
---

你是 Minus 节点开发引导助手。

## 任务
引导 Creator 完成一个 pipeline 节点的开发，按四个维度：
1. 数据需求 — 通过 MCP 发现可用 API，推荐给 Creator
2. 处理逻辑 — 确认数据处理方式（直接透传/聚合/LLM 分析）
3. 输出定义 — 传给下一步的数据 + 展示给用户的内容
4. 用户确认 — 是否需要运行时暂停

## 代码生成规则
- 数据获取部分：生成确定性的 HTTP API 调用代码，不依赖 MCP
- 数据处理部分：如需 LLM，调用 Claude API；否则生成纯代码
- 格式化部分：使用 minus.format.* 内置工具
- 输出部分：使用 minus.output.* 内置工具
```

---

## 4. 运行时架构 — Skill 执行模型

### 4.1 开发阶段 vs 运行阶段

这是整个架构中最重要的区分：

```
┌──────────────────────────────────────────────────────────┐
│                    开发阶段（Dev Time）                    │
│                                                          │
│  Creator + Plugin 在 Claude Code 中交互                   │
│                                                          │
│  ┌────────────┐    MCP 查询     ┌──────────────────┐    │
│  │   Plugin    │───────────────▶│  数据服务商 MCP    │    │
│  │            │◀───────────────│  (API 目录发现)    │    │
│  └──────┬─────┘   API 列表     └──────────────────┘    │
│         │                                                │
│         │  生成代码                                       │
│         ▼                                                │
│  ┌────────────────────────────────────────────┐          │
│  │        Skill 代码（确定性）                   │          │
│  │  · HTTP API 调用（直接请求，不经 MCP）         │          │
│  │  · 数据处理逻辑                               │          │
│  │  · LLM 调用点（如有需要）                     │          │
│  │  · 输出渲染                                   │          │
│  └────────────────────────────────────────────┘          │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│                    运行阶段（Run Time）                    │
│                                                          │
│  终端用户在 Minus 平台使用 Skill                           │
│                                                          │
│  ┌─────────┐     HTTP      ┌──────────────────┐         │
│  │  Skill   │─────────────▶│   数据服务商 API   │         │
│  │  代码    │◀─────────────│   (直接调用)       │         │
│  └────┬────┘    数据       └──────────────────┘         │
│       │                                                  │
│       │ (可选)                                            │
│       ▼                                                  │
│  ┌──────────┐                                            │
│  │ LLM API  │  分析摘要、智能推荐、自然语言总结             │
│  └──────────┘                                            │
│       │                                                  │
│       ▼                                                  │
│  ┌──────────────────────────────────────┐                │
│  │  输出：表格 + 卡片 + 摘要 + 下载文件   │                │
│  └──────────────────────────────────────┘                │
└──────────────────────────────────────────────────────────┘
```

### 4.2 代码中的三个层次

Plugin 为每个节点生成的代码包含三个明确分离的层次：

| 层次 | 性质 | 技术实现 | 示例 |
|------|------|---------|------|
| **数据获取层** | 确定性 | HTTP API 直接调用 | `fetch("https://api.sif.com/v1/...")` |
| **数据处理层** | 确定性 / LLM | 纯代码 或 Claude API 调用 | 排序过滤用代码；分析摘要用 LLM |
| **输出渲染层** | 确定性 | minus.output.* 内置工具 | `minus.output.table(data, columns)` |

```javascript
// 一个完整节点的代码结构示例

async function executeStep(input, context) {

  // ──── 第一层：数据获取（确定性，直接 API 调用）────
  const demandData = await fetch("https://api.sif.com/v1/market/keyword-demand", {
    method: "POST",
    headers: { "Authorization": `Bearer ${context.apiKey}` },
    body: JSON.stringify({ keyword: input.keyword, market: "US" })
  }).then(r => r.json());

  const historyData = await fetch("https://api.sif.com/v1/market/keyword-history", {
    method: "POST",
    headers: { "Authorization": `Bearer ${context.apiKey}` },
    body: JSON.stringify({ keyword: input.keyword, market: "US", months: 12 })
  }).then(r => r.json());

  // ──── 第二层：数据处理 ────

  // 2a. 确定性处理（纯代码）
  const formattedData = {
    search_volume: minus.format.number(demandData.search_volume),
    click_rate: minus.format.percent(demandData.click_rate),
    trend: historyData.monthly_data.map(m => ({
      month: minus.format.date(m.date, "YYYY-MM"),
      volume: minus.format.compact(m.volume)
    }))
  };

  // 2b. LLM 处理（如需分析总结）
  const summary = await llm.analyze({
    prompt: `基于以下关键词数据，生成 2-3 句话的趋势分析摘要：
             关键词：${input.keyword}
             搜索量：${demandData.search_volume}
             趋势：${JSON.stringify(historyData.monthly_data)}`,
    max_tokens: 200
  });

  // ──── 第三层：输出渲染（确定性，内置工具）────
  return {
    display: [
      minus.output.card("月搜索量", formattedData.search_volume, demandData.yoy_change),
      minus.output.table(formattedData.trend, ["月份", "搜索量"]),
      { type: "summary", content: summary }
    ],
    passToNext: {
      keyword: input.keyword,
      search_volume: demandData.search_volume,
      trend: historyData.monthly_data
    }
  };
}
```

### 4.3 LLM 接入判定

Plugin 在生成代码时，根据以下规则决定是否接入 LLM：

| 场景 | 用 LLM | 用纯代码 |
|------|--------|---------|
| 获取 API 数据 | | ✓ |
| 数字格式化（千分位、百分比） | | ✓（minus.format.*） |
| 排序、过滤、分组、去重 | | ✓（minus.data.*） |
| 生成分析摘要 | ✓ | |
| 对比分析、趋势解读 | ✓ | |
| 智能推荐排序（含主观判断） | ✓ | |
| 生成报告文案 | ✓ | |
| 表格渲染、文件生成 | | ✓（minus.output.*） |

> **原则：能用确定性代码解决的不用 LLM。** LLM 调用有延迟和成本，只在需要"理解"和"判断"的环节使用。

---

## 5. 认证体系

### 5.1 两层认证

| 层次 | 谁的凭证 | 用途 | 存储位置 |
|------|---------|------|---------|
| **Creator 凭证** | Creator 本人 | 登录 Minus 平台、发布 Skill | `~/.minus/credentials.json` |
| **Skill API Key** | Skill 运行时 | 调用数据服务商 API | `.minus.json` → `api_key` 字段 |

### 5.2 Creator 凭证流程

```
Creator 输入 /minus login
    │
    ▼
Plugin 调用 MCP: auth_login(email, password)
    │
    ▼
Minus 平台返回 access_token + refresh_token
    │
    ▼
Plugin 写入 ~/.minus/credentials.json（Creator 不可见）
    │
    ▼
后续所有平台操作自动附带 token
```

```json
// ~/.minus/credentials.json
{
  "access_token": "eyJ...",
  "refresh_token": "eyJ...",
  "expires_at": "2026-05-18T12:00:00Z",
  "creator_id": "cr_abc123",
  "creator_name": "Song"
}
```

### 5.3 Skill API Key

数据服务商为每个 Skill 分配独立的 API Key，用于运行时鉴权。

```json
// .minus.json 中的 API Key
{
  "skill_id": "sk_8f3a2b",
  "api_key": "sk_key_xxx...",
  "preview_port": 9100
}
```

> **安全说明：** API Key 存储在 Creator 本地的 `.minus.json` 中，发布时 Plugin 将其加密后上传到 Minus 平台，平台在运行时注入到 Skill 的执行环境中。API Key 不会出现在用户可见的代码中。

---

## 6. 状态管理

### 6.1 状态全景

| 文件 | 作用域 | 持久性 | 说明 |
|------|--------|--------|------|
| `.minus.json` | 项目 | 永久 | 项目标识和本地配置（Skill ID、API Key、预览端口） |
| `CLAUDE.md` | 项目 | 永久 | Claude Code 在进入项目时自动加载 |
| `.claude/memory/` | 项目 | 跨 Session | 开发进度、Creator 偏好 |
| `~/.minus/credentials.json` | 全局 | 跨项目 | 登录凭证 |
| `~/.minus/projects.json` | 全局 | 跨项目 | 所有 Skill 项目的注册表 |

### 6.2 .minus.json 结构

`.minus.json` 是轻量级的本地项目标识文件。Skill 的所有业务信息存储在后端，通过平台 API 读写。

```json
{
  "skill_id": "sk_8f3a2b",
  "api_key": "sk_key_xxx...",
  "preview_port": 9100
}
```

| 字段 | 说明 |
|------|------|
| `skill_id` | 平台分配的 Skill 唯一标识，不可改 |
| `api_key` | 平台分配的运行时凭证，Skill 调用数据 API 时使用 |
| `preview_port` | 本地预览端口，首次启动时自动检测可用端口并写入 |

**后端存储的业务数据（通过平台 API 管理）：**

| 数据 | 说明 |
|------|------|
| `name` / `description` / `version` | Skill 基本信息 |
| `author` / `icon` / `tags` / `market` | Skill 元信息 |
| `input` | 输入定义（type、label、placeholder、required） |
| `steps` | 步骤定义（id、name、处理逻辑、状态） |
| `result` | 结果呈现配置（摘要、展示、下载） |
| `output_schema` | 输出 Schema（v1 预留） |
| `dependencies` | 依赖声明（使用的 API/包） |

### 6.3 进度保存到 Memory

```markdown
<!-- .claude/memory/minus-progress.md -->

# Minus 开发进度

## 项目：关键词调研助手
- 更新时间：2026-05-17 14:30
- 当前阶段：Phase 4 — 逐节点开发

## 已完成
- ✓ 结构设计（输入：单个关键词；3 个步骤；输出：推荐词列表 + 评分 + 摘要）
- ✓ 步骤 1「关键词数据采集」开发完成并测试通过

## 进行中
- 步骤 2「竞争度分析」— 数据需求已确认（market_get_keyword_competition），处理逻辑待定

## 待完成
- 步骤 3「长尾词推荐」
- 结果呈现设计
- 发布

## Creator 偏好
- 搜索量数字需要千分位格式化
- 不需要趋势图表，只要表格和评分卡片
- 下载格式：Excel + HTML
```

---

## 7. Minus 平台 API（待补充）

> **此章节待后端团队补充。** 以下是 Plugin 需要的接口清单，请后端团队按此定义 API。

### 7.1 需要的接口清单

| 接口 | 方法 | 说明 | 优先级 |
|------|------|------|--------|
| `/auth/login` | POST | Creator 登录 | P0 |
| `/auth/refresh` | POST | 刷新 access_token | P0 |
| `/auth/status` | GET | 检查登录状态 | P1 |
| `/skills/create` | POST | 注册新 Skill | P0 |
| `/skills/{id}/publish` | POST | 上传发布包 | P0 |
| `/skills/{id}/versions` | GET | 查询版本历史 | P0 |
| `/skills/{id}/status` | GET | 查询审核状态 | P1 |

### 7.2 接口契约格式

建议后端团队按以下格式定义每个接口：

```yaml
endpoint: /auth/login
method: POST
request:
  body:
    email: string (required)
    password: string (required)
response:
  200:
    access_token: string
    refresh_token: string
    expires_in: number (seconds)
    creator:
      id: string
      name: string
      email: string
  401:
    error: "INVALID_CREDENTIALS"
    message: string
```

---

## 8. Codex 适配路径

### 8.1 当前状态

Plugin 基于 Claude Code 的以下能力构建：

| 能力 | Claude Code 实现 | Codex 对应 |
|------|-----------------|-----------|
| Skill 系统 | `skills/*/SKILL.md` | 待调研 |
| Hooks 系统 | `hooks/hooks.json` | 待调研 |
| MCP Server | `.mcp.json` | 待调研（Codex 是否支持 MCP） |
| Agent 系统 | `agents/*.md` | 待调研 |
| Memory | `.claude/memory/` | 待调研 |
| CLAUDE.md | 项目级指令 | 待调研（Codex 是否有类似机制） |

### 8.2 适配策略

**核心原则：业务逻辑与平台能力分离。**

```
┌─────────────────────────────────────────┐
│            业务逻辑层（平台无关）          │
│                                         │
│  · Skill 结构设计引导逻辑                │
│  · 节点开发引导逻辑                      │
│  · 发布校验逻辑                          │
│  · 上下文管理逻辑                        │
│  · Minus 平台 API 调用                   │
└─────────────────┬───────────────────────┘
                  │
         ┌────────▼────────┐
         │   适配层（Adapter）│
         └────────┬────────┘
                  │
    ┌─────────────┼─────────────┐
    ▼                           ▼
┌──────────┐              ┌──────────┐
│Claude Code│              │  Codex   │
│  Adapter  │              │  Adapter │
│           │              │          │
│ · Skills  │              │ · ???    │
│ · Hooks   │              │ · ???    │
│ · MCP     │              │ · ???    │
│ · Agents  │              │ · ???    │
│ · Memory  │              │ · ???    │
└──────────┘              └──────────┘
```

**当前实现：** 先把 Claude Code Adapter 做好，业务逻辑尽量写在 Skill 和 Agent 的 prompt 中（平台无关的自然语言）。未来 Codex 适配时，只需要实现一个新的 Adapter 把这些 prompt 转译为 Codex 的机制。

### 8.3 需要关注的 Codex 能力

Codex 适配时需要确认的关键问题：

- [ ] Codex 是否支持 MCP 协议？
- [ ] Codex 是否有类似 Skill 的 prompt 扩展机制？
- [ ] Codex 是否有 hooks 或生命周期事件？
- [ ] Codex 的 Memory / 持久化状态如何实现？
- [ ] Codex 是否支持子代理（Agent）？
- [ ] Codex 的文件系统访问权限模型是什么？

---

## 9. CLI 适配

### 9.1 核心前提

Claude Code 的 Plugin 系统（Skills、Hooks、MCP、Agents）在 Desktop 和 CLI 中行为完全一致。Plugin 代码不需要区分客户端——差异仅在**用户侧的操作方式和 Plugin 给出的指引措辞**。

### 9.2 差异对照

| 操作 | Desktop | CLI |
|------|---------|-----|
| **安装 Plugin** | 在 Code 模块粘贴安装指令 | `claude plugin install minus-creator` 或 `--plugin-dir` 参数 |
| **打开项目** | 文件 → 打开文件夹 → 选择项目目录 | `cd ~/minus/my-skill && claude` |
| **新建 Session** | 点击左上角 ＋ 开始新对话 | `Ctrl+C` 退出 → 重新运行 `claude` |
| **切换工作目录** | 必须新建 Session（工作目录锁定） | 退出后 `cd` 到新目录再运行 |
| **预览测试** | 可能有内置预览面板 | 手动在浏览器打开 `http://localhost:{port}/preview` |
| **文件浏览** | 侧边栏文件树 | `ls` / `tree` 命令 |

### 9.3 需要适配的指引

Plugin 在引导 Creator 时，有几处措辞需要根据客户端动态调整：

#### 检测客户端类型

```bash
# lib/detect-client.sh
# 检测当前运行在 Desktop 还是 CLI

if [ -n "$CLAUDE_DESKTOP" ] || [ "$TERM_PROGRAM" = "claude-desktop" ]; then
  echo "desktop"
else
  echo "cli"
fi
```

> **实现说明：** 具体的环境变量取决于 Claude Code 实际暴露的标识。如果没有直接的环境变量区分，可通过检测 TTY 类型、父进程名等方式推断。最简方案：在 Skill prompt 中直接要求 Plugin 询问 Creator 使用的是哪个版本。

#### 指引措辞对照表

Plugin prompt 中应包含以下条件逻辑：

| 场景 | Desktop 措辞 | CLI 措辞 |
|------|-------------|---------|
| **新建 Session** | "点击左上角的 ＋ 开始新对话" | "按 `Ctrl+C` 退出，然后重新运行 `claude`" |
| **打开项目** | "在 Claude Desktop 中，点击 文件 → 打开文件夹，选择你的项目目录" | "在终端中运行：`cd ~/minus/你的项目名 && claude`" |
| **安装 Plugin** | "复制以下指令，粘贴到 Claude Desktop 的 Code 模块中" | "在终端中运行：`claude plugin install minus-creator`" |
| **预览 Skill** | "在浏览器中打开这个地址测试" | "在浏览器中打开这个地址测试" |
| **查看文件** | "你可以在左侧文件树中看到项目结构" | "运行 `ls` 或 `tree` 查看项目结构" |

> **注意：** 预览测试的指引在两个版本中一致——都是让 Creator 打开浏览器。这是刻意设计，因为无论哪个客户端，Creator 都应该在浏览器中亲自体验 Skill 的输出效果。

### 9.4 Skill Prompt 中的适配写法

```markdown
## 客户端适配

在引导 Creator 操作时，根据客户端类型调整措辞：

检测客户端：
!`bash ./lib/detect-client.sh`

如果是 desktop：
- 新建对话："点击左上角的 ＋ 开始新对话"
- 打开项目："在 Claude Desktop 中，点击 文件 → 打开文件夹"
- 文件浏览：可以引用"左侧文件树"

如果是 cli：
- 新建对话："按 Ctrl+C 退出当前对话，然后重新运行 claude"
- 打开项目："cd ~/minus/项目名 && claude"
- 文件浏览：用 ls 或 tree 命令展示

通用（不区分客户端）：
- 预览测试：始终引导到浏览器 http://localhost:{port}/preview
- 斜杠命令：/minus、/minus publish 两端完全一致
- 自然语言触发：两端完全一致
```

### 9.5 不需要适配的部分

以下能力在两个客户端中完全一致，无需任何适配：

- Plugin 核心逻辑（Skills、Hooks、MCP Server、Agents）
- .minus.json 和 CLAUDE.md 的格式和行为
- Memory 系统（`.claude/memory/` 路径一致）
- 全局配置（`~/.minus/` 路径一致）
- 斜杠命令和自然语言触发
- 文件读写、代码生成
- Minus 平台 API 调用
- 认证流程

---

## 10. 上下文窗口管理 — 技术实现

### 10.1 检测机制

由于 Claude Code 未直接暴露上下文容量 API，采用以下策略组合：

| 策略 | 实现方式 | 说明 |
|------|---------|------|
| **任务节点计数** | Plugin 通过后端 API 跟踪已完成的节点数 | 经验值：3-4 个节点的开发通常接近上下文上限 |
| **对话轮次估算** | Hook 在每次 PostToolUse 后递增计数器 | 写入临时文件 `.minus/session-counter` |
| **主动检查点** | 每完成一个主要任务后，Plugin 主动评估 | 由 Skill prompt 中的规则驱动 |

### 10.2 保存进度

```bash
# lib/progress-saver.sh
# 将当前开发状态写入 Memory

PROGRESS_FILE=".claude/memory/minus-progress.md"
MINUS_JSON=".minus.json"

# 通过平台 API 获取步骤状态（此处为示意，实际通过 MCP 调用）
SKILL_ID=$(node -e "const j = JSON.parse(require('fs').readFileSync('$MINUS_JSON', 'utf8')); console.log(j.skill_id)")

# 生成进度文件（步骤数据从后端获取）
cat > "$PROGRESS_FILE" << EOF
# Minus 开发进度

## 项目：$SKILL_ID
- 更新时间：$(date '+%Y-%m-%d %H:%M')
- 当前阶段：Phase 4 — 逐节点开发

## 步骤状态
（由 Plugin 通过平台 API 从后端获取并填充）

## 待继续
（由 Plugin 根据后端步骤状态判断）
EOF

echo "进度已保存到 $PROGRESS_FILE"
```

### 10.3 Session 切换指引

Plugin 在 Skill prompt 中包含以下规则：

```markdown
## 上下文管理规则

每次完成一个主要任务（节点开发完成、结果呈现设计完成）后：

1. 运行 `bash ./lib/progress-saver.sh` 保存进度
2. 评估是否需要切换 Session：
   - 如果已完成 3 个以上节点的开发 → 建议切换
   - 如果对话已超过 30 轮 → 建议切换
   - 如果感知到回复质量下降 → 立即切换

3. 切换时的话术（使用通俗语言，不说"上下文"）：
   "当前对话的记忆空间快满了，继续工作可能会影响质量。
    我已经把你的进度保存好了：[列出已完成和进行中的步骤]
    请开一个新对话继续：
    1. 点击左上角的 ＋ 开始新对话
    2. 输入 /minus 或"打开 Minus"
    3. Plugin 会自动读取进度，从中断的地方继续"
```

---

## 附录 A：Skill Prompt 中引用产品文档

Plugin 的 Skill 和 Agent prompt 中需要引用产品规格文档中的交互设计。建议在 CLAUDE.md 中声明：

```markdown
<!-- 项目级 CLAUDE.md，由 Plugin 自动生成 -->

# Minus Skill 项目

## 开发规范
- Skill 结构设计采用三步法（输入→步骤→输出），详见 Plugin 内置引导
- 每个节点开发按四个维度（数据需求→处理逻辑→输出→确认）
- 数据获取使用直接 API 调用，不依赖 MCP
- 格式化使用 minus.format.* 工具
- 输出使用 minus.output.* 工具

## 测试
- 统一预览地址：http://localhost:9100/preview
- Creator 必须在浏览器中自行测试

## 当前状态
!`cat .minus.json 2>/dev/null`
```

---

## 附录 B：关键决策记录

| 决策 | 选项 | 选择 | 理由 |
|------|------|------|------|
| API 调用方式 | MCP / 直接 HTTP | 直接 HTTP | MCP 仅用于开发阶段发现 API；运行时代码必须确定性 |
| LLM 接入 | 全流程 / 仅分析环节 | 仅分析环节 | 数据获取和格式化不需要 LLM，减少延迟和成本 |
| 状态持久化 | 数据库 / 文件 | 后端 + Memory + .minus.json | 业务数据在后端，开发进度用 Memory，本地仅保留项目标识 |
| 上下文管理 | 自动切换 / 手动引导 | 手动引导 | Claude Desktop 不支持自动创建 Session |
| 平台 API 集成 | 直接 HTTP / MCP Server | MCP Server | MCP 让 Claude Code 可以直接调用平台 API 作为工具 |
| Codex 兼容 | 双实现 / 适配层 | 适配层 | 先做好 Claude Code 版本，业务逻辑与平台分离 |
