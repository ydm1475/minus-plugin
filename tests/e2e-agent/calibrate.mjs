// calibrate.mjs — judge 校准回归
// 把 judge-calibration/ 里的人工裁定用例逐个重新交给 judge 评判，
// 对比 judge 结论与人工标准答案，输出一致率与分歧清单。
// 改 judge prompt / 换评判模型（E2E_JUDGE_MODEL）之前后各跑一遍，一致率不降才算改好。
//
// 用法:
//   node tests/e2e-agent/calibrate.mjs [casesDir]
//
// ⚠ 每个用例一次真实 judge 调用（消耗 token），用例多时注意成本。

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { judgeTranscript, formatTranscriptLines, verifyEvidence } from "./judge.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

export function loadCases(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => ({ file: f, ...JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")) }));
}

async function main() {
  const dir = path.resolve(process.argv[2] || path.join(HERE, "judge-calibration"));
  const cases = loadCases(dir);
  if (!cases.length) {
    console.log(`（${dir} 下没有校准用例——先用 feedback.mjs 记录几条人工复核）`);
    return;
  }
  console.log(`校准集: ${cases.length} 个用例（${dir}）`);
  console.log(`评判模型: ${process.env.E2E_JUDGE_MODEL || "sonnet"}\n`);

  let agree = 0;
  const disagreements = [];
  for (const c of cases) {
    const lines = formatTranscriptLines(c.transcript);
    let verdict;
    try {
      [verdict] = await judgeTranscript([c.rule], lines.join("\n\n"));
    } catch (err) {
      disagreements.push({ ...c, error: err.message });
      console.log(`  ✗ [${c.rule.id}] ${c.file} — 评判调用失败: ${err.message}`);
      continue;
    }
    const ok = verdict.pass === c.human.pass;
    const verified = verifyEvidence(verdict, lines);
    if (ok) {
      agree++;
      console.log(`  ✓ [${c.rule.id}] ${c.file} — judge=${verdict.pass ? "pass" : "fail"} 与人工一致（证据核验: ${verified}）`);
    } else {
      disagreements.push({ ...c, latest: verdict });
      console.log(`  ✗ [${c.rule.id}] ${c.file} — judge=${verdict.pass ? "pass" : "fail"}，人工=${c.human.pass ? "pass" : "fail"}`);
      console.log(`      人工理由: ${c.human.reason}`);
      console.log(`      judge 证据: ${String(verdict.evidence).slice(0, 150)}`);
    }
  }

  console.log(`\n一致率: ${agree}/${cases.length}`);
  if (disagreements.length) {
    console.log(`分歧 ${disagreements.length} 条——若同一规则反复分歧且方向一致，考虑改剧本里的规则措辞而非继续调 judge。`);
    process.exit(1);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err.stack || err.message);
    process.exit(1);
  });
}
