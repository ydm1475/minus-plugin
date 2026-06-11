#!/bin/bash
# 场景 07（CI-only）：真实 Volta 自动安装链路
# 干净假 HOME + 无 node PATH → bootstrap-env.sh 的 ensure_volta/provision_node_via_volta
# 真下载 Volta、真装 node@NODE_TARGET，断言整条链可用。
# 本机绝不跑（写 ~/.volta 级别的真实安装），由 run.sh 的 CI_ONLY 拦截兜底，这里再自检一次。
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
scenario_setup

if ! is_ci; then
  skip "真实 Volta 安装链路" "CI-only"
  scenario_summary; exit $?
fi

# 真安装需要 curl/winget 等网络工具；PATH 用裁剪版（无 node）。
# Windows 用【真实】HOME/LOCALAPPDATA：winget/volta 是机器级安装，假 LOCALAPPDATA 会和
# Windows 原生进程的路径语义打架（实测 zip 落假目录、image 散落两边、shim 不落地）。
# runner 一次性，污染无虞，且真实目录恰是真实用户机器的形态。mac 仍用假 HOME 隔离。
if is_windows; then
  EHOME="$HOME"; ELA="${LOCALAPPDATA:-}"
else
  EHOME="$FAKE_HOME"; ELA="$FAKE_LOCALAPPDATA"
fi
INSTALL_OUT="$(env HOME="$EHOME" LOCALAPPDATA="$ELA" PATH="$CLEAN_PATH" bash -c '
  . "'"$BOOTSTRAP_ENV"'"
  if [ "$OS" = "windows" ]; then
    ensure_volta && volta install "node@${NODE_TARGET}" 2>&1
  else
    provision_node_via_volta 2>&1
  fi
  node_major_ok
' 2>&1)"; RC=$?

if [ $RC -eq 0 ]; then
  pass "bootstrap-env.sh：Volta 真实安装 + node@target 配给成功"
else
  fail "bootstrap-env.sh：Volta 真实安装" "rc=$RC; 输出尾部：$(echo "$INSTALL_OUT" | tail -5)"
fi

# 装完后 resolve-node.sh 应能在同一套 HOME / LOCALAPPDATA 下命中（PATH 仍无 node）
OUT="$(env HOME="$EHOME" LOCALAPPDATA="$ELA" ProgramFiles="$FAKE_PROGRAMFILES" PROGRAMFILES="$FAKE_PROGRAMFILES" PATH="$CLEAN_PATH" sh "$RESOLVE_NODE")"; RC2=$?
if [ $RC2 -eq 0 ] && [ -n "$OUT" ]; then
  pass "resolve-node.sh：命中 Volta 新装的 node（${OUT}）"
else
  fail "resolve-node.sh：装后探测" "rc=$RC2 out=[$OUT]"
  # 诊断：安装全程输出 + volta/node 实际落点
  echo "  [diag] install 输出："
  echo "$INSTALL_OUT" | tail -15 | sed 's/^/    /'
  echo "  [diag] env 内探测：$(env HOME="$EHOME" LOCALAPPDATA="$ELA" PATH="$CLEAN_PATH" bash -c '
    . "'"$BOOTSTRAP_ENV"'" 2>/dev/null
    volta_on_path >/dev/null 2>&1
    echo "volta=$(command -v volta 2>&1) node=$(command -v node 2>&1) node-v=$(node -v 2>&1) volta-which=$(volta which node 2>&1)"' 2>&1)"
  for d in "$EHOME/.volta" "$ELA/Volta"; do
    [ -n "$d" ] && [ -d "$d" ] && echo "  [diag] $d: $(find "$d" \( -name 'node' -o -name 'node.exe' \) 2>/dev/null | head -5)"
  done
fi

scenario_summary
