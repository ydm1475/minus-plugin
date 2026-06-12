#!/bin/bash
# check-running-flow.sh
# 检测当前项目的后端是否疑似有进行中的流程执行（Creator 正在浏览器里跑流程）。
#
# 用法: check-running-flow.sh
# 输出:
#   RUNNING — 后端端口上有 ESTABLISHED 连接（SSE 流/活跃页面），大概率有人在跑流程
#   IDLE    — 无活跃连接，或后端未启动（没有可被打断的执行）
# 退出码恒为 0（这是信息探测，不是门禁；门禁决策由调用方做）。
#
# 设计原因（人工测试 612）：pipeline.py 改动触发 uvicorn --reload、
# MINUS_DEV_RESTART=1 强制重启，都会立刻杀掉 Creator 正在跑的流程。
# Agent 在修改代码/重启服务前必须先跑本脚本，RUNNING 时要先征得 Creator 同意。
#
# 局限：SDK 未暴露"运行中 session 列表"端点，只能用 TCP 连接数做启发式判断
# （SSE 流在执行期间保持 ESTABLISHED）。精确检测已作为需求提给 Platform。

BACKEND_PORT=""
if [ -f .minus/dev-ports.json ]; then
  BACKEND_PORT=$(node -e "const p=JSON.parse(require('fs').readFileSync('.minus/dev-ports.json','utf8')).backend;console.log(p>0?p:'')" 2>/dev/null)
fi

if [ -z "$BACKEND_PORT" ]; then
  echo "IDLE"
  exit 0
fi

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    COUNT=$(netstat -ano 2>/dev/null | grep -i 'ESTABLISHED' | grep -cE "[:.]${BACKEND_PORT}[[:space:]]")
    ;;
  *)
    COUNT=$(lsof -nP -iTCP:"$BACKEND_PORT" -sTCP:ESTABLISHED -t 2>/dev/null | sort -u | wc -l | tr -d ' ')
    ;;
esac

if [ "${COUNT:-0}" -gt 0 ]; then
  echo "RUNNING"
else
  echo "IDLE"
fi
exit 0
