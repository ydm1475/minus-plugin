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
# 不伪造 ProgramFiles：Windows 上 winget 把 volta.exe 装进真实 Program Files，
# install_volta_windows 要靠它找到刚装的 volta（HOME/LOCALAPPDATA 仍指向假目录隔离 shim/工具链）。
INSTALL_OUT="$(env HOME="$FAKE_HOME" LOCALAPPDATA="$FAKE_LOCALAPPDATA" PATH="$CLEAN_PATH" bash -c '
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

# 装完后 resolve-node.sh 应能在假 HOME / 假 LOCALAPPDATA 命中
OUT="$(env HOME="$FAKE_HOME" LOCALAPPDATA="$FAKE_LOCALAPPDATA" ProgramFiles="$FAKE_PROGRAMFILES" PROGRAMFILES="$FAKE_PROGRAMFILES" PATH="$CLEAN_PATH" sh "$RESOLVE_NODE")"; RC2=$?
if [ $RC2 -eq 0 ] && [ -n "$OUT" ]; then
  pass "resolve-node.sh：命中 Volta 新装的 node（${OUT}）"
else
  fail "resolve-node.sh：装后探测" "rc=$RC2 out=[$OUT]"
fi

scenario_summary
