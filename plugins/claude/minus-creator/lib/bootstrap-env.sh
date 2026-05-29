#!/bin/bash
# bootstrap-env.sh
# 确定性、幂等、跨平台的开发环境初始化。
#
# 把原来散在 SKILL.md 里的「不说话不询问」内联安装命令收敛到这里，
# 解决：无进度反馈、假设 pnpm/uv 已存在、本地 Node 版本过旧导致的各种诡异 bug
# （如 macOS 上 localhost IPv6 解析 + Node18 autoSelectFamily=false 引发的代理 504）。
#
# 职责（缺什么补什么，已就绪则跳过）：
#   1. 保障 Node>=24 运行时：缺失或版本过旧都通过 Volta 安装/选中 node@24（硬下限）
#   2. pnpm —— 不走 corepack，pin 死版本（优先 Volta，否则 npm 全局装指定版本）
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
NODE_FLOOR=24

# 当前 node/npm 是否就绪且主版本 >= NODE_FLOOR
node_major_ok() {
  have node && have npm || return 1
  local major
  major=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo "")
  [ -n "$major" ] && [ "$major" -ge "$NODE_FLOOR" ] 2>/dev/null
}

# 通过 Volta 安装并选中 node@NODE_FLOOR（mac/linux）。成功 0 / 失败 1。
provision_node_via_volta() {
  if ! have volta; then
    have curl || return 1
    say "安装 Volta（Node 版本管理器，单次安装全局共享）……"
    curl -fsSL https://get.volta.sh | bash -s -- --skip-setup >/dev/null 2>&1 || true
  fi
  export VOLTA_HOME="${VOLTA_HOME:-$HOME/.volta}"
  export PATH="$VOLTA_HOME/bin:$PATH"
  hash -r 2>/dev/null || true
  have volta || return 1
  say "通过 Volta 安装并选中 Node ${NODE_FLOOR}（可能需要几分钟）……"
  volta install "node@${NODE_FLOOR}" >/dev/null 2>&1 || true
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
        volta install "node@${NODE_FLOOR}" >/dev/null 2>&1 || true
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
    finish_fail NODE_TOO_OLD "当前 Node 低于 v${NODE_FLOOR} 且自动升级失败。请安装 Node v${NODE_FLOOR}+（推荐 'curl https://get.volta.sh | bash' 后 'volta install node@${NODE_FLOOR}'）后重跑 /minus。"
  fi
  finish_fail NO_NODE "Node.js 自动安装失败。请手动安装 Node v${NODE_FLOOR}+（推荐 https://volta.sh）后重跑 /minus。"
}

# ════════════════════════════════════════════
# pnpm（不走 corepack，pin 死版本）
# ════════════════════════════════════════════
# 不用 @latest：pnpm 的次版本会引入破坏性策略变更（如 onlyBuiltDependencies 从
# package.json 迁到 pnpm-workspace.yaml、忽略构建脚本时硬报错 ERR_PNPM_IGNORED_BUILDS），
# 浮动版本会让客户机器随时间漂移到未验证的 pnpm 上踩雷。统一 pin 到验证过的版本。
# 优先用 Volta 装（与 Node 同源管理，shim 在 PATH 上、非交互 spawn 也能接管）；
# 无 Volta 才退回 npm 全局装指定版本。
PNPM_PIN=11.4.0

ensure_pnpm() {
  # pnpm 存在、能跑、且就是 pin 的版本 → 就绪
  if have pnpm && pnpm --version >/dev/null 2>&1; then
    local cur
    cur=$(pnpm --version 2>/dev/null)
    if [ "$cur" = "$PNPM_PIN" ]; then
      say "pnpm 已就绪（${cur}）。"
      return 0
    fi
    say "检测到 pnpm ${cur}，切换到 pin 版本 ${PNPM_PIN}……"
  else
    say "安装 pnpm@${PNPM_PIN}（不走 corepack）……"
  fi

  # 优先 Volta（已由 ensure_node 装好/选好 Node 时通常已就绪）
  if have volta; then
    if volta install "pnpm@${PNPM_PIN}" >/dev/null 2>&1; then
      hash -r 2>/dev/null || true
      if have pnpm && [ "$(pnpm --version 2>/dev/null)" = "$PNPM_PIN" ]; then
        say "pnpm 安装完成（$(pnpm --version 2>/dev/null)，Volta 管理）。"
        return 0
      fi
    fi
  fi

  # 退回 npm 全局装指定版本
  if npm i -g "pnpm@${PNPM_PIN}" >/dev/null 2>&1; then
    hash -r 2>/dev/null || true
    if have pnpm; then
      say "pnpm 安装完成（$(pnpm --version 2>/dev/null)）。"
      return 0
    fi
  fi
  finish_fail PNPM_INSTALL_FAILED "pnpm 安装失败。请手动运行：npm i -g pnpm@${PNPM_PIN}"
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
