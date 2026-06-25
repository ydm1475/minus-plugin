#!/usr/bin/env node
// restructure.cjs — 步骤结构变更的原子操作模块
// 用法: node restructure.cjs <insert|delete|append|swap|generate> [args]
//
// 每个操作声明自己需要读写哪些数据源，执行器根据声明动态组合：
// 读声明的数据源 → 执行操作 → 校验一致性（如声明） → 写回

'use strict';
const fs = require('fs');
const path = require('path');

// ── 数据源读写 ──

const PROGRESS_FILE = path.join('.minus', 'progress.json');
const TOTAL_STEPS_FILE = path.join('.minus', 'total-steps');
const DEV_DIR = path.join('.minus', 'dev-progress');
const PIPELINE_FILE = 'pipeline.py';
const FRONTEND_FILE = path.join('frontend', 'src', 'main.tsx');

function readPipeline() {
  return fs.readFileSync(PIPELINE_FILE, 'utf8');
}

function writePipeline(code) {
  fs.writeFileSync(PIPELINE_FILE, code);
}

function readFrontend() {
  if (!fs.existsSync(FRONTEND_FILE)) return null;
  return fs.readFileSync(FRONTEND_FILE, 'utf8');
}

function writeFrontend(code) {
  if (code === null) return;
  fs.writeFileSync(FRONTEND_FILE, code);
}

function readProgress() {
  try {
    return JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'));
  } catch (e) {
    return { currentStep: 0, steps: {} };
  }
}

function writeProgress(p) {
  p.updatedAt = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  fs.mkdirSync(path.dirname(PROGRESS_FILE), { recursive: true });
  fs.writeFileSync(PROGRESS_FILE, JSON.stringify(p, null, 2) + '\n');
}

function readTotalSteps() {
  if (fs.existsSync(TOTAL_STEPS_FILE)) {
    return Number(fs.readFileSync(TOTAL_STEPS_FILE, 'utf8').trim());
  }
  if (fs.existsSync(PIPELINE_FILE)) {
    const code = fs.readFileSync(PIPELINE_FILE, 'utf8');
    return (code.match(/async def step_\d+/g) || []).length;
  }
  return 0;
}

function writeTotalSteps(n) {
  fs.writeFileSync(TOTAL_STEPS_FILE, String(n));
}

function readStepNames() {
  const names = {};
  if (!fs.existsSync(DEV_DIR)) return names;
  const files = fs.readdirSync(DEV_DIR).filter(function(f) { return /^step_\d+_name$/.test(f); });
  for (var i = 0; i < files.length; i++) {
    var f = files[i];
    var n = Number(f.match(/^step_(\d+)_name$/)[1]);
    names[n] = fs.readFileSync(path.join(DEV_DIR, f), 'utf8');
  }
  return names;
}

function writeStepNames(names) {
  fs.mkdirSync(DEV_DIR, { recursive: true });
  // 先删除旧的 step_N_name 文件
  if (fs.existsSync(DEV_DIR)) {
    var existing = fs.readdirSync(DEV_DIR).filter(function(f) { return /^step_\d+_name$/.test(f); });
    for (var i = 0; i < existing.length; i++) {
      fs.unlinkSync(path.join(DEV_DIR, existing[i]));
    }
  }
  var keys = Object.keys(names);
  for (var j = 0; j < keys.length; j++) {
    var n = keys[j];
    fs.writeFileSync(path.join(DEV_DIR, 'step_' + n + '_name'), names[n]);
  }
}

const SOURCES = {
  pipeline:   { read: readPipeline,   write: writePipeline },
  frontend:   { read: readFrontend,   write: writeFrontend },
  progress:   { read: readProgress,   write: writeProgress },
  totalSteps: { read: readTotalSteps, write: writeTotalSteps },
  stepNames:  { read: readStepNames,  write: writeStepNames },
};

// ── 一致性校验 ──

function countPipelineMethods(code) {
  return (code.match(/async def step_\d+/g) || []).length;
}

function countBuildStepItems(code) {
  if (!code) return null;
  var fnStart = code.indexOf('function buildSteps');
  if (fnStart === -1) return null;
  var returnIdx = code.indexOf('return [', fnStart);
  if (returnIdx === -1) return null;
  var arrStart = code.indexOf('[', returnIdx);
  var depth = 1, count = 0;
  var inString = false, strChar = '';
  for (var i = arrStart + 1; i < code.length; i++) {
    var ch = code[i];
    if (inString) {
      if (ch === '\\') { i++; continue; }
      if (ch === strChar) inString = false;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') { inString = true; strChar = ch; continue; }
    if (ch === '{' && depth === 1) count++;
    if (ch === '[' || ch === '{' || ch === '(') depth++;
    if (ch === ']' || ch === '}' || ch === ')') {
      depth--;
      if (depth === 0) break;
    }
  }
  return count;
}

function validateConsistency(result) {
  var total = result.totalSteps;
  var errors = [];

  if (result.pipeline !== undefined) {
    var pCount = countPipelineMethods(result.pipeline);
    if (pCount !== total) errors.push('pipeline.py: ' + pCount + ' 个方法，期望 ' + total);
  }

  if (result.frontend !== undefined && result.frontend !== null) {
    var fCount = countBuildStepItems(result.frontend);
    if (fCount !== null && fCount !== total) errors.push('main.tsx: ' + fCount + ' 个渲染项，期望 ' + total);
  }

  if (result.progress !== undefined) {
    var pKeys = Object.keys(result.progress.steps || {}).length;
    if (pKeys !== total) errors.push('progress.json: ' + pKeys + ' 个步骤，期望 ' + total);
  }

  if (errors.length > 0) {
    console.error('错误：一致性校验失败，不写入任何文件');
    for (var i = 0; i < errors.length; i++) console.error('  - ' + errors[i]);
    process.exit(1);
  }
}

// ── 操作注册表 ──

const ops = {};

// ── 执行器 ──

function execute(opName, args) {
  var op = ops[opName];
  if (!op) {
    console.error('错误：未知操作 "' + opName + '"，支持 ' + Object.keys(ops).join(' / '));
    process.exit(1);
  }

  var sources = {};
  for (var i = 0; i < op.reads.length; i++) {
    var key = op.reads[i];
    sources[key] = SOURCES[key].read();
  }

  var result = op.run.apply(null, [sources].concat(args));

  if (op.validate) validateConsistency(result);

  for (var j = 0; j < op.writes.length; j++) {
    var wkey = op.writes[j];
    if (result[wkey] !== undefined) SOURCES[wkey].write(result[wkey]);
  }

  return result;
}

// ── CLI ──

if (require.main === module) {
  if (!fs.existsSync(path.join('.minus', 'skill.json'))) {
    console.error('错误：未找到 .minus/skill.json，不在 Minus Skill 项目目录中');
    process.exit(1);
  }

  var argv = process.argv.slice(2);
  var opName = argv[0];
  var args = argv.slice(1);
  if (!opName) {
    console.error('用法: node restructure.cjs <' + Object.keys(ops).join('|') + '> [args]');
    process.exit(1);
  }

  execute(opName, args);
}

module.exports = { execute: execute, ops: ops, SOURCES: SOURCES, validateConsistency: validateConsistency, countPipelineMethods: countPipelineMethods, countBuildStepItems: countBuildStepItems };
