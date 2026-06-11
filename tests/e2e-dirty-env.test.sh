#!/bin/bash
# E2E 脏环境测试
# 干净 mktemp 目录里跑通 ≠ 用户环境里能活。真实用户环境的特征是「有残留」：
# 上个 session 的 dev server 半死不活、过期的 dev-ports.json、损坏的 progress.json、
# 老 node 遮挡 PATH（实测 2026-06-11：/usr/local/bin/node v12 + 旧 server 占 5173
# 双坑叠加）。本测试先布置这些残留，再经 bin/minus-lib 跑生产路径命令，验证
# 检测/恢复链在脏环境下的行为。
#
# Usage: bash tests/e2e-dirty-env.test.sh

set -euo pipefail
export AUTO_OPEN=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_DIR="$REPO_DIR/plugins/claude/minus-creator"
ML_BIN="$PLUGIN_DIR/bin/minus-lib"

# 套件自身的 node 解析（断言用）；被测命令统一经分发器、且强制从零解析
RESOLVED_NODE="$(sh "$PLUGIN_DIR/scripts/resolve-node.sh" 2>/dev/null || true)"
[ -n "$RESOLVED_NODE" ] && export PATH="$(dirname "$RESOLVED_NODE"):$PATH"

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

skip() {
  echo "  ○ $1 (skip: $2)"
  read P F S < "$RESULTS_FILE"
  echo "$P $F $((S + 1))" > "$RESULTS_FILE"
}

# ── 脏环境布置 ──

BASE=$(mktemp -d)
PROJ="$BASE/proj"
OTHER="$BASE/other-proj"
mkdir -p "$PROJ/.minus" "$OTHER"
echo '{"name":"dirty","skillId":"sk_dirty","version":"1.0.0"}' > "$PROJ/.minus/skill.json"

SRV_PIDS=""
cleanup() {
  [ -n "$SRV_PIDS" ] && { kill $SRV_PIDS 2>/dev/null; wait $SRV_PIDS 2>/dev/null; } || true
  rm -rf "$BASE"
}
trap cleanup EXIT

# 残留 1：v12 假 node 占 PATH 首位（跑 ?? 语法必崩）
OLD_SHIM="$BASE/oldnode"
mkdir -p "$OLD_SHIM"
cat > "$OLD_SHIM/node" <<'FAKE'
#!/bin/bash
if [ "$1" = "-p" ]; then echo 12; exit 0; fi
if [ "$1" = "-v" ]; then echo v12.18.0; exit 0; fi
echo "SyntaxError: Unexpected token '?'" >&2; exit 1
FAKE
chmod +x "$OLD_SHIM/node"
# 重启链路会走到 pnpm：给无害 stub，测试只验清理与解析，不真起 dev server
printf '#!/bin/bash\necho "PNPM_ARGS=$*"\n' > "$OLD_SHIM/pnpm"; chmod +x "$OLD_SHIM/pnpm"

# 生产路径调用：脏 PATH + 强制分发器从零解析 node
run_lib() {
  MINUS_NODE_BIN_DIR= PATH="$OLD_SHIM:$PATH" bash "$ML_BIN" "$@"
}

HAS_PY=0; command -v python3 >/dev/null 2>&1 && HAS_PY=1
HAS_LSOF=0; command -v lsof >/dev/null 2>&1 && HAS_LSOF=1

# 等端口真正可达：CI 冷启动 python 首次 bind 可能 >1s，固定 sleep 有竞态。
# 实测 GH macOS：归属校验在 server 未 bind 时 lsof 查不到 PID，trusted 来源
# 回退 curl 验证——curl 时刚好 bind 上 → 跳过归属校验误放行。
wait_port_up() {
  local W=0
  while [ $W -lt 10 ] && ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/" 2>/dev/null; do
    sleep 1; W=$((W+1))
  done
}

cd "$PROJ"

# ══════════════════════════════════════════════════════
echo "═══ Phase 1: 老 node 遮挡下的进度链 ═══"
# ══════════════════════════════════════════════════════

if OUT=$(run_lib update-progress init-design 2>&1); then RC=0; else RC=$?; fi
if [ "$RC" = "0" ] && grep -q '"designStage": "input_done"' .minus/progress.json 2>/dev/null; then
  pass "update-progress init-design 在 v12 遮挡下成功"
else
  fail "update-progress 应在 v12 遮挡下成功" "rc=$RC out=$OUT"
fi

mkdir -p frontend/src
printf 'function buildSteps(t) {\n  return [];\n}\n' > frontend/src/main.tsx
cat > pipeline.py <<'PYEOF'
from minus_ai_sdk import Pipeline, PipelineContext, StepOutcome

class TestPipeline(Pipeline):
    async def step_1(self, ctx: PipelineContext) -> StepOutcome:
        return StepOutcome.complete(payload={})
PYEOF
if OUT=$(run_lib generate-steps "步骤甲" "步骤乙" 2>&1); then RC=0; else RC=$?; fi
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "2 个步骤" && ! echo "$OUT" | grep -q "SyntaxError"; then
  pass "generate-steps 在 v12 遮挡下生成骨架"
else
  fail "generate-steps 应在 v12 遮挡下成功" "rc=$RC out=$OUT"
fi

# ══════════════════════════════════════════════════════
echo ""
echo "═══ Phase 2: 损坏的 progress.json ═══"
# ══════════════════════════════════════════════════════

printf '{"currentStep": 2, "steps": {INVALID' > .minus/progress.json
if OUT=$(run_lib update-progress init-design 2>&1); then RC=0; else RC=$?; fi
if [ "$RC" = "0" ] && grep -q '"designStage": "input_done"' .minus/progress.json 2>/dev/null; then
  pass "损坏 progress.json → update-progress 自愈重建"
else
  fail "损坏 progress.json 应被重建" "rc=$RC out=$OUT"
fi

if OUT=$(run_lib progress-check 2>&1); then RC=0; else RC=$?; fi
if ! echo "$OUT" | grep -q "SyntaxError"; then
  pass "progress-check 在脏环境下无 SyntaxError"
else
  fail "progress-check 不应 SyntaxError" "out=$OUT"
fi

# ══════════════════════════════════════════════════════
echo ""
echo "═══ Phase 3: 过期 dev-ports.json 指向别人的 server ═══"
# ══════════════════════════════════════════════════════

if [ "$HAS_PY" = "1" ] && [ "$HAS_LSOF" = "1" ]; then
  # 残留 2：端口活着，但属于另一个项目（cwd=$OTHER）——存在 ≠ 属于我
  (cd "$OTHER" && python3 -m http.server 5191 >/dev/null 2>&1) & SRV_PIDS="$SRV_PIDS $!"
  wait_port_up 5191
  echo '{"frontend":5191}' > .minus/dev-ports.json
  if OUT=$(DETECT_PORT_MAX_WAIT=2 run_lib check-dev-server 2>&1); then RC=0; else RC=$?; fi
  if [ "$RC" = "1" ] && echo "$OUT" | grep -q "GATE_FAILED"; then
    pass "非归属 server → 门禁拒绝（GATE_FAILED）"
  else
    fail "非归属 server 应被门禁拒绝" "rc=$RC out=$OUT"
  fi
else
  skip "非归属 server 门禁拒绝" "缺 python3 或 lsof"
fi

# ══════════════════════════════════════════════════════
echo ""
echo "═══ Phase 4: 归属本项目的旧 server 残留 ═══"
# ══════════════════════════════════════════════════════

if [ "$HAS_PY" = "1" ]; then
  # 残留 3：上个 session 的 server 还活着且归属本项目（cwd=$PROJ）
  python3 -m http.server 5192 >/dev/null 2>&1 & SRV_OWNED=$!; SRV_PIDS="$SRV_PIDS $SRV_OWNED"
  wait_port_up 5192
  echo '{"frontend":5192}' > .minus/dev-ports.json

  if OUT=$(DETECT_PORT_MAX_WAIT=2 run_lib check-dev-server 2>&1); then RC=0; else RC=$?; fi
  if [ "$RC" = "0" ] && echo "$OUT" | grep -q "GATE_PASSED" && echo "$OUT" | grep -q "PREVIEW_PORT=5192"; then
    pass "归属本项目的旧 server → 门禁放行"
  else
    fail "归属旧 server 应放行" "rc=$RC out=$OUT"
  fi

  # 143 回归：再启动不应重复起进程，而是复用
  if OUT=$(DETECT_PORT_MAX_WAIT=2 run_lib start-dev full 2>&1); then RC=0; else RC=$?; fi
  if [ "$RC" = "0" ] && echo "$OUT" | grep -q "ALREADY_RUNNING"; then
    pass "旧 server 活着 → start-dev 复用不重复启动（143 回归）"
  else
    fail "start-dev 应输出 ALREADY_RUNNING" "rc=$RC out=$OUT"
  fi

  # 残留 4：前端活、后端死（半死不活的最典型形态）
  echo '{"frontend":5192,"backend":5993}' > .minus/dev-ports.json
  if OUT=$(DETECT_PORT_MAX_WAIT=2 run_lib check-dev-server 2>&1); then RC=0; else RC=$?; fi
  if [ "$RC" = "1" ] && echo "$OUT" | grep -q "BACKEND_DOWN"; then
    pass "前端活后端死 → 门禁拦截（BACKEND_DOWN）"
  else
    fail "半死 server 应被拦截" "rc=$RC out=$OUT"
  fi
else
  skip "归属旧 server 复用/半死拦截" "缺 python3"
fi

# ══════════════════════════════════════════════════════
echo ""
echo "═══ Phase 5: 强制重启清掉归属旧进程（v12 遮挡下）═══"
# ══════════════════════════════════════════════════════

if [ "$HAS_PY" = "1" ] && [ "$HAS_LSOF" = "1" ]; then
  echo '{"frontend":5192}' > .minus/dev-ports.json
  if OUT=$(MINUS_DEV_RESTART=1 run_lib start-dev full 2>&1); then RC=0; else RC=$?; fi
  if ! kill -0 "$SRV_OWNED" 2>/dev/null && [ ! -f .minus/dev-ports.json ] \
     && ! echo "$OUT" | grep -q "SyntaxError"; then
    pass "强制重启：杀归属旧进程 + 删端口记录 + 无 SyntaxError"
  else
    fail "强制重启清理链" "rc=$RC old_alive=$(kill -0 "$SRV_OWNED" 2>/dev/null && echo y || echo n) ports=$([ -f .minus/dev-ports.json ] && echo y || echo n) out=$OUT"
  fi
else
  skip "强制重启清理链" "缺 python3 或 lsof"
fi

# ══════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════

read PASS FAIL SKIP < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo ""
echo "════════════════════════════════════════"
echo "脏环境 E2E: $((PASS + FAIL + SKIP)) tests, $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "ALL PASSED"
