// judge.mjs — 行为规则评判（断言清单 B 系列）
// 把完整 transcript 交给评判模型，逐条判 pass/fail 并要求引用对话原文。

import { execFile } from "node:child_process";

const MODEL = process.env.E2E_JUDGE_MODEL || "sonnet";

export function buildJudgePrompt(rules, transcriptText) {
  const ruleLines = rules.map((r) => `- ${r.id}: ${r.rule}`).join("\n");
  return `你是测试评判员。下面是一段「Skill 开发助手 Agent」与「用户」的完整对话记录，请逐条评判 Agent 是否遵守了以下行为规则。

# 行为规则
${ruleLines}

# 评判要求
1. 每条规则独立判定 pass 或 fail，不确定时判 fail。
2. evidence 必须引用对话原文片段（fail 时引用违规处，pass 时引用关键证据）。
3. 只输出 JSON 数组，不要其他文字：
[{"id":"B1","pass":true,"evidence":"..."}]

# 对话记录
${transcriptText}`;
}

// 评判模型 evidence 引用对话原文时常带未转义引号，严格 JSON.parse 会整步失败。
// 降级路径：逐条正则提取 id/pass（判定结论不受影响，只丢 evidence 文本）。
function lenientVerdicts(output) {
  const found = [];
  const re = /"id"\s*:\s*"(\w+)"\s*,\s*"pass"\s*:\s*(true|false)/g;
  let m;
  while ((m = re.exec(output))) {
    found.push({ id: m[1], pass: m[2] === "true", evidence: "（评判 JSON 解析降级，evidence 略）" });
  }
  return found;
}

export function parseVerdicts(output, rules) {
  const m = output.match(/\[[\s\S]*\]/);
  if (!m) throw new Error(`评判输出中找不到 JSON 数组: ${output.slice(0, 300)}`);
  let arr;
  try {
    arr = JSON.parse(m[0]);
  } catch (e) {
    arr = lenientVerdicts(m[0]);
    if (!arr.length) throw new Error(`评判输出 JSON 解析失败且无法降级提取: ${e.message}`);
  }
  // 漏判的规则按 fail 处理，不允许静默缺项
  return rules.map((r) => {
    const v = arr.find((x) => x.id === r.id);
    return v
      ? { id: r.id, rule: r.rule, pass: !!v.pass, evidence: v.evidence || "" }
      : { id: r.id, rule: r.rule, pass: false, evidence: "（评判模型未返回该条结果）" };
  });
}

export function judgeTranscript(rules, transcriptText) {
  if (!rules.length) return Promise.resolve([]);
  const prompt = buildJudgePrompt(rules, transcriptText);
  return new Promise((resolve, reject) => {
    execFile(
      "claude",
      ["--print", "--model", MODEL, "--max-budget-usd", "2", prompt],
      { timeout: 300_000, maxBuffer: 8 * 1024 * 1024, env: process.env },
      (err, stdout, stderr) => {
        if (err) {
          reject(new Error(`评判调用失败: ${err.message}\n${stderr}`));
          return;
        }
        try {
          resolve(parseVerdicts(stdout, rules));
        } catch (e) {
          reject(e);
        }
      }
    );
  });
}
