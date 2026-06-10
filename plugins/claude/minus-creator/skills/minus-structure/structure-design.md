# 结构设计引导

Plugin 的角色是**帮 Creator 结构化表达想法**，不是替 Creator 规划。一次只聚焦一个问题。

## 第一步：确定输入

**必须按以下三个子步骤顺序执行，禁止跳步：**

**① 确认输入类型和数量：**
Creator 回答后，先确认输入类型（ASIN/关键词/文件等）和数量限制。
如果 Creator 只说了类型没说数量，原样输出以下追问（不改写、不省略）：
「用户可以输入几个？只能一个、一个或多个、还是至少两个」
⛔ 禁止简化为"一个或多个？"——必须包含全部三个选项。

**② 问提示语（placeholder）：**
确认类型和数量后，必须追问输入框的提示语怎么写。
⛔ 禁止跳过此步，不管什么输入类型都必须问。

**③ 输出确认：**
提示语确认后才输出"✓ 输入定义确认"，然后立即写入进度文件：

```bash
printf '{"currentStep":0,"steps":{},"phase":"designing","designStage":"input_done","updatedAt":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .minus/progress.json
```

**首次提问必须原样输出以下内容（不改写、不省略、不合并，任何需要问这个问题的场景都用这段话）：**

「用户使用这个 Skill 时，需要提供什么信息？」
「比如关键词、ASIN、品类……」
「还有，用户可以输入几个？只能一个、一个或多个、还是至少两个」

对话示例 A — Creator 同时回答了类型和数量：

```
Plugin: 用户使用这个 Skill 时，需要提供什么信息？
       比如关键词、ASIN、品类……
       还有，用户可以输入几个？只能一个、一个或多个、还是至少两个

Creator: 一个主关键词

Plugin: 好的，一个主关键词。                          ← ①
       用户输入时的提示语你想写什么？比如"请输入要调研的关键词"？  ← ②

Creator: 就写"输入主关键词，如 wireless earbuds"

Plugin: ✓ 输入定义确认。                              ← ③
```

对话示例 B — Creator 只回答了类型，没说数量：

```
Plugin: 用户使用这个 Skill 时，需要提供什么信息？
       比如关键词、ASIN、品类……
       还有，用户可以输入几个？只能一个、一个或多个、还是至少两个

Creator: 关键词

Plugin: 好的，关键词。                                ← 确认类型
       用户可以输入几个？只能一个、一个或多个、还是至少两个  ← 原样追问数量

Creator: 一个或多个

Plugin: 好的，一个或多个关键词。                       ← ①
       用户输入时的提示语你想写什么？比如"请输入要调研的关键词"？  ← ②
```

确认后更新前端代码：

**根据输入类型在前端 `frontend/src/main.tsx` 的 Home 组件中添加输入区域：**

默认模板（inputType: default）的 Home 组件只有元信息展示（title、description、useCases、tags），没有输入组件。确认输入类型后，需要在 Home 中添加完整的输入区域：

1. 给 Home 添加 `onStart` prop
2. 添加输入状态（`value`、`country`、`error`、`loading`）
3. 添加 `handleSubmit` 函数 + 对应验证：keyword → `validateKeywords`，ASIN → `validateAsins`
4. 添加输入组件：keyword/ASIN → `AmazonSearchBar` + `CountrySelect` + `SearchSubmitButton`，file → `FilePicker`
5. 补上对应的 import（`AmazonSearchBar`、`CountrySelect`、`SearchSubmitButton`、`validateAsins` / `validateKeywords`）
6. 更新 `frontend/src/locales/` 下的 locale 文件中的 placeholder
7. 更新 `renderHome` 调用，传入 `onStart`
8. 数量限制通过验证函数的第二个参数 `{ min, max }` 控制，具体签名读 SDK 类型定义
9. 同步更新 `renderHistoryItem` 中的主标识字段名，与 `handleSubmit` 中 `onStart` 的字段名一致：
   - keyword → `label: inp?.keywords ?? '—'`，`meta: inp?.country || undefined`
   - asin → `label: inp?.asins ?? '—'`，`meta: inp?.country || undefined`
   - file → `label: inp?.fileName ?? '—'`
   - default/custom → `label: inp?.text ?? '—'`

参考现有模板（`asin/main.tsx.tpl` 或 `keyword/main.tsx.tpl`）的 Home 组件结构来添加。

**如果 Home 已有输入组件（切换类型场景）：** 按最小改动原则，改验证函数 + onStart 字段名 + locale 文案，保留组件不动。

⛔ 禁止：只改 main.tsx 不改 locale 文件。placeholder、按钮文案等必须同步更新 `frontend/src/locales/` 下的 locale 文件。
⛔ 禁止：在 Creator 确认输入类型之前就添加输入组件。
⛔ 禁止：把 AmazonSearchBar 替换为原生 textarea 或 input。AmazonSearchBar 是平台组件，placeholder 通过 locale 文件控制，不是通过 HTML 属性。
⛔ 禁止：更新 Home 输入组件后不同步更新 renderHistoryItem。两者的字段名必须匹配。

## 第二步：拆解步骤

```
Plugin: 第二个问题：拿到用户的关键词后，Skill 要分几步完成？
       每一步做什么？按你的思路说就行。（后续随时都可以调整）

Creator: 先查搜索量和趋势，然后看竞争度有多激烈，最后推荐一些相关的长尾词

Plugin: 整理一下，3 步：
       1. 关键词数据采集 — 搜索量、趋势
       2. 竞争度分析 — 竞争密度、排名难度
       3. 长尾词推荐 — 扩展相关词，按潜力排序
       有没有要加的或者要调整的？

Creator: 差不多就这样

Plugin: ✓ 步骤结构确认。
```

确认后用 `skill_update` 将步骤结构写入后端（**字段必须是 stepNumber + stepName，不要用其他字段名**）：

```json
{
  "skillId": "从 .minus/skill.json 读取",
  "version": "从 .minus/skill.json 读取",
  "updates": {
    "steps": [
      { "stepNumber": 1, "stepName": "关键词数据采集" },
      { "stepNumber": 2, "stepName": "竞争度分析" },
      { "stepNumber": 3, "stepName": "长尾词推荐" }
    ]
  }
}
```

**后端是步骤定义的唯一数据源。** 所有平台 API 的字段格式参照 `.claude/api/openapi-bundled.yaml`。

⛔ 禁止：在更新 steps 时顺带修改 description、displayName 等其他字段。每次 `skill_update` 只传 Creator 明确确认的字段。

然后执行 Bash 命令生成步骤骨架代码（**必须执行，不要自己手写**）：

```bash
minus-lib generate-steps --input-type keyword "步骤1名称" "步骤2名称" "步骤3名称"
```

`--input-type` 的值对应第一步确认的输入类型（keyword/asin/file/default）。脚本会自动更新 `pipeline.py`（生成 step_N 方法）、`frontend/src/main.tsx`（更新 buildSteps 渲染配置和 renderHistoryItem 字段名），保证前后端代码和后端步骤定义数量一致。

**添加新步骤（已有步骤不受影响）：**

如果 Creator 在节点开发过程中要求新增步骤，使用 `--append` 模式：

```bash
minus-lib generate-steps --append "新步骤名称"
```

此模式只在已有代码后面追加新步骤骨架，不会覆盖已实现的步骤代码。同时更新 `.minus/total-steps` 和 `main.tsx` 的 `buildSteps`。

**结构设计完成后，保存进度到 `.minus/progress.json`：**

```json
{
  "currentStep": 1,
  "steps": {
    "1": { "name": "步骤1名称", "status": "pending" },
    "2": { "name": "步骤2名称", "status": "pending" }
  },
  "phase": "developing",
  "updatedAt": "ISO8601 时间戳"
}
```

⛔ 禁止：对已有步骤的项目使用不带 `--append` 的 `generate-steps.sh`，这会覆盖所有已实现的代码。
⛔ 禁止：手写 pipeline.py 和 main.tsx 的步骤结构。必须用 generate-steps.sh 生成骨架，只在骨架基础上填充逻辑。

## 结构设计完成后

保存进度后，**立即** Read [node-dev.md](../minus-step/node-dev.md)，从步骤 1 开始逐节点开发。

⛔ **硬性规则：禁止不加载 node-dev.md 就直接编辑 pipeline.py 或 main.tsx 的步骤代码。** node-dev.md 包含数据接口发现（通过 MCP 查找 API）、处理逻辑选型、输出设计等关键流程，跳过它会导致 Agent 自己猜接口而非用正确的数据源。
