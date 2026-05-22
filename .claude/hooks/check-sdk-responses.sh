#!/bin/bash
# check-sdk-responses.sh
# SessionStart hook: check for responses from SDK team

RESPONSES_DIR="$HOME/minus-shared/responses"

if [ ! -d "$RESPONSES_DIR" ]; then
  exit 0
fi

pending=""
for f in "$RESPONSES_DIR"/*.md; do
  [ -f "$f" ] || continue
  status=$(grep "^status:" "$f" 2>/dev/null | sed 's/^status: //' | tr -d ' ')
  if [ "$status" = "pending" ] || [ "$status" = "replied" ]; then
    pending="${pending}${f}\n"
  fi
done
pending=$(echo -e "$pending" | sed '/^$/d')

if [ -n "$pending" ]; then
  count=$(echo "$pending" | wc -l | tr -d ' ')
  echo "[SDK 回复] 有 ${count} 条来自 SDK 团队的回复："
  echo ""
  for f in $pending; do
    title=$(grep "^title:" "$f" 2>/dev/null | sed 's/^title: //')
    echo "  → ${title:-$(basename "$f")}"
    echo "    路径: $f"
  done
  echo ""
  echo "[协作规则] 收到回复后必须："
  echo "  1. 先读取并理解回复内容"
  echo "  2. 评估对 Plugin 侧的影响（哪些指令/脚本需要改）"
  echo "  3. 有不理解的地方 → 写追问到 ~/minus-shared/proposals/，不要猜测"
  echo "  4. 确认理解后 → 向用户汇报评估结论，等用户确认再动手改代码"
  echo "  5. 对方标记 resolved 的提案 → 从 References/sdk-improvement-proposals.md 中删除对应条目"
  echo "  禁止：收到回复后直接修改代码"
fi

# no longer using timestamp-based detection
