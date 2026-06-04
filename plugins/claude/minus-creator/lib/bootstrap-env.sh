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

# ── 国内镜像源（默认开启）──────────────────────────────────
# 大多数 Minus 第三方开发者在国内，默认走国内源避免 npm/PyPI 拉包慢到超时。
# 只 export 环境变量、不写任何工具的全局配置文件 —— 海外开发者 MINUS_MIRROR=off
# 一关即零残留。已显式设置同名变量的用户（自带 .npmrc/索引）一律尊重，不覆盖。
#   npm  → registry.npmmirror.com（阿里），覆盖 pnpm install / volta install pnpm
#   PyPI → 清华 tuna，覆盖 uv pip install
# 注：Volta 的 node 二进制（nodejs.org）与 uv 的 Python 解释器下载无干净镜像 env，
#     仍走官方源；这两处是已知剩余慢点。
MIRROR_NPM_DEFAULT="https://registry.npmmirror.com"
MIRROR_PYPI_DEFAULT="https://pypi.tuna.tsinghua.edu.cn/simple"
MIRROR_NPM_OFFICIAL="https://registry.npmjs.org"
MIRROR_PYPI_OFFICIAL="https://pypi.org/simple"

# 设环境变量层的镜像源。同时记三个标志供 write_project_mirror_config 用：
#   MINUS_MIRROR_ENABLED  镜像是否开启（off → 0）
#   MIRROR_NPM_OURS       npm 源是「我们设的默认值」还是「用户已自带」（自带则不落盘）
#   MIRROR_PYPI_OURS      PyPI 源同上
# 注：本函数不写任何项目文件——它也被 SKILL.md 的 create-skill 安装块复用（cwd 不定），
#     落盘逻辑单独放在 write_project_mirror_config，仅在项目目录内的主流程调用。
setup_cn_mirror() {
  MINUS_MIRROR_ENABLED=0; MIRROR_NPM_OURS=0; MIRROR_PYPI_OURS=0
  case "${MINUS_MIRROR:-on}" in
    off|0|false|none|no)
      say "镜像源：已禁用（MINUS_MIRROR=${MINUS_MIRROR:-}），走官方源。"
      return ;;
  esac
  MINUS_MIRROR_ENABLED=1
  if [ -z "${npm_config_registry:-}" ]; then
    export npm_config_registry="${MINUS_NPM_REGISTRY:-$MIRROR_NPM_DEFAULT}"
    MIRROR_NPM_OURS=1
  fi
  if [ -z "${UV_DEFAULT_INDEX:-}" ] && [ -z "${UV_INDEX_URL:-}" ]; then
    export UV_DEFAULT_INDEX="${MINUS_PYPI_INDEX:-$MIRROR_PYPI_DEFAULT}"
    MIRROR_PYPI_OURS=1
  fi
  say "镜像源：npm→${npm_config_registry} ，PyPI→${UV_DEFAULT_INDEX:-${UV_INDEX_URL:-（用户已配置）}}（关闭：MINUS_MIRROR=off）。"
}

# 把镜像源落盘成项目级 .npmrc / uv.toml，让「后续手动升级依赖」（pnpm add/update、
# uv pip install -U、uv add）也走国内源——env 变量只活在 bootstrap 子进程里，盖不到。
# 这两个文件已加进 create-skill 的 .gitignore：本地生效、不入库、不污染发布产物。
# 安全：带 minus 标记头，只动「我们生成的」文件，绝不覆盖用户自有的 .npmrc / uv.toml。
MIRROR_MARK="# managed-by: minus (MINUS_MIRROR) — 自动生成，勿手改；设 MINUS_MIRROR=off 后重跑 /minus 可移除"

# 文件首行是否带 minus 托管标记（纯 shell，零外部命令）
is_minus_managed() {
  [ -e "$1" ] || return 1
  local first; IFS= read -r first < "$1" 2>/dev/null || return 1
  case "$first" in "# managed-by: minus"*) return 0 ;; *) return 1 ;; esac
}

# 谁创建文件谁负责忽略：bootstrap 落盘 .npmrc/uv.toml，就由 bootstrap 保证它们进
# .gitignore——而不是寄希望于 create-skill 模板（那样得发包才生效、且会无条件吞掉
# 用户自有 .npmrc）。下面两个助手都幂等、精确匹配整行、绝不动用户已有的行。
GITIGNORE_MARK="# minus 自动生成的国内镜像源配置（本地生效，不入库）"

gitignore_add() {  # $@=要忽略的文件名；缺啥补啥，已存在则跳过
  local entry need=0
  for entry in "$@"; do
    { [ -e .gitignore ] && grep -qxF "$entry" .gitignore 2>/dev/null; } || need=1
  done
  [ "$need" = 0 ] && return 0
  # 追加前确保末尾有换行，避免和最后一行粘连
  if [ -s .gitignore ] && [ -n "$(tail -c1 .gitignore 2>/dev/null)" ]; then printf '\n' >> .gitignore; fi
  grep -qxF "$GITIGNORE_MARK" .gitignore 2>/dev/null || printf '%s\n' "$GITIGNORE_MARK" >> .gitignore
  for entry in "$@"; do
    grep -qxF "$entry" .gitignore 2>/dev/null || printf '%s\n' "$entry" >> .gitignore
  done
}

gitignore_del() {  # 仅当我们的注释头在场才回删我们加的忽略行（off 时零残留）
  [ -e .gitignore ] || return 0
  grep -qxF "$GITIGNORE_MARK" .gitignore 2>/dev/null || return 0
  local tmp; tmp="$(mktemp 2>/dev/null)" || return 0
  grep -vxF "$GITIGNORE_MARK" .gitignore | grep -vxF '.npmrc' | grep -vxF 'uv.toml' > "$tmp"
  mv "$tmp" .gitignore
}

write_project_mirror_config() {
  # 镜像关闭：清掉我们以前生成的托管文件 + .gitignore 里我们加的忽略行（用户自有的一律不碰）
  if [ "${MINUS_MIRROR_ENABLED:-0}" != "1" ]; then
    is_minus_managed .npmrc && { rm -f .npmrc; say "已移除托管 .npmrc（镜像已关闭）。"; }
    is_minus_managed uv.toml && { rm -f uv.toml; say "已移除托管 uv.toml（镜像已关闭）。"; }
    gitignore_del
    return 0
  fi
  local wrote=0 gi=()
  # npm：仅当源由我们决定，且不存在用户自有 .npmrc 时落盘
  if [ "${MIRROR_NPM_OURS:-0}" = "1" ]; then
    if [ ! -e .npmrc ] || is_minus_managed .npmrc; then
      printf '%s\nregistry=%s\n' "$MIRROR_MARK" "$npm_config_registry" > .npmrc && { wrote=1; gi+=(".npmrc"); }
    else
      say "检测到用户自有 .npmrc，保留不动。"
    fi
  fi
  # PyPI：[[index]] default 一份同时覆盖 uv pip 与 uv add/sync
  if [ "${MIRROR_PYPI_OURS:-0}" = "1" ]; then
    if [ ! -e uv.toml ] || is_minus_managed uv.toml; then
      printf '%s\n[[index]]\nurl = "%s"\ndefault = true\n' "$MIRROR_MARK" "$UV_DEFAULT_INDEX" > uv.toml && { wrote=1; gi+=("uv.toml"); }
    else
      say "检测到用户自有 uv.toml，保留不动。"
    fi
  fi
  # 谁落盘谁负责忽略：把刚写的镜像配置加进 .gitignore（幂等），不入库、不污染发布产物
  [ ${#gi[@]} -gt 0 ] && gitignore_add "${gi[@]}"
  [ "$wrote" = "1" ] && say "已写项目镜像配置（.npmrc / uv.toml，已加入 .gitignore），后续升级依赖也走国内源。"
  return 0
}

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

# Volta 的 shim 目录：Windows 是 %LOCALAPPDATA%\Volta\bin，其余平台是 $HOME/.volta/bin。
# volta_on_path 据此把正确的 shim 目录提到 PATH 最前。
volta_bin_dir() {
  if [ "$OS" = "windows" ]; then
    local la="${LOCALAPPDATA:-${USERPROFILE:-$HOME}/AppData/Local}"
    echo "$la/Volta/bin" | sed 's#\\#/#g; s#^\([A-Za-z]\):#/\L\1#'
  else
    echo "${VOLTA_HOME:-$HOME/.volta}/bin"
  fi
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
  local vbin; vbin="$(volta_bin_dir)"
  local cleaned="" entry oldifs="$IFS" glob_off=1
  case $- in *f*) ;; *) glob_off=0; set -f ;; esac   # 暂关 glob，避免 PATH 含 * 被展开
  IFS=':'
  for entry in $PATH; do
    [ -z "$entry" ] && continue
    [ "$entry" = "$vbin" ] && continue
    cleaned="${cleaned:+$cleaned:}$entry"
  done
  IFS="$oldifs"
  [ "$glob_off" -eq 0 ] && set +f
  export PATH="$vbin:$cleaned"
  hash -r 2>/dev/null || true
  have volta
}

# Windows：用 winget 装 Volta。返回 volta 在「本会话」是否立即可用。
# 注意：winget 把 volta.exe 装到 Program Files\Volta 并写 System PATH、shim 到
# %LOCALAPPDATA%\Volta\bin，二者通常都要重开终端才生效——故本会话很可能仍 return 1，
# 这是预期的，调用方（ensure_pnpm）会走 npm-g 兜底。
install_volta_windows() {
  have winget || have powershell.exe || return 1
  say "通过 winget 安装 Volta（可能需要几分钟）……"
  powershell.exe -NoProfile -Command \
    "winget install -e --id Volta.Volta --accept-source-agreements --accept-package-agreements" >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  volta_on_path
}

# 确保 Volta 可用：先看是否已装（仅 PATH，无网络）；没有才按 OS 安装。
# 返回 volta 是否最终可用（Windows 多半要重启终端才生效，本会话可能 return 1）。
ensure_volta() {
  volta_on_path && return 0
  if [ "$OS" = "windows" ]; then
    install_volta_windows
    return $?
  fi
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
  # 起手先把已装的 ~/.volta/bin 顶到 PATH 最前再检测：继承环境（Desktop spawn）里
  # 没有 ~/.volta/bin、node@22 在前，不先 prepend 就会每次漏掉已装的 node24、空转重配。
  volta_on_path || true
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
    if ensure_volta; then
      LAST_ERR="$(volta install "node@${NODE_TARGET}" 2>&1)"
      hash -r 2>/dev/null || true
      if node_major_ok; then
        say "Node.js 安装完成（$(node -v 2>/dev/null)）。"
        return 0
      fi
      finish_fail RESTART_NEEDED "Volta 已安装，但当前终端 PATH 未刷新。请重启 Claude Code / 终端后重跑 /minus。"
    fi
    # ensure_volta 没能让 volta 在本会话立即可用：若确实尝试过 winget 安装（有 winget/powershell），
    # 多半是 PATH 未刷新 → 让用户重启；否则真的无从安装 → NO_NODE。
    if have winget || have powershell.exe; then
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
  fi

  # Windows 兜底：Volta shim 多半要重启终端才生效，本会话装不上 pnpm。
  # Windows 的 npm 全局 prefix = %APPDATA%\npm（用户可写、免 admin、无 EACCES），
  # 故 npm -g 在 Windows 上安全——这正是 mac 上被砍掉的那条兜底在 Windows 上可用的原因。
  if [ "$OS" = "windows" ] && have npm; then
    say "经 Volta 未就绪，改用 npm 全局安装 pnpm@${PNPM_PIN}（Windows，写 %APPDATA%\\npm，免 admin）……"
    LAST_ERR="$(npm install -g "pnpm@${PNPM_PIN}" 2>&1)"
    hash -r 2>/dev/null || true
    if pnpm_ok; then
      say "pnpm 安装完成（$(pnpm --version 2>/dev/null)，npm 全局）。"
      return 0
    fi
  fi

  # 真实错误透出，不再吞掉——这样下次失败能一眼看出是网络、Volta 还是版本问题。
  finish_fail PNPM_INSTALL_FAILED "pnpm 安装失败。真实错误：${LAST_ERR:-（无输出）}。手动可试：curl https://get.volta.sh | bash 后 VOLTA_FEATURE_PNPM=1 volta install pnpm@${PNPM_PIN}（Windows：npm install -g pnpm@${PNPM_PIN}）"
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
  # 镜像源可能滞后/抽风（个别新包未同步）：回退官方 npm 源重试一次。
  # 注意：必须用 CLI 的 --registry 而非 npm_config_registry 环境变量 —— pnpm 里
  # 项目 .npmrc 的优先级高于该 env（实测：带 env 官方源，pnpm config 仍读 .npmrc 的镜像），
  # 而我们已把镜像源落盘进 .npmrc，只设 env 会被 .npmrc 反噬、又撞回镜像；CLI flag 优先级
  # 最高，才能真正盖过落盘的 .npmrc。（uv 那边相反：env 高于 uv.toml，故用 env 显式赋值。）
  if [ -n "${npm_config_registry:-}" ] && [ "$npm_config_registry" != "$MIRROR_NPM_OFFICIAL" ]; then
    say "镜像源安装失败，回退官方 npm 源重试……"
    if pnpm install --registry="$MIRROR_NPM_OFFICIAL" >/dev/null 2>&1; then
      say "前端依赖安装完成（官方源）。"
      return 0
    fi
  fi
  finish_fail PNPM_INSTALL_FAILED "前端依赖安装失败。请手动运行：pnpm install"
}

ensure_venv() {
  if [ -d .venv ]; then
    say "后端虚拟环境已就绪（.venv 存在）。"
    return 0
  fi
  say "创建后端虚拟环境并安装依赖（uv venv + uv pip install -e .，首次可能需要几分钟）……"
  if uv venv -p "$PYTHON_TARGET" >/dev/null 2>&1 && uv pip install -e . >/dev/null 2>&1; then
    say "后端依赖安装完成。"
    return 0
  fi
  # venv 多半已建好（uv venv 不走 PyPI 索引），失败常出在 pip 装包阶段：
  # 镜像源滞后/抽风时回退官方 PyPI 重试一次（仅重试装包，复用已建的 .venv）。
  # 注意：必须「显式设官方 index」而非 `env -u UV_DEFAULT_INDEX` —— 我们已把
  # uv.toml（[[index]] default=true 指向镜像）落盘，仅卸 env 会被 uv.toml 反噬、
  # 又指回镜像（实测）；env 显式赋值能盖过 uv.toml，才是真回退。
  if [ -n "${UV_DEFAULT_INDEX:-}" ] && [ -d .venv ]; then
    say "镜像源安装失败，回退官方 PyPI 重试……"
    if UV_DEFAULT_INDEX="$MIRROR_PYPI_OFFICIAL" uv pip install -e . >/dev/null 2>&1; then
      say "后端依赖安装完成（官方源）。"
      return 0
    fi
  fi
  finish_fail UV_INSTALL_FAILED "后端依赖安装失败。请手动运行：uv venv -p $PYTHON_TARGET && uv pip install -e ."
}

# ════════════════════════════════════════════
# 主流程
# ════════════════════════════════════════════
# 仅在「直接执行」时跑主流程并 finish_ok(exit)；被 source 时只暴露函数
# （install.sh 复用 node_major_ok/provision_node_via_volta，不能触发副作用与退出）。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  say "检测开发环境（OS=${OS}）……"
  setup_cn_mirror
  write_project_mirror_config
  ensure_node
  ensure_pnpm
  ensure_uv
  ensure_node_modules
  ensure_venv
  finish_ok
fi
