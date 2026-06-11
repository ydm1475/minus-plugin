#!/bin/bash
# Minus Creator Plugin 安装脚本
# 用法: bash install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# marketplace 根目录是 minus-creator 的父级 claude/（.claude-plugin/marketplace.json 所在处）
MARKETPLACE_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_NAME="minus-creator"
MARKETPLACE_NAME="minus-plugin"

GREEN='\033[0;32m'
NC='\033[0m'
PLUGIN_ID="${PLUGIN_NAME}@${MARKETPLACE_NAME}"

# 查询插件状态：echo "enabled" / "disabled" / "missing"
plugin_state() {
  claude plugin list --json 2>/dev/null | node -e '
    let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      let arr=[]; try{arr=JSON.parse(s||"[]")}catch{}
      const p=arr.find(x=>x.id===process.argv[1]);
      console.log(!p?"missing":(p.enabled?"enabled":"disabled"));
    });
  ' "$PLUGIN_ID"
}

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Minus Creator Plugin Installer     ║"
echo "╚══════════════════════════════════════╝"
echo ""

# 1. 检测 Claude Code
if ! command -v claude &>/dev/null; then
  echo "❌ 未检测到 Claude Code CLI，请先安装。"
  exit 1
fi
echo -e "${GREEN}✓${NC} 检测到 Claude Code: $(claude --version 2>/dev/null || echo 'unknown')"

# 1.5 Node 版本 gate（建议 Node 24）
# MCP server（bundle）与后续 installPath 解析都依赖 node；缺/旧则询问后用 Volta 装 24。
# 复用 bootstrap-env.sh 的 provision_node_via_volta / node_major_ok（NODE_FLOOR=24）。
# ⚠️ 局限：此检查走的是终端 PATH；客户端 spawn MCP 用的是 launchd PATH，二者可能不一致。
#    若装了新 node 但 skill_update 仍连不上，需把客户端 PATH 上的旧 node（如
#    /usr/local/bin/node）也替换/升级掉——那是系统层操作，不在本脚本范围。
source "$SCRIPT_DIR/scripts/bootstrap-env.sh"
NODE_MIN=20  # 技术硬下限：mcp-remote 依赖 undici File API，需 Node 20+；对外建议 24

node_major() {
  command -v node >/dev/null 2>&1 || { echo ""; return; }
  node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo ""
}

echo ""
echo "→ 检查 Node 版本（建议 Node 24）..."
NMAJ="$(node_major)"
if [ -z "$NMAJ" ] || [ "$NMAJ" -lt "$NODE_MIN" ] 2>/dev/null; then
  if [ -z "$NMAJ" ]; then
    echo "  未检测到 Node.js，建议安装 Node 24（最低 ${NODE_MIN}）。"
  else
    echo "  当前 Node $(node -v 2>/dev/null) 过旧，建议升级到 Node 24（最低 ${NODE_MIN}）。"
  fi
  printf "  是否现在帮你安装 Node 24？[Y/n] "
  read -r ans
  case "$ans" in
    [Nn]*)
      echo "❌ 已取消。请自行安装 Node 24（最低 ${NODE_MIN}，推荐 https://volta.sh）后重跑 install.sh。"
      exit 1 ;;
    *)
      if provision_node_via_volta; then
        echo -e "${GREEN}✓${NC} Node 已就绪（$(node -v 2>/dev/null)，Volta 管理 Node 24）"
      else
        echo "❌ Node 24 自动安装失败。请手动安装 Node 24（推荐 https://volta.sh）后重跑 install.sh。"
        exit 1
      fi ;;
  esac
elif [ "$NMAJ" -lt "$NODE_FLOOR" ] 2>/dev/null; then
  echo -e "${GREEN}✓${NC} Node $(node -v 2>/dev/null) 可用；建议升级到 Node 24 以获得最佳体验。"
else
  echo -e "${GREEN}✓${NC} Node 已就绪（$(node -v 2>/dev/null)）"
fi

# 1.6 自迁移：把 marketplace 根目录固化到稳定家目录，绝不从解压/下载目录注册。
# 根因：directory-source marketplace 存的是对该路径的实时引用，源目录一旦被删/移动就 cache-miss。
# 把"目录必须持久"从口头契约变成代码保证（对齐设计原则 #1）。
STABLE_HOME="$HOME/.claude/minus-creator-marketplace"
if [ "$(cd "$MARKETPLACE_DIR" && pwd -P)" != "$STABLE_HOME" ]; then
  echo ""
  echo "→ 固化 marketplace 到稳定目录：$STABLE_HOME"
  rm -rf "$STABLE_HOME"; mkdir -p "$STABLE_HOME"
  ( cd "$MARKETPLACE_DIR" && tar --exclude='./*/node_modules' --exclude='./.git' -cf - . ) \
    | ( cd "$STABLE_HOME" && tar -xf - )
  MARKETPLACE_DIR="$STABLE_HOME"
  echo -e "${GREEN}✓${NC} 已固化到 $STABLE_HOME"
fi

# 2. 注册 marketplace（remove->add 强制重指稳定目录）
# 重指：机器上若残留指向已死临时目录的旧注册，remove->add 会重新指向稳定目录，自愈。
echo ""
echo "→ 注册 marketplace（remove->add 强制重指稳定目录）..."
claude plugin marketplace remove "$MARKETPLACE_NAME" 2>/dev/null || true
claude plugin marketplace add "$MARKETPLACE_DIR"
echo -e "${GREEN}✓${NC} Marketplace 注册成功（来源：$MARKETPLACE_DIR）"

# 3. 安装并启用插件（区分 未装 / 已装未启用 / 已启用）
echo ""
echo "→ 安装插件..."
case "$(plugin_state)" in
  enabled)
    echo -e "${GREEN}✓${NC} 插件已安装并启用" ;;
  disabled)
    echo "  插件已安装但未启用，启用中..."
    claude plugin enable "$PLUGIN_ID"
    echo -e "${GREEN}✓${NC} 插件已启用" ;;
  *)
    # 装前清残留缓存：claude plugin install 先把插件解到 temp_local_* 暂存目录，再
    # rename 成 cache/<mp>/<plugin>/<ver>。撞到上次失败/旧版的残留目标目录时，
    # Windows 的 fs.rename 会 EPERM（无法覆盖非空目录）。清掉残留暂存目录 + 本插件
    # cache 目标，保证 rename 有干净落点（原则 #1：别靠 agent 手动清缓存）。
    CACHE_ROOT="$HOME/.claude/plugins/cache"
    if [ -d "$CACHE_ROOT" ]; then
      rm -rf "$CACHE_ROOT"/temp_local_* 2>/dev/null || true
      rm -rf "$CACHE_ROOT/$MARKETPLACE_NAME/$PLUGIN_NAME" 2>/dev/null || true
    fi
    claude plugin install "$PLUGIN_ID"
    echo -e "${GREEN}✓${NC} 插件安装成功" ;;
esac

# 4. 校验 MCP Server 产物（自包含 bundle，依赖已内联，无需 npm install）
echo ""
echo "→ 校验 MCP Server 产物..."
INSTALL_PATH="$(claude plugin list --json 2>/dev/null | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const p=JSON.parse(s||"[]").find(x=>x.id===process.argv[1]);
    process.stdout.write(p?p.installPath:"");
  });' "$PLUGIN_ID")"
MCP_DIR="$INSTALL_PATH/mcp-servers/minus-platform"
if [ -z "$INSTALL_PATH" ] || [ ! -f "$MCP_DIR/dist/minus-platform.cjs" ]; then
  echo "❌ 未找到 MCP Server 产物 dist/minus-platform.cjs（installPath=[$INSTALL_PATH]）。MCP 是必需项，安装中止。"
  exit 1
fi
# launcher：.mcp.json 的 command:"node" 实际跑它（按已知位置探测 >=20 node 再跑 bundle，
# 绕开「客户端 spawn 的 node 被老 node 遮挡」问题，跨平台）。缺它 MCP 起不来。
if [ ! -f "$MCP_DIR/launch.cjs" ]; then
  echo "❌ 未找到 MCP launcher（$MCP_DIR/launch.cjs）。MCP 是必需项，安装中止。"
  exit 1
fi
echo -e "${GREEN}✓${NC} MCP Server 产物就绪"

# 5. 校验：插件是否真的被启用（凭实际状态判定，不凭"没报错"）
echo ""
echo "→ 校验安装结果..."
STATE="$(plugin_state)"
if [ "$STATE" != "enabled" ]; then
  echo "❌ 校验失败：${PLUGIN_ID} 当前状态为 [${STATE}]，未处于 enabled。"
  echo "   请检查上面的报错；marketplace 来源目录：$MARKETPLACE_DIR"
  exit 1
fi
echo -e "${GREEN}✓${NC} 已确认插件安装并启用（enabled）"

# 6. 完成
echo ""
echo "══════════════════════════════════════"
echo -e "${GREEN}安装完成！${NC}"
echo ""
echo "使用方法："
echo "  1. 重启 Claude Code 会话"
echo "  2. 输入 /minus 开始开发 Skill"
echo "══════════════════════════════════════"
echo ""
