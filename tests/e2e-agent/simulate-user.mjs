// simulate-user.mjs — LLM 模拟用户（Creator）
// 拿剧本 persona + answers 口径，针对 Agent 最新输出生成"用户会说的话"。

import { execFile } from "node:child_process";

const MODEL = process.env.E2E_SIM_MODEL || "haiku";

function flattenAnswers(answers) {
  const lines = [];
  const phaseNames = {
    structure: "结构设计阶段",
    result: "结果呈现设计阶段",
  };
  const dimNames = {
    input: "用户输入定义",
    steps: "步骤拆分",
    confirm_structure: "结构确认",
    data: "维度①数据需求",
    logic: "维度②处理逻辑",
    output: "维度③输出定义",
    confirm: "维度④用户确认",
    summary: "结果摘要",
    download: "下载内容",
  };
  for (const [phase, qa] of Object.entries(answers || {})) {
    const phaseName = phaseNames[phase] || `${phase} 节点开发`;
    for (const [k, v] of Object.entries(qa || {})) {
      lines.push(`- [${phaseName} / ${dimNames[k] || k}] ${v}`);
    }
  }
  return lines.join("\n");
}

const PHASE_LABELS = {
  structure: "结构设计阶段",
  result: "结果呈现设计阶段",
};

function phaseLabel(phase) {
  return PHASE_LABELS[phase] || `${phase} 节点开发`;
}

export function buildSimPrompt(scenario, agentText, currentPhase = null) {
  const phaseHint = currentPhase
    ? `\n# 当前进度\n现在处于【${phaseLabel(currentPhase)}】。只用该阶段的口径作答，禁止使用其他步骤/阶段的口径。\n`
    : "";
  return `你正在扮演一个使用 Minus 插件开发 Skill 的 Creator（用户），与开发助手 Agent 对话。

# 你的人设
${scenario.persona.trim()}
${phaseHint}
# 你的回答口径（按 Agent 当前问题选最匹配的一条作答，不要把多条口径合并到一次回答里）
${flattenAnswers(scenario.answers)}

# 规则
1. 只输出你作为用户要说的话，一到两句，中文口语，不要任何解释、前缀、引号。
2. 不要使用任何工具，不要扮演 Agent，不要替 Agent 推进流程。
3. Agent 的问题在口径中找不到对应时，回答"按你的推荐来"。
4. Agent 在汇报进展、没有提问时，回答"好的，继续"。
5. 绝不主动提出新需求或修改已确认的需求。

# Agent 刚才说
${agentText.slice(-4000)}

你的回答：`;
}

export function simulateUser(scenario, agentText, currentPhase = null) {
  const prompt = buildSimPrompt(scenario, agentText, currentPhase);
  return new Promise((resolve, reject) => {
    execFile(
      "claude",
      ["--print", "--model", MODEL, "--max-budget-usd", "0.2", prompt],
      { timeout: 120_000, maxBuffer: 1024 * 1024, env: process.env },
      (err, stdout, stderr) => {
        if (err) {
          reject(new Error(`模拟用户调用失败: ${err.message}\n${stderr}`));
          return;
        }
        const reply = stdout.trim();
        if (!reply) {
          reject(new Error("模拟用户返回空回复"));
          return;
        }
        resolve(reply);
      }
    );
  });
}
