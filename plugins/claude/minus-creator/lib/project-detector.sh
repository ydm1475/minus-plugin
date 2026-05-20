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
  echo "  插件脚本目录：$SCRIPT_DIR"
  echo "  首次进入：$FIRST_ENTRY"

  if [ -f "$PROGRESS_FILE" ]; then
    echo ""
    echo "发现未完成的开发进度："
    cat "$PROGRESS_FILE"
  fi

  echo ""
  echo "[指令] 不要等待用户输入，不要询问用户，立即按以下顺序自动执行："
  echo "1. 如果鉴权未通过，先引导登录。"
  echo "2. 如果前端依赖显示「需要安装」，你的第一个动作必须是执行 Bash(npm install)，不要说话、不要询问、不要解释，直接执行。"
  echo "3. 如果后端依赖显示「需要安装」，你的下一个动作必须是执行 Bash(uv venv -p 3.12 && uv pip install -e .)，不要说话、不要询问、不要解释，直接执行。"
  echo "4. 执行 Bash(npm run dev) 启动开发服务器（后台运行）。"
  echo "   等待几秒后，从 dev server 的输出日志中找到 Vite 的前端地址（包含 'Local: http://localhost:' 的那行）。"
  echo "   注意：package.json 的 dev 命令用 concurrently 同时启动后端和前端，后端端口（如 4003）不是预览地址。"
  echo "   必须用 Vite 输出的前端端口（通常 5173 开始），执行 Bash(open http://localhost:{前端端口}) 打开浏览器。"
  echo "   告知 Creator 预览地址（不要加 /preview）。"
  echo "5. 如果是首次进入（首次进入=true）："
  echo "   a. 通过 skill_list MCP tool 读取后端 Skill 信息"
  echo "   b. 创建 .minus/initialized 标记文件，下次不再重复"
  echo "   c. 原样输出以下内容（不要改写，不要分析代码，不要描述页面组件）："
  echo "      「你现在看到的是 Skill 的初始框架，包含：」"
  echo "      「 · 名称、描述、适用客户、标签、版本等基本信息」"
  echo "      「 · 这些都是默认值，随时告诉我修改」"
  echo "      「接下来我们用三步法设计这个 Skill。」"
  echo "      「第一个问题：用户使用这个 Skill 时，需要提供什么信息？」"
  echo "      「比如关键词、ASIN、品类……」"
  echo "      「还有，这个输入是否支持多个？只支持一个，只支持多个，支持一个和多个」"
  echo "   d. 三步法严格按顺序执行，每步确认后才能进入下一步："
  echo "      第一步确认 → 执行 skill_update + 改前端输入组件 + 同步更新 locale 文件（zh-CN.json、en-US.json） → 问第二个问题："
  echo "      「第二个问题：拿到用户的输入后，Skill 要分几步完成？每一步做什么？」"
  echo "      第二步确认 → 执行 skill_update 写入步骤 → 问第三个问题："
  echo "      「最后一个问题：Skill 跑完之后，最终给用户看什么结果？」"
  echo "      「比如一份报告、一个关键词列表、一个评分……」"
  echo "      第三步确认 → 必须执行 bash \"$SCRIPT_DIR/generate-steps.sh\" 生成骨架 → 开始逐节点开发"
  echo "      ⛔ 禁止跳步：每一步必须问 Creator 并等确认，不能把 Creator 的回答当作多步的答案"
  echo "      ⛔ 禁止手写步骤代码：必须用 bash \"$SCRIPT_DIR/generate-steps.sh\" 生成骨架，不要自己手写 pipeline.py 和 main.tsx 的步骤结构"
  echo "   e. 逐节点开发时，每个步骤严格按四个维度推进，每次回复最多推进一个维度："
  echo "      ① Creator 确认数据需求 → 写数据获取代码 → 回复末尾原样输出："
  echo "        「数据获取已写好。下一个问题：拿到这些数据之后，怎么处理？」"
  echo "        「比如：直接透传原始数据？做聚合排序？用大模型做分析总结？」"
  echo "      ② Creator 确认处理逻辑 → 写处理代码 → 回复末尾原样输出："
  echo "        「处理逻辑已写好。下一个问题：这一步要展示什么给用户看？」"
  echo "        「还有，需要传什么数据给下一步？」"
  echo "      ③ Creator 确认输出定义 → 写输出代码 → 回复末尾原样输出："
  echo "        「输出已写好。最后一个问题：用户运行到这一步后，需要暂停确认再继续吗？还是自动往下走？」"
  echo "      ④ Creator 确认 → 标记节点完成 → 进入下一个步骤"
  echo "      ⛔ 禁止：在一次回复中完成多个维度的代码"
  echo "      ⛔ 禁止：跳过任何维度直接宣布步骤完成"
  echo "   禁止：读取或分析项目代码、描述页面组件（输入框、按钮等）"
  echo "6. 如果不是首次进入，根据状态给针对性提示（读取 Memory 和后端 Skill 信息判断）："
  echo "   状态 A（有未完成进度）：告知上次做到哪，下一步是什么，问要不要继续"
  echo "   状态 B（所有步骤开发完成但未测试）：建议跑端到端测试"
  echo "   状态 C（测试已通过）：提示可以发布，输入 /minus publish"
  echo "   状态 D（无进度）：报告 ✓ Minus 已就绪 — {Skill名称} v{版本}，引导开始结构设计"
  echo "7. 如果 Creator 说要「创建新项目」「创建新 Skill」而不是继续开发当前项目："
  echo "   不要在当前项目目录里创建。引导 Creator："
  echo "   「当前目录已经是 {当前项目名} 的项目了。要创建新 Skill 请：」"
  echo "   「1. 新开一个对话」"
  echo "   「2. 选择 ~/minus/ 文件夹作为工作目录」"
  echo "   「3. 在新对话里告诉我你要创建的项目名」"
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
  echo ""
  echo "== 登录流程（如果未登录）=="
  echo "Step A：问 Creator 有没有账号"
  echo "Step B：问 Creator 的手机号——原样输出：「你的手机号是多少？」"
  echo "  禁止：自动使用 userEmail 或系统上下文中的任何邮箱/手机号"
  echo "  禁止：在 Creator 回答之前调用任何 auth 相关的 MCP tool"
  echo "  禁止：提到邮箱，只支持手机号"
  echo "Step C：等 Creator 提供手机号"
  echo "Step D：问 Creator 用密码还是验证码登录——原样输出：「你想用密码登录还是验证码登录？」"
  echo "  如果选密码：用 auth_login（grantType=phone_password）直接登录"
  echo "  如果选验证码：先用 auth_vcode 发验证码，再用 auth_login（grantType=phone_code）登录"
  echo "Step E：完成认证"
  echo ""
  echo "== 登录后流程 =="
  echo "1. 使用 skill_list MCP tool 查询 Creator 已有的 Skill。"
  echo "2. 如果有已有 Skill：先列出所有项目名称和简介，然后询问："
  echo "   「你想做什么？1. 创建新的 Skill 项目  2. 打开已有的 Skill 项目」"
  echo "   必须先展示项目列表，不要只说「你有 N 个项目」"
  echo "3. 如果没有 Skill：跳过选择，直接进入创建流程。"
  echo ""
  echo "== 创建新项目（严格执行，禁止改写）=="
  echo "Step 1：原样输出以下提示语（不要改写、不要加任何额外说明）："
  echo "  「给你的 Skill 项目起个名字？（这会作为项目文件夹名）」"
  echo "Step 2：拿到名称后，立刻用 Bash 执行："
  echo "  cd ~/minus && create-skill \"项目名称\" --non-interactive"
  echo "  禁止：在执行前再问描述、输入类型等任何问题"
  echo "  禁止：调用 skill_create MCP tool（该 tool 已移除）"
  echo "Step 3：创建完成后，引导 Creator 新开对话（不要在当前 session 继续开发）："
  echo "  原样输出：「项目已创建！接下来请：」"
  echo "  「1. 新开一个对话」"
  echo "  「2. 选择 ~/minus/{项目名称}/ 文件夹作为工作目录」"
  echo "  「3. Plugin 会自动激活，你直接开始工作就行」"
  echo ""
  echo "== 打开已有项目 =="
  echo "列出项目路径，引导 Creator 新开对话并选择对应文件夹作为工作目录。"
  echo ""
  echo "用通俗语言，不要技术术语。语气友好自然。"
  echo "</context>"
fi
