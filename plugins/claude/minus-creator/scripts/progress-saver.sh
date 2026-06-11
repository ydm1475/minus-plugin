#!/bin/bash
# progress-saver.sh
# 将当前开发状态写入 .minus/progress.json

MINUS_JSON=".minus/skill.json"
PROGRESS_FILE=".minus/progress.json"

if [ ! -f "$MINUS_JSON" ]; then
  echo "错误：未找到 .minus/skill.json，不在 Minus Skill 项目目录中" >&2
  exit 1
fi

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

if [ -f "$PROGRESS_FILE" ]; then
  # 更新 updatedAt
  node -e "
    const fs = require('fs');
    const p = JSON.parse(fs.readFileSync('$PROGRESS_FILE','utf8'));
    p.updatedAt = '$TIMESTAMP';
    fs.writeFileSync('$PROGRESS_FILE', JSON.stringify(p, null, 2) + '\n');
  " 2>/dev/null
else
  # 初始化空进度
  cat > "$PROGRESS_FILE" << EOF
{
  "currentStep": 0,
  "steps": {},
  "phase": "designing",
  "updatedAt": "$TIMESTAMP"
}
EOF
fi

echo "进度已保存到 $PROGRESS_FILE"
