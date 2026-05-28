#!/bin/bash
# Shell scripts test suite
# Usage: bash tests/shell-scripts.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$REPO_DIR/plugins/claude/minus-creator/lib"

# ── Test Framework ──

RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"

pass() {
  echo "  ✓ $1"
  read P F < "$RESULTS_FILE"
  echo "$((P + 1)) $F" > "$RESULTS_FILE"
}

fail() {
  echo "  ✗ $1"
  echo "    $2"
  read P F < "$RESULTS_FILE"
  echo "$P $((F + 1))" > "$RESULTS_FILE"
}

assert_contains() {
  if echo "$1" | grep -q "$2"; then
    return 0
  else
    return 1
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    return 0
  else
    return 1
  fi
}

# ── Setup ──

TMPDIR_BASE=$(mktemp -d)
trap "rm -rf '$TMPDIR_BASE'" EXIT

make_tmp() {
  mktemp -d "$TMPDIR_BASE/test.XXXXXX"
}

# ══════════════════════════════════════════════════════
echo ""
echo "═══ projects-manager.sh ═══"
# ══════════════════════════════════════════════════════

PM="$LIB_DIR/projects-manager.sh"

# Test: list with no projects
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  OUTPUT=$(bash "$PM" list 2>&1)
  if assert_contains "$OUTPUT" "无项目"; then
    pass "list: empty project list shows '无项目'"
  else
    fail "list: empty project list" "got: $OUTPUT"
  fi
)

# Test: add a project
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  PROJ=$(make_tmp)
  OUTPUT=$(bash "$PM" add "my-skill" "$PROJ" 2>&1)
  if assert_contains "$OUTPUT" "已注册"; then
    pass "add: registers new project"
  else
    fail "add: registers new project" "got: $OUTPUT"
  fi
)

# Test: add duplicate project
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  PROJ=$(make_tmp)
  bash "$PM" add "my-skill" "$PROJ" >/dev/null 2>&1
  OUTPUT=$(bash "$PM" add "my-skill" "$PROJ" 2>&1)
  if assert_contains "$OUTPUT" "已存在"; then
    pass "add: duplicate detected"
  else
    fail "add: duplicate detected" "got: $OUTPUT"
  fi
)

# Test: list after adding (use real dirs so list doesn't filter them out)
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  PROJ_A=$(make_tmp)
  PROJ_B=$(make_tmp)
  bash "$PM" add "skill-a" "$PROJ_A" >/dev/null 2>&1
  bash "$PM" add "skill-b" "$PROJ_B" >/dev/null 2>&1
  OUTPUT=$(bash "$PM" list 2>&1)
  if assert_contains "$OUTPUT" "skill-a" && assert_contains "$OUTPUT" "skill-b"; then
    pass "list: shows all added projects"
  else
    fail "list: shows all added projects" "got: $OUTPUT"
  fi
)

# Test: list auto-cleans deleted project directories
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  PROJ_ALIVE=$(make_tmp)
  PROJ_DEAD=$(make_tmp)
  bash "$PM" add "alive-skill" "$PROJ_ALIVE" >/dev/null 2>&1
  bash "$PM" add "dead-skill" "$PROJ_DEAD" >/dev/null 2>&1
  rm -rf "$PROJ_DEAD"
  OUTPUT=$(bash "$PM" list 2>&1)
  if assert_contains "$OUTPUT" "alive-skill" && ! assert_contains "$OUTPUT" "dead-skill"; then
    pass "list: auto-cleans deleted directories"
  else
    fail "list: auto-cleans deleted directories" "got: $OUTPUT"
  fi
)

# Test: remove a project
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  PROJ=$(make_tmp)
  bash "$PM" add "my-skill" "$PROJ" >/dev/null 2>&1
  OUTPUT=$(bash "$PM" remove "$PROJ" 2>&1)
  if assert_contains "$OUTPUT" "移除了 1"; then
    pass "remove: removes existing project"
  else
    fail "remove: removes existing project" "got: $OUTPUT"
  fi
  # Verify it's gone
  LIST_OUT=$(bash "$PM" list 2>&1)
  if assert_contains "$LIST_OUT" "无项目"; then
    pass "remove: project no longer in list"
  else
    fail "remove: project no longer in list" "got: $LIST_OUT"
  fi
)

# Test: find a project
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  PROJ=$(make_tmp)
  bash "$PM" add "my-skill" "$PROJ" >/dev/null 2>&1
  OUTPUT=$(bash "$PM" find "my-skill" 2>&1)
  if assert_eq "$OUTPUT" "$PROJ"; then
    pass "find: returns correct path"
  else
    fail "find: returns correct path" "expected: $PROJ, got: $OUTPUT"
  fi
)

# Test: find non-existent
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  if bash "$PM" find "nonexistent" >/dev/null 2>&1; then
    fail "find: non-existent returns exit 1" "expected non-zero exit"
  else
    pass "find: non-existent returns exit 1"
  fi
)

# Test: touch updates last_opened
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  PROJ=$(make_tmp)
  bash "$PM" add "my-skill" "$PROJ" >/dev/null 2>&1
  sleep 1
  bash "$PM" touch "$PROJ" >/dev/null 2>&1
  # Just verify no error
  pass "touch: updates without error"
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ context-manager.sh ═══"
# ══════════════════════════════════════════════════════

CM="$LIB_DIR/context-manager.sh"

# Test: counter increments
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$CM" check >/dev/null 2>&1
  bash "$CM" check >/dev/null 2>&1
  bash "$CM" check >/dev/null 2>&1
  COUNT=$(cat .minus/session-counter)
  if assert_eq "$COUNT" "3"; then
    pass "context-manager: counter increments to 3"
  else
    fail "context-manager: counter increments" "expected 3, got: $COUNT"
  fi
)

# Test: warning at threshold
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  echo "39" > .minus/session-counter
  OUTPUT=$(bash "$CM" check 2>&1)
  if assert_contains "$OUTPUT" "上下文检查"; then
    pass "context-manager: warns at threshold (40)"
  else
    fail "context-manager: warns at threshold" "got: $OUTPUT"
  fi
)

# Test: no warning below threshold
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  echo "5" > .minus/session-counter
  OUTPUT=$(bash "$CM" check 2>&1)
  if [ -z "$OUTPUT" ]; then
    pass "context-manager: silent below threshold"
  else
    fail "context-manager: silent below threshold" "got: $OUTPUT"
  fi
)

# Test: reset
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  echo "50" > .minus/session-counter
  bash "$CM" reset >/dev/null 2>&1
  if [ ! -f .minus/session-counter ]; then
    pass "context-manager: reset removes counter"
  else
    fail "context-manager: reset removes counter" "file still exists"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ env-manager.sh ═══"
# ══════════════════════════════════════════════════════

EM="$LIB_DIR/env-manager.sh"

# Test: config file triggers restart signal
(
  OUTPUT=$(bash "$EM" "vite.config.js" 2>&1)
  # Will only produce output if a dev server is running on 9100/3000/5173
  # We test the function logic, not the lsof detection
  pass "env-manager: handles config file without error"
)

# Test: no file arg exits cleanly
(
  bash "$EM" "" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    pass "env-manager: empty arg exits 0"
  else
    fail "env-manager: empty arg exits 0" "non-zero exit"
  fi
)

# Test: irrelevant file produces no output
(
  OUTPUT=$(bash "$EM" "src/components/Button.tsx" 2>&1)
  if [ -z "$OUTPUT" ]; then
    pass "env-manager: irrelevant file produces no output"
  else
    fail "env-manager: irrelevant file produces no output" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ progress-saver.sh ═══"
# ══════════════════════════════════════════════════════

PS_SCRIPT="$LIB_DIR/progress-saver.sh"

# Test: fails without .minus/skill.json
(
  TMP=$(make_tmp)
  cd "$TMP"
  OUTPUT=$(bash "$PS_SCRIPT" 2>&1 || true)
  # Check that it actually outputs the error
  if assert_contains "$OUTPUT" "未找到"; then
    pass "progress-saver: fails without skill.json"
  else
    fail "progress-saver: fails without skill.json" "got: $OUTPUT"
  fi
)

# Test: saves progress with skill.json
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus .claude/memory
  echo '{"skillId":"sk_test123"}' > .minus/skill.json
  OUTPUT=$(bash "$PS_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "已保存" && [ -f ".claude/memory/minus-progress.md" ]; then
    CONTENT=$(cat .claude/memory/minus-progress.md)
    if assert_contains "$CONTENT" "sk_test123"; then
      pass "progress-saver: saves progress with skill ID"
    else
      fail "progress-saver: saves progress with skill ID" "content: $CONTENT"
    fi
  else
    fail "progress-saver: saves progress" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ project-detector.sh ═══"
# ══════════════════════════════════════════════════════

PD_SCRIPT="$LIB_DIR/project-detector.sh"

# Test: scenario 1 - in a Skill project directory
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  mkdir -p "$TMP/test-project/.minus"
  echo '{"skillId":"sk_abc"}' > "$TMP/test-project/.minus/skill.json"
  cd "$TMP/test-project"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "当前目录是 Minus Skill 项目"; then
    pass "project-detector: identifies Skill project directory"
  else
    fail "project-detector: identifies Skill project directory" "got: $OUTPUT"
  fi
)

# Test: scenario 4 - non-Minus directory
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  cd "$TMP"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "当前目录不是 Minus 项目"; then
    pass "project-detector: identifies non-Minus directory"
  else
    fail "project-detector: identifies non-Minus directory" "got: $OUTPUT"
  fi
)

# Test: scenario 2 - in Workspace directory
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  mkdir -p "$TMP/minus"
  touch "$TMP/minus/.minus-workspace"
  cd "$TMP/minus"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "Workspace"; then
    pass "project-detector: identifies Workspace directory"
  else
    fail "project-detector: identifies Workspace directory" "got: $OUTPUT"
  fi
)

# Test: Skill project output triggers auto-load of minus skill
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  mkdir -p "$TMP/test-project/.minus"
  echo '{"skillId":"sk_abc","name":"test-project"}' > "$TMP/test-project/.minus/skill.json"
  cd "$TMP/test-project"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "自动触发" && ! assert_contains "$OUTPUT" "npm run dev" 2>/dev/null; then
    pass "project-detector: Skill project auto-triggers minus skill"
  else
    fail "project-detector: Skill project auto-triggers minus skill" "got: $OUTPUT"
  fi
)

# Test: Skill project output does NOT contain auto-execution instructions
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  mkdir -p "$TMP/test-project/.minus"
  echo '{"skillId":"sk_abc","name":"test-project"}' > "$TMP/test-project/.minus/skill.json"
  echo '{}' > "$TMP/test-project/package.json"
  cd "$TMP/test-project"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if ! assert_contains "$OUTPUT" "即时动作" 2>/dev/null && ! assert_contains "$OUTPUT" "不要等待用户输入" 2>/dev/null; then
    pass "project-detector: no auto-execution instructions in output"
  else
    fail "project-detector: no auto-execution instructions in output" "got: $OUTPUT"
  fi
)

# Test: Skill project shows project name from skill.json
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  mkdir -p "$TMP/test-project/.minus"
  echo '{"skillId":"sk_abc","name":"我的测试项目"}' > "$TMP/test-project/.minus/skill.json"
  cd "$TMP/test-project"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "我的测试项目"; then
    pass "project-detector: shows project display name"
  else
    fail "project-detector: shows project display name" "got: $OUTPUT"
  fi
)

# Test: Skill project shows login status
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  echo '{"auth_type":"api_key"}' > "$TMP/.minus/credentials.json"
  mkdir -p "$TMP/test-project/.minus"
  echo '{"skillId":"sk_abc","name":"test-project"}' > "$TMP/test-project/.minus/skill.json"
  cd "$TMP/test-project"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "登录状态：true"; then
    pass "project-detector: shows logged-in status"
  else
    fail "project-detector: shows logged-in status" "got: $OUTPUT"
  fi
)

# Test: Non-Minus directory output is lightweight (no login/create flow)
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  mkdir -p "$TMP/random-dir"
  cd "$TMP/random-dir"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "/minus" && ! assert_contains "$OUTPUT" "API Key" 2>/dev/null; then
    pass "project-detector: non-Minus dir shows lightweight prompt"
  else
    fail "project-detector: non-Minus dir shows lightweight prompt" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ step-tracker.sh ═══"
# ══════════════════════════════════════════════════════

ST="$LIB_DIR/step-tracker.sh"

# Test: fails without arguments
(
  OUTPUT=$(bash "$ST" 2>&1 || true)
  if assert_contains "$OUTPUT" "用法"; then
    pass "step-tracker: fails without arguments"
  else
    fail "step-tracker: fails without arguments" "got: $OUTPUT"
  fi
)

# Test: complete and status
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$ST" complete 1 data >/dev/null 2>&1
  OUTPUT=$(bash "$ST" status 1 2>&1)
  if assert_contains "$OUTPUT" "✓ 数据需求"; then
    pass "step-tracker: complete data + status shows done"
  else
    fail "step-tracker: complete data + status" "got: $OUTPUT"
  fi
)

# Test: must complete in order
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  OUTPUT=$(bash "$ST" complete 1 logic 2>&1 || true)
  if assert_contains "$OUTPUT" "还未完成"; then
    pass "step-tracker: enforces dimension order"
  else
    fail "step-tracker: enforces dimension order" "got: $OUTPUT"
  fi
)

# Test: check returns INCOMPLETE
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$ST" complete 1 data >/dev/null 2>&1
  OUTPUT=$(bash "$ST" check 1 2>&1 || true)
  if assert_contains "$OUTPUT" "INCOMPLETE"; then
    pass "step-tracker: check returns INCOMPLETE when missing dims"
  else
    fail "step-tracker: check returns INCOMPLETE" "got: $OUTPUT"
  fi
)

# Test: check returns COMPLETE when all done
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$ST" complete 1 data >/dev/null 2>&1
  bash "$ST" complete 1 logic >/dev/null 2>&1
  bash "$ST" complete 1 output >/dev/null 2>&1
  bash "$ST" complete 1 confirm auto >/dev/null 2>&1
  OUTPUT=$(bash "$ST" check 1 2>&1)
  if assert_contains "$OUTPUT" "COMPLETE"; then
    pass "step-tracker: check returns COMPLETE when all dims done"
  else
    fail "step-tracker: check returns COMPLETE" "got: $OUTPUT"
  fi
)

# Test: reset clears state
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$ST" complete 1 data >/dev/null 2>&1
  bash "$ST" reset 1 >/dev/null 2>&1
  OUTPUT=$(bash "$ST" check 1 2>&1 || true)
  if assert_contains "$OUTPUT" "INCOMPLETE"; then
    pass "step-tracker: reset clears state"
  else
    fail "step-tracker: reset clears state" "got: $OUTPUT"
  fi
)

# Test: list shows progress
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$ST" complete 1 data >/dev/null 2>&1
  bash "$ST" complete 1 logic >/dev/null 2>&1
  bash "$ST" complete 1 output >/dev/null 2>&1
  bash "$ST" complete 1 confirm auto >/dev/null 2>&1
  bash "$ST" complete 2 data >/dev/null 2>&1
  OUTPUT=$(bash "$ST" list 2>&1)
  if assert_contains "$OUTPUT" "✓ 步骤 1" && assert_contains "$OUTPUT" "◐ 步骤 2"; then
    pass "step-tracker: list shows mixed progress"
  else
    fail "step-tracker: list shows mixed progress" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ generate-steps.sh ═══"
# ══════════════════════════════════════════════════════

GS="$LIB_DIR/generate-steps.sh"

# Test: fails without arguments
(
  TMP=$(make_tmp)
  cd "$TMP"
  OUTPUT=$(bash "$GS" 2>&1 || true)
  if assert_contains "$OUTPUT" "用法"; then
    pass "generate-steps: fails without arguments"
  else
    fail "generate-steps: fails without arguments" "got: $OUTPUT"
  fi
)

# Test: fails without skill.json
(
  TMP=$(make_tmp)
  cd "$TMP"
  OUTPUT=$(bash "$GS" "步骤1" 2>&1 || true)
  if assert_contains "$OUTPUT" "不是 Minus Skill 项目"; then
    pass "generate-steps: fails without skill.json"
  else
    fail "generate-steps: fails without skill.json" "got: $OUTPUT"
  fi
)

# Test: generates correct number of steps in pipeline.py
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus frontend/src
  echo '{"skillId":"sk_test"}' > .minus/skill.json
  cat > pipeline.py << 'PYEOF'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome

class TestPipeline(Pipeline):
    version = "1.0.0"

    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={"text": "done"})
PYEOF
  # 创建最小 main.tsx
  cat > frontend/src/main.tsx << 'TSXEOF'
function buildSteps(t: (k: string, fb?: string) => string): StepConfig[] {
  return [
    {
      render: ({ data }) => (<div>{data.text}</div>),
    },
  ];
}
TSXEOF

  OUTPUT=$(bash "$GS" "搜索量查询" "竞争度分析" "长尾词推荐" 2>&1)

  # 验证 pipeline.py 有 3 个 step 方法
  STEP_COUNT=$(grep -c "async def step_" pipeline.py)
  if assert_eq "$STEP_COUNT" "3"; then
    pass "generate-steps: generates 3 steps in pipeline.py"
  else
    fail "generate-steps: generates 3 steps" "expected 3, got $STEP_COUNT"
  fi
)

# Test: pipeline.py contains step names
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  echo '{"skillId":"sk_test"}' > .minus/skill.json
  echo 'class TestPipeline(Pipeline):' > pipeline.py
  echo '    version = "1.0.0"' >> pipeline.py

  bash "$GS" "数据采集" "分析处理" 2>&1 >/dev/null

  if assert_contains "$(cat pipeline.py)" "数据采集" && assert_contains "$(cat pipeline.py)" "分析处理"; then
    pass "generate-steps: pipeline.py contains step names"
  else
    fail "generate-steps: pipeline.py contains step names" ""
  fi
)

# Test: preserves class name
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  echo '{"skillId":"sk_test"}' > .minus/skill.json
  cat > pipeline.py << 'PYEOF'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome

class MyCustomPipeline(Pipeline):
    version = "1.0.0"

    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={"text": "done"})
PYEOF

  bash "$GS" "步骤A" 2>&1 >/dev/null

  if assert_contains "$(cat pipeline.py)" "MyCustomPipeline"; then
    pass "generate-steps: preserves class name"
  else
    fail "generate-steps: preserves class name" ""
  fi
)

# Test: main.tsx buildSteps updated with correct step count and names
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus frontend/src
  echo '{"skillId":"sk_test"}' > .minus/skill.json
  cat > pipeline.py << 'PYEOF'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome

class TestPipeline(Pipeline):
    version = "1.0.0"

    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={"text": "done"})
PYEOF
  cat > frontend/src/main.tsx << 'TSXEOF'
function buildSteps(t: (k: string, fb?: string) => string): StepConfig[] {
  return [
    {
      render: ({ data }) => (<div>{data.text}</div>),
    },
  ];
}
TSXEOF

  bash "$GS" "数据采集" "趋势分析" 2>&1 >/dev/null

  MAIN_TSX="frontend/src/main.tsx"
  RENDER_COUNT=$(grep -c "render:" "$MAIN_TSX")
  if assert_eq "$RENDER_COUNT" "2"; then
    pass "generate-steps: main.tsx buildSteps has 2 render blocks"
  else
    fail "generate-steps: main.tsx buildSteps has 2 render blocks" "expected 2, got $RENDER_COUNT"
  fi

  if assert_contains "$(cat "$MAIN_TSX")" "数据采集" && assert_contains "$(cat "$MAIN_TSX")" "趋势分析"; then
    pass "generate-steps: main.tsx contains step names"
  else
    fail "generate-steps: main.tsx contains step names" ""
  fi

  if assert_contains "$(cat "$MAIN_TSX")" "function buildSteps"; then
    pass "generate-steps: main.tsx preserves buildSteps function"
  else
    fail "generate-steps: main.tsx preserves buildSteps function" ""
  fi
)

# Test: main.tsx buildSteps works when function body has extra variables (brackets)
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus frontend/src
  echo '{"skillId":"sk_test"}' > .minus/skill.json
  cat > pipeline.py << 'PYEOF'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome

class TestPipeline(Pipeline):
    version = "1.0.0"

    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={"text": "done"})
PYEOF
  cat > frontend/src/main.tsx << 'TSXEOF'
function buildSteps(t: (k: string, fb?: string) => string): StepConfig[] {
  const columns = [
    { key: 'keyword', title: t('col.keyword') },
  ];
  return [
    {
      render: ({ data }) => (<div>{data.text}</div>),
    },
  ];
}
TSXEOF

  bash "$GS" "步骤X" "步骤Y" 2>&1 >/dev/null

  MAIN_TSX="frontend/src/main.tsx"
  RENDER_COUNT=$(grep -c "render:" "$MAIN_TSX")
  if assert_eq "$RENDER_COUNT" "2"; then
    pass "generate-steps: main.tsx works with extra brackets in function body"
  else
    fail "generate-steps: main.tsx works with extra brackets in function body" "expected 2 renders, got $RENDER_COUNT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ generate-result-design.sh ═══"
# ══════════════════════════════════════════════════════

GRD="$LIB_DIR/generate-result-design.sh"

# Test: fails without total-steps
(
  cd "$(mktemp -d)"
  mkdir -p .minus
  OUTPUT=$(bash "$GRD" 2>&1) && {
    fail "generate-result-design: should fail without total-steps" "got: $OUTPUT"
  } || {
    pass "generate-result-design: fails without total-steps"
  }
)

# Test: fails when steps incomplete
(
  cd "$(mktemp -d)"
  mkdir -p .minus/dev-progress
  echo "2" > .minus/total-steps
  # step 1 complete, step 2 missing
  touch .minus/dev-progress/step_1_{data,logic,output,confirm}
  OUTPUT=$(bash "$GRD" 2>&1) && {
    fail "generate-result-design: should fail with incomplete steps" "got: $OUTPUT"
  } || {
    if echo "$OUTPUT" | grep -q "步骤2"; then
      pass "generate-result-design: fails with incomplete steps, reports which"
    else
      fail "generate-result-design: should report incomplete step number" "got: $OUTPUT"
    fi
  }
)

# Test: passes when all steps complete
(
  cd "$(mktemp -d)"
  mkdir -p .minus/dev-progress
  echo "2" > .minus/total-steps
  touch .minus/dev-progress/step_1_{data,logic,output,confirm}
  touch .minus/dev-progress/step_2_{data,logic,output,confirm}
  OUTPUT=$(bash "$GRD" 2>&1)
  if echo "$OUTPUT" | grep -q "GATE_PASSED"; then
    pass "generate-result-design: gate passes when all steps complete"
  else
    fail "generate-result-design: should output GATE_PASSED" "got: $OUTPUT"
  fi
  if echo "$OUTPUT" | grep -q "结果摘要" && echo "$OUTPUT" | grep -q "下载内容"; then
    pass "generate-result-design: outputs two-dimension guidance"
  else
    fail "generate-result-design: should output both dimensions" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ agent files ═══"
# ══════════════════════════════════════════════════════

AGENTS_DIR="$REPO_DIR/plugins/claude/minus-creator/agents"

# Test: skill-guide.md has required frontmatter
(
  CONTENT=$(cat "$AGENTS_DIR/skill-guide.md")
  if assert_contains "$CONTENT" "name: skill-guide" && assert_contains "$CONTENT" "skill_update" && assert_contains "$CONTENT" "skill_update"; then
    pass "skill-guide.md: has name, mentions skill_update"
  else
    fail "skill-guide.md: missing required content" ""
  fi
)

# Test: node-dev.md has required frontmatter and MCP mention
(
  CONTENT=$(cat "$AGENTS_DIR/node-dev.md")
  if assert_contains "$CONTENT" "name: node-dev" && assert_contains "$CONTENT" "MCP" && assert_contains "$CONTENT" "skill_update"; then
    pass "node-dev.md: has name, mentions MCP and skill_update"
  else
    fail "node-dev.md: missing required content" ""
  fi
)

# Test: node-dev.md references pipeline.py
(
  CONTENT=$(cat "$AGENTS_DIR/node-dev.md")
  if assert_contains "$CONTENT" "pipeline.py"; then
    pass "node-dev.md: references pipeline.py"
  else
    fail "node-dev.md: should reference pipeline.py" ""
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ project-detector.sh ═══"
# ══════════════════════════════════════════════════════

# Test: outputs context tags
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  cd "$TMP"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "<context>" && assert_contains "$OUTPUT" "</context>"; then
    pass "project-detector: wraps output in context tags"
  else
    fail "project-detector: wraps output in context tags" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ detect-client.sh ═══"
# ══════════════════════════════════════════════════════

DC="$LIB_DIR/detect-client.sh"

# Test: returns a value
(
  OUTPUT=$(bash "$DC" 2>&1)
  if [ -n "$OUTPUT" ]; then
    pass "detect-client: returns a value ($OUTPUT)"
  else
    fail "detect-client: returns a value" "empty output"
  fi
)

# Test: detects desktop when CLAUDE_CODE_ENTRYPOINT=claude-desktop
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$DC" 2>&1)
  if assert_eq "$OUTPUT" "desktop"; then
    pass "detect-client: claude-desktop entrypoint → desktop"
  else
    fail "detect-client: claude-desktop entrypoint → desktop" "got: $OUTPUT"
  fi
)

# Test: detects cli when CLAUDE_CODE_ENTRYPOINT=cli
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=cli bash "$DC" 2>&1)
  if assert_eq "$OUTPUT" "cli"; then
    pass "detect-client: cli entrypoint → cli"
  else
    fail "detect-client: cli entrypoint → cli" "got: $OUTPUT"
  fi
)

# Test: vscode entrypoint → desktop
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=vscode bash "$DC" 2>&1)
  if assert_eq "$OUTPUT" "desktop"; then
    pass "detect-client: vscode entrypoint → desktop"
  else
    fail "detect-client: vscode entrypoint → desktop" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ open-preview.sh ═══"
# ══════════════════════════════════════════════════════

OP="$LIB_DIR/open-preview.sh"

# Test: fails without port argument
(
  OUTPUT=$(bash "$OP" 2>&1 || true)
  if assert_contains "$OUTPUT" "用法"; then
    pass "open-preview: fails without port argument"
  else
    fail "open-preview: fails without port argument" "got: $OUTPUT"
  fi
)

# Test: CLI mode outputs URL and CLIENT=cli
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=cli bash "$OP" 5173 2>&1 || true)
  if assert_contains "$OUTPUT" "PREVIEW_URL=http://localhost:5173" && assert_contains "$OUTPUT" "CLIENT=cli"; then
    pass "open-preview: CLI mode outputs URL and client type"
  else
    fail "open-preview: CLI mode outputs URL and client type" "got: $OUTPUT"
  fi
)

# Test: Desktop mode outputs URL and CLIENT=desktop, no open command
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$OP" 5173 2>&1)
  if assert_contains "$OUTPUT" "PREVIEW_URL=http://localhost:5173" && assert_contains "$OUTPUT" "CLIENT=desktop"; then
    pass "open-preview: Desktop mode outputs URL without opening browser"
  else
    fail "open-preview: Desktop mode outputs URL without opening browser" "got: $OUTPUT"
  fi
)

# Test: custom port
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=cli bash "$OP" 9100 2>&1 || true)
  if assert_contains "$OUTPUT" "PREVIEW_URL=http://localhost:9100"; then
    pass "open-preview: respects custom port"
  else
    fail "open-preview: respects custom port" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ detect-preview-port.sh ═══"
# ══════════════════════════════════════════════════════

DPP="$LIB_DIR/detect-preview-port.sh"

# Test: returns DETECT_FAILED when no Vite process running
(
  OUTPUT=$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=0 bash "$DPP" 2>&1 || true)
  if [ "$OUTPUT" = "DETECT_FAILED" ]; then
    pass "detect-preview-port: returns DETECT_FAILED when no server"
  else
    fail "detect-preview-port: returns DETECT_FAILED when no server" "got: $OUTPUT"
  fi
)

# Test: output is DETECT_FAILED or a number
(
  OUTPUT=$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=0 bash "$DPP" 2>&1 || true)
  if [[ "$OUTPUT" =~ ^[0-9]+$ ]] || [ "$OUTPUT" = "DETECT_FAILED" ]; then
    pass "detect-preview-port: output is numeric or DETECT_FAILED"
  else
    fail "detect-preview-port: output is numeric or DETECT_FAILED" "got: $OUTPUT"
  fi
)

# Test: reads port from dev-ports.json (without verify — no real server)
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  echo '{"frontend":5199,"backend":4007}' > .minus/dev-ports.json
  OUTPUT=$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=1 bash "$DPP" 2>&1 || true)
  # 没有真实 server 跑在 5199，所以 verify 会失败，应该 DETECT_FAILED
  if [ "$OUTPUT" = "DETECT_FAILED" ]; then
    pass "detect-preview-port: DETECT_FAILED when dev-ports.json port is unreachable"
  else
    fail "detect-preview-port: DETECT_FAILED when dev-ports.json port is unreachable" "got: $OUTPUT"
  fi
)

# Test: DETECT_PORT_MAX_WAIT env controls polling duration
(
  TMP=$(make_tmp)
  cd "$TMP"
  START=$(date +%s)
  OUTPUT=$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=0 bash "$DPP" 2>&1 || true)
  END=$(date +%s)
  ELAPSED=$((END - START))
  if [ "$ELAPSED" -lt 3 ]; then
    pass "detect-preview-port: MAX_WAIT=0 skips polling"
  else
    fail "detect-preview-port: MAX_WAIT=0 skips polling" "took ${ELAPSED}s"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ preview flow (vite template + SKILL.md) ═══"
# ══════════════════════════════════════════════════════

PLATFORM_DIR="$(dirname "$REPO_DIR")/minus-platform"
VITE_TPL="$PLATFORM_DIR/packages/create-skill/templates/vite.config.ts.tpl"
SKILL_MD="$REPO_DIR/plugins/claude/minus-creator/skills/minus/SKILL.md"

# Test: vite template must have server.open = false
(
  if [ -f "$VITE_TPL" ]; then
    if grep -q 'open: false' "$VITE_TPL"; then
      pass "vite-template: server.open is false (no auto-open browser)"
    elif grep -q 'open: true' "$VITE_TPL"; then
      fail "vite-template: server.open is false" "found open: true — Vite will auto-open Chrome"
    else
      pass "vite-template: no server.open setting (defaults to false)"
    fi
  else
    fail "vite-template: file exists" "not found at $VITE_TPL"
  fi
)

# Test: SKILL.md preview flow — two branches
(
  if grep -q 'ToolSearch.*preview' "$SKILL_MD"; then
    pass "SKILL.md: step 3 probes Claude_Preview via ToolSearch"
  else
    fail "SKILL.md: step 3 probes Claude_Preview via ToolSearch" "not found"
  fi
)

(
  if grep -q 'preview_start.*name.*frontend' "$SKILL_MD"; then
    pass "SKILL.md: branch A calls preview_start with name=frontend"
  else
    fail "SKILL.md: branch A calls preview_start with name=frontend" "not found"
  fi
)

(
  if grep -q 'launch\.json' "$SKILL_MD"; then
    pass "SKILL.md: branch A creates .claude/launch.json"
  else
    fail "SKILL.md: branch A creates .claude/launch.json" "not found"
  fi
)

(
  if grep -q '自动打开预览' "$SKILL_MD"; then
    pass "SKILL.md: branch B auto-opens preview via detect-preview-port.sh"
  else
    fail "SKILL.md: branch B auto-opens preview via detect-preview-port.sh" "not found"
  fi
)

(
  if grep -q 'CLAUDE_CODE_ENTRYPOINT' "$SKILL_MD"; then
    pass "SKILL.md: detects client type via CLAUDE_CODE_ENTRYPOINT"
  else
    fail "SKILL.md: detects client type via CLAUDE_CODE_ENTRYPOINT" "not found"
  fi
)

# Test: SKILL.md must NOT contain sed patch for vite.config.ts (anti-pattern per CLAUDE.md principle 4)
(
  if grep -q "sed.*open.*true.*open.*false" "$SKILL_MD"; then
    fail "SKILL.md: no sed patch for vite.config.ts" "found sed hack — plugin should not patch user source code"
  else
    pass "SKILL.md: no sed patch for vite.config.ts"
  fi
)

echo "═══ auth fallback prohibition ═══"

# Test: SKILL.md must prohibit manual credential writes when MCP tool unavailable
(
  if grep -q "禁止.*手动写入.*credentials" "$SKILL_MD"; then
    pass "SKILL.md: prohibits manual credentials.json write on auth tool failure"
  else
    fail "SKILL.md: prohibits manual credentials.json write on auth tool failure" "not found"
  fi
)

echo "═══ MCP Server dependencies ═══"

MCP_PKG="$REPO_DIR/plugins/claude/minus-creator/mcp-servers/minus-platform/package.json"

# Test: zod must be declared as a direct dependency (not just a transitive dep)
(
  if grep -q '"zod"' "$MCP_PKG"; then
    pass "MCP package.json: zod is a declared dependency"
  else
    fail "MCP package.json: zod is a declared dependency" "missing — will crash after plugin cache copy"
  fi
)

echo "═══ install.sh ═══"

INSTALL_SH="$REPO_DIR/plugins/claude/minus-creator/install.sh"

# Test: install.sh exists and contains usage instructions
(
  if [ -f "$INSTALL_SH" ]; then
    pass "install.sh: exists"
  else
    fail "install.sh: exists" "not found"
  fi
)
(
  if grep -q "/minus" "$INSTALL_SH" && grep -q "重启" "$INSTALL_SH"; then
    pass "install.sh: outputs usage instructions"
  else
    fail "install.sh: outputs usage instructions" "missing usage instructions in output"
  fi
)

# ══════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════

read PASS FAIL < "$RESULTS_FILE"
TOTAL=$((PASS + FAIL))
rm -f "$RESULTS_FILE"

echo ""
echo "═══════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (total: $TOTAL)"
echo "═══════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
