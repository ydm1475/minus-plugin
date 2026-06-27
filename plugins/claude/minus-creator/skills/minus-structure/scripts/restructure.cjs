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
  var fnBody = code.slice(fnStart);
  var closeIdx = fnBody.indexOf('\n}');
  if (closeIdx !== -1) fnBody = fnBody.slice(0, closeIdx);
  return (fnBody.match(/\brender\s*:/g) || []).length;
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

// ── pipeline.py 工具函数 ──

function escPy(s) {
  return (s || '').replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
}

function pipelineSkeleton(pos, name) {
  return '\n    async def step_' + pos + '(self, ctx: PipelineContext) -> StepOutcome:\n' +
    '        # TODO: 实现「' + escPy(name) + '」的逻辑\n' +
    '        return StepOutcome.complete(payload={"text": "' + escPy(name) + '完成"})\n';
}

function renumberPipeline(code, from, to) {
  var f = String(from), t = String(to);
  code = code.replace(new RegExp('(async def step_)' + f + '(?=\\()', 'g'), '$1' + t);
  code = code.replace(new RegExp('(ctx\\.previous_outputs\\.get\\()' + f + '(?=[,\\)])', 'g'), '$1' + t);
  code = code.replace(new RegExp('(ctx\\.step_payload\\()' + f + '(?=[,\\)])', 'g'), '$1' + t);
  return code;
}

function insertPipelineSkeleton(code, pos, total, name) {
  for (var i = total; i >= pos; i--) {
    code = renumberPipeline(code, i, i + 1);
  }
  var skeleton = pipelineSkeleton(pos, name);
  var marker = 'async def step_' + (pos + 1) + '(';
  var idx = code.indexOf(marker);
  if (idx !== -1) {
    var lineStart = code.lastIndexOf('\n', idx);
    code = code.slice(0, lineStart) + skeleton + code.slice(lineStart);
  } else {
    code = code + skeleton;
  }
  return code;
}

function deletePipelineMethod(code, pos, total) {
  var methodStart = code.indexOf('\n    async def step_' + pos + '(');
  if (methodStart !== -1) {
    var searchAfter = methodStart + 1;
    var nextBoundary = code.slice(searchAfter).search(/\n(    (async def |def )|[^ \t\n])/);
    var methodEnd = nextBoundary !== -1 ? searchAfter + nextBoundary : code.length;
    var trailing = code.slice(methodEnd);
    if (trailing.trim().length === 0) {
      code = code.slice(0, methodStart);
    } else {
      code = code.slice(0, methodStart) + code.slice(methodEnd);
    }
  }
  for (var i = pos + 1; i <= total; i++) {
    code = renumberPipeline(code, i, i - 1);
  }
  return code;
}

function extractPipelineMethod(code, pos) {
  var methodStart = code.indexOf('\n    async def step_' + pos + '(');
  if (methodStart === -1) return null;
  var searchAfter = methodStart + 1;
  var nextBoundary = code.slice(searchAfter).search(/\n(    (async def |def )|[^ \t\n])/);
  var methodEnd = nextBoundary !== -1 ? searchAfter + nextBoundary : code.length;
  return code.slice(methodStart, methodEnd);
}

// ── main.tsx 工具函数 ──

function escJsx(s) {
  return (s || '').replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/</g, '&lt;').replace(/[{}]/g, function(c) { return '&#' + c.charCodeAt(0) + ';'; });
}

function findStepMarkerRange(code, n) {
  var marker = '// __STEP_' + n + '__';
  var mIdx = code.indexOf(marker);
  if (mIdx === -1) return null;
  var lineStart = code.lastIndexOf('\n', mIdx);
  var start = lineStart === -1 ? 0 : lineStart + 1;
  var nextMarker = code.indexOf('// __STEP_', mIdx + marker.length);
  var end;
  if (nextMarker !== -1) {
    var nl = code.lastIndexOf('\n', nextMarker);
    end = nl === -1 ? nextMarker : nl + 1;
  } else {
    var closeBracket = code.indexOf('];', mIdx);
    if (closeBracket === -1) return null;
    var nl2 = code.lastIndexOf('\n', closeBracket);
    end = nl2 === -1 ? closeBracket : nl2 + 1;
  }
  return { start: start, end: end };
}

function buildStepEntry(name, stepNum) {
  return '    // __STEP_' + stepNum + '__\n' +
    '    {\n' +
    '      render: ({ data }) => (\n' +
    "        <div style={{ marginTop: 24, padding: '32px 24px', borderRadius: 12, background: 'var(--minus-step-bg, #f9fafb)', border: '1px solid var(--minus-step-border, #e5e7eb)', textAlign: 'center', fontSize: 18, fontWeight: 600 }}>\n" +
    "          {(data.text as string) ?? '" + escJsx(name) + "'}\n" +
    '        </div>\n' +
    '      ),\n' +
    '    },\n';
}

function renumberStepMarkers(code, from, delta) {
  if (delta > 0) {
    for (var i = 99; i >= from; i--) {
      code = code.replace('// __STEP_' + i + '__', '// __STEP_' + (i + delta) + '__');
    }
  } else {
    for (var j = from; j <= 99; j++) {
      var old = '// __STEP_' + j + '__';
      if (code.indexOf(old) === -1) break;
      code = code.replace(old, '// __STEP_' + (j + delta) + '__');
    }
  }
  return code;
}

function ensureStepMarkers(code) {
  if (/\/\/ __STEP_\d+__/.test(code)) return code;
  var fnStart = code.indexOf('function buildSteps');
  if (fnStart === -1) return code;
  var returnIdx = code.indexOf('return [', fnStart);
  if (returnIdx === -1) return code;
  var lines = code.split('\n');
  var returnLine = code.slice(0, returnIdx).split('\n').length - 1;
  var stepNum = 0;
  for (var i = returnLine + 1; i < lines.length; i++) {
    var line = lines[i];
    if (/\brender\s*:/.test(line)) {
      stepNum++;
      var objLine = i;
      if (i > 0 && /^\s+\{$/.test(lines[i - 1])) objLine = i - 1;
      lines.splice(objLine, 0, '    // __STEP_' + stepNum + '__');
      i++;
    }
    if (/^\s*\];/.test(line)) break;
  }
  return lines.join('\n');
}

function insertBuildStep(code, pos, name) {
  code = ensureStepMarkers(code);
  code = renumberStepMarkers(code, pos, 1);
  var newEntry = buildStepEntry(name, pos);
  var nextMarker = code.indexOf('// __STEP_' + (pos + 1) + '__');
  if (nextMarker !== -1) {
    var lineStart = code.lastIndexOf('\n', nextMarker);
    code = code.slice(0, lineStart + 1) + newEntry + code.slice(lineStart + 1);
  } else {
    var closeBracket = code.indexOf('];', code.indexOf('function buildSteps'));
    if (closeBracket !== -1) {
      var insertPoint = code.lastIndexOf('\n', closeBracket);
      code = code.slice(0, insertPoint + 1) + newEntry + code.slice(insertPoint + 1);
    }
  }
  return code;
}

function deleteBuildStep(code, pos) {
  code = ensureStepMarkers(code);
  var range = findStepMarkerRange(code, pos);
  if (!range) return code;
  code = code.slice(0, range.start) + code.slice(range.end);
  code = renumberStepMarkers(code, pos + 1, -1);
  return code;
}

function extractBuildStep(code, pos) {
  code = ensureStepMarkers(code);
  var range = findStepMarkerRange(code, pos);
  if (!range) return null;
  return code.slice(range.start, range.end);
}

// ── 操作注册表 ──

const ops = {};

ops.insert = {
  reads: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  validate: true,
  run: function(sources, posStr, name) {
    var pos = Number(posStr);
    var total = sources.totalSteps;
    var newTotal = total + 1;

    if (!name) { console.error('用法: restructure.cjs insert <位置N> <步骤名称>'); process.exit(1); }
    if (pos < 1 || pos > total + 1) { console.error('错误：插入位置 ' + pos + ' 超出范围（1 ~ ' + (total + 1) + '）'); process.exit(1); }
    if (sources.frontend === null) { console.error('错误：未找到 ' + FRONTEND_FILE + '，结构变更需要 main.tsx 存在'); process.exit(1); }

    var pipeline = insertPipelineSkeleton(sources.pipeline, pos, total, name);
    var frontend = insertBuildStep(sources.frontend, pos, name);

    var p = sources.progress;
    p.steps = p.steps || {};
    var max = Math.max.apply(null, [0].concat(Object.keys(p.steps).map(Number)));
    for (var i = max; i >= pos; i--) {
      p.steps[String(i + 1)] = p.steps[String(i)];
    }
    p.steps[String(pos)] = { name: name, status: 'pending' };
    if (p.currentStep >= pos) p.currentStep = p.currentStep + 1;

    var stepNames = {};
    var snKeys = Object.keys(sources.stepNames);
    for (var si = 0; si < snKeys.length; si++) {
      var sn = Number(snKeys[si]);
      stepNames[sn >= pos ? sn + 1 : sn] = sources.stepNames[snKeys[si]];
    }
    stepNames[pos] = name;

    console.log('✓ 已在位置 ' + pos + ' 插入步骤「' + name + '」，总步骤数 ' + total + ' → ' + newTotal);
    return { pipeline: pipeline, frontend: frontend, progress: p, totalSteps: newTotal, stepNames: stepNames };
  },
};

ops.delete = {
  reads: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  validate: true,
  run: function(sources, posStr) {
    var pos = Number(posStr);
    var total = sources.totalSteps;
    var newTotal = total - 1;

    if (pos < 1 || pos > total) { console.error('错误：步骤 ' + pos + ' 不存在（当前共 ' + total + ' 步）'); process.exit(1); }
    if (newTotal < 1) { console.error('错误：只剩一个步骤，不能删除'); process.exit(1); }
    if (sources.frontend === null) { console.error('错误：未找到 ' + FRONTEND_FILE + '，结构变更需要 main.tsx 存在'); process.exit(1); }

    var pipeline = deletePipelineMethod(sources.pipeline, pos, total);
    var frontend = deleteBuildStep(sources.frontend, pos);

    var p = sources.progress;
    p.steps = p.steps || {};
    var max = Math.max.apply(null, [0].concat(Object.keys(p.steps).map(Number)));
    for (var i = pos; i < max; i++) {
      p.steps[String(i)] = p.steps[String(i + 1)];
    }
    delete p.steps[String(max)];

    if (p.currentStep > pos) {
      p.currentStep = p.currentStep - 1;
    } else if (p.currentStep === pos) {
      if (p.currentStep > newTotal) p.currentStep = newTotal;
      var step = p.steps[String(p.currentStep)];
      if (step && step.status !== 'completed') step.status = 'in_progress';
    }

    var stepNames = {};
    var snKeys2 = Object.keys(sources.stepNames);
    for (var si2 = 0; si2 < snKeys2.length; si2++) {
      var sn2 = Number(snKeys2[si2]);
      if (sn2 === pos) continue;
      stepNames[sn2 > pos ? sn2 - 1 : sn2] = sources.stepNames[snKeys2[si2]];
    }

    console.log('✓ 已删除步骤 ' + pos + '，总步骤数 ' + total + ' → ' + newTotal);
    return { pipeline: pipeline, frontend: frontend, progress: p, totalSteps: newTotal, stepNames: stepNames };
  },
};

ops.append = {
  reads: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  validate: true,
  run: function(sources) {
    var names = Array.prototype.slice.call(arguments, 1);
    if (names.length === 0) { console.error('用法: restructure.cjs append <步骤名称> ...'); process.exit(1); }

    var pipeline = sources.pipeline;
    var frontend = sources.frontend;
    var total = sources.totalSteps;
    var newTotal = total + names.length;
    var p = sources.progress;
    p.steps = p.steps || {};
    var stepNames = {};
    var snKeys3 = Object.keys(sources.stepNames);
    for (var si3 = 0; si3 < snKeys3.length; si3++) {
      stepNames[snKeys3[si3]] = sources.stepNames[snKeys3[si3]];
    }

    if (frontend === null) { console.error('⚠ 未找到 ' + FRONTEND_FILE + '，仅更新 pipeline.py'); }

    for (var i = 0; i < names.length; i++) {
      var name = names[i];
      var stepNum = total + i + 1;
      pipeline += pipelineSkeleton(stepNum, name);
      if (frontend !== null) frontend = insertBuildStep(frontend, stepNum, name);
      p.steps[String(stepNum)] = { name: name, status: 'pending' };
      stepNames[stepNum] = name;
    }

    console.log('✓ 追加了 ' + names.length + ' 个步骤，总步骤数 ' + total + ' → ' + newTotal);
    return { pipeline: pipeline, frontend: frontend, progress: p, totalSteps: newTotal, stepNames: stepNames };
  },
};

ops.swap = {
  reads: ['pipeline', 'frontend', 'progress', 'stepNames', 'totalSteps'],
  writes: ['pipeline', 'frontend', 'progress', 'stepNames'],
  validate: true,
  run: function(sources, aStr, bStr) {
    var a = Number(aStr), b = Number(bStr);
    if (!a || !b || a === b) { console.error('用法: restructure.cjs swap <A> <B>'); process.exit(1); }
    var pipeline = sources.pipeline;
    var frontend = sources.frontend;
    var p = sources.progress;

    var bodyA = extractPipelineMethod(pipeline, a);
    var bodyB = extractPipelineMethod(pipeline, b);
    if (bodyA && bodyB) {
      var defNlA = bodyA.indexOf('\n', 1);
      var defNlB = bodyB.indexOf('\n', 1);
      var defLineA = bodyA.slice(0, defNlA);
      var defLineB = bodyB.slice(0, defNlB);
      var bodyOnlyA = bodyA.slice(defNlA);
      var bodyOnlyB = bodyB.slice(defNlB);
      var markerA = 'async def step_' + a + '(';
      var markerB = 'async def step_' + b + '(';
      var mA = pipeline.indexOf(markerA);
      var mB = pipeline.indexOf(markerB);
      if (mA !== -1 && mB !== -1) {
        var posA = pipeline.lastIndexOf('\n', mA);
        var posB = pipeline.lastIndexOf('\n', mB);
        // 确保先替换靠后的位置，避免偏移
        var lo, hi, loBody, hiBody;
        if (posA < posB) {
          lo = posA; hi = posB; loBody = bodyA; hiBody = bodyB;
        } else {
          lo = posB; hi = posA; loBody = bodyB; hiBody = bodyA;
        }
        // 交换：保留各自的 def 行（含步骤号），交换方法体
        var loDefLine = loBody.slice(0, loBody.indexOf('\n', 1));
        var hiDefLine = hiBody.slice(0, hiBody.indexOf('\n', 1));
        var loBodyOnly = loBody.slice(loBody.indexOf('\n', 1));
        var hiBodyOnly = hiBody.slice(hiBody.indexOf('\n', 1));
        pipeline = pipeline.slice(0, hi) + hiDefLine + loBodyOnly + pipeline.slice(hi + hiBody.length);
        pipeline = pipeline.slice(0, lo) + loDefLine + hiBodyOnly + pipeline.slice(lo + loBody.length);
      }
    }

    if (frontend !== null) {
      frontend = ensureStepMarkers(frontend);
      var rangeA = findStepMarkerRange(frontend, a);
      var rangeB = findStepMarkerRange(frontend, b);
      if (rangeA && rangeB) {
        var contentA = frontend.slice(rangeA.start, rangeA.end);
        var contentB = frontend.slice(rangeB.start, rangeB.end);
        // 交换内容但保留标记编号（标记标位置不标内容）
        var toA = contentB.replace('// __STEP_' + b + '__', '// __STEP_' + a + '__');
        var toB = contentA.replace('// __STEP_' + a + '__', '// __STEP_' + b + '__');
        // 先替换靠后的位置
        var early, late, earlyNew, lateNew;
        if (rangeA.start < rangeB.start) {
          early = rangeA; late = rangeB; earlyNew = toA; lateNew = toB;
        } else {
          early = rangeB; late = rangeA; earlyNew = toB; lateNew = toA;
        }
        frontend = frontend.slice(0, late.start) + lateNew + frontend.slice(late.end);
        frontend = frontend.slice(0, early.start) + earlyNew + frontend.slice(early.end);
      }
    }

    var tmp = p.steps[String(a)];
    p.steps[String(a)] = p.steps[String(b)] || { name: '步骤' + a, status: 'pending' };
    p.steps[String(b)] = tmp || { name: '步骤' + b, status: 'pending' };

    var stepNames = {};
    var snKeys = Object.keys(sources.stepNames);
    for (var i = 0; i < snKeys.length; i++) {
      stepNames[snKeys[i]] = sources.stepNames[snKeys[i]];
    }
    var tmpName = stepNames[a];
    stepNames[a] = stepNames[b];
    stepNames[b] = tmpName;

    console.log('✓ 步骤 ' + a + ' 和步骤 ' + b + ' 已交换');
    return { pipeline: pipeline, frontend: frontend, progress: p, stepNames: stepNames, totalSteps: sources.totalSteps };
  },
};

ops.generate = {
  reads: ['pipeline', 'frontend'],
  writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  validate: true,
  run: function(sources) {
    var names = Array.prototype.slice.call(arguments, 1);
    if (names.length === 0) { console.error('用法: restructure.cjs generate <步骤名称> ...'); process.exit(1); }

    var classMatch = sources.pipeline.match(/class\s+(\w+)\(Pipeline\)/);
    var className = classMatch ? classMatch[1] : 'SkillPipeline';

    var pipeline = 'from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome\n\n\n' +
      'class ' + className + '(Pipeline):\n';
    for (var i = 0; i < names.length; i++) {
      var name = names[i];
      pipeline += pipelineSkeleton(i + 1, name);
    }

    var frontend = sources.frontend;
    if (frontend !== null) {
      var stepsCode = '';
      for (var j = 0; j < names.length; j++) {
        stepsCode += buildStepEntry(names[j], j + 1);
      }
      var pattern = /(function buildSteps\([^)]*\)[^{]*\{[\s\S]*?return\s*\[)([\s\S]*?)(\];\s*\n\})/m;
      var match = frontend.match(pattern);
      if (match) {
        frontend = frontend.replace(pattern, match[1] + '\n' + stepsCode + '  ' + match[3]);
      }
    }

    var steps = {};
    var stepNames = {};
    for (var k = 0; k < names.length; k++) {
      steps[String(k + 1)] = { name: names[k], status: k === 0 ? 'in_progress' : 'pending' };
      stepNames[k + 1] = names[k];
    }
    var progress = { currentStep: 1, steps: steps, phase: 'developing' };

    console.log('✓ 已生成 ' + names.length + ' 个步骤');
    return { pipeline: pipeline, frontend: frontend, progress: progress, totalSteps: names.length, stepNames: stepNames };
  },
};

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

module.exports = {
  execute: execute, ops: ops, SOURCES: SOURCES, validateConsistency: validateConsistency,
  countPipelineMethods: countPipelineMethods, countBuildStepItems: countBuildStepItems,
  _renumberPipeline: renumberPipeline,
  _deletePipelineMethod: deletePipelineMethod,
  _extractPipelineMethod: extractPipelineMethod,
  _insertPipelineSkeleton: insertPipelineSkeleton,
  _insertBuildStep: insertBuildStep,
  _deleteBuildStep: deleteBuildStep,
  _extractBuildStep: extractBuildStep,
  _ensureStepMarkers: ensureStepMarkers,
  _findStepMarkerRange: findStepMarkerRange,
  _renumberStepMarkers: renumberStepMarkers,
};
