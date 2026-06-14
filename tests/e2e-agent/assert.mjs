// assert.mjs — 硬断言执行器（断言清单 H 系列）
// 所有断言在 skill 项目目录（cwd）下执行，结果累积到 report。

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

export class Report {
  constructor() {
    this.items = [];
  }
  add(id, label, pass, detail = "") {
    this.items.push({ id, label, pass, detail });
    const mark = pass ? "✓" : "✗";
    console.log(`  ${mark} [${id}] ${label}${pass || !detail ? "" : ` — ${detail}`}`);
    return pass;
  }
  get failed() {
    return this.items.filter((i) => !i.pass);
  }
  summary() {
    const pass = this.items.filter((i) => i.pass).length;
    return { pass, fail: this.items.length - pass, total: this.items.length };
  }
}

function sh(cwd, file, args) {
  try {
    const out = execFileSync("bash", [file, ...args], {
      cwd,
      encoding: "utf8",
      timeout: 60_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { ok: true, out };
  } catch (err) {
    return { ok: false, out: `${err.stdout || ""}${err.stderr || ""}${err.message}` };
  }
}

const DIMS = ["data", "logic", "output", "confirm"];

// H1：结构设计后 pipeline 节点数
export function assertStructure(report, projectDir, expectedSteps) {
  const skillJson = path.join(projectDir, ".minus", "skill.json");
  let n = countPipelineSteps(projectDir);
  return report.add(
    "H1",
    `pipeline 拆成 ${expectedSteps} 个节点`,
    n === expectedSteps,
    `实际 ${n} 个（${skillJson}）`
  );
}

export function countPipelineSteps(projectDir) {
  // 优先 .minus/total-steps，其次 pipeline.py 的 step_N 计数
  const totalFile = path.join(projectDir, ".minus", "total-steps");
  if (fs.existsSync(totalFile)) {
    const n = parseInt(fs.readFileSync(totalFile, "utf8").trim(), 10);
    if (Number.isFinite(n)) return n;
  }
  const pipelineFile = path.join(projectDir, "pipeline.py");
  if (fs.existsSync(pipelineFile)) {
    const code = fs.readFileSync(pipelineFile, "utf8");
    return new Set(
      [...code.matchAll(/async def step_(\d+)\(/g)].map((m) => m[1])
    ).size;
  }
  return 0;
}

// H2：四维度全完成且按 ①→②→③→④ 顺序（用状态文件 mtime 验证时序）
export function assertDimensions(report, projectDir, step, trackerPath) {
  const check = sh(projectDir, trackerPath, ["check", String(step)]);
  const complete = check.ok && /(^|\n)COMPLETE(\n|$)/.test(check.out);
  report.add("H2", `step${step} 四维度全部完成`, complete, check.out.trim());
  if (!complete) return false;

  const trackerDir = path.join(projectDir, ".minus", "dev-progress");
  const times = DIMS.map((d) => {
    const f = path.join(trackerDir, `step_${step}_${d}`);
    return fs.existsSync(f) ? fs.statSync(f).mtimeMs : Infinity;
  });
  const ordered = times.every((t, i) => i === 0 || times[i - 1] <= t);
  return report.add(
    "H2",
    `step${step} 维度完成顺序 ①→②→③→④`,
    ordered,
    `mtime 序列: ${times.map((t) => Math.round(t)).join(" → ")}`
  );
}

// H3：门禁通过（GATE_PASSED）
export function assertGate(report, projectDir, step, genNodeCodePath) {
  const res = sh(projectDir, genNodeCodePath, [String(step)]);
  const passed = res.ok && res.out.includes("GATE_PASSED");
  report.add("H3", `step${step} 门禁 GATE_PASSED`, passed, passed ? "" : res.out.slice(0, 500));
  return passed ? res.out : null;
}

// H5（一部分）：is-last 判定
export function assertIsLast(report, projectDir, step, trackerPath, expectYes) {
  const res = sh(projectDir, trackerPath, ["is-last", String(step)]);
  const val = res.out.trim();
  const want = expectYes ? "YES" : "NO";
  return report.add(
    "H5",
    `step${step} is-last = ${want}`,
    res.ok && val === want,
    `实际: ${val}`
  );
}

// 节点代码已实现（pipeline.py 中 step_N 不是占位骨架）
export function assertStepImplemented(report, projectDir, step) {
  const implemented = stepImplemented(projectDir, step);
  return report.add(
    "H4",
    `step${step} 代码已生成（非骨架占位）`,
    implemented,
    implemented ? "" : `pipeline.py 中 step_${step} 仍是占位实现`
  );
}

export function stepImplemented(projectDir, step) {
  const pipelineFile = path.join(projectDir, "pipeline.py");
  if (!fs.existsSync(pipelineFile)) return false;
  const code = fs.readFileSync(pipelineFile, "utf8");
  const m = code.match(
    new RegExp(`async def step_${step}\\([\\s\\S]*?(?=\\n\\s*async def step_|$)`)
  );
  if (!m) return false;
  const body = m[0];
  // 骨架特征：TODO / NotImplemented / 仅 pass / 占位 complete
  if (/TODO|NotImplementedError/.test(body)) return false;
  const meaningful = body
    .split("\n")
    .slice(1)
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("#") && !l.startsWith('"""') && l !== "pass");
  return meaningful.length >= 3;
}

// 结果页设计完成检测：两维度（摘要/下载）均已确认，且结果页代码已生成。
// 标记落在 .minus/dev-progress/result_{summary,download}_confirmed（generate-result-design confirm 写）；
// 代码标志：FlowApp 的 renderCompletion / CompletionPanel（结果页只能放这里，见 platform frontend-guide）。
export function resultComplete(projectDir) {
  const dir = path.join(projectDir, ".minus", "dev-progress");
  const summary = fs.existsSync(path.join(dir, "result_summary_confirmed"));
  const download = fs.existsSync(path.join(dir, "result_download_confirmed"));
  return summary && download && resultRendered(projectDir);
}

function resultRendered(projectDir) {
  const main = path.join(projectDir, "frontend", "src", "main.tsx");
  try {
    return /renderCompletion|CompletionPanel/.test(fs.readFileSync(main, "utf8"));
  } catch {
    return false;
  }
}

// R 系列：结果呈现设计阶段断言（两维度确认 + 代码生成 + 写代码门禁）
export function assertResult(report, projectDir, genResultPath) {
  const dir = path.join(projectDir, ".minus", "dev-progress");
  const summary = fs.existsSync(path.join(dir, "result_summary_confirmed"));
  const download = fs.existsSync(path.join(dir, "result_download_confirmed"));
  report.add("R1", "结果页两维度（摘要/下载）均已确认", summary && download,
    `summary=${summary} download=${download}`);
  report.add("R2", "结果页代码已生成（renderCompletion/CompletionPanel）", resultRendered(projectDir),
    resultRendered(projectDir) ? "" : "frontend/src/main.tsx 未见结果页渲染");
  const res = sh(projectDir, genResultPath, ["check"]);
  const gated = res.ok && res.out.includes("RESULT_DESIGN_COMPLETE");
  report.add("R3", "结果页写代码门禁 RESULT_DESIGN_COMPLETE", gated, gated ? "" : res.out.slice(0, 300));
}

// 节点 / 终验输出 payload 字段检查（宽松子串匹配，忽略大小写）
export function assertPayloadContains(report, id, label, payload, needles) {
  const text = JSON.stringify(payload ?? {}).toLowerCase();
  let allOk = true;
  for (const needle of needles || []) {
    const ok = text.includes(String(needle).toLowerCase());
    report.add(id, `${label} 包含 "${needle}"`, ok, ok ? "" : `payload: ${text.slice(0, 300)}`);
    allOk = allOk && ok;
  }
  return allOk;
}
