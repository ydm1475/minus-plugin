#!/bin/bash
# progress-saver.sh
# 将当前开发状态写入 Claude Code Memory

MINUS_JSON=".minus/skill.json"
MEMORY_DIR=".claude/memory"
PROGRESS_FILE="$MEMORY_DIR/minus-progress.md"

if [ ! -f "$MINUS_JSON" ]; then
  echo "错误：未找到 .minus/skill.json，不在 Minus Skill 项目目录中" >&2
  exit 1
fi

mkdir -p "$MEMORY_DIR" 2>/dev/null

SKILL_ID=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$MINUS_JSON','utf8')).skillId||'unknown')}catch(e){console.log('unknown')}" 2>/dev/null)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

cat > "$PROGRESS_FILE" << EOF
# Minus 开发进度

## 项目：$SKILL_ID
- 更新时间：$TIMESTAMP
- 自动保存（由 Plugin 在 session 切换时生成）

## 说明
此文件由 Plugin 自动生成，记录开发进度以便在新 session 中恢复。
具体的步骤状态请通过平台 API 查询。
EOF

echo "进度已保存到 $PROGRESS_FILE"
