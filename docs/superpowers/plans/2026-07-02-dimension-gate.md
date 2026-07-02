# minus-structure / minus-step 门禁统一方案：共享维度确认脚本

> 依据：诺曼视角审查发现，五个"需要 Creator 确认才能生成代码"的环节，拦截强度和代价高低正好倒挂——
> 结果设计（代价最小）已经是脚本级硬门禁（tracker 文件 + check 拦截）；
> node-dev 四维度（代价最大——决定 pipeline.py 一整段业务逻辑怎么写）完全没有硬门禁，
> 全靠 `.md` 里的 ⛔ 提示词，Agent 可能疏忽直接写代码；
> 输入定义 ①②、步骤拆解同样是软门禁。
> 原则：**该不该硬，按代价判断，不强求一律**；但凡决定要硬，机制必须共用一套，不再各自手搓
> （CLAUDE.md 单源化原则——`generate-result-design.sh` 已经手搓过一次 confirm/check/reset，
> 不该再复制两份）。

**贯穿全文的示例场景**：沿用前两份计划的「亚马逊关键词分析」Skill，共 4 步
（① 选类目 → ② 关键词筛选 → ③ 竞品分析 → ④ 生成报告）。

**当前拦截强度 vs 代价对照**（调研结论，详见下方各改动的「设计说明」）：

| 环节 | 一旦漏问，返工代价 | 现状 |
|---|---|---|
| 结果设计（摘要/下载）| 结果页代码要重写 | 🔒 硬（`generate-result-design.sh` confirm/check）|
| 输入定义 ①②（类型数量/提示语）| 前端 Home 组件 9 处改动要重来 | 📄 软 |
| 输入定义 ③（输出确认）| —— | 🩹 半硬（写 `progress.json` 但不校验①②真发生过）|
| 步骤拆解（第二步）| 下游所有步骤的 pipeline.py/main.tsx 都建立在这个结构上 | 📄 软 |
| node-dev 四维度 | pipeline.py 业务逻辑 + 前端展示代码整段重写 | 📄📄 **完全软**（`generate-node-code.sh` 只校验参数合法性，不校验四维度是否被确认过）|

---

## 改动 1：新增共享脚本 `confirm-dim.sh`

**位置**：新增 `plugins/claude/minus-creator/scripts/confirm-dim.sh`（跨 skill 共享目录，不放进任何一个 skill 的私有 `scripts/`）。

**设计**：脚本不携带任何业务语义，只做两件通用的事——记一个时间戳文件、检查一批时间戳文件在不在。"有哪些维度、叫什么名字"由调用方（各 skill 的 `.md`）决定。

```bash
#!/usr/bin/env bash
# confirm-dim.sh — 通用维度确认追踪器（跨 skill 共享）
# 用法:
#   confirm-dim.sh confirm <flow> <dim>            — 记录 <flow> 下 <dim> 已确认
#   confirm-dim.sh check <flow> <dim1> [dim2 ...]  — 检查给定维度是否全部已确认
#   confirm-dim.sh reset <flow> [dim1 dim2 ...]    — 清除指定维度（不给 dim 则清空该 flow 下全部）
#
# flow/dim 均为调用方自定义的字符串标识，脚本不解释其业务含义。
# 存储：.minus/dev-progress/<flow>__<dim>_confirmed（时间戳文件）

set -euo pipefail
TRACKER_DIR=".minus/dev-progress"
ACTION="${1:?用法: confirm-dim.sh <confirm|check|reset> <flow> [dim...]}"
FLOW="${2:?缺少 <flow> 参数}"
shift 2

case "$ACTION" in
  confirm)
    DIM="${1:?用法: confirm-dim.sh confirm <flow> <dim>}"
    mkdir -p "$TRACKER_DIR"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$TRACKER_DIR/${FLOW}__${DIM}_confirmed"
    echo "✓ ${FLOW}/${DIM} 已确认"
    ;;
  check)
    [ "$#" -ge 1 ] || { echo "用法: confirm-dim.sh check <flow> <dim1> [dim2 ...]" >&2; exit 1; }
    MISSING=""
    for DIM in "$@"; do
      [ -f "$TRACKER_DIR/${FLOW}__${DIM}_confirmed" ] || MISSING="${MISSING} ${DIM}"
    done
    if [ -n "$MISSING" ]; then
      echo "GATE_FAILED"
      echo "以下维度未确认：${MISSING}" >&2
      exit 1
    fi
    echo "GATE_PASSED"
    ;;
  reset)
    if [ "$#" -eq 0 ]; then
      rm -f "$TRACKER_DIR/${FLOW}__"*"_confirmed"
    else
      for DIM in "$@"; do
        rm -f "$TRACKER_DIR/${FLOW}__${DIM}_confirmed"
      done
    fi
    echo "✓ ${FLOW} 的确认标记已清除"
    ;;
  *)
    echo "用法: confirm-dim.sh <confirm|check|reset> <flow> [dim...]" >&2
    exit 1
    ;;
esac
```

**设计说明**：
- 命名用 `<flow>__<dim>_confirmed`（双下划线分隔），因为 `flow` 本身可能带数字（`node1`、`node2`），`dim` 是 snake_case（`data_need`），单下划线会有歧义。
- 这不是全新范式——`.minus/dev-progress/` 目录下"一个维度一个时间戳文件"的存储方式，`generate-result-design.sh` 和 `final_test_confirmed` 已经在用；这里只是把它参数化成通用脚本，消灭"每个 skill 各自手搓一份几乎一样的 confirm/check/reset"的重复。
- `check` 失败只报缺失的维度名、不猜测该去问什么——具体该说什么话补救，是调用方 `.md` 的职责，脚本只回答"缺什么"。

**场景示例（脚本本身的行为，非对话）**：

> `confirm-dim.sh confirm node2 data_need` → 写入 `.minus/dev-progress/node2__data_need_confirmed`
> `confirm-dim.sh check node2 data_need data_process display handoff` → 若 `data_process` 未确认，输出：
> ```
> GATE_FAILED
> 以下维度未确认： data_process
> ```
> 退出码 1，调用方据此拒绝生成代码。

---

## 改动 2：structure-design.md 接入（①②③ + 第二步）

**位置**：`skills/minus-structure/structure-design.md`。

**①确认类型和数量后**，追加调用：

```bash
minus-lib confirm-dim confirm input type_qty
```

**②确认 placeholder 后**，追加调用：

```bash
minus-lib confirm-dim confirm input placeholder
```

**「确认后更新前端代码」的 9 步 checklist 之前**，新增门禁：

```bash
minus-lib confirm-dim check input type_qty placeholder
```

GATE_FAILED 时不动代码，回到对应子步骤补问，确认后重跑 check。

**第二步「拆解步骤」**，Creator 确认步骤结构（"✓ 步骤结构确认"）后追加调用：

```bash
minus-lib confirm-dim confirm steps breakdown
```

**调用 `generate-steps` 骨架生成命令之前**，新增门禁：

```bash
minus-lib confirm-dim check steps breakdown
```

**设计说明**：
- ③现有的 `update-progress init-design` 调用不变、不冲突——它标记的是"设计阶段"这个更大粒度的状态机，`confirm-dim` 标记的是维度级别的确认，两层粒度不同，都保留。
- 步骤拆解只有一个不可再分的确认动作，`dim` 只需要一个 key（`breakdown`），不需要拆更细。

**场景示例**：

> Creator 只回答了输入类型（"关键词"），Agent 因为疏忽没问 placeholder 就想直接改前端代码：
>
> **改动前**：Agent 直接开始改 `main.tsx`，没人拦。
>
> **改动后**：Agent 在改代码前照规则跑 `confirm-dim check input type_qty placeholder`，收到 `GATE_FAILED / 以下维度未确认： placeholder`，被迫回去问"用户输入时的提示语你想写什么？"，问完再重跑 check，通过后才能动代码。

---

## 改动 3：node-dev.md 四维度接入 + generate-node-code.sh 新增硬门禁（核心改动）

**位置**：`skills/minus-step/node-dev.md`（各维度确认后调用 confirm）+ `skills/minus-step/scripts/generate-node-code.sh`（新增 check 门禁）。

**node-dev.md**：每个维度 Creator 明确确认后，追加调用：

```bash
minus-lib confirm-dim confirm node${STEP} data_need      # 维度①确认后
minus-lib confirm-dim confirm node${STEP} data_process   # 维度②确认后
minus-lib confirm-dim confirm node${STEP} display        # 维度③确认后
minus-lib confirm-dim confirm node${STEP} handoff         # 维度④确认后（仅非最后一步）
```

**generate-node-code.sh**：在现有的 `logic_mode`/`confirm_mode` 参数校验之后、`echo GATE_PASSED`（现第 47 行）之前，新增：

```bash
# 判断是否最后一步，决定要不要求 handoff 维度
TOTAL=$(cat .minus/total-steps 2>/dev/null || echo 0)
REQUIRED_DIMS="data_need data_process display"
[ "$STEP" -lt "$TOTAL" ] && REQUIRED_DIMS="$REQUIRED_DIMS handoff"

if ! "$(dirname "$0")/../../../scripts/confirm-dim.sh" check "node${STEP}" $REQUIRED_DIMS; then
  echo "错误：步骤 ${STEP} 的四维度问答未全部确认，禁止生成代码" >&2
  exit 1
fi
```

**设计说明**：
- 这是全计划里**唯一真正新增硬拦截点**的改动——之前 `generate-node-code.sh` 只检查 `logic_mode`/`confirm_mode` 这两个参数合不合法，完全不检查"四维度是否被 Creator 逐一确认过"。node-dev.md 里那句"⛔ 禁止在门禁通过前编辑代码"目前只是提示词层面的约束，没有脚本真的会拦。
- 是否要求 `handoff` 维度，复用脚本已经在做的"是否最后一步"判断逻辑，不新增读文件成本。

**场景示例**：

> Creator 在维度②说完"用大模型分析哪些词值得投"后，Agent 误判维度②已经问完，直接跳到维度④，漏掉了维度③"这一步要展示什么给用户看"，随后调用 `generate-node-code 2 llm interactive`：
>
> **改动前**：脚本只看 `llm`/`interactive` 参数合法，直接 `GATE_PASSED`，Agent 开始写代码——漏问的维度③要等 Creator 看到成品才会发现。
>
> **改动后**：脚本发现 `node2__display_confirmed` 不存在，报错拒绝生成代码，Agent 被迫回去问"这一步要展示什么给用户看"，问完确认再重跑，才能真正生成代码。

---

## 改动 4：结构变更时的 tracker 生命周期管理（风险点，必须一起做）

**位置**：`skills/minus-structure/scripts/restructure.cjs` 的 `ops.insert`、`ops.delete`、`ops.swap` 三个分支。

**问题**：如果在位置 2 插入新步骤，原步骤 2/3/4 会被重编号为 3/4/5。如果不同步处理 `node2__*_confirmed`、`node3__*_confirmed` 这些 tracker 文件，插入后的新"第 3 步"会错误地读到旧步骤 3（现已变成第 4 步业务内容）遗留的确认标记，导致四维度问答被误判"早已确认"而跳过——**这是新机制会引入的风险，现状（完全没有 tracker）反而不存在**。加了硬门禁却不处理这个坑，比不加更危险。

**改法**：不做"智能重编号迁移"，直接清空所有 `node*__*_confirmed` 文件，逼着受影响及之后的步骤重新走一遍四维度确认。三个分支末尾各加一次清理调用：

```bash
rm -f "${DEV_DIR}"/node*__*_confirmed 2>/dev/null || true
```

**设计说明**：
- 代码库里已经有同类问题的先例可以照抄：`restructure.cjs` 的 `writeStepNames`（现第 79-92 行）处理 `step_N_name` 文件时，就是"先删光旧的、再按新编号全部重写"，不做逐个映射。`node*__*_confirmed` 用同一策略，只是更简单——直接全清，不重写（因为清空后本来就该逼 Creator 重新走四维度，不像 `step_N_name` 那样有值需要保留）。
- 为什么不做"聪明"的重编号迁移：插入/交换步骤经常伴随内容变化（否则 Creator 为什么要插入），"node2 的确认状态等于新 node3 的确认状态"这个假设本身就不一定成立。强制重新确认虽然多问几轮，但比悄悄继承一个可能不再适用的确认状态安全得多。
- **修改已完成步骤**（node-dev.md「修改已完成步骤的处理逻辑」，只重新确认受影响维度）不受本改动影响——那是同一个步骤编号内部的部分维度更新，不涉及重编号，未受影响维度的 tracker 文件保持不动，机制天然兼容，不需要额外处理。

**场景示例**：

> Creator 说"在第 2 步前面插入一个搜索趋势分析步骤"，此时原步骤 2「关键词筛选」已经走完四维度、`node2__*_confirmed` 四个文件都在。
>
> **不做本改动**：插入后原步骤 2 变成新步骤 3，但 `node2__*_confirmed` 没人清理、`node3__*_confirmed` 也不存在——新步骤 2（搜索趋势分析，全新内容）的四维度问答会正常走一遍没问题；但如果 Agent 之后又把新步骤 3 误当作"已经确认过"（因为读到了残留的 `node2__*_confirmed`，编号对应关系已经错位），可能会跳过本该重新确认的维度。
>
> **改动后**：插入操作执行时顺带清空全部 `node*__*_confirmed`，新步骤 2、3、4、5 无论内容变没变，都必须重新走一遍四维度确认，不存在"编号对错"的判断负担。

---

## 改动 5（可选、独立执行）：generate-result-design.sh 内部迁移到共享脚本

**位置**：`skills/minus-structure/scripts/generate-result-design.sh`。

**内容**：`confirm`/`check`/`reset` 三个子命令的内部实现，改为委托给 `confirm-dim.sh`（`flow=result`，`dim` 分别是 `summary`/`download`）。**对外 CLI 子命令名、回显文案、退出码全部不变**——`tests/shell-scripts.test.sh:1985/1998` 断言了具体输出文案，必须保持一致。

**设计说明**：
- 这一步纯粹是内部重构，不改变任何外部可观察行为，风险最低。标记为可选、可独立提交，不必和改动 1-4 同批做——建议等前四项验证通过、稳定运行一段时间后再做，避免风险叠加。
- 做完之后，全仓库只有一份"记时间戳文件 + 检查文件是否存在"的实现，不再有两份几乎相同的 shell 逻辑分别躺在 `generate-result-design.sh` 和 `confirm-dim.sh` 里。

---

## 不做的事（明确排除）

| 排除项 | 理由 |
|---|---|
| 合并 `progress.json` 和 `.minus/dev-progress/` 成一套存储 | 职责已经分工清楚——`progress.json` 是整体阶段状态机，`dev-progress` 是离散维度确认标记，合并是过度设计，超出本次范围 |
| 对结构变更时的 tracker 做"智能重编号迁移" | 见改动 4 设计说明——强制清空更安全，试图智能映射的风险比重新确认更大 |
| 给"步骤拆解"（第二步）拆成多个子维度 | 它是一个不可再分的确认动作，一个 dim key 足够 |
| 进度条/百分比展示 | 沿用前两份计划（node-dev-map、structure-result-map）的排除原则 |
| 统一所有环节的拦截强度 | 明确不追求"一律硬"——该不该硬取决于代价，见文首对照表 |

---

## 风险与测试影响（本计划独有，必须提醒）

这是三份计划里**第一份改变实际拦截行为**的（前两份只是话术/顺序调整，不影响流程能否继续）。具体影响：

- `tests/e2e-conversation-replay.test.sh`、`tests/e2e-dev-flow.sh` 这类端到端模拟对话测试，如果脚本化的对话没有在正确时机调用 `confirm-dim confirm`，新增的硬门禁会让测试中途 `GATE_FAILED`——需要逐个检查这些测试脚本，在模拟对话里补上对应的 confirm 调用。
- `generate-node-code.sh` 新增门禁后，`tests/shell-scripts.test.sh` 里所有直接调用 `generate-node-code.sh` 的用例都需要先补 `confirm-dim confirm` 调用，否则会全部失败——这是本计划工作量最大的一块，是回归测试的体力活，不是设计问题。

**建议实现顺序**（降低风险叠加）：
1. 先落地 `confirm-dim.sh` 本体 + 单元测试（纯新增，不影响任何现有流程）
2. 接入 `structure-design.md`（①②③、第二步），跑一次 `tests/run-all.sh`
3. 接入 `node-dev.md` + `generate-node-code.sh` 门禁 + `restructure.cjs` 的 tracker 清理（风险最高、影响面最大，单独一批，跑完整测试）
4. （可选）改动 5 迁移 `generate-result-design.sh`

不要一次性全接完再测——每接入一处就跑一次测试，出问题能定位到具体是哪一处改动引入的。

---

## 涉及文件

| 文件 | 改动 |
|---|---|
| `plugins/claude/minus-creator/scripts/confirm-dim.sh` | 新增：confirm/check/reset 三个子命令 |
| `skills/minus-structure/structure-design.md` | ①②确认后调用 confirm；9 步改代码前、`generate-steps` 骨架生成前各加一道 check 门禁 |
| `skills/minus-step/node-dev.md` | 四维度确认后各自调用 confirm |
| `skills/minus-step/scripts/generate-node-code.sh` | 新增四维度 check 硬门禁（核心改动） |
| `skills/minus-structure/scripts/restructure.cjs` | insert/delete/swap 三个分支新增清空 `node*__*_confirmed` 逻辑 |
| `skills/minus-structure/scripts/generate-result-design.sh` | （改动 5，可选）内部委托给共享脚本，外部接口不变 |
| `tests/shell-scripts.test.sh` | 新增 `confirm-dim.sh` 单元测试；补全 `generate-node-code.sh` 相关用例的 confirm 前置调用 |
| `tests/e2e-conversation-replay.test.sh`、`tests/e2e-dev-flow.sh` 等 | 检查模拟对话是否需要补 confirm 调用时机 |

## 验证方式

1. 单独跑 `confirm-dim.sh` 的单元测试：confirm 落盘、check 缺失时报错退出码 1、reset 清空（含"清空整个 flow"和"只清指定 dim"两种用法）。
2. 真实走一遍「亚马逊关键词分析」4 步场景：
   - 跳过②直接想改前端代码 → 确认会被拦（模拟 Agent 疏忽）
   - 四维度问答漏问一个维度直接调 `generate-node-code` → 确认会被拦
   - 在步骤 2 前插入新步骤 → 确认插入后新步骤 2/3 的四维度 tracker 已被清空，必须重新走四维度，而不是继承旧编号的确认状态
3. 跑 `bash tests/run-all.sh`——预期第一轮会有失败（现有测试脚本没有补 confirm 调用），按上面「建议实现顺序」逐批修复到全绿，不要指望一次性通过。
