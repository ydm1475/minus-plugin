#!/bin/bash
# env-manager.sh
# 自动环境管理：根据文件变更类型决定是否需要重启 dev server

CHANGED_FILE="$1"

if [ -z "$CHANGED_FILE" ]; then
  exit 0
fi

needs_restart() {
  case "$CHANGED_FILE" in
    vite.config.*|next.config.*|tsconfig.json|webpack.config.*)
      echo "config"
      return 0
      ;;
    package.json)
      echo "dependency"
      return 0
      ;;
    .env|.env.local|.env.*)
      echo "env"
      return 0
      ;;
    server.*|api/*)
      echo "backend"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

REASON=$(needs_restart)
if [ $? -eq 0 ]; then
  # 检测运行中的 dev server
  DEV_PID=$(lsof -ti :9100 2>/dev/null || lsof -ti :3000 2>/dev/null || lsof -ti :5173 2>/dev/null)

  if [ -n "$DEV_PID" ]; then
    PORT=$(lsof -Pan -p "$DEV_PID" -i 2>/dev/null | grep LISTEN | awk '{print $9}' | cut -d: -f2 | head -1)

    if [ "$REASON" = "dependency" ]; then
      echo "<context>"
      echo "[环境管理] 检测到 package.json 变更，需要安装依赖并重启开发服务器。"
      echo "请执行：npm install && 重启 dev server（端口 $PORT，PID $DEV_PID）"
      echo "</context>"
    else
      echo "<context>"
      echo "[环境管理] 检测到配置文件变更（$REASON），需要重启开发服务器。"
      echo "当前 dev server 运行在端口 $PORT（PID $DEV_PID）。"
      echo "请先 kill $DEV_PID 然后重新启动。"
      echo "</context>"
    fi
  fi
fi
