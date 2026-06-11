#!/bin/bash
# Shell scripts test suite
# Usage: bash tests/shell-scripts.test.sh

set -euo pipefail

# 测试不开浏览器（全局兜底，CLAUDE.md #1 能硬编码的别靠每个用例自觉加 AUTO_OPEN=0）
export AUTO_OPEN=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$REPO_DIR/plugins/claude/minus-creator/scripts"
SKILL_LIB="$REPO_DIR/plugins/claude/minus-creator/skills/minus/scripts"
STEP_LIB="$REPO_DIR/plugins/claude/minus-creator/skills/minus-step/scripts"
STRUCT_LIB="$REPO_DIR/plugins/claude/minus-creator/skills/minus-structure/scripts"

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
echo "═══ update-progress.sh ═══"
# ══════════════════════════════════════════════════════

UP="$LIB_DIR/update-progress.sh"
PC="$LIB_DIR/progress-check.sh"

# 读取 progress.json 字段（路径表达式如 .phase / .steps["1"].status）
pj() {
  node -e "const p=require('fs').readFileSync('.minus/progress.json','utf8');console.log(JSON.parse(p)$1)"
}

# 搭一个最小 Minus 项目：skill.json + pipeline.py（含 N 个骨架步骤）+ total-steps
setup_project() {
  local N="$1"
  mkdir -p .minus
  echo '{"skillId":"sk_test","version":"v1"}' > .minus/skill.json
  {
    echo "class SkillPipeline(Pipeline):"
    for i in $(seq 1 "$N"); do
      echo ""
      echo "    async def step_${i}(self, ctx):"
      echo "        # TODO: 实现「步骤${i}名」的逻辑"
      echo "        return None"
    done
  } > pipeline.py
  echo "$N" > .minus/total-steps
}

# 标记某步四维度全部完成
mark_dims_done() {
  mkdir -p .minus/dev-progress
  for dim in data logic output confirm; do
    touch ".minus/dev-progress/step_${1}_${dim}"
  done
}

# 把某步的 TODO 骨架替换为"已实现"
implement_step() {
  node -e "
    const fs=require('fs');
    let c=fs.readFileSync('pipeline.py','utf8');
    c=c.replace(new RegExp('        # TODO: 实现「步骤${1}名」的逻辑'),'        x = 1  # implemented');
    fs.writeFileSync('pipeline.py',c);
  "
}

# Test: fails without skill.json
(
  TMP=$(make_tmp); cd "$TMP"
  OUTPUT=$(bash "$UP" touch 2>&1 || true)
  if assert_contains "$OUTPUT" "未找到"; then
    pass "update-progress: fails without skill.json"
  else
    fail "update-progress: fails without skill.json" "got: $OUTPUT"
  fi
)

# Test: init-design writes designing + input_done
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus; echo '{"skillId":"sk_t"}' > .minus/skill.json
  bash "$UP" init-design >/dev/null 2>&1
  if [ "$(pj .phase)" = "designing" ] && [ "$(pj .designStage)" = "input_done" ] && [ "$(pj .currentStep)" = "0" ]; then
    pass "update-progress: init-design"
  else
    fail "update-progress: init-design" "got: $(cat .minus/progress.json)"
  fi
)

# Test: design-done writes steps + developing, removes designStage
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 3
  bash "$UP" init-design >/dev/null 2>&1
  bash "$UP" design-done "关键词采集" "竞争度分析" "长尾词推荐" >/dev/null 2>&1
  if [ "$(pj .phase)" = "developing" ] && [ "$(pj .currentStep)" = "1" ] \
     && [ "$(pj '.steps["1"].status')" = "in_progress" ] \
     && [ "$(pj '.steps["3"].name')" = "长尾词推荐" ] \
     && [ "$(pj '.designStage')" = "undefined" ]; then
    pass "update-progress: design-done"
  else
    fail "update-progress: design-done" "got: $(cat .minus/progress.json)"
  fi
)

# Test: 中文/引号步骤名不破坏 JSON
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 1
  bash "$UP" design-done '步骤"带引号"和$符号' >/dev/null 2>&1
  if [ "$(pj '.steps["1"].name')" = '步骤"带引号"和$符号' ]; then
    pass "update-progress: special chars in step names"
  else
    fail "update-progress: special chars in step names" "got: $(cat .minus/progress.json 2>&1)"
  fi
)

# Test: append-steps 追加且不动已有状态
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 2
  bash "$UP" design-done "A" "B" >/dev/null 2>&1
  bash "$UP" append-steps "C" >/dev/null 2>&1
  if [ "$(pj '.steps["3"].status')" = "pending" ] && [ "$(pj '.steps["1"].status')" = "in_progress" ]; then
    pass "update-progress: append-steps"
  else
    fail "update-progress: append-steps" "got: $(cat .minus/progress.json)"
  fi
)

# Test: step-done 四维度未完成时拒写
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 2
  bash "$UP" design-done "A" "B" >/dev/null 2>&1
  OUTPUT=$(bash "$UP" step-done 1 2>&1 || true)
  if assert_contains "$OUTPUT" "四维度未全部完成" && [ "$(pj '.steps["1"].status')" = "in_progress" ]; then
    pass "update-progress: step-done blocked when dims incomplete"
  else
    fail "update-progress: step-done blocked when dims incomplete" "got: $OUTPUT"
  fi
)

# Test: step-done 时 step_N 仍是 TODO 骨架则拒写
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 2
  bash "$UP" design-done "A" "B" >/dev/null 2>&1
  mark_dims_done 1
  OUTPUT=$(bash "$UP" step-done 1 2>&1 || true)
  if assert_contains "$OUTPUT" "骨架占位" && [ "$(pj '.steps["1"].status')" = "in_progress" ]; then
    pass "update-progress: step-done blocked when step is TODO skeleton"
  else
    fail "update-progress: step-done blocked when TODO" "got: $OUTPUT"
  fi
)

# Test: step-done 门禁齐全时正常推进
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 2
  bash "$UP" design-done "A" "B" >/dev/null 2>&1
  mark_dims_done 1; implement_step 1
  bash "$UP" step-done 1 >/dev/null 2>&1
  if [ "$(pj '.steps["1"].status')" = "completed" ] && [ "$(pj '.steps["2"].status')" = "in_progress" ] \
     && [ "$(pj .currentStep)" = "2" ] && [ "$(pj .phase)" = "developing" ]; then
    pass "update-progress: step-done advances progress"
  else
    fail "update-progress: step-done advances progress" "got: $(cat .minus/progress.json)"
  fi
)

# Test: 最后一步 step-done 自动 phase=testing
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 2
  bash "$UP" design-done "A" "B" >/dev/null 2>&1
  mark_dims_done 1; implement_step 1; bash "$UP" step-done 1 >/dev/null 2>&1
  mark_dims_done 2; implement_step 2; bash "$UP" step-done 2 >/dev/null 2>&1
  if [ "$(pj .phase)" = "testing" ] && [ "$(pj '.steps["2"].status')" = "completed" ]; then
    pass "update-progress: last step-done sets phase=testing"
  else
    fail "update-progress: last step-done sets phase=testing" "got: $(cat .minus/progress.json)"
  fi
)

# Test: set-phase 枚举校验
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 1
  bash "$UP" set-phase ready >/dev/null 2>&1
  OUTPUT=$(bash "$UP" set-phase bogus 2>&1 || true)
  if [ "$(pj .phase)" = "ready" ] && assert_contains "$OUTPUT" "无效的 phase"; then
    pass "update-progress: set-phase validates enum"
  else
    fail "update-progress: set-phase validates enum" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ progress-check.sh ═══"
# ══════════════════════════════════════════════════════

# Test: 非项目目录静默退出 0
(
  TMP=$(make_tmp); cd "$TMP"
  OUTPUT=$(bash "$PC" 2>&1); CODE=$?
  if [ "$CODE" -eq 0 ] && [ -z "$OUTPUT" ]; then
    pass "progress-check: silent exit outside project"
  else
    fail "progress-check: silent exit outside project" "code=$CODE got: $OUTPUT"
  fi
)

# Test: progress.json 缺失时从骨架重建（步骤名取自 TODO 注释）
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 2
  OUTPUT=$(bash "$PC" 2>&1)
  if assert_contains "$OUTPUT" "进度自愈" && [ "$(pj '.steps["2"].name')" = "步骤2名" ] \
     && [ "$(pj .phase)" = "developing" ]; then
    pass "progress-check: rebuilds missing progress.json"
  else
    fail "progress-check: rebuilds missing progress.json" "got: $OUTPUT / $(cat .minus/progress.json 2>&1)"
  fi
)

# Test: 硬产物显示完成但 json 未标 → 补标并推进 currentStep
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 2
  bash "$UP" design-done "A" "B" >/dev/null 2>&1
  mark_dims_done 1; implement_step 1
  # 模拟 agent 漏调 step-done
  OUTPUT=$(bash "$PC" 2>&1)
  if assert_contains "$OUTPUT" "补标 completed" && [ "$(pj '.steps["1"].status')" = "completed" ] \
     && [ "$(pj .currentStep)" = "2" ]; then
    pass "progress-check: heals missed step-done"
  else
    fail "progress-check: heals missed step-done" "got: $OUTPUT / $(cat .minus/progress.json)"
  fi
)

# Test: 全完成且 developing → testing；ready 不被降级
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 1
  bash "$UP" design-done "A" >/dev/null 2>&1
  mark_dims_done 1; implement_step 1
  bash "$PC" >/dev/null 2>&1
  PHASE_AFTER=$(pj .phase)
  bash "$UP" set-phase ready >/dev/null 2>&1
  bash "$PC" >/dev/null 2>&1
  if [ "$PHASE_AFTER" = "testing" ] && [ "$(pj .phase)" = "ready" ]; then
    pass "progress-check: all-done→testing, ready not downgraded"
  else
    fail "progress-check: phase convergence" "after=$PHASE_AFTER final=$(pj .phase)"
  fi
)

# Test: 状态一致时静默
(
  TMP=$(make_tmp); cd "$TMP"
  setup_project 2
  bash "$UP" design-done "A" "B" >/dev/null 2>&1
  bash "$PC" >/dev/null 2>&1
  OUTPUT=$(bash "$PC" 2>&1)
  if [ -z "$OUTPUT" ]; then
    pass "progress-check: silent when consistent"
  else
    fail "progress-check: silent when consistent" "got: $OUTPUT"
  fi
)

# Test: generate-steps 全量模式自动写入 progress.json
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus
  echo '{"skillId":"sk_t"}' > .minus/skill.json
  echo "class SkillPipeline(Pipeline):" > pipeline.py
  bash "$STRUCT_LIB/generate-steps.sh" "步骤A" "步骤B" >/dev/null 2>&1 || true
  if [ -f .minus/progress.json ] && [ "$(pj .phase)" = "developing" ] \
     && [ "$(pj '.steps["2"].name')" = "步骤B" ]; then
    pass "generate-steps: writes progress.json (full mode)"
  else
    fail "generate-steps: writes progress.json (full mode)" "got: $(cat .minus/progress.json 2>&1)"
  fi
)

# Test: generate-steps --append 同步追加 progress.json
(
  TMP=$(make_tmp); cd "$TMP"
  mkdir -p .minus
  echo '{"skillId":"sk_t"}' > .minus/skill.json
  echo "class SkillPipeline(Pipeline):" > pipeline.py
  bash "$STRUCT_LIB/generate-steps.sh" "步骤A" >/dev/null 2>&1 || true
  bash "$STRUCT_LIB/generate-steps.sh" --append "步骤B" >/dev/null 2>&1 || true
  if [ "$(pj '.steps["2"].name')" = "步骤B" ] && [ "$(pj '.steps["2"].status')" = "pending" ]; then
    pass "generate-steps: --append updates progress.json"
  else
    fail "generate-steps: --append updates progress.json" "got: $(cat .minus/progress.json 2>&1)"
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

ST="$STEP_LIB/step-tracker.sh"

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
  OUTPUT=$(bash "$STEP_LIB/generate-node-code.sh" 1 2>&1)
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
  OUTPUT=$(bash "$STEP_LIB/generate-node-code.sh" 1 2>&1)
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
  OUTPUT=$(bash "$STEP_LIB/generate-node-code.sh" 1 2>&1)
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

GS="$STRUCT_LIB/generate-steps.sh"

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

GRD="$STRUCT_LIB/generate-result-design.sh"

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

CPD="$SKILL_LIB/check-python-deps.sh"

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

# Test【Windows venv 布局】: 只有 .venv/Scripts/python.exe（无 .venv/bin/python）时也能找到解释器。
# 复现真实 Windows 卡点：旧代码写死 .venv/bin/python → Windows 永远报"未找到项目虚拟环境"。
(
  TMP=$(make_tmp)
  cd "$TMP"
  mkdir -p .venv/Scripts
  ln -s "$TEST_PYTHON" .venv/Scripts/python.exe
  cat > pipeline.py <<'PY'
import datetime
PY
  write_pyproject pyproject.toml ""
  OUTPUT=$(bash "$CPD" 2>&1 || true)
  if assert_contains "$OUTPUT" "DEPENDENCIES_OK"; then
    pass "check-python-deps: 认 Windows venv 布局（.venv/Scripts/python.exe）"
  else
    fail "check-python-deps: Windows venv 布局应通过" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ skill reference files (原 agent files，已迁入 skills/minus) ═══"
# ══════════════════════════════════════════════════════

SKILL_REF_DIR="$REPO_DIR/plugins/claude/minus-creator/skills/minus"

# Test: structure-design.md mentions skill_update
(
  CONTENT=$(cat "$SKILL_REF_DIR/../minus-structure/structure-design.md")
  if assert_contains "$CONTENT" "skill_update"; then
    pass "structure-design.md: mentions skill_update"
  else
    fail "structure-design.md: missing required content" ""
  fi
)

# Test: node-dev.md mentions MCP and skill_update
(
  CONTENT=$(cat "$SKILL_REF_DIR/../minus-step/node-dev.md")
  if assert_contains "$CONTENT" "MCP" && assert_contains "$CONTENT" "skill_update"; then
    pass "node-dev.md: mentions MCP and skill_update"
  else
    fail "node-dev.md: missing required content" ""
  fi
)

# Test: node-dev.md references pipeline.py
(
  CONTENT=$(cat "$SKILL_REF_DIR/../minus-step/node-dev.md")
  if assert_contains "$CONTENT" "pipeline.py"; then
    pass "node-dev.md: references pipeline.py"
  else
    fail "node-dev.md: should reference pipeline.py" ""
  fi
)

# Test: node-dev.md keeps frontend SDK usage on documented stable APIs
(
  CONTENT=$(cat "$SKILL_REF_DIR/../minus-step/node-dev.md")
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
  CONTENT=$(cat "$SKILL_REF_DIR/../minus-step/node-dev.md")
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
  CONTENT=$(cat "$SKILL_REF_DIR/../minus-step/node-dev.md")
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
  CONTENT=$(cat "$SKILL_REF_DIR/../minus-step/node-dev.md")
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
  CONTENT=$(cat "$STRUCT_LIB/generate-result-design.sh")
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
  CONTENT=$(cat "$STEP_LIB/generate-node-code.sh")
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

DC="$SKILL_LIB/detect-client.sh"

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

GNS="$SKILL_LIB/generate-next-steps.sh"

# Test: fails without project name argument
(
  OUTPUT=$(bash "$GNS" 2>&1) && RC=0 || RC=$?
  if [ "$RC" -ne 0 ] && echo "$OUTPUT" | grep -q "缺少项目名称"; then
    pass "generate-next-steps: fails without project name"
  else
    fail "generate-next-steps: fails without project name" "rc=$RC got: $OUTPUT"
  fi
)

# Test: cli 入口（无真实路径）→ 回退 $HOME/minus/{name}（完整绝对路径，不用 ~ 简写），不含图片/选文件夹文案。
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=cli bash "$GNS" "竞品分析_SKILL" 2>&1)
  if echo "$OUTPUT" | grep -q "cd \"$HOME/minus/竞品分析_SKILL\" && claude" \
     && ! echo "$OUTPUT" | grep -q 'cd ~/minus' \
     && ! echo "$OUTPUT" | grep -q '!\[' \
     && ! echo "$OUTPUT" | grep -q "选择 .*文件夹作为工作目录"; then
    pass "generate-next-steps: cli 无路径 → 回退完整 \$HOME/minus/{name}"
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

# Test: 真实路径在 $HOME 下 → 展示完整绝对路径（不折叠成 ~，与 CLI 分支一致）。
(
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=claude-desktop bash "$GNS" "竞品分析_SKILL" "$HOME/minus/竞品分析_SKILL" 2>&1)
  if echo "$OUTPUT" | grep -q "选择 \`$HOME/minus/竞品分析_SKILL\`" \
     && ! echo "$OUTPUT" | grep -q "选择 \`~/minus"; then
    pass "generate-next-steps: \$HOME 下真实路径 → 完整绝对路径，不折叠 ~"
  else
    fail "generate-next-steps: 完整路径不折叠" "got: $OUTPUT"
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
     && echo "$OUTPUT" | grep -q "$HOME/minus/竞品分析_SKILL" \
     && ! echo "$OUTPUT" | grep -q "~/minus/竞品分析_SKILL" \
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

OP="$SKILL_LIB/open-preview.sh"

# Test: fails without port argument
(
  OUTPUT=$(bash "$OP" 2>&1 || true)
  if assert_contains "$OUTPUT" "用法"; then
    pass "open-preview: fails without port argument"
  else
    fail "open-preview: fails without port argument" "got: $OUTPUT"
  fi
)

# Test: CLI mode outputs URL and CLIENT=cli（stub 掉 open/xdg-open，禁止测试真开浏览器）
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"; cd "$TMP"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" open 'exit 0'
  write_stub "$SB" xdg-open 'exit 0'
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=cli PATH="$SB:$PATH" bash "$OP" 5173 2>&1 || true)
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

# Test: custom port（同样 stub 掉浏览器命令）
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"; cd "$TMP"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" open 'exit 0'
  write_stub "$SB" xdg-open 'exit 0'
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=cli PATH="$SB:$PATH" bash "$OP" 9100 2>&1 || true)
  if assert_contains "$OUTPUT" "PREVIEW_URL=http://localhost:9100"; then
    pass "open-preview: respects custom port"
  else
    fail "open-preview: respects custom port" "got: $OUTPUT"
  fi
)

# Test【去重】: 项目目录内（有 .minus/）同端口只开一次浏览器；换端口重新打开
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/.minus"; cd "$TMP"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" open "echo \"open \$*\" >> $TMP/open.log"
  write_stub "$SB" xdg-open "echo \"open \$*\" >> $TMP/open.log"
  : > "$TMP/open.log"
  OUT1=$(CLAUDE_CODE_ENTRYPOINT=cli PATH="$SB:$PATH" bash "$OP" 5173 2>&1 || true)
  OUT2=$(CLAUDE_CODE_ENTRYPOINT=cli PATH="$SB:$PATH" bash "$OP" 5173 2>&1 || true)
  OUT3=$(CLAUDE_CODE_ENTRYPOINT=cli PATH="$SB:$PATH" bash "$OP" 5180 2>&1 || true)
  OPENS=$(grep -c "open" "$TMP/open.log")
  if [ "$OPENS" = "2" ] && assert_contains "$OUT2" "OPEN_SKIPPED_ALREADY" \
     && assert_contains "$OUT2" "PREVIEW_URL=http://localhost:5173" \
     && [ "$(cat .minus/.preview-opened)" = "5180" ]; then
    pass "open-preview: 同端口去重，换端口重开（共开 $OPENS 次）"
  else
    fail "open-preview: 同端口去重" "opens=$OPENS out2=$OUT2 marker=$(cat .minus/.preview-opened 2>/dev/null)"
  fi
)

# Test【去重边界】: 无 .minus/ 的目录（非项目）不做去重，每次都开
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"; cd "$TMP"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" open "echo open >> $TMP/open.log"
  write_stub "$SB" xdg-open "echo open >> $TMP/open.log"
  : > "$TMP/open.log"
  CLAUDE_CODE_ENTRYPOINT=cli PATH="$SB:$PATH" bash "$OP" 5173 >/dev/null 2>&1 || true
  CLAUDE_CODE_ENTRYPOINT=cli PATH="$SB:$PATH" bash "$OP" 5173 >/dev/null 2>&1 || true
  OPENS=$(grep -c "open" "$TMP/open.log")
  if [ "$OPENS" = "2" ]; then
    pass "open-preview: 非项目目录不去重"
  else
    fail "open-preview: 非项目目录不去重" "opens=$OPENS"
  fi
)

# Test【Windows】: CLI 模式用 start 开浏览器（不是 mac 的 open）。
# 复现真实 Windows 卡点：旧代码只会调 open → Windows 上打不开浏览器。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"; cd "$TMP"   # 隔离 cwd：勿在 repo 根跑（.minus 去重标记会污染）
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" uname 'echo MINGW64_NT-10.0'
  write_stub "$SB" start "echo \"start \$*\" >> $TMP/start.log"
  : > "$TMP/start.log"
  OUTPUT=$(CLAUDE_CODE_ENTRYPOINT=cli PATH="$SB:$PATH" bash "$OP" 5173 2>&1 || true)
  if assert_contains "$OUTPUT" "PREVIEW_URL=http://localhost:5173" \
     && assert_contains "$(cat "$TMP/start.log")" "http://localhost:5173"; then
    pass "open-preview: Windows CLI 用 start 开浏览器"
  else
    fail "open-preview: Windows CLI start" "out: $OUTPUT; start.log: $(cat "$TMP/start.log")"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ check-project-state.sh ═══"
# ══════════════════════════════════════════════════════

CPS="$SKILL_LIB/check-project-state.sh"

(
  TMP=$(make_tmp)
  OUTPUT=$(cd "$TMP" && bash "$CPS")
  if assert_contains "$OUTPUT" "INITIALIZED=0" \
     && assert_contains "$OUTPUT" "NODE_MODULES=0" \
     && assert_contains "$OUTPUT" "VENV=0"; then
    pass "check-project-state: missing state outputs 0"
  else
    fail "check-project-state: missing state" "out: $OUTPUT"
  fi
)

(
  TMP=$(make_tmp)
  mkdir -p "$TMP/.minus" "$TMP/node_modules" "$TMP/.venv"
  touch "$TMP/.minus/initialized"
  OUTPUT=$(cd "$TMP" && bash "$CPS")
  if assert_contains "$OUTPUT" "INITIALIZED=1" \
     && assert_contains "$OUTPUT" "NODE_MODULES=1" \
     && assert_contains "$OUTPUT" "VENV=1"; then
    pass "check-project-state: existing state outputs 1"
  else
    fail "check-project-state: existing state" "out: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ detect-preview-port.sh ═══"
# ══════════════════════════════════════════════════════

DPP="$SKILL_LIB/detect-preview-port.sh"

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

# Test【Windows】: 无 lsof，用 netstat 找端口；dev-ports.json 命中即认（跳过 cwd 校验）。
# 复现真实 Windows 卡点：旧代码 verify_port 只用 lsof → Windows 永远空 PID → 服务活着也 DETECT_FAILED。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/.minus"
  cd "$TMP"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  echo '{"frontend":5199,"backend":4007}' > .minus/dev-ports.json
  write_stub "$SB" uname 'echo MINGW64_NT-10.0'                                          # 强制 windows 分支
  write_stub "$SB" netstat 'echo "  TCP    0.0.0.0:5199     0.0.0.0:0      LISTENING       4321"'
  write_stub "$SB" curl 'exit 0'                                                          # 端口可达
  # 故意不提供 lsof：若 windows 分支仍调 lsof 即失败
  OUTPUT=$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=2 PATH="$SB:$PATH" bash "$DPP" 2>&1 || true)
  if [ "$OUTPUT" = "5199" ]; then
    pass "detect-preview-port: Windows 用 netstat 命中 dev-ports.json 端口（无 lsof）"
  else
    fail "detect-preview-port: Windows netstat 检测" "got: $OUTPUT"
  fi
)

# Test【mac 误报回归】: 端口同时有客户端连接(cwd 非本项目)和监听者(cwd 本项目)时，
# port_pid 必须只取监听者。复现真实 bug：用户打开预览后浏览器对 vite 建连，旧代码
# lsof -i :port -t | head -1 抓到客户端进程 → cwd 归属校验误判 → 活着的 server 被门禁误报失败。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/.minus" "$TMP/frontend"
  cd "$TMP"
  PROJ="$(pwd)"   # 与 detect-preview-port.sh 的 PROJECT_DIR=$(pwd) 一致（避免 symlink 路径差异）
  echo '{"frontend":5174,"backend":4002}' > .minus/dev-ports.json
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" uname 'echo Darwin'   # 强制 unix 分支（走 cwd 校验）
  write_stub "$SB" curl 'exit 0'         # 端口可达
  # lsof 桩：
  #   -sTCP:LISTEN -t  → 只返回监听者 PID 7777（正确）
  #   -p 7777 -Fn      → fcwd 指向本项目 frontend（归属通过）
  #   其余(旧式 -i :port -t) → 先返回客户端 PID 9999（cwd 非本项目，会误判）
  cat > "$SB/lsof" <<EOF
#!/bin/bash
args="\$*"
case "\$args" in
  *"-sTCP:LISTEN"*) echo 7777 ;;
  *"-p 7777"*) printf 'fcwd\nn%s/frontend\n' "$PROJ" ;;
  *"-p 9999"*) printf 'fcwd\nn/somewhere/else\n' ;;
  *) echo 9999 ;;
esac
EOF
  chmod +x "$SB/lsof"
  OUTPUT=$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=2 PATH="$SB:$PATH" bash "$DPP" 2>&1 | head -1 || true)
  if [ "$OUTPUT" = "5174" ]; then
    pass "detect-preview-port: 只取监听者，忽略客户端连接（mac 误报回归）"
  else
    fail "detect-preview-port: 只取监听者" "got: ${OUTPUT} (expected 5174)"
  fi
)

# Test【Preview 托管回归】: 端口来自 dev-ports.json（trusted）但 lsof 找不到 PID
# （Claude Preview 托管的 vite 进程对 Bash 环境不可见）→ 降级为 curl 可达性校验，应通过。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/.minus"
  cd "$TMP"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  echo '{"frontend":50559,"backend":4007}' > .minus/dev-ports.json
  write_stub "$SB" uname 'echo Darwin'
  write_stub "$SB" lsof 'exit 0'   # 任何调用都返回空 → PID 不可见
  write_stub "$SB" curl 'exit 0'   # 端口可达
  OUTPUT=$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=2 PATH="$SB:$PATH" bash "$DPP" 2>&1 | head -1 || true)
  if [ "$OUTPUT" = "50559" ]; then
    pass "detect-preview-port: trusted 端口 PID 不可见时降级为可达性校验（Preview 回归）"
  else
    fail "detect-preview-port: Preview trusted 降级" "got: $OUTPUT (expected 50559)"
  fi
)

# Test【Preview 残留】: trusted 端口 PID 不可见且 curl 不可达（Preview 已死、文件残留）→ DETECT_FAILED
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/.minus"
  cd "$TMP"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  echo '{"frontend":50559}' > .minus/dev-ports.json
  write_stub "$SB" uname 'echo Darwin'
  write_stub "$SB" lsof 'exit 0'
  write_stub "$SB" curl 'exit 1'   # 不可达
  OUTPUT=$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=1 PATH="$SB:$PATH" bash "$DPP" 2>&1 || true)
  if [ "$OUTPUT" = "DETECT_FAILED" ]; then
    pass "detect-preview-port: trusted 端口不可达（残留文件）→ DETECT_FAILED"
  else
    fail "detect-preview-port: trusted 残留文件" "got: $OUTPUT"
  fi
)

# Test【降级范围】: 非 trusted 来源（方法 3 扫描）PID 不可见时仍严格判失败——即使 curl 可达。
# 确认降级只对 dev-ports.json 来源生效，不放宽扫描路径的归属校验。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"
  cd "$TMP"   # 无 dev-ports.json → 只走方法 2/3
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" uname 'echo Darwin'
  write_stub "$SB" lsof 'exit 0'   # PID 不可见
  write_stub "$SB" curl 'exit 0'   # 端口可达（若误放宽，方法 3 会认领 5173）
  write_stub "$SB" pgrep 'exit 1'  # 无 vite 进程
  OUTPUT=$(AUTO_OPEN=0 DETECT_PORT_MAX_WAIT=0 PATH="$SB:$PATH" bash "$DPP" 2>&1 || true)
  if [ "$OUTPUT" = "DETECT_FAILED" ]; then
    pass "detect-preview-port: 非 trusted 来源 PID 不可见仍判失败（降级范围受限）"
  else
    fail "detect-preview-port: 降级范围受限" "got: $OUTPUT"
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
echo "═══ record-preview-port.sh ═══"
# ══════════════════════════════════════════════════════

RPP="$SKILL_LIB/record-preview-port.sh"

# Test: 空目录正常写入 frontend 字段
(
  TMP=$(make_tmp); cd "$TMP"
  OUTPUT=$(bash "$RPP" 50559 2>&1); RC=$?
  WRITTEN=$(node -e "console.log(JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).frontend)" 2>/dev/null)
  if [ "$RC" = "0" ] && [ "$OUTPUT" = "RECORDED frontend=50559" ] && [ "$WRITTEN" = "50559" ]; then
    pass "record-preview-port: 空目录写入 frontend"
  else
    fail "record-preview-port: 空目录写入" "rc=$RC out=$OUTPUT written=$WRITTEN"
  fi
)

# Test: 更新 frontend 时保留已有字段（如 backend）
(
  TMP=$(make_tmp); cd "$TMP"; mkdir -p .minus
  echo '{"frontend":5177,"backend":4007}' > .minus/dev-ports.json
  bash "$RPP" 50559 >/dev/null 2>&1
  FE=$(node -e "console.log(JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).frontend)" 2>/dev/null)
  BE=$(node -e "console.log(JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).backend)" 2>/dev/null)
  if [ "$FE" = "50559" ] && [ "$BE" = "4007" ]; then
    pass "record-preview-port: 更新 frontend 保留 backend"
  else
    fail "record-preview-port: 保留已有字段" "frontend=$FE backend=$BE"
  fi
)

# Test: 损坏的 JSON 文件不致命，重建为合法 JSON
(
  TMP=$(make_tmp); cd "$TMP"; mkdir -p .minus
  echo 'not-json{{{' > .minus/dev-ports.json
  bash "$RPP" 5173 >/dev/null 2>&1; RC=$?
  FE=$(node -e "console.log(JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).frontend)" 2>/dev/null)
  if [ "$RC" = "0" ] && [ "$FE" = "5173" ]; then
    pass "record-preview-port: 损坏 JSON 重建"
  else
    fail "record-preview-port: 损坏 JSON 重建" "rc=$RC frontend=$FE"
  fi
)

# Test: 非法参数（空/非数字/超范围）→ 退出码 2
(
  ALL_OK=1
  for BAD in "" "abc" "0" "70000" "51 59"; do
    if bash "$RPP" "$BAD" >/dev/null 2>&1; then RC=0; else RC=$?; fi
    [ "$RC" = "2" ] || ALL_OK=0
  done
  if [ "$ALL_OK" = "1" ]; then
    pass "record-preview-port: 非法参数退出码 2"
  else
    fail "record-preview-port: 非法参数" "某个非法输入未返回 2"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ start-dev.sh ═══"
# ══════════════════════════════════════════════════════

SD="$SKILL_LIB/start-dev.sh"

# Test: mac/Linux full → pnpm dev；并导出 VOLTA_FEATURE_PNPM
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" uname 'echo Darwin'
  write_stub "$SB" pnpm 'echo "PNPM_ARGS=$*"; echo "FEATURE=$VOLTA_FEATURE_PNPM"'
  OUTPUT=$(VOLTA_HOME="$TMP/novolta" PATH="$SB:$PATH" bash "$SD" full 2>&1 || true)
  if echo "$OUTPUT" | grep -q "PNPM_ARGS=dev$" && echo "$OUTPUT" | grep -q "FEATURE=1"; then
    pass "start-dev: mac/Linux full → pnpm dev + VOLTA_FEATURE_PNPM=1"
  else
    fail "start-dev: mac/Linux full" "got: $OUTPUT"
  fi
)

# Test: Windows full → pnpm run dev:win
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" uname 'echo MINGW64_NT-10.0'
  write_stub "$SB" pnpm 'echo "PNPM_ARGS=$*"'
  OUTPUT=$(VOLTA_HOME="$TMP/novolta" PATH="$SB:$PATH" bash "$SD" full 2>&1 || true)
  if echo "$OUTPUT" | grep -q "PNPM_ARGS=run dev:win$"; then
    pass "start-dev: Windows full → pnpm run dev:win"
  else
    fail "start-dev: Windows full" "got: $OUTPUT"
  fi
)

# Test: backend 模式 → dev:backend（mac/Linux）
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" uname 'echo Darwin'
  write_stub "$SB" pnpm 'echo "PNPM_ARGS=$*"'
  OUTPUT=$(VOLTA_HOME="$TMP/novolta" PATH="$SB:$PATH" bash "$SD" backend 2>&1 || true)
  if echo "$OUTPUT" | grep -q "PNPM_ARGS=dev:backend$"; then
    pass "start-dev: backend 模式 → pnpm dev:backend"
  else
    fail "start-dev: backend 模式" "got: $OUTPUT"
  fi
)

# Test: 优先用 Volta shim 的 pnpm 绝对路径
(
  TMP=$(make_tmp); SB="$TMP/sb"; VB="$TMP/novolta/bin"; mkdir -p "$SB" "$VB"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  write_stub "$SB" uname 'echo Darwin'
  write_stub "$VB" pnpm 'echo "FROM=volta-shim PNPM_ARGS=$*"'
  write_stub "$SB" pnpm 'echo "FROM=path"'   # 不应被选中
  OUTPUT=$(VOLTA_HOME="$TMP/novolta" PATH="$SB:$PATH" bash "$SD" full 2>&1 || true)
  if echo "$OUTPUT" | grep -q "FROM=volta-shim"; then
    pass "start-dev: 优先 Volta shim 的 pnpm"
  else
    fail "start-dev: 优先 Volta shim" "got: $OUTPUT"
  fi
)

# Test: 非法模式 → 退出码 2
(
  if OUTPUT=$(bash "$SD" bogus 2>&1); then RC=0; else RC=$?; fi
  if [ "$RC" = "2" ]; then
    pass "start-dev: 非法模式退出码 2"
  else
    fail "start-dev: 非法模式退出码" "rc=$RC out=$OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ check-dev-server.sh ═══"
# ══════════════════════════════════════════════════════

CDS="$SKILL_LIB/check-dev-server.sh"

# Test: 无 dev server → GATE_FAILED + 退出码 1（门禁拦截）
(
  TMP=$(make_tmp); cd "$TMP"
  if OUTPUT=$(DETECT_PORT_MAX_WAIT=0 bash "$CDS" 2>&1); then RC=0; else RC=$?; fi
  if echo "$OUTPUT" | grep -q "GATE_FAILED" && [ "$RC" = "1" ]; then
    pass "check-dev-server: 无 server → GATE_FAILED 退出码 1"
  else
    fail "check-dev-server: 无 server" "rc=$RC out=$OUTPUT"
  fi
)

# Test: dev server 在跑且归属本项目 → GATE_PASSED（复用 detect-preview-port，Windows 路径命中 dev-ports.json）
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/.minus"; cd "$TMP"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  echo '{"frontend":5199,"backend":4007}' > .minus/dev-ports.json
  write_stub "$SB" uname 'echo MINGW64_NT-10.0'
  write_stub "$SB" netstat 'echo "  TCP    0.0.0.0:5199     0.0.0.0:0      LISTENING       4321"'
  write_stub "$SB" curl 'exit 0'
  OUTPUT=$(DETECT_PORT_MAX_WAIT=2 PATH="$SB:$PATH" bash "$CDS" 2>&1); RC=$?
  if echo "$OUTPUT" | grep -q "GATE_PASSED" && echo "$OUTPUT" | grep -q "PREVIEW_PORT=5199" && [ "$RC" = "0" ]; then
    pass "check-dev-server: server 在跑且归属 → GATE_PASSED"
  else
    fail "check-dev-server: GATE_PASSED" "rc=$RC out=$OUTPUT"
  fi
)

# Test【Preview 托管回归】: record-preview-port 记录端口 + PID 不可见 + 端口可达 → GATE_PASSED
# 复现 Desktop 分支 A 全链路：preview_start 拿到端口 → record → 门禁认 trusted 来源。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"; cd "$TMP"
  write_stub() { printf '#!/bin/bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
  bash "$SKILL_LIB/record-preview-port.sh" 50559 >/dev/null 2>&1
  write_stub "$SB" uname 'echo Darwin'
  write_stub "$SB" lsof 'exit 0'   # Preview 托管进程对 lsof 不可见
  write_stub "$SB" curl 'exit 0'   # 端口可达
  OUTPUT=$(DETECT_PORT_MAX_WAIT=2 PATH="$SB:$PATH" bash "$CDS" 2>&1); RC=$?
  if echo "$OUTPUT" | grep -q "GATE_PASSED" && echo "$OUTPUT" | grep -q "PREVIEW_PORT=50559" && [ "$RC" = "0" ]; then
    pass "check-dev-server: Preview 托管端口 record 后 → GATE_PASSED"
  else
    fail "check-dev-server: Preview 托管回归" "rc=$RC out=$OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ bootstrap-env.sh ═══"
# ══════════════════════════════════════════════════════

BS="$LIB_DIR/bootstrap-env.sh"
# SKILL.md 已精简为纯路由 hub，流程内容拆分在 skills/minus/*.md；
# 内容断言（存在性与禁止性）对全部 skill 指令文件的拼接生效。
SKILL_MD=$(mktemp)
cat "$REPO_DIR"/plugins/claude/minus-creator/skills/minus/*.md "$REPO_DIR"/plugins/claude/minus-creator/skills/minus-auth/*.md "$REPO_DIR"/plugins/claude/minus-creator/skills/minus-step/*.md "$REPO_DIR"/plugins/claude/minus-creator/skills/minus-structure/*.md > "$SKILL_MD"

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

# Test【回归·静态】: bootstrap 全局 export VOLTA_FEATURE_PNPM=1
# 防止有人把这行删掉/挪进只覆盖安装的局部作用域 —— 它必须在文件顶层、对所有 pnpm 调用生效。
(
  if grep -Eq '^[[:space:]]*export VOLTA_FEATURE_PNPM=1' "$BS"; then
    pass "bootstrap-env: 顶层 export VOLTA_FEATURE_PNPM=1（覆盖所有 pnpm 调用）"
  else
    fail "bootstrap-env: 缺少顶层 export VOLTA_FEATURE_PNPM=1" "未找到 'export VOLTA_FEATURE_PNPM=1'"
  fi
)

# Test【回归·行为】: pnpm 是「实验 flag 装的」—— 运行时不带 VOLTA_FEATURE_PNPM=1 就报
# Could not find executable，带上才返回版本。复现彭元峰机器的真实坏态：pnpm 其实装好了，
# 但 bootstrap 的 pnpm_ok 校验（裸 pnpm --version）误判为失败 → 假性 PNPM_INSTALL_FAILED。
# 现在 bootstrap 顶层 export 了 flag，gated pnpm 也应被识别为「已就绪」，不再误判、不重装。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac'
  write_stub "$SB" npm "echo \"npm \$*\" >> $TMP/npm.log; exit 0"
  # gated pnpm：--version 仅在 VOLTA_FEATURE_PNPM=1 时返回 11.4.0，否则模拟 Volta 报错并退非零
  write_stub "$SB" pnpm 'case "$1" in --version|-v) if [ "$VOLTA_FEATURE_PNPM" = "1" ]; then echo 11.4.0; else echo "Volta error: Could not find executable \"pnpm\"" >&2; exit 1; fi;; *) echo ok;; esac'
  write_stub "$SB" uv 'echo "uv 0.5.0"'
  write_stub "$SB" volta "echo \"volta \$*\" >> $TMP/volta.log; exit 0"
  : > "$TMP/npm.log"; : > "$TMP/volta.log"
  cd "$TMP/proj"
  OUTPUT=$(HOME="$TMP" PATH="$SB:/usr/bin:/bin" bash "$BS" 2>&1)
  # 期望：识别为已就绪、整体 ok，且没触发任何 pnpm 重装（volta install pnpm 未被调用）
  if assert_contains "$OUTPUT" "BOOTSTRAP_RESULT=ok" \
     && assert_contains "$OUTPUT" "pnpm 已就绪（11.4.0" \
     && ! assert_contains "$(cat "$TMP/volta.log")" "install pnpm" 2>/dev/null; then
    pass "bootstrap-env: gated pnpm（需 VOLTA_FEATURE_PNPM=1）不再被误判失败"
  else
    fail "bootstrap-env: gated pnpm 误判回归" "out: $OUTPUT; volta.log: $(cat "$TMP/volta.log")"
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

# Test【Windows winget 自举】: winget 把 volta 装到 ProgramFiles\Volta（写 System PATH 本会话不生效、
# shim 未初始化）。复现真实日志卡点：旧 install_volta_windows 只往 LOCALAPPDATA\Volta\bin 找、
# 不接 ProgramFiles\Volta 也不跑 volta setup → 本会话 volta 找不到 → NODE24_PROVISION_FAILED。
# 期望：新代码把 ProgramFiles\Volta 接进 PATH + 跑 volta setup → 同一会话即 volta 可用（return 0）。
(
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"
  PF="$TMP/ProgFiles"; LA="$TMP/AppData/Local"; mkdir -p "$PF" "$LA"
  : > "$TMP/setup.log"
  # powershell winget install → 模拟 winget：把 volta 桩落到 ProgramFiles\Volta（不写当前 PATH）
  write_stub "$SB" powershell.exe "mkdir -p '$PF/Volta'; printf '%s\n' '#!/bin/bash' 'case \"\$1\" in setup) echo setup >> $TMP/setup.log; mkdir -p \"\${VOLTA_HOME:-\$HOME/.volta}/bin\";; --version) echo 2.0.2;; esac' > '$PF/Volta/volta'; chmod +x '$PF/Volta/volta'; exit 0"
  OUTPUT=$(HOME="$TMP" USERPROFILE="$TMP" LOCALAPPDATA="$LA" ProgramFiles="$PF" BOOTSTRAP_OS=windows PATH="$SB:/usr/bin:/bin" bash -c '. "'"$BS"'"; if install_volta_windows; then echo VOLTA_READY; else echo VOLTA_NOT_READY; fi' 2>&1)
  if assert_contains "$OUTPUT" "VOLTA_READY" && assert_contains "$(cat "$TMP/setup.log")" "setup"; then
    pass "bootstrap-env: Windows winget 装完自举（接 ProgramFiles\\Volta + volta setup）本会话即可用"
  else
    fail "bootstrap-env: Windows winget 自举" "out: $OUTPUT; setup.log: $(cat "$TMP/setup.log")"
  fi
)

# Test【静态】: winget 自举两步落到源码——install_volta_windows 接 ProgramFiles 目录 + 跑 volta setup；
# 且 VOLTA_HOME 与 volta shim 目录同源（volta_home_base），不再 LOCALAPPDATA / $HOME/.volta 打架。
(
  ok=1
  grep -q 'win_volta_install_dir' "$BS" || ok=0          # 接 winget 落地目录进 PATH
  grep -q 'volta setup' "$BS" || ok=0                      # 初始化 shim
  grep -q 'volta_home_base' "$BS" || ok=0                  # VOLTA_HOME 与 bin 目录单源
  # volta_on_path 不再写死 $HOME/.volta，改用 volta_home_base
  grep -qE 'export VOLTA_HOME="\$\(volta_home_base\)"' "$BS" || ok=0
  if [ "$ok" -eq 1 ]; then
    pass "bootstrap-env: winget 自举两步 + VOLTA_HOME 单源（volta_home_base）落到源码"
  else
    fail "bootstrap-env: winget 自举静态校验" "缺 win_volta_install_dir / volta setup / volta_home_base 单源"
  fi
)

# Test【静态】: B 的跨平台改造落到源码——ensure_volta 不再 windows 硬 return 1、
# volta shim 目录认 Windows %LOCALAPPDATA%\Volta\bin、ensure_pnpm 有 Windows npm-g 兜底。
(
  ok=1
  # ensure_volta 内不应再出现「windows 直接 return 1」这条硬挡
  if grep -qE '\[ "\$OS" = "windows" \] && return 1' "$BS"; then ok=0; fi
  # volta_bin_dir 处理 Windows shim 布局（家目录单源 volta_home_base + /bin）
  grep -q 'volta_bin_dir' "$BS" || ok=0
  grep -qE 'volta_home_base.*/bin|/Volta' "$BS" || ok=0
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
  if grep -q "minus-lib bootstrap-env" "$SKILL_MD" 2>/dev/null \
     && ! grep -qE '`Bash\(pnpm install\)`' "$SKILL_MD" 2>/dev/null; then
    pass "SKILL.md: env init calls bootstrap-env.sh, no inline 'Bash(pnpm install)'"
  else
    fail "SKILL.md: env init calls bootstrap-env.sh, no inline pnpm install" "still inlines install or missing bootstrap call"
  fi
)

(
  if grep -q "minus-lib check-project-state" "$SKILL_MD" 2>/dev/null; then
    pass "SKILL.md: env init uses check-project-state for local state"
  else
    fail "SKILL.md: env init state check" "missing minus-lib check-project-state"
  fi
)

# Test: run-create-skill.sh 的 create-skill 自动安装块复用镜像源（setup_cn_mirror），不另起炉灶
# create-skill 包自身的 volta/npm 全局安装在 bootstrap 之前跑，必须自己接上同一套镜像逻辑。
(
  RCS="$REPO_DIR/plugins/claude/minus-creator/skills/minus/scripts/run-create-skill.sh"
  if grep -q "@minus-ai/create-skill" "$RCS" 2>/dev/null \
     && grep -q "setup_cn_mirror" "$RCS" 2>/dev/null; then
    pass "run-create-skill.sh: create-skill 自动安装复用 setup_cn_mirror 镜像源"
  else
    fail "run-create-skill.sh: create-skill 安装走镜像源" "未在 run-create-skill.sh 找到 setup_cn_mirror 调用"
  fi
)

# Test【现场化文案】: NODE24_PROVISION_FAILED 时 Volta 已装 → 引导「网络/重试」而非重装 Volta。
# 复现用户质疑：旧文案无脑喊「curl 装 Volta」，但 Volta 可能早装好，失败的是拉 node@24。
(
  RCS="$REPO_DIR/plugins/claude/minus-creator/skills/minus/scripts/run-create-skill.sh"
  TMP=$(make_tmp); SB="$TMP/sb"; VB="$TMP/.volta/bin"; mkdir -p "$SB" "$VB"
  # node 桩固定 20：≥20 过 resolve-node（否则回退探测到机器真实 node 24，场景失效），但 < NODE_FLOOR(24) → provision 后 node_major_ok 失败
  write_stub "$SB" node 'case "$1" in -v) echo v20.0.0;; *) echo 20;; esac'
  write_stub "$SB" npm 'exit 0'
  # volta 已装（桩）：install node@24 不真正升级 node → provision 失败，但 Volta 在场
  write_stub "$VB" volta 'exit 0'
  OUTPUT=$(HOME="$TMP" VOLTA_HOME="$TMP/.volta" BOOTSTRAP_OS=mac PATH="$SB:/usr/bin:/bin" bash "$RCS" "测试项目" 2>&1 || true)
  if assert_contains "$OUTPUT" "NODE24_PROVISION_FAILED" \
     && assert_contains "$OUTPUT" "Volta 已就绪" \
     && ! assert_contains "$OUTPUT" "get.volta.sh"; then
    pass "run-create-skill: Volta 已装时引导网络/重试，不喊重装 Volta"
  else
    fail "run-create-skill: Volta 已装文案" "out: $OUTPUT"
  fi
)

# Test【现场化文案】: NODE24_PROVISION_FAILED 时 Volta 未装 + mac → 引导 curl 装 Volta，并透出真实原因。
(
  RCS="$REPO_DIR/plugins/claude/minus-creator/skills/minus/scripts/run-create-skill.sh"
  TMP=$(make_tmp); SB="$TMP/sb"; mkdir -p "$SB"
  write_stub "$SB" node 'case "$1" in -v) echo v18.0.0;; *) echo 18;; esac'
  write_stub "$SB" npm 'exit 0'
  write_stub "$SB" curl 'exit 1'   # 有 curl 但下载失败 → ensure_volta 失败、不触网
  # 假 HOME 铺 volta image node 桩（20 = 过 resolve-node 下限，< NODE_FLOOR 24 → 走 provision）：
  # 不能指望机器绝对路径（/usr/local 等）有现代 node 兜底 resolve（实测有机器是 v12 → 提前 NO_GOOD_NODE，场景失效）
  IMG="$TMP/.volta/tools/image/node/20.0.0/bin"; mkdir -p "$IMG"
  write_stub "$IMG" node 'case "$1" in -v) echo v20.0.0;; *) echo 20;; esac'
  # 不提供 volta / winget / powershell.exe → Volta 真的不在场
  OUTPUT=$(HOME="$TMP" VOLTA_HOME="$TMP/.volta" BOOTSTRAP_OS=mac PATH="$SB:/usr/bin:/bin" bash "$RCS" "测试项目" 2>&1 || true)
  if assert_contains "$OUTPUT" "NODE24_PROVISION_FAILED" \
     && assert_contains "$OUTPUT" "get.volta.sh" \
     && assert_contains "$OUTPUT" "原因："; then
    pass "run-create-skill: Volta 未装(mac) → 引导 curl 装 Volta + 透出真实原因"
  else
    fail "run-create-skill: Volta 未装(mac)文案" "out: $OUTPUT"
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
# SKILL.md 已精简为纯路由 hub，流程内容拆分在 skills/minus/*.md；
# 内容断言（存在性与禁止性）对全部 skill 指令文件的拼接生效。
SKILL_MD=$(mktemp)
cat "$REPO_DIR"/plugins/claude/minus-creator/skills/minus/*.md "$REPO_DIR"/plugins/claude/minus-creator/skills/minus-auth/*.md "$REPO_DIR"/plugins/claude/minus-creator/skills/minus-step/*.md "$REPO_DIR"/plugins/claude/minus-creator/skills/minus-structure/*.md > "$SKILL_MD"

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
# 该逻辑已硬编码进 generate-launch-json.sh（设计原则①），skill 只调脚本
(
  GLJ="$SKILL_LIB/generate-launch-json.sh"
  if grep -q 'minus-lib generate-launch-json' "$SKILL_MD" \
     && grep -q '/bin/pnpm' "$GLJ" && grep -q 'PNPM_BIN' "$GLJ" \
     && ! grep -qE '"runtimeExecutable": *"pnpm"' "$GLJ"; then
    pass "launch.json: skill 调 generate-launch-json.sh，脚本内 runtimeExecutable 绝对路径无裸 pnpm"
  else
    fail "launch.json runtimeExecutable 绝对路径" "skill 未引用脚本，或脚本仍裸 pnpm / 缺 Volta 路径解析"
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

(
  if grep -q 'lsof' "$SKILL_MD"; then
    fail "SKILL.md: no lsof precheck for dev server" "Windows/Git Bash 不保证 lsof，dev cleanup belongs to minus-dev"
  else
    pass "SKILL.md: no lsof precheck for dev server"
  fi
)

# 启动逻辑已下沉到 start-dev.sh（CLAUDE.md #3 单源化）：dev:win 分支 + pnpm 解析
# 都在脚本里，SKILL.md 只引用脚本，不再内联。
(
  if grep -q 'run dev:win' "$SD" \
     && grep -q 'run dev:win:backend' "$SD" \
     && grep -q '"\$PNPM_CMD" dev:backend' "$SD" \
     && grep -q '"\$PNPM_CMD" dev' "$SD" \
     && grep -Fq 'MINGW*|MSYS*|CYGWIN*' "$SD"; then
    pass "start-dev.sh: Windows uses dev:win while mac/Linux keeps stable dev scripts"
  else
    fail "start-dev.sh: platform dev script selection" "missing dev:win branch or mac/Linux stable command"
  fi
)

(
  if grep -q 'VOLTA_HOME="${VOLTA_HOME:-$HOME/.volta}"' "$SD" \
     && grep -q 'PNPM_CMD="$VOLTA_HOME/bin/pnpm"' "$SD" \
     && grep -q 'PNPM_CMD="$(command -v pnpm)"' "$SD"; then
    pass "start-dev.sh: dev server launch resolves pnpm via VOLTA_HOME before PATH"
  else
    fail "start-dev.sh: pnpm resolution for GUI PATH" "missing VOLTA_HOME/PNPM_CMD resolution"
  fi
)

# SKILL.md 不再内联启动逻辑，只引用 start-dev.sh（单源化）
(
  if grep -q 'minus-lib start-dev' "$SKILL_MD" \
     && ! grep -q '"$PNPM_CMD" run dev:win' "$SKILL_MD"; then
    pass "SKILL.md: 启动逻辑引用 start-dev.sh，不内联"
  else
    fail "SKILL.md: 启动逻辑应引用 start-dev.sh" "仍内联 pnpm 启动块或未引用脚本"
  fi
)

# SKILL.md 必须在进入结构设计前调 dev server 门禁
(
  if grep -q 'minus-lib check-dev-server' "$SKILL_MD" \
     && grep -q 'GATE_FAILED' "$SKILL_MD"; then
    pass "SKILL.md: 结构设计前有 check-dev-server.sh 硬门禁"
  else
    fail "SKILL.md: 缺 dev server 门禁" "未引用 check-dev-server.sh 或未处理 GATE_FAILED"
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

# Test: create-skill 经 run-create-skill.sh → resolve-node.sh 解析 node 后调用，不裸调（裸调落老 node 崩在 ??）
(
  RCS="$REPO_DIR/plugins/claude/minus-creator/skills/minus/scripts/run-create-skill.sh"
  if grep -q 'run-create-skill.sh' "$SKILL_MD" \
     && grep -q 'resolve-node.sh' "$RCS" \
     && grep -q 'node_dir="$(dirname "$NODE_BIN")' "$RCS"; then
    pass "SKILL.md: create-skill 经 run-create-skill.sh/resolve-node.sh 解析 node 后调用"
  else
    fail "SKILL.md: create-skill 解析 node" "still bare create-skill or missing run-create-skill.sh/resolve-node.sh"
  fi
)

# Test: create-skill 每次无条件对齐 @beta（Volta 优先 / 不碰 /usr/local），失败才提示手动。
# 不能再有 `if ! command -v create-skill` 的"缺了才装"门禁，否则装过一次就永远停在旧版。
(
  RCS="$REPO_DIR/plugins/claude/minus-creator/skills/minus/scripts/run-create-skill.sh"
  if grep -q 'CREATE_SKILL_SPEC="${MINUS_CREATE_SKILL_SPEC:-@minus-ai/create-skill@beta}"' "$RCS" \
     && grep -q 'install "$CREATE_SKILL_SPEC"' "$RCS" \
     && grep -q 'CREATE_SKILL_EXPECTED=' "$RCS" \
     && grep -q 'CREATE_SKILL_INSTALLED=' "$RCS" \
     && grep -q 'registry.npmjs.org' "$RCS" \
     && grep -q 'CREATE_SKILL_INSTALLED" != "$CREATE_SKILL_EXPECTED' "$RCS" \
     && grep -q 'CREATE_SKILL_INSTALL_FAILED' "$RCS" \
     && ! grep -q 'if ! command -v create-skill' "$RCS"; then
    pass "run-create-skill.sh: create-skill 每次对齐官方 @beta，安装后版本硬校验"
  else
    fail "run-create-skill.sh: create-skill 自动对齐 @beta" "expected official version lookup + installed version gate + no missing-only gate"
  fi
)

(
  RCS="$REPO_DIR/plugins/claude/minus-creator/skills/minus/scripts/run-create-skill.sh"
  if grep -q 'MINUS_CREATE_SKILL_SPEC' "$RCS" \
     && ! grep -q 'MINUS_CREATE_SKILL_BIN' "$RCS" \
     && ! grep -q 'windows-canary' "$RCS" \
     && ! grep -q '.npm-global/bin' "$RCS" \
     && ! grep -q 'installed_version_via_command' "$RCS" \
     && ! grep -q 'add_npm_global_bin' "$RCS" \
     && ! grep -q 'command -v create-skill' "$RCS"; then
    pass "run-create-skill.sh: 测试包仅通过 MINUS_CREATE_SKILL_SPEC 显式启用，不写死 canary/link"
  else
    fail "run-create-skill.sh: create-skill spec override" "must support env spec without link/bin/canary hardcode"
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
  if grep -q 'source .*scripts/bootstrap-env.sh' "$INSTALL_SH" \
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

# Test: install.sh 产物校验委托单源脚本（dist bundle + launch.cjs 检查在 post-install-check.sh），
# 且不再跑 npm install --omit=dev
(
  if grep -q 'post-install-check.sh" --strict' "$INSTALL_SH" \
     && ! grep -q 'npm install --omit=dev' "$INSTALL_SH"; then
    pass "install.sh: 产物校验委托 post-install-check.sh，无 npm install --omit=dev"
  else
    fail "install.sh: 产物校验委托" "missing post-install-check.sh --strict call or still uses npm install --omit=dev"
  fi
)

# Test: post-install-check.sh 校验 bundle + launcher（单源所在处）
(
  PIC_SH="$REPO_DIR/plugins/claude/minus-creator/scripts/post-install-check.sh"
  if grep -q 'dist/minus-platform.cjs' "$PIC_SH" && grep -q 'launch.cjs' "$PIC_SH" \
     && ! grep -q 'launch.sh' "$PIC_SH"; then
    pass "post-install-check.sh: 校验 dist bundle + launch.cjs（单源）"
  else
    fail "post-install-check.sh: 产物校验单源" "missing dist/launch.cjs checks or stale launch.sh ref"
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
# 临时树两级目录，让 launch.cjs 的 ../../scripts/toolchain.sh 落到 stub 上。
(
  T="$(mktemp -d)"
  mkdir -p "$T/a/b" "$T/scripts"
  cp "$LAUNCH_CJS" "$T/a/b/launch.cjs"
  printf 'NODE_RUNTIME_FLOOR=999\nNODE_TARGET=24\n' > "$T/scripts/toolchain.sh"
  if OUT=$(node "$T/a/b/launch.cjs" </dev/null 2>&1); then RC=0; else RC=$?; fi
  rm -rf "$T"
  if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q '建议使用 Node 24'; then
    pass "launch.cjs: 无达标 node 时给「建议 Node 24」人话报错并 exit 非 0"
  else
    fail "launch.cjs: 无 node 报错" "rc=$RC out: $OUT"
  fi
)

echo "═══ resolve-node.sh ═══"

RESOLVE_NODE="$REPO_DIR/plugins/claude/minus-creator/scripts/resolve-node.sh"

# Test: resolve-node.sh 存在、下限单源 toolchain.sh、与 launch.cjs 同序探测（含 Volta image）
(
  if [ -f "$RESOLVE_NODE" ] \
     && grep -q 'NODE_RUNTIME_FLOOR' "$RESOLVE_NODE" \
     && grep -q 'toolchain.sh' "$RESOLVE_NODE" \
     && grep -q '.volta/tools/image/node' "$RESOLVE_NODE" \
     && grep -q 'Volta/tools/image/node' "$RESOLVE_NODE"; then
    pass "resolve-node.sh: 下限单源 toolchain.sh + 探测 Volta image（unix + Windows LOCALAPPDATA）"
  else
    fail "resolve-node.sh: 探测逻辑" "missing file/NODE_RUNTIME_FLOOR/toolchain source/volta image(unix/win)"
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

# Test: Windows Program Files 路径含空格时不能被 for-word-splitting 拆坏
(
  TMP=$(make_tmp)
  RN_TMP="$TMP/lib/resolve-node.sh"
  mkdir -p "$TMP/lib" "$TMP/Program Files/nodejs"
  cp "$RESOLVE_NODE" "$RN_TMP"
  printf 'NODE_RUNTIME_FLOOR=999\nNODE_TARGET=24\n' > "$TMP/lib/toolchain.sh"
  cat > "$TMP/Program Files/nodejs/node.exe" <<'EOF'
#!/bin/sh
case "$1" in
  -p) echo 999;;
  -v) echo v999.0.0;;
  *) echo 999;;
esac
EOF
  chmod +x "$TMP/Program Files/nodejs/node.exe" "$RN_TMP"
  OUT=$(HOME="$TMP/home" ProgramFiles="$TMP/Program Files" PATH=/bin:/usr/bin /bin/sh "$RN_TMP" 2>&1 || true)
  if [ "$OUT" = "$TMP/Program Files/nodejs/node.exe" ]; then
    pass "resolve-node.sh: Windows Program Files 空格路径可解析"
  else
    fail "resolve-node.sh: Windows Program Files 空格路径" "out=[$OUT]"
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

# Test: install.sh 自迁移——注册前把 marketplace 固化到稳定家目录（防 cache-miss）
(
  if grep -q 'minus-creator-marketplace' "$INSTALL_SH" \
     && grep -q 'MARKETPLACE_DIR="\$STABLE_HOME"' "$INSTALL_SH"; then
    pass "install.sh: 自迁移到稳定家目录 minus-creator-marketplace"
  else
    fail "install.sh: 自迁移" "未把 marketplace 固化到 ~/.claude/minus-creator-marketplace 再注册"
  fi
)

# Test: install.sh 用 remove->add 强制重指（不再用 update，避免旧注册指向死目录）
(
  if grep -q 'marketplace remove "\$MARKETPLACE_NAME"' "$INSTALL_SH" \
     && ! grep -q 'marketplace update "\$MARKETPLACE_NAME"' "$INSTALL_SH"; then
    pass "install.sh: marketplace remove->add 强制重指（不再用 update）"
  else
    fail "install.sh: marketplace 重指" "仍用 update，旧注册可能指向已死目录"
  fi
)

# Test: install.ps1 自迁移——固化到稳定家目录再注册
(
  INSTALL_PS1="$REPO_DIR/plugins/claude/minus-creator/install.ps1"
  if [ -f "$INSTALL_PS1" ] && grep -q 'minus-creator-marketplace' "$INSTALL_PS1" \
     && grep -q '\$MarketplaceDir = \$StableHome' "$INSTALL_PS1"; then
    pass "install.ps1: 自迁移到稳定家目录 minus-creator-marketplace"
  else
    fail "install.ps1: 自迁移" "未把 marketplace 固化到稳定目录再注册"
  fi
)

# Test: install.sh 装前清残留 plugin cache（防 Windows EPERM rename 撞已存在目标目录）
(
  if grep -q 'temp_local_\*' "$INSTALL_SH" \
     && grep -q '\$CACHE_ROOT/\$MARKETPLACE_NAME/\$PLUGIN_NAME' "$INSTALL_SH"; then
    pass "install.sh: 装前清残留 plugin cache（temp_local_* + 本插件目标）"
  else
    fail "install.sh: 清残留缓存" "未在 claude plugin install 前清 temp_local_* / 本插件 cache 目标"
  fi
)

# Test: install.ps1 装前清残留 plugin cache（防 Windows EPERM rename 撞已存在目标目录）
(
  INSTALL_PS1="$REPO_DIR/plugins/claude/minus-creator/install.ps1"
  if [ -f "$INSTALL_PS1" ] && grep -q "temp_local_\*" "$INSTALL_PS1" \
     && grep -q 'plugins\\cache' "$INSTALL_PS1" \
     && grep -q '\$pluginCache' "$INSTALL_PS1"; then
    pass "install.ps1: 装前清残留 plugin cache（temp_local_* + 本插件目标）"
  else
    fail "install.ps1: 清残留缓存" "未在 claude plugin install 前清 temp_local_* / 本插件 cache 目标"
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
echo "═══ sync-plugin.sh ═══"
# ══════════════════════════════════════════════════════

SYNC_SH="$LIB_DIR/sync-plugin.sh"

# Test: 安装位置从注册表读，不硬编码 cache 布局；不复制到 ~/.claude/skills（双注册）
(
  if grep -q 'installed_plugins.json' "$SYNC_SH" \
     && grep -q 'installPath' "$SYNC_SH" \
     && ! grep -q 'CLAUDE_DIR/skills' "$SYNC_SH" \
     && ! grep -q 'CLAUDE_DIR/agents' "$SYNC_SH"; then
    pass "sync-plugin: 从 installed_plugins.json 读 installPath，不写 ~/.claude/skills|agents"
  else
    fail "sync-plugin: 安装位置来源" "应读注册表 installPath，且不得复制到全局 skills/agents"
  fi
)

# Test: 注册表缺失/无安装记录时明确报错（行为测试，伪 HOME）
(
  TMP=$(make_tmp)
  OUTPUT=$(CLAUDE_CONFIG_DIR="$TMP" bash "$SYNC_SH" 2>&1 || true)
  if assert_contains "$OUTPUT" "未找到插件注册表"; then
    pass "sync-plugin: 注册表缺失时明确报错"
  else
    fail "sync-plugin: 注册表缺失报错" "got: $OUTPUT"
  fi
)

# Test: 有注册记录时同步到 installPath（行为测试，伪注册表 + 伪安装目录）
(
  TMP=$(make_tmp)
  mkdir -p "$TMP/plugins" "$TMP/install-here"
  cat > "$TMP/plugins/installed_plugins.json" << EOF
{"version":2,"plugins":{"minus-creator@fake":[{"installPath":"$TMP/install-here"}]}}
EOF
  OUTPUT=$(CLAUDE_CONFIG_DIR="$TMP" bash "$SYNC_SH" 2>&1 || true)
  if assert_contains "$OUTPUT" "同步完成" && [ -f "$TMP/install-here/skills/minus/SKILL.md" ] \
     && [ ! -d "$TMP/install-here/.git" ]; then
    pass "sync-plugin: 同步到注册表 installPath 并排除 .git"
  else
    fail "sync-plugin: 同步到 installPath" "got: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ uninstall.sh ═══"
# ══════════════════════════════════════════════════════

UNINSTALL_SH="$REPO_DIR/plugins/claude/minus-creator/uninstall.sh"

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

# Test: uninstall.sh 清理自迁移的稳定家目录 minus-creator-marketplace
(
  if grep -q 'minus-creator-marketplace' "$UNINSTALL_SH"; then
    pass "uninstall.sh: 清理稳定家目录 minus-creator-marketplace"
  else
    fail "uninstall.sh: 清理稳定家目录" "未清理 ~/.claude/minus-creator-marketplace，卸载会残留"
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
     && grep -q '\-lt 20' "$PACK_SH"; then
    pass "pack.sh: 重建 bundle 并解析 >=20 node"
  else
    fail "pack.sh: 重建 bundle + node>=20" "missing build.mjs / Volta 回退 / node 版本判断"
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

# Test: 排除 .minus 运行时状态（曾随 zip 分发出去污染安装目录）
(
  if grep -q '"\*/\.minus/\*"' "$PACK_SH"; then
    pass "pack.sh: 排除 .minus 运行时状态"
  else
    fail "pack.sh: 应排除 .minus" "zip 会把 session-counter 等运行时状态带给安装者"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ marketplace.json ═══"
# ══════════════════════════════════════════════════════

# Test: 仓库根 marketplace.json 存在、合法，source 指向真实插件目录且 name 与 plugin.json 一致
(
  MP_JSON="$REPO_DIR/.claude-plugin/marketplace.json"
  if [ -f "$MP_JSON" ] && node -e "
    const mp = require('$MP_JSON');
    const p = mp.plugins.find(x => x.name === 'minus-creator');
    if (!p) process.exit(1);
    const path = require('path').join('$REPO_DIR', p.source);
    const pj = require(path + '/.claude-plugin/plugin.json');
    process.exit(pj.name === p.name ? 0 : 1);
  " 2>/dev/null; then
    pass "marketplace.json: 合法且 source/name 与插件一致（claude plugin marketplace add 可用）"
  else
    fail "marketplace.json: 校验失败" "缺失、JSON 非法、source 目录不存在或 name 不一致"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ run-create-skill.sh ═══"
# ══════════════════════════════════════════════════════

RCS="$SKILL_LIB/run-create-skill.sh"

# 隔离：run-create-skill.sh 按自身 SCRIPT_DIR 解析 resolve-node.sh / bootstrap-env.sh 兄弟文件，
# 故复制真脚本到临时 lib、桩化两个兄弟，再桩化 node/npm/volta，整条创建流程可在本机离线跑。
# node 桩：-p 读 $3 指向的 package.json 取 version（脚本探测已装 create-skill 版本即走此路）。
# npm 桩：view 回固定 EXPECTED 版本；其余命令成功即可。
# volta 桩：install 时按需写出 image package.json（版本可控）与 bin/create-skill（可控存在性）。
setup_rcs() {
  # $1=TMP；落盘 lib（真脚本 + 桩兄弟）与 sb（node/npm 桩）。EXPECTED 固定 1.2.3。
  local TMP="$1" LIB="$1/lib" SB="$1/sb"
  mkdir -p "$LIB" "$SB" "$TMP/.volta/bin"
  cp "$RCS" "$LIB/run-create-skill.sh"
  write_stub "$LIB" resolve-node.sh "echo \"$SB/node\""
  # bootstrap 桩须提供 ensure_project_node 依赖的 NODE_FLOOR / provision_node_via_volta；
  # 默认 provision 成功（关注 node24 配给的用例会按需覆盖本桩）。
  write_stub "$LIB" bootstrap-env.sh 'NODE_FLOOR=24
setup_cn_mirror() { :; }
provision_node_via_volta() { return 0; }'
  write_stub "$SB" node 'case "$1" in -v) echo v24.16.0;; -p) f="$3"; if [ -n "$f" ] && [ -f "$f" ]; then sed -n '"'"'s/.*"version"[: ]*"\([^"]*\)".*/\1/p'"'"' "$f"; fi;; *) echo 24;; esac'
  write_stub "$SB" npm 'case "$1" in view) echo 1.2.3;; *) exit 0;; esac'
  # 默认预置一份 ≥NODE_FLOOR 的 Volta node image → ensure_project_node 命中、跳过 provision，
  # 让既有创建流程用例不受 node24 配给逻辑干扰。
  mkdir -p "$TMP/.volta/tools/image/node/24.16.0"
}

# Test: Volta happy path —— node 合格 + volta 装好版本==EXPECTED + bin 存在 → 执行 create-skill
(
  TMP=$(make_tmp); setup_rcs "$TMP"
  VB="$TMP/.volta/bin"; IMG="$TMP/.volta/tools/image/packages/@minus-ai/create-skill/lib/node_modules/@minus-ai/create-skill"
  write_stub "$VB" volta "echo \"volta \$*\" >> $TMP/volta.log
mkdir -p '$IMG'
printf '{\"version\":\"1.2.3\"}' > '$IMG/package.json'
printf '#!/bin/bash\necho \"create-skill \$*\" >> $TMP/cs.log\n' > '$VB/create-skill'
chmod +x '$VB/create-skill'"
  : > "$TMP/volta.log"
  OUTPUT=$(HOME="$TMP" PATH="$TMP/sb:/usr/bin:/bin" bash "$TMP/lib/run-create-skill.sh" my-skill 2>&1)
  if ! assert_contains "$OUTPUT" "CREATE_SKILL_INSTALL_FAILED" \
     && [ -f "$TMP/cs.log" ] && assert_contains "$(cat "$TMP/cs.log")" "my-skill"; then
    pass "run-create-skill: Volta happy path → 执行 create-skill"
  else
    fail "run-create-skill: Volta happy path" "out: $OUTPUT; cs.log: $(cat "$TMP/cs.log" 2>/dev/null)"
  fi
)

# Test: 首次 volta install 版本≠EXPECTED → 改用官方源重试到一致 → 成功执行
(
  TMP=$(make_tmp); setup_rcs "$TMP"
  VB="$TMP/.volta/bin"; IMG="$TMP/.volta/tools/image/packages/@minus-ai/create-skill/lib/node_modules/@minus-ai/create-skill"
  # @beta 装出陈旧 0.0.1；@1.2.3（重试）才装出 EXPECTED 并落 bin
  write_stub "$VB" volta "echo \"volta \$*\" >> $TMP/volta.log
mkdir -p '$IMG'
case \"\$2\" in
  @minus-ai/create-skill@1.2.3) printf '{\"version\":\"1.2.3\"}' > '$IMG/package.json'; printf '#!/bin/bash\necho \"create-skill \$*\" >> $TMP/cs.log\n' > '$VB/create-skill'; chmod +x '$VB/create-skill';;
  *) printf '{\"version\":\"0.0.1\"}' > '$IMG/package.json';;
esac"
  : > "$TMP/volta.log"
  OUTPUT=$(HOME="$TMP" PATH="$TMP/sb:/usr/bin:/bin" bash "$TMP/lib/run-create-skill.sh" my-skill 2>&1)
  if assert_contains "$OUTPUT" "改用官方 npm 源重试" \
     && ! assert_contains "$OUTPUT" "CREATE_SKILL_INSTALL_FAILED" \
     && [ -f "$TMP/cs.log" ]; then
    pass "run-create-skill: 版本不一致 → 官方源重试到一致后执行"
  else
    fail "run-create-skill: 版本不一致重试" "out: $OUTPUT; volta.log: $(cat "$TMP/volta.log")"
  fi
)

# Test（回归改动1）：volta 报版本==EXPECTED 但 bin/create-skill 缺失 → CREATE_SKILL_INSTALL_FAILED，
# 绝不去执行不存在的文件。撤掉 Volta 分支的 -x 校验，本用例应由绿转红。
(
  TMP=$(make_tmp); setup_rcs "$TMP"
  VB="$TMP/.volta/bin"; IMG="$TMP/.volta/tools/image/packages/@minus-ai/create-skill/lib/node_modules/@minus-ai/create-skill"
  # 版本对得上，但故意不写 bin/create-skill
  write_stub "$VB" volta "echo \"volta \$*\" >> $TMP/volta.log
mkdir -p '$IMG'
printf '{\"version\":\"1.2.3\"}' > '$IMG/package.json'"
  : > "$TMP/volta.log"
  OUTPUT=$(HOME="$TMP" PATH="$TMP/sb:/usr/bin:/bin" bash "$TMP/lib/run-create-skill.sh" my-skill 2>&1)
  if assert_contains "$OUTPUT" "CREATE_SKILL_INSTALL_FAILED" && [ ! -f "$TMP/cs.log" ]; then
    pass "run-create-skill: 版本符但 bin 缺失 → INSTALL_FAILED，不执行不存在文件"
  else
    fail "run-create-skill: bin 缺失应 INSTALL_FAILED" "out: $OUTPUT; cs.log 存在? $([ -f "$TMP/cs.log" ] && echo yes || echo no)"
  fi
)

# Test: resolve-node 解析不到合格 node → NO_GOOD_NODE，不进入安装流程
(
  TMP=$(make_tmp); setup_rcs "$TMP"
  write_stub "$TMP/lib" resolve-node.sh 'exit 0'   # 不输出任何路径
  OUTPUT=$(HOME="$TMP" PATH="$TMP/sb:/usr/bin:/bin" bash "$TMP/lib/run-create-skill.sh" my-skill 2>&1)
  if assert_contains "$OUTPUT" "NO_GOOD_NODE"; then
    pass "run-create-skill: 无合格 node → NO_GOOD_NODE"
  else
    fail "run-create-skill: 无合格 node → NO_GOOD_NODE" "out: $OUTPUT"
  fi
)

# Test: 缺项目名 → CREATE_SKILL_MISSING_NAME
(
  TMP=$(make_tmp); setup_rcs "$TMP"
  OUTPUT=$(HOME="$TMP" PATH="$TMP/sb:/usr/bin:/bin" bash "$TMP/lib/run-create-skill.sh" 2>&1)
  if assert_contains "$OUTPUT" "CREATE_SKILL_MISSING_NAME"; then
    pass "run-create-skill: 缺项目名 → CREATE_SKILL_MISSING_NAME"
  else
    fail "run-create-skill: 缺项目名" "out: $OUTPUT"
  fi
)

# Test: 同事场景 —— 机器无 node24 image（只有 node22）→ 创建前自动经 Volta 备好 node24 → 正常创建。
# 验证根因修复：create 路径不再缺 node24 provision，create-skill 第①档命中、不退出。
(
  TMP=$(make_tmp); setup_rcs "$TMP"
  rm -rf "$TMP/.volta/tools/image/node"   # 没有任何已装 node image
  # provision 桩：模拟 volta install node@24 成功并落 image，留 marker 证明确被调用
  write_stub "$TMP/lib" bootstrap-env.sh "NODE_FLOOR=24
setup_cn_mirror() { :; }
provision_node_via_volta() { mkdir -p '$TMP/.volta/tools/image/node/24.16.0'; echo provisioned > '$TMP/provision.log'; return 0; }"
  VB="$TMP/.volta/bin"; IMG="$TMP/.volta/tools/image/packages/@minus-ai/create-skill/lib/node_modules/@minus-ai/create-skill"
  write_stub "$VB" volta "mkdir -p '$IMG'
printf '{\"version\":\"1.2.3\"}' > '$IMG/package.json'
printf '#!/bin/bash\necho \"create-skill \$*\" >> $TMP/cs.log\n' > '$VB/create-skill'
chmod +x '$VB/create-skill'"
  OUTPUT=$(HOME="$TMP" PATH="$TMP/sb:/usr/bin:/bin" bash "$TMP/lib/run-create-skill.sh" my-skill 2>&1)
  if [ -f "$TMP/provision.log" ] \
     && ! assert_contains "$OUTPUT" "NODE24_PROVISION_FAILED" \
     && [ -f "$TMP/cs.log" ]; then
    pass "run-create-skill: 无 node24 → 自动 Volta provision → 正常创建"
  else
    fail "run-create-skill: 无 node24 自动 provision" "out: $OUTPUT; provision: $([ -f "$TMP/provision.log" ] && echo yes || echo no); cs: $([ -f "$TMP/cs.log" ] && echo yes || echo no)"
  fi
)

# Test（第二层防护）：node24 provision 失败 → 输出固定标记 NODE24_PROVISION_FAILED，
# 绝不跑 create-skill（cs.log 不产生），也就不会把 create-skill 的「未找到 Node 24+」
# stderr 透传给 Agent 去自行 brew 装 node。
(
  TMP=$(make_tmp); setup_rcs "$TMP"
  rm -rf "$TMP/.volta/tools/image/node"
  write_stub "$TMP/lib" bootstrap-env.sh 'NODE_FLOOR=24
setup_cn_mirror() { :; }
provision_node_via_volta() { return 1; }'
  VB="$TMP/.volta/bin"
  # 即便 create-skill bin 摆在那，也不该被执行
  write_stub "$VB" volta 'exit 0'
  write_stub "$VB" create-skill "echo \"create-skill \$*\" >> $TMP/cs.log"
  OUTPUT=$(HOME="$TMP" PATH="$TMP/sb:/usr/bin:/bin" bash "$TMP/lib/run-create-skill.sh" my-skill 2>&1)
  if assert_contains "$OUTPUT" "NODE24_PROVISION_FAILED" && [ ! -f "$TMP/cs.log" ]; then
    pass "run-create-skill: provision 失败 → 固定标记，不跑 create-skill"
  else
    fail "run-create-skill: provision 失败应固定标记" "out: $OUTPUT; cs 存在? $([ -f "$TMP/cs.log" ] && echo yes || echo no)"
  fi
)

echo "═══ diagnose-mcp.sh ═══"

DIAG="$REPO_DIR/plugins/claude/minus-creator/skills/minus/scripts/diagnose-mcp.sh"

# Test: 脚本存在、单源 toolchain.sh、始终 exit 0（SKILL.md 原样展示其 stdout）
(
  if [ -f "$DIAG" ] && grep -q 'toolchain.sh' "$DIAG"; then
    pass "diagnose-mcp.sh: 存在且下限单源 toolchain.sh"
  else
    fail "diagnose-mcp.sh: 基本结构" "missing file 或未 source toolchain.sh"
  fi
)

# Test: 坏 node（node -v 崩溃 + dyld/simdjson stderr）→ 给「brew reinstall / volta」自救指引
(
  T="$(mktemp -d)"
  printf '#!/bin/sh\necho "dyld: Library not loaded: libsimdjson.31.dylib" >&2; exit 1\n' > "$T/node"
  chmod +x "$T/node"
  OUT=$(PATH="$T:$PATH" bash "$DIAG" 2>&1); RC=$?
  rm -rf "$T"
  if [ "$RC" -eq 0 ] \
     && assert_contains "$OUT" '已损坏' \
     && assert_contains "$OUT" 'brew reinstall node@22' \
     && assert_contains "$OUT" 'volta install node@'; then
    pass "diagnose-mcp.sh: 坏 node → brew/volta 自救指引（exit 0）"
  else
    fail "diagnose-mcp.sh: 坏 node 分支" "rc=$RC out: $OUT"
  fi
)

# Test: PATH 无 node 但 off-path（Volta image）有合格 node → 提示 PATH 没带上 Volta
# 造一个假 HOME，里面塞一个 Volta image 的 node v24 stub；PATH=/usr/bin:/bin（无 node）。
(
  T="$(mktemp -d)"
  VIMG="$T/.volta/tools/image/node/24.0.0/bin"
  mkdir -p "$VIMG"
  printf '#!/bin/sh\ncase "$1" in -v) echo v24.16.0;; -p) echo 24;; *) echo 24;; esac\n' > "$VIMG/node"
  chmod +x "$VIMG/node"
  OUT=$(HOME="$T" PATH=/usr/bin:/bin bash "$DIAG" 2>&1); RC=$?
  rm -rf "$T"
  if [ "$RC" -eq 0 ] \
     && assert_contains "$OUT" '未就绪' \
     && assert_contains "$OUT" 'PATH'; then
    pass "diagnose-mcp.sh: PATH 无 node 但 Volta 有 → 提示 PATH/Volta"
  else
    fail "diagnose-mcp.sh: off-path Volta 分支" "rc=$RC out: $OUT"
  fi
)

# Test: 彻底无 node（PATH 与 off-path 都没有）→ 提示「未检测到 Node」+ install
# 本机系统路径有 node 时无法模拟「彻底无 node」，skip（同 resolve-node 的处理）。
(
  if host_has_abs_modern_node; then
    skip "diagnose-mcp.sh: 彻底无 node → 未检测到 Node" "本机系统路径已有 node，无法模拟彻底无 node"
  else
    T="$(mktemp -d)"
    OUT=$(HOME="$T" PATH=/usr/bin:/bin bash "$DIAG" 2>&1); RC=$?
    rm -rf "$T"
    if [ "$RC" -eq 0 ] && assert_contains "$OUT" '未检测到 Node'; then
      pass "diagnose-mcp.sh: 彻底无 node → 未检测到 Node + install 提示"
    else
      fail "diagnose-mcp.sh: 无 node 分支" "rc=$RC out: $OUT"
    fi
  fi
)

# Test: node 过旧（v18 < NODE_FLOOR 24）→ 提示过旧 + 建议 Node 24
(
  T="$(mktemp -d)"
  printf '#!/bin/sh\necho v18.20.0\n' > "$T/node"
  chmod +x "$T/node"
  OUT=$(PATH="$T:$PATH" HOME="$T/fh" bash "$DIAG" 2>&1); RC=$?
  rm -rf "$T"
  if [ "$RC" -eq 0 ] \
     && assert_contains "$OUT" '过旧' \
     && assert_contains "$OUT" 'Node 24'; then
    pass "diagnose-mcp.sh: 过旧 v18 → 升级 Node 24 提示"
  else
    fail "diagnose-mcp.sh: 过旧分支" "rc=$RC out: $OUT"
  fi
)

# Test: node 看似正常（v24）→ 走「重启/launchd PATH」分支，且不误报「损坏」
(
  T="$(mktemp -d)"
  printf '#!/bin/sh\ncase "$1" in -v) echo v24.16.0;; -p) echo 24;; esac\n' > "$T/node"
  chmod +x "$T/node"
  OUT=$(PATH="$T:$PATH" bash "$DIAG" 2>&1); RC=$?
  rm -rf "$T"
  if [ "$RC" -eq 0 ] \
     && assert_contains "$OUT" '看起来正常' \
     && ! assert_contains "$OUT" '已损坏'; then
    pass "diagnose-mcp.sh: 正常 v24 → 重启/launchd 分支，不误报损坏"
  else
    fail "diagnose-mcp.sh: 正常分支" "rc=$RC out: $OUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ gate.sh（子 skill 前置门禁） ═══"
# ══════════════════════════════════════════════════════

GATE="$REPO_DIR/plugins/claude/minus-creator/scripts/gate.sh"

(
  TMP=$(make_tmp)
  OUTPUT=$(cd "$TMP" && HOME="$TMP" sh "$GATE")
  if assert_contains "$OUTPUT" "GATE=fail reason=NOT_LOGGED_IN" \
     && assert_contains "$OUTPUT" "minus-auth"; then
    pass "gate.sh: 未登录 → NOT_LOGGED_IN + minus-auth 补救提示"
  else
    fail "gate.sh: 未登录分支" "out: $OUTPUT"
  fi
)

(
  TMP=$(make_tmp)
  mkdir -p "$TMP/.minus"
  echo '{"session_id":"s1","user_id":"u1"}' > "$TMP/.minus/credentials.json"
  OUTPUT=$(cd "$TMP" && HOME="$TMP" sh "$GATE")
  if assert_contains "$OUTPUT" "GATE=fail reason=NO_PROJECT" \
     && assert_contains "$OUTPUT" "project-setup.md"; then
    pass "gate.sh: 已登录无项目 → NO_PROJECT + project-setup 补救提示"
  else
    fail "gate.sh: 无项目分支" "out: $OUTPUT"
  fi
)

(
  TMP=$(make_tmp)
  mkdir -p "$TMP/.minus" "$TMP/proj/.minus"
  echo '{"session_id":"s1","user_id":"u1"}' > "$TMP/.minus/credentials.json"
  echo '{"skillId":"t"}' > "$TMP/proj/.minus/skill.json"
  OUTPUT=$(cd "$TMP/proj" && HOME="$TMP" sh "$GATE")
  if assert_contains "$OUTPUT" "GATE=fail reason=ENV_NOT_READY" \
     && assert_contains "$OUTPUT" "env-init.md"; then
    pass "gate.sh: 环境未就绪 → ENV_NOT_READY + env-init 补救提示"
  else
    fail "gate.sh: 环境未就绪分支" "out: $OUTPUT"
  fi
)

(
  TMP=$(make_tmp)
  mkdir -p "$TMP/.minus" "$TMP/proj/.minus" "$TMP/proj/node_modules" "$TMP/proj/.venv"
  echo '{"session_id":"s1","user_id":"u1"}' > "$TMP/.minus/credentials.json"
  echo '{"skillId":"t"}' > "$TMP/proj/.minus/skill.json"
  OUTPUT=$(cd "$TMP/proj" && HOME="$TMP" sh "$GATE")
  if [ "$OUTPUT" = "GATE=ok" ]; then
    pass "gate.sh: 全部就绪 → GATE=ok"
  else
    fail "gate.sh: 就绪分支" "out: $OUTPUT"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ minus-lib（glob 查找新 skill 目录） ═══"
# ══════════════════════════════════════════════════════

MINUS_LIB="$REPO_DIR/plugins/claude/minus-creator/bin/minus-lib"

(
  # 各新 skill 私有目录的脚本均可被裸名分发
  OK=1
  for name in step-tracker generate-node-code generate-steps generate-result-design gate; do
    OUT=$(bash "$MINUS_LIB" "$name" --__probe__ 2>&1) || true
    if echo "$OUT" | grep -q "未找到脚本"; then
      OK=0
      fail "minus-lib: 找不到 $name" "out: $OUT"
    fi
  done
  if [ "$OK" = "1" ]; then
    pass "minus-lib: glob 可定位 minus-step/minus-structure/共享 scripts 下的脚本"
  fi
)

(
  OUT=$(bash "$MINUS_LIB" no-such-script 2>&1) || true
  if assert_contains "$OUT" "未找到脚本"; then
    pass "minus-lib: 未知脚本名报错"
  else
    fail "minus-lib: 未知脚本名" "out: $OUT"
  fi
)

(
  # 脚本名全局唯一：分发器按 scripts/ → skills/*/scripts 顺序取第一个命中，
  # 重名会静默遮蔽后者。在此拦下，而不是等运行时"新脚本不生效"。
  PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
  DUPS=$(
    for d in "$PLUGIN_DIR/scripts" "$PLUGIN_DIR"/skills/*/scripts; do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        [ -f "$f" ] || continue
        basename "$f" .sh
      done
    done | sort | uniq -d
  )
  if [ -z "$DUPS" ]; then
    pass "minus-lib: 脚本名全局唯一（无跨目录遮蔽）"
  else
    PATHS=$(for n in $DUPS; do
      find "$PLUGIN_DIR/scripts" "$PLUGIN_DIR"/skills/*/scripts \
        -maxdepth 1 \( -name "$n" -o -name "$n.sh" \) 2>/dev/null
    done)
    fail "minus-lib: 脚本名全局唯一" "重名脚本会被静默遮蔽: $(echo $PATHS)"
  fi
)

# ══════════════════════════════════════════════════════
echo ""
echo "═══ post-install-check.sh ═══"
# ══════════════════════════════════════════════════════

PIC="$LIB_DIR/post-install-check.sh"

# 构造一个伪 PLUGIN_ROOT（complete=yes 时含全部 MCP 产物）
make_plugin_root() {
  local root="$1"; local complete="$2"
  mkdir -p "$root/mcp-servers/minus-platform/dist"
  if [ "$complete" = "yes" ]; then
    echo "//bundle" > "$root/mcp-servers/minus-platform/dist/minus-platform.cjs"
    echo "//launcher" > "$root/mcp-servers/minus-platform/launch.cjs"
  fi
}

# Test: 产物齐全 → 静默成功（hook 模式不污染会话上下文）
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  make_plugin_root "$TMP/plugin" yes
  OUTPUT=$(bash "$PIC" "$TMP/plugin" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUTPUT" ]; then
    pass "post-install-check: 产物齐全 → 静默 exit 0"
  else
    fail "post-install-check: 产物齐全应静默" "rc=$RC out: $OUTPUT"
  fi
)

# Test: 缺产物，hook 模式 → 输出补救指引但 exit 0（不阻塞会话）
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  make_plugin_root "$TMP/plugin" no
  OUTPUT=$(bash "$PIC" "$TMP/plugin" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && assert_contains "$OUTPUT" "minus-platform.cjs" \
     && assert_contains "$OUTPUT" "claude plugin install"; then
    pass "post-install-check: 缺产物 hook 模式 → 补救指引 + exit 0"
  else
    fail "post-install-check: 缺产物 hook 模式" "rc=$RC out: $OUTPUT"
  fi
)

# Test: 缺产物，--strict 模式 → exit 1（install.sh 据此中止）
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  make_plugin_root "$TMP/plugin" no
  RC=0; OUTPUT=$(bash "$PIC" --strict "$TMP/plugin" 2>&1) || RC=$?
  if [ "$RC" -eq 1 ]; then
    pass "post-install-check: 缺产物 --strict → exit 1"
  else
    fail "post-install-check: 缺产物 --strict 应 exit 1" "rc=$RC out: $OUTPUT"
  fi
)

# Test: 陈旧 temp_local_* 残留被清理；新鲜的（可能正在安装）保留
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  make_plugin_root "$TMP/plugin" yes
  CACHE="$TMP/cache"
  mkdir -p "$CACHE/temp_local_stale" "$CACHE/temp_local_fresh"
  # 陈旧目录：mtime 拨到 2 小时前（mac 用 -v，linux 用 -d）
  touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$CACHE/temp_local_stale"
  MINUS_CACHE_ROOT="$CACHE" bash "$PIC" "$TMP/plugin" >/dev/null 2>&1
  if [ ! -d "$CACHE/temp_local_stale" ] && [ -d "$CACHE/temp_local_fresh" ]; then
    pass "post-install-check: 清理陈旧 temp_local_*，保留新鲜目录"
  else
    fail "post-install-check: temp_local_* 清理" "stale: $([ -d "$CACHE/temp_local_stale" ] && echo 还在 || echo 已清), fresh: $([ -d "$CACHE/temp_local_fresh" ] && echo 还在 || echo 被误删)"
  fi
)

# Test: Node 过旧（v18 桩）且无合格备选 → 指示 Agent 跑 bootstrap-env，受众是 Agent 而非用户
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  make_plugin_root "$TMP/plugin" yes
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nif [ "$1" = "-p" ]; then echo 18; else echo v18.0.0; fi\n' > "$TMP/bin/node"
  chmod +x "$TMP/bin/node"
  OUTPUT=$(PATH="$TMP/bin:/usr/bin:/bin" MINUS_NODE_CANDIDATES="$TMP/none" bash "$PIC" "$TMP/plugin" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && assert_contains "$OUTPUT" "minus-lib bootstrap-env" \
     && assert_contains "$OUTPUT" "不是程序员"; then
    pass "post-install-check: Node 过旧 → 指示 Agent 自动跑 bootstrap-env"
  else
    fail "post-install-check: Node 过旧分支" "rc=$RC out: $OUTPUT"
  fi
)

# Test: PATH 无合格 node 但备选位置（如 Volta）有 → 静默，不误报
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  make_plugin_root "$TMP/plugin" yes
  mkdir -p "$TMP/bin" "$TMP/volta"
  printf '#!/bin/sh\nif [ "$1" = "-p" ]; then echo 18; else echo v18.0.0; fi\n' > "$TMP/bin/node"
  printf '#!/bin/sh\nif [ "$1" = "-p" ]; then echo 24; else echo v24.0.0; fi\n' > "$TMP/volta/node"
  chmod +x "$TMP/bin/node" "$TMP/volta/node"
  OUTPUT=$(PATH="$TMP/bin:/usr/bin:/bin" MINUS_NODE_CANDIDATES="$TMP/volta/node" bash "$PIC" "$TMP/plugin" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUTPUT" ]; then
    pass "post-install-check: 备选位置有合格 node → 静默不误报"
  else
    fail "post-install-check: 备选 node 探测" "rc=$RC out: $OUTPUT"
  fi
)

# Test: --strict 模式跳过 Node 检查（install.sh 有自己的交互式 gate）
(
  TMP=$(make_tmp)
  export HOME="$TMP"
  make_plugin_root "$TMP/plugin" yes
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nif [ "$1" = "-p" ]; then echo 18; else echo v18.0.0; fi\n' > "$TMP/bin/node"
  chmod +x "$TMP/bin/node"
  RC=0; OUTPUT=$(PATH="$TMP/bin:/usr/bin:/bin" MINUS_NODE_CANDIDATES="$TMP/none" bash "$PIC" --strict "$TMP/plugin" 2>&1) || RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUTPUT" ]; then
    pass "post-install-check: --strict 跳过 Node 检查"
  else
    fail "post-install-check: --strict 应跳过 Node 检查" "rc=$RC out: $OUTPUT"
  fi
)

# Test: hooks.json 已注册 post-install-check 到 SessionStart（机制接线，不靠人记得）
(
  HOOKS_JSON="$REPO_DIR/plugins/claude/minus-creator/hooks/hooks.json"
  if node -e '
    const h=require(process.argv[1]).hooks.SessionStart.flatMap(g=>g.hooks);
    process.exit(h.some(x=>x.command.includes("post-install-check.sh"))?0:1);
  ' "$HOOKS_JSON"; then
    pass "hooks.json: SessionStart 已注册 post-install-check.sh"
  else
    fail "hooks.json: SessionStart 应注册 post-install-check.sh" "未找到注册项"
  fi
)

# Test: install.sh 不再内联产物校验，而是调用单源脚本
(
  INSTALL_SH="$REPO_DIR/plugins/claude/minus-creator/install.sh"
  if grep -q 'post-install-check.sh" --strict' "$INSTALL_SH" \
     && ! grep -q 'MCP_DIR/dist/minus-platform.cjs' "$INSTALL_SH"; then
    pass "install.sh: 产物校验委托给 post-install-check.sh（单源）"
  else
    fail "install.sh: 产物校验应委托单源脚本" "内联校验未移除或未调用 --strict"
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
