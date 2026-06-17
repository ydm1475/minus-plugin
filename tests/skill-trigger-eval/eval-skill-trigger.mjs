#!/usr/bin/env node

import { readFileSync, writeFileSync, readdirSync, existsSync } from 'fs';
import { execFileSync } from 'child_process';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { parseArgs } from 'util';

const __dirname = dirname(fileURLToPath(import.meta.url));
const EMPTY_SETTINGS = '/tmp/eval-empty-settings.json';
if (!existsSync(EMPTY_SETTINGS)) writeFileSync(EMPTY_SETTINGS, '{}');
const SKILLS_DIR = join(__dirname, '..', '..', 'plugins', 'claude', 'minus-creator', 'skills');

// --- CLI args ---
const { values: args } = parseArgs({
  options: {
    skill:   { type: 'string', short: 's' },
    samples: { type: 'string', short: 'n', default: '5' },
    model:   { type: 'string', short: 'm', default: 'haiku' },
    cases:   { type: 'string', short: 'c' },
  },
  strict: false,
});
const SAMPLES = parseInt(args.samples, 10);
const MODEL = args.model;

// --- Parse SKILL.md frontmatter ---
function parseSkillMeta(skillDir) {
  const content = readFileSync(join(SKILLS_DIR, skillDir, 'SKILL.md'), 'utf-8');
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return null;
  const yaml = match[1];
  const get = (key) => {
    const m = yaml.match(new RegExp(`^${key}:\\s*>?\\s*\\n((?:  .+\\n?)+)`, 'm'));
    if (m) return m[1].replace(/^  /gm, '').trim().replace(/\n/g, ' ');
    const m2 = yaml.match(new RegExp(`^${key}:\\s*(.+)`, 'm'));
    return m2 ? m2[1].trim() : '';
  };
  return { name: get('name'), description: get('description'), when_to_use: get('when_to_use') };
}

const SKILL_NAMES = readdirSync(SKILLS_DIR).filter(d => {
  try { readFileSync(join(SKILLS_DIR, d, 'SKILL.md')); return true; } catch { return false; }
});
const SKILLS = SKILL_NAMES.map(parseSkillMeta).filter(Boolean);

// --- Fisher-Yates shuffle ---
function shuffle(arr) {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

// --- Build system prompt ---
function buildSystemPrompt(skills) {
  const list = skills.map(s => {
    const when = s.when_to_use ? ` - ${s.when_to_use}` : '';
    return `- ${s.name}: ${s.description}${when}`;
  }).join('\n');
  return `You are Claude Code. The following skills are available for use with the Skill tool:

${list}

Given the user message and environment context below, respond with ONLY the skill name to invoke (e.g. "minus-step"), or "none" if no skill matches. No explanation, no punctuation, just the skill name or "none".`;
}

// --- Build user message with context ---
function buildUserMessage(input, context) {
  const inProject = context.in_project !== false;
  const loggedIn = context.logged_in !== false;
  const envLine = `\n\n[环境] 当前目录：${inProject ? 'Minus 项目（.minus/skill.json 存在）' : '非 Minus 项目目录'}；登录状态：${loggedIn ? '已登录' : '未登录'}`;
  return input + envLine;
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const MAX_RETRIES = 2;
const RETRY_DELAY = 2000;
const CALL_DELAY = 500;

function callClaudeOnce(systemPrompt, userMessage) {
  const result = execFileSync('/Users/tutu/.local/bin/claude', [
    '-p', '--disable-slash-commands', '--settings', EMPTY_SETTINGS,
    '--model', MODEL, '--system-prompt', systemPrompt, userMessage
  ], { encoding: 'utf-8', timeout: 60000, stdio: ['pipe', 'pipe', 'pipe'] });
  const raw = result.trim().toLowerCase();
  if (process.env.DEBUG) console.log(`\n  [DEBUG] raw="${raw}"`);
  const validNames = SKILLS.map(s => s.name).concat(['none']);
  for (const name of validNames) {
    if (raw === name) return name;
  }
  for (const name of [...validNames].sort((a, b) => b.length - a.length)) {
    if (raw.includes(name)) return name;
  }
  return raw.length < 30 ? raw : 'parse-error';
}

function callClaude(systemPrompt, userMessage) {
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    try {
      return callClaudeOnce(systemPrompt, userMessage);
    } catch (e) {
      if (attempt < MAX_RETRIES) {
        if (process.env.DEBUG) console.log(`\n  [RETRY] attempt ${attempt + 1} failed, waiting ${RETRY_DELAY}ms...`);
        execFileSync('sleep', [String(RETRY_DELAY / 1000)]);
      }
    }
  }
  return 'error';
}

// --- Load test cases ---
const casesFile = args.cases || join(__dirname, 'eval-skill-cases.json');
const allCases = JSON.parse(readFileSync(casesFile, 'utf-8')).cases;
const cases = args.skill
  ? allCases.filter(c => c.expected === args.skill || c.id.startsWith(args.skill))
  : allCases;

console.log(`\n🔬 Eval: ${cases.length} cases × ${SAMPLES} samples = ${cases.length * SAMPLES} calls (model: ${MODEL})\n`);

// --- Run eval ---
const results = [];
for (let i = 0; i < cases.length; i++) {
  const tc = cases[i];
  const responses = [];
  process.stdout.write(`[${i + 1}/${cases.length}] ${tc.id}: `);

  for (let s = 0; s < SAMPLES; s++) {
    const shuffled = shuffle(SKILLS);
    const sysPrompt = buildSystemPrompt(shuffled);
    const userMsg = buildUserMessage(tc.input, tc.context || {});
    const resp = callClaude(sysPrompt, userMsg);
    responses.push(resp);
    process.stdout.write(resp === tc.expected || (tc.acceptable && tc.acceptable.includes(resp)) ? '✓' : '✗');
    if (s < SAMPLES - 1) execFileSync('sleep', [String(CALL_DELAY / 1000)]);
  }

  const isCorrect = (r) => r === tc.expected || (tc.acceptable && tc.acceptable.includes(r));
  const correctCount = responses.filter(isCorrect).length;
  const accuracy = correctCount / SAMPLES;
  const pass = accuracy >= 0.8;

  results.push({ ...tc, responses, accuracy, pass });
  console.log(` ${(accuracy * 100).toFixed(0)}%${pass ? '' : ' ⚠️'}`);
}

// --- Per-skill recall ---
console.log('\n═══ Per-skill Recall ═══\n');
const byExpected = {};
for (const r of results) {
  const key = r.expected;
  if (!byExpected[key]) byExpected[key] = { total: 0, pass: 0 };
  byExpected[key].total++;
  if (r.pass) byExpected[key].pass++;
}
for (const [skill, stats] of Object.entries(byExpected).sort((a, b) => a[0].localeCompare(b[0]))) {
  const pct = (stats.pass / stats.total * 100).toFixed(0);
  const bar = '█'.repeat(Math.round(stats.pass / stats.total * 20));
  console.log(`  ${skill.padEnd(18)} ${stats.pass}/${stats.total} (${pct}%) ${bar}`);
}

// --- Confusion matrix (majority vote) ---
console.log('\n═══ Confusion Matrix (majority vote) ═══\n');
const labels = [...new Set(results.flatMap(r => [r.expected, ...r.responses]))].sort();
const matrix = {};
for (const l of labels) { matrix[l] = {}; for (const l2 of labels) matrix[l][l2] = 0; }

for (const r of results) {
  const counts = {};
  for (const resp of r.responses) counts[resp] = (counts[resp] || 0) + 1;
  const majority = Object.entries(counts).sort((a, b) => b[1] - a[1])[0][0];
  if (matrix[r.expected] && matrix[r.expected][majority] !== undefined) {
    matrix[r.expected][majority]++;
  }
}

const header = ''.padEnd(18) + labels.map(l => l.slice(0, 8).padStart(9)).join('');
console.log(header);
for (const row of labels) {
  const cells = labels.map(col => {
    const v = (matrix[row] && matrix[row][col]) || 0;
    return (v > 0 ? String(v) : '·').padStart(9);
  }).join('');
  console.log(`  ${row.padEnd(16)}${cells}`);
}

// --- Problem cases ---
const problems = results.filter(r => !r.pass);
if (problems.length > 0) {
  console.log(`\n═══ Problem Cases (${problems.length}) ═══\n`);
  for (const p of problems) {
    const counts = {};
    for (const r of p.responses) counts[r] = (counts[r] || 0) + 1;
    const dist = Object.entries(counts).map(([k, v]) => `${k}:${v}`).join(' ');
    console.log(`  ⚠️  ${p.id}`);
    console.log(`      input:    "${p.input}"`);
    console.log(`      expected: ${p.expected}${p.acceptable ? ` (also ok: ${p.acceptable.join(', ')})` : ''}`);
    console.log(`      got:      ${dist}`);
    console.log('');
  }
} else {
  console.log('\n✅ All cases passed!\n');
}

// --- Summary ---
const totalPass = results.filter(r => r.pass).length;
const totalErrors = results.reduce((sum, r) => sum + r.responses.filter(x => x === 'error').length, 0);
const totalCalls = results.reduce((sum, r) => sum + r.responses.length, 0);
console.log(`═══ Summary: ${totalPass}/${results.length} passed (${(totalPass / results.length * 100).toFixed(0)}%) | errors: ${totalErrors}/${totalCalls} (${(totalErrors / totalCalls * 100).toFixed(1)}%) ═══\n`);

// --- Save results ---
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const outFile = join(__dirname, `eval-results-${timestamp}.jsonl`);
for (const r of results) {
  writeFileSync(outFile, JSON.stringify({
    case_id: r.id, input: r.input, expected: r.expected,
    acceptable: r.acceptable || null, responses: r.responses,
    accuracy: r.accuracy, pass: r.pass
  }) + '\n', { flag: 'a' });
}
console.log(`Results saved to ${outFile}`);
