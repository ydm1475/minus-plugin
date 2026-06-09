# 项目创建与选择

读取本地 `~/.minus/projects.json` 中的已注册项目列表（已自动过滤掉被删除的目录）。
⛔ 禁止：调用 `skill_list` MCP tool 查后端。已有项目以本地为准。

**如果有项目：先列出所有项目名称和路径**，然后再询问。
⚠️ 以下内容原样输出为纯文本，禁止加粗、禁止把选项渲染成 markdown 列表或加任何 `**` 强调：

```
Plugin: 你有这些本地项目：
  1. 关键词调研 (~/minus/关键词调研/)
  2. 竞品监控 (~/minus/竞品监控/)

你想做什么？
  1. 创建新的 Skill 项目
  2. 打开已有的 Skill 项目
```

**如果选"创建新项目"：**

**Step 1：只问名称（原样输出以下提示语，不要改写）：**
"给你的 Skill 项目起个名字？（这会作为项目文件夹名）"

命名约束：过滤文件系统非法字符（/ \ : \* ? " < > |），中英文均可，长度 1-50 字符。

**Step 2：拿到名称后立刻用 Bash 执行 create-skill（禁止使用 skill_create MCP tool）：**

⚠️ **不要裸调 `create-skill`，不要内联安装逻辑。** 创建项目的执行逻辑单源在
`lib/run-create-skill.sh`：脚本会先经 `lib/resolve-node.sh` 解析一个 ≥20 的 node，
把 node/npm/Volta 路径处理好，再把 `@minus-ai/create-skill@beta` 对齐到官方当前版本
并执行 `create-skill`。测试预发布包时可通过环境变量 `MINUS_CREATE_SKILL_SPEC`
覆盖包 spec；默认值永远是 `@minus-ai/create-skill@beta`，不要在指令里写死测试 tag。
它同时复用 `bootstrap-env.sh` 的镜像源策略，避免在指令里复制安装细节。

```bash
PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/run-create-skill.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
bash "$PLUGIN_ROOT/lib/run-create-skill.sh" "项目名称"
```

- 输出 `NO_GOOD_NODE` → 原样提示 Creator："未找到可用的 Node（需 ≥20，建议 24），请安装 Node 24（推荐 https://volta.sh）后重跑 /minus"，并终止。
- 输出 `CREATE_SKILL_INSTALL_FAILED` → 自动安装失败（通常是网络或全局目录权限），提示 Creator 手动安装 `@minus-ai/create-skill@beta`（见下方命令）后重跑 `/minus`，并终止。
- 输出 `NODE24_PROVISION_FAILED` → 脚本自动用 Volta 准备 Node 24 失败。脚本会在该标记后**按现场打印**真实错误（`原因：…`）和可操作指引（`提示：…`，已区分「Volta 已装/未装」「Windows/mac/Linux」）。把脚本输出里的 `原因：` 和 `提示：` 两行**原样转达**给 Creator 后终止，不要自己改写或套用固定文案。⛔ **不要自己用 brew / nvm / 其它方式装 Node**——准备 Node 的唯一途径是脚本里的 Volta，绕开它只会制造版本不一致。
- ⛔ 禁止：调用 `skill_create` MCP tool 来注册 Skill
- ⛔ 禁止：在执行 create-skill 之前再问描述、输入类型等任何问题
- ✅ 必须：通过 Bash tool 执行上面这段（脚本内部经 resolve-node.sh 解析 node）

描述由 agent 根据项目名称自动生成，输入类型默认为 asin（页面自带 ASIN 输入框 + 国家选择器）。结构设计第一步确认输入类型后，如果 Creator 要的不是 ASIN，再切换。

MCP Server 和 create-skill 共享同一个凭证文件 `~/.minus/credentials.json`，MCP 登录后 create-skill 自动复用登录态，无需额外传参。

脚手架会自动完成：

- 向平台注册 Skill（获得 skillId 和 apiKey）
- 在 ~/minus/{folder}/ 下生成完整项目结构（前后端代码、配置文件、.minus/skill.json）；`folder` 见下方 `__CREATE_RESULT__`
- 创建 Python 虚拟环境并安装后端依赖
- 安装前端依赖

脚手架输出末尾有 `__CREATE_RESULT__` JSON，Plugin 应解析获取 folder、skillId、apiKey 等信息。

⚠️ `folder` 是项目真实落地的文件夹名，create-skill 可能对 Creator 输入做过清洗（如空格转 `-`），**与 Creator 输入的名字未必一致**。后续所有需要项目文件夹名/路径的地方（引导文案、`cd` 路径等），一律使用 `__CREATE_RESULT__.folder`，禁止用 Creator 输入的原始名字。

**scaffold 成功后：**
原样输出："项目创建成功！现在自动生成描述和适用场景。"
然后根据项目名称自动生成一句简短的 Skill 描述和 2 条适用场景。同时调用 `skill_tag_list` 查询可用标签，如果标签字典不为空，根据项目名称自动匹配合适的标签。调用 `skill_update` 一次性写入 description、useCases 和 tags 字段。不需要问 Creator，直接生成写入。Creator 后续可以随时修改。

上面的执行块每次都会自动把 create-skill 对齐到 `@beta`（含首次安装和后续升级），无需让
Creator 手动装。仅当输出 `CREATE_SKILL_INSTALL_FAILED`（安装失败）时，才提示 Creator 手动
安装后重跑 `/minus`：

```bash
npm install -g @minus-ai/create-skill@beta
```

**如果选"打开已有"：引导新开对话并打开项目文件夹**

```
Plugin: 请按以下步骤打开项目：
  1. 新开一个对话
  2. 选择对应项目的文件夹作为工作目录（如 `~/minus/关键词调研/`）
  3. 输入 `/minus` 进入开发
```

**如果没有本地项目（projects.json 为空或不存在）：跳过选择，直接进入命名**

**`skill_update` 写入后，运行 `generate-next-steps.sh` 输出"接下来请"引导，把输出原样转达：**

⛔ 禁止：在引导前后输出任何过渡/旁白文字（如"现在生成接下来的引导""下面是后续步骤"之类）。引导内容已自带开头语"项目已创建！接下来请："，直接原样转达，不加任何前言后语。

```bash
PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/generate-next-steps.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
bash "$PLUGIN_ROOT/lib/generate-next-steps.sh" "{__CREATE_RESULT__.folder}" "{__CREATE_RESULT__.targetDir}"
```

脚本内部按客户端类型分支：desktop 输出引导文案 + 两张操作截图外链（markdown 图片），cli 输出 `cd` 启动命令。Agent 不需要自己判定客户端，直接转达脚本输出即可。

注意：不要在当前 session 中进入结构设计。Creator 必须先打开项目文件夹、新开 session，CLAUDE.md 和 Memory 才能正常工作。结构设计在新 session 的 Phase 4/5 中进行。
