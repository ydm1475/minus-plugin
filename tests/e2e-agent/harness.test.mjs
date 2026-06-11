// harness.test.mjs — e2e-agent harness 自身的单元测试（不消耗 token）
// 运行: node --test tests/e2e-agent/harness.test.mjs

import { test } from "node:test";
import assert from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { parseYaml, loadScenario } from "./scenario.mjs";
import { buildSimPrompt } from "./simulate-user.mjs";
import { buildJudgePrompt, parseVerdicts } from "./judge.mjs";
import { parseSseChunk, resolveEntryParams, buildConfirmData } from "./run-skill.mjs";
import { Report, stepImplemented, countPipelineSteps } from "./assert.mjs";

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

test("buildJudgePrompt: 包含全部规则", () => {
  const p = buildJudgePrompt(
    [{ id: "B1", rule: "两步法顺序" }],
    "【Agent】hi"
  );
  assert.ok(p.includes("B1: 两步法顺序"));
  assert.ok(p.includes("【Agent】hi"));
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

test("Report: 统计与失败收集", () => {
  const r = new Report();
  r.add("H1", "ok 项", true);
  r.add("H2", "fail 项", false, "原因");
  assert.deepEqual(r.summary(), { pass: 1, fail: 1, total: 2 });
  assert.equal(r.failed[0].id, "H2");
});
