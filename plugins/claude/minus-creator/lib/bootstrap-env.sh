#!/bin/bash
# bootstrap-env.sh
# 确定性、幂等、跨平台的开发环境初始化。
#
# 把原来散在 SKILL.md 里的「不说话不询问」内联安装命令收敛到这里，
# 解决：无进度反馈、假设 pnpm/uv 已存在、Node 旧版本 corepack 拉 pnpm@latest 崩溃。
#
# 职责（缺什么补什么，已就绪则跳过）：
#   1. 保障 node/npm 运行时（完全缺失才自动装，不动既有旧版本）
#   2. pnpm —— 不走 corepack，按 Node 主版本选版本（<20→8，否则 latest）
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
# Step 0 — Node / npm 运行时保障
# ════════════════════════════════════════════
ensure_node() {
  if have node && have npm; then
    say "Node/npm 已就绪（$(node -v 2>/dev/null)）。"
    return 0
  fi

  # node 在但 npm 不在：残缺安装，不强行修
  if have node && ! have npm; then
    finish_fail NO_NPM "检测到 node 但缺少 npm（Node 安装不完整）。请重装 Node.js（建议 LTS）后重跑 /minus。"
  fi

  say "未检测到 Node.js，开始自动安装……"
  if [ "$OS" = "windows" ]; then
    if have winget || have powershell.exe; then
      say "通过 winget 安装 Node.js LTS（可能需要几分钟）……"
      powershell.exe -NoProfile -Command \
        "winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements" >/dev/null 2>&1 || true
      hash -r 2>/dev/null || true
      if have node && have npm; then
        say "Node.js 安装完成（$(node -v 2>/dev/null)）。"
        return 0
      fi
      finish_fail RESTART_NEEDED "Node.js 已安装，但当前终端 PATH 未刷新。请重启 Claude Code / 终端后重跑 /minus。"
    fi
    finish_fail NO_NODE "未找到 winget，无法自动安装 Node.js。请到 https://nodejs.org 下载 LTS 安装后重跑 /minus。"
  fi

  # mac / linux：用 self-contained 的 fnm（curl 单文件安装器）
  if have curl; then
    say "通过 fnm 安装 Node.js LTS（可能需要几分钟）……"
    curl -fsSL https://fnm.vercel.app/install | bash >/dev/null 2>&1 || true
    export PATH="$HOME/.local/share/fnm:$HOME/.fnm:$PATH"
    hash -r 2>/dev/null || true
    if have fnm; then
      eval "$(fnm env 2>/dev/null)" 2>/dev/null || true
      fnm install --lts >/dev/null 2>&1 || true
      fnm use lts-latest >/dev/null 2>&1 || true
      eval "$(fnm env 2>/dev/null)" 2>/dev/null || true
      hash -r 2>/dev/null || true
    fi
    if have node && have npm; then
      say "Node.js 安装完成（$(node -v 2>/dev/null)）。"
      return 0
    fi
  fi
  finish_fail NO_NODE "Node.js 自动安装失败。请手动安装 Node.js LTS（如 'brew install node' 或 https://nodejs.org），然后重跑 /minus。"
}

# ════════════════════════════════════════════
# pnpm（不走 corepack）
# ════════════════════════════════════════════
NODE_MAJOR=""
PNPM_TARGET=""

compute_pnpm_target() {
  NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo "")
  if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -lt 20 ] 2>/dev/null; then
    PNPM_TARGET="8"
  else
    PNPM_TARGET="latest"
  fi
  say "Node 主版本: ${NODE_MAJOR:-未知} → pnpm 目标版本: $PNPM_TARGET"
}

ensure_pnpm() {
  local need_install="no"
  if ! have pnpm; then
    need_install="yes"
  else
    local cur_major
    cur_major=$(pnpm --version 2>/dev/null | cut -d. -f1)
    if [ -z "$cur_major" ]; then
      # pnpm 存在但跑不起来（如 corepack 在旧 Node 上崩溃）→ 重装
      need_install="yes"
    elif [ "$PNPM_TARGET" = "8" ] && [ "$cur_major" -gt 8 ] 2>/dev/null; then
      # Node<20 但现有 pnpm 太新（会触发 Node18 的 dynamic import bug）→ 降级
      need_install="yes"
    fi
  fi

  if [ "$need_install" = "no" ]; then
    say "pnpm 已就绪（$(pnpm --version 2>/dev/null)）。"
    return 0
  fi

  say "安装 pnpm@$PNPM_TARGET（经 npm，不走 corepack）……"
  if npm i -g "pnpm@$PNPM_TARGET" >/dev/null 2>&1; then
    hash -r 2>/dev/null || true
    if have pnpm; then
      say "pnpm 安装完成（$(pnpm --version 2>/dev/null)）。"
      return 0
    fi
  fi
  finish_fail PNPM_INSTALL_FAILED "pnpm 安装失败。请手动运行：npm i -g pnpm@$PNPM_TARGET"
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
say "检测开发环境（OS=$OS）……"
ensure_node
compute_pnpm_target
ensure_pnpm
ensure_uv
ensure_node_modules
ensure_venv
finish_ok
