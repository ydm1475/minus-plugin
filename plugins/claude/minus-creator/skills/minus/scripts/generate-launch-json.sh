#!/bin/bash
# generate-launch-json.sh
# 生成 .claude/launch.json（幂等，已存在则跳过）
# runtimeExecutable 必须写 pnpm 的绝对路径，不能写裸 "pnpm"

set -euo pipefail

mkdir -p .claude
if [ -f .claude/launch.json ]; then
  echo "ALREADY_EXISTS"
  exit 0
fi

PNPM_BIN=""
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    _VOLTA_LOCAL="$(echo "${LOCALAPPDATA:-${USERPROFILE:-$HOME}/AppData/Local}" | tr '\\' '/')/Volta"
    _VOLTA_PF="$(echo "${ProgramFiles:-${PROGRAMFILES:-C:/Program Files}}" | tr '\\' '/')/Volta"
    if [ -x "$_VOLTA_LOCAL/bin/pnpm" ]; then
      PNPM_BIN="$_VOLTA_LOCAL/bin/pnpm"
    elif [ -x "$_VOLTA_PF/pnpm.exe" ]; then
      PNPM_BIN="$_VOLTA_PF/pnpm.exe"
    elif [ -x "$_VOLTA_PF/pnpm" ]; then
      PNPM_BIN="$_VOLTA_PF/pnpm"
    fi
    if [ -n "$PNPM_BIN" ]; then
      case "$PNPM_BIN" in
        /[a-zA-Z]/*) PNPM_BIN="$(echo "$PNPM_BIN" | sed 's#^/\(.\)#\U\1:#')" ;;
      esac
      case "$PNPM_BIN" in *.exe|*.cmd) ;; *) PNPM_BIN="${PNPM_BIN}.exe" ;; esac
    fi
    ;;
  *)
    if [ -x "${VOLTA_HOME:-$HOME/.volta}/bin/pnpm" ]; then
      PNPM_BIN="${VOLTA_HOME:-$HOME/.volta}/bin/pnpm"
    fi
    ;;
esac

if [ -z "$PNPM_BIN" ]; then
  if command -v pnpm >/dev/null 2>&1; then
    PNPM_BIN="$(command -v pnpm)"
    case "$(uname -s 2>/dev/null)" in
      MINGW*|MSYS*|CYGWIN*)
        case "$PNPM_BIN" in
          /[a-zA-Z]/*) PNPM_BIN="$(echo "$PNPM_BIN" | sed 's#^/\(.\)#\U\1:#')" ;;
        esac
        case "$PNPM_BIN" in *.exe|*.cmd) ;; *) PNPM_BIN="${PNPM_BIN}.exe" ;; esac
        ;;
    esac
  else
    PNPM_BIN="pnpm"
  fi
fi

cat > .claude/launch.json <<EOF
{
  "version": "0.0.1",
  "configurations": [
    {
      "name": "frontend",
      "runtimeExecutable": "${PNPM_BIN}",
      "runtimeArgs": ["--filter", "./frontend", "exec", "vite"],
      "env": { "VOLTA_FEATURE_PNPM": "1" },
      "port": 5173,
      "autoPort": true
    }
  ]
}
EOF

echo "CREATED"
