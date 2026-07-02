# 结构设计引导

Plugin 的角色是**帮 Creator 结构化表达想法**，不是替 Creator 规划。一次只聚焦一个问题。

### 任务清单（单源定义，仅适用于初次设计）

本清单是初次结构设计两件事的唯一权威定义，开场白、切换报站话术都从这里取名字。已有步骤代码的项目走「已有项目的步骤结构变更」，不适用本清单。

| 序号 | 名称 |
|------|------|
| ① | 用户需要提供什么信息 |
| ② | 流程分几步以及每步具体做什么 |

## 第一步：确定输入

**必须按以下三个子步骤顺序执行，禁止跳步：**

**首次提问必须原样输出以下内容（不改写、不省略、不合并，任何需要问这个问题的场景都用这段话；代码块本身不输出）。下文标记为「开场白」：**

```
我们要确认两件事：用户需要提供什么信息、流程分几步以及每步具体做什么——先看第一件。
用户使用这个 Skill 时，需要提供什么信息？
比如关键词、ASIN、品类……不限于这些，按你的思路说就行
```

**① 确认输入类型和数量：**
Creator 回答后，直接采信其给出的输入类型（ASIN/关键词/文件等，哪怕是开场白里的示例词），按下面的属性判断决定是否追问数量：

- **判断标准：这个输入，用户提供多个是否说得通？**（不按类型清单枚举，按属性判断）
- 说得通（如关键词、ASIN），且 Creator 没说数量 → 原样追问（不改写、不省略，代码块本身不输出）：

```
用户可以输入几个？只能一个、一个或多个、还是至少两个（比如做对比分析，通常
至少要两个）
```

- 说不通（如上传一份待分析的文件）→ 跳过数量追问，直接进入 ②
- **拿不准 → 问。**多问一句数量代价只有几秒；该问没问，数量限制就是拍脑袋定的，错误要到用户真实使用时才暴露

⛔ 禁止简化为"一个或多个？"——追问数量时必须包含全部三个选项。
⛔ 禁止在开场提问里合并数量菜单——数量是否需要问，取决于类型的答案，开场时还不知道。
⛔ 三选项菜单（含"至少两个"括号里的示例理由）固定不变，原样输出，不改写、不省略、不按当前
Skill 用途另编理由。

**② 问提示语（placeholder）：**
类型和数量都确认后，必须追问输入框的提示语怎么写。
⛔ 禁止跳过此步，不管什么输入类型都必须问。

**③ 输出确认：**
提示语确认后才输出"✓ 输入定义确认"，然后立即写入进度文件：

```bash
minus-lib update-progress init-design
```

以下对话示例中的 `[Plugin：]` / `[Creator：]` 是写给 Agent 看的角色批注，本身不输出；只输出批注后面的正文。

**对话示例 A — Creator 一句话答全了类型和数量：**

```
[Plugin：] (原样输出开场白)

[Creator：] 一个主关键词

[Plugin：] 好的，一个主关键词。                          ← ①（数量已明确，不再追问）
       用户输入时的提示语你想写什么？比如"请输入要调研的关键词"？  ← ②

[Creator：] 就写"输入主关键词，如 wireless earbuds"

[Plugin：] ✓ 输入定义确认。                              ← ③
```

**对话示例 B — Creator 只回答了类型，数量说得通但没说：**

```
[Plugin：] (原样输出开场白)

[Creator：] 关键词

[Plugin：] 好的。用户可以输入几个？只能一个、一个或多个、还是至少两个（比如做对比分析，通常
       至少要两个）  ← 直接采信输入类型；数量说得通且未明确，固定模板原样追问

[Creator：] 一个或多个

[Plugin：] 好的，一个或多个关键词。                       ← ①
       用户输入时的提示语你想写什么？比如"请输入要调研的关键词"？  ← ②
```

**对话示例 C — 输入类型没有数量概念（如文件）：**

```
[Plugin：] (原样输出开场白)

[Creator：] 上传一份销售数据的 Excel

[Plugin：] 好的，一份销售数据 Excel 文件。                 ← ①（"提供多个"说不通，跳过数量追问）
       上传区的提示语你想写什么？比如"上传销售数据 Excel 文件"？  ← ②
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

代码改完后必须原样输出以下收尾话术，邀请 Creator 去看效果（不改写、不省略）：

```
这部分已经改好了，刷新页面看一下效果——提示语和交互方式是你想要的样子吗？
```

⛔ 禁止：只改 main.tsx 不改 locale 文件。placeholder、按钮文案等必须同步更新 `frontend/src/locales/` 下的 locale 文件。
⛔ 禁止：在 Creator 确认输入类型之前就添加输入组件。
⛔ 禁止：把 AmazonSearchBar 替换为原生 textarea 或 input。AmazonSearchBar 是平台组件，placeholder 通过 locale 文件控制，不是通过 HTML 属性。
⛔ 禁止：更新 Home 输入组件后不同步更新 renderHistoryItem。两者的字段名必须匹配。

## 第二步：拆解步骤

第一步「✓ 输入定义确认」之后，先切换报站再提问（半句收束 + 半句开新）：

批注含义同上：

```
[Plugin：] 第一件事确认完，接下来看流程分几步以及每步具体做什么。
       下一个问题：拿到用户的关键词后，Skill 要分几步完成？
       每一步做什么？按你的思路说就行。（后续随时都可以调整）

[Creator：] 先查搜索量和趋势，然后看竞争度有多激烈，最后推荐一些相关的长尾词

[Plugin：] 整理一下，3 步：
       1. 关键词数据采集 — 搜索量、趋势
       2. 竞争度分析 — 竞争密度、排名难度
       3. 长尾词推荐 — 扩展相关词，按潜力排序
       有没有要加的或者要调整的？

[Creator：] 差不多就这样

[Plugin：] ✓ 步骤结构确认。
```

确认后用 `skill_update` 将步骤结构写入后端（**字段必须是 stepNumber + stepName + inputRequired，不要用其他字段名**）：

```json
{
  "skillId": "从 .minus/skill.json 读取",
  "version": "从 .minus/skill.json 读取",
  "updates": {
    "steps": [
      { "stepNumber": 1, "stepName": "关键词数据采集", "inputRequired": false },
      { "stepNumber": 2, "stepName": "竞争度分析", "inputRequired": false },
      { "stepNumber": 3, "stepName": "长尾词推荐", "inputRequired": false }
    ]
  }
}
```

`inputRequired` 对应步骤开发维度 ④ 的确认模式：confirm_mode = interactive 时为 true（用户需要暂停确认再继续），confirm_mode = auto 时为 false（自动往下走）。**结构设计阶段先全部填 false**，等每个步骤进入维度 ④ 开发时再按 Creator 确认的交互方式更新。

**后端是步骤定义的唯一数据源。** 所有平台 API 的字段格式参照 `.claude/api/openapi-bundled.yaml`。

⛔ 禁止：在更新 steps 时顺带修改 description、displayName 等其他字段。每次 `skill_update` 只传 Creator 明确确认的字段。

然后执行 Bash 命令生成步骤骨架代码（**必须执行，不要自己手写**）：

```bash
minus-lib generate-steps --input-type keyword "步骤1名称" "步骤2名称" "步骤3名称"
```

`--input-type` 的值对应第一步确认的输入类型（keyword/asin/file/default）。脚本会自动更新 `pipeline.py`（生成 step_N 方法）、`frontend/src/main.tsx`（更新 buildSteps 渲染配置和 renderHistoryItem 字段名），保证前后端代码和后端步骤定义数量一致。

**已有项目的步骤结构变更（插入/删除/追加/交换）：**

根据 Creator 意图选择对应命令。脚本自动处理 pipeline.py 重编号、main.tsx buildSteps 数组、`.minus/total-steps`、`.minus/progress.json`，不需要手动改这些文件。

```bash
# 在位置 N 插入新步骤（N 及之后的步骤自动重编号）
minus-lib generate-steps --insert-at 2 "搜索趋势分析"

# 删除步骤 N（N 之后的步骤自动前移重编号）
minus-lib generate-steps --delete 3

# 在末尾追加新步骤（已有步骤不受影响）
minus-lib generate-steps --append "新步骤名称"

# 交换两个步骤的位置（自动同步 pipeline.py + main.tsx + progress.json）
minus-lib generate-steps --swap 3 4

# 重命名步骤
minus-lib update-progress rename-step 3 "新名称"
```

结构变更完成后，必须用 `skill_update` 同步后端步骤定义（stepNumber + stepName + inputRequired），保持前后端和后端三方一致。

⛔ 禁止：对已有步骤的项目使用不带 `--append`/`--insert-at`/`--delete`/`--swap` 的 `generate-steps.sh`，这会覆盖所有已实现的代码。
⛔ 禁止：手动编辑 pipeline.py 的方法编号或 main.tsx 的 buildSteps 数组顺序来实现插入/删除——必须用脚本，否则容易漏改引用导致数据错位。

## 结构变更完成后

如果变更产生了新的骨架步骤（插入/追加），用 Skill tool 调用 `minus-step` 开发该步骤。

如果是纯删除或交换，确认 Creator 对变更结果满意即可。

## 初次设计完成后

步骤骨架生成后，用 Skill tool 调用 `minus-step` 开发步骤 1（与结构变更流程统一入口，确保门禁和步骤状态判断不被跳过）。
