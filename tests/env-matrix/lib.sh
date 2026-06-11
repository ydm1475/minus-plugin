#!/bin/bash
# tests/env-matrix/lib.sh — 环境矩阵测试公共 harness
#
# 职责：为每个场景构造「受控环境」——假 HOME / 假 LOCALAPPDATA / 裁剪 PATH，
# 让 resolve-node.sh / launch.cjs / bootstrap-env.sh 的候选链探测只命中我们铺设的布局。
#
# 候选链里 PATH 裁剪挡不住的绝对路径，分类处理（与计划一致）：
#   ~/.volta ~/.nvm            → 假 HOME（scenario_setup 自动）
#   %LOCALAPPDATA% %ProgramFiles% → 重定向 env 到空临时目录（scenario_setup 自动）
#   /usr/local/bin/node /opt/homebrew/bin/node → CI 上 sudo mv 改名 + trap 恢复；
#                                                本机不动文件系统，场景自行 skip
#
# 环境约定（由 run.sh / CI workflow 注入）：
#   MATRIX_SCOPE=ci|local   ci 下允许破坏性操作（sudo mv、真装 Volta/Claude CLI）
#   MATRIX_OLD_NODE=<path>  一个主版本 < NODE_RUNTIME_FLOOR 的真 node（CI 用 setup-node 18 提供），
#                           用于以老解释器跑 launch.cjs 测它的候选链（execPath 第一位故必须老）

set -u

EM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EM_DIR/../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugins/claude/minus-creator"
RESOLVE_NODE="$PLUGIN_DIR/scripts/resolve-node.sh"
BOOTSTRAP_ENV="$PLUGIN_DIR/scripts/bootstrap-env.sh"
LAUNCH_CJS="$PLUGIN_DIR/mcp-servers/minus-platform/launch.cjs"

MATRIX_SCOPE="${MATRIX_SCOPE:-local}"
MATRIX_OLD_NODE="${MATRIX_OLD_NODE:-}"

# ── 计数与断言（与 tests/shell-scripts.test.sh 同风格）──────────
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1 — $2"; }
skip() { SKIP=$((SKIP+1)); echo "  ○ $1 (skip: $2)"; }

assert_contains() { # $1=haystack $2=needle $3=test name
  case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" "expected to contain [$2], got [$(echo "$1" | head -3)]" ;; esac
}

is_windows() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
is_ci() { [ "$MATRIX_SCOPE" = "ci" ]; }

# ── 受控环境 ──────────────────────────────────────────────
# scenario_setup 后导出：
#   FAKE_HOME FAKE_LOCALAPPDATA CLEAN_PATH SCENARIO_TMP
# 注意：不直接改本进程的 HOME/PATH——所有被测调用统一经 in_env 包装，
# 场景脚本自身始终运行在正常环境里（能用 git/node/coreutils）。
scenario_setup() {
  SCENARIO_TMP="$(mktemp -d)"
  FAKE_HOME="$SCENARIO_TMP/home"
  FAKE_LOCALAPPDATA="$SCENARIO_TMP/localappdata"
  FAKE_PROGRAMFILES="$SCENARIO_TMP/programfiles"
  mkdir -p "$FAKE_HOME" "$FAKE_LOCALAPPDATA" "$FAKE_PROGRAMFILES"
  CLEAN_PATH="$(make_clean_path)"
  MOVED_NODES=""
  trap scenario_teardown EXIT
}

scenario_teardown() {
  restore_abs_nodes
  rm -rf "${SCENARIO_TMP:-}" 2>/dev/null || true
}

# 裁剪 PATH：保留 shell 基础工具目录，剔除任何含 node 可执行文件的目录。
# 动态剔除而非白名单：Git Bash 的基础目录因安装方式而异，黑名单「含 node 的目录」更稳。
make_clean_path() {
  local out="" dir
  local oldifs="$IFS"; IFS=':'
  for dir in $PATH; do
    [ -z "$dir" ] && continue
    if [ -x "$dir/node" ] || [ -x "$dir/node.exe" ]; then continue; fi
    case ":$out:" in *":$dir:"*) continue ;; esac
    out="${out:+$out:}$dir"
  done
  IFS="$oldifs"
  printf '%s' "$out"
}

# 在受控环境里执行命令：假 HOME/LOCALAPPDATA/ProgramFiles + 裁剪 PATH。
# 用法：in_env [PATH=<override>] <cmd...>（首参形如 PATH=… 时覆盖默认 CLEAN_PATH）
in_env() {
  local p="$CLEAN_PATH"
  case "${1:-}" in PATH=*) p="${1#PATH=}"; shift ;; esac
  env HOME="$FAKE_HOME" \
      LOCALAPPDATA="$FAKE_LOCALAPPDATA" \
      ProgramFiles="$FAKE_PROGRAMFILES" \
      PROGRAMFILES="$FAKE_PROGRAMFILES" \
      PATH="$p" \
      "$@"
}

# ── 绝对路径 node 的屏蔽（mac/linux 的 /usr/local、/opt/homebrew）─────
# CI runner 一次性、免密 sudo → 临时改名；本机绝不动文件系统。
# 返回 0 = 屏蔽完成（或本就无残留），调用方可继续；返回 1 = 本机有残留且不能动 → 场景应 skip。
hide_abs_nodes() {
  is_windows && return 0  # Git Bash 下 /usr/local /opt/homebrew 映射进 Git 安装目录，无系统 node
  local p found=""
  for p in /usr/local/bin/node /opt/homebrew/bin/node; do
    [ -e "$p" ] && found="$found $p"
  done
  [ -z "$found" ] && return 0
  if is_ci; then
    for p in $found; do
      if sudo mv "$p" "$p.matrix-bak"; then MOVED_NODES="$MOVED_NODES $p"; else
        echo "  ! sudo mv $p 失败"; return 1
      fi
    done
    return 0
  fi
  return 1
}

restore_abs_nodes() {
  local p
  for p in ${MOVED_NODES:-}; do
    sudo mv "$p.matrix-bak" "$p" 2>/dev/null || true
  done
  MOVED_NODES=""
}

# ── 布局铺设 ──────────────────────────────────────────────
# 找一个「合规且独立可执行」的真 node 二进制，用于铺设布局。
# 两个坑都要避开：PATH 第一个 node 可能过旧（实测本机 /usr/local/bin/node 是 v12）；
# Volta/nvm 的 shim 在假 HOME 下找不到工具链真身会失效。
# 故先用 resolve-node.sh 在【正常环境】解析合规 node，再取其 execPath 拿到真二进制。
real_node() {
  local n
  n="$(sh "$RESOLVE_NODE" 2>/dev/null)" || return 1
  [ -n "$n" ] || return 1
  "$n" -p "process.execPath" 2>/dev/null
}

# 在 $1 处铺一个「可被候选链命中的 node」。
# mac/linux：软链真 node；Windows：拷贝真 node.exe（PE 二进制，sh -x 与 spawnSync 都认）。
plant_node() {
  local dest="$1" rn; rn="$(real_node)" || return 1
  mkdir -p "$(dirname "$dest")"
  if is_windows; then cp "$rn" "$dest"; else ln -s "$rn" "$dest"; fi
}

# 铺一个「假装是老版本」的 node stub（应答 resolve-node.sh 的 -p 主版本探测，回 $2 默认 12）
plant_old_node_stub() {
  local dest="$1" major="${2:-12}"
  mkdir -p "$(dirname "$dest")"
  printf '#!/bin/sh\necho %s\n' "$major" > "$dest"
  chmod +x "$dest"
}

# ── MCP 握手 ──────────────────────────────────────────────
# 用 $1 指定的 node 解释器跑 launch.cjs（在受控环境下），喂 initialize+tools/list，
# stdout 落到全局 MCP_OUT。调用方自行断言。
MCP_OUT=""
mcp_handshake() {
  local interp="$1"; shift
  local rpc
  rpc='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"env-matrix","version":"0.0.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  MCP_OUT="$(printf '%s\n' "$rpc" | in_env "$@" "$interp" "$LAUNCH_CJS" 2>&1)"
}

# 场景收尾：打印小结并以 FAIL 数为退出码
scenario_summary() {
  echo "  — pass=$PASS fail=$FAIL skip=$SKIP"
  [ "$FAIL" -eq 0 ]
}
