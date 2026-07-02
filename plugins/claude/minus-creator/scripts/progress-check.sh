#!/bin/bash
# progress-check.sh
# 进度自愈：从硬产物（pipeline.py 占位标记、.minus/total-steps）
# 单向收敛 .minus/progress.json，兜底 Agent 漏调 update-progress.sh。
# 挂载于 SessionStart 与 Stop hook；非 Minus 项目目录静默退出。
# 收敛方向只允许"少标 → 补标"，禁止把人工确认的 ready 降级。

set -uo pipefail

[ -f ".minus/skill.json" ] || exit 0
[ -f "pipeline.py" ] || exit 0

TRACKER_DIR=".minus/dev-progress"
PROGRESS_FILE=".minus/progress.json"

# 结构设计未完成（design-done 尚未原子写入 total-steps）时不做自愈判断，
# 避免把 create-skill 生成的初始占位 step（无 TODO 标记）误判为"已开发完成"
[ -f ".minus/total-steps" ] || exit 0

# 双重防护：phase 仍处于 designing 时同样跳过
if [ -f "$PROGRESS_FILE" ]; then
  PHASE=$(node -e '
    try {
      const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      process.stdout.write(p.phase || "");
    } catch (e) {}
  ' "$PROGRESS_FILE" 2>/dev/null)
  [ "$PHASE" != "designing" ] || exit 0
fi

TOTAL=$(cat .minus/total-steps)
[ "$TOTAL" -ge 1 ] 2>/dev/null || exit 0

# 收集每步硬产物完成证据：step_N 无骨架占位
HARD_DONE=""
for STEP in $(seq 1 "$TOTAL"); do
  if ! awk -v step="$STEP" '
      $0 ~ "async def step_" step "\\(" { inside = 1; next }
      inside && /async def step_[0-9]/ { inside = 0 }
      inside && /# TODO: 实现「/ { found = 1 }
      END { exit found ? 0 : 1 }
    ' pipeline.py; then
    HARD_DONE="$HARD_DONE $STEP"
  fi
done

SUMMARY=$(PROGRESS_FILE="$PROGRESS_FILE" TOTAL_STEPS="$TOTAL" \
  HARD_DONE="$HARD_DONE" \
  PROGRESS_TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" node -e '
  const fs = require("fs");
  const file = process.env.PROGRESS_FILE;
  const total = Number(process.env.TOTAL_STEPS);
  const hardDone = new Set(process.env.HARD_DONE.trim().split(/\s+/).filter(Boolean).map(Number));

  // 步骤名（重建用）：从 pipeline.py 的骨架占位注释提取
  const names = {};
  try {
    const code = fs.readFileSync("pipeline.py", "utf8");
    let cur = null;
    for (const line of code.split("\n")) {
      const def = line.match(/async def step_(\d+)\(/);
      if (def) { cur = def[1]; continue; }
      const todo = line.match(/# TODO: 实现「(.*)」/);
      if (cur && todo) { names[cur] = todo[1]; cur = null; }
    }
  } catch (e) {}

  let p = null;
  try { p = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}

  const fixes = [];
  if (!p || typeof p !== "object" || !p.steps || Object.keys(p.steps).length === 0) {
    // 能走到这里说明 pipeline.py 已有步骤骨架（结构设计已完成），收敛到 developing；
    // 但人工确认过的 ready 不降级
    const keepPhase = p && (p.phase === "ready" || p.phase === "testing") ? p.phase : "developing";
    p = { currentStep: 0, steps: {}, phase: keepPhase };
    fixes.push("重建 steps");
  }
  p.steps = p.steps || {};

  // 补齐缺失步骤条目
  for (let n = 1; n <= total; n++) {
    if (!p.steps[String(n)]) {
      p.steps[String(n)] = { name: names[String(n)] || "步骤" + n, status: "pending" };
      if (!fixes.includes("重建 steps")) fixes.push("补步骤 " + n);
    }
  }

  // 硬产物显示完成但状态未标 → 补标 completed
  for (const n of hardDone) {
    const s = p.steps[String(n)];
    if (s && s.status !== "completed") {
      s.status = "completed";
      fixes.push("步骤 " + n + " 补标 completed");
    }
  }

  // currentStep 重算 = 第一个非 completed 步骤号（全完成 = total）
  let cur = total;
  for (let n = 1; n <= total; n++) {
    if (p.steps[String(n)].status !== "completed") { cur = n; break; }
  }
  if (p.currentStep !== cur) {
    p.currentStep = cur;
    fixes.push("currentStep → " + cur);
  }

  // 全完成且仍 developing → testing（不动 designing/ready）
  const allDone = Object.values(p.steps).every((s) => s.status === "completed");
  if (allDone && p.phase === "developing") {
    p.phase = "testing";
    fixes.push("phase → testing");
  }

  if (fixes.length > 0) {
    p.updatedAt = process.env.PROGRESS_TS;
    fs.writeFileSync(file, JSON.stringify(p, null, 2) + "\n");
    console.log(fixes.join("；"));
  }
' 2>/dev/null) || exit 0

if [ -n "$SUMMARY" ]; then
  echo "[进度自愈] progress.json 已根据代码与开发标记修正：$SUMMARY"
fi
exit 0
