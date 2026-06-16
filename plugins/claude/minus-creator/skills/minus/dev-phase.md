# 状态路由与开发调度

门禁通过后，根据项目状态进入对应阶段。

## 状态路由

路由输入直接用 `resume-env` 输出的字段（`INITIALIZED=` / `PHASE=` / `DESIGN_STAGE=` / `CURRENT_STEP=` / `STEPS_TOTAL=` / `STEPS_DONE=` / `STEP_STATUS=`），**不要重复 Read progress.json**。`.minus/skill.json` 只在需要 skillId/version 传给 MCP tool 时读。（没有 resume-env 输出的场景——如中途被用户打断后重入——才退回自己读 progress.json。）

| 状态 | 条件 | Read |
|------|------|------|
| A — 开发中 | `PHASE=developing` 且 `STEPS_DONE` < `STEPS_TOTAL` | [node-dev.md](../minus-step/node-dev.md)，继续 `CURRENT_STEP` |
| B — 待测试 | `PHASE=developing` 且步骤全完成，或 `PHASE=testing` | （提示跑端到端测试） |
| C — 可发布 | 测试已通过 | （提示 /minus publish） |
| D — 结构设计中 | `PHASE=designing` | [structure-design.md](../minus-structure/structure-design.md) |
| E — 无进度 | `PHASE=`（空，progress.json 不存在） | [structure-design.md](../minus-structure/structure-design.md) |

### 首次进入（`INITIALIZED=0`）

1. 通过 `skill_version_get` MCP tool 读取后端草稿版本信息（传入 .minus/skill.json 中的 skillId 和 version）
2. 创建 .minus/initialized 标记文件
3. 原样输出（不改写）：
   「你现在看到的是 Skill 的初始页面，展示了名称、描述、适用场景等基本信息。」
   「这些都是根据名称自动生成的，随时可以改。」
4. 「接下来我们来设计这个 Skill。」
   然后 Read [structure-design.md](../minus-structure/structure-design.md)，从第一步开始执行。

### 非首次进入 — 按状态分发

状态 A — 开发中（有未完成进度）：

先验证"未完成"步骤的真实状态——检查 pipeline.py 中对应的 `step_N` 方法是否仍包含 `# TODO: 实现「` 骨架占位：
- **有占位** = 确实未开发，按下方话术汇报
- **无占位** = 代码已写好但 progress 未更新（可能是 context 压缩后跳过了四维度），先用 `minus-lib update-progress step-done {N}` 修正进度，再重新判断状态

```
当前项目：{名称} v{版本}
上次你完成了「{已完成步骤}」的开发，
下一个待开发的步骤是「{下一步骤}」。
要继续吗？
```
→ Read [node-dev.md](../minus-step/node-dev.md)，继续对应步骤

状态 B — 待测试（所有步骤开发完成但未测试）：
```
当前项目：{名称} v{版本}
所有步骤已开发完成，但还没有运行过测试。
建议先跑一遍端到端测试，确认流程通畅。
```

状态 C — 可发布（测试已通过）：
```
当前项目：{名称} v{版本}
所有步骤已开发，测试已通过。
可以考虑发布了。输入 /minus publish 开始校验和打包。
```

状态 D — 结构设计进行中（progress.json 存在且 phase 为 designing）：
根据 `designStage` 恢复：
- `input_done` → 输入定义已完成
  ```
  当前项目：{名称} v{版本}
  上次已完成输入定义，接下来拆解步骤。
  ```
  → Read [structure-design.md](../minus-structure/structure-design.md)，从第二步恢复
- 无 `designStage` → Read [structure-design.md](../minus-structure/structure-design.md)，从头开始

状态 E — 无进度（刚创建的项目，progress.json 不存在或为空）：
```
✓ Minus 已就绪 — {名称} v{版本}
```
→ Read [structure-design.md](../minus-structure/structure-design.md)，从第一步开始

## 逐节点开发规则

⛔ **硬性规则：任何涉及 pipeline 节点的新增、修改、开发（包括 Creator 说"加一个步骤"、"改一下步骤 X"、"开发步骤 X"等），都必须先 Read [node-dev.md](../minus-step/node-dev.md) 并严格按四维度流程执行。禁止直接编辑 pipeline.py 或 main.tsx 的步骤代码。**

**调用方式：** 进入节点开发前，用 Read 工具读取 [node-dev.md](../minus-step/node-dev.md)，然后**在当前对话中**严格按其中定义的四维度流程执行。

**节点完成后：** 用 `skill_update` 更新后端该步骤的状态为 completed，执行 `minus-lib update-progress step-done {N}`（自动推进本地进度，禁止手写 progress.json），进入下一个节点。

## 结果呈现设计

**所有 pipeline 节点开发完成后**，Read [result-design.md](../minus-structure/result-design.md) 并按其中指令执行。

---

**特殊情况 — Creator 报障（"报错了"、"打不开"、"白屏"等症状描述）：**
用 Skill tool 调用 minus-diagnose 体检分类后按其路由处理。

**特殊情况 — Creator 要求创建新项目：**
```
当前目录已经是「{当前项目名}」的项目了。要创建新 Skill 请：
1. 新开一个对话
2. 选择 `~/minus/` 文件夹作为工作目录
3. 在新对话里告诉我你要创建的项目名
```
