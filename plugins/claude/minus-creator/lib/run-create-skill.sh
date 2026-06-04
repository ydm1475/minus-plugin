#!/usr/bin/env bash
# run-create-skill.sh
# 创建 Skill 项目的确定性入口：解析合格 Node，安装/对齐 create-skill，然后执行。

set -euo pipefail

PROJECT_NAME="${1:-}"
if [ -z "$PROJECT_NAME" ]; then
  echo "CREATE_SKILL_MISSING_NAME"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE_NODE="$SCRIPT_DIR/resolve-node.sh"
BOOTSTRAP_ENV="$SCRIPT_DIR/bootstrap-env.sh"
CREATE_SKILL_SPEC="${MINUS_CREATE_SKILL_SPEC:-@minus-ai/create-skill@beta}"

NODE_BIN="$(sh "$RESOLVE_NODE" 2>/dev/null || true)"
if [ -z "$NODE_BIN" ]; then
  echo "NO_GOOD_NODE"
  exit 0
fi

node_dir="$(dirname "$NODE_BIN")"
export PATH="$node_dir:$PATH"

win_path() {
  local p d
  p="$(printf '%s' "$1" | tr '\\' '/')"
  case "$p" in
    [A-Za-z]:*)
      d="$(printf '%.1s' "$p" | tr '[:upper:]' '[:lower:]')"
      printf '/%s%s\n' "$d" "${p#?:}"
      ;;
    *) printf '%s\n' "$p" ;;
  esac
}

volta_home_dir() {
  if [ -n "${VOLTA_HOME:-}" ]; then
    win_path "$VOLTA_HOME"
  elif [ -n "${LOCALAPPDATA:-}" ]; then
    win_path "$LOCALAPPDATA/Volta"
  else
    printf '%s\n' "$HOME/.volta"
  fi
}

VOLTA_HOME_DIR="$(volta_home_dir)"
VOLTA_BIN="$VOLTA_HOME_DIR/bin/volta"
[ -d "$VOLTA_HOME_DIR/bin" ] && export PATH="$VOLTA_HOME_DIR/bin:$PATH"

NPM_BIN=""
for n in "$node_dir/npm" "$node_dir/npm.cmd" "$(command -v npm 2>/dev/null || true)"; do
  [ -n "$n" ] && [ -x "$n" ] && { NPM_BIN="$n"; break; }
done
if [ -z "$NPM_BIN" ]; then
  echo "CREATE_SKILL_INSTALL_FAILED"
  exit 0
fi

# create-skill 生成项目时要给 volta.node 落一个确切的 node24 patch（见 create-skill 的
# resolveProjectNodeVersion）：首选 ~/.volta 里已装的 ≥NODE_FLOOR image。/minus 创建步骤
# 早于 bootstrap，机器若没预装 node24 → create-skill 取不到版本号、报「未找到 Node 24+」退出
# （服务端已注册、本地零文件），且那句自然语言会诱导 Agent 自行 brew/nvm 装 node。故这里
# 确定性地用 Volta 备好 node24，把"装哪个 node、怎么装"从 Agent 手里收回（CLAUDE.md 设计原则①）。
ensure_project_node() {
  local img_dir="$VOLTA_HOME_DIR/tools/image/node" name major
  if [ -d "$img_dir" ]; then
    for name in "$img_dir"/*; do
      [ -d "$name" ] || continue
      major="${name##*/}"; major="${major%%.*}"
      if [ "$major" -ge "${NODE_FLOOR:-24}" ] 2>/dev/null; then
        return 0
      fi
    done
  fi
  provision_node_via_volta
}

# 安装策略与 node24 配给都复用 bootstrap-env.sh（镜像源同源 + provision 同源）。
if [ -f "$BOOTSTRAP_ENV" ]; then
  # shellcheck source=/dev/null
  . "$BOOTSTRAP_ENV"
  setup_cn_mirror >/dev/null 2>&1 || true
  # 备好生成项目要 pin 的 node24；失败走固定标记，绝不让 create-skill 跑到它自己的
  # 「未找到 Node 24+」stderr（那是诱导 Agent 自行装 node 的入口）。
  if ! ensure_project_node; then
    echo "NODE24_PROVISION_FAILED"
    exit 0
  fi
fi

npm_global_bin() {
  local prefix
  prefix="$("$NPM_BIN" prefix -g 2>/dev/null || true)"
  [ -n "$prefix" ] || return 0
  prefix="$(win_path "$prefix")"
  if [ -d "$prefix/bin" ]; then
    printf '%s\n' "$prefix/bin"
  else
    printf '%s\n' "$prefix"
  fi
}

installed_version_via_volta() {
  local pkg="$VOLTA_HOME_DIR/tools/image/packages/@minus-ai/create-skill/lib/node_modules/@minus-ai/create-skill/package.json"
  "$NODE_BIN" -p "try{require(process.argv[1]).version}catch{''}" "$pkg" 2>/dev/null || true
}

installed_version_via_npm() {
  "$NPM_BIN" list -g @minus-ai/create-skill --depth=0 --json 2>/dev/null \
    | "$NODE_BIN" -p "try{JSON.parse(require('fs').readFileSync(0,'utf8')).dependencies['@minus-ai/create-skill'].version}catch{''}" 2>/dev/null || true
}

echo "正在安装/更新 ${CREATE_SKILL_SPEC}……"
CREATE_SKILL_EXPECTED="$("$NPM_BIN" view "$CREATE_SKILL_SPEC" version --registry=https://registry.npmjs.org 2>/dev/null || true)"
CREATE_SKILL_INSTALLED=""

if [ -x "$VOLTA_BIN" ]; then
  "$VOLTA_BIN" install "$CREATE_SKILL_SPEC" >/dev/null 2>&1 || true
  CREATE_SKILL_INSTALLED="$(installed_version_via_volta)"
else
  "$NPM_BIN" install -g "$CREATE_SKILL_SPEC" >/dev/null 2>&1 || true
  CREATE_SKILL_INSTALLED="$(installed_version_via_npm)"
fi

if [ -n "$CREATE_SKILL_EXPECTED" ] && [ "$CREATE_SKILL_INSTALLED" != "$CREATE_SKILL_EXPECTED" ]; then
  echo "镜像版本未就绪，改用官方 npm 源重试……"
  if [ -x "$VOLTA_BIN" ]; then
    npm_config_registry=https://registry.npmjs.org "$VOLTA_BIN" install "@minus-ai/create-skill@$CREATE_SKILL_EXPECTED" >/dev/null 2>&1 || true
    CREATE_SKILL_INSTALLED="$(installed_version_via_volta)"
  else
    "$NPM_BIN" install -g "@minus-ai/create-skill@$CREATE_SKILL_EXPECTED" --registry=https://registry.npmjs.org >/dev/null 2>&1 || true
    CREATE_SKILL_INSTALLED="$(installed_version_via_npm)"
  fi
fi

CREATE_SKILL_BIN=""
if [ -x "$VOLTA_BIN" ]; then
  for candidate in "$VOLTA_HOME_DIR/bin/create-skill" "$VOLTA_HOME_DIR/bin/create-skill.cmd"; do
    if [ -x "$candidate" ]; then
      CREATE_SKILL_BIN="$candidate"
      break
    fi
  done
else
  npm_bin_dir="$(npm_global_bin)"
  if [ -n "$npm_bin_dir" ]; then
    for candidate in "$npm_bin_dir/create-skill" "$npm_bin_dir/create-skill.cmd"; do
      if [ -x "$candidate" ]; then
        CREATE_SKILL_BIN="$candidate"
        break
      fi
    done
  fi
fi

if [ -z "$CREATE_SKILL_EXPECTED" ] || [ "$CREATE_SKILL_INSTALLED" != "$CREATE_SKILL_EXPECTED" ] || [ -z "$CREATE_SKILL_BIN" ]; then
  echo "CREATE_SKILL_INSTALL_FAILED"
  exit 0
fi

mkdir -p "$HOME/minus"
cd "$HOME/minus"
"$CREATE_SKILL_BIN" "$PROJECT_NAME" --non-interactive
