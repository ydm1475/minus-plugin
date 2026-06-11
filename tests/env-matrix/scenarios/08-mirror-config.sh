#!/bin/bash
# 场景 08：镜像配置落盘（MINUS_MIRROR on/off）
# 断言：on → 项目目录写入带 managed-by 标记的 .npmrc/uv.toml 并进 .gitignore；
#       off → 托管文件被移除、不残留
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
scenario_setup

PROJ="$SCENARIO_TMP/proj"; mkdir -p "$PROJ"

# source bootstrap-env.sh 只暴露函数（主流程有直接执行 guard），在子 shell 内按开关调用
run_mirror() { # $1=on|off
  ( cd "$PROJ" && MINUS_MIRROR="$1" bash -c '
      . "'"$BOOTSTRAP_ENV"'"
      setup_cn_mirror
      write_project_mirror_config
    ' ) >/dev/null 2>&1
}

run_mirror on
if head -1 "$PROJ/.npmrc" 2>/dev/null | grep -q "managed-by: minus"; then
  pass "MINUS_MIRROR=on：.npmrc 落盘且带 managed-by 标记"
else
  fail "MINUS_MIRROR=on：.npmrc" "missing or unmarked: [$(head -1 "$PROJ/.npmrc" 2>/dev/null)]"
fi
if head -1 "$PROJ/uv.toml" 2>/dev/null | grep -q "managed-by: minus"; then
  pass "MINUS_MIRROR=on：uv.toml 落盘且带 managed-by 标记"
else
  fail "MINUS_MIRROR=on：uv.toml" "missing or unmarked"
fi
if grep -qxF ".npmrc" "$PROJ/.gitignore" 2>/dev/null && grep -qxF "uv.toml" "$PROJ/.gitignore" 2>/dev/null; then
  pass "MINUS_MIRROR=on：.gitignore 已忽略托管文件"
else
  fail "MINUS_MIRROR=on：.gitignore" "$(cat "$PROJ/.gitignore" 2>/dev/null)"
fi

# 用户自有 .npmrc 必须保留不动
echo "registry=https://my.example" > "$PROJ/.npmrc"
run_mirror on
if [ "$(head -1 "$PROJ/.npmrc")" = "registry=https://my.example" ]; then
  pass "用户自有 .npmrc：保留不动"
else
  fail "用户自有 .npmrc" "被覆盖为 [$(head -1 "$PROJ/.npmrc")]"
fi
rm -f "$PROJ/.npmrc"; run_mirror on  # 恢复托管态

run_mirror off
if [ ! -e "$PROJ/.npmrc" ] && [ ! -e "$PROJ/uv.toml" ]; then
  pass "MINUS_MIRROR=off：托管文件零残留"
else
  fail "MINUS_MIRROR=off：残留" "$(ls "$PROJ")"
fi

scenario_summary
