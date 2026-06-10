#!/bin/sh
# check-project-state.sh
# 输出 Minus Skill 项目的本地初始化状态，避免 Agent 自行混用 PowerShell/Unix 语法。

if [ -f .minus/initialized ]; then
  echo "INITIALIZED=1"
else
  echo "INITIALIZED=0"
fi

if [ -d node_modules ]; then
  echo "NODE_MODULES=1"
else
  echo "NODE_MODULES=0"
fi

if [ -d .venv ]; then
  echo "VENV=1"
else
  echo "VENV=0"
fi
