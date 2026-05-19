#!/bin/bash
# project-detector.sh
# SessionStart hook: 初始化 Minus 环境 + 检测当前目录状态

# ── 跨平台路径 ──
OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    PLATFORM="windows"
    MINUS_GLOBAL="${APPDATA:-$HOME}/Minus"
    MINUS_WORKSPACE="$USERPROFILE/minus"
    ;;
  Darwin*)
    PLATFORM="mac"
    MINUS_GLOBAL="$HOME/.minus"
    MINUS_WORKSPACE="$HOME/minus"
    ;;
  *)
    PLATFORM="linux"
    MINUS_GLOBAL="${XDG_CONFIG_HOME:-$HOME/.config}/minus"
    MINUS_WORKSPACE="$HOME/minus"
    ;;
esac
MINUS_JSON=".minus/skill.json"

# ── 前置检查：Node.js 是否可用 ──
if ! command -v node >/dev/null 2>&1; then
  echo "<context>"
  echo "Minus Creator Plugin 需要 Node.js，当前环境未安装。"
  echo ""
  echo "当前平台：$PLATFORM"
  echo ""
  echo "[指令] 不要等待用户输入，立即自动安装 Node.js："
  echo ""
  if [ "$PLATFORM" = "mac" ]; then
    echo "Mac 安装方案（按优先级尝试）："
    echo "  1. 如果有 brew → brew install node"
    echo "  2. 如果没有 brew → 先装 brew：/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"，再 brew install node"
    echo "  3. 都失败 → 引导 Creator 访问 nodejs.org 下载 .pkg 安装包"
  elif [ "$PLATFORM" = "windows" ]; then
    echo "Windows 安装方案（按优先级尝试）："
    echo "  1. 如果有 winget → winget install OpenJS.NodeJS.LTS"
    echo "  2. 如果有 choco → choco install nodejs-lts"
    echo "  3. 都没有 → 引导 Creator 访问 nodejs.org 下载 .msi 安装包，告知"下载后双击安装，一路点下一步即可""
  else
    echo "Linux 安装方案（按优先级尝试）："
    echo "  1. 如果有 apt → curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs"
    echo "  2. 如果有 yum → curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash - && sudo yum install -y nodejs"
    echo "  3. 都失败 → 引导 Creator 访问 nodejs.org 下载"
  fi
  echo ""
  echo "安装过程中告知 Creator：「正在准备运行环境，稍等片刻...」"
  echo "安装完成后：不要让 Creator 重开对话，直接在当前对话中继续正常流程（检测项目、检查登录等）。"
  echo "安装失败时用通俗语言说明，引导 Creator 访问 nodejs.org 手动安装。手动安装完成后也不需要重开对话，直接继续。"
  echo "</context>"
  exit 0
fi

# ── 静默初始化：确保全局目录和 Workspace 存在 ──
if [ ! -d "$MINUS_GLOBAL" ]; then
  mkdir -p "$MINUS_GLOBAL"
fi
if [ ! -d "$MINUS_WORKSPACE" ]; then
  mkdir -p "$MINUS_WORKSPACE"
  touch "$MINUS_WORKSPACE/.minus-workspace"
fi
if [ ! -f "$MINUS_WORKSPACE/.minus-workspace" ]; then
  touch "$MINUS_WORKSPACE/.minus-workspace"
fi

# ── 检测登录状态 ──
LOGGED_IN="false"
if [ -f "$MINUS_GLOBAL/credentials.json" ]; then
  LOGGED_IN="true"
fi

# ── 检测项目列表 ──
PROJECTS_JSON="$MINUS_GLOBAL/projects.json"
PROJECT_COUNT=0
if [ -f "$PROJECTS_JSON" ]; then
  PROJECT_COUNT=$(node -e "try{const d=JSON.parse(require('fs').readFileSync('$PROJECTS_JSON','utf8'));console.log(d.projects?.length||0)}catch{console.log(0)}" 2>/dev/null)
fi

# ── projects.json 管理脚本路径 ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PM="$SCRIPT_DIR/projects-manager.sh"

# ── 场景判断 ──

# 场景 1：当前目录是 Skill 项目
if [ -f "$MINUS_JSON" ]; then
  # 静默注册/更新 projects.json
  PROJ_NAME=$(basename "$(pwd)")
  bash "$PM" add "$PROJ_NAME" "$(pwd)" >/dev/null 2>&1
  bash "$PM" touch "$(pwd)" >/dev/null 2>&1
  PROJECT_INFO=$(cat "$MINUS_JSON" 2>/dev/null)
  PROGRESS_FILE=".claude/memory/minus-progress.md"

  # 首次进入检测：后端步骤为空 + 无初始页面标记
  FIRST_ENTRY="false"
  if [ ! -f ".minus/initialized" ]; then
    FIRST_ENTRY="true"
  fi

  # ── 环境检查 ──
  AUTH_OK="false"
  if [ "$LOGGED_IN" = "true" ]; then
    AUTH_OK="true"
  fi

  NEED_NPM_INSTALL="false"
  if [ -f "package.json" ] && [ ! -d "node_modules" ]; then
    NEED_NPM_INSTALL="true"
  fi

  NEED_PIP_INSTALL="false"
  if [ -f "pyproject.toml" ] && [ ! -d ".venv" ]; then
    NEED_PIP_INSTALL="true"
  fi

  echo "<context>"
  echo "Minus Creator Plugin 已激活。"
  echo "当前目录是 Minus Skill 项目。"
  echo "项目信息：$PROJECT_INFO"
  echo ""
  echo "环境检查结果："
  echo "  鉴权状态：$( [ "$AUTH_OK" = "true" ] && echo "已登录" || echo "未登录，需重新登录" )"
  echo "  项目识别：.minus/skill.json 存在"
  echo "  前端依赖：$( [ "$NEED_NPM_INSTALL" = "true" ] && echo "需要安装（无 node_modules）" || echo "已就绪" )"
  echo "  后端依赖：$( [ "$NEED_PIP_INSTALL" = "true" ] && echo "需要安装（无 .venv）" || echo "已就绪" )"
  echo "  首次进入：$FIRST_ENTRY"

  if [ -f "$PROGRESS_FILE" ]; then
    echo ""
    echo "发现未完成的开发进度："
    cat "$PROGRESS_FILE"
  fi

  echo ""
  echo "[指令] 不要等待用户输入，立即按以下顺序自动执行："
  echo "1. 如果鉴权未通过，先引导登录。"
  echo "2. 如果前端依赖需要安装，执行 npm install，告知 Creator「正在初始化开发环境...」"
  echo "3. 如果后端依赖需要安装，执行 python -m venv .venv && source .venv/bin/activate && pip install -e .，告知 Creator「正在安装后端依赖...」"
  echo "4. 如果是首次进入（首次进入=true）："
  echo "   a. 通过 skill_list MCP tool 读取后端 Skill 信息"
  echo "   b. 基于 Skill 信息自动生成初始页面代码（使用项目中已有的模板文件）"
  echo "   c. 启动 dev server 并告知 Creator 预览地址（http://localhost:{port}/preview）"
  echo "   d. 创建 .minus/initialized 标记文件，下次不再重复"
  echo "   e. 告知 Creator：初始页面已生成，可以在浏览器中查看"
  echo "   f. 引导 Creator 开始结构设计（三步法）"
  echo "5. 如果不是首次进入，报告状态：✓ Minus 已就绪 — {Skill名称} v{版本}"
  echo "6. 如果有未完成进度，告知上次做到哪里、下一步建议做什么。"
  echo "7. 如果无进度且非首次，引导 Creator 继续开发或选择其他操作。"
  echo "用通俗语言，不要技术术语。"
  echo "</context>"

# 场景 2：在 Workspace 目录中
elif [ -f "$(pwd)/.minus-workspace" ] || [ "$(pwd)" = "$MINUS_WORKSPACE" ] || [[ "$(pwd)" == "$MINUS_WORKSPACE"/* ]]; then
  echo "<context>"
  echo "Minus Creator Plugin 已激活。"
  echo "当前在 Minus Workspace 目录中，但不是具体的 Skill 项目目录。"
  echo "登录状态：$LOGGED_IN"

  SKILL_DIRS=$(find "$(pwd)" -maxdepth 2 -name "skill.json" -path "*/.minus/*" 2>/dev/null)
  if [ -n "$SKILL_DIRS" ]; then
    echo "检测到以下 Skill 项目："
    for p in $SKILL_DIRS; do
      DIR=$(dirname "$p")
      NAME=$(basename "$DIR")
      echo "  - $NAME ($DIR)"
    done
    echo ""
    echo "[指令] 立即主动向 Creator 展示项目列表，引导选择一个打开，或创建新 Skill。不要等待用户输入。"
  else
    echo "[指令] 立即主动提示 Creator 还没有 Skill 项目，引导创建第一个。不要等待用户输入。"
  fi
  echo "</context>"

# 场景 3：在 Skill 子目录中（向上查找 .minus.json）
elif [ -f "../$MINUS_JSON" ] || [ -f "../../$MINUS_JSON" ]; then
  FOUND=""
  if [ -f "../$MINUS_JSON" ]; then FOUND=$(cd .. && pwd); fi
  if [ -f "../../$MINUS_JSON" ]; then FOUND=$(cd ../.. && pwd); fi

  echo "<context>"
  echo "Minus Creator Plugin 已激活。"
  echo "检测到当前在 Skill 项目的子目录中。"
  echo "项目根目录：$FOUND"
  echo "项目信息：$(cat "$FOUND/.minus/skill.json" 2>/dev/null)"
  echo ""
  echo "[指令] 立即主动告知 Creator：检测到项目，但当前在子目录中。"
  echo "建议下次直接以 $FOUND 作为工作目录。本次可以继续，但部分功能可能受限。"
  echo "不要等待用户输入。"
  echo "</context>"

# 场景 4：非 Minus 目录
else
  echo "<context>"
  echo "Minus Creator Plugin 已激活。"
  echo "当前目录不是 Minus 项目。"
  echo "登录状态：$LOGGED_IN"
  echo "已有项目数：$PROJECT_COUNT"
  echo "Workspace 路径：$MINUS_WORKSPACE"

  if [ "$PROJECT_COUNT" -gt 0 ] && [ -f "$PROJECTS_JSON" ]; then
    echo "已注册的项目列表："
    node -e "try{const d=JSON.parse(require('fs').readFileSync('$PROJECTS_JSON','utf8'));(d.projects||[]).forEach(p=>console.log('  - '+p.name+' ('+p.path+')'))}catch{}" 2>/dev/null
  fi

  echo ""
  echo "[指令] 不要等待用户输入，立即主动执行以下流程："
  echo "1. 如果未登录，先引导登录（询问是否有账号 → 发验证码 → 登录/注册）。"
  echo "2. 登录后，使用 skill_list MCP tool 查询 Creator 已有的 Skill。"
  echo "3. 如果有已有 Skill：展示列表，询问「你想做什么？1. 创建新的 Skill 项目  2. 打开已有的 Skill 项目」"
  echo "4. 如果没有 Skill：直接引导创建第一个「给你的 Skill 项目起个名字？」"
  echo "5. 创建新项目时：问名称 → 执行 create-skill 脚手架 → 引导打开项目文件夹"
  echo "6. 打开已有时：列出项目路径，引导打开对应文件夹"
  echo "用通俗语言，不要技术术语。语气友好自然。"
  echo "</context>"
fi
