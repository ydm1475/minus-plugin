# 节点开发引导

帮 Creator 完成一个 pipeline 步骤的具体开发。

## 插件脚本调用方式

插件脚本通过 `minus-lib <脚本名> [参数]` 裸命令调用（bin/ 已在 PATH 上），如 `minus-lib step-tracker check 1`。

## 任务

引导 Creator 按顺序确认当前 pipeline 节点的四个维度意图，**全部确认后一次性生成代码**。

⛔ 核心规则：

- 每个维度的业务意图必须得到 Creator **明确**确认后才能进入下一个
- **明确确认** = Creator 清楚说出了该维度的具体内容（如"表格""排序""自动继续"）；Agent 推断、联想、从技能名猜测出来的**不算明确表达**
- **四个维度的问答阶段只收集意图，不写任何代码**
- **所有维度全部确认后，一次性生成 pipeline.py + main.tsx 代码**
- **禁止抢答**：Creator 的回复只有在你已执行 `ask` 并输出该维度问题之后，才算该维度的回答。不确定 Creator 在回答哪个维度时，先复述理解请 Creator 确认，禁止自行判断并标记完成

## 每个维度的标准流程

```
1. 执行 minus-lib step-tracker ask <step> <dim>  → 输出话术，转达，停止等回复
2. 等待 Creator 明确回复
3. 执行 minus-lib step-tracker complete <step> <dim> [mode]
```

若 Creator 一句话**明确**覆盖了多个维度（如同时说清楚了处理方式和展示内容），可合并：

```
minus-lib step-tracker ask <step> output confirm  → 输出合并确认句，停止等回复
Creator 确认后 → complete output，complete confirm <mode>
```

合并的前提是各维度内容均已**明确**说出，不是 Agent 推断的。

## 阶段一：逐维度收集意图

### ① 数据需求

数据源选择是开发侧的职责：进入维度 ① 时立即执行下面的接口发现流程，把能拿到的数据用通俗语言列给 Creator 确认（"数据从哪来""用什么接口""你有特定数据源吗"这类问题不抛给 Creator——他们答不了）。

**数据接口发现流程：**

0. 先确认当前步骤的**用户输入是什么**。读 `frontend/src/main.tsx` 和 `frontend/src/locales/zh-CN.json`，找到 Home 组件的输入表单（placeholder、字段名、onStart 传参），以用户实际输入的类型（关键词？ASIN？类目 ID？）作为后续搜索接口的依据（Skill 名称或步骤名推断的输入类型经常与表单不一致）。
1. 调用 `ToolSearch("mcp__")` 发现当前会话中可用的 MCP 工具（这些工具来自插件 `.mcp.json` 中配置的 MCP 服务，会话启动时已自动注册）。排除 `mcp__plugin_minus-creator_minus-platform__` 开头的（那是平台管理工具），剩下的就是数据服务商的工具。工具列表和参数 schema 只能通过 ToolSearch 获取（`.mcp.json` 里只有启动配置，没有这些信息）。
2. 用该服务的搜索工具搜索与当前步骤相关的数据 API
3. 如果搜索返回多个候选接口，用详情查询工具逐个查看参数要求，**选参数最简单、最匹配当前场景的接口**（只看第一个结果就决定经常选错）
4. 用通俗语言向 Creator 展示能获取的数据（如"可以查到搜索量、点击率、竞争度"），接口确认后执行 ask

⛔ P0：写进确认内容的接口必须来自上述 MCP 发现流程的真实结果。找不到合适接口时，如实告诉 Creator 这一步取不到数据并讨论调整——不读本地 SDK 源码猜接口，不用 mock 数据顶替。

**重要：MCP 只用于开发阶段发现 API。生成的代码通过 SDK 调用 API（如 SIF 数据源用 `ctx.sif.*`），不依赖 MCP。具体用哪个 SDK 方法，参考 MCP 返回的接口文档。**

接口发现完成后，执行：

```bash
minus-lib step-tracker ask {step_number} data
```

脚本输出话术后**停止，等 Creator 回复**。Creator 明确确认后执行：

```bash
minus-lib step-tracker complete {step_number} data
```

### ② 处理逻辑

处理逻辑按意图选择确定性代码或 SDK LLM 能力：

- 格式化、排序、过滤、聚合 → 纯代码
- 分析摘要、趋势解读、推荐理由、风险提示、文案生成 → 可使用 SDK 内置 LLM 能力

原则：能用确定性代码解决的不用 LLM；Creator 明确说"用大模型自动生成"、"AI 总结"、"自动分析"等意图时，要把它识别为 LLM 处理逻辑并确认生成目标。

引导时不要主动推销"大模型生成"作为默认选项；只在 Creator 明确表达，或任务确实需要自然语言理解/判断/生成时使用。

如果使用 LLM，必须先完成一次动态确认，不暴露技术细节：

1. 根据当前步骤的数据内容、Creator 已表达的业务目标和上下文，动态生成需要确认的问题（固定问题清单无法贴合具体数据语境，不要照搬）。
2. Creator 回答后，用通俗语言归纳大模型将生成什么、重点关注什么、有哪些边界，并询问「这样可以吗？」
3. 只有 Creator 明确确认后，才能记录 `logic llm` 并进入下一维度。

执行：

```bash
minus-lib step-tracker ask {step_number} logic
```

脚本输出话术后**停止，等 Creator 回复**。Creator 明确确认后，根据处理方式执行其中一个命令：

```bash
# 排序、筛选、聚合、格式化等确定性处理
minus-lib step-tracker complete {step_number} logic deterministic

# 大模型生成、AI 总结、自动分析等 LLM 处理
minus-lib step-tracker complete {step_number} logic llm
```

### ③ 输出定义

只收集展示意图（不写代码）：

- **展示给用户的内容**：表格、摘要、卡片等
- 传给下一步的数据在维度 ④ 确认后再问
- ⛔ **禁止自动补展示内容**：代码只能渲染 Creator 在输出定义阶段明确确认的展示内容。接口返回字段、计算中间值、排序依据、调试信息，都不是默认展示内容。Creator 只说"表格"就只生成表格；只有 Creator 明确要求"概览/摘要/统计卡片/顶部汇总"时，才可以添加这类 UI。

执行：

```bash
minus-lib step-tracker ask {step_number} output
```

脚本输出话术后**停止，等 Creator 回复**。Creator 明确确认后执行：

```bash
minus-lib step-tracker complete {step_number} output
```

脚本会自动判断是否为最后一步：

- **最后一步**：脚本自动标记 `confirm (auto)` 并输出 `NEXT=GENERATE`——直接进入「阶段二：一次性生成代码」，维度 ④ 不存在于最后一步
- **非最后一步**：脚本提示执行 `ask <step> confirm`，执行后停止等回复

### ④ 用户确认 + 传递数据

本维度只在脚本提示执行 `ask <step> confirm` 时进入（最后一步已由脚本自动跳过）。

确认模式必须由 Creator 亲口选择，按字面映射：说"需要确认"→ interactive；说"自动继续"或"用户不用确认"→ auto（"不用确认"是 auto 的同义表达，不是 interactive）。

执行：

```bash
minus-lib step-tracker ask {step_number} confirm
```

脚本输出话术后**停止，等 Creator 回复**。

**分两轮收集：**

**第一轮：确认模式**

- "需要确认" → 记录 interactive
- "自动继续" / "用户不用确认" → 记录 auto

**第二轮：传递数据（根据确认模式调整措辞）**

如果 interactive，原样输出：

「好，用户需要先确认再继续。」

「那用户勾选确认的什么数据传给下一步？比如选中的关键词、选中的 ASIN……」

如果 auto，原样输出：

「好，自动往下走。」

「那这一步的什么数据传给下一步？」

Creator 确认后，执行：

```bash
minus-lib step-tracker complete {step_number} confirm <auto|interactive>
```

脚本输出 `NEXT=GENERATE` 后，执行门禁检查进入阶段二。

## 阶段二：一次性生成代码

⛔ **进入阶段二前必须执行门禁检查**，门禁不通过则不能写任何代码：

```bash
minus-lib generate-node-code {step_number}
```

此脚本会检查四维度是否全部 COMPLETE，并输出 `LOGIC_MODE`（deterministic/llm）、`LLM_REQUIRED`（YES/NO）、`CONFIRM_MODE`（auto/interactive）和前端代码模板。

- 如果输出 `GATE_PASSED` → 可以开始写代码
- 如果报错 → 四维度未全部确认，必须补完

⛔ **禁止在门禁通过前编辑 pipeline.py 或 main.tsx。** 任何代码修改必须在 `generate-node-code.sh` 返回 `GATE_PASSED` 之后。

根据门禁输出的 `LOGIC_MODE`、`LLM_REQUIRED`、`CONFIRM_MODE` 和收集到的意图一次性生成所有代码。`LLM_REQUIRED=YES` 时，后端必须使用 SDK 内置 LLM 能力。

### 步骤摘要规则

⛔ **摘要不是默认行为——仅当 Creator 在输出定义阶段明确要求"摘要/总结/概览"时，才在后端 payload 中加 `summary` 字段。** Creator 没提摘要需求的步骤，禁止自行生成 summary。

当 Creator 确认需要摘要时：
- 摘要必须来自后端 payload，不能只在前端临时拼接（这样摘要会随步骤结果持久化，用户回放时不会丢失）。
- 摘要的时序写法（什么时候用 `STEP_PARTIAL_DETAIL`、什么时候直接随终态下发）见前端 SDK 手册（frontend-guide.md）「步骤摘要（LLM summary）的三种时序」章节，按 `CONFIRM_MODE` 和摘要分析对象选择对应时序。
- ⛔ 禁止为此拆出隐藏步骤——Creator 定义几步就是几步，pipeline 步骤数必须与业务步骤数一致。
- ⛔ 禁止修改 Python SDK。

### 写代码前：必须查 API 文档（硬性前置步骤）

⛔ **禁止凭记忆或推测写 API 调用代码。** 每个 `ctx.sif.request(...)` 调用前，检查当前对话中是否已有该接口的 `get_endpoint_details` 返回结果（维度 ① 查过的接口会在上文出现完整的参数和响应定义——有则直接使用，不需要重新查询）。只有维度 ① 未涉及的新接口才需要调用 MCP 查询。需确认以下三项：

1. **HTTP 方法和参数名**：用 `get_endpoint_details` 查端点详情，确认 method（GET/POST）、参数名（如 `keywords` 不是 `searchKeyword`）、参数类型（数组/字符串）、参数位置（body/query）
2. **响应结构**：确认返回数据的嵌套层级和字段名（如数据在 `list` 还是 `dataList`，ASIN 详情在 `asinDetail` 子对象还是扁平字段）
3. **ctx.sif.request 返回值已解包**：SDK 会自动解包 API 响应的外层 `{"code":1, "data":{...}}`，`ctx.sif.request` 返回的就是 `data` 的内容。直接从返回值取字段（如 `resp.get("list")`、`resp.get("keywords")`）——再写 `resp.get("data")` 会拿到 None
4. **Null 安全**：外部 API 返回的数值字段可能是显式 `null`（不是缺失），`.get(key, 0)` 防不住——key 存在但值为 None 时仍返回 None。必须用 `or` 兜底：`kw.get("estSearchesNum") or 0`，排序用 `key=lambda r: r["field"]`（字段在构造时已兜底）
5. **前后端字段对齐**：后端 payload 的 key 和前端渲染读取的 key 必须完全一致
6. **数据契约完整性**：Creator 已确认展示的每个字段必须逐项核对真实接口或计算来源。切换接口后逐项重新核对。⛔ 禁止在尚未接入真实数据来源时，用固定占位值 `"-"`、`"—"`、`"N/A"` 伪装成已完成。接口已真实调用但个别数据为空时，可以展示缺省值。如果无法提供某字段，先向 Creator 说明并确认删减。

```bash
# 示例：写 competePatternFlexibleGroupByWeekly 调用前
mcp get_endpoint_details("competePatternFlexibleGroupByWeekly")
# 确认：method=POST, body 参数 keywords(array), 响应 data.list[].asinDetail.title
```

⛔ P0：未经 `get_endpoint_details` 确认的参数名和响应字段名，一个都不能写进代码（`keywords` vs `searchKeyword`、`list` vs `dataList` 这类猜测命中率极低，错一个字段整步白跑）。

### 前后端字段名一致性

前端 `confirmedKey` 和后端 `ctx.last_user_input.get(key)` 必须使用**完全相同的字符串**。统一用 camelCase。

```
# 正确：两端一致
前端: confirmedKey: 'selectedAsins'
后端: ctx.last_user_input.get("selectedAsins")

# 错误：大小写/风格不一致
前端: confirmedKey: 'selectedAsins'
后端: ctx.last_user_input.get("selected_asins")  ← 读不到
```

### 后端代码（pipeline.py）

写后端代码前，检查 `generate-node-code` 的输出——如果输出了 `SDK_DOC_PATH=...`，**必须先 Read 该文件**，从文档中确认 `ctx.*` 的属性名、方法签名和用法示例，然后再写代码。如果输出了 `SDK_CTX_PATH=...`（SDK 尚未附带 README 的 fallback），**必须先 Read 该源码文件**，从 `@property` 和方法定义中确认正确的属性名和参数签名。

⛔ **禁止凭记忆写 `ctx.*` 调用。** 正确的属性名只能从 SDK 文档、门禁输出或 SDK 源码中获取。上下文中没有对应方法签名时必须查文档，文档查不到就去 Read `.venv` 里 `minus_ai_sdk/` 下的源码确认。

### 前端代码（frontend/src/main.tsx）

写前端代码前，先读项目 CLAUDE.md 中列出的前端 SDK 开发手册（如 frontend-guide.md），根据当前步骤的 `CONFIRM_MODE`（auto/interactive）和展示需求，从文档中查找对应的组件用法和示例代码。组件选择、prop 名称、回调签名都以文档为准——凭记忆写大概率对不上当前版本。

项目 `CLAUDE.md` 中的前端 SDK 文档使用远程 `${platformUrl}/runtime/...` 稳定地址。文档不可达时，明确告诉 Creator 并停止写前端代码——文档是唯一可靠来源，遍历用户目录、找本地 runtime 包或解析 minified CDN JS 得到的"API"不可信。

#### ⛔ 使用 `@minus/*` 能力前必须查 `${platformUrl}/runtime/` 文档确认 props

`${platformUrl}/runtime/` 是 `@minus/*` 的权威文档和运行时来源：

- `${platformUrl}/runtime/frontend-guide/doc.md` — 前端 SDK 手册（步骤 ⑤ 已读取），覆盖 defineWidgetStep、常用组件用法、时序模式等
- `${platformUrl}/runtime/platform-widgets/docs.md` — platform-widgets 组件文档（Chart、SelectableTable 等完整 props）

如果步骤 ⑤ 读取的前端 SDK 手册中已有该组件的完整 props 示例和行为说明，直接使用。手册未覆盖的组件，查 `${platformUrl}/runtime/` 下对应包的文档。文档仍不够时，再去读 platform 仓库源码确认：

```bash
# 源码位置（在 platform 仓库，不在项目 .venv 里）
# widget-framework: packages/widget-framework/src/    （FlowApp、Timeline、defineWidgetStep 等框架行为）
# platform-widgets: packages/platform-widgets/src/    （Chart、EChart、SelectableTable、CompletionPanel 等组件）
```

⛔ 禁止凭记忆写 props 或假设框架行为。遇到展示效果不符预期时，**先查 `${platformUrl}/runtime/` 下的文档，文档不够再读源码的 props interface 和 JSDoc**，检查是否有现成 prop 或框架内置行为能解决，再考虑手写。高层组件有现成 prop 能解决的问题（如 Chart 的 `colorByData`），降级到底层组件手写 option 是反模式。

#### ⛔ 步骤摘要由框架自动展示，禁止在 render 里重复渲染

后端 payload 中带 `summary` 字段时，框架会自动在步骤卡片上展示该摘要。**禁止在 `StepConfig.render` 里再手动渲染步骤摘要**——否则同一段摘要会出现两份。注意：只有 Creator 明确要求摘要时才加 `summary` 字段（见「步骤摘要规则」）。详见前端 SDK 手册（frontend-guide.md）的「用户确认后的步骤摘要」章节。

需要在默认确认值之外向下一步追加字段时，使用前端 SDK 手册里的 `extendConfirmed`；`mapConfirmed` 是完全自定义 payload 的高级能力，使用不当会导致 readonly 回放丢失用户选择。

### locale 文件

`frontend/src/locales/*.json` ⛔ 禁止用 Edit 直接修改（手工编辑会破坏 JSON 格式），必须走脚本：

```bash
minus-lib locale-set set frontend/src/locales/zh-CN.json "{key}" "{文案}"
minus-lib locale-set rm  frontend/src/locales/zh-CN.json "{key}"
```

### 代码生成后

1. 执行 `step-tracker.sh check {step_number}` 确认四维度全部 COMPLETE

<!-- TODO（暂时注释，先不管）：前端类型检查门禁。
     当前 `@minus/*` 真实类型到不了编译期（兜底桩 `declare module '@minus/*';` 让类型塌成 any），
     check-frontend 在任何真实项目上都过不了，硬门禁会死锁流程。
     待平台「类型随运行时 JS 动态下发」落地（详见项目根目录 CLAUDE.md「@minus/* SDK 类型契约」章节）后恢复：

2. 执行前端类型检查硬门禁（输出 `FRONTEND_OK` 才能继续；`GATE_FAILED` 时 Agent 必须自己修到通过，包括 tsconfig 配置错误——配置错误意味着类型检查整体失效，不是可忽略的小报错）：

```bash
minus-lib check-frontend
```
-->

3. 执行 Python 依赖一致性检查：

```bash
minus-lib check-python-deps
```

- 如果输出 `DEPENDENCIES_OK` → 继续
- 如果报缺失依赖 → Agent 自己修复：把依赖写进 `pyproject.toml` 再执行 `uv pip install -e .`（只装进 `.venv` 不更新 pyproject，换环境就丢），然后重新检查；通过前不要让 Creator 测试（依赖修复是 Agent 的事，不交给 Creator 手动处理）
- 验证依赖用项目 venv 的 python（Unix：`.venv/bin/python`；Windows：`.venv/Scripts/python.exe`）——系统 `python3` 看不到 venv 里的包，结果不可信

4. 用 `skill_update` 更新后端步骤状态为 completed（传入 .minus/skill.json 中的 skillId 和 version）
5. 执行 `minus-lib update-progress step-done {step_number}`（自动标记本步骤完成、推进 currentStep；最后一步会自动进入待测试阶段）。⛔ 禁止手写 `.minus/progress.json`。
6. 脚本会输出测试邀请话术（单源在脚本里）：原样转达「」内的行（每行独立），然后**停止，等 Creator 回复**。
   - ⛔ 禁止把 step-done 与其他流程命令（如 generate-result-design）串在一条命令里执行
   - 最后一步：Creator 确认整体测试通过后，先执行 `minus-lib update-progress confirm-test`，再进入结果呈现设计（其门禁会校验该确认）

### 修改已完成步骤的处理逻辑

Creator 可能在步骤完成后要求追加功能（如"加一个大模型摘要"）。如果追加的功能**改变了该步骤的处理模式**（例如原本是 deterministic 排序，现在要加 `ctx.llm.chat` 调用），必须重新标记 logic 维度：

```bash
# 重置 logic 维度并重新确认
minus-lib step-tracker ask <step> logic
# Creator 确认后
minus-lib step-tracker complete <step> logic <新模式>
# 然后重新执行 generate-node-code 门禁
minus-lib generate-node-code <step>
```

⛔ 禁止在 logic_mode=deterministic 的步骤里直接加 LLM 调用而不更新 logic_mode。元数据和代码不一致会导致后续门禁和流程路由判断错误。

### 测试期间的代码修改保护

Creator 可测试后（任一步骤 step-done 之后），修改 pipeline.py 会触发后端热重载，**正在跑的流程会被立刻打断**。因此：

- 修改 pipeline.py 或重启 dev server 前，先执行 `minus-lib check-running-flow`
- 输出 `RUNNING` → 先问 Creator：「你当前正在跑的流程会被这次修改打断，现在改还是等你跑完？」，Creator 同意后再动
- 输出 `IDLE` → 直接修改

## 代码生成规则

生成的每个节点代码必须包含三层：

```javascript
async function executeStep(input, context) {
  // 第一层：数据获取（确定性，直接 HTTP API 调用）
  const data = await fetch("https://api.example.com/...", { ... });

  // 第二层：数据处理（确定性代码 或 LLM 调用）
  const processed = ...; // 排序/过滤/格式化用代码；分析摘要用 LLM

  // 第三层：输出渲染（确定性，minus.output.* 工具）
  return {
    display: [...],      // 展示给用户
    passToNext: { ... }  // 传给下一步
  };
}
```

原则：能用确定性代码解决的不用 LLM。

## 交互规则

- 四个维度按顺序收集意图，全部确认后才写代码
- Creator 只需确认业务逻辑，代码在后台一次性生成
- 如果 Creator 的需求不明确，用具体例子引导
- Creator 可在浏览器中体验效果并提出修改意见
