#!/bin/sh
# gate.sh — 子 skill 直达入口的前置门禁（单源，被 minus-step / minus-structure / resume-env 调用）
# 输出：
#   GATE=ok
#   GATE=fail reason=NOT_LOGGED_IN|NO_PROJECT|ENV_NOT_READY|DEV_SERVER_DOWN
#   HINT=<给 Agent 转达/执行的中文提示>
# 检查顺序：登录 → 项目 → 环境 → dev server，命中第一个失败原因即返回。
#
# 用法: gate.sh [--checks login,project,env,devserver]
#   默认全部检查。--checks 可指定子集（逗号分隔），
#   例如 resume-env 只需 login,project（依赖和 dev server 自己有更细粒度的处理）。

VALID_CHECKS="login,project,env,devserver"
case "${1:-}" in
  --checks)  CHECKS="${2:?gate.sh: --checks requires a value}" ;;
  --checks=*) CHECKS="${1#--checks=}"
              [ -z "$CHECKS" ] && { echo "gate.sh: --checks requires a non-empty value" >&2; exit 2; } ;;
  "")        CHECKS=all ;;
  *)         echo "gate.sh: unknown argument '$1'" >&2; exit 2 ;;
esac
if [ "$CHECKS" != "all" ]; then
  for c in $(printf '%s' "$CHECKS" | tr ',' ' '); do
    case ",$VALID_CHECKS," in *,"$c",*) ;; *) echo "gate.sh: unknown check '$c'" >&2; exit 2 ;; esac
  done
fi
should_check() { [ "$CHECKS" = "all" ] || case ",$CHECKS," in *,"$1",*) return 0 ;; *) return 1 ;; esac; }

if should_check login; then
  CRED="$HOME/.minus/credentials.json"
  if [ ! -s "$CRED" ] || ! grep -q '"session_id"' "$CRED" 2>/dev/null; then
    echo "GATE=fail reason=NOT_LOGGED_IN"
    echo "HINT=尚未登录 Minus。请用 Skill tool 调用 minus-auth 完成登录，登录后继续当前任务。"
    exit 0
  fi
fi

if should_check project; then
  if [ ! -f .minus/skill.json ]; then
    echo "GATE=fail reason=NO_PROJECT"
    echo "HINT=当前目录不是 Minus 项目。请 Read ../minus/project-setup.md 引导选择或创建项目，完成后继续当前任务。"
    exit 0
  fi
fi

if should_check env; then
  if [ ! -d node_modules ] || [ ! -d .venv ]; then
    echo "GATE=fail reason=ENV_NOT_READY"
    echo "HINT=项目环境未就绪（依赖未安装或未初始化）。请 Read ../minus/env-init.md 完成环境初始化，完成后继续当前任务。"
    exit 0
  fi
fi

if should_check devserver; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CHECK_DEV_SH="${MINUS_CHECK_DEV_SH:-$SCRIPT_DIR/../skills/minus/scripts/check-dev-server.sh}"
  if ! "$CHECK_DEV_SH" >/dev/null 2>&1; then
    echo "GATE=fail reason=DEV_SERVER_DOWN"
    echo "HINT=Dev server 未运行。请 Read ../minus/env-init.md 完成环境恢复（会自动启动 dev server），完成后继续当前任务。"
    exit 0
  fi
fi

echo "GATE=ok"
