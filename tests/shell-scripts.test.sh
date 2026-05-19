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
  OUTPUT=$(bash "$PM" add "my-skill" "/tmp/my-skill" 2>&1)
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
  bash "$PM" add "my-skill" "/tmp/my-skill" >/dev/null 2>&1
  OUTPUT=$(bash "$PM" add "my-skill" "/tmp/my-skill" 2>&1)
  if assert_contains "$OUTPUT" "已存在"; then
    pass "add: duplicate detected"
  else
    fail "add: duplicate detected" "got: $OUTPUT"
  fi
)

# Test: list after adding
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  bash "$PM" add "skill-a" "/tmp/skill-a" >/dev/null 2>&1
  bash "$PM" add "skill-b" "/tmp/skill-b" >/dev/null 2>&1
  OUTPUT=$(bash "$PM" list 2>&1)
  if assert_contains "$OUTPUT" "skill-a" && assert_contains "$OUTPUT" "skill-b"; then
    pass "list: shows all added projects"
  else
    fail "list: shows all added projects" "got: $OUTPUT"
  fi
)

# Test: remove a project
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  bash "$PM" add "my-skill" "/tmp/my-skill" >/dev/null 2>&1
  OUTPUT=$(bash "$PM" remove "/tmp/my-skill" 2>&1)
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
  bash "$PM" add "my-skill" "/tmp/my-skill" >/dev/null 2>&1
  OUTPUT=$(bash "$PM" find "my-skill" 2>&1)
  if assert_eq "$OUTPUT" "/tmp/my-skill"; then
    pass "find: returns correct path"
  else
    fail "find: returns correct path" "expected: /tmp/my-skill, got: $OUTPUT"
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
  bash "$PM" add "my-skill" "/tmp/my-skill" >/dev/null 2>&1
  sleep 1
  bash "$PM" touch "/tmp/my-skill" >/dev/null 2>&1
  # Just verify no error
  pass "touch: updates without error"
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ port-detector.sh ═══"
# ══════════════════════════════════════════════════════

PD="$LIB_DIR/port-detector.sh"

# Test: finds an available port
(
  OUTPUT=$(bash "$PD" 2>&1)
  if [ -n "$OUTPUT" ] && [ "$OUTPUT" -eq "$OUTPUT" ] 2>/dev/null; then
    if [ "$OUTPUT" -ge 9100 ] && [ "$OUTPUT" -le 9200 ]; then
      pass "port-detector: returns valid port ($OUTPUT)"
    else
      fail "port-detector: returns valid port" "got: $OUTPUT (out of range)"
    fi
  else
    fail "port-detector: returns numeric port" "got: $OUTPUT"
  fi
)

# Test: custom start port
(
  OUTPUT=$(bash "$PD" 8000 2>&1)
  if [ -n "$OUTPUT" ] && [ "$OUTPUT" -ge 8000 ]; then
    pass "port-detector: respects custom start port ($OUTPUT)"
  else
    fail "port-detector: respects custom start port" "got: $OUTPUT"
  fi
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
