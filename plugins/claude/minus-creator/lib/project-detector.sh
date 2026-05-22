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
  echo "Minus Creator Plugin 已加载，但需要 Node.js 才能正常工作。"
  echo "当前平台：$PLATFORM"
  echo "当 Creator 输入 /minus 时，引导安装 Node.js。"
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
  PROJECT_COUNT=$(node -e "
    const fs=require('fs');
    try{
      const d=JSON.parse(fs.readFileSync('$PROJECTS_JSON','utf8'));
      const before=(d.projects||[]).length;
      d.projects=(d.projects||[]).filter(p=>fs.existsSync(p.path));
      if(d.projects.length<before) fs.writeFileSync('$PROJECTS_JSON',JSON.stringify(d,null,2));
      console.log(d.projects.length);
    }catch{console.log(0)}
  " 2>/dev/null)
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

  PROJ_DISPLAY_NAME=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$MINUS_JSON','utf8')).name||'')}catch{}" 2>/dev/null)
  [ -z "$PROJ_DISPLAY_NAME" ] && PROJ_DISPLAY_NAME="$PROJ_NAME"

  echo "<context>"
  echo "Minus Creator Plugin 已加载。"
  echo "当前目录是 Minus Skill 项目：$PROJ_DISPLAY_NAME"
  echo "登录状态：$LOGGED_IN"
  echo "[自动触发] 检测到 Skill 项目，必须立即调用 Skill 工具执行 minus-creator:minus，不要等用户输入。"
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
