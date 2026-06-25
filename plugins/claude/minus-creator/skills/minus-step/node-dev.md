# 节点开发引导

帮 Creator 完成一个 pipeline 步骤的具体开发。

## 插件脚本调用方式

插件脚本通过 `minus-lib <脚本名> [参数]` 裸命令调用（bin/ 已在 PATH 上），如 `minus-lib generate-node-code 1 deterministic auto`。

## 任务

进入步骤开发时，先检查 pipeline.py 中对应步骤函数的状态：

- **函数不存在**（Creator 要新增步骤）→ 先执行 `minus-lib generate-steps --append "步骤名称"` 创建骨架（自动注册平台步骤名、更新 main.tsx、更新 total-steps），然后按下方四维度流程执行
- **函数存在且包含 `# TODO: 实现「` 骨架占位** → 未开发，按四维度流程执行
- **函数存在且无骨架占位** → 已有代码，进入修改流程

引导 Creator 按顺序确认当前 pipeline 节点的四个维度意图，**全部确认后一次性生成代码**。

⛔ 核心规则：

- 每个维度的业务意图必须得到 Creator **明确**确认后才能进入下一个
- **明确确认** = Creator 清楚说出了该维度的具体内容（如"表格""排序""自动继续"）；Agent 推断、联想、从技能名猜测出来的**不算明确表达**
- **四个维度的问答阶段只收集意图，不写任何代码**
- **所有维度全部确认后，一次性生成 pipeline.py + main.tsx 代码**
- **禁止抢答**：Creator 的回复只有在你已提出该维度问题之后，才算该维度的回答。不确定 Creator 在回答哪个维度时，先复述理解请 Creator 确认，禁止自行判断并标记完成

## 每个维度的标准流程

对于每个维度：
1. **进入前先回顾**：检查 Creator **在当前步骤的问答中**是否已经覆盖了本维度的内容（⛔ 只看当前步骤，其他步骤的对话不算）
   - 已覆盖 → 不要从头提问，改为复述你的理解并请 Creator 确认（如「你前面说了要展示趋势曲线 + 体量数字 + 一段解读总结，展示内容就按这个来，可以吗？」），Creator 确认后直接进入下一维度
   - 未覆盖 → 正常提出该维度的问题（结合具体建议）
2. 等待 Creator 明确回复
3. 记住 Creator 的回答，进入下一维度

⛔ **禁止对已有答案视而不见地重新提问。** Creator 的回答经常一句话覆盖多个维度（如回答处理逻辑时顺带说了展示内容），进入后续维度时必须识别出来，用确认式推进代替从头提问。

⛔ **上下文隔离**：每个步骤的四维度问答是独立的。回顾 Creator 回答时，只看「当前步骤」开发过程中 Creator 说的话。其他步骤的对话（包括其他步骤确认的展示形式、处理逻辑等）不能当作当前步骤的已知需求。Creator 主动引用其他步骤时（如"跟上一步一样"）除外。

## 阶段一：逐维度收集意图

### ① 数据需求

数据源选择是开发侧的职责：进入维度 ① 时立即执行下面的接口发现流程，把能拿到的数据用通俗语言列给 Creator 确认（"数据从哪来""用什么接口""你有特定数据源吗"这类问题不抛给 Creator——他们答不了）。

**数据接口发现流程：**

0. 先确认当前步骤的**输入数据是什么**。
   - **第 1 步**：读 `frontend/src/main.tsx` 和 `frontend/src/locales/zh-CN.json`，找到 Home 组件的输入表单（placeholder、字段名、onStart 传参），以用户实际输入的类型（关键词？ASIN？类目 ID？）作为后续搜索接口的依据。
   - **第 2 步及之后**：先读 `pipeline.py`，找到前序步骤的 `step_N` 方法，确认它的 `StepOutcome.data` 里传了哪些字段给当前步骤。上一步已经传过来的数据直接用，不需要重新调 API 获取。只有上一步没提供、当前步骤确实需要额外获取的数据，才进入下面的接口发现流程。
1. 调用 `ToolSearch("mcp__")` 发现当前会话中可用的 MCP 工具（这些工具来自插件 `.mcp.json` 中配置的 MCP 服务，会话启动时已自动注册）。排除 `mcp__plugin_minus-creator_minus-platform__` 开头的（那是平台管理工具），剩下的就是数据服务商的工具。工具列表和参数 schema 只能通过 ToolSearch 获取（`.mcp.json` 里只有启动配置，没有这些信息）。
2. 用该服务的搜索工具搜索与当前步骤相关的数据 API
3. 如果搜索返回多个候选接口，用详情查询工具逐个查看参数要求，**选参数最简单、最匹配当前场景的接口**（只看第一个结果就决定经常选错）
4. 用通俗语言向 Creator 展示能获取的数据（如"可以查到搜索量、点击率、竞争度"），等 Creator 确认

⛔ P0：写进确认内容的接口必须来自上述 MCP 发现流程的真实结果。找不到合适接口时，如实告诉 Creator 这一步取不到数据并讨论调整——不读本地 SDK 源码猜接口，不用 mock 数据顶替。

**重要：MCP 只用于开发阶段发现 API。生成的代码通过 SDK 调用 API（如 SIF 数据源用 `ctx.sif.*`），不依赖 MCP。具体用哪个 SDK 方法，参考 MCP 返回的接口文档。**

接口发现完成后，向 Creator 确认（原样转达，[…] 处填入实际发现的数据字段）：

「这一步能拿到以下数据——[在此填入接口发现的数据字段]。这些数据够用吗？还是需要补充？」

**等 Creator 确认后进入下一维度。**

### ② 处理逻辑

处理逻辑可以是确定性代码、SDK LLM 能力，或两者组合。一步内可以同时包含两种：先用代码做结构化处理，再用大模型基于处理后的数据生成分析内容。

建议判断原则：**先看步骤目的，再结合数据特征。** 步骤目的是得出结论/判断/解读（步骤名含"分析""洞察""评估""对比""推荐"等），且数据维度足够丰富（多个字段可交叉比较）→ 建议用大模型。步骤目的是筛选/排序/聚合/格式化，或数据维度单一（只需排序/取 Top N 就能完成目的）→ 建议纯代码。
- 正例：步骤叫「热门产品分析」，数据有价格/销量/评分/评论数多个维度 → 建议 LLM（多维数据交叉分析出结论，纯代码做不到）
- 反例：步骤叫「筛选高评分产品」，数据同样有多个维度但目的只是筛选 → 建议纯代码（Creator 要的是筛选结果）

常见操作速查（参考）：

| 纯代码 | LLM |
|--------|-----|
| 获取 API 数据、数字格式化、排序/过滤/分组/去重、表格渲染/文件生成 | 分析摘要、对比分析/趋势解读、智能推荐（含主观判断）、报告文案 |

向 Creator 输出以下三部分（**同一条消息内全部说完**，不要说完前两句就停下等回复）：

「下一个问题：拿到这些数据之后，怎么处理？」

「比如：直接透传原始数据？做聚合/排序？用大模型做分析总结？也可以组合，比如先排序再让大模型总结。」

「我的建议：[基于上述判断原则，结合当前步骤的名称/目的和维度 ① 已确认的具体数据，给出处理方式建议]」

如果使用 LLM，必须先完成一次动态确认，不暴露技术细节：

1. 根据当前步骤的数据内容、Creator 已表达的业务目标和上下文，动态生成需要确认的问题（固定问题清单无法贴合具体数据语境，不要照搬）。
2. Creator 回答后，用通俗语言归纳大模型将生成什么、重点关注什么、有哪些边界，并询问「这样可以吗？」
3. 只有 Creator 明确确认后，才能记录 logic 为 llm 并进入下一维度。

Creator 确认后，记住处理模式（deterministic 或 llm），**进入下一维度**。

### ③ 输出定义

只收集展示意图（不写代码）：

- **展示给用户的内容**：表格、摘要、卡片等
- 传给下一步的数据在维度 ④ 确认后再问
- ⛔ **禁止自动补展示内容**：代码只能渲染 Creator 在输出定义阶段明确确认的展示内容。接口返回字段、计算中间值、排序依据、调试信息，都不是默认展示内容。Creator 只说"表格"就只生成表格。

**⛔ 必须先执行以下判断，禁止跳过直接提问：**

**首先判断：维度 ② 记录的 logic 是 llm 还是 deterministic？**

- **llm**：LLM 的分析产出自动作为步骤摘要（summary），不需要 Creator 说"我要摘要"。向 Creator 输出（**同一条消息内全部说完**）：

  「大模型的分析内容会自动展示为步骤摘要。除了这个摘要之外，还需要额外展示什么数据吗？比如产品卡片、数据表格、排行榜……不需要的话这一步就只展示分析结果。」

  「我的建议：[基于当前步骤除 LLM 分析产出之外的结构化数据，判断有没有值得额外展示的内容。如有则推荐具体形式，如无则建议只保留摘要]」

- **deterministic**：回顾 Creator **在当前步骤**维度 ①② 中的回答，判断是否已经说了要展示什么（⛔ 其他步骤的对话不算）：

  - **已说了展示内容**（Creator 提到了表格、图表、曲线、摘要、卡片、列表等具体展示形式）→ **禁止再问"这一步要展示什么给用户看"**，改为复述确认：「你前面说了要展示 [复述具体内容，如"趋势曲线 + 体量数字 + 一段解读总结"]，展示内容就按这个来，可以吗？」Creator 确认后 → 进入下一维度
  - **未说展示内容**（Creator 只说了处理逻辑，没提到具体展示形式）→ 向 Creator 输出以下三部分（**同一条消息内全部说完**）：

    「下一个问题：这一步要展示什么给用户看？」

    「比如：一个数据表格、一段文字摘要、一个卡片……」

    「我的建议：[基于当前步骤的数据特征推荐展示形式——结构化多行数据→表格，时间序列→图表，单条详情→卡片。推荐理由必须从数据特征推出，不能用其他步骤的目的作为当前步骤展示形式的理由]」

**等 Creator 确认后进入下一维度。**

**最后一步判断**：读 `.minus/total-steps` 中的数字，如果当前步骤编号 >= 该数字，则为最后一步。最后一步没有维度 ④（最后一步没有"传给下一步"的概念），直接进入阶段二。

### ④ 用户确认 + 传递数据

本维度只在非最后一步时进入。

**⛔ 必须先执行以下判断，禁止跳过直接提问：**

回顾 Creator **在当前步骤**维度 ①②③ 中的回答，判断 Creator 是否已经表达了用户交互意图（⛔ 其他步骤的对话不算）：

- **已表达交互意图**（Creator 提到了勾选、选择、复选框、用户确认、筛选等用户操作动作）→ 确认模式 = interactive。**禁止再问"需要暂停让用户确认吗"**，改为复述确认：「你前面说了要让用户 [复述具体操作，如"勾选想要的词"]，所以这一步会暂停等用户操作完再继续，对吧？」Creator 确认后 → 直接跳到下面的「传递数据」
- **未表达交互意图**（Creator 只描述了纯展示，没提到任何用户操作）→ 正常提问：「下一个问题：用户运行到这一步后，需要暂停让用户确认数据再继续吗？还是自动往下走？」

按字面映射：说"需要确认"→ interactive；说"自动继续"或"用户不用确认"→ auto（"不用确认"是 auto 的同义表达，不是 interactive）。

**传递数据：**

根据维度 ①②③ 已确认的内容（数据源、处理逻辑、展示内容）和 Skill 整体步骤设计，推断这一步应该传给下一步哪些数据。除了这一步自身的产出，还要看后续步骤是否会复用这一步已经拿到的信息（如类目、站点、关键词清单等），如果会复用就一起推荐传下去，省得后续步骤重复查接口。

推荐时用业务语言描述每条数据是什么、后面哪些步骤会用到。条目数量不固定，由实际情况决定。始终给出具体推荐，Creator 只需确认或修正。

如果 interactive：

「好，用户需要先确认再继续。」

「下一个问题：那什么数据传给下一步？我的建议：」

然后列出推荐，说明每条数据后面哪些步骤会用到。interactive 模式下注意区分哪些是用户选择的数据（如勾选的关键词）、哪些是自动带过去的（如类目、站点信息）。例如：这一步展示了关键词表格，就说「**类目身份**（哪个类目、哪个站点）——后面每步都要用，自动带过去不需要用户操心；**用户选中的关键词**——用户从表格里勾选的那些词。这样可以吗？」

如果 auto：

「好，自动往下走。」

「下一个问题：那什么数据传给下一步？我的建议：」

然后列出推荐，说明每条数据后面哪些步骤会用到。例如：这一步做了关键词筛选，就说「**类目身份**（哪个类目、哪个站点）——后面分析要围绕它；**核心关键词清单**——这一步已经查出来了。这样可以吗？」

Creator 确认后，**进入阶段二**。

## 阶段二：一次性生成代码

四个维度全部确认后，执行代码生成门禁：

```bash
minus-lib generate-node-code {step_number} {logic_mode} {confirm_mode}
```

其中 `logic_mode` 是维度 ② 确认的处理模式（deterministic 或 llm），`confirm_mode` 是维度 ④ 确认的交互模式（auto 或 interactive，最后一步固定传 auto）。

- 如果输出 `GATE_PASSED` → 可以开始写代码
- 如果报错 → 按提示修正

⛔ **禁止在门禁通过前编辑 pipeline.py 或 main.tsx。** 任何代码修改必须在 `generate-node-code.sh` 返回 `GATE_PASSED` 之后。

根据门禁输出的 `LOGIC_MODE`、`LLM_REQUIRED`、`CONFIRM_MODE` 和收集到的意图一次性生成所有代码。`LLM_REQUIRED=YES` 时，后端必须使用 SDK 内置 LLM 能力。

### 步骤摘要规则

⛔ **summary 字段的两种来源**：① 维度 ② 确认使用 LLM 分析/总结/解读时，LLM 产出自动作为 summary（维度 ③ 已告知 Creator 并确认）；② Creator 在输出定义阶段主动要求"摘要/总结/概览"。两种情况之外，禁止自行生成 summary。

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

写前端代码前，必须完成两步：

1. **组件选型**（⛔ 每个步骤都要做，不能用"上一步已查过"跳过——每步展示需求不同）：重新读项目 CLAUDE.md「前端 SDK 参考」中的组件索引，对照维度 ③ 确认的展示需求选出合适的现成组件。**只有确认没有合适组件时才手写 JSX。**
2. **确认 props**：选定组件后，从文档中确认 props、回调签名等。组件选择、prop 名称、回调签名都以文档为准——凭记忆写大概率对不上当前版本。

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

1. 执行 Python 依赖一致性检查：

```bash
minus-lib check-python-deps
```

- 如果输出 `DEPENDENCIES_OK` → 继续
- 如果报缺失依赖 → Agent 自己修复：把依赖写进 `pyproject.toml` 再执行 `uv pip install -e .`（只装进 `.venv` 不更新 pyproject，换环境就丢），然后重新检查；通过前不要让 Creator 测试（依赖修复是 Agent 的事，不交给 Creator 手动处理）
- 验证依赖用项目 venv 的 python（Unix：`.venv/bin/python`；Windows：`.venv/Scripts/python.exe`）——系统 `python3` 看不到 venv 里的包，结果不可信

2. 用 `skill_update` 更新后端步骤状态为 completed（传入 .minus/skill.json 中的 skillId 和 version）
3. 执行 `minus-lib update-progress step-done {step_number}`（自动标记本步骤完成、推进 currentStep；最后一步会自动进入待测试阶段）。⛔ 禁止手写 `.minus/progress.json`。
4. 脚本会输出测试邀请话术（单源在脚本里）：原样转达「」内的行（每行独立），然后**停止，等 Creator 回复**。
   - ⛔ 禁止把 step-done 与其他流程命令（如 generate-result-design）串在一条命令里执行
   - 最后一步：Creator 确认整体测试通过后，先执行 `minus-lib update-progress confirm-test`，再进入结果呈现设计（其门禁会校验该确认）

### 修改已完成步骤的处理逻辑

当 pipeline.py 中对应步骤已有实际代码（无骨架占位）时，进入修改流程。先区分修改类型：

**Bug 修复**（Creator 说"有 bug"/"不对"/"没生效"/"报错"等故障症状）：不重走任何维度，直接读代码和后端日志定位问题并修复。意图没变，只是代码写错了。

**功能修改**（Creator 说"加一列"/"换接口"/"改成手动确认"等功能调整）：**不重走全部四维度**，只针对受影响的维度重新确认。

**第一步：判断修改影响了哪些维度**

根据 Creator 的修改意图对照：

| 修改内容                     | 受影响维度 |
| ---------------------------- | ---------- |
| 换数据接口 / 改数据来源      | ① data     |
| 改排序、过滤、聚合逻辑       | ② logic    |
| 加 LLM 分析 / 改处理模式     | ② logic    |
| 改展示字段、表格列、卡片内容 | ③ output   |
| 改确认方式（自动/手动）      | ④ confirm  |

一次修改可能影响多个维度（如"换接口并改展示字段" → ① + ③）。

**第二步：只针对受影响维度重新确认**

向 Creator 确认受影响维度的新意图，未受影响的维度保留原状不重新询问。全部确认后重新调用：

```bash
minus-lib generate-node-code {step} {logic_mode} {confirm_mode}
```

其中 `logic_mode` 和 `confirm_mode` 使用更新后的值（如果 logic 维度被修改了就用新值，否则沿用原值——从现有代码判断：有 `ctx.llm` 调用 = llm，否则 = deterministic；有 `StepOutcome.input_required` = interactive，否则 = auto）。

⛔ 判断不清哪些维度受影响时，向 Creator 简要说明修改涉及的维度并确认，不要默认全部重走。

### 测试期间的代码修改保护

Creator 可测试后（任一步骤 step-done 之后），修改 pipeline.py 会触发后端热重载，**正在跑的流程会被立刻打断**。因此：

- 修改 pipeline.py 或重启 dev server 前，先执行 `minus-lib check-running-flow`
- 输出 `RUNNING` → 先问 Creator：「你当前正在跑的流程会被这次修改打断，现在改还是等你跑完？」，Creator 同意后再动
- 输出 `IDLE` → 直接修改

## 交互规则

- 四个维度按顺序收集意图，全部确认后才写代码
- Creator 只需确认业务逻辑，代码在后台一次性生成
- 如果 Creator 的需求不明确，用具体例子引导
- Creator 可在浏览器中体验效果并提出修改意见
