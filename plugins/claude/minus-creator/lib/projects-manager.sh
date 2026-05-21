#!/bin/bash
# projects-manager.sh
# 管理 ~/.minus/projects.json 本地项目注册表
# 用法: projects-manager.sh <command> [args]
#   list                     — 列出所有项目（按 last_opened 倒序）
#   add <name> <path>        — 注册新项目
#   remove <path>            — 移除项目
#   touch <path>             — 更新 last_opened
#   find <name>              — 按名称查找项目路径

OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    PROJECTS_FILE="${APPDATA:-$HOME}/Minus/projects.json" ;;
  Darwin*)
    PROJECTS_FILE="$HOME/.minus/projects.json" ;;
  *)
    PROJECTS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/minus/projects.json" ;;
esac

ensure_file() {
  if [ ! -f "$PROJECTS_FILE" ]; then
    mkdir -p "$(dirname "$PROJECTS_FILE")"
    echo '{"projects":[]}' > "$PROJECTS_FILE"
  fi
}

case "$1" in
  list)
    ensure_file
    node -e "
      const fs = require('fs');
      const d = JSON.parse(fs.readFileSync('$PROJECTS_FILE','utf8'));
      const before = (d.projects||[]).length;
      d.projects = (d.projects||[]).filter(p => fs.existsSync(p.path));
      if (d.projects.length < before) {
        fs.writeFileSync('$PROJECTS_FILE', JSON.stringify(d,null,2));
      }
      const sorted = d.projects.sort((a,b) => (b.last_opened||'').localeCompare(a.last_opened||''));
      sorted.forEach((p,i) => console.log((i+1)+'. '+p.name+'  '+p.path));
      if(!sorted.length) console.log('（无项目）');
    " 2>/dev/null
    ;;

  add)
    ensure_file
    NAME="$2"
    PROJ_PATH="$3"
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    node -e "
      const fs = require('fs');
      const d = JSON.parse(fs.readFileSync('$PROJECTS_FILE','utf8'));
      if(!d.projects) d.projects=[];
      const exists = d.projects.find(p => p.path === '$PROJ_PATH');
      if(!exists) {
        d.projects.push({name:'$NAME',path:'$PROJ_PATH',created_at:'$NOW',last_opened:'$NOW'});
        fs.writeFileSync('$PROJECTS_FILE', JSON.stringify(d,null,2));
        console.log('已注册: $NAME ($PROJ_PATH)');
      } else {
        console.log('已存在: $NAME ($PROJ_PATH)');
      }
    " 2>/dev/null
    ;;

  remove)
    ensure_file
    PROJ_PATH="$2"
    node -e "
      const fs = require('fs');
      const d = JSON.parse(fs.readFileSync('$PROJECTS_FILE','utf8'));
      const before = (d.projects||[]).length;
      d.projects = (d.projects||[]).filter(p => p.path !== '$PROJ_PATH');
      fs.writeFileSync('$PROJECTS_FILE', JSON.stringify(d,null,2));
      console.log('移除了 '+(before - d.projects.length)+' 个项目');
    " 2>/dev/null
    ;;

  touch)
    ensure_file
    PROJ_PATH="$2"
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    node -e "
      const fs = require('fs');
      const d = JSON.parse(fs.readFileSync('$PROJECTS_FILE','utf8'));
      const p = (d.projects||[]).find(p => p.path === '$PROJ_PATH');
      if(p) { p.last_opened = '$NOW'; fs.writeFileSync('$PROJECTS_FILE', JSON.stringify(d,null,2)); }
    " 2>/dev/null
    ;;

  find)
    ensure_file
    NAME="$2"
    node -e "
      const d = JSON.parse(require('fs').readFileSync('$PROJECTS_FILE','utf8'));
      const p = (d.projects||[]).find(p => p.name === '$NAME');
      if(p) console.log(p.path); else process.exit(1);
    " 2>/dev/null
    ;;

  *)
    echo "用法: projects-manager.sh <list|add|remove|touch|find> [args]"
    exit 1
    ;;
esac
