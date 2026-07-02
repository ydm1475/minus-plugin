// harness.test.mjs — e2e-agent harness 自身的单元测试（不消耗 token）
// 运行: node --test tests/e2e-agent/harness.test.mjs

import { test } from "node:test";
import assert from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import childProcess from "node:child_process";

import { parseYaml, loadScenario } from "./scenario.mjs";
import { buildSimPrompt } from "./simulate-user.mjs";
import { buildJudgePrompt, parseVerdicts, formatTranscriptLines, verifyEvidence } from "./judge.mjs";
import { renderHtml, parseTranscriptMd, applyOverrides } from "./report-html.mjs";
import { recordOverride, isJudgedItem } from "./feedback.mjs";
import { loadCases } from "./calibrate.mjs";
import { createReviewServer, unresolvedItems } from "./review-server.mjs";
import { ClaudeSession, parseLine, extractResult } from "./session.mjs";
import { parseSseChunk, resolveEntryParams, buildConfirmData, detectConfirmedKeys } from "./run-skill.mjs";
import { Report, stepImplemented, countPipelineSteps, resultComplete, assertResult } from "./assert.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// ── scenario.mjs ──

test("parseYaml: 标量、嵌套 map、列表、块标量", () => {
  const obj = parseYaml(`
name: demo
steps: 2
flag: true
answers:
  structure:
    input: "一个关键词"
  step1:
    logic: 排序  # 行尾注释
list:
  - "a"
  - b
brief: |
  第一行
  第二行
rules:
  - id: B1
    rule: "规则一"
  - id: B2
    rule: "规则二"
`);
  assert.equal(obj.name, "demo");
  assert.equal(obj.steps, 2);
  assert.equal(obj.flag, true);
  assert.equal(obj.answers.structure.input, "一个关键词");
  assert.equal(obj.answers.step1.logic, "排序");
  assert.deepEqual(obj.list, ["a", "b"]);
  assert.equal(obj.brief, "第一行\n第二行\n");
  assert.equal(obj.rules.length, 2);
  assert.equal(obj.rules[1].id, "B2");
  assert.equal(obj.rules[1].rule, "规则二");
});

test("loadScenario: 真实剧本文件可解析且字段齐全", () => {
  const sc = loadScenario(path.join(HERE, "scenarios/keyword-to-asin.yaml"));
  assert.equal(sc.name, "keyword-to-asin");
  assert.equal(sc.steps, 2);
  assert.ok(sc.brief.includes("主关键词"));
  assert.ok(sc.persona.includes("跨境电商"));
  assert.equal(sc.answers.step1.confirm.includes("暂停"), true);
  assert.equal(sc.answers.step2.confirm, undefined, "最后一步不应有维度④口径");
  assert.equal(sc.expect.confirm_data.selectedKeywords, "$select:3");
  assert.equal(sc.expect.final_input.default, "gaming chair");
  assert.equal(sc.transcript_rules.length, 5);
  assert.equal(sc.transcript_rules[2].id, "B3");
});

test("loadScenario: 缺字段报错", () => {
  const tmp = path.join(os.tmpdir(), `bad-scenario-${process.pid}.yaml`);
  fs.writeFileSync(tmp, "name: x\nsteps: 1\n");
  assert.throws(() => loadScenario(tmp), /缺少必填字段/);
  fs.unlinkSync(tmp);
});

// ── simulate-user.mjs ──

test("buildSimPrompt: 包含人设、口径与最新 Agent 输出", () => {
  const sc = loadScenario(path.join(HERE, "scenarios/keyword-to-asin.yaml"));
  const p = buildSimPrompt(sc, "请问用户需要输入什么？");
  assert.ok(p.includes("跨境电商"));
  assert.ok(p.includes("维度①数据需求"));
  assert.ok(p.includes("请问用户需要输入什么？"));
  assert.ok(p.includes("按你的推荐来"));
  assert.ok(!p.includes("当前进度"), "未传阶段时不应有进度提示");
});

test("buildSimPrompt: 带 currentPhase 时置顶当前阶段约束", () => {
  const sc = loadScenario(path.join(HERE, "scenarios/keyword-to-asin.yaml"));
  const p = buildSimPrompt(sc, "这一步展示什么？", "step2");
  assert.ok(p.includes("当前进度"));
  assert.ok(p.includes("step2 节点开发"));
  assert.ok(p.includes("禁止使用其他步骤"));
  assert.ok(buildSimPrompt(sc, "x", "structure").includes("结构设计阶段"));
});

// ── judge.mjs ──

test("parseVerdicts: 解析评判 JSON 并补齐漏判项为 fail", () => {
  const rules = [
    { id: "B1", rule: "规则一" },
    { id: "B2", rule: "规则二" },
  ];
  const out = `评判如下：\n[{"id":"B1","pass":true,"evidence":"原文"}]`;
  const verdicts = parseVerdicts(out, rules);
  assert.equal(verdicts.length, 2);
  assert.equal(verdicts[0].pass, true);
  assert.equal(verdicts[1].pass, false);
  assert.ok(verdicts[1].evidence.includes("未返回"));
});

test("parseVerdicts: evidence 含未转义引号时降级提取 id/pass", () => {
  const rules = [
    { id: "B1", rule: "规则一" },
    { id: "B2", rule: "规则二" },
  ];
  // evidence 内嵌未转义双引号 → 严格 JSON.parse 失败，走降级路径
  const out = `[{"id":"B1","pass":true,"evidence":"用户说"没问题"继续"},{"id":"B2","pass":false,"evidence":"违规"}]`;
  const verdicts = parseVerdicts(out, rules);
  assert.equal(verdicts.length, 2);
  assert.equal(verdicts[0].pass, true);
  assert.equal(verdicts[1].pass, false);
  assert.ok(verdicts[0].evidence.includes("降级"));
});

test("buildJudgePrompt: 包含全部规则", () => {
  const p = buildJudgePrompt(
    [{ id: "B1", rule: "两步法顺序" }],
    "【Agent】hi"
  );
  assert.ok(p.includes("B1: 两步法顺序"));
  assert.ok(p.includes("【Agent】hi"));
  assert.ok(p.includes("round"), "评判要求引用轮次号");
  assert.ok(p.includes("逐字摘抄"), "评判要求逐字引用原文");
});

test("parseVerdicts: 保留轮次号，非整数轮次归一为 null", () => {
  const rules = [{ id: "B1", rule: "规则一" }, { id: "B2", rule: "规则二" }];
  const out = `[{"id":"B1","pass":true,"round":3,"evidence":"原文"},{"id":"B2","pass":false,"round":"第4轮","evidence":"x"}]`;
  const verdicts = parseVerdicts(out, rules);
  assert.equal(verdicts[0].round, 3);
  assert.equal(verdicts[1].round, null);
});

test("formatTranscriptLines: 带轮次号与角色标签", () => {
  const lines = formatTranscriptLines([
    { role: "agent", text: "请问输入什么？" },
    { role: "user", text: "一个关键词" },
  ]);
  assert.deepEqual(lines, [
    "【第1轮 · Agent】请问输入什么？",
    "【第2轮 · 用户】一个关键词",
  ]);
});

test("verifyEvidence: 三态核验（命中所标轮次 / 命中其他轮次 / 未命中）", () => {
  const lines = formatTranscriptLines([
    { role: "agent", text: "步骤 1 开发完成了，请到预览页测试一下，确认后我们继续。" },
    { role: "user", text: "我在预览里看过了，没问题，继续开发步骤 2" },
  ]);
  // 逐字命中所标轮次（允许空白/引号差异）
  assert.equal(
    verifyEvidence({ round: 1, evidence: "请到预览页测试一下，确认后我们继续" }, lines),
    "round"
  );
  // 原文说过，但轮次标错
  assert.equal(
    verifyEvidence({ round: 1, evidence: "我在预览里看过了，没问题" }, lines),
    "transcript"
  );
  // 编造的引用 → miss
  assert.equal(
    verifyEvidence({ round: 2, evidence: "Agent 直接跳过了测试邀请环节继续开发" }, lines),
    "miss"
  );
  // 多片段用 … 分隔：全部命中才算
  assert.equal(
    verifyEvidence({ round: 1, evidence: "步骤 1 开发完成了…确认后我们继续" }, lines),
    "round"
  );
  assert.equal(
    verifyEvidence({ round: 1, evidence: "步骤 1 开发完成了…这句是编的引用内容" }, lines),
    "miss"
  );
  // 空 evidence / 片段太短 → miss（不构成证据）
  assert.equal(verifyEvidence({ round: 1, evidence: "" }, lines), "miss");
  assert.equal(verifyEvidence({ round: 1, evidence: "继续" }, lines), "miss");
});

// ── run-skill.mjs ──

test("parseSseChunk: 解析 message 事件与忽略 marker", () => {
  const msg = parseSseChunk(
    'event: message\ndata: {"id":"msg_3","messageType":"step_complete","payload":{"stepNumber":1}}'
  );
  assert.equal(msg.messageType, "step_complete");
  assert.equal(msg.payload.stepNumber, 1);
  assert.equal(parseSseChunk("event: snapshot_begin\ndata: (marker)"), null);
  assert.equal(parseSseChunk(": keepalive"), null);
});

test("resolveEntryParams: default 值赋给第一个入参键，显式键按名匹配", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-entry-"));
  fs.writeFileSync(
    path.join(dir, "pipeline.py"),
    'kw = ctx.entry_params.get("keywords")\nco = ctx.entry_params.get("country") or "US"\n'
  );
  assert.deepEqual(resolveEntryParams(dir, { default: "earbuds" }), { keywords: "earbuds" });
  assert.deepEqual(
    resolveEntryParams(dir, { default: "earbuds", country: "JP" }),
    { country: "JP", keywords: "earbuds" }
  );
  fs.rmSync(dir, { recursive: true });
});

test("buildConfirmData: $select:N 从候选行取前 N 行", () => {
  const payload = { data: { keywords: [{ keyword: "a" }, { keyword: "b" }, { keyword: "c" }, { keyword: "d" }] } };
  const out = buildConfirmData({ selectedKeywords: "$select:2", note: "x" }, payload);
  assert.deepEqual(out.selectedKeywords, [{ keyword: "a" }, { keyword: "b" }]);
  assert.equal(out.note, "x");
});

test("buildConfirmData: actualKey 改写 $select 落键（剧本占位 key 忽略）", () => {
  const payload = { data: { rows: [{ keyword: "a" }, { keyword: "b" }, { keyword: "c" }] } };
  // 剧本写死 selectedKeywords，生成代码实际用 selectedRows → 按真实 key 落
  const out = buildConfirmData({ selectedKeywords: "$select:2", note: "x" }, payload, "selectedRows");
  assert.deepEqual(out.selectedRows, [{ keyword: "a" }, { keyword: "b" }]);
  assert.equal(out.selectedKeywords, undefined);
  assert.equal(out.note, "x"); // 非 $select 字面字段不受影响
});

test("resultComplete: 两维度确认 + 结果页渲染齐了才算完成", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-result-"));
  const dp = path.join(dir, ".minus/dev-progress");
  fs.mkdirSync(dp, { recursive: true });
  fs.mkdirSync(path.join(dir, "frontend/src"), { recursive: true });
  const main = path.join(dir, "frontend/src/main.tsx");
  // 啥都没有 → 未完成
  assert.equal(resultComplete(dir), false);
  // 只有两维度确认、无结果页代码 → 未完成（不能在代码生成前就 break）
  fs.writeFileSync(path.join(dp, "result_summary_confirmed"), "t");
  fs.writeFileSync(path.join(dp, "result_download_confirmed"), "t");
  fs.writeFileSync(main, "<FlowApp />");
  assert.equal(resultComplete(dir), false);
  // 补上 renderCompletion → 完成
  fs.writeFileSync(main, "<FlowApp renderCompletion={() => <CompletionPanel />} />");
  assert.equal(resultComplete(dir), true);
  // 少一维度 → 未完成
  fs.rmSync(path.join(dp, "result_download_confirmed"));
  assert.equal(resultComplete(dir), false);
});

test("assertResult: R1/R2/R3 三项断言", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-rassert-"));
  const dp = path.join(dir, ".minus/dev-progress");
  fs.mkdirSync(dp, { recursive: true });
  fs.mkdirSync(path.join(dir, "frontend/src"), { recursive: true });
  fs.writeFileSync(path.join(dp, "result_summary_confirmed"), "t");
  fs.writeFileSync(path.join(dp, "result_download_confirmed"), "t");
  fs.writeFileSync(path.join(dir, "frontend/src/main.tsx"), "renderCompletion={() => <CompletionPanel />}");
  const genResult = path.join(HERE, "../../plugins/claude/minus-creator/skills/minus-structure/scripts/generate-result-design.sh");
  const report = new Report();
  assertResult(report, dir, genResult);
  const byId = Object.fromEntries(report.items.map((i) => [i.id, i.pass]));
  assert.equal(byId.R1, true);
  assert.equal(byId.R2, true);
  assert.equal(byId.R3, true); // 真实脚本 check：两 marker 在 → RESULT_DESIGN_COMPLETE
});

test("detectConfirmedKeys: 按源码顺序提取前端 confirmedKey", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-keys-"));
  fs.mkdirSync(path.join(dir, "frontend/src"), { recursive: true });
  fs.writeFileSync(
    path.join(dir, "frontend/src/main.tsx"),
    `defineWidgetStep({ confirmedKey: 'selectedRows' });\n` +
      `defineWidgetStep({ confirmedKey: "selectedAsins" });\n`
  );
  assert.deepEqual(detectConfirmedKeys(dir), ["selectedRows", "selectedAsins"]);
  // 缺文件时返回空数组，不抛
  assert.deepEqual(detectConfirmedKeys(path.join(dir, "nope")), []);
});

// ── assert.mjs ──

function makeProject(pipelineCode) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-test-"));
  fs.mkdirSync(path.join(dir, ".minus"), { recursive: true });
  fs.writeFileSync(path.join(dir, "pipeline.py"), pipelineCode);
  return dir;
}

test("stepImplemented: 区分骨架与真实实现", () => {
  const dir = makeProject(`
class Pipeline:
    async def step_1(self, ctx):
        # TODO: 实现
        pass

    async def step_2(self, ctx):
        rows = await ctx.sif.keyword_metrics(ctx.entry_params.get("keyword"))
        sorted_rows = sorted(rows, key=lambda r: -r["volume"])[:200]
        return StepOutcome.input_required(payload={"keywords": sorted_rows})
`);
  assert.equal(stepImplemented(dir, 1), false, "TODO 骨架不算实现");
  assert.equal(stepImplemented(dir, 2), true);
  assert.equal(stepImplemented(dir, 3), false, "不存在的步骤");
  fs.rmSync(dir, { recursive: true });
});

test("countPipelineSteps: total-steps 优先，否则数 pipeline.py", () => {
  const dir = makeProject(
    "async def step_1(self, ctx):\n    pass\nasync def step_2(self, ctx):\n    pass\n"
  );
  assert.equal(countPipelineSteps(dir), 2);
  fs.writeFileSync(path.join(dir, ".minus", "total-steps"), "3\n");
  assert.equal(countPipelineSteps(dir), 3);
  fs.rmSync(dir, { recursive: true });
});

test("Report: 统计与失败收集，extra 字段并入 item", () => {
  const r = new Report();
  r.add("H1", "ok 项", true);
  r.add("H2", "fail 项", false, "原因");
  r.add("C1", "评判项", true, "证据原文", { round: 5, verified: "round" });
  assert.deepEqual(r.summary(), { pass: 2, fail: 1, total: 3 });
  assert.equal(r.failed[0].id, "H2");
  assert.equal(r.items[2].round, 5);
  assert.equal(r.items[2].verified, "round");
});

// ── report-html.mjs ──

test("renderHtml: 对话锚点、跳转按钮、核验角标、HTML 转义", () => {
  const html = renderHtml({
    scenario: "demo",
    transcript: [
      { role: "agent", text: "第一句 <script>alert(1)</script>" },
      { role: "user", text: "第二句" },
    ],
    items: [
      { id: "H1", label: "硬断言", pass: true, detail: "" },
      { id: "C1", label: "评判项", pass: false, detail: "证据", round: 2, verified: "miss" },
    ],
    round: 4,
    tokensTotal: 12345,
  });
  assert.ok(html.includes('id="round-1"') && html.includes('id="round-2"'), "每轮对话有锚点");
  assert.ok(html.includes('data-round="2"'), "评判项带跳转按钮");
  assert.ok(html.includes("需人工复核"), "miss 核验角标");
  assert.ok(!html.includes("<script>alert"), "对话内容已转义");
  assert.ok(html.includes("&lt;script&gt;alert"), "转义后原文仍可见");
  assert.ok(html.includes("1 passed") && html.includes("1 failed"));
});

test("renderHtml: 旧 report.json（无 round/verified 字段）可渲染", () => {
  const html = renderHtml({
    scenario: "legacy",
    transcript: [],
    items: [{ id: "B1", label: "旧格式项", pass: true, detail: "旧 evidence" }],
  });
  assert.ok(html.includes("旧格式项"));
  assert.ok(!html.includes('data-round="'), "无轮次不渲染跳转按钮");
});

// ── feedback.mjs / calibrate.mjs ──

function makeRunLogDir(projectDir = null) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-fb-"));
  fs.writeFileSync(
    path.join(dir, "report.json"),
    JSON.stringify({
      scenario: "demo",
      round: 4,
      tokensTotal: 100,
      ...(projectDir ? { projectDir } : {}),
      items: [
        { id: "H2", label: "硬断言项", pass: true, detail: "" },
        { id: "C4", label: "不抢答", pass: false, detail: "证据原文", round: 3, verified: "round" },
      ],
    })
  );
  fs.writeFileSync(
    path.join(dir, "transcript.json"),
    JSON.stringify([
      { role: "agent", text: "请确认结果摘要怎么写？" },
      { role: "user", text: "大模型自动生成" },
      { role: "agent", text: "好的，那下载内容呢？" },
    ])
  );
  return dir;
}

test("recordOverride: 裁定落盘 + 评判类判定沉淀校准用例", () => {
  const logDir = makeRunLogDir();
  const calDir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-cal-"));
  const { override, caseFile } = recordOverride(logDir, "C4", true, "judge 漏看了第 2 轮的确认", calDir);
  assert.equal(override.overturned, true, "人工 pass vs judge fail → 推翻");
  assert.equal(override.judgePass, false);
  const overrides = JSON.parse(fs.readFileSync(path.join(logDir, "overrides.json"), "utf8"));
  assert.equal(overrides.length, 1);
  assert.equal(overrides[0].id, "C4");
  // 校准用例：对话 + 规则 + 人工标准答案齐全
  assert.ok(caseFile && fs.existsSync(caseFile));
  const c = JSON.parse(fs.readFileSync(caseFile, "utf8"));
  assert.equal(c.rule.id, "C4");
  assert.equal(c.human.pass, true);
  assert.equal(c.transcript.length, 3);
  // loadCases 能读回
  const cases = loadCases(calDir);
  assert.equal(cases.length, 1);
  assert.equal(cases[0].scenario, "demo");
  fs.rmSync(logDir, { recursive: true });
  fs.rmSync(calDir, { recursive: true });
});

test("recordOverride: 硬断言不进校准集；未知 ID 报错并列出可用项", () => {
  const logDir = makeRunLogDir();
  const calDir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-cal2-"));
  const { override, caseFile } = recordOverride(logDir, "H2", false, "断言脚本误判", calDir);
  assert.equal(override.overturned, true);
  assert.equal(caseFile, null, "H 系列是脚本断言，不生成 judge 校准用例");
  assert.throws(() => recordOverride(logDir, "X9", true, "x", calDir), /可用 ID: H2 C4/);
  fs.rmSync(logDir, { recursive: true });
  fs.rmSync(calDir, { recursive: true });
});

test("isJudgedItem: verified 字段或 B/C 前缀视为评判类", () => {
  assert.equal(isJudgedItem({ id: "C4" }), true);
  assert.equal(isJudgedItem({ id: "B1" }), true);
  assert.equal(isJudgedItem({ id: "H2" }), false);
  assert.equal(isJudgedItem({ id: "R1", verified: "round" }), true, "带核验字段的按评判类处理");
});

test("applyOverrides + renderHtml: 人工裁定叠加显示且计入汇总", () => {
  const items = [
    { id: "H1", label: "硬断言", pass: true },
    { id: "C4", label: "不抢答", pass: false, detail: "证据", round: 3, verified: "round" },
  ];
  const overrides = [
    { id: "C4", pass: true, reason: "judge 漏看确认", judgePass: false, overturned: true, at: "2026-07-02T00:00:00Z" },
  ];
  const merged = applyOverrides(items, overrides);
  assert.equal(merged[1].effectivePass, true, "人工裁定覆盖 judge 结论");
  assert.equal(merged[0].effectivePass, true, "无裁定的项保持原判");
  const html = renderHtml({ scenario: "demo", transcript: [], items, overrides });
  assert.ok(html.includes("人工复核推翻"), "叠加显示推翻标记");
  assert.ok(html.includes("judge 漏看确认"), "显示裁定理由");
  assert.ok(html.includes("2 passed") && html.includes("0 failed"), "汇总按人工裁定后结果统计");
  assert.ok(html.includes("1 项人工复核"));
});

test("renderHtml: 评判类判定带网页复核表单，硬断言不带", () => {
  const html = renderHtml({
    scenario: "demo",
    transcript: [],
    items: [
      { id: "H1", label: "硬断言", pass: true },
      { id: "C4", label: "不抢答", pass: false, verified: "round" },
    ],
  });
  assert.ok(html.includes('data-id="C4"'), "C 系列有复核表单");
  assert.ok(!html.includes('data-id="H1"'), "H 系列无复核表单");
  assert.ok(html.includes("复核此判定"));
  assert.ok(html.includes("/api/override"), "提交走复核服务接口");
});

test("review-server: 网页提交裁定落盘，非法请求 400", async () => {
  const logDir = makeRunLogDir();
  const calDir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-cal3-"));
  const server = createReviewServer(logDir, { calibrationDir: calDir });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    // GET / 返回渲染后的报告
    const page = await fetch(base + "/");
    assert.equal(page.status, 200);
    assert.ok((await page.text()).includes("不抢答"));
    // POST 裁定 → overrides.json 落盘
    const r = await fetch(base + "/api/override", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: "C4", pass: true, reason: "网页复核测试" }),
    });
    const data = await r.json();
    assert.equal(data.ok, true);
    assert.equal(data.overturned, true);
    const overrides = JSON.parse(fs.readFileSync(path.join(logDir, "overrides.json"), "utf8"));
    assert.equal(overrides[0].reason, "网页复核测试");
    // 再 GET：叠加显示人工复核
    assert.ok((await (await fetch(base + "/")).text()).includes("人工复核推翻"));
    // 缺理由 → 400
    const bad = await fetch(base + "/api/override", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: "C4", pass: true, reason: " " }),
    });
    assert.equal(bad.status, 400);
    // 校准用例落在指定目录而非仓库默认目录
    assert.equal(loadCases(calDir).length, 1);
  } finally {
    server.close();
    fs.rmSync(logDir, { recursive: true });
    fs.rmSync(calDir, { recursive: true });
  }
});

test("unresolvedItems: 失败项与证据存疑项需裁定，裁定后视为已复核", () => {
  const items = [
    { id: "H1", pass: true },
    { id: "C1", pass: false },                       // ✗ 未裁定 → 未复核
    { id: "C2", pass: true, verified: "miss" },       // ⚠ 证据存疑未裁定 → 未复核
    { id: "C3", pass: true, verified: "round" },      // ✓ 且核验通过 → 不需要
  ];
  assert.deepEqual(unresolvedItems(items, []), ["C1", "C2"]);
  assert.deepEqual(unresolvedItems(items, [{ id: "C1", pass: true }]), ["C2"]);
  assert.deepEqual(
    unresolvedItems(items, [{ id: "C1", pass: false }, { id: "C2", pass: true }]),
    [],
    "确认 fail 也算复核完成"
  );
});

test("review-server /api/cleanup: 未复核完拒绝，复核完删项目，日志保留", async () => {
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-proj-"));
  fs.mkdirSync(path.join(projectDir, ".minus"), { recursive: true });
  const logDir = makeRunLogDir(projectDir);
  const calDir = fs.mkdtempSync(path.join(os.tmpdir(), "e2e-agent-cal4-"));
  const server = createReviewServer(logDir, { calibrationDir: calDir });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    // C4 是 fail 且未裁定 → 门禁拒绝
    const denied = await fetch(base + "/api/cleanup", { method: "POST" });
    assert.equal(denied.status, 409);
    const d = await denied.json();
    assert.deepEqual(d.unresolved, ["C4"]);
    assert.ok(fs.existsSync(projectDir), "被拒绝时项目必须原封不动");
    // 裁定 C4 后 → 清理放行
    await fetch(base + "/api/override", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: "C4", pass: false, reason: "确认是真违规" }),
    });
    const ok = await (await fetch(base + "/api/cleanup", { method: "POST" })).json();
    assert.equal(ok.ok, true);
    assert.ok(!fs.existsSync(projectDir), "项目已删除");
    assert.ok(fs.existsSync(path.join(logDir, "report.json")), "日志与报告保留");
    assert.ok(fs.existsSync(path.join(logDir, "overrides.json")), "裁定档案保留");
  } finally {
    server.close();
    fs.rmSync(logDir, { recursive: true });
    fs.rmSync(calDir, { recursive: true });
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
});

test("review-server /api/cleanup: 非 e2e-agent-* 目录一律拒绝删除", async () => {
  const realProject = fs.mkdtempSync(path.join(os.tmpdir(), "my-real-project-"));
  const logDir = makeRunLogDir(realProject);
  // 改造 report：无失败项，门禁可过，卡在目录名约束上
  const report = JSON.parse(fs.readFileSync(path.join(logDir, "report.json"), "utf8"));
  report.items = [{ id: "H1", label: "ok", pass: true }];
  fs.writeFileSync(path.join(logDir, "report.json"), JSON.stringify(report));
  const server = createReviewServer(logDir);
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  try {
    const r = await fetch(`http://127.0.0.1:${server.address().port}/api/cleanup`, { method: "POST" });
    assert.equal(r.status, 400);
    assert.ok((await r.json()).error.includes("拒绝清理"));
    assert.ok(fs.existsSync(realProject), "真实目录不能被碰");
  } finally {
    server.close();
    fs.rmSync(logDir, { recursive: true });
    fs.rmSync(realProject, { recursive: true });
  }
});

test("renderHtml: 有 projectDir 时渲染清理入口，无则不渲染", () => {
  const withDir = renderHtml({ scenario: "demo", items: [], projectDir: "/tmp/e2e-agent-x" });
  assert.ok(withDir.includes("复核完成，清理临时项目"));
  assert.ok(withDir.includes("/api/cleanup"));
  const without = renderHtml({ scenario: "demo", items: [] });
  assert.ok(!without.includes('id="cleanup-btn"'));
});

// ── session.mjs（stream-json 单进程会话）──

test("parseLine / extractResult: 事件解析与 result 提取", () => {
  assert.equal(parseLine(""), null);
  assert.equal(parseLine("非 JSON 行"), null);
  assert.equal(extractResult(parseLine('{"type":"assistant"}')), null);
  const r = extractResult(
    parseLine('{"type":"result","subtype":"success","result":"好","session_id":"s1","usage":{"input_tokens":18,"output_tokens":378},"total_cost_usd":0.037}')
  );
  assert.equal(r.text, "好");
  assert.equal(r.sessionId, "s1");
  assert.deepEqual(r.usage, { input: 18, output: 378 });
  assert.equal(r.costUsd, 0.037);
});

const STUB_CLAUDE = path.join(HERE, "stub-claude.mjs");

function stubSession(extra = {}) {
  return new ClaudeSession({
    command: process.execPath,
    prependArgs: [STUB_CLAUDE],
    ...extra,
  }).start();
}

test("ClaudeSession: 单进程多轮问答、usage 累计、正常收尾", async () => {
  const events = [];
  const s = stubSession({ onEvent: (e) => events.push(e.type) });
  const r1 = await s.send("第一轮");
  assert.equal(r1.text, "echo: 第一轮");
  assert.equal(r1.sessionId, "stub-session-1");
  const r2 = await s.send("第二轮");
  assert.equal(r2.text, "echo: 第二轮");
  assert.ok(events.includes("assistant") && events.includes("result"));
  await s.close();
  assert.equal(s.exited, true);
  assert.equal(s.exitInfo.code, 0, "stdin end 后进程正常退出");
});

test("ClaudeSession: 进程中途死亡 → 在途轮次报错，后续 send 拒绝", async () => {
  const s = stubSession();
  await assert.rejects(() => s.send("CRASH"), /进程在等待应答时退出.*code=3/);
  await assert.rejects(() => s.send("再来"), /进程已退出/);
});

test("ClaudeSession: 应答超时与串行约束", async () => {
  const s = stubSession();
  const slow = s.send("SLOW", { timeoutMs: 300 });
  await assert.rejects(() => s.send("插队"), /串行发送/);
  await assert.rejects(() => slow, /超时/);
  await s.close();
});

test("parseTranscriptMd: 按 record() 的 md 格式回解析", () => {
  const md = "## Agent\n\n你好，我们开始。\n\n---\n\n## 模拟用户\n\n好的，继续\n";
  assert.deepEqual(parseTranscriptMd(md), [
    { role: "agent", text: "你好，我们开始。" },
    { role: "user", text: "好的，继续" },
  ]);
});

// ── mock Claude_Preview MCP server（Desktop 模式）──

const MOCK = path.join(path.dirname(fileURLToPath(import.meta.url)), "mock-preview-mcp.mjs");

// 起一个 mock MCP 子进程，发一串 JSON-RPC 请求，收齐响应
function mcpRoundtrip(cwd, requests) {
  return new Promise((resolve, reject) => {
    const { spawn } = childProcess;
    const child = spawn(process.execPath, [MOCK], { cwd, stdio: ["pipe", "pipe", "inherit"] });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.on("close", () => {
      try {
        resolve(out.trim().split("\n").map((l) => JSON.parse(l)));
      } catch (e) { reject(e); }
    });
    child.on("error", reject);
    child.stdin.write(requests.map((r) => JSON.stringify(r) + "\n").join(""));
    child.stdin.end();
  });
}

function callText(resp) {
  return resp.result.content[0].text;
}

test("mock-preview-mcp: 协议、幂等、跨进程复用、stop、不支持工具报错", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mockprev-"));
  const init = { jsonrpc: "2.0", id: 1, method: "initialize", params: {} };
  const start = { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "preview_start", arguments: { name: "frontend" } } };

  // 第一次 start：分配高位端口，reused:false，状态文件落盘
  let resps = await mcpRoundtrip(dir, [init, { jsonrpc: "2.0", id: 9, method: "tools/list" }, start]);
  const tools = resps.find((r) => r.id === 9).result.tools.map((t) => t.name);
  assert.ok(tools.includes("preview_start") && tools.includes("preview_list") && tools.includes("preview_stop"));
  const first = JSON.parse(callText(resps.find((r) => r.id === 2)).split("\n}")[0] + "\n}");
  assert.equal(first.reused, false);
  assert.ok(first.port > 1024);
  const stateFile = path.join(dir, ".minus", "mock-preview-state.json");
  assert.ok(fs.existsSync(stateFile), "状态文件已写入");

  // 第二次（新 MCP 进程，模拟下一轮 claude -p）：同 serverId/端口，reused:true
  resps = await mcpRoundtrip(dir, [init, start, { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "preview_eval", arguments: {} } }]);
  const second = JSON.parse(callText(resps.find((r) => r.id === 2)).split("\n}")[0] + "\n}");
  assert.equal(second.reused, true);
  assert.equal(second.port, first.port);
  assert.equal(second.serverId, first.serverId);
  const evalResp = resps.find((r) => r.id === 3);
  assert.equal(evalResp.result.isError, true, "不支持的工具明确报错");

  // 子进程真实可达
  const reachable = await fetch(`http://127.0.0.1:${first.port}/`).then((r) => r.ok).catch(() => false);
  assert.equal(reachable, true, "detached 子进程跨 MCP 进程存活且可达");

  // stop：杀子进程并清状态
  resps = await mcpRoundtrip(dir, [init, { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "preview_stop", arguments: { serverId: first.serverId } } }]);
  assert.ok(callText(resps.find((r) => r.id === 4)).includes("stopped"));
  assert.deepEqual(JSON.parse(fs.readFileSync(stateFile, "utf8")), {});

  fs.rmSync(dir, { recursive: true });
});
