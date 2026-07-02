// driver.mjs — E2E Agent 测试驱动器
// 用 claude -p 真实驱动 Creator Agent，LLM 模拟用户应答，
// 按阶段执行硬断言（H 系列），最后真实运行 skill + 行为评判（B 系列）。
//
// 由 run.sh 调用，依赖环境变量：
//   E2E_PROJECT_DIR  skill 项目目录
//   E2E_PLUGIN_DIR   插件目录（--plugin-dir）
//   E2E_LOG_DIR      日志目录
//   E2E_SCENARIO     剧本文件路径

import fs from "node:fs";
import path from "node:path";
import { execFile, execFileSync } from "node:child_process";

import { loadScenario } from "./scenario.mjs";
import {
  Report,
  assertStructure,
  assertDimensions,
  assertGate,
  assertIsLast,
  assertStepImplemented,
  assertNoHiddenSteps,
  assertResult,
  resultComplete,
  assertPayloadContains,
  countPipelineSteps,
  stepImplemented,
} from "./assert.mjs";
import { simulateUser } from "./simulate-user.mjs";
import { judgeTranscript, formatTranscriptLines, verifyEvidence } from "./judge.mjs";
import { renderHtml } from "./report-html.mjs";
import { runPipeline, stopDevServer } from "./run-skill.mjs";

const PROJECT_DIR = required("E2E_PROJECT_DIR");
const PLUGIN_DIR = required("E2E_PLUGIN_DIR");
const LOG_DIR = required("E2E_LOG_DIR");
const SCENARIO_FILE = required("E2E_SCENARIO");

const MAX_ROUNDS = parseInt(process.env.E2E_MAX_ROUNDS || "60", 10);
const AGENT_MODEL = process.env.E2E_AGENT_MODEL || "sonnet";
const ROUND_BUDGET_USD = process.env.E2E_ROUND_BUDGET_USD || "3";
const SKIP_RUN = process.env.E2E_SKIP_RUN === "1"; // 跳过真实运行（调试对话流程用）
// Desktop 模式：注入 CLAUDE_CODE_ENTRYPOINT + mock Claude_Preview MCP，
// 驱动 env-init 走分支 A（preview_start → record-preview-port → 门禁）。
// 验证的是 Agent 行为链；进程不可见的降级路径由 shell 桩测试覆盖。
const DESKTOP = process.env.E2E_DESKTOP === "1";
const MOCK_PREVIEW_MCP = path.join(path.dirname(new URL(import.meta.url).pathname), "mock-preview-mcp.mjs");
const MCP_CONFIG_FILE = path.join(LOG_DIR, "mock-preview-mcp.json");
if (DESKTOP) {
  fs.writeFileSync(MCP_CONFIG_FILE, JSON.stringify({
    mcpServers: { Claude_Preview: { command: process.execPath, args: [MOCK_PREVIEW_MCP] } },
  }, null, 2));
}

const TRACKER = path.join(PLUGIN_DIR, "skills/minus-step/scripts/step-tracker.sh");
const GEN_NODE = path.join(PLUGIN_DIR, "skills/minus-step/scripts/generate-node-code.sh");
const GEN_RESULT = path.join(PLUGIN_DIR, "skills/minus-structure/scripts/generate-result-design.sh");

function required(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`缺少环境变量 ${name}（应由 run.sh 设置）`);
    process.exit(2);
  }
  return v;
}

// ── 对话 ──

const transcript = [];
let sessionId = null;
let round = 0;
let tokensTotal = 0;

function record(role, text) {
  transcript.push({ role, text });
  const tag = role === "agent" ? "\x1b[36m[Agent]\x1b[0m" : "\x1b[33m[模拟用户]\x1b[0m";
  console.log(`\n${tag} ${text}\n`);
  const md = transcript
    .map((t) => `## ${t.role === "agent" ? "Agent" : "模拟用户"}\n\n${t.text}\n`)
    .join("\n---\n\n");
  fs.writeFileSync(path.join(LOG_DIR, "transcript.md"), md);
  // 结构化对话：report-html 回放与证据核验的数据源（md 是给人 grep 的，json 是给机器的）
  fs.writeFileSync(path.join(LOG_DIR, "transcript.json"), JSON.stringify(transcript, null, 2));
}

function claudeSend(prompt) {
  const args = [
    "--print",
    "--plugin-dir", PLUGIN_DIR,
    "--model", AGENT_MODEL,
    "--dangerously-skip-permissions",
    "--output-format", "json",
    "--max-budget-usd", ROUND_BUDGET_USD,
  ];
  if (DESKTOP) args.push("--mcp-config", MCP_CONFIG_FILE);
  if (sessionId) args.push("--resume", sessionId);
  args.push(prompt);
  const env = DESKTOP
    ? { ...process.env, CLAUDE_CODE_ENTRYPOINT: "claude-desktop" }
    : process.env;
  return new Promise((resolve, reject) => {
    execFile(
      "claude",
      args,
      { cwd: PROJECT_DIR, timeout: 15 * 60_000, maxBuffer: 32 * 1024 * 1024, env },
      (err, stdout, stderr) => {
        round++;
        fs.writeFileSync(path.join(LOG_DIR, `round-${round}.json`), stdout || "");
        let parsed = null;
        try {
          parsed = JSON.parse(stdout);
        } catch {}
        if (err && !parsed) {
          reject(new Error(`claude 调用失败（round ${round}）: ${err.message}\n${(stderr || "").slice(0, 500)}`));
          return;
        }
        if (parsed?.session_id) sessionId = parsed.session_id;
        const usage = parsed?.usage;
        if (usage) tokensTotal += (usage.input_tokens || 0) + (usage.output_tokens || 0);
        resolve(parsed?.result ?? stdout);
      }
    );
  });
}

// ── 阶段检测 ──

function trackerComplete(step) {
  try {
    const out = execFileSync("bash", [TRACKER, "check", String(step)], {
      cwd: PROJECT_DIR,
      encoding: "utf8",
      timeout: 30_000,
    });
    return /(^|\n)COMPLETE(\n|$)/.test(out);
  } catch {
    return false;
  }
}

// ── 主流程 ──

const scenario = loadScenario(SCENARIO_FILE);
const report = new Report();
const startedAt = Date.now();

const phaseState = {
  structureAsserted: false,
  stepAsserted: Object.fromEntries(
    Array.from({ length: scenario.steps }, (_, i) => [i + 1, false])
  ),
  hiddenStepsAsserted: false,
  resultAsserted: false,
};

let devServerHandle = null;

// Desktop 分支 A 行为链断言：env-init 完成后（结构设计开始即说明已过门禁），
// D1: Agent 把 preview_start 返回的端口 record 进了 dev-ports.json（高位端口下门禁通过的唯一途径）
// D2: 门禁脚本在项目里真实通过
function assertDesktopPreview() {
  const stateFile = path.join(PROJECT_DIR, ".minus", "mock-preview-state.json");
  const portsFile = path.join(PROJECT_DIR, ".minus", "dev-ports.json");
  let mockPort = null, recordedPort = null;
  try {
    mockPort = Object.values(JSON.parse(fs.readFileSync(stateFile, "utf8")))[0]?.port ?? null;
  } catch {}
  try {
    recordedPort = JSON.parse(fs.readFileSync(portsFile, "utf8")).frontend ?? null;
  } catch {}
  report.add("D1", `preview_start 端口已 record 进 dev-ports.json（mock=${mockPort} recorded=${recordedPort}）`,
    mockPort !== null && recordedPort === mockPort);
  let gateOut = "", gateOk = false;
  try {
    gateOut = execFileSync("bash", [path.join(PLUGIN_DIR, "skills/minus/scripts/check-dev-server.sh")], {
      cwd: PROJECT_DIR, encoding: "utf8", timeout: 60_000,
      env: { ...process.env, DETECT_PORT_MAX_WAIT: "3" },
    });
    gateOk = /GATE_PASSED/.test(gateOut);
  } catch (err) {
    gateOut = (err.stdout || "") + (err.stderr || "");
  }
  report.add("D2", "dev server 门禁 GATE_PASSED（Desktop 分支 A）", gateOk, gateOk ? "" : gateOut.slice(0, 200));
}

function stopMockPreview() {
  if (!DESKTOP) return;
  const stateFile = path.join(PROJECT_DIR, ".minus", "mock-preview-state.json");
  try {
    for (const s of Object.values(JSON.parse(fs.readFileSync(stateFile, "utf8")))) {
      try { process.kill(s.pid); } catch {}
    }
  } catch {}
}

async function checkPhaseTransitions(forceResult = false) {
  if (!phaseState.structureAsserted && countPipelineSteps(PROJECT_DIR) >= scenario.steps) {
    console.log("\n═══ 阶段断言：结构设计 ═══");
    assertStructure(report, PROJECT_DIR, scenario.steps);
    if (DESKTOP) {
      console.log("\n═══ 阶段断言：Desktop 分支 A（preview → record → 门禁） ═══");
      assertDesktopPreview();
    }
    phaseState.structureAsserted = true;
  }
  for (let n = 1; n <= scenario.steps; n++) {
    if (phaseState.stepAsserted[n]) continue;
    if (!trackerComplete(n) || !stepImplemented(PROJECT_DIR, n)) continue;
    console.log(`\n═══ 阶段断言：step${n} ═══`);
    assertDimensions(report, PROJECT_DIR, n, TRACKER);
    assertGate(report, PROJECT_DIR, n, GEN_NODE);
    assertIsLast(report, PROJECT_DIR, n, TRACKER, n === scenario.steps);
    assertStepImplemented(report, PROJECT_DIR, n);
    if (!SKIP_RUN) {
      await runNodeVerification(n);
    }
    phaseState.stepAsserted[n] = true;
  }
  // H6：所有步骤代码生成后，检查 pipeline.py 无隐藏步骤
  if (
    !phaseState.hiddenStepsAsserted &&
    Object.values(phaseState.stepAsserted).every(Boolean)
  ) {
    console.log("\n═══ 阶段断言：无隐藏步骤 ═══");
    assertNoHiddenSteps(report, PROJECT_DIR, scenario.steps);
    phaseState.hiddenStepsAsserted = true;
  }
  // 结果呈现设计阶段：所有步骤完成后触发结果页断言。
  // 触发条件二选一（任一即评判，避免死锁）：
  //   1. resultComplete：两维度确认标记 + 结果页代码都齐（Agent 走完正常流程）
  //   2. forceResult：对话已停滞（Agent 连续多轮不再提问，自认为做完了）——
  //      此时若 Agent 漏跑 generate-result-design confirm，R1/R3 会如实判失败，
  //      而不是让循环空转到 MAX_ROUNDS。教训同 confirmedKey：退出不依赖 Agent 记得跑跟踪命令。
  if (
    !phaseState.resultAsserted &&
    Object.values(phaseState.stepAsserted).every(Boolean) &&
    (resultComplete(PROJECT_DIR) || forceResult)
  ) {
    console.log("\n═══ 阶段断言：结果呈现设计 ═══");
    assertResult(report, PROJECT_DIR, GEN_RESULT);
    phaseState.resultAsserted = true;
  }
}

async function runNodeVerification(n) {
  console.log(`\n═══ 逐节点真实验证：step${n} ═══`);
  try {
    const result = await runPipeline(PROJECT_DIR, LOG_DIR, scenario.expect.final_input || {}, {
      targetStep: n,
      confirmData: scenario.expect.confirm_data || {},
    });
    devServerHandle = devServerHandle || result.server;
    const terminal = result.terminal;
    const ok =
      terminal &&
      (terminal.messageType === "step_complete" ||
        terminal.messageType === "step_input_required") &&
      terminal.payload?.stepNumber === n;
    report.add("H4", `step${n} 真实执行到位（${terminal?.messageType || "无终态"}）`, !!ok);
    if (ok && n === 1 && scenario.expect.step1_output_contains) {
      assertPayloadContains(
        report, "H4", "step1 输出",
        terminal.payload?.data,
        scenario.expect.step1_output_contains
      );
    }
  } catch (err) {
    report.add("H4", `step${n} 真实执行`, false, err.message);
  }
}

function currentPhase() {
  if (!phaseState.structureAsserted) return "structure";
  for (let n = 1; n <= scenario.steps; n++) {
    if (!phaseState.stepAsserted[n]) return `step${n}`;
  }
  return "result";
}

// 全流程完成 = 结构 + 所有 pipeline 步骤 + 结果呈现设计。
// ⚠ 不能只看 pipeline 步骤就退出对话——否则结果页 Q&A 跑半句就被掐断，
// answers.result 永不被用、结果页从不生成/断言（2026-06-14 复盘：对话提前终止缺陷）。
function allStepsDone() {
  return (
    phaseState.structureAsserted &&
    Object.values(phaseState.stepAsserted).every(Boolean) &&
    phaseState.resultAsserted
  );
}

async function finalVerification() {
  if (SKIP_RUN) {
    console.log("\n（E2E_SKIP_RUN=1，跳过终验真实运行）");
    return;
  }
  console.log("\n═══ 终验：以最终用户身份完整运行 ═══");
  try {
    const result = await runPipeline(PROJECT_DIR, LOG_DIR, scenario.expect.final_input || {}, {
      targetStep: null,
      confirmData: scenario.expect.confirm_data || {},
    });
    devServerHandle = devServerHandle || result.server;
    const done = result.terminal?.messageType === "pipeline_complete";
    report.add("H6", "完整 pipeline 跑通（pipeline_complete）", done);
    if (done && scenario.expect.final_output_contains) {
      const lastComplete = [...result.messages]
        .reverse()
        .find((m) => m.messageType === "step_complete");
      assertPayloadContains(
        report, "H6", "最终结果",
        lastComplete?.payload?.data,
        scenario.expect.final_output_contains
      );
    }
  } catch (err) {
    report.add("H6", "完整 pipeline 跑通", false, err.message);
  }
}

async function behaviorJudge() {
  if (!scenario.transcript_rules.length) return;
  console.log("\n═══ 行为规则评判 ═══");
  // 评判与核验必须用同一份带轮次号的文本，evidence 才能逐字对回原文
  const lines = formatTranscriptLines(transcript);
  try {
    const verdicts = await judgeTranscript(scenario.transcript_rules, lines.join("\n\n"));
    for (const v of verdicts) {
      const verified = verifyEvidence(v, lines);
      report.add(v.id, v.rule, v.pass, v.evidence, { round: v.round, verified });
    }
  } catch (err) {
    report.add("B?", "行为规则评判执行", false, err.message);
  }
}

function finish(code) {
  const { pass, fail, total } = report.summary();
  const mins = ((Date.now() - startedAt) / 60000).toFixed(1);
  console.log("\n═══════════════════════════════════════");
  console.log(`  结果: ${pass} passed, ${fail} failed (共 ${total} 项)`);
  console.log(`  对话轮数: ${round}  tokens: ~${tokensTotal}  耗时: ${mins} 分钟`);
  console.log(`  transcript: ${path.join(LOG_DIR, "transcript.md")}`);
  console.log("═══════════════════════════════════════");
  fs.writeFileSync(
    path.join(LOG_DIR, "report.json"),
    JSON.stringify({ scenario: scenario.name, items: report.items, round, tokensTotal }, null, 2)
  );
  try {
    const htmlFile = path.join(LOG_DIR, "report.html");
    fs.writeFileSync(
      htmlFile,
      renderHtml({ scenario: scenario.name, transcript, items: report.items, round, tokensTotal })
    );
    console.log(`  回放报告: ${htmlFile}`);
    if (fail > 0) {
      console.log(`  网页复核（对判定不认可时）: node tests/e2e-agent/review-server.mjs ${LOG_DIR}`);
    }
  } catch (err) {
    console.error(`  ⚠ 回放报告生成失败: ${err.message}`);
  }
  stopDevServer(devServerHandle);
  stopMockPreview();
  process.exit(code ?? (fail > 0 ? 1 : 0));
}

// 完成信号：所有阶段断言已触发，且 Agent 不再有待答问题
async function main() {
  console.log(`剧本: ${scenario.name}（${scenario.steps} 步）`);
  console.log(`项目: ${PROJECT_DIR}`);
  console.log(`Agent 模型: ${AGENT_MODEL}  最大轮数: ${MAX_ROUNDS}`);

  let agentText = await claudeSend(scenario.brief.trim());
  record("agent", agentText);

  // 停滞计数：Agent 输出不含问句即 +1，提问则归零。连续 STALL_LIMIT 轮无提问 →
  // 视为 Agent 自认为做完（常见为退化成"再见/谢谢"循环），强制评判结果页并退出。
  const STALL_LIMIT = 3;
  let idleRounds = /[?？]/.test(agentText) ? 0 : 1;

  while (round < MAX_ROUNDS) {
    await checkPhaseTransitions(idleRounds >= STALL_LIMIT);
    if (allStepsDone()) break;

    let userReply;
    try {
      userReply = await simulateUser(scenario, agentText, currentPhase());
    } catch (err) {
      console.error(`模拟用户失败: ${err.message}，用兜底回答`);
      userReply = "按你的推荐来，继续";
    }
    record("user", userReply);
    agentText = await claudeSend(userReply);
    record("agent", agentText);
    idleRounds = /[?？]/.test(agentText) ? 0 : idleRounds + 1;
  }

  await checkPhaseTransitions(true);
  if (!allStepsDone()) {
    report.add(
      "H0",
      `对话在 ${MAX_ROUNDS} 轮内完成全部节点开发 + 结果页`,
      false,
      `结构: ${phaseState.structureAsserted}，节点: ${JSON.stringify(phaseState.stepAsserted)}，结果页: ${phaseState.resultAsserted}`
    );
    await behaviorJudge();
    finish(1);
    return;
  }

  await finalVerification();
  await behaviorJudge();
  finish();
}

main().catch((err) => {
  console.error(`驱动器异常: ${err.stack || err.message}`);
  finish(1);
});
