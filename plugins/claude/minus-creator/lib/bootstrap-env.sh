#!/bin/bash
# bootstrap-env.sh
# 确定性、幂等、跨平台的开发环境初始化。
#
# 把原来散在 SKILL.md 里的「不说话不询问」内联安装命令收敛到这里，
# 解决：无进度反馈、假设 pnpm/uv 已存在、本地 Node 版本过旧导致的各种诡异 bug
# （如 macOS 上 localhost IPv6 解析 + Node18 autoSelectFamily=false 引发的代理 504）。
#
# 职责（缺什么补什么，已就绪则跳过）：
#   1. 保障 Node 运行时：缺失或版本过旧都通过 Volta 安装/选中 node@NODE_TARGET（版本见 toolchain.sh）
#   2. pnpm —— 不走 corepack，pin 死版本，统一经 Volta 安装（免 sudo，不碰 /usr/local）
#   3. uv —— Unix 用官方 curl，Windows 用 PowerShell installer
#   4. 安装项目依赖（pnpm install / uv venv + uv pip install -e .）
#
# 输出：每阶段一行 `[bootstrap] ...`（人类可读，供模型转述）；
#       末尾一行 `BOOTSTRAP_RESULT=ok` 或 `BOOTSTRAP_RESULT=failed reason=<CODE>`。
# 退出码恒为 0：失败信息通过 BOOTSTRAP_RESULT 传递，不靠非零退出码中断流程。
#
# 测试钩子（仅供测试，生产不设置）：
#   BOOTSTRAP_OS=mac|linux|windows  覆盖 OS 探测
#
# 用法: bootstrap-env.sh

say() { echo "[bootstrap] $1"; }

# 成功/失败统一出口（恒 exit 0）
finish_ok() {
  say "环境就绪。"
  echo "BOOTSTRAP_RESULT=ok"
  exit 0
}
finish_fail() {
  # $1=reason code  $2=给用户的说明（含手动命令）
  say "环境准备未完成：$2"
  echo "BOOTSTRAP_RESULT=failed reason=$1"
  exit 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# ── 工具链版本：从单源 toolchain.sh 读取（见该文件注释）──────────
# 必须在用到 NODE_FLOOR/PNPM_PIN 之前 source。被 install.sh source 时也会带上这些值。
TOOLCHAIN_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolchain.sh"
# shellcheck source=/dev/null
[ -f "$TOOLCHAIN_SH" ] && . "$TOOLCHAIN_SH"
# 兜底默认：清单缺失也不致命（保持与清单一致的安全值）。
NODE_FLOOR="${NODE_FLOOR:-24}"
NODE_TARGET="${NODE_TARGET:-$NODE_FLOOR}"
PNPM_PIN="${PNPM_TARGET:-11.4.0}"        # 全脚本沿用 PNPM_PIN 这个名字
PYTHON_TARGET="${PYTHON_TARGET:-3.12}"

# 最近一次安装尝试的真实错误（供 finish_fail 透出，不再用 || true 吞掉）。
LAST_ERR=""

# ── OS 探测（复用 project-detector.sh 的判断口径，可被 BOOTSTRAP_OS 覆盖）──
detect_os() {
  if [ -n "${BOOTSTRAP_OS:-}" ]; then
    echo "$BOOTSTRAP_OS"; return
  fi
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) echo "windows" ;;
    Darwin*) echo "mac" ;;
    *) echo "linux" ;;
  esac
}
OS="$(detect_os)"

# Windows 下 $USERPROFILE 的本地 bin（uv 默认装到这里）
win_local_bin() {
  # MSYS 下把 C:\Users\x 转成 /c/Users/x
  local up="${USERPROFILE:-$HOME}"
  echo "$up/.local/bin" | sed 's#\\#/#g; s#^\([A-Za-z]\):#/\L\1#'
}

# ════════════════════════════════════════════
# Step 0 — Node 运行时保障（硬下限 >= NODE_FLOOR）
# ════════════════════════════════════════════
# 为什么硬卡版本：Node<20 的 autoSelectFamily 默认 false，macOS 上 localhost 先解析
# IPv6 ::1，而本地后端只绑 IPv4 → dev 代理连 ::1 失败秒回 504。只放行 24+ 从根上避开
# 这类与 Node 版本耦合的诡异 bug。用 Volta 而非 fnm：Volta 的 shim 是 PATH 上的真二进制，
# 非交互式 spawn（含 GUI 客户端起 dev）也能被接管，不像 fnm 依赖 shell hook。
# NODE_FLOOR / NODE_TARGET 来自 toolchain.sh（已在文件顶部 source）。

# 当前 node/npm 是否就绪且主版本 >= NODE_FLOOR
node_major_ok() {
  have node && have npm || return 1
  local major
  major=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo "")
  [ -n "$major" ] && [ "$major" -ge "$NODE_FLOOR" ] 2>/dev/null
}

# 把 ~/.volta/bin 强制提到 PATH 最前并刷新命令缓存（幂等，无网络）。
# 专治两类问题：
#   1.「Volta 已装但不在当前 PATH」——非交互 spawn / 系统 Node 达标分支下没人 export 过。
#   2.「Volta 在 PATH 但排在 /usr/local/bin 之后」——只判断"是否在 PATH 里"不够：
#      2025 年遗留的 /usr/local/bin/{pnpm,node} root 软链会 shadow 掉 Volta pin 版本
#      （实测 /usr/local/bin/pnpm@10.6.5 盖过 volta@11.4.0），导致版本检测永远不等于 pin
#      → 假性 PNPM_INSTALL_FAILED。故必须把 ~/.volta/bin 提到最前，而非"已存在就跳过"。
# 实现：先剔除 PATH 里所有已存在的 ~/.volta/bin，再 prepend，保证幂等且必在最前。
volta_on_path() {
  export VOLTA_HOME="${VOLTA_HOME:-$HOME/.volta}"
  local cleaned="" entry oldifs="$IFS" glob_off=1
  case $- in *f*) ;; *) glob_off=0; set -f ;; esac   # 暂关 glob，避免 PATH 含 * 被展开
  IFS=':'
  for entry in $PATH; do
    [ -z "$entry" ] && continue
    [ "$entry" = "$VOLTA_HOME/bin" ] && continue
    cleaned="${cleaned:+$cleaned:}$entry"
  done
  IFS="$oldifs"
  [ "$glob_off" -eq 0 ] && set +f
  export PATH="$VOLTA_HOME/bin:$cleaned"
  hash -r 2>/dev/null || true
  have volta
}

# 确保 Volta 可用：先看是否已装（仅 PATH，无网络）；没有才在 Unix 上 curl 安装。
# windows / 无 curl 直接 return 1。返回 volta 是否最终可用。
ensure_volta() {
  volta_on_path && return 0
  [ "$OS" = "windows" ] && return 1
  have curl || return 1
  say "安装 Volta（Node 版本管理器，单次安装全局共享）……"
  curl -fsSL https://get.volta.sh | bash -s -- --skip-setup >/dev/null 2>&1 || true
  volta_on_path
}

# 通过 Volta 安装并选中 node@NODE_TARGET（mac/linux）。成功 0 / 失败 1。
provision_node_via_volta() {
  if ! ensure_volta; then
    LAST_ERR="无法获取 Volta（未安装且自动安装失败；需联网从 https://get.volta.sh 下载）。"
    return 1
  fi
  say "通过 Volta 安装并选中 Node ${NODE_TARGET}（可能需要几分钟）……"
  LAST_ERR="$(volta install "node@${NODE_TARGET}" 2>&1)"
  hash -r 2>/dev/null || true
  node_major_ok
}

ensure_node() {
  # 已就绪且版本达标 → 直接放行
  if node_major_ok; then
    say "Node/npm 已就绪（$(node -v 2>/dev/null)）。"
    return 0
  fi

  # node 在但 npm 不在：残缺安装，不强行修
  if have node && ! have npm; then
    finish_fail NO_NPM "检测到 node 但缺少 npm（Node 安装不完整）。请重装 Node.js（>= v${NODE_FLOOR}）后重跑 /minus。"
  fi

  # 到这里：要么完全没有 node，要么 node 版本 < NODE_FLOOR —— 都用 Volta 配给
  if have node; then
    say "检测到 Node $(node -v 2>/dev/null)，低于要求的 v${NODE_FLOOR}，开始通过 Volta 升级……"
  else
    say "未检测到 Node.js，开始通过 Volta 安装 v${NODE_FLOOR}……"
  fi

  if [ "$OS" = "windows" ]; then
    if have winget || have powershell.exe; then
      say "通过 winget 安装 Volta（可能需要几分钟）……"
      powershell.exe -NoProfile -Command \
        "winget install -e --id Volta.Volta --accept-source-agreements --accept-package-agreements" >/dev/null 2>&1 || true
      hash -r 2>/dev/null || true
      if have volta; then
        LAST_ERR="$(volta install "node@${NODE_TARGET}" 2>&1)"
        hash -r 2>/dev/null || true
        if node_major_ok; then
          say "Node.js 安装完成（$(node -v 2>/dev/null)）。"
          return 0
        fi
      fi
      finish_fail RESTART_NEEDED "Volta 已安装，但当前终端 PATH 未刷新。请重启 Claude Code / 终端后重跑 /minus。"
    fi
    finish_fail NO_NODE "未找到 winget，无法自动安装。请安装 Node.js v${NODE_FLOOR}+（https://volta.sh 或 https://nodejs.org）后重跑 /minus。"
  fi

  # mac / linux
  if provision_node_via_volta; then
    say "Node.js 就绪（$(node -v 2>/dev/null)）。"
    return 0
  fi

  if have node; then
    finish_fail NODE_TOO_OLD "当前 Node 低于 v${NODE_FLOOR} 且自动升级失败。真实错误：${LAST_ERR:-（无输出）}。请安装 Node v${NODE_TARGET}（推荐 'curl https://get.volta.sh | bash' 后 'volta install node@${NODE_TARGET}'）后重跑 /minus。"
  fi
  finish_fail NO_NODE "Node.js 自动安装失败。真实错误：${LAST_ERR:-（无输出）}。请手动安装 Node v${NODE_TARGET}（推荐 https://volta.sh）后重跑 /minus。"
}

# ════════════════════════════════════════════
# pnpm（不走 corepack，pin 死版本）
# ════════════════════════════════════════════
# 版本来自 toolchain.sh（PNPM_PIN ← PNPM_TARGET，已在文件顶部赋值）。
# 统一经 Volta 安装：Volta 装到 ~/.volta（用户可写、免 sudo），不碰 /usr/local，
# 从根上避开「npm i -g 写系统目录」的 EACCES。VOLTA_FEATURE_PNPM=1 兼容旧版 Volta
# （pnpm 支持曾是实验特性需此 flag；新版无需，加了无害）。
# 不再保留 npm -g 兜底：它是唯一会写 /usr/local 触发 EACCES 的来源，已砍。

ensure_pnpm() {
  # 判定依据始终是「pnpm@pin 能不能跑」，而不是「某条安装命令退没退出 0」。
  pnpm_ok() { have pnpm && [ "$(pnpm --version 2>/dev/null)" = "$PNPM_PIN" ]; }

  # 暴露可能已装但不在 PATH 的 Volta（仅 PATH，无网络）；再看现状是否已达标。
  volta_on_path || true
  if pnpm_ok; then
    say "pnpm 已就绪（$(pnpm --version 2>/dev/null)）。"
    return 0
  fi

  if have pnpm; then
    say "检测到 pnpm $(pnpm --version 2>/dev/null)，切换到 pin 版本 ${PNPM_PIN}（经 Volta，免 sudo）……"
  else
    say "安装 pnpm@${PNPM_PIN}（经 Volta，免 sudo）……"
  fi

  if ensure_volta; then
    LAST_ERR="$(VOLTA_FEATURE_PNPM=1 volta install "pnpm@${PNPM_PIN}" 2>&1)"
    hash -r 2>/dev/null || true
    if pnpm_ok; then
      say "pnpm 安装完成（$(pnpm --version 2>/dev/null)，Volta 管理）。"
      return 0
    fi
  else
    LAST_ERR="无法获取 Volta（未安装且自动安装失败；需联网从 https://get.volta.sh 下载）。"
  fi

  # 真实错误透出，不再吞掉——这样下次失败能一眼看出是网络、Volta 还是版本问题。
  finish_fail PNPM_INSTALL_FAILED "pnpm 安装失败。真实错误：${LAST_ERR:-（无输出）}。手动可试：curl https://get.volta.sh | bash 后 VOLTA_FEATURE_PNPM=1 volta install pnpm@${PNPM_PIN}"
}

# ════════════════════════════════════════════
# uv（OS 分支）
# ════════════════════════════════════════════
uv_present() {
  if have uv; then return 0; fi
  if [ "$OS" = "windows" ]; then
    [ -x "$(win_local_bin)/uv.exe" ] || [ -x "$(win_local_bin)/uv" ]
  else
    [ -x "$HOME/.local/bin/uv" ]
  fi
}

ensure_uv() {
  if uv_present; then
    [ "$OS" = "windows" ] && export PATH="$(win_local_bin):$PATH" || export PATH="$HOME/.local/bin:$PATH"
    hash -r 2>/dev/null || true
    say "uv 已就绪（$(uv --version 2>/dev/null)）。"
    return 0
  fi

  say "未检测到 uv，开始自动安装……"
  if [ "$OS" = "windows" ]; then
    if have powershell.exe; then
      powershell.exe -NoProfile -ExecutionPolicy ByPass -Command \
        "irm https://astral.sh/uv/install.ps1 | iex" >/dev/null 2>&1 || true
      export PATH="$(win_local_bin):$PATH"
      hash -r 2>/dev/null || true
      if have uv; then
        say "uv 安装完成（$(uv --version 2>/dev/null)）。"
        return 0
      fi
      finish_fail RESTART_NEEDED "uv 已安装，但当前终端 PATH 未刷新。请重启 Claude Code / 终端后重跑 /minus。"
    fi
    finish_fail UV_INSTALL_FAILED "未找到 PowerShell，无法自动安装 uv。请手动安装 uv（见 https://docs.astral.sh/uv/）后重跑 /minus。"
  fi

  if have curl; then
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
    hash -r 2>/dev/null || true
    if have uv; then
      say "uv 安装完成（$(uv --version 2>/dev/null)）。"
      return 0
    fi
  fi
  finish_fail UV_INSTALL_FAILED "uv 自动安装失败。请手动运行：curl -LsSf https://astral.sh/uv/install.sh | sh"
}

# ════════════════════════════════════════════
# 项目依赖
# ════════════════════════════════════════════
ensure_node_modules() {
  if [ -d node_modules ]; then
    say "前端依赖已安装（node_modules 存在）。"
    return 0
  fi
  say "安装前端依赖（pnpm install，首次可能需要几分钟）……"
  if pnpm install >/dev/null 2>&1; then
    say "前端依赖安装完成。"
    return 0
  fi
  finish_fail PNPM_INSTALL_FAILED "前端依赖安装失败。请手动运行：pnpm install"
}

ensure_venv() {
  if [ -d .venv ]; then
    say "后端虚拟环境已就绪（.venv 存在）。"
    return 0
  fi
  say "创建后端虚拟环境并安装依赖（uv venv + uv pip install -e .，首次可能需要几分钟）……"
  if uv venv -p 3.12 >/dev/null 2>&1 && uv pip install -e . >/dev/null 2>&1; then
    say "后端依赖安装完成。"
    return 0
  fi
  finish_fail UV_INSTALL_FAILED "后端依赖安装失败。请手动运行：uv venv -p 3.12 && uv pip install -e ."
}

# ════════════════════════════════════════════
# 主流程
# ════════════════════════════════════════════
# 仅在「直接执行」时跑主流程并 finish_ok(exit)；被 source 时只暴露函数
# （install.sh 复用 node_major_ok/provision_node_via_volta，不能触发副作用与退出）。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  say "检测开发环境（OS=${OS}）……"
  ensure_node
  ensure_pnpm
  ensure_uv
  ensure_node_modules
  ensure_venv
  finish_ok
fi
