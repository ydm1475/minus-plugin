// feedback.mjs — 断言/评判结果的人工复核通道
// 对某次 run 的判定不认可（或想显式确认）时，落盘人工裁定，形成可追溯的分歧记录。
//
// 用法:
//   node tests/e2e-agent/feedback.mjs <logDir> <规则ID> <pass|fail> <理由...>
// 例:
//   node tests/e2e-agent/feedback.mjs logs/keyword-market-612-20260615-142239 C4 pass "用户在第12轮已确认，judge 漏看了"
//
// 效果:
//   1. <logDir>/overrides.json 追加一条人工裁定（同一 ID 多次裁定以最后一次为准）
//   2. 语义评判类规则（B/C 系列）自动沉淀校准用例到 judge-calibration/，
//      供 calibrate.mjs 在改 judge prompt / 换评判模型时回归验证
//   3. 重新生成 <logDir>/report.html，人工复核结论叠加显示在 judge 判定上

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { generateReport, parseTranscriptMd, isJudgedItem } from "./report-html.mjs";
export { isJudgedItem };

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const CALIBRATION_DIR = path.join(HERE, "judge-calibration");

function loadTranscript(logDir) {
  const tj = path.join(logDir, "transcript.json");
  const tm = path.join(logDir, "transcript.md");
  if (fs.existsSync(tj)) return JSON.parse(fs.readFileSync(tj, "utf8"));
  if (fs.existsSync(tm)) return parseTranscriptMd(fs.readFileSync(tm, "utf8"));
  return [];
}

export function recordOverride(logDir, id, humanPass, reason, calibrationDir = CALIBRATION_DIR) {
  const reportFile = path.join(logDir, "report.json");
  if (!fs.existsSync(reportFile)) throw new Error(`找不到 ${reportFile}（不是一个 run 日志目录？）`);
  const report = JSON.parse(fs.readFileSync(reportFile, "utf8"));
  const item = (report.items || []).find((i) => i.id === id);
  if (!item) {
    const ids = [...new Set((report.items || []).map((i) => i.id))].join(" ");
    throw new Error(`该 run 中没有判定项 ${id}，可用 ID: ${ids}`);
  }

  const override = {
    id,
    pass: humanPass,
    reason,
    judgePass: item.pass,
    overturned: humanPass !== item.pass,
    at: new Date().toISOString(),
  };
  const overridesFile = path.join(logDir, "overrides.json");
  const overrides = fs.existsSync(overridesFile)
    ? JSON.parse(fs.readFileSync(overridesFile, "utf8"))
    : [];
  overrides.push(override);
  fs.writeFileSync(overridesFile, JSON.stringify(overrides, null, 2));

  // 校准用例沉淀：对话 + 规则 + 人工标准答案，是以后回归 judge 的考题
  let caseFile = null;
  if (isJudgedItem(item)) {
    const transcript = loadTranscript(logDir);
    if (transcript.length) {
      fs.mkdirSync(calibrationDir, { recursive: true });
      const runBase = path.basename(path.resolve(logDir));
      caseFile = path.join(calibrationDir, `${runBase}--${id}.json`);
      fs.writeFileSync(
        caseFile,
        JSON.stringify(
          {
            scenario: report.scenario,
            run: runBase,
            rule: { id, rule: item.label },
            judge: { pass: item.pass, round: item.round ?? null, evidence: item.detail || "" },
            human: { pass: humanPass, reason, at: override.at },
            transcript,
          },
          null,
          2
        )
      );
    }
  }

  return { override, item, caseFile };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [logDirArg, id, verdict, ...reasonParts] = process.argv.slice(2);
  const reason = reasonParts.join(" ").trim();
  if (!logDirArg || !id || !["pass", "fail"].includes(verdict) || !reason) {
    console.error("用法: node feedback.mjs <logDir> <规则ID> <pass|fail> <理由>");
    console.error('例:  node feedback.mjs logs/xxx-20260615 C4 pass "用户在第12轮已确认，judge 漏看了"');
    process.exit(2);
  }
  const logDir = path.resolve(logDirArg);
  try {
    const { override, item, caseFile } = recordOverride(logDir, id, verdict === "pass", reason);
    const rel = override.overturned ? "推翻" : "确认";
    console.log(`✓ 已记录人工复核（${rel} judge 判定）: [${id}] judge=${item.pass ? "pass" : "fail"} → 人工=${verdict}`);
    console.log(`  理由: ${reason}`);
    console.log(`  裁定记录: ${path.join(logDir, "overrides.json")}`);
    if (caseFile) console.log(`  校准用例已沉淀: ${caseFile}`);
    else console.log(`  （硬断言或无对话记录，未生成 judge 校准用例）`);
    const html = generateReport(logDir);
    console.log(`  回放报告已更新: ${html}`);
  } catch (err) {
    console.error(`✗ ${err.message}`);
    process.exit(1);
  }
}
