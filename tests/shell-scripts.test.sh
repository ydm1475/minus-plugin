#!/bin/bash
# Shell scripts test suite
# Usage: bash tests/shell-scripts.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$REPO_DIR/plugins/claude/minus-creator/lib"

# ── Test Framework ──

RESULTS_FILE=$(mktemp)
echo "0 0 0" > "$RESULTS_FILE"

pass() {
  echo "  ✓ $1"
  read P F S < "$RESULTS_FILE"
  echo "$((P + 1)) $F $S" > "$RESULTS_FILE"
}

fail() {
  echo "  ✗ $1"
  echo "    $2"
  read P F S < "$RESULTS_FILE"
  echo "$P $((F + 1)) $S" > "$RESULTS_FILE"
}

# 跳过：测试前提在本机无法成立（如「无可用 node」却本机系统路径确有新 node）。
# 不计为失败，但单独计数透出，避免悄悄掩盖。
skip() {
  echo "  ○ $1 (skipped: $2)"
  read P F S < "$RESULTS_FILE"
  echo "$P $F $((S + 1))" > "$RESULTS_FILE"
}

# 本机在 resolve-node.sh/launch.sh 探测的「绝对系统路径」上是否已有 >=18 node。
# 这些路径（/usr/local/bin、/opt/homebrew/bin、~/.volta、~/.nvm）绕过 PATH，
# 故「PATH=/usr/bin:/bin 模拟无 node」在这类机器上不成立——对应测试应 skip 而非 fail。
host_has_abs_modern_node() {
  for c in /usr/local/bin/node /opt/homebrew/bin/node \
           "$HOME"/.volta/tools/image/node/*/bin/node "$HOME"/.volta/bin/node \
           "$HOME"/.nvm/versions/node/*/bin/node; do
    [ -x "$c" ] || continue
    m=$("$c" -p "process.versions.node.split('.')[0]" 2>/dev/null) || continue
    [ -n "$m" ] && [ "$m" -ge 18 ] 2>/dev/null && return 0
  done
  return 1
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

TEST_PYTHON="/Users/tutu/minus/CLI-create/.venv/bin/python"
if [ ! -x "$TEST_PYTHON" ]; then
  TEST_PYTHON=$(find "$HOME/.local/share/uv/python" -path '*/bin/python3.12' -type f -perm +111 2>/dev/null | head -1 || true)
fi
if [ -z "$TEST_PYTHON" ] || [ ! -x "$TEST_PYTHON" ]; then
  TEST_PYTHON=$(find "$HOME/.local/share/uv/python" -path '*/bin/python3.12' -type f 2>/dev/null | head -1 || true)
fi
if [ -z "$TEST_PYTHON" ] || [ ! -x "$TEST_PYTHON" ]; then
  TEST_PYTHON=$(command -v python3 || true)
fi

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
  if assert_contains "$OUTPUT" "默认入口" \
     && assert_contains "$OUTPUT" "minus-creator:minus" \
     && assert_contains "$OUTPUT" "不要直接按普通代码任务修改项目文件" \
     && ! assert_contains "$OUTPUT" "npm run dev" 2>/dev/null; then
    pass "project-detector: Skill project auto-triggers minus skill"
  else
    fail "project-detector: Skill project auto-triggers minus skill" "got: $OUTPUT"
  fi
)

# Test: Skill project output includes project root and Creator workflow scope
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  mkdir -p "$TMP/.minus"
  mkdir -p "$TMP/test-project/.minus"
  echo '{"skillId":"sk_abc","name":"test-project"}' > "$TMP/test-project/.minus/skill.json"
  cd "$TMP/test-project"
  OUTPUT=$(bash "$PD_SCRIPT" 2>&1)
  if assert_contains "$OUTPUT" "项目根目录：$TMP/test-project" \
     && assert_contains "$OUTPUT" "Skill 输入、步骤、pipeline、前端步骤渲染、测试或发布"; then
    pass "project-detector: Skill project declares root and workflow scope"
  else
    fail "project-detector: Skill project should declare root and workflow scope" "got: $OUTPUT"
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

# Test: logic mode defaults to deterministic for backward compatibility
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$ST" complete 1 data >/dev/null 2>&1
  bash "$ST" complete 1 logic >/dev/null 2>&1
  MODE=$(cat .minus/dev-progress/step_1_logic_mode)
  if [ "$MODE" = "deterministic" ]; then
    pass "step-tracker: logic defaults to deterministic for old calls"
  else
    fail "step-tracker: default logic mode" "expected deterministic, got: $MODE"
  fi
)

# Test: explicit llm mode persists and status displays it
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$ST" complete 1 data >/dev/null 2>&1
  bash "$ST" complete 1 logic llm >/dev/null 2>&1
  OUTPUT=$(bash "$ST" status 1 2>&1)
  if [ "$(cat .minus/dev-progress/step_1_logic_mode)" = "llm" ] \
     && assert_contains "$OUTPUT" "模式: llm"; then
    pass "step-tracker: explicit llm mode persists and appears in status"
  else
    fail "step-tracker: llm mode persistence" "got: $OUTPUT"
  fi
)

# Test: invalid logic mode is rejected
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$ST" complete 1 data >/dev/null 2>&1
  OUTPUT=$(bash "$ST" complete 1 logic auto 2>&1 || true)
  if assert_contains "$OUTPUT" "logic 模式必须是 deterministic 或 llm"; then
    pass "step-tracker: rejects invalid logic mode"
  else
    fail "step-tracker: invalid logic mode should fail" "got: $OUTPUT"
  fi
)

# Test: reset clears the persisted logic mode
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  bash "$ST" complete 1 data >/dev/null 2>&1
  bash "$ST" complete 1 logic llm >/dev/null 2>&1
  bash "$ST" reset 1 >/dev/null 2>&1
  if [ ! -f .minus/dev-progress/step_1_logic_mode ]; then
    pass "step-tracker: reset clears logic mode"
  else
    fail "step-tracker: reset should clear logic mode" "logic mode file still exists"
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

# Test: generate-node-code exposes llm mode to the code-generation stage
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  echo 1 > .minus/total-steps
  bash "$ST" complete 1 data >/dev/null 2>&1
  bash "$ST" complete 1 logic llm >/dev/null 2>&1
  bash "$ST" complete 1 output >/dev/null 2>&1
  bash "$ST" complete 1 confirm auto >/dev/null 2>&1
  OUTPUT=$(bash "$LIB_DIR/generate-node-code.sh" 1 2>&1)
  if assert_contains "$OUTPUT" "LOGIC_MODE=llm" \
     && assert_contains "$OUTPUT" "LLM_REQUIRED=YES" \
     && assert_contains "$OUTPUT" "使用 SDK 内置 LLM 能力"; then
    pass "generate-node-code: llm mode emits LLM_REQUIRED guidance"
  else
    fail "generate-node-code: llm mode guidance" "got: $OUTPUT"
  fi
)

# Test: interactive code generation explains persisted hidden finalize summaries
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  echo 2 > .minus/total-steps
  bash "$ST" complete 1 data >/dev/null 2>&1
  bash "$ST" complete 1 logic deterministic >/dev/null 2>&1
  bash "$ST" complete 1 output >/dev/null 2>&1
  bash "$ST" complete 1 confirm interactive >/dev/null 2>&1
  OUTPUT=$(bash "$LIB_DIR/generate-node-code.sh" 1 2>&1)
  if assert_contains "$OUTPUT" "frontend-guide.md" \
     && assert_contains "$OUTPUT" "隐藏 finalize 摘要" \
     && assert_contains "$OUTPUT" "不在这里重复定义 UI 契约"; then
    pass "generate-node-code: interactive template points summary finalize to platform docs"
  else
    fail "generate-node-code: summary finalize docs pointer" "got: $OUTPUT"
  fi
)

# Test: code generation gate rejects silent placeholder degradation
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .minus
  echo 1 > .minus/total-steps
  bash "$ST" complete 1 data >/dev/null 2>&1
  bash "$ST" complete 1 logic deterministic >/dev/null 2>&1
  bash "$ST" complete 1 output >/dev/null 2>&1
  bash "$ST" complete 1 confirm auto >/dev/null 2>&1
  printf '%s\n' 'class Demo:' '    async def step_1(self, ctx):' '        return StepOutcome.complete(payload={"rows": []})' > pipeline.py
  OUTPUT=$(bash "$LIB_DIR/generate-node-code.sh" 1 2>&1)
  if assert_contains "$OUTPUT" "真实接口或计算来源" \
     && assert_contains "$OUTPUT" "尚未接入真实数据来源" \
     && assert_contains "$OUTPUT" "重新核对全部展示字段"; then
    pass "generate-node-code: emits data-contract completeness checks"
  else
    fail "generate-node-code: data-contract completeness checks" "got: $OUTPUT"
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
  if echo "$OUTPUT" | grep -q "Skill 运行结束后，结果页底部会有一段摘要来总结分析结论。" \
     && echo "$OUTPUT" | grep -q "这段摘要由大模型在运行时基于实际数据自动生成，还是你来定义模板？"; then
    pass "generate-result-design: asks whether bottom summary uses runtime LLM or creator template"
  else
    fail "generate-result-design: should ask runtime LLM vs creator template" "got: $OUTPUT"
  fi
  if echo "$OUTPUT" | grep -q "动态生成需要确认的问题" \
     && echo "$OUTPUT" | grep -q "禁止照搬固定问题清单" \
     && echo "$OUTPUT" | grep -q "只有 Creator 明确确认后，才能继续进入下载内容"; then
    pass "generate-result-design: runtime LLM summary requires dynamic creator confirmation"
  else
    fail "generate-result-design: runtime LLM summary should require dynamic confirmation" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ check-python-deps.sh ═══"
# ══════════════════════════════════════════════════════

CPD="$LIB_DIR/check-python-deps.sh"

write_pyproject() {
  local file="$1"
  local deps="$2"
  cat > "$file" <<EOF
[project]
name = "test-skill"
version = "1.0.0"
dependencies = [
    "minus-ai-sdk-python",
    "python-dotenv",
    "uvicorn[standard]"$deps
]
EOF
}

# Test: missing third-party dependency is rejected
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .venv/bin
  ln -s "$TEST_PYTHON" .venv/bin/python
  cat > pipeline.py <<'PY'
from openpyxl import Workbook
from minus_ai_sdk import Pipeline
PY
  write_pyproject pyproject.toml ""
  OUTPUT=$(bash "$CPD" 2>&1 || true)
  if assert_contains "$OUTPUT" "未声明的 Python 依赖" \
     && assert_contains "$OUTPUT" "openpyxl" \
     && assert_contains "$OUTPUT" "Agent 必须先把缺失依赖加入 pyproject.toml" \
     && assert_contains "$OUTPUT" "禁止把这个修复交给 Creator 手动处理"; then
    pass "check-python-deps: rejects missing third-party dependency"
  else
    fail "check-python-deps: should reject missing openpyxl" "got: $OUTPUT"
  fi
)

# Test: declared dependency passes import scan when pipeline imports no unavailable runtime package
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .venv/bin
  ln -s "$TEST_PYTHON" .venv/bin/python
  cat > pipeline.py <<'PY'
import datetime
from io import BytesIO
PY
  write_pyproject pyproject.toml ""
  OUTPUT=$(bash "$CPD" 2>&1)
  if assert_contains "$OUTPUT" "DEPENDENCIES_OK"; then
    pass "check-python-deps: allows stdlib imports"
  else
    fail "check-python-deps: stdlib imports should pass" "got: $OUTPUT"
  fi
)

# Test: import/package name mapping works
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .venv/bin
  ln -s "$TEST_PYTHON" .venv/bin/python
  mkdir -p PIL
  touch PIL/__init__.py
  cat > pipeline.py <<'PY'
from PIL import Image
PY
  write_pyproject pyproject.toml ',
    "pillow"'
  OUTPUT=$(bash "$CPD" 2>&1 || true)
  if ! assert_contains "$OUTPUT" "未声明的 Python 依赖" 2>/dev/null; then
    pass "check-python-deps: maps PIL import to pillow dependency"
  else
    fail "check-python-deps: PIL should be satisfied by pillow" "got: $OUTPUT"
  fi
)

# Test: missing project venv is rejected
(
  TMP=$(make_tmp)
  cd "$TMP"
  cat > pipeline.py <<'PY'
import datetime
PY
  write_pyproject pyproject.toml ""
  OUTPUT=$(bash "$CPD" 2>&1 || true)
  if assert_contains "$OUTPUT" "未找到项目虚拟环境 Python"; then
    pass "check-python-deps: rejects missing project venv"
  else
    fail "check-python-deps: should reject missing project venv" "got: $OUTPUT"
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

# Test: node-dev.md keeps frontend SDK usage on documented stable APIs
(
  CONTENT=$(cat "$AGENTS_DIR/node-dev.md")
  if assert_contains "$CONTENT" "extendConfirmed" \
     && assert_contains "$CONTENT" "禁止通过遍历用户目录" \
     && assert_contains "$CONTENT" "禁止在尚未接入真实数据来源时"; then
    pass "node-dev.md: uses extendConfirmed and prohibits undocumented fallback guessing"
  else
    fail "node-dev.md: should document stable frontend API usage and data completeness" ""
  fi
)

# Test: node-dev.md prohibits unrequested overview/summary cards
(
  CONTENT=$(cat "$AGENTS_DIR/node-dev.md")
  if assert_contains "$CONTENT" "禁止自动补展示内容" \
     && assert_contains "$CONTENT" "Creator 只说\"表格\"就只生成表格" \
     && assert_contains "$CONTENT" "接口返回字段、计算中间值、排序依据、调试信息，都不是默认展示内容"; then
    pass "node-dev.md: prohibits unrequested overview cards"
  else
    fail "node-dev.md: should prohibit unrequested overview cards" ""
  fi
)

# Test: node-dev.md reminds Creator how to test after step implementation
(
  CONTENT=$(cat "$AGENTS_DIR/node-dev.md")
  if assert_contains "$CONTENT" "重新输入测试数据开始一次新的流程" \
     && assert_contains "$CONTENT" "点击【重新执行】按钮" \
     && assert_contains "$CONTENT" "用同一份输入重新跑一遍流程" \
     && assert_contains "$CONTENT" "看完如果没问题，我们继续开发步骤 {next_step_number}「{next_step_name}」吗？" \
     && assert_contains "$CONTENT" "看完如果没问题，我们继续进入结果呈现设计"; then
    pass "node-dev.md: step completion includes test reminder"
  else
    fail "node-dev.md: should include step completion test reminder" ""
  fi
)

# Test: node-dev.md makes Agent responsible for dependency fixes
(
  CONTENT=$(cat "$AGENTS_DIR/node-dev.md")
  if assert_contains "$CONTENT" "Agent 必须自己更新 \`pyproject.toml\`" \
     && assert_contains "$CONTENT" "禁止把依赖修复交给 Creator 手动处理" \
     && assert_contains "$CONTENT" "通过前不要让 Creator 测试"; then
    pass "node-dev.md: Agent owns dependency fixes"
  else
    fail "node-dev.md: should make Agent responsible for dependency fixes" ""
  fi
)

# Test: generate-result-design.sh makes Agent responsible for dependency fixes
(
  CONTENT=$(cat "$LIB_DIR/generate-result-design.sh")
  if assert_contains "$CONTENT" "Agent 必须自己更新 pyproject.toml" \
     && assert_contains "$CONTENT" "禁止把依赖修复交给 Creator 手动处理" \
     && assert_contains "$CONTENT" "通过前不要让 Creator 测试"; then
    pass "generate-result-design: Agent owns dependency fixes"
  else
    fail "generate-result-design: should make Agent responsible for dependency fixes" ""
  fi
)

# Test: generate-node-code.sh display template prohibits unrequested overview cards
(
  CONTENT=$(cat "$LIB_DIR/generate-node-code.sh")
  if assert_contains "$CONTENT" "只渲染 Creator 在输出定义阶段明确确认的展示内容" \
     && assert_contains "$CONTENT" "接口返回字段、计算中间值、排序依据、调试信息，都不是默认展示内容" \
     && assert_contains "$CONTENT" "Creator 未明确要求概览、摘要、统计卡片或顶部汇总时"; then
    pass "generate-node-code: display template prohibits unrequested overview cards"
  else
    fail "generate-node-code: should prohibit unrequested overview cards" ""
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
echo "═══ generate-next-steps.sh ═══"
# ══════════════════════════════════════════════════════

GNS="$LIB_DIR/generate-next-steps.sh"

# Test: fails without project name argument
(
  OUTPUT=$(bash "$GNS" 2>&1) && RC=0 || RC=$?
  if [ "$RC" -ne 0 ] && echo "$OUTPUT" | grep -q "缺少项目名称"; then
    pass "generate-next-steps: fails without project name"
  else
    fail "generate-next-steps: fails without project name" "rc=$RC got: $OUTPUT"
  fi
)

# Test: cli 入口（无真实路径）→ 回退 ~/minus/{name}，不含图片/选文件夹文案。
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=cli bash "$GNS" "竞品分析_SKILL" 2>&1)
  if echo "$OUTPUT" | grep -q 'cd ~/minus/"竞品分析_SKILL" && claude' \
     && ! echo "$OUTPUT" | grep -q '!\[' \
     && ! echo "$OUTPUT" | grep -q "选择 .*文件夹作为工作目录"; then
    pass "generate-next-steps: cli 无路径 → 回退 ~/minus/{name}"
  else
    fail "generate-next-steps: cli 回退文案" "got: $OUTPUT"
  fi
)

# Test: cli 入口（有真实 targetDir）→ cd 用真实绝对路径并加引号，不再硬编码 ~/minus。
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=cli bash "$GNS" "竞品分析_SKILL" "/custom/work/竞品分析_SKILL" 2>&1)
  if echo "$OUTPUT" | grep -q 'cd "/custom/work/竞品分析_SKILL" && claude' \
     && ! echo "$OUTPUT" | grep -q "~/minus"; then
    pass "generate-next-steps: cli 有 targetDir → cd 真实路径，无 ~/minus 硬编码"
  else
    fail "generate-next-steps: cli 真实路径" "got: $OUTPUT"
  fi
)

# Test: 真实路径在 $HOME 下 → 展示折叠成 ~（desktop 文案可读性）。
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$GNS" "竞品分析_SKILL" "$HOME/minus/竞品分析_SKILL" 2>&1)
  if echo "$OUTPUT" | grep -q "选择 \`~/minus/竞品分析_SKILL\`"; then
    pass "generate-next-steps: \$HOME 下真实路径 → 折叠成 ~"
  else
    fail "generate-next-steps: ~ 折叠" "got: $OUTPUT"
  fi
)

# Test: Windows 真实路径 → 原样显示，绝不伪造 ~/minus（核心跨平台修复）。
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$GNS" "竞品分析_SKILL" "C:/Users/wangshu/projects/竞品分析_SKILL" 2>&1)
  if echo "$OUTPUT" | grep -q "选择 \`C:/Users/wangshu/projects/竞品分析_SKILL\`" \
     && ! echo "$OUTPUT" | grep -q "~/minus"; then
    pass "generate-next-steps: Windows 真实路径原样显示，不伪造 ~/minus"
  else
    fail "generate-next-steps: Windows 路径" "got: $OUTPUT"
  fi
)

# Test: desktop 入口 → 引导文案 + 两张操作截图外链（markdown 图片），无 cd 命令。
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$GNS" "竞品分析_SKILL" 2>&1)
  if echo "$OUTPUT" | grep -q "项目已创建" \
     && echo "$OUTPUT" | grep -q "https://i.postimg.cc/vBBxtGWW/start.png" \
     && echo "$OUTPUT" | grep -q "https://i.postimg.cc/sxrZtqqq/guide.png" \
     && echo "$OUTPUT" | grep -q "~/minus/竞品分析_SKILL" \
     && [ "$(echo "$OUTPUT" | grep -c "点击下图可查看操作示意")" -eq 2 ] \
     && ! echo "$OUTPUT" | grep -q "cd ~/minus/竞品分析_SKILL && claude"; then
    pass "generate-next-steps: desktop → 文案 + 两张截图外链 + 两处备注，无 cd 命令"
  else
    fail "generate-next-steps: desktop 文案" "got: $OUTPUT"
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
echo "═══ bootstrap-env.sh ═══"
# ══════════════════════════════════════════════════════

BS="$LIB_DIR/bootstrap-env.sh"
SKILL_MD="$REPO_DIR/plugins/claude/minus-creator/skills/minus/SKILL.md"

# Helper: write an executable stub into a dir
write_stub() {
  # $1=dir $2=name $3=body
  printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"
  chmod +x "$1/$2"
}

# Test: exists and executable
(
  if [ -f "$BS" ] && [ -x "$BS" ]; then
    pass "bootstrap-env: exists and is executable"
  else
    fail "bootstrap-env: exists and is executable" "missing or not executable"
  fi
)

# Test: passes bash syntax check
(
  if bash -n "$BS" 2>/dev/null; then
    pass "bootstrap-env: passes bash -n syntax check"
  else
    fail "bootstrap-env: passes bash -n syntax check" "syntax error"
  fi
)

# Test: 版本单源——toolchain.sh 存在且 bootstrap source 了它（不在 bootstrap 内联版本号）
(
  TC="$(dirname "$BS")/toolchain.sh"
  if [ -f "$TC" ] && grep -q 'NODE_TARGET=' "$TC" && grep -q 'NODE_FLOOR=' "$TC" \
     && grep -q 'NODE_RUNTIME_FLOOR=' "$TC" \
     && grep -q 'toolchain.sh' "$BS" && grep -qE '\.[[:space:]]+"\$TOOLCHAIN_SH"' "$BS"; then
    pass "bootstrap-env: 版本单源于 toolchain.sh 并被 source"
  else
    fail "bootstrap-env: 版本单源 toolchain.sh" "toolchain.sh 缺失/缺字段 或 bootstrap 未 source"
  fi
)

# Test: 跨仓 major 一致——create-skill（minus-platform 独立包）的 NODE_MAJOR_FLOOR
# 必须等于 toolchain.sh 的 NODE_TARGET。两仓各自写死同一 24，无运行时耦合，靠此测试守住。
# create-skill 是独立 npm 包，CI 单仓时通常不在场 → skip（不 fail）。
(
  TC="$LIB_DIR/toolchain.sh"
  CS="$REPO_DIR/../minus-platform/packages/create-skill/index.mjs"
  if [ ! -f "$CS" ]; then
    skip "create-skill major 与 toolchain.sh NODE_TARGET 一致" "未找到并列的 minus-platform/create-skill"
  else
    TGT=$(grep -E '^NODE_TARGET=[0-9]+' "$TC" | head -1 | sed 's/[^0-9]//g')
    FLOOR=$(grep -oE 'NODE_MAJOR_FLOOR[[:space:]]*=[[:space:]]*[0-9]+' "$CS" | head -1 | sed 's/[^0-9]//g')
    if [ -n "$TGT" ] && [ "$TGT" = "$FLOOR" ]; then
      pass "create-skill NODE_MAJOR_FLOOR ($FLOOR) == toolchain.sh NODE_TARGET ($TGT)"
    else
      fail "create-skill major 与 toolchain.sh NODE_TARGET 一致" "NODE_TARGET=$TGT 但 create-skill NODE_MAJOR_FLOOR=$FLOOR"
    fi
  fi
)

# Test: build.mjs 的 banner 版本号也单源 toolchain.sh（读 NODE_RUNTIME_FLOOR / NODE_TARGET）
(
  BUILD_MJS="$REPO_DIR/plugins/claude/minus-creator/mcp-servers/minus-platform/build.mjs"
  if [ -f "$BUILD_MJS" ] \
     && grep -q 'toolchain.sh' "$BUILD_MJS" \
     && grep -q 'NODE_RUNTIME_FLOOR' "$BUILD_MJS" \
     && grep -q 'NODE_TARGET' "$BUILD_MJS" \
     && ! grep -qE 'MIN_MAJOR = 1[0-9];' "$BUILD_MJS"; then
    pass "build.mjs: banner 版本单源 toolchain.sh，无内联字面量"
  else
    fail "build.mjs: banner 单源" "未读 toolchain.sh 或仍内联 MIN_MAJOR 字面量"
  fi
)

# Test: Node < 24 且无法装 Volta（curl 失败）→ 升级失败 NODE_TOO_OLD，绝不放行旧 Node
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v18.16.0;; -p) echo 18;; *) echo 18;; esac'
  write_stub "$SB" npm "echo called >> $TMP/npm.log"
  write_stub "$SB" curl 'exit 1'
  : > "$TMP/npm.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=failed reason=NODE_TOO_OLD" && [ ! -s "$TMP/npm.log" ]; then
    pass "bootstrap-env: Node<24 + Volta 装不上 → NODE_TOO_OLD，不放行旧 Node、不碰 pnpm"
  else
    fail "bootstrap-env: Node<24 → NODE_TOO_OLD" "out: $OUTPUT; npm.log: $(cat "$TMP/npm.log")"
  fi
)

# Test: 现有 Node >= 24 → 直接放行，不触发 Volta 安装
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm 'exit 0'
  write_stub "$SB" pnpm 'echo 11.4.0'
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "Node/npm 已就绪" && ! assert_contains "$OUTPUT" "通过 Volta"; then
    pass "bootstrap-env: 现有 Node>=24 直接放行，不装 Volta"
  else
    fail "bootstrap-env: Node>=24 放行" "got: $OUTPUT"
  fi
)

# Test: 系统 node 为 v22，但 Volta 已装 node24（在 ~/.volta/bin、不在初始 PATH）
# → ensure_node 起手先 volta_on_path 顶前，命中已装 node24 直接放行，绝不重跑 volta install node。
# 回归本机场景：Desktop spawn 的继承 PATH 里 node@22 在前、~/.volta/bin 缺席；
# 不在 node_major_ok 之前 prepend，就会每次撞 node22、空转重配（并连累后续 pnpm）。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/.volta/bin" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  # 继承 PATH 上的 node 是旧 v22
  write_stub "$SB" node 'case "$1" in -v) echo v22.22.3;; -p) echo 22;; *) echo 22;; esac'
  write_stub "$SB" npm 'exit 0'
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  # Volta 管理的 node24 / pnpm 落在 ~/.volta/bin（不在初始 PATH）
  write_stub "$TMP/.volta/bin" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$TMP/.volta/bin" npm 'exit 0'
  write_stub "$TMP/.volta/bin" pnpm 'echo 11.4.0'
  write_stub "$TMP/.volta/bin" volta "echo \"volta \$*\" >> $TMP/volta.log; exit 0"
  : > "$TMP/volta.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "Node/npm 已就绪" \
     && ! assert_contains "$OUTPUT" "通过 Volta 安装并选中 Node" \
     && ! assert_contains "$(cat "$TMP/volta.log")" "install node"; then
    pass "bootstrap-env: 系统 node22 但 Volta 已装 node24 → 起手顶前复用，不重配"
  else
    fail "bootstrap-env: node24 已装应复用不重配" "out: $OUTPUT; volta.log: $(cat "$TMP/volta.log")"
  fi
)

# Test: all tools + deps present → BOOTSTRAP_RESULT=ok, no install attempted
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm "echo called >> $TMP/npm.log"
  write_stub "$SB" pnpm 'echo 11.4.0'
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  : > "$TMP/npm.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=ok" && [ ! -s "$TMP/npm.log" ]; then
    pass "bootstrap-env: all present → ok, skips install (npm not called)"
  else
    fail "bootstrap-env: all present → ok, skips install" "result/npm.log mismatch; out: $OUTPUT; npm.log: $(cat "$TMP/npm.log")"
  fi
)

# Test: Node18 在升级失败时早早 finish_fail，绝不退回去碰 pnpm / corepack
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v18.16.0;; -p) echo 18;; *) echo 18;; esac'
  write_stub "$SB" npm "echo \"npm \$*\" >> $TMP/npm.log; exit 0"
  write_stub "$SB" pnpm 'echo 11.4.0'
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  write_stub "$SB" curl 'exit 1'
  write_stub "$SB" corepack "echo corepack >> $TMP/corepack.log"
  : > "$TMP/npm.log"; : > "$TMP/corepack.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "reason=NODE_TOO_OLD" && [ ! -s "$TMP/npm.log" ] && [ ! -s "$TMP/corepack.log" ]; then
    pass "bootstrap-env: Node18 升级失败即停，绝不碰 pnpm / corepack"
  else
    fail "bootstrap-env: Node18 升级失败即停" "out: $OUTPUT; npm.log: $(cat "$TMP/npm.log"); corepack.log: $(cat "$TMP/corepack.log")"
  fi
)

# Test: pnpm 被 pin 死版本，绝不用 @latest（浮动版本会随时间漂到未验证 pnpm 上踩雷）
# 版本号现单源于 toolchain.sh（PNPM_TARGET），bootstrap 仅引用、不再内联字面量。
(
  TC="$(dirname "$BS")/toolchain.sh"
  if grep -qE 'PNPM_TARGET=[0-9]' "$TC" && ! grep -q 'pnpm@latest' "$BS"; then
    pass "bootstrap-env: pnpm pin 死版本（单源 toolchain.sh），无 pnpm@latest"
  else
    fail "bootstrap-env: pnpm pin 死版本" "toolchain.sh 缺 PNPM_TARGET 字面量 或 bootstrap 用了 pnpm@latest"
  fi
)

# Test: 已装 pnpm 但版本 != pin → 切到 pin 版本（优先 Volta）
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm 'exit 0'
  write_stub "$SB" pnpm 'echo 9.1.0'
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  write_stub "$SB" volta "echo \"volta \$*\" >> $TMP/volta.log; exit 0"
  : > "$TMP/volta.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "切换到 pin 版本" && assert_contains "$(cat "$TMP/volta.log")" "install pnpm@11.4.0"; then
    pass "bootstrap-env: pnpm 版本不符 → 经 Volta 切到 pin 版本"
  else
    fail "bootstrap-env: pnpm 切到 pin 版本" "out: $OUTPUT; volta.log: $(cat "$TMP/volta.log")"
  fi
)

# Test: Volta 已装但不在 PATH + pnpm≠pin + npm 失败 → 经 Volta 装上 pin、npm 未被调用
# 复现本机场景：Volta shim 在 ~/.volta/bin 却不在 PATH，npm 全局目录不可写（exit 1）。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/.volta/bin" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm "echo \"npm \$*\" >> $TMP/npm.log; exit 1"
  write_stub "$SB" pnpm "case \"\$1\" in --version|-v) if [ -f $TMP/pnpm-installed ]; then echo 11.4.0; else echo 9.1.0; fi;; *) echo ok;; esac"
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  # volta 桩落在 ~/.volta/bin（不在 PATH）；install pnpm@pin 时翻转 pnpm 桩版本
  write_stub "$TMP/.volta/bin" volta "echo \"volta \$*\" >> $TMP/volta.log; case \"\$1 \$2\" in \"install pnpm@11.4.0\") touch $TMP/pnpm-installed;; esac"
  : > "$TMP/npm.log"; : > "$TMP/volta.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=ok" \
     && assert_contains "$(cat "$TMP/volta.log")" "install pnpm@11.4.0" && [ ! -s "$TMP/npm.log" ]; then
    pass "bootstrap-env: Volta 装了不在 PATH + npm 不可写 → 经 Volta 成功，npm 未被调用"
  else
    fail "bootstrap-env: Volta 不在 PATH 仍可用" "out: $OUTPUT; volta.log: $(cat "$TMP/volta.log"); npm.log: $(cat "$TMP/npm.log")"
  fi
)

# Test: Volta 在 PATH 但排在陈旧 /usr/local/bin 之后 → 强制提前，不被旧 pnpm shadow
# 复现本机场景：~/.volta/bin/pnpm 是 pin 版本，但 PATH 里 /usr/local/bin 在它之前，
# 且 /usr/local/bin/pnpm 是 2025 年遗留的旧版（10.6.5）。旧逻辑"已在 PATH 就跳过"会
# 让裸 pnpm 解析到旧版 → 版本检测永远不等于 pin → 假性 PNPM_INSTALL_FAILED。
(
  TMP=$(make_tmp); SB="$TMP/sb"; USRLOCAL="$TMP/usrlocal"
  mkdir -p "$SB" "$USRLOCAL" "$TMP/.volta/bin" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm "echo \"npm \$*\" >> $TMP/npm.log; exit 1"
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  # 陈旧 pnpm（恒返回旧版）放在 /usr/local/bin；volta 管理的 pnpm（pin 版本）放在 ~/.volta/bin
  write_stub "$USRLOCAL" pnpm 'case "$1" in --version|-v) echo 10.6.5;; *) echo ok;; esac'
  write_stub "$TMP/.volta/bin" pnpm 'case "$1" in --version|-v) echo 11.4.0;; *) echo ok;; esac'
  write_stub "$TMP/.volta/bin" volta "echo \"volta \$*\" >> $TMP/volta.log"
  : > "$TMP/npm.log"; : > "$TMP/volta.log"
  cd "$TMP/proj"
  # 关键：~/.volta/bin 已在 PATH 中，但排在 $USRLOCAL 之后
  OUTPUT=$(HOME="$TMP" PATH="$USRLOCAL:$SB:/usr/bin:/bin:$TMP/.volta/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=ok" \
     && assert_contains "$OUTPUT" "pnpm 已就绪（11.4.0" && [ ! -s "$TMP/npm.log" ]; then
    pass "bootstrap-env: Volta 排在陈旧 /usr/local/bin 之后 → 强制提前，旧 pnpm 不再 shadow"
  else
    fail "bootstrap-env: 强制 Volta 提前避免被旧 pnpm shadow" "out: $OUTPUT; npm.log: $(cat "$TMP/npm.log")"
  fi
)

# Test: 已装 Volta 时优先用 Volta，不退回 npm
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm "echo \"npm \$*\" >> $TMP/npm.log; exit 0"
  write_stub "$SB" pnpm "case \"\$1\" in --version|-v) if [ -f $TMP/pnpm-installed ]; then echo 11.4.0; else echo 9.1.0; fi;; *) echo ok;; esac"
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  write_stub "$SB" volta "echo \"volta \$*\" >> $TMP/volta.log; case \"\$1 \$2\" in \"install pnpm@11.4.0\") touch $TMP/pnpm-installed;; esac"
  : > "$TMP/npm.log"; : > "$TMP/volta.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$(cat "$TMP/volta.log")" "install pnpm@11.4.0" && [ ! -s "$TMP/npm.log" ]; then
    pass "bootstrap-env: 已装 Volta 时优先 Volta，不碰 npm"
  else
    fail "bootstrap-env: 优先 Volta" "out: $OUTPUT; volta.log: $(cat "$TMP/volta.log"); npm.log: $(cat "$TMP/npm.log")"
  fi
)

# Test【核心保证】: 即便 npm 可写也统一走 Volta —— 绝不用 npm -g 写 /usr/local（EACCES 来源已砍）
# 旧设计会在 npm 可写时优先 npm；现已统一经 Volta（免 sudo），从根上规避 EACCES。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm "echo \"npm \$*\" >> $TMP/npm.log; case \"\$*\" in *pnpm@11.4.0*) touch $TMP/pnpm-installed;; esac; exit 0"
  write_stub "$SB" pnpm "case \"\$1\" in --version|-v) if [ -f $TMP/pnpm-installed ]; then echo 11.4.0; else echo 9.1.0; fi;; *) echo ok;; esac"
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  # curl 桩模拟 get.volta.sh：装一个可用 volta 桩进 ~/.volta/bin
  write_stub "$SB" curl "echo curl >> $TMP/curl.log; mkdir -p $TMP/.volta/bin; printf '#!/bin/bash\necho \"volta \$*\" >> %s\ncase \"\$1 \$2\" in \"install pnpm@11.4.0\") touch %s;; esac\n' $TMP/volta.log $TMP/pnpm-installed > $TMP/.volta/bin/volta; chmod +x $TMP/.volta/bin/volta"
  : > "$TMP/npm.log"; : > "$TMP/curl.log"; : > "$TMP/volta.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=ok" \
     && assert_contains "$(cat "$TMP/volta.log")" "install pnpm@11.4.0" && [ ! -s "$TMP/npm.log" ]; then
    pass "bootstrap-env: npm 可写也统一走 Volta，绝不调用 npm -g"
  else
    fail "bootstrap-env: 统一走 Volta 不用 npm" "out: $OUTPUT; npm.log: $(cat "$TMP/npm.log"); volta.log: $(cat "$TMP/volta.log")"
  fi
)

# Test: 无 Volta 且 npm 失败 → 自动装 Volta 兜底，最终经 Volta 装上 pin
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm "echo \"npm \$*\" >> $TMP/npm.log; exit 1"
  write_stub "$SB" pnpm "case \"\$1\" in --version|-v) if [ -f $TMP/pnpm-installed ]; then echo 11.4.0; else echo 9.1.0; fi;; *) echo ok;; esac"
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  # curl 桩模拟 get.volta.sh：把一个可用 volta 桩落进 ~/.volta/bin
  write_stub "$SB" curl "echo curl >> $TMP/curl.log; mkdir -p $TMP/.volta/bin; printf '#!/bin/bash\necho \"volta \$*\" >> %s\ncase \"\$1 \$2\" in \"install pnpm@11.4.0\") touch %s;; esac\n' $TMP/volta.log $TMP/pnpm-installed > $TMP/.volta/bin/volta; chmod +x $TMP/.volta/bin/volta"
  : > "$TMP/npm.log"; : > "$TMP/curl.log"; : > "$TMP/volta.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=ok" \
     && [ -s "$TMP/curl.log" ] && assert_contains "$(cat "$TMP/volta.log")" "install pnpm@11.4.0"; then
    pass "bootstrap-env: 无 Volta + npm 失败 → 自动装 Volta 兜底成功"
  else
    fail "bootstrap-env: 自动装 Volta 兜底" "out: $OUTPUT; curl.log: $(cat "$TMP/curl.log"); volta.log: $(cat "$TMP/volta.log")"
  fi
)

# Test: no node + curl fails (mac/linux) → reason=NO_NODE, never tries pnpm
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj"
  write_stub "$SB" curl 'exit 1'
  write_stub "$SB" npm "echo called >> $TMP/npm.log"
  : > "$TMP/npm.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" BOOTSTRAP_OS=mac PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=failed reason=NO_NODE" && [ ! -s "$TMP/npm.log" ]; then
    pass "bootstrap-env: no node → NO_NODE, stops before pnpm"
  else
    fail "bootstrap-env: no node → NO_NODE" "out: $OUTPUT; npm.log: $(cat "$TMP/npm.log")"
  fi
)

# Test: Windows branch uses winget/powershell (not curl); PATH not refreshed → RESTART_NEEDED
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj"
  write_stub "$SB" powershell.exe "echo \"ps \$*\" >> $TMP/ps.log; exit 0"
  write_stub "$SB" curl "echo curl >> $TMP/curl.log"
  : > "$TMP/ps.log"; : > "$TMP/curl.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" USERPROFILE="$TMP" BOOTSTRAP_OS=windows PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=failed reason=RESTART_NEEDED" \
     && assert_contains "$(cat "$TMP/ps.log")" "winget install" && [ ! -s "$TMP/curl.log" ]; then
    pass "bootstrap-env: Windows uses winget/powershell (not curl), RESTART_NEEDED when PATH stale"
  else
    fail "bootstrap-env: Windows uses winget/powershell" "out: $OUTPUT; ps.log: $(cat "$TMP/ps.log"); curl.log: $(cat "$TMP/curl.log")"
  fi
)

# Test【Windows 跨平台】: node>=24 已就绪、pnpm≠pin、Volta 本会话不可用（无 winget/powershell）
# → 走 Windows npm-g 兜底（npm install -g pnpm@pin），最终 ok。复现真实 Windows 装机日志的卡点：
# 旧代码 ensure_volta 在 windows 硬 return 1、ensure_pnpm 无兜底 → 假性 PNPM_INSTALL_FAILED。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  # npm: install -g pnpm@pin → 翻转 pnpm 桩版本；其余记日志
  write_stub "$SB" npm "echo \"npm \$*\" >> $TMP/npm.log; case \"\$*\" in *'install -g pnpm@11.4.0'*) touch $TMP/pnpm-installed;; esac; exit 0"
  write_stub "$SB" pnpm "case \"\$1\" in --version|-v) if [ -f $TMP/pnpm-installed ]; then echo 11.4.0; else echo 9.1.0; fi;; *) echo ok;; esac"
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  # 故意不提供 volta / winget / powershell.exe → ensure_volta 在 windows 必失败 → 触发 npm-g 兜底
  : > "$TMP/npm.log"; : > "$TMP/volta.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" USERPROFILE="$TMP" BOOTSTRAP_OS=windows PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=ok" \
     && assert_contains "$(cat "$TMP/npm.log")" "install -g pnpm@11.4.0" \
     && [ ! -s "$TMP/volta.log" ]; then
    pass "bootstrap-env: Windows Volta 不可用 → npm-g 兜底装 pnpm，最终 ok"
  else
    fail "bootstrap-env: Windows npm-g 兜底" "out: $OUTPUT; npm.log: $(cat "$TMP/npm.log")"
  fi
)

# Test【静态】: B 的跨平台改造落到源码——ensure_volta 不再 windows 硬 return 1、
# volta shim 目录认 Windows %LOCALAPPDATA%\Volta\bin、ensure_pnpm 有 Windows npm-g 兜底。
(
  ok=1
  # ensure_volta 内不应再出现「windows 直接 return 1」这条硬挡
  if grep -qE '\[ "\$OS" = "windows" \] && return 1' "$BS"; then ok=0; fi
  # volta_bin_dir 处理 Windows shim 布局
  grep -q 'volta_bin_dir' "$BS" || ok=0
  grep -q 'Volta/bin' "$BS" || ok=0
  grep -q 'LOCALAPPDATA' "$BS" || ok=0
  # ensure_pnpm 的 Windows npm-g 兜底
  grep -q 'npm install -g "pnpm@' "$BS" || ok=0
  if [ "$ok" -eq 1 ]; then
    pass "bootstrap-env: ensure_volta 跨平台 + volta shim 认 win + ensure_pnpm 有 npm-g 兜底"
  else
    fail "bootstrap-env: B 跨平台静态校验" "缺 volta_bin_dir/LOCALAPPDATA/npm-g 兜底 或残留 windows 硬 return 1"
  fi
)

# Test: SKILL.md drives bootstrap via the script, not inline install commands
(
  if grep -q "bootstrap-env.sh" "$SKILL_MD" 2>/dev/null \
     && ! grep -qE '`Bash\(pnpm install\)`' "$SKILL_MD" 2>/dev/null; then
    pass "SKILL.md: env init calls bootstrap-env.sh, no inline 'Bash(pnpm install)'"
  else
    fail "SKILL.md: env init calls bootstrap-env.sh, no inline pnpm install" "still inlines install or missing bootstrap call"
  fi
)

# Test: SKILL.md 的 create-skill 自动安装块复用镜像源（setup_cn_mirror），不另起炉灶
# create-skill 包自身的 volta/npm 全局安装在 bootstrap 之前跑，必须自己接上同一套镜像逻辑。
(
  if grep -q "@minus-ai/create-skill" "$SKILL_MD" 2>/dev/null \
     && grep -q "setup_cn_mirror" "$SKILL_MD" 2>/dev/null; then
    pass "SKILL.md: create-skill 自动安装复用 setup_cn_mirror 镜像源"
  else
    fail "SKILL.md: create-skill 安装走镜像源" "未在 SKILL.md 找到 setup_cn_mirror 调用"
  fi
)

# Test: 默认启用国内镜像源（npmmirror + 清华），source 后调 setup_cn_mirror
(
  TMP=$(make_tmp)
  OUTPUT=$(
    cd "$TMP"
    unset npm_config_registry UV_DEFAULT_INDEX UV_INDEX_URL MINUS_MIRROR
    # shellcheck source=/dev/null
    . "$BS"; setup_cn_mirror
    echo "R=${npm_config_registry:-unset} I=${UV_DEFAULT_INDEX:-unset}"
  )
  if assert_contains "$OUTPUT" "R=https://registry.npmmirror.com" \
     && assert_contains "$OUTPUT" "I=https://pypi.tuna.tsinghua.edu.cn/simple"; then
    pass "bootstrap-env: 默认启用国内镜像（npmmirror + 清华）"
  else
    fail "bootstrap-env: 默认启用国内镜像" "out: $OUTPUT"
  fi
)

# Test: MINUS_MIRROR=off → 禁用镜像，不设 registry，走官方源
(
  TMP=$(make_tmp)
  OUTPUT=$(
    cd "$TMP"
    unset npm_config_registry UV_DEFAULT_INDEX UV_INDEX_URL
    export MINUS_MIRROR=off
    # shellcheck source=/dev/null
    . "$BS"; setup_cn_mirror
    echo "R=${npm_config_registry:-unset}"
  )
  if assert_contains "$OUTPUT" "已禁用" && assert_contains "$OUTPUT" "R=unset"; then
    pass "bootstrap-env: MINUS_MIRROR=off → 禁用镜像，走官方源"
  else
    fail "bootstrap-env: MINUS_MIRROR=off 禁用镜像" "out: $OUTPUT"
  fi
)

# Test: 用户已显式设 npm_config_registry → 尊重不覆盖
(
  TMP=$(make_tmp)
  OUTPUT=$(
    cd "$TMP"
    unset UV_DEFAULT_INDEX UV_INDEX_URL MINUS_MIRROR
    export npm_config_registry="https://my.private/registry"
    # shellcheck source=/dev/null
    . "$BS"; setup_cn_mirror
    echo "R=${npm_config_registry:-unset}"
  )
  if assert_contains "$OUTPUT" "R=https://my.private/registry"; then
    pass "bootstrap-env: 尊重用户已设 npm_config_registry，不覆盖"
  else
    fail "bootstrap-env: 尊重用户已设 registry" "out: $OUTPUT"
  fi
)

# Test: 默认落盘托管 .npmrc + uv.toml（带 minus 标记），让后续升级依赖也走国内源
(
  TMP=$(make_tmp)
  OUTPUT=$(
    cd "$TMP"
    unset npm_config_registry UV_DEFAULT_INDEX UV_INDEX_URL MINUS_MIRROR
    # shellcheck source=/dev/null
    . "$BS"; setup_cn_mirror >/dev/null; write_project_mirror_config >/dev/null
    cat .npmrc 2>/dev/null; cat uv.toml 2>/dev/null
    echo "--GI--"; cat .gitignore 2>/dev/null
  )
  # 落盘内容 + bootstrap 自己把两文件加进 .gitignore（不再依赖 create-skill 模板/发包）
  if assert_contains "$OUTPUT" "registry=https://registry.npmmirror.com" \
     && assert_contains "$OUTPUT" "managed-by: minus" \
     && assert_contains "$OUTPUT" "pypi.tuna.tsinghua.edu.cn" \
     && assert_contains "$OUTPUT" "国内镜像源配置" ; then
    # 精确断言 .gitignore 含 .npmrc 与 uv.toml 两行
    GI_LINES=$(printf '%s\n' "$OUTPUT" | sed -n '/--GI--/,$p')
    if printf '%s\n' "$GI_LINES" | grep -qxF ".npmrc" && printf '%s\n' "$GI_LINES" | grep -qxF "uv.toml"; then
      pass "bootstrap-env: 默认落盘托管 .npmrc + uv.toml 并自动加入 .gitignore"
    else
      fail "bootstrap-env: 落盘后未正确写入 .gitignore" "out: $OUTPUT"
    fi
  else
    fail "bootstrap-env: 落盘托管镜像配置" "out: $OUTPUT"
  fi
)

# Test: MINUS_MIRROR=off → 清掉之前生成的托管 .npmrc / uv.toml
(
  TMP=$(make_tmp)
  OUTPUT=$(
    cd "$TMP"
    printf '# managed-by: minus\nregistry=x\n' > .npmrc
    printf '# managed-by: minus\n' > uv.toml
    # 预置一个含「用户自有行 + 我们托管块」的 .gitignore，验证 off 只删我们的行
    printf 'node_modules/\n# minus 自动生成的国内镜像源配置（本地生效，不入库）\n.npmrc\nuv.toml\n' > .gitignore
    unset npm_config_registry UV_DEFAULT_INDEX UV_INDEX_URL
    export MINUS_MIRROR=off
    # shellcheck source=/dev/null
    . "$BS"; setup_cn_mirror >/dev/null; write_project_mirror_config >/dev/null
    if [ ! -e .npmrc ] && [ ! -e uv.toml ]; then echo "BOTH_GONE"; else echo "STILL:$(ls -A)"; fi
    echo "--GI--"; cat .gitignore
  )
  # 文件被删 + .gitignore 里我们的三行（注释+两文件）被回删，但用户的 node_modules/ 保留
  GI_OFF=$(printf '%s\n' "$OUTPUT" | sed -n '/--GI--/,$p')
  if assert_contains "$OUTPUT" "BOTH_GONE" \
     && printf '%s\n' "$GI_OFF" | grep -qxF "node_modules/" \
     && ! printf '%s\n' "$GI_OFF" | grep -qxF ".npmrc" \
     && ! printf '%s\n' "$GI_OFF" | grep -qxF "uv.toml" \
     && ! printf '%s\n' "$GI_OFF" | grep -qF "国内镜像源配置"; then
    pass "bootstrap-env: MINUS_MIRROR=off → 移除托管文件 + 回删 .gitignore 我们的行（保留用户行）"
  else
    fail "bootstrap-env: off 移除托管文件/gitignore" "out: $OUTPUT"
  fi
)

# Test: 用户自有 .npmrc（无 minus 标记）→ 绝不覆盖
(
  TMP=$(make_tmp)
  OUTPUT=$(
    cd "$TMP"
    printf 'registry=https://my.own/reg\n' > .npmrc
    unset npm_config_registry UV_DEFAULT_INDEX UV_INDEX_URL MINUS_MIRROR
    # shellcheck source=/dev/null
    . "$BS"; setup_cn_mirror >/dev/null; write_project_mirror_config >/dev/null
    cat .npmrc
  )
  if assert_contains "$OUTPUT" "registry=https://my.own/reg" \
     && ! assert_contains "$OUTPUT" "npmmirror"; then
    pass "bootstrap-env: 用户自有 .npmrc 不被覆盖"
  else
    fail "bootstrap-env: 尊重用户自有 .npmrc" "out: $OUTPUT"
  fi
)

# Test: 前端依赖在镜像源失败时回退官方 npm 源重试
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/.venv"  # 故意不建 node_modules → 触发 pnpm install
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm 'exit 0'
  # pnpm install：模拟 pnpm 真实优先级——只认 CLI --registry，忽略 npm_config_registry env
  # （因为落盘的 .npmrc 优先级高于 env）。只有显式 --registry=官方 才成功。
  # 这样旧的「设 env 回退」写法（无 --registry）会失败 → 测试能抓住该 bug。
  write_stub "$SB" pnpm 'case "$1" in
    --version|-v) echo 11.4.0;;
    install)
      reg=""; for a in "$@"; do case "$a" in --registry=*) reg="${a#--registry=}";; esac; done
      [ "$reg" = "https://registry.npmjs.org" ] && exit 0 || exit 1;;
    *) echo ok;; esac'
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  cd "$TMP/proj"
  OUTPUT=$(env -u npm_config_registry -u UV_DEFAULT_INDEX -u UV_INDEX_URL -u MINUS_MIRROR \
    HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "回退官方 npm 源重试" \
     && assert_contains "$OUTPUT" "前端依赖安装完成（官方源）" \
     && assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=ok"; then
    pass "bootstrap-env: 前端依赖镜像失败 → 回退官方 npm 源成功"
  else
    fail "bootstrap-env: 前端依赖回退官方源" "out: $OUTPUT"
  fi
)

# Test: 后端依赖在镜像源失败时回退官方 PyPI 重试
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules"  # 故意不建 .venv → 触发 uv venv+pip
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm 'exit 0'
  write_stub "$SB" pnpm 'echo 11.4.0'
  # uv：venv 总成功并建出 .venv；pip 只在「显式指向官方 PyPI」时成功，镜像源失败。
  # 这样能区分真修复（显式 UV_DEFAULT_INDEX=官方）与旧 bug（env -u 卸载后被 uv.toml 反噬回镜像）：
  # 旧写法卸掉 env → UV_DEFAULT_INDEX 为空 → 不匹配 pypi.org → 仍失败。
  write_stub "$SB" uv 'case "$1" in
    --version) echo "uv 0.5.0";;
    venv) mkdir -p .venv; exit 0;;
    pip) case "${UV_DEFAULT_INDEX:-}" in *pypi.org*) exit 0;; *) exit 1;; esac;;
    *) echo ok;; esac'
  cd "$TMP/proj"
  OUTPUT=$(env -u npm_config_registry -u UV_DEFAULT_INDEX -u UV_INDEX_URL -u MINUS_MIRROR \
    HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  if assert_contains "$OUTPUT" "回退官方 PyPI 重试" \
     && assert_contains "$OUTPUT" "后端依赖安装完成（官方源）" \
     && assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=ok"; then
    pass "bootstrap-env: 后端依赖镜像失败 → 回退官方 PyPI 成功"
  else
    fail "bootstrap-env: 后端依赖回退官方源" "out: $OUTPUT"
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

# Test: launch.json 用 pnpm 绝对路径（Volta shim 优先），不写裸 "pnpm"
# 客户端 spawn Preview 拿 launchd PATH（不含 ~/.volta/bin），裸 pnpm 会落到系统老 Node 崩
(
  if grep -q '/bin/pnpm' "$SKILL_MD" && grep -q 'PNPM_BIN' "$SKILL_MD" \
     && ! grep -qE '"runtimeExecutable": *"pnpm"' "$SKILL_MD"; then
    pass "SKILL.md: launch.json runtimeExecutable 用绝对路径（Volta 优先），无裸 pnpm"
  else
    fail "SKILL.md: launch.json runtimeExecutable 绝对路径" "still bare pnpm or missing volta path resolution"
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

# Test: 登录检查走 auth_status 工具，不再用 ! 钩子裸读 credentials.json
# （裸 cat 凭证文件会撞 Auto Mode 敏感分类器被拦、且依赖 PATH 上有 node）
(
  if grep -q 'mcp__minus-platform__auth_status' "$SKILL_MD" \
     && ! grep -q '!`cat ~/.minus/credentials.json' "$SKILL_MD"; then
    pass "SKILL.md: 登录检查走 auth_status，无裸 cat credentials.json 钩子"
  else
    fail "SKILL.md: 登录检查走 auth_status" "still has !cat credentials hook or missing auth_status check"
  fi
)

# Test: create-skill 经 resolve-node.sh 解析 node 后调用，不裸调（裸调落老 node 崩在 ??）
(
  if grep -q 'resolve-node.sh' "$SKILL_MD" \
     && grep -q 'export PATH="$(dirname "$NODE_BIN")' "$SKILL_MD"; then
    pass "SKILL.md: create-skill 经 resolve-node.sh 解析 node 后调用"
  else
    fail "SKILL.md: create-skill 解析 node" "still bare create-skill or missing resolve-node.sh"
  fi
)

# Test: create-skill 每次无条件对齐 @beta（Volta 优先 / 不碰 /usr/local），失败才提示手动。
# 不能再有 `if ! command -v create-skill` 的"缺了才装"门禁，否则装过一次就永远停在旧版。
(
  if grep -q 'volta/bin/volta" install @minus-ai/create-skill@beta' "$SKILL_MD" \
     && grep -q 'CREATE_SKILL_EXPECTED=' "$SKILL_MD" \
     && grep -q 'CREATE_SKILL_INSTALLED=' "$SKILL_MD" \
     && grep -q 'registry.npmjs.org' "$SKILL_MD" \
     && grep -q 'CREATE_SKILL_INSTALLED" = "$CREATE_SKILL_EXPECTED' "$SKILL_MD" \
     && grep -q 'CREATE_SKILL_INSTALL_FAILED' "$SKILL_MD" \
     && ! grep -q 'if ! command -v create-skill' "$SKILL_MD"; then
    pass "SKILL.md: create-skill 每次对齐官方 @beta，安装后版本硬校验"
  else
    fail "SKILL.md: create-skill 自动对齐 @beta" "expected official version lookup + installed version gate + no missing-only gate"
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

# Test: install.sh source 了 bootstrap-env.sh 并做 node 版本 gate（复用 Volta 装 24）
(
  if grep -q 'source .*lib/bootstrap-env.sh' "$INSTALL_SH" \
     && grep -q 'provision_node_via_volta' "$INSTALL_SH" \
     && grep -q 'NODE_MIN=' "$INSTALL_SH"; then
    pass "install.sh: source bootstrap-env.sh + node 版本 gate（复用 Volta 装 24）"
  else
    fail "install.sh: node 版本 gate" "missing source / provision_node_via_volta / NODE_MIN"
  fi
)

# Test: install.sh 文案以"建议 Node 24"为主，不把 18 放主位
(
  if grep -q '建议.*Node 24\|建议安装 Node 24\|建议升级到 Node 24' "$INSTALL_SH"; then
    pass "install.sh: node 文案以建议 24 为主"
  else
    fail "install.sh: node 文案建议 24" "missing '建议 Node 24' 主表述"
  fi
)

# Test: install.sh 校验自包含 bundle，不再跑 npm install --omit=dev
(
  if grep -q 'dist/minus-platform.cjs' "$INSTALL_SH" \
     && ! grep -q 'npm install --omit=dev' "$INSTALL_SH"; then
    pass "install.sh: 校验 dist bundle，无 npm install --omit=dev"
  else
    fail "install.sh: 校验 dist bundle" "still uses npm install --omit=dev or missing dist check"
  fi
)

# Test: install.sh 校验 launcher 存在（.mcp.json command 实际跑它）
(
  if grep -q 'launch.cjs' "$INSTALL_SH" && ! grep -q 'launch.sh' "$INSTALL_SH"; then
    pass "install.sh: 校验 MCP launcher (launch.cjs) 存在"
  else
    fail "install.sh: 校验 launch.cjs" "missing launch.cjs validation or stale launch.sh ref"
  fi
)

echo "═══ MCP launcher (launch.cjs) ═══"

MCP_DIR="$REPO_DIR/plugins/claude/minus-creator/mcp-servers/minus-platform"
LAUNCH_CJS="$MCP_DIR/launch.cjs"
MCP_JSON="$REPO_DIR/plugins/claude/minus-creator/.mcp.json"

# Test: launch.cjs 存在（经 node 跑，无需可执行位）；旧 launch.sh 已删
(
  if [ -f "$LAUNCH_CJS" ] && [ ! -f "$MCP_DIR/launch.sh" ]; then
    pass "launch.cjs: 存在且旧 launch.sh 已删"
  else
    fail "launch.cjs: 存在/launch.sh 已删" "missing launch.cjs or stale launch.sh"
  fi
)

# Test: launch.cjs 探测 node（下限单源 toolchain.sh，含 Volta image 真身），再 spawn bundle
(
  if grep -q 'NODE_RUNTIME_FLOOR' "$LAUNCH_CJS" \
     && grep -q 'toolchain.sh' "$LAUNCH_CJS" \
     && grep -qi 'volta' "$LAUNCH_CJS" \
     && grep -q 'image' "$LAUNCH_CJS" \
     && grep -q 'minus-platform.cjs' "$LAUNCH_CJS" \
     && grep -q 'spawnSync' "$LAUNCH_CJS"; then
    pass "launch.cjs: 下限单源 toolchain.sh + 探测 Volta image 后 spawn bundle"
  else
    fail "launch.cjs: node 探测/spawn" "missing NODE_RUNTIME_FLOOR/toolchain source/volta image/spawn bundle"
  fi
)

# Test: .mcp.json 的 minus-platform 经 node launch.cjs 启动（command==node 且 args 指向 launch.cjs，非裸 bundle）
(
  if grep -q '"command": "node"' "$MCP_JSON" \
     && grep -q 'launch.cjs' "$MCP_JSON" \
     && ! grep -q 'launch.sh' "$MCP_JSON" \
     && ! grep -q '/bin/sh' "$MCP_JSON"; then
    pass ".mcp.json: minus-platform 经 node launch.cjs 启动（跨平台，非 /bin/sh）"
  else
    fail ".mcp.json: 经 node launch.cjs 启动" "command 非 node 或 args 未指向 launch.cjs 或残留 /bin/sh"
  fi
)

# Test: 没有任何达标 node 时，launch.cjs 给人话报错（口径：建议 Node 24），而非神秘失败。
# launch.cjs 由 node 跑，process.execPath 恒为候选——无法靠限 PATH 模拟「无 node」。
# 改用 stub toolchain.sh 把 NODE_RUNTIME_FLOOR 抬到 999：任何真实 node 都 < 999 → 必走报错分支。
# 临时树两级目录，让 launch.cjs 的 ../../lib/toolchain.sh 落到 stub 上。
(
  T="$(mktemp -d)"
  mkdir -p "$T/a/b" "$T/lib"
  cp "$LAUNCH_CJS" "$T/a/b/launch.cjs"
  printf 'NODE_RUNTIME_FLOOR=999\nNODE_TARGET=24\n' > "$T/lib/toolchain.sh"
  if OUT=$(node "$T/a/b/launch.cjs" </dev/null 2>&1); then RC=0; else RC=$?; fi
  rm -rf "$T"
  if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '建议使用 Node 24'; then
    pass "launch.cjs: 无达标 node 时给「建议 Node 24」人话报错并 exit 非 0"
  else
    fail "launch.cjs: 无 node 报错" "rc=$RC out: $OUT"
  fi
)

echo "═══ resolve-node.sh ═══"

RESOLVE_NODE="$REPO_DIR/plugins/claude/minus-creator/lib/resolve-node.sh"

# Test: resolve-node.sh 存在、下限单源 toolchain.sh、与 launch.cjs 同序探测（含 Volta image）
(
  if [ -f "$RESOLVE_NODE" ] \
     && grep -q 'NODE_RUNTIME_FLOOR' "$RESOLVE_NODE" \
     && grep -q 'toolchain.sh' "$RESOLVE_NODE" \
     && grep -q '.volta/tools/image/node' "$RESOLVE_NODE"; then
    pass "resolve-node.sh: 下限单源 toolchain.sh + 探测 Volta image"
  else
    fail "resolve-node.sh: 探测逻辑" "missing file/NODE_RUNTIME_FLOOR/toolchain source/volta image"
  fi
)

# Test: 无可用 node 时 exit 1 且无输出（调用方据此报错）
(
  if host_has_abs_modern_node; then
    skip "resolve-node.sh: 无可用 node 时 exit 非 0 且无输出" "本机系统路径已有 >=18 node，无法模拟无 node"
  else
    if OUT=$(PATH=/usr/bin:/bin HOME=/tmp/minus-no-node-rn-$$ /bin/sh "$RESOLVE_NODE" 2>&1); then RC=0; else RC=$?; fi
    if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then
      pass "resolve-node.sh: 无可用 node 时 exit 非 0 且无输出"
    else
      fail "resolve-node.sh: 无 node 行为" "rc=$RC out=[$OUT]"
    fi
  fi
)

# Test: MARKETPLACE_DIR 解析到含 marketplace.json 的目录（install.sh 在 minus-creator/ 内，
# marketplace 根是其父级 claude/；旧 bug 拼成 $SCRIPT_DIR/plugins/claude 指向不存在的目录）
(
  SCRIPT_DIR="$(cd "$(dirname "$INSTALL_SH")" && pwd)"
  MARKETPLACE_DIR="$(dirname "$SCRIPT_DIR")"
  if [ -f "$MARKETPLACE_DIR/.claude-plugin/marketplace.json" ] \
     && ! grep -q 'MARKETPLACE_DIR="\$SCRIPT_DIR/plugins/claude"' "$INSTALL_SH"; then
    pass "install.sh: MARKETPLACE_DIR 指向含 marketplace.json 的目录"
  else
    fail "install.sh: MARKETPLACE_DIR 路径" "未解析到含 marketplace.json 的目录，或仍用 \$SCRIPT_DIR/plugins/claude"
  fi
)

# Test: bootstrap-env.sh 主流程被 BASH_SOURCE 守卫包住（可被 install.sh 安全 source）
(
  if grep -q 'BASH_SOURCE\[0\].*=.*"\$0"' "$BS"; then
    pass "bootstrap-env: 主流程有 BASH_SOURCE 守卫，可被 source 而不触发副作用"
  else
    fail "bootstrap-env: BASH_SOURCE 守卫" "main flow not guarded, sourcing will exit"
  fi
)

# Test: source bootstrap-env.sh 不触发主流程（不输出"检测开发环境"、不 exit）
(
  OUTPUT=$( source "$BS" 2>&1; echo "SOURCED_OK" )
  if assert_contains "$OUTPUT" "SOURCED_OK" && ! assert_contains "$OUTPUT" "检测开发环境" >/dev/null 2>&1; then
    pass "bootstrap-env: 被 source 时静默（不跑主流程、不退出）"
  else
    fail "bootstrap-env: source 静默" "out: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ uninstall.sh ═══"
# ══════════════════════════════════════════════════════

UNINSTALL_SH="$LIB_DIR/uninstall.sh"

# Test: uninstall.sh exists
(
  if [ -f "$UNINSTALL_SH" ]; then
    pass "uninstall.sh: exists"
  else
    fail "uninstall.sh: exists" "not found"
  fi
)

# Test: data 目录用 glob 清理（覆盖 minus-creator-inline 与 minus-creator-minus-plugin 两种命名）
(
  if grep -q 'plugins/data/minus-creator\*' "$UNINSTALL_SH" \
     && ! grep -q 'plugins/data/minus-creator-inline"' "$UNINSTALL_SH"; then
    pass "uninstall.sh: data 目录 glob 清理（不再写死 -inline）"
  else
    fail "uninstall.sh: data glob" "仍写死 minus-creator-inline 或未用 glob"
  fi
)

# Test: 清理散落副本 / 解压目录（~/.claude/claude/minus-creator、minus-installer、解压目录）
(
  if grep -q '.claude/claude/minus-creator' "$UNINSTALL_SH" \
     && grep -q '.claude/minus-installer' "$UNINSTALL_SH" \
     && grep -q '.minus-creator-plugin' "$UNINSTALL_SH" \
     && grep -q '.claude-plugins/claude' "$UNINSTALL_SH"; then
    pass "uninstall.sh: 清理散落副本/解压目录"
  else
    fail "uninstall.sh: 散落副本清理" "missing claude/minus-creator / minus-installer / .minus-creator-plugin / .claude-plugins"
  fi
)

# Test: 清理 ~/.claude/plugins/claude 残留解压目录（注册表不引用但物理残留的真实落点）
(
  if grep -q '.claude/plugins/claude/minus-creator' "$UNINSTALL_SH"; then
    pass "uninstall.sh: 清理 ~/.claude/plugins/claude 残留"
  else
    fail "uninstall.sh: ~/.claude/plugins/claude 残留" "missing .claude/plugins/claude/minus-creator"
  fi
)

# Test: 不碰对话历史和登录凭证（projects/ 与 ~/.minus 不在删除范围）
# 只看行首的实际 rm 命令，排除末尾 echo 帮助文字里的 "rm -rf ~/.minus" 示例。
# 注意 .minus-creator-plugin 是合法清理项，故 .minus 后必须紧跟 " / 或行尾才算误删凭证。
(
  if ! grep -Eq '^[[:space:]]*rm -rf.*\.claude/projects' "$UNINSTALL_SH" \
     && ! grep -Eq '^[[:space:]]*rm -rf.*\.minus("|/|$)' "$UNINSTALL_SH"; then
    pass "uninstall.sh: 不删对话历史 / 不删 ~/.minus 凭证"
  else
    fail "uninstall.sh: 误删用户数据" "脚本里出现了删除 projects/ 或 ~/.minus 的命令"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ pack.sh ═══"
# ══════════════════════════════════════════════════════

PACK_SH="$LIB_DIR/pack.sh"

# Test: pack.sh exists
(
  if [ -f "$PACK_SH" ]; then
    pass "pack.sh: exists"
  else
    fail "pack.sh: exists" "not found"
  fi
)

# Test: 打包前重建 bundle，且用 >=18 node（老 node 跑不了 ESM build.mjs）
(
  if grep -q 'build.mjs' "$PACK_SH" \
     && grep -q 'VOLTA_HOME' "$PACK_SH" \
     && grep -q '\-lt 18' "$PACK_SH"; then
    pass "pack.sh: 重建 bundle 并解析 >=18 node"
  else
    fail "pack.sh: 重建 bundle + node>=18" "missing build.mjs / Volta 回退 / node 版本判断"
  fi
)

# Test: 排除 node_modules，且打包后校验 dist 进包、node_modules 没进包
(
  if grep -q 'node_modules' "$PACK_SH" \
     && grep -q 'dist/minus-platform.cjs' "$PACK_SH" \
     && grep -q 'grep -c node_modules' "$PACK_SH"; then
    pass "pack.sh: 排除 node_modules 并校验产物"
  else
    fail "pack.sh: 排除 node_modules + 校验" "missing node_modules 排除或打包后校验"
  fi
)

# ══════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════

read PASS FAIL SKIP < "$RESULTS_FILE"
TOTAL=$((PASS + FAIL + SKIP))
rm -f "$RESULTS_FILE"

echo ""
echo "═══════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped (total: $TOTAL)"
echo "═══════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
