#!/bin/bash
# check-dev-server.sh
# 进入「结构设计」前的硬门禁：dev server 必须已在运行且属于当前项目。
#
# 用法: check-dev-server.sh
# 退出码:
#   0  → 前端 dev server 在跑且归属本项目（输出 GATE_PASSED + PREVIEW_PORT=端口）
#   1  → 未检测到属于本项目的 dev server（输出 GATE_FAILED + 启动指引）
#
# 设计原因（CLAUDE.md #1 能硬编码的别靠 Agent 自觉）：启动 dev server 是散文步骤，
# Agent 可能整段跳过。本门禁把「dev server 必须在跑」从 Agent 自觉变成代码强制——
# 跳过启动就进不了结构设计。
# 归属校验（CLAUDE.md #5 存在≠属于我）复用 detect-preview-port.sh，它已验证占用
# 进程的 cwd 属于本项目（Windows 靠 dev-ports.json 文件位置保证归属）。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 复用端口检测脚本，AUTO_OPEN=0 避免门禁里重复弹预览。
PORT=$(AUTO_OPEN=0 bash "$SCRIPT_DIR/detect-preview-port.sh" 2>/dev/null | head -1)

if [ -n "$PORT" ] && [ "$PORT" != "DETECT_FAILED" ]; then
  # 后端健康检查：前端活着不代表后端活着（典型场景：上一个 session 的 vite 还在、
  # 后端已死——此时若放行门禁，用户要到运行步骤撞 504 才发现）。后端端口由 SDK 写入
  # dev-ports.json 的 backend 字段；字段缺失时跳过本检查（Desktop 分支 A 等场景由
  # record-preview-port 只写 frontend，不应误伤）。
  # 路径必须用相对路径传给 node：Windows Git Bash 下 node 是原生二进制，
  # 读不了嵌在 JS 字符串里的 MSYS 绝对路径（/tmp/...、/c/...），相对路径两边通吃。
  BACKEND_PORT=""
  if [ -f .minus/dev-ports.json ]; then
    BACKEND_PORT=$(node -e "const p=JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).backend;console.log(p>0?p:'')" 2>/dev/null)
  fi
  if [ -n "$BACKEND_PORT" ] && ! curl -s -o /dev/null --max-time 2 "http://localhost:$BACKEND_PORT/" 2>/dev/null; then
    echo "GATE_FAILED"
    echo "BACKEND_DOWN"
    echo "前端预览（端口 $PORT）在运行，但后端（端口 $BACKEND_PORT）无响应。" >&2
    echo "请执行 env-init.md「4. dev server 异常处理」的固定重启脚本后重试本门禁。" >&2
    exit 1
  fi
  echo "GATE_PASSED"
  echo "PREVIEW_PORT=$PORT"
  [ -n "$BACKEND_PORT" ] && echo "BACKEND_PORT=$BACKEND_PORT"
  exit 0
fi

echo "GATE_FAILED"
echo "未检测到属于当前项目的 dev server，禁止进入结构设计。" >&2
echo "请先按 SKILL.md「3. 已登录 + 有项目」的步骤 2（探测预览能力）和步骤 3（启动 dev server + 打开预览）启动 dev server，再重试。" >&2
echo "Desktop 分支 A 场景：若预览已在右侧面板打开，先执行 minus-lib record-preview-port <实际端口> 记录端口，再重跑本门禁。" >&2
exit 1
