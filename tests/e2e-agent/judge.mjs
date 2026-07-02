// judge.mjs — 行为规则评判（断言清单 B 系列）
// 把完整 transcript 交给评判模型，逐条判 pass/fail 并要求引用对话原文。
// 评判结论是语义的、无法直接机器验证；但"引用的原文是否真的说过"可以：
// verifyEvidence 把 evidence 逐字对回 transcript，未命中的判定标记 miss（需人工复核）。

import { execFile } from "node:child_process";

const MODEL = process.env.E2E_JUDGE_MODEL || "sonnet";

// 对话记录统一格式：带轮次号。评判 prompt 与证据核验必须用同一份文本，
// 否则评判引用的轮次/原文对不回来。
export function formatTranscriptLines(transcript) {
  return transcript.map(
    (t, i) => `【第${i + 1}轮 · ${t.role === "agent" ? "Agent" : "用户"}】${t.text}`
  );
}

export function buildJudgePrompt(rules, transcriptText) {
  const ruleLines = rules.map((r) => `- ${r.id}: ${r.rule}`).join("\n");
  return `你是测试评判员。下面是一段「Skill 开发助手 Agent」与「用户」的完整对话记录（每条消息带轮次号），请逐条评判 Agent 是否遵守了以下行为规则。

# 行为规则
${ruleLines}

# 评判要求
1. 每条规则独立判定 pass 或 fail，不确定时判 fail。
2. evidence 必须逐字摘抄对话原文片段（fail 时引用违规处，pass 时引用关键证据），不得改写、缩写或转述；多个片段之间用 … 分隔。
3. round 填 evidence 主要片段所在消息的轮次号（整数）。
4. 只输出 JSON 数组，不要其他文字：
[{"id":"B1","pass":true,"round":3,"evidence":"..."}]

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
    found.push({ id: m[1], pass: m[2] === "true", round: null, evidence: "（评判 JSON 解析降级，evidence 略）" });
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
    if (!v) return { id: r.id, rule: r.rule, pass: false, round: null, evidence: "（评判模型未返回该条结果）" };
    const round = Number.isInteger(v.round) ? v.round : null;
    return { id: r.id, rule: r.rule, pass: !!v.pass, round, evidence: v.evidence || "" };
  });
}

// 证据核验：把 evidence 逐字对回 transcript（去空白/引号后子串匹配）。
// 返回三态：
//   round      — 所有片段命中所标轮次（证据成立）
//   transcript — 片段在对话里说过，但不在所标轮次（结论可信，轮次标错）
//   miss       — 至少一个片段在整个对话里找不到（evidence 疑似编造，需人工复核）
const strip = (s) => String(s || "").replace(/[\s"'“”‘’「」『』]+/g, "");

export function verifyEvidence(verdict, lines) {
  const frags = String(verdict.evidence || "")
    .split(/…|⋯|\.{3}/)
    .map(strip)
    .filter((f) => f.length >= 6); // 太短的片段到处都能撞上，不构成证据
  if (!frags.length) return "miss";
  const roundLine =
    Number.isInteger(verdict.round) && verdict.round >= 1 && verdict.round <= lines.length
      ? strip(lines[verdict.round - 1])
      : null;
  if (roundLine && frags.every((f) => roundLine.includes(f))) return "round";
  const whole = strip(lines.join("\n"));
  if (frags.every((f) => whole.includes(f))) return "transcript";
  return "miss";
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
