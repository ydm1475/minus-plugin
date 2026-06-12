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

# Windows Git Bash 下 node 是原生二进制，读不了嵌在 JS 字符串里的 MSYS 路径
# （/c/Users/... 或 APPDATA 缺失时的 /tmp/...）。cygpath -m 转成 C:/Users/...
# 正斜杠形式，JS 字符串里无需转义，两边通吃。下方所有 node -e 统一用本变量。
js_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}
PROJECTS_FILE_JS="$(js_path "$PROJECTS_FILE")"

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
      const fs = require('fs'), path = require('path'), os = require('os');
      const d = JSON.parse(fs.readFileSync('$PROJECTS_FILE_JS','utf8'));
      const before = (d.projects||[]).length;
      d.projects = (d.projects||[]).filter(p => fs.existsSync(p.path));
      // 兜底：projects.json 为空时扫描 ~/minus/*/.minus/skill.json 重建
      if (!d.projects.length) {
        const scanRoot = path.join(os.homedir(), 'minus');
        try {
          for (const name of fs.readdirSync(scanRoot)) {
            const projPath = path.join(scanRoot, name);
            const skillJson = path.join(projPath, '.minus', 'skill.json');
            if (!fs.statSync(projPath).isDirectory()) continue;
            if (!fs.existsSync(skillJson)) continue;
            if (d.projects.some(p => p.path === projPath)) continue;
            const stat = fs.statSync(skillJson);
            d.projects.push({ name, path: projPath, created_at: stat.birthtime.toISOString(), last_opened: stat.mtime.toISOString() });
          }
        } catch {}
      }
      if (d.projects.length !== before) {
        fs.writeFileSync('$PROJECTS_FILE_JS', JSON.stringify(d,null,2));
      }
      const sorted = d.projects.sort((a,b) => (b.last_opened||'').localeCompare(a.last_opened||''));
      sorted.forEach((p,i) => console.log((i+1)+'. '+p.name+'  '+p.path));
      if(!sorted.length) console.log('（无项目）');
    " 2>/dev/null
    ;;

  add)
    ensure_file
    NAME="$2"
    PROJ_PATH="$(js_path "$3")"
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    node -e "
      const fs = require('fs');
      const d = JSON.parse(fs.readFileSync('$PROJECTS_FILE_JS','utf8'));
      if(!d.projects) d.projects=[];
      const exists = d.projects.find(p => p.path === '$PROJ_PATH');
      if(!exists) {
        d.projects.push({name:'$NAME',path:'$PROJ_PATH',created_at:'$NOW',last_opened:'$NOW'});
        fs.writeFileSync('$PROJECTS_FILE_JS', JSON.stringify(d,null,2));
        console.log('已注册: $NAME ($PROJ_PATH)');
      } else {
        console.log('已存在: $NAME ($PROJ_PATH)');
      }
    " 2>/dev/null
    ;;

  remove)
    ensure_file
    PROJ_PATH="$(js_path "$2")"
    node -e "
      const fs = require('fs');
      const d = JSON.parse(fs.readFileSync('$PROJECTS_FILE_JS','utf8'));
      const before = (d.projects||[]).length;
      d.projects = (d.projects||[]).filter(p => p.path !== '$PROJ_PATH');
      fs.writeFileSync('$PROJECTS_FILE_JS', JSON.stringify(d,null,2));
      console.log('移除了 '+(before - d.projects.length)+' 个项目');
    " 2>/dev/null
    ;;

  touch)
    ensure_file
    PROJ_PATH="$(js_path "$2")"
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    node -e "
      const fs = require('fs');
      const d = JSON.parse(fs.readFileSync('$PROJECTS_FILE_JS','utf8'));
      const p = (d.projects||[]).find(p => p.path === '$PROJ_PATH');
      if(p) { p.last_opened = '$NOW'; fs.writeFileSync('$PROJECTS_FILE_JS', JSON.stringify(d,null,2)); }
    " 2>/dev/null
    ;;

  find)
    ensure_file
    NAME="$2"
    node -e "
      const d = JSON.parse(require('fs').readFileSync('$PROJECTS_FILE_JS','utf8'));
      const p = (d.projects||[]).find(p => p.name === '$NAME');
      if(p) console.log(p.path); else process.exit(1);
    " 2>/dev/null
    ;;

  *)
    echo "用法: projects-manager.sh <list|add|remove|touch|find> [args]"
    exit 1
    ;;
esac
