#!/bin/bash
# tests/env-matrix/run.sh — 环境矩阵场景驱动器
#
# 用法：
#   bash tests/env-matrix/run.sh                  # local scope：跳过破坏性场景（07/09 及需 sudo 的子断言）
#   bash tests/env-matrix/run.sh --scope ci       # CI scope：全场景实跑（一次性 runner 上用）
#   bash tests/env-matrix/run.sh --only 03        # 只跑指定编号（调试）
#
# 环境：MATRIX_OLD_NODE 见 lib.sh 头注释（CI workflow 注入）。

set -u
EM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCOPE="local"; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --only)  ONLY="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done
export MATRIX_SCOPE="$SCOPE"

# CI-only 场景（真实安装，污染环境）：local scope 下整场景跳过
CI_ONLY="07 09"

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0; FAILED_SCENARIOS=""

echo "▶ Env Matrix（scope=$SCOPE, os=$(uname -s)）"
for sc in "$EM_DIR"/scenarios/*.sh; do
  name="$(basename "$sc" .sh)"
  num="${name%%-*}"
  [ -n "$ONLY" ] && [ "$num" != "$ONLY" ] && continue
  case " $CI_ONLY " in
    *" $num "*)
      if [ "$SCOPE" != "ci" ]; then
        echo "— $name"
        echo "  ○ 整场景 (skip: CI-only，真实安装会污染本机)"
        TOTAL_SKIP=$((TOTAL_SKIP+1))
        continue
      fi ;;
  esac
  echo "— $name"
  OUT="$(bash "$sc" 2>&1)"; RC=$?
  echo "$OUT"
  # 汇总各场景小结行（— pass=N fail=N skip=N）。
  # 场景中途崩掉时没有小结行——提取值必须兜底 0（空值会让算术展开语法错误，
  # bash 会把整个 for 循环打断，后续场景被静默跳过且退出码仍为 0，实测翻过车），
  # 且「无小结行」本身就视为场景失败。
  s="$(echo "$OUT" | grep -o 'pass=[0-9]* fail=[0-9]* skip=[0-9]*' | tail -1)"
  p="$(echo "$s" | sed -n 's/.*pass=\([0-9]*\).*/\1/p')"
  f="$(echo "$s" | sed -n 's/.*fail=\([0-9]*\).*/\1/p')"
  k="$(echo "$s" | sed -n 's/.*skip=\([0-9]*\).*/\1/p')"
  TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
  TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))
  TOTAL_SKIP=$((TOTAL_SKIP + ${k:-0}))
  if [ $RC -ne 0 ] || [ -z "$s" ]; then
    FAILED_SCENARIOS="$FAILED_SCENARIOS $name"
  fi
done

echo ""
echo "Env Matrix 汇总：pass=$TOTAL_PASS fail=$TOTAL_FAIL skip=$TOTAL_SKIP"
if [ -n "$FAILED_SCENARIOS" ]; then
  echo "失败场景：$FAILED_SCENARIOS"
  exit 1
fi
# CI 上不允许意外 skip（07/09 必须实跑；MATRIX_OLD_NODE 必须就位）
if [ "$SCOPE" = "ci" ] && [ "$TOTAL_SKIP" -gt 2 ]; then
  echo "CI scope 下 skip 过多（>2，仅允许 OS-only 场景互跳），视为配置缺陷"
  exit 1
fi
exit 0
