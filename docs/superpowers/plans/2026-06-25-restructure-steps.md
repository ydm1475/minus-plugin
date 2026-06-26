# 步骤结构变更：多文件原子同步重构 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将步骤结构变更操作（insert/delete/append/swap/generate）从 3 个独立进程串行执行，合并为单一 Node.js 模块 `restructure.cjs`，实现一次读取、内存操作、一致性校验、一次写回。

**Architecture:** 每个操作声明自己需要读写哪些数据源（pipeline.py / main.tsx / progress.json / total-steps / step_N_name），执行器根据声明动态组合读→执行→校验→写。声明 `validate: true` 的操作在写回前自动校验步骤数一致性。

**Tech Stack:** Node.js (CJS), Bash (薄壳 + 测试)

## Global Constraints

- Shell 脚本 shebang 必须用 `#!/usr/bin/env bash`
- 避免 Bash 4+ 特性（Windows Git Bash 只有 3.2）
- 生成的文件用 LF，不用 CRLF
- Node.js 代码用 `path.join()` 处理路径，不硬编码分隔符
- CLI 接口不变：所有 `.md` 里的 `minus-lib update-progress` / `minus-lib generate-steps` 命令不需要改
- 进度操作（step-done / set-phase / touch 等）不重写，保持在 update-progress.sh 中

---

### Task 1: restructure.cjs — 执行器框架 + 数据源读写

**Files:**
- Create: `plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs`
- Test: `tests/shell-scripts.test.sh`（追加测试）

**Interfaces:**
- Produces: `execute(opName, args)` 函数 — 后续 Task 的所有操作函数注册到 `ops` 对象后，由此执行器驱动
- Produces: `SOURCES` 对象 — 5 个数据源的 read/write 函数
- Produces: `validateConsistency(result)` — 校验步骤数一致性
- Produces: CLI 入口 — `node restructure.cjs <op> [args]`

- [ ] **Step 1: 写 restructure.cjs 的框架代码**

```js
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
  const files = fs.readdirSync(DEV_DIR).filter(f => /^step_\d+_name$/.test(f));
  for (const f of files) {
    const n = Number(f.match(/^step_(\d+)_name$/)[1]);
    names[n] = fs.readFileSync(path.join(DEV_DIR, f), 'utf8');
  }
  return names;
}

function writeStepNames(names) {
  fs.mkdirSync(DEV_DIR, { recursive: true });
  // 先删除旧的 step_N_name 文件
  if (fs.existsSync(DEV_DIR)) {
    for (const f of fs.readdirSync(DEV_DIR).filter(f => /^step_\d+_name$/.test(f))) {
      fs.unlinkSync(path.join(DEV_DIR, f));
    }
  }
  for (const [n, name] of Object.entries(names)) {
    fs.writeFileSync(path.join(DEV_DIR, `step_${n}_name`), name);
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
  const fnStart = code.indexOf('function buildSteps');
  if (fnStart === -1) return null;
  const returnIdx = code.indexOf('return [', fnStart);
  if (returnIdx === -1) return null;
  const arrStart = code.indexOf('[', returnIdx);
  let depth = 1, count = 0;
  let inString = false, strChar = '';
  for (let i = arrStart + 1; i < code.length; i++) {
    const ch = code[i];
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
  const total = result.totalSteps;
  const errors = [];

  if (result.pipeline !== undefined) {
    const pCount = countPipelineMethods(result.pipeline);
    if (pCount !== total) errors.push(`pipeline.py: ${pCount} 个方法，期望 ${total}`);
  }

  if (result.frontend !== undefined && result.frontend !== null) {
    const fCount = countBuildStepItems(result.frontend);
    if (fCount !== null && fCount !== total) errors.push(`main.tsx: ${fCount} 个渲染项，期望 ${total}`);
  }

  if (result.progress !== undefined) {
    const pKeys = Object.keys(result.progress.steps || {}).length;
    if (pKeys !== total) errors.push(`progress.json: ${pKeys} 个步骤，期望 ${total}`);
  }

  if (errors.length > 0) {
    console.error('错误：一致性校验失败，不写入任何文件');
    for (const e of errors) console.error('  - ' + e);
    process.exit(1);
  }
}

// ── 操作注册表 ──

const ops = {};

// ── 执行器 ──

function execute(opName, args) {
  const op = ops[opName];
  if (!op) {
    console.error(`错误：未知操作 "${opName}"，支持 ${Object.keys(ops).join(' / ')}`);
    process.exit(1);
  }

  const sources = {};
  for (const key of op.reads) sources[key] = SOURCES[key].read();

  const result = op.run(sources, ...args);

  if (op.validate) validateConsistency(result);

  for (const key of op.writes) {
    if (result[key] !== undefined) SOURCES[key].write(result[key]);
  }

  return result;
}

// ── CLI ──

if (require.main === module) {
  if (!fs.existsSync(path.join('.minus', 'skill.json'))) {
    console.error('错误：未找到 .minus/skill.json，不在 Minus Skill 项目目录中');
    process.exit(1);
  }

  const [opName, ...args] = process.argv.slice(2);
  if (!opName) {
    console.error(`用法: node restructure.cjs <${Object.keys(ops).join('|')}> [args]`);
    process.exit(1);
  }

  execute(opName, args);
}

module.exports = { execute, ops, SOURCES, validateConsistency, countPipelineMethods, countBuildStepItems };
```

- [ ] **Step 2: 写框架冒烟测试**

在 `tests/shell-scripts.test.sh` 的 `═══ generate-steps.sh ═══` 段落之后、`═══ generate-result-design.sh ═══` 段落之前，追加：

```bash
# ══════════════════════════════════════════════════════
echo ""
echo "═══ restructure.cjs ═══"
# ══════════════════════════════════════════════════════

RS="$STRUCT_LIB/restructure.cjs"

# Test: restructure.cjs 无参报用法
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus; echo '{"skillId":"sk_t"}' > .minus/skill.json
  OUTPUT=$(node "$RS" 2>&1 || true)
  if assert_contains "$OUTPUT" "用法"; then
    pass "restructure: shows usage without args"
  else
    fail "restructure: shows usage without args" "got: $OUTPUT"
  fi
)

# Test: restructure.cjs 未知操作报错
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus; echo '{"skillId":"sk_t"}' > .minus/skill.json
  OUTPUT=$(node "$RS" unknown 2>&1 || true)
  if assert_contains "$OUTPUT" "未知操作"; then
    pass "restructure: unknown op errors"
  else
    fail "restructure: unknown op errors" "got: $OUTPUT"
  fi
)
```

- [ ] **Step 3: 运行测试确认框架冒烟通过**

Run: `bash tests/shell-scripts.test.sh 2>&1 | tail -5`
Expected: 全部 pass，0 failures

- [ ] **Step 4: Commit**

```bash
git add plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs tests/shell-scripts.test.sh
git commit -m "feat(restructure): 新建 restructure.cjs 框架 — 执行器 + 数据源读写 + 一致性校验"
```

---

### Task 2: restructure.cjs — pipeline.py 工具函数

**Files:**
- Modify: `plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs`
- Test: `tests/shell-scripts.test.sh`

**Interfaces:**
- Consumes: `restructure.cjs` 框架（Task 1）
- Produces: `escPy(s)` / `renumberPipeline(code, from, to)` / `insertPipelineSkeleton(code, pos, total, name)` / `deletePipelineMethod(code, pos, total)` / `extractPipelineMethod(code, pos)` — 供 Task 4 的操作函数使用

- [ ] **Step 1: 写 pipeline 工具函数的测试**

在 `═══ restructure.cjs ═══` 段追加：

```bash
# Test: restructure.cjs renumberPipeline 正确重编号
(
  TMP=$(make_tmp); cd "$TMP"
  cat > pipeline.py <<'PYEOF'
class SkillPipeline(Pipeline):

    async def step_1(self, ctx):
        prev = ctx.previous_outputs.get(1, {})
        return None

    async def step_2(self, ctx):
        prev = ctx.previous_outputs.get(1, {})
        return None
PYEOF
  # 用 node 直接测试内部函数
  node -e "
    const m = require('$RS');
    let code = require('fs').readFileSync('pipeline.py','utf8');
    code = m._renumberPipeline(code, 2, 3);
    if (!/step_3/.test(code)) { console.error('step_2 未变成 step_3'); process.exit(1); }
    if (!/step_1/.test(code)) { console.error('step_1 被误改'); process.exit(1); }
    // get(1) in step_2(now step_3) should NOT change — it references step 1's output
    if (!/get\(1/.test(code)) { console.error('get(1) 被误改'); process.exit(1); }
    console.log('ok');
  "
  if [ $? -eq 0 ]; then
    pass "restructure: renumberPipeline renames step_2 to step_3"
  else
    fail "restructure: renumberPipeline renames step_2 to step_3" ""
  fi
)

# Test: restructure.cjs deletePipelineMethod 保留末尾代码
(
  TMP=$(make_tmp); cd "$TMP"
  cat > pipeline.py <<'PYEOF'
class SkillPipeline(Pipeline):

    async def step_1(self, ctx):
        return None

    async def step_2(self, ctx):
        return None

if __name__ == '__main__':
    SkillPipeline().run()
PYEOF
  node -e "
    const m = require('$RS');
    let code = require('fs').readFileSync('pipeline.py','utf8');
    code = m._deletePipelineMethod(code, 2, 2);
    if (!/step_1/.test(code)) { console.error('step_1 丢失'); process.exit(1); }
    if (/step_2/.test(code)) { console.error('step_2 未删除'); process.exit(1); }
    if (!/__main__/.test(code)) { console.error('末尾代码被吞'); process.exit(1); }
    console.log('ok');
  "
  if [ $? -eq 0 ]; then
    pass "restructure: deletePipelineMethod preserves trailing code"
  else
    fail "restructure: deletePipelineMethod preserves trailing code" ""
  fi
)

# Test: restructure.cjs extractPipelineMethod 提取方法体
(
  TMP=$(make_tmp); cd "$TMP"
  cat > pipeline.py <<'PYEOF'
class SkillPipeline(Pipeline):

    async def step_1(self, ctx):
        x = 1
        return x

    async def step_2(self, ctx):
        y = 2
        return y
PYEOF
  node -e "
    const m = require('$RS');
    let code = require('fs').readFileSync('pipeline.py','utf8');
    const body = m._extractPipelineMethod(code, 1);
    if (!/x = 1/.test(body)) { console.error('方法体未包含 x = 1'); process.exit(1); }
    if (/step_2/.test(body)) { console.error('方法体包含了 step_2'); process.exit(1); }
    console.log('ok');
  "
  if [ $? -eq 0 ]; then
    pass "restructure: extractPipelineMethod extracts step_1 body"
  else
    fail "restructure: extractPipelineMethod extracts step_1 body" ""
  fi
)
```

- [ ] **Step 2: 从 restructure-pipeline.cjs 搬入工具函数并导出**

在 `restructure.cjs` 的 `// ── 操作注册表 ──` 行前面，添加以下代码（从 restructure-pipeline.cjs 搬入，加上新增的 extract）：

```js
// ── pipeline.py 工具函数 ──

function escPy(s) {
  return (s || '').replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
}

function renumberPipeline(code, from, to) {
  const f = String(from), t = String(to);
  code = code.replace(new RegExp('(async def step_)' + f + '(?=\\()', 'g'), '$1' + t);
  code = code.replace(new RegExp('(ctx\\.previous_outputs\\.get\\()' + f + '(?=[,\\)])', 'g'), '$1' + t);
  code = code.replace(new RegExp('(ctx\\.step_payload\\()' + f + '(?=[,\\)])', 'g'), '$1' + t);
  return code;
}

function insertPipelineSkeleton(code, pos, total, name) {
  for (let i = total; i >= pos; i--) {
    code = renumberPipeline(code, i, i + 1);
  }
  const skeleton =
    '\n    async def step_' + pos + '(self, ctx: PipelineContext) -> StepOutcome:\n' +
    '        # TODO: 实现「' + escPy(name) + '」的逻辑\n' +
    '        return StepOutcome.complete(payload={"text": "' + escPy(name) + '完成"})\n';
  const marker = 'async def step_' + (pos + 1) + '(';
  const idx = code.indexOf(marker);
  if (idx !== -1) {
    const lineStart = code.lastIndexOf('\n', idx);
    code = code.slice(0, lineStart) + skeleton + code.slice(lineStart);
  } else {
    code = code + skeleton;
  }
  return code;
}

function deletePipelineMethod(code, pos, total) {
  const methodStart = code.indexOf('\n    async def step_' + pos + '(');
  if (methodStart !== -1) {
    const searchAfter = methodStart + 1;
    const nextBoundary = code.slice(searchAfter).search(/\n(    (async def |def )|[^ \t\n])/);
    const methodEnd = nextBoundary !== -1 ? searchAfter + nextBoundary : code.length;
    const trailing = code.slice(methodEnd);
    if (trailing.trim().length === 0) {
      code = code.slice(0, methodStart);
    } else {
      code = code.slice(0, methodStart) + code.slice(methodEnd);
    }
  }
  for (let i = pos + 1; i <= total; i++) {
    code = renumberPipeline(code, i, i - 1);
  }
  return code;
}

function extractPipelineMethod(code, pos) {
  const methodStart = code.indexOf('\n    async def step_' + pos + '(');
  if (methodStart === -1) return null;
  const searchAfter = methodStart + 1;
  const nextBoundary = code.slice(searchAfter).search(/\n(    (async def |def )|[^ \t\n])/);
  const methodEnd = nextBoundary !== -1 ? searchAfter + nextBoundary : code.length;
  return code.slice(methodStart, methodEnd);
}
```

在 `module.exports` 行中追加内部函数导出（供测试用）：

```js
module.exports = {
  execute, ops, SOURCES, validateConsistency, countPipelineMethods, countBuildStepItems,
  _renumberPipeline: renumberPipeline,
  _deletePipelineMethod: deletePipelineMethod,
  _extractPipelineMethod: extractPipelineMethod,
  _insertPipelineSkeleton: insertPipelineSkeleton,
};
```

- [ ] **Step 3: 运行测试**

Run: `bash tests/shell-scripts.test.sh 2>&1 | tail -5`
Expected: 新增的 3 个测试全部 pass

- [ ] **Step 4: Commit**

```bash
git add plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs tests/shell-scripts.test.sh
git commit -m "feat(restructure): 添加 pipeline.py 工具函数 — renumber/insert/delete/extract"
```

---

### Task 3: restructure.cjs — main.tsx 工具函数

**Files:**
- Modify: `plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs`
- Test: `tests/shell-scripts.test.sh`

**Interfaces:**
- Consumes: `restructure.cjs` 框架（Task 1）
- Produces: `escJsx(s)` / `findNthBuildStep(code, arrStart, n)` / `insertBuildStep(code, pos, name)` / `deleteBuildStep(code, pos)` — 供 Task 4 的操作函数使用

- [ ] **Step 1: 写 frontend 工具函数的测试**

```bash
# Test: restructure.cjs insertBuildStep 在中间位置插入
(
  TMP=$(make_tmp); cd "$TMP"
  cat > main.tsx <<'TSXEOF'
function buildSteps(t) {
  return [
    {
      render: ({ data }) => (<div>A</div>),
    },
    {
      render: ({ data }) => (<div>B</div>),
    },
  ];
}
TSXEOF
  node -e "
    const m = require('$RS');
    let code = require('fs').readFileSync('main.tsx','utf8');
    code = m._insertBuildStep(code, 2, '插入项');
    const count = (code.match(/render:/g) || []).length;
    if (count !== 3) { console.error('期望 3 个 render，得到 ' + count); process.exit(1); }
    console.log('ok');
  "
  if [ $? -eq 0 ]; then
    pass "restructure: insertBuildStep inserts at position 2"
  else
    fail "restructure: insertBuildStep inserts at position 2" ""
  fi
)

# Test: restructure.cjs deleteBuildStep 删除并保持结构
(
  TMP=$(make_tmp); cd "$TMP"
  cat > main.tsx <<'TSXEOF'
function buildSteps(t) {
  return [
    {
      render: ({ data }) => (<div>A</div>),
    },
    {
      render: ({ data }) => (<div>B</div>),
    },
    {
      render: ({ data }) => (<div>C</div>),
    },
  ];
}
TSXEOF
  node -e "
    const m = require('$RS');
    let code = require('fs').readFileSync('main.tsx','utf8');
    code = m._deleteBuildStep(code, 2);
    const count = (code.match(/render:/g) || []).length;
    if (count !== 2) { console.error('期望 2 个 render，得到 ' + count); process.exit(1); }
    if (/B/.test(code)) { console.error('B 未被删除'); process.exit(1); }
    console.log('ok');
  "
  if [ $? -eq 0 ]; then
    pass "restructure: deleteBuildStep removes item 2"
  else
    fail "restructure: deleteBuildStep removes item 2" ""
  fi
)
```

- [ ] **Step 2: 从 restructure-frontend.cjs 搬入工具函数并导出**

在 pipeline 工具函数之后，`// ── 操作注册表 ──` 之前添加：

```js
// ── main.tsx 工具函数 ──

function escJsx(s) {
  return (s || '').replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/</g, '&lt;').replace(/[{}]/g, c => '&#' + c.charCodeAt(0) + ';');
}

function findBuildStepArrayStart(code) {
  const fnStart = code.indexOf('function buildSteps');
  if (fnStart === -1) return -1;
  const returnIdx = code.indexOf('return [', fnStart);
  if (returnIdx === -1) return -1;
  return code.indexOf('[', returnIdx);
}

function findNthBuildStep(code, arrStart, n) {
  let depth = 1, itemCount = 0, itemStart = -1, itemEnd = -1;
  let inString = false, strChar = '';
  for (let i = arrStart + 1; i < code.length; i++) {
    const ch = code[i];
    if (inString) {
      if (ch === '\\') { i++; continue; }
      if (ch === strChar) inString = false;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') { inString = true; strChar = ch; continue; }
    if (ch === '{' && depth === 1) {
      itemCount++;
      if (itemCount === n) itemStart = i;
    }
    if (ch === '[' || ch === '{' || ch === '(') depth++;
    if (ch === ']' || ch === '}' || ch === ')') {
      depth--;
      if (itemCount === n && depth === 1) { itemEnd = i + 1; break; }
    }
  }
  return { itemStart, itemEnd };
}

function buildStepEntry(name) {
  return '    {\n' +
    '      render: ({ data }) => (\n' +
    "        <div style={{ marginTop: 24, padding: '32px 24px', borderRadius: 12, background: 'var(--minus-step-bg, #f9fafb)', border: '1px solid var(--minus-step-border, #e5e7eb)', textAlign: 'center', fontSize: 18, fontWeight: 600 }}>\n" +
    "          {(data.text as string) ?? '" + escJsx(name) + "'}\n" +
    '        </div>\n' +
    '      ),\n' +
    '    },\n';
}

function insertBuildStep(code, pos, name) {
  const arrStart = findBuildStepArrayStart(code);
  if (arrStart === -1) return code;
  const newEntry = buildStepEntry(name);
  const { itemStart } = findNthBuildStep(code, arrStart, pos);
  if (itemStart !== -1) {
    const lineStart = code.lastIndexOf('\n', itemStart);
    code = code.slice(0, lineStart + 1) + newEntry + code.slice(lineStart + 1);
  } else {
    let d = 0, closeIdx = -1;
    for (let i = arrStart; i < code.length; i++) {
      if (code[i] === '[') d++;
      else if (code[i] === ']') { d--; if (d === 0) { closeIdx = i; break; } }
    }
    if (closeIdx !== -1) {
      code = code.slice(0, closeIdx) + newEntry + code.slice(closeIdx);
    }
  }
  return code;
}

function deleteBuildStep(code, pos) {
  const arrStart = findBuildStepArrayStart(code);
  if (arrStart === -1) return code;
  const { itemStart, itemEnd } = findNthBuildStep(code, arrStart, pos);
  if (itemStart === -1 || itemEnd === -1) return code;
  let lineStart = code.lastIndexOf('\n', itemStart);
  let afterEnd = itemEnd;
  if (afterEnd < code.length && code[afterEnd] === ',') afterEnd++;
  while (afterEnd < code.length && (code[afterEnd] === ' ' || code[afterEnd] === '\n')) afterEnd++;
  if (afterEnd < code.length && (code[afterEnd] === ']' || code[afterEnd] === '}')) {
    code = code.slice(0, lineStart + 1) + code.slice(afterEnd);
  } else {
    code = code.slice(0, lineStart) + '\n' + code.slice(afterEnd);
  }
  return code;
}

function extractBuildStep(code, pos) {
  const arrStart = findBuildStepArrayStart(code);
  if (arrStart === -1) return null;
  const { itemStart, itemEnd } = findNthBuildStep(code, arrStart, pos);
  if (itemStart === -1 || itemEnd === -1) return null;
  const lineStart = code.lastIndexOf('\n', itemStart);
  let afterEnd = itemEnd;
  if (afterEnd < code.length && code[afterEnd] === ',') afterEnd++;
  return code.slice(lineStart, afterEnd);
}
```

在 `module.exports` 追加：

```js
_insertBuildStep: insertBuildStep,
_deleteBuildStep: deleteBuildStep,
_extractBuildStep: extractBuildStep,
```

- [ ] **Step 3: 运行测试**

Run: `bash tests/shell-scripts.test.sh 2>&1 | tail -5`
Expected: 新增的 2 个测试全部 pass

- [ ] **Step 4: Commit**

```bash
git add plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs tests/shell-scripts.test.sh
git commit -m "feat(restructure): 添加 main.tsx 工具函数 — findNth/insert/delete/extract"
```

---

### Task 4: restructure.cjs — 注册 insert / delete / append 操作

**Files:**
- Modify: `plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs`
- Test: `tests/shell-scripts.test.sh`

**Interfaces:**
- Consumes: pipeline 工具函数（Task 2）、frontend 工具函数（Task 3）
- Produces: `ops.insert` / `ops.delete` / `ops.append` — 可通过 `node restructure.cjs insert 2 "名称"` 直接调用

- [ ] **Step 1: 写 insert / delete / append 的集成测试**

```bash
# Test: restructure.cjs insert 原子写入全部数据源
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus frontend/src
  echo '{"skillId":"sk_t"}' > .minus/skill.json
  setup_project 3
  bash "$UP" design-done "A" "B" "C" >/dev/null 2>&1
  # 创建 main.tsx
  cat > frontend/src/main.tsx <<'TSXEOF'
function buildSteps(t) {
  return [
    { render: ({ data }) => (<div>A</div>), },
    { render: ({ data }) => (<div>B</div>), },
    { render: ({ data }) => (<div>C</div>), },
  ];
}
TSXEOF
  # 执行 insert
  node "$RS" insert 2 "新步骤"
  # 验证 5 个数据源全部一致
  PIPE_COUNT=$(grep -c 'async def step_' pipeline.py)
  FRONT_COUNT=$(grep -c 'render:' frontend/src/main.tsx)
  PROG_NAME=$(pj '.steps["2"].name')
  TOTAL=$(cat .minus/total-steps)
  NAME_FILE=$(cat .minus/dev-progress/step_2_name 2>/dev/null)
  if [ "$PIPE_COUNT" = "4" ] && [ "$FRONT_COUNT" = "4" ] \
     && [ "$PROG_NAME" = "新步骤" ] && [ "$TOTAL" = "4" ] && [ "$NAME_FILE" = "新步骤" ]; then
    pass "restructure: insert atomically writes all 5 sources"
  else
    fail "restructure: insert atomically writes all 5 sources" \
      "pipeline=$PIPE_COUNT frontend=$FRONT_COUNT progress=$PROG_NAME total=$TOTAL name=$NAME_FILE"
  fi
)

# Test: restructure.cjs delete 原子写入全部数据源
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus frontend/src
  echo '{"skillId":"sk_t"}' > .minus/skill.json
  setup_project 3
  bash "$UP" design-done "A" "B" "C" >/dev/null 2>&1
  mkdir -p .minus/dev-progress
  printf 'A' > .minus/dev-progress/step_1_name
  printf 'B' > .minus/dev-progress/step_2_name
  printf 'C' > .minus/dev-progress/step_3_name
  cat > frontend/src/main.tsx <<'TSXEOF'
function buildSteps(t) {
  return [
    { render: ({ data }) => (<div>A</div>), },
    { render: ({ data }) => (<div>B</div>), },
    { render: ({ data }) => (<div>C</div>), },
  ];
}
TSXEOF
  node "$RS" delete 2
  PIPE_COUNT=$(grep -c 'async def step_' pipeline.py)
  FRONT_COUNT=$(grep -c 'render:' frontend/src/main.tsx)
  PROG_NAME=$(pj '.steps["2"].name')
  TOTAL=$(cat .minus/total-steps)
  NAME_FILE=$(cat .minus/dev-progress/step_2_name 2>/dev/null)
  if [ "$PIPE_COUNT" = "2" ] && [ "$FRONT_COUNT" = "2" ] \
     && [ "$PROG_NAME" = "C" ] && [ "$TOTAL" = "2" ] && [ "$NAME_FILE" = "C" ]; then
    pass "restructure: delete atomically writes all 5 sources"
  else
    fail "restructure: delete atomically writes all 5 sources" \
      "pipeline=$PIPE_COUNT frontend=$FRONT_COUNT progress=$PROG_NAME total=$TOTAL name=$NAME_FILE"
  fi
)

# Test: restructure.cjs append 原子写入
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus frontend/src
  echo '{"skillId":"sk_t"}' > .minus/skill.json
  setup_project 2
  bash "$UP" design-done "A" "B" >/dev/null 2>&1
  cat > frontend/src/main.tsx <<'TSXEOF'
function buildSteps(t) {
  return [
    { render: ({ data }) => (<div>A</div>), },
    { render: ({ data }) => (<div>B</div>), },
  ];
}
TSXEOF
  node "$RS" append "C" "D"
  PIPE_COUNT=$(grep -c 'async def step_' pipeline.py)
  FRONT_COUNT=$(grep -c 'render:' frontend/src/main.tsx)
  TOTAL=$(cat .minus/total-steps)
  PROG_KEYS=$(node -e "const p=JSON.parse(require('fs').readFileSync('.minus/progress.json','utf8'));console.log(Object.keys(p.steps).length)")
  if [ "$PIPE_COUNT" = "4" ] && [ "$FRONT_COUNT" = "4" ] \
     && [ "$TOTAL" = "4" ] && [ "$PROG_KEYS" = "4" ]; then
    pass "restructure: append atomically writes all sources"
  else
    fail "restructure: append atomically writes all sources" \
      "pipeline=$PIPE_COUNT frontend=$FRONT_COUNT total=$TOTAL progress_keys=$PROG_KEYS"
  fi
)

# Test: restructure.cjs insert 无 main.tsx 时报错不写
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus
  echo '{"skillId":"sk_t"}' > .minus/skill.json
  setup_project 2
  bash "$UP" design-done "A" "B" >/dev/null 2>&1
  OUTPUT=$(node "$RS" insert 1 "X" 2>&1 || true)
  # pipeline.py 不应被改动（原子性：前端缺失则全部不写）
  if assert_contains "$OUTPUT" "错误" && grep -q 'step_1' pipeline.py && ! grep -q 'step_3' pipeline.py; then
    pass "restructure: insert without main.tsx errors and writes nothing"
  else
    fail "restructure: insert without main.tsx errors and writes nothing" "got: $OUTPUT"
  fi
)

# Test: restructure.cjs delete 不覆盖 completed 状态
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus frontend/src
  echo '{"skillId":"sk_t"}' > .minus/skill.json
  setup_project 3
  bash "$UP" design-done "A" "B" "C" >/dev/null 2>&1
  # 手动设置步骤 3 为 completed
  node -e "
    const fs=require('fs');
    const p=JSON.parse(fs.readFileSync('.minus/progress.json','utf8'));
    p.steps['1'].status='completed';
    p.currentStep=2;
    p.steps['3'].status='completed';
    fs.writeFileSync('.minus/progress.json',JSON.stringify(p,null,2)+'\n');
  "
  cat > frontend/src/main.tsx <<'TSXEOF'
function buildSteps(t) {
  return [
    { render: ({ data }) => (<div>A</div>), },
    { render: ({ data }) => (<div>B</div>), },
    { render: ({ data }) => (<div>C</div>), },
  ];
}
TSXEOF
  node "$RS" delete 2
  STATUS=$(pj '.steps["2"].status')
  if [ "$STATUS" = "completed" ]; then
    pass "restructure: delete does not overwrite completed status"
  else
    fail "restructure: delete does not overwrite completed status" "got status=$STATUS"
  fi
)
```

- [ ] **Step 2: 实现 insert / delete / append 操作**

在 `restructure.cjs` 的 `const ops = {};` 之后，添加：

```js
ops.insert = {
  reads: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  validate: true,
  run(sources, posStr, name) {
    const pos = Number(posStr);
    const total = sources.totalSteps;
    const newTotal = total + 1;

    if (!name) { console.error('用法: restructure.cjs insert <位置N> <步骤名称>'); process.exit(1); }
    if (pos < 1 || pos > total + 1) { console.error(`错误：插入位置 ${pos} 超出范围（1 ~ ${total + 1}）`); process.exit(1); }
    if (sources.frontend === null) { console.error('错误：未找到 ' + FRONTEND_FILE + '，结构变更需要 main.tsx 存在'); process.exit(1); }

    const pipeline = insertPipelineSkeleton(sources.pipeline, pos, total, name);
    const frontend = insertBuildStep(sources.frontend, pos, name);

    const p = sources.progress;
    p.steps = p.steps || {};
    const max = Math.max(0, ...Object.keys(p.steps).map(Number));
    for (let i = max; i >= pos; i--) {
      p.steps[String(i + 1)] = p.steps[String(i)];
    }
    p.steps[String(pos)] = { name, status: 'pending' };
    if (p.currentStep >= pos) p.currentStep = p.currentStep + 1;

    const stepNames = {};
    for (const [k, v] of Object.entries(sources.stepNames)) {
      const n = Number(k);
      stepNames[n >= pos ? n + 1 : n] = v;
    }
    stepNames[pos] = name;

    console.log(`✓ 已在位置 ${pos} 插入步骤「${name}」，总步骤数 ${total} → ${newTotal}`);
    return { pipeline, frontend, progress: p, totalSteps: newTotal, stepNames };
  },
};

ops.delete = {
  reads: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  validate: true,
  run(sources, posStr) {
    const pos = Number(posStr);
    const total = sources.totalSteps;
    const newTotal = total - 1;

    if (pos < 1 || pos > total) { console.error(`错误：步骤 ${pos} 不存在（当前共 ${total} 步）`); process.exit(1); }
    if (newTotal < 1) { console.error('错误：只剩一个步骤，不能删除'); process.exit(1); }
    if (sources.frontend === null) { console.error('错误：未找到 ' + FRONTEND_FILE + '，结构变更需要 main.tsx 存在'); process.exit(1); }

    const pipeline = deletePipelineMethod(sources.pipeline, pos, total);
    const frontend = deleteBuildStep(sources.frontend, pos);

    const p = sources.progress;
    const max = Math.max(0, ...Object.keys(p.steps).map(Number));
    for (let i = pos; i < max; i++) {
      p.steps[String(i)] = p.steps[String(i + 1)];
    }
    delete p.steps[String(max)];

    if (p.currentStep > pos) {
      p.currentStep = p.currentStep - 1;
    } else if (p.currentStep === pos) {
      if (p.currentStep > newTotal) p.currentStep = newTotal;
      const step = p.steps[String(p.currentStep)];
      if (step && step.status !== 'completed') step.status = 'in_progress';
    }

    const stepNames = {};
    for (const [k, v] of Object.entries(sources.stepNames)) {
      const n = Number(k);
      if (n === pos) continue;
      stepNames[n > pos ? n - 1 : n] = v;
    }

    console.log(`✓ 已删除步骤 ${pos}，总步骤数 ${total} → ${newTotal}`);
    return { pipeline, frontend, progress: p, totalSteps: newTotal, stepNames };
  },
};

ops.append = {
  reads: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
  validate: true,
  run(sources, ...names) {
    if (names.length === 0) { console.error('用法: restructure.cjs append <步骤名称> ...'); process.exit(1); }
    if (sources.frontend === null) { console.error('错误：未找到 ' + FRONTEND_FILE + '，结构变更需要 main.tsx 存在'); process.exit(1); }

    let { pipeline, frontend } = sources;
    const total = sources.totalSteps;
    const newTotal = total + names.length;
    const p = sources.progress;
    const stepNames = { ...sources.stepNames };

    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      const stepNum = total + i + 1;
      pipeline += '\n    async def step_' + stepNum + '(self, ctx: PipelineContext) -> StepOutcome:\n' +
        '        # TODO: 实现「' + escPy(name) + '」的逻辑\n' +
        '        return StepOutcome.complete(payload={"text": "' + escPy(name) + '完成"})\n';
      frontend = insertBuildStep(frontend, stepNum, name);
      p.steps = p.steps || {};
      p.steps[String(stepNum)] = { name, status: 'pending' };
      stepNames[stepNum] = name;
    }

    console.log(`✓ 追加了 ${names.length} 个步骤，总步骤数 ${total} → ${newTotal}`);
    return { pipeline, frontend, progress: p, totalSteps: newTotal, stepNames };
  },
};
```

- [ ] **Step 3: 运行测试**

Run: `bash tests/shell-scripts.test.sh 2>&1 | tail -5`
Expected: 新增的 5 个集成测试全部 pass

- [ ] **Step 4: Commit**

```bash
git add plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs tests/shell-scripts.test.sh
git commit -m "feat(restructure): 实现 insert/delete/append 操作 — 原子多文件写入 + delete 不覆盖 completed"
```

---

### Task 5: restructure.cjs — 注册 swap / generate 操作

**Files:**
- Modify: `plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs`
- Test: `tests/shell-scripts.test.sh`

**Interfaces:**
- Consumes: pipeline + frontend 工具函数（Task 2, 3）
- Produces: `ops.swap` / `ops.generate`

- [ ] **Step 1: 写 swap / generate 的测试**

```bash
# Test: restructure.cjs swap 同时交换全部数据源
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus/dev-progress frontend/src
  echo '{"skillId":"sk_t"}' > .minus/skill.json
  # 手工搭一个 2 步项目（非骨架，有真实代码）
  cat > pipeline.py <<'PYEOF'
class SkillPipeline(Pipeline):

    async def step_1(self, ctx):
        x = "step1_code"
        return x

    async def step_2(self, ctx):
        y = "step2_code"
        return y
PYEOF
  echo '2' > .minus/total-steps
  cat > .minus/progress.json <<'JEOF'
{"currentStep":1,"steps":{"1":{"name":"甲","status":"in_progress"},"2":{"name":"乙","status":"pending"}},"phase":"developing"}
JEOF
  printf '甲' > .minus/dev-progress/step_1_name
  printf '乙' > .minus/dev-progress/step_2_name
  cat > frontend/src/main.tsx <<'TSXEOF'
function buildSteps(t) {
  return [
    { render: ({ data }) => (<div>甲</div>), },
    { render: ({ data }) => (<div>乙</div>), },
  ];
}
TSXEOF
  node "$RS" swap 1 2
  # 验证 pipeline.py 方法体已交换
  STEP1_BODY=$(node -e "const m=require('$RS');const c=require('fs').readFileSync('pipeline.py','utf8');console.log(m._extractPipelineMethod(c,1))")
  STEP2_BODY=$(node -e "const m=require('$RS');const c=require('fs').readFileSync('pipeline.py','utf8');console.log(m._extractPipelineMethod(c,2))")
  PROG_1=$(pj '.steps["1"].name')
  PROG_2=$(pj '.steps["2"].name')
  NAME_1=$(cat .minus/dev-progress/step_1_name)
  NAME_2=$(cat .minus/dev-progress/step_2_name)
  if assert_contains "$STEP1_BODY" "step2_code" && assert_contains "$STEP2_BODY" "step1_code" \
     && [ "$PROG_1" = "乙" ] && [ "$PROG_2" = "甲" ] \
     && [ "$NAME_1" = "乙" ] && [ "$NAME_2" = "甲" ]; then
    pass "restructure: swap exchanges all data sources"
  else
    fail "restructure: swap exchanges all data sources" \
      "step1_body=$STEP1_BODY prog1=$PROG_1 name1=$NAME_1"
  fi
)

# Test: restructure.cjs generate 全量生成
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus frontend/src
  echo '{"skillId":"sk_t"}' > .minus/skill.json
  cat > pipeline.py <<'PYEOF'
class TestPipeline(Pipeline):
    version = "1.0.0"
PYEOF
  cat > frontend/src/main.tsx <<'TSXEOF'
function buildSteps(t) {
  return [
    { render: ({ data }) => (<div>old</div>), },
  ];
}
TSXEOF
  node "$RS" generate "步骤A" "步骤B" "步骤C"
  PIPE_COUNT=$(grep -c 'async def step_' pipeline.py)
  TOTAL=$(cat .minus/total-steps)
  PROG_PHASE=$(pj '.phase')
  if [ "$PIPE_COUNT" = "3" ] && [ "$TOTAL" = "3" ] && [ "$PROG_PHASE" = "developing" ]; then
    pass "restructure: generate creates full project"
  else
    fail "restructure: generate creates full project" "pipe=$PIPE_COUNT total=$TOTAL phase=$PROG_PHASE"
  fi
)
```

- [ ] **Step 2: 实现 swap 和 generate 操作**

在 `ops.append` 之后添加：

```js
ops.swap = {
  reads: ['pipeline', 'frontend', 'progress', 'stepNames'],
  writes: ['pipeline', 'frontend', 'progress', 'stepNames'],
  validate: false,
  run(sources, aStr, bStr) {
    const a = Number(aStr), b = Number(bStr);
    if (!a || !b || a === b) { console.error('用法: restructure.cjs swap <A> <B>'); process.exit(1); }
    if (sources.frontend === null) { console.error('错误：未找到 ' + FRONTEND_FILE); process.exit(1); }

    let { pipeline, frontend } = sources;
    const p = sources.progress;

    // swap pipeline method bodies
    const bodyA = extractPipelineMethod(pipeline, a);
    const bodyB = extractPipelineMethod(pipeline, b);
    if (bodyA && bodyB) {
      // replace body of step_a with body of step_b (keeping the def line of step_a)
      const defLineA = '\n    async def step_' + a + '(';
      const defLineB = '\n    async def step_' + b + '(';
      // extract just the body (after the def line)
      const bodyOnlyA = bodyA.slice(bodyA.indexOf('\n', 1));
      const bodyOnlyB = bodyB.slice(bodyB.indexOf('\n', 1));
      // swap: put B's body under A's def, and A's body under B's def
      pipeline = pipeline.replace(bodyA, bodyA.slice(0, bodyA.indexOf('\n', 1)) + bodyOnlyB);
      pipeline = pipeline.replace(bodyB, bodyB.slice(0, bodyB.indexOf('\n', 1)) + bodyOnlyA);
    }

    // swap frontend buildStep items
    const entryA = extractBuildStep(frontend, a);
    const entryB = extractBuildStep(frontend, b);
    if (entryA && entryB) {
      const placeholder = '\n    /* __SWAP_PLACEHOLDER__ */';
      frontend = frontend.replace(entryA, placeholder);
      frontend = frontend.replace(entryB, entryA);
      frontend = frontend.replace(placeholder, entryB);
    }

    // swap progress
    const tmp = p.steps[String(a)];
    p.steps[String(a)] = p.steps[String(b)] || { name: '步骤' + a, status: 'pending' };
    p.steps[String(b)] = tmp || { name: '步骤' + b, status: 'pending' };

    // swap step names
    const stepNames = { ...sources.stepNames };
    const tmpName = stepNames[a];
    stepNames[a] = stepNames[b];
    stepNames[b] = tmpName;

    console.log(`✓ 步骤 ${a} 和步骤 ${b} 已交换`);
    return { pipeline, frontend, progress: p, stepNames };
  },
};

ops.generate = {
  reads: ['pipeline', 'frontend'],
  writes: ['pipeline', 'frontend', 'progress', 'totalSteps'],
  validate: true,
  run(sources, ...names) {
    if (names.length === 0) { console.error('用法: restructure.cjs generate <步骤名称> ...'); process.exit(1); }

    // 读 class name from existing pipeline.py
    const classMatch = sources.pipeline.match(/class\s+(\w+)\(Pipeline\)/);
    const className = classMatch ? classMatch[1] : 'SkillPipeline';

    // generate pipeline.py
    let pipeline = 'from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome\n\n\n' +
      'class ' + className + '(Pipeline):\n';
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      pipeline += '\n    async def step_' + (i + 1) + '(self, ctx: PipelineContext) -> StepOutcome:\n' +
        '        # TODO: 实现「' + escPy(name) + '」的逻辑\n' +
        '        return StepOutcome.complete(payload={"text": "' + escPy(name) + '完成"})\n';
    }

    // generate frontend buildSteps (if main.tsx exists)
    let frontend = sources.frontend;
    if (frontend !== null) {
      let stepsCode = '';
      for (let i = 0; i < names.length; i++) {
        stepsCode += buildStepEntry(names[i]);
      }
      const pattern = /(function buildSteps\([^)]*\)[^{]*\{[\s\S]*?return\s*\[)([\s\S]*?)(\];\s*\n\})/m;
      const match = frontend.match(pattern);
      if (match) {
        frontend = frontend.replace(pattern, match[1] + '\n' + stepsCode + '  ' + match[3]);
      }
    }

    // generate progress
    const steps = {};
    for (let i = 0; i < names.length; i++) {
      steps[String(i + 1)] = { name: names[i], status: i === 0 ? 'in_progress' : 'pending' };
    }
    const progress = { currentStep: 1, steps, phase: 'developing' };

    console.log(`✓ 已生成 ${names.length} 个步骤`);
    return { pipeline, frontend, progress, totalSteps: names.length };
  },
};
```

- [ ] **Step 3: 运行测试**

Run: `bash tests/shell-scripts.test.sh 2>&1 | tail -5`
Expected: 新增的 2 个测试 pass

- [ ] **Step 4: Commit**

```bash
git add plugins/claude/minus-creator/skills/minus-structure/scripts/restructure.cjs tests/shell-scripts.test.sh
git commit -m "feat(restructure): 实现 swap（全数据源同步）和 generate（全量生成）操作"
```

---

### Task 6: generate-steps.sh 改为调用 restructure.cjs + update-progress.sh 清理

**Files:**
- Modify: `plugins/claude/minus-creator/skills/minus-structure/scripts/generate-steps.sh`
- Modify: `plugins/claude/minus-creator/scripts/update-progress.sh`

**Interfaces:**
- Consumes: `restructure.cjs` 的 CLI 接口（`node restructure.cjs <op> [args]`）
- 保持: `minus-lib generate-steps` 和 `minus-lib update-progress` 的 CLI 接口不变

- [ ] **Step 1: 改写 generate-steps.sh 的 insert / delete / append / 全量生成模式**

将 `generate-steps.sh` 的四个模式改为调用 `restructure.cjs`。非步骤管理逻辑（input-type、node-dev.md 输出）保留不动。

替换 insert 模式（约第 50-76 行）：

```bash
# ── --insert-at 模式 ──
if [ "$MODE" = "insert" ]; then
  node "$GS_SCRIPT_DIR/restructure.cjs" insert "$INSERT_AT" "$1"
  exit 0
fi
```

替换 delete 模式（约第 78-103 行）：

```bash
# ── --delete 模式 ──
if [ "$MODE" = "delete" ]; then
  node "$GS_SCRIPT_DIR/restructure.cjs" delete "$DELETE_AT"
  exit 0
fi
```

替换 append 模式（约第 105-148 行）：

```bash
# ── --append 模式 ──
if [ "$MODE" = "append" ]; then
  node "$GS_SCRIPT_DIR/restructure.cjs" append "$@"
  exit 0
fi
```

替换全量生成（约第 150-225 行，到 input-type 处理之前）：

```bash
STEP_COUNT=$#
STEP_NAMES=("$@")

# ── 读取 pipeline.py 的 class 名 ──
CLASS_NAME=$(grep 'class.*Pipeline' pipeline.py 2>/dev/null | sed 's/class \([A-Za-z0-9_]*\)(Pipeline).*/\1/' | head -1)
if [ -z "$CLASS_NAME" ]; then
  CLASS_NAME="SkillPipeline"
fi

# ── 调用 restructure.cjs generate ──
node "$GS_SCRIPT_DIR/restructure.cjs" generate "${STEP_NAMES[@]}"

echo "✓ pipeline.py 已生成 ${STEP_COUNT} 个步骤"
```

input-type 处理和 node-dev.md 输出逻辑保持不动（约第 227 行之后）。

注意：全量生成模式原来调用 `bash "$UPDATE_PROGRESS" design-done`，现在 `restructure.cjs generate` 内部直接写 progress.json（设置 phase=developing 和步骤列表），所以不再需要调用 update-progress.sh。

- [ ] **Step 2: 清理 update-progress.sh**

2a. 修改 shebang：

```bash
# 第 1 行：#!/bin/bash → #!/usr/bin/env bash
```

2b. 删除 `insert-step)` 和 `delete-step)` 两个 case 分支（约第 163-212 行）。这些分支不再被调用——restructure.cjs 直接写 progress.json + total-steps + step_N_name。

2c. 更新用法说明（约第 317 行），移除 `insert-step|delete-step`：

```bash
echo "用法: update-progress.sh <init-design|design-done|append-steps|step-done|confirm-test|set-phase|touch|show> [args]" >&2
```

2d. 同步更新 JS apply() 函数中的 insert-step 和 delete-step 分支（约第 64-89 行）——删除这两段。

- [ ] **Step 3: 运行全部测试**

Run: `bash tests/run-all.sh 2>&1 | tail -10`
Expected: 全部 pass。注意 insert/delete 的旧测试（直接调 `update-progress.sh insert-step`）会失败——需要更新它们改为调用 `restructure.cjs` 或 `generate-steps.sh --insert-at`。

- [ ] **Step 4: 更新旧测试**

将 `tests/shell-scripts.test.sh` 中直接调用 `bash "$UP" insert-step` 和 `bash "$UP" delete-step` 的测试改为调用 `node "$RS"` 或 `bash "$GS" --insert-at` / `bash "$GS" --delete`。

具体：
- `update-progress: insert-step shifts steps` → 改为 `node "$RS" insert 2 "新步骤"`
- `update-progress: insert-step renumbers step_N_name files` → 同上，加 main.tsx 搭建
- `update-progress: delete-step renumbers step_N_name files` → 改为 `node "$RS" delete 2`
- `update-progress: delete-step shifts steps` → 同上
- `update-progress: delete-step promotes successor to in_progress` → 同上
- `update-progress: delete-step rejects last step` → 同上
- `restructure-pipeline: delete last step preserves trailing code` → 改为调 restructure.cjs 内部函数
- `restructure-pipeline: insert escapes quotes in stepName` → 同上

每个旧测试需要补 `mkdir -p frontend/src` + 创建 main.tsx（因为 restructure.cjs 的 insert/delete 要求 main.tsx 存在）。

- [ ] **Step 5: 运行全部测试**

Run: `bash tests/run-all.sh 2>&1 | tail -10`
Expected: 全部 pass，0 failures

- [ ] **Step 6: Commit**

```bash
git add plugins/claude/minus-creator/skills/minus-structure/scripts/generate-steps.sh \
  plugins/claude/minus-creator/scripts/update-progress.sh \
  tests/shell-scripts.test.sh
git commit -m "refactor: generate-steps.sh 改为调用 restructure.cjs + update-progress.sh 删除 insert/delete 分支"
```

---

### Task 7: 删除旧文件 + 最终验证

**Files:**
- Delete: `plugins/claude/minus-creator/skills/minus-structure/scripts/restructure-pipeline.cjs`
- Delete: `plugins/claude/minus-creator/skills/minus-structure/scripts/restructure-frontend.cjs`
- Test: `tests/shell-scripts.test.sh`

- [ ] **Step 1: 确认无其他文件引用旧脚本**

Run: `grep -rn 'restructure-pipeline\|restructure-frontend' plugins/ tests/ --include='*.sh' --include='*.md' --include='*.cjs' --include='*.js'`
Expected: 只有旧文件自身和本文件引用自身，无外部引用（generate-steps.sh 在 Task 6 已改完）

- [ ] **Step 2: 删除旧文件**

```bash
git rm plugins/claude/minus-creator/skills/minus-structure/scripts/restructure-pipeline.cjs
git rm plugins/claude/minus-creator/skills/minus-structure/scripts/restructure-frontend.cjs
```

- [ ] **Step 3: 运行全部测试**

Run: `bash tests/run-all.sh 2>&1 | tail -10`
Expected: 全部 pass，0 failures

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: 删除 restructure-pipeline.cjs 和 restructure-frontend.cjs — 逻辑已并入 restructure.cjs"
```
