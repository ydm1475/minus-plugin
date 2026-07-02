# E2E Agent 剧本测试 — 完整使用流程

> 一句话：**一条命令跑测试 → 只审报告页上标红标黄的 → 网页上点两下裁定 → 每次裁定自动变成让 judge 更准的考题。**
> 人工投入从"读全文找问题"收窄到"对可疑判定做 30 秒仲裁"。

## 流程总览

| 步骤 | 谁做 | 做什么 |
| ---- | ---- | ------ |
| ① 发起 | 你 | 一条命令启动剧本测试 |
| ② 执行 | 机器 | 建项目 → 真实对话 → 硬断言 → 行为评判 → 证据核验 → 出报告 |
| ③ 审查 | 你 | 打开报告页，只看 ✗ 和 ⚠ 项，核对原文，网页裁定 |
| ④ 沉淀 | 机器 | 裁定落档案 + 更新报告 + 生成 judge 校准用例 |
| ⑤ 清理 | 你（报告页一键） | 全部复核完后点"清理临时项目"；有未复核项会被门禁拒绝 |
| ⑥ 回报 | 你（偶尔） | 改 judge 前后跑校准回归；同向推翻多次 → 改规则措辞 |

## ① 发起测试

```bash
bash tests/e2e-agent/run.sh keyword-to-asin        # 全量：含真实运行验证，数十万 token，几十分钟
E2E_SKIP_RUN=1 bash tests/e2e-agent/run.sh <剧本>  # 快检：只测对话流程，便宜很多
```

剧本 = `scenarios/` 下的 YAML 文件名（不带扩展名）。其他开关（Desktop 模式、脏端口模式、模型覆盖）见 `run.sh` 头注释。

## ② 自动执行（无人值守）

1. **建临时项目**：create-skill 脚手架 + npm/uv 装依赖；
2. **真实对话**：单个 `claude` 进程内多轮对话（stream-json 双向流）驱动 Creator Agent，haiku 按剧本 persona/answers 扮演"不懂技术的运营"逐轮应答，走完 结构设计 → 每步四维度 → 结果页设计。与真实用户的连续 session 对齐：hooks 只注入一次、MCP server 全程不重启。协议异常时可用 `E2E_TURN_MODE=resume` 切回"每轮 `claude -p --resume` 重启进程"的旧模式兜底；
3. **边跑边硬断言**（H/R/D 系列）：每阶段完成即机器检查——文件生成、维度顺序、门禁、逐节点真实执行、终验完整跑通；
4. **行为评判**（B/C 系列）：评判模型读完整对话逐条判规则（不抢答、测试邀请后停下等），要求**逐字引用原文 + 标注轮次号**；
5. **证据核验**：把 judge 引用的原文对回 transcript 做字符串比对——命中所标轮次 ✓ / 命中其他轮次 △ / 全文找不到 ⚠（疑似编造，需人工复核）；
6. **出报告**：自动生成 `logs/<run>/report.html`，终端打印路径；有失败项时附复核服务启动命令。

## ③ 审查与裁定（只看报告页）

```bash
node tests/e2e-agent/review-server.mjs logs/<run目录>   # 自动开浏览器（AUTO_OPEN=0 禁止）
```

报告页布局：**左侧**完整对话回放（带轮次号气泡）；**右侧**全部断言与评判。

审查节奏：

- 只看 **✗ 项**和 **⚠ 角标项**；✓ 且证据已核验的扫一眼就过；
- 点判定上的"第 N 轮 ↗"跳转并高亮它引用的那轮原文，对照判断；
- 不认可（或想显式确认）→ 展开"**复核此判定**" → 选 实际应为 pass/fail → 填理由 → 提交。

命令行等价物（效果完全相同）：

```bash
node tests/e2e-agent/feedback.mjs logs/<run目录> C4 pass "用户在第12轮已确认，judge 漏看了"
```

注意：复核表单只出现在 B/C 语义评判上。**H 系列硬断言判错 = assert.mjs 脚本有 bug，改脚本，不走人工裁定。**

## ④ 裁定自动沉淀（提交后不用再做任何事）

每条裁定同时落三处：

1. `logs/<run>/overrides.json` — 分歧档案（谁裁的、裁了什么、为什么，永久可查）；
2. 报告页紫色"人工复核推翻/确认"块 — 顶部统计按裁定后结果重算；
3. `judge-calibration/<run>--<ID>.json` — 校准用例（完整对话 + 规则 + 你给的标准答案），judge 的考题。

## ⑤ 清理临时项目（复核完才允许）

证据链活到复核完成为止：

- `run.sh` 默认 `E2E_KEEP=1`——跑完**不删**临时项目和 dev server；失败一律保留现场；
- 复核完毕后，在报告页底部点"**复核完成，清理临时项目**"（两次点击确认）。服务端有门禁：**所有 ✗ 项与 ⚠ 证据存疑项都已有人工裁定**才放行，否则拒绝并列出漏了哪几条；
- 清理只删 `e2e-agent-*` 临时项目（目录名硬约束，删不到别的东西）；`logs/` 下的对话、报告、裁定档案**永久保留**，不受影响。

## ⑥ 长期回报

```bash
node tests/e2e-agent/calibrate.mjs    # 消耗 token：每个用例一次 judge 调用
```

- **改评判 prompt / 换评判模型（E2E_JUDGE_MODEL）前后各跑一遍**：新 judge 重考你裁定过的所有案例，一致率不降才算改好；
- **某条规则被同方向推翻 3~5 次** → 不是 judge 笨，是规则措辞有歧义：去改剧本 yaml 里那条 `transcript_rules`，校准集里存着现成的参考案例。

## 常用命令速查

```bash
bash tests/e2e-agent/run.sh <剧本>                     # 跑测试（E2E_SKIP_RUN=1 快检）
node tests/e2e-agent/review-server.mjs logs/<run>      # 网页复核（推荐）
node tests/e2e-agent/feedback.mjs logs/<run> <ID> pass|fail "理由"   # CLI 裁定
node tests/e2e-agent/report-html.mjs logs/<run>        # 给历史日志补生成回放报告
node tests/e2e-agent/calibrate.mjs                     # judge 校准回归（消耗 token）
node --test tests/e2e-agent/harness.test.mjs           # 框架自测（零 token，已含在 run-all.sh）
```

## 文件地图

| 文件 | 职责 |
| ---- | ---- |
| `run.sh` | 入口：环境检查、建临时项目、装依赖、调 driver、清理 |
| `driver.mjs` | 主循环：对话调度、阶段断言、终验、评判、出报告 |
| `session.mjs` | 单进程多轮 claude 会话（stream-json 协议封装，协议细节见头注释） |
| `stub-claude.mjs` | 协议桩：harness 测试用，零 token 模仿 stream-json 应答 |
| `scenario.mjs` | 剧本 YAML 解析 |
| `scenarios/*.yaml` | 剧本：persona / answers 口径 / expect 硬断言 / transcript_rules 行为规则（**规则的单一权威来源**） |
| `simulate-user.mjs` | LLM 模拟用户（haiku） |
| `assert.mjs` | 硬断言执行器（H/R 系列） |
| `judge.mjs` | 行为评判（B/C 系列）+ 证据核验 verifyEvidence |
| `run-skill.mjs` | 真实运行 pipeline（SSE 消费、interactive 确认） |
| `report-html.mjs` | 回放报告渲染 + 裁定叠加 |
| `feedback.mjs` | 人工裁定落盘 + 校准用例沉淀 |
| `review-server.mjs` | 网页复核服务（127.0.0.1，POST 与 CLI 同源逻辑） |
| `calibrate.mjs` | judge 校准回归 |
| `logs/<run>/` | 每次 run 的现场：transcript、report.json/html、overrides.json |
| `judge-calibration/` | 人工裁定沉淀的 judge 考题 |

## 新增测试场景

在 `scenarios/` 新增一个 YAML 剧本即可，不用写代码。建议从人工手测的真实对话中提炼（现有剧本头注释都标了来源与回归重点）。
