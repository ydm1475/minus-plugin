#!/usr/bin/env bash
# generate-steps.sh
# 根据步骤列表自动生成 pipeline.py 和 main.tsx 的骨架代码
# 用法: generate-steps.sh [--input-type keyword|asin|file|default] "步骤1名称" ...
#       generate-steps.sh --append "新步骤名称" ...
#       generate-steps.sh --insert-at <N> "新步骤名称"
#       generate-steps.sh --delete <N>
# 必须在 Skill 项目根目录下执行
#
# ⚠ 骨架占位标记「# TODO: 实现「」被 update-progress.sh（step-done 门禁）和
#   progress-check.sh（自愈重建）依赖，修改此模板需同步两处。

set -euo pipefail

GS_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_PROGRESS="$GS_SCRIPT_DIR/../../../scripts/update-progress.sh"

MODE=""
INPUT_TYPE=""
INSERT_AT=""
DELETE_AT=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --append) MODE=append; shift ;;
    --insert-at) MODE=insert; INSERT_AT="$2"; shift 2 ;;
    --delete) MODE=delete; DELETE_AT="$2"; shift 2 ;;
    --input-type) INPUT_TYPE="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [ "$MODE" != "delete" ] && [ $# -eq 0 ]; then
  echo "用法: generate-steps.sh [--input-type keyword|asin|file|default] \"步骤1名称\" ..." >&2
  echo "       generate-steps.sh --append \"新步骤名称\" ..." >&2
  echo "       generate-steps.sh --insert-at <N> \"新步骤名称\"" >&2
  echo "       generate-steps.sh --delete <N>" >&2
  exit 1
fi

if [ ! -f ".minus/skill.json" ]; then
  echo "错误：当前目录不是 Minus Skill 项目（未找到 .minus/skill.json）" >&2
  exit 1
fi

if [ ! -f "pipeline.py" ]; then
  echo "错误：未找到 pipeline.py" >&2
  exit 1
fi

# ── --insert-at 模式 ──
if [ "$MODE" = "insert" ]; then
  node "$GS_SCRIPT_DIR/restructure.cjs" insert "$INSERT_AT" "$1"
  exit 0
fi

# ── --delete 模式 ──
if [ "$MODE" = "delete" ]; then
  node "$GS_SCRIPT_DIR/restructure.cjs" delete "$DELETE_AT"
  exit 0
fi

# ── --append 模式 ──
if [ "$MODE" = "append" ]; then
  node "$GS_SCRIPT_DIR/restructure.cjs" append "$@"
  exit 0
fi

STEP_COUNT=$#
STEP_NAMES=("$@")

# ── 调用 restructure.cjs generate（原子写入 pipeline.py + main.tsx + progress.json + total-steps）──
node "$GS_SCRIPT_DIR/restructure.cjs" generate "${STEP_NAMES[@]}"

echo "✓ pipeline.py 已生成 ${STEP_COUNT} 个步骤"

MAIN_TSX="frontend/src/main.tsx"
if [ ! -f "$MAIN_TSX" ]; then
  echo "⚠ 未找到 ${MAIN_TSX}，跳过前端更新" >&2
fi

# ── 根据输入类型更新 renderHistoryItem ──
if [ -n "$INPUT_TYPE" ]; then
  case "$INPUT_TYPE" in
    keyword) LABEL_FIELD="keywords" ;;
    asin)    LABEL_FIELD="asins" ;;
    file)    LABEL_FIELD="fileName" ;;
    *)       LABEL_FIELD="text" ;;
  esac

  node -e "
const fs = require('fs');
let code = fs.readFileSync('${MAIN_TSX}', 'utf8');
const pattern = /label:\s*inp\?\\.\w+\s*\?\?\s*'—'/;
if (pattern.test(code)) {
  code = code.replace(pattern, \"label: inp?.${LABEL_FIELD} ?? '—'\");
  fs.writeFileSync('${MAIN_TSX}', code);
  console.log('✓ renderHistoryItem 已更新为 inp?.${LABEL_FIELD}');
} else {
  console.log('⚠ 未找到 renderHistoryItem label 模式，跳过');
}
" 2>&1
fi

# ── 输出 node-dev.md 指令（硬编码注入，不依赖 agent 自觉去 Read）──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_DEV="$SCRIPT_DIR/../../minus-step/node-dev.md"
if [ -f "$NODE_DEV" ]; then
  echo "═══════════════════════════════════════════════════════"
  echo "  步骤骨架已生成。逐节点开发必须严格按以下流程执行："
  echo "═══════════════════════════════════════════════════════"
  echo ""
  # 去掉 frontmatter，只输出正文
  sed '1,/^---$/{ /^---$/!d; /^---$/d; }; /^---$/,/^---$/d' "$NODE_DEV"
fi
