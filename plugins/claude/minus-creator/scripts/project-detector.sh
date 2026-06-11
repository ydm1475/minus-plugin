#!/bin/bash
# project-detector.sh
# SessionStart hook: 初始化 Minus 环境 + 输出轻量提示
#
# 设计变更 [2026-05-22]：从"自动执行完整流程"改为"只输出轻量提示"。
# 原因：自动跑登录/项目选择/创建流程会干扰不想使用 Plugin 的用户。
# 完整的交互流程（登录、项目选择、环境初始化）由 /minus skill 承担。

# ── 跨平台路径 ──
OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    PLATFORM="windows"
    # 与 MCP（os.homedir()/.minus）对齐：node 在 Windows 把 credentials.json 写到
    # %USERPROFILE%\.minus，Git Bash 下即 $HOME/.minus。旧的 %APPDATA%\Minus 读不到 → 登录态恒为 false。
    MINUS_GLOBAL="$HOME/.minus"
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

# ── Node.js 探测（不拦截流程）──
# 无 node 不再提前 exit：/minus 进入开发环境时 bootstrap-env.sh 会自动安装。
# 提前退出会让用户根本走不到自动安装那一步。这里只记录状态供 context 提示。
if command -v node >/dev/null 2>&1; then
  NODE_INFO="Node.js：$(node -v 2>/dev/null)"
else
  NODE_INFO="Node.js：未检测到（/minus 进入开发环境时会自动安装，无需手动处理）"
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
if [ -f "$PROJECTS_JSON" ] || [ -d "$HOME/minus" ]; then
  [ ! -f "$PROJECTS_JSON" ] && mkdir -p "$(dirname "$PROJECTS_JSON")" && echo '{"projects":[]}' > "$PROJECTS_JSON"
  PROJECT_COUNT=$(node -e "
    const fs=require('fs'),path=require('path'),os=require('os');
    try{
      const d=JSON.parse(fs.readFileSync('$PROJECTS_JSON','utf8'));
      const before=(d.projects||[]).length;
      d.projects=(d.projects||[]).filter(p=>fs.existsSync(p.path));
      if(!d.projects.length){
        const scanRoot=path.join(os.homedir(),'minus');
        try{
          for(const name of fs.readdirSync(scanRoot)){
            const pp=path.join(scanRoot,name);
            const sj=path.join(pp,'.minus','skill.json');
            if(!fs.statSync(pp).isDirectory())continue;
            if(!fs.existsSync(sj))continue;
            if(d.projects.some(p=>p.path===pp))continue;
            const st=fs.statSync(sj);
            d.projects.push({name,path:pp,created_at:st.birthtime.toISOString(),last_opened:st.mtime.toISOString()});
          }
        }catch{}
      }
      if(d.projects.length!==before)fs.writeFileSync('$PROJECTS_JSON',JSON.stringify(d,null,2));
      console.log(d.projects.length);
    }catch{console.log(0)}
  " 2>/dev/null)
fi
# node 缺失时上面会返回空，兜底为 0
[ -z "$PROJECT_COUNT" ] && PROJECT_COUNT=0

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

  PROJ_DISPLAY_NAME=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$MINUS_JSON','utf8')).name||'')}catch{}" 2>/dev/null)
  [ -z "$PROJ_DISPLAY_NAME" ] && PROJ_DISPLAY_NAME="$PROJ_NAME"

  echo "<context>"
  echo "Minus Creator Plugin 已加载。"
  echo "当前目录是 Minus Skill 项目：$PROJ_DISPLAY_NAME"
  echo "项目根目录：$(pwd)"
  echo "登录状态：$LOGGED_IN"
  echo "$NODE_INFO"
  echo "默认入口：当用户表达开发、继续、测试、发布等意图，或意图不明确但与本项目相关时，先调用 Skill 工具执行 minus-creator:minus 进入流程。"
  echo "在该项目内，凡是涉及 Skill 输入、步骤、pipeline、前端步骤渲染、测试或发布的请求，都属于 Minus Creator 开发流程；不要直接按普通代码任务修改项目文件。"
  echo "</context>"

# 场景 2：在 Workspace 目录中
elif [ -f "$(pwd)/.minus-workspace" ] || [ "$(pwd)" = "$MINUS_WORKSPACE" ] || [[ "$(pwd)" == "$MINUS_WORKSPACE"/* ]]; then
  echo "<context>"
  echo "Minus Creator Plugin 已加载。"
  echo "当前在 Minus Workspace 目录中。"
  echo "登录状态：$LOGGED_IN"
  echo "已有项目数：$PROJECT_COUNT"
  echo "输入 /minus 创建或打开 Skill 项目。"
  echo "</context>"

# 场景 3：在 Skill 子目录中
elif [ -f "../$MINUS_JSON" ] || [ -f "../../$MINUS_JSON" ]; then
  FOUND=""
  if [ -f "../$MINUS_JSON" ]; then FOUND=$(cd .. && pwd); fi
  if [ -f "../../$MINUS_JSON" ]; then FOUND=$(cd ../.. && pwd); fi

  echo "<context>"
  echo "Minus Creator Plugin 已加载。"
  echo "检测到 Skill 项目在上级目录：$FOUND"
  echo "建议以项目根目录作为工作目录。输入 /minus 了解详情。"
  echo "</context>"

# 场景 4：非 Minus 目录
else
  echo "<context>"
  echo "Minus Creator Plugin 已加载。"
  echo "当前目录不是 Minus 项目。"
  echo "登录状态：$LOGGED_IN"
  echo "已有项目数：$PROJECT_COUNT"
  echo "输入 /minus 开始。"
  echo "</context>"
fi
