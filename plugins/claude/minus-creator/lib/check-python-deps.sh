#!/bin/bash
# check-python-deps.sh
# 检查 pipeline.py 引入的第三方 Python 包是否已声明在 pyproject.toml，
# 并用项目虚拟环境验证 pipeline 可导入。禁止用系统 python 代替项目 venv。

set -euo pipefail

if [ ! -f "pipeline.py" ]; then
  echo "错误：未找到 pipeline.py" >&2
  exit 1
fi

if [ ! -f "pyproject.toml" ]; then
  echo "错误：未找到 pyproject.toml" >&2
  exit 1
fi

PYTHON_BIN=".venv/bin/python"
if [ ! -x "$PYTHON_BIN" ]; then
  echo "错误：未找到项目虚拟环境 Python：$PYTHON_BIN" >&2
  echo "请先通过 /minus 准备开发环境，或运行 bootstrap-env.sh 创建 .venv。" >&2
  exit 1
fi

TMP_IMPORTS=$(mktemp)
TMP_DEPS=$(mktemp)
trap 'rm -f "$TMP_IMPORTS" "$TMP_DEPS"' EXIT

"$PYTHON_BIN" - <<'PY' > "$TMP_IMPORTS"
import ast
import sys

with open("pipeline.py", "r", encoding="utf-8") as f:
    tree = ast.parse(f.read())

imports = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            imports.add(alias.name.split(".", 1)[0])
    elif isinstance(node, ast.ImportFrom):
        if node.module and node.level == 0:
            imports.add(node.module.split(".", 1)[0])

for name in sorted(imports):
    print(name)
PY

"$PYTHON_BIN" - <<'PY' > "$TMP_DEPS"
import re

text = open("pyproject.toml", "r", encoding="utf-8").read()

match = re.search(r'(?ms)^\s*dependencies\s*=\s*\[(.*?)^\s*\]', text)
if not match:
    raise SystemExit(0)

for item in re.findall(r'["\']([^"\']+)["\']', match.group(1)):
    # PEP 508: name may be followed by version specs, extras, markers, or direct refs.
    name = re.split(r'\s|<|>|=|!|~|\[|@|;', item, 1)[0].strip().lower().replace("_", "-")
    if name:
        print(name)
PY

MISSING=()

while IFS= read -r import_name; do
  [ -n "$import_name" ] || continue

  case "$import_name" in
    # 项目本地模块
    pipeline|server)
      continue
      ;;
    # SDK / 模板已声明或由运行环境提供
    minus_ai_sdk)
      dep_name="minus-ai-sdk-python"
      ;;
    dotenv)
      dep_name="python-dotenv"
      ;;
    PIL)
      dep_name="pillow"
      ;;
    bs4)
      dep_name="beautifulsoup4"
      ;;
    yaml)
      dep_name="pyyaml"
      ;;
    sklearn)
      dep_name="scikit-learn"
      ;;
    cv2)
      dep_name="opencv-python"
      ;;
    *)
      # 标准库：能在当前解释器中解析且位于 stdlib/builtin 的模块不需要声明。
      if "$PYTHON_BIN" - "$import_name" <<'PY' >/dev/null 2>&1
import importlib.util
import sys
import sysconfig
from pathlib import Path

name = sys.argv[1]
spec = importlib.util.find_spec(name)
if spec is None:
    raise SystemExit(1)
if spec.origin in ("built-in", "frozen"):
    raise SystemExit(0)
origin = spec.origin or ""
stdlib = sysconfig.get_paths().get("stdlib", "")
if stdlib and Path(origin).resolve().is_relative_to(Path(stdlib).resolve()):
    raise SystemExit(0)
raise SystemExit(1)
PY
      then
        continue
      fi
      dep_name=$(echo "$import_name" | tr '_' '-' | tr '[:upper:]' '[:lower:]')
      ;;
  esac

  if ! grep -qx "$dep_name" "$TMP_DEPS"; then
    MISSING+=("$dep_name")
  fi
done < "$TMP_IMPORTS"

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "错误：pipeline.py 引入了未声明的 Python 依赖：" >&2
  printf '  - %s\n' "${MISSING[@]}" | sort -u >&2
  echo "" >&2
  echo "Agent 必须先把缺失依赖加入 pyproject.toml 的 [project].dependencies，然后运行：" >&2
  echo "  uv pip install -e ." >&2
  echo "完成后重新执行本检查，通过后再让 Creator 测试。" >&2
  echo "" >&2
  echo "禁止把这个修复交给 Creator 手动处理；禁止只对 .venv 临时安装某个包而不更新 pyproject.toml。" >&2
  exit 1
fi

IMPORT_OUTPUT=$("$PYTHON_BIN" -c "import pipeline" 2>&1) || {
  echo "错误：项目虚拟环境无法导入 pipeline.py：" >&2
  echo "$IMPORT_OUTPUT" >&2
  exit 1
}

echo "DEPENDENCIES_OK"
