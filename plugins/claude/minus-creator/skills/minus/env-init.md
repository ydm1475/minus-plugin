# 环境初始化与 Dev Server

**每次进入有项目的开发环境都执行以下步骤：**

## 1. 准备开发环境（依赖工具 + 项目依赖）

先用脚本读取本地状态，禁止自己写 `Test-Path` / `test -f` 等内联检查：
```bash
PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/check-project-state.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
bash "$PLUGIN_ROOT/lib/check-project-state.sh"
```
输出固定为 `INITIALIZED=0|1`、`NODE_MODULES=0|1`、`VENV=0|1`。

若 `node_modules` 或 `.venv` 任一缺失（需要安装）：**先原样告诉 Creator**「正在准备开发环境，首次安装依赖可能需要几分钟，请稍候」，**再**执行 bootstrap 脚本（前台、单条命令、给足超时）：
```bash
PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/bootstrap-env.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
bash "$PLUGIN_ROOT/lib/bootstrap-env.sh"
```
调用时给 `Bash` 传 `timeout: 600000`。

读取脚本最后一行 `BOOTSTRAP_RESULT`：
- `ok` → 继续后续步骤。
- `failed reason=NO_NODE` / `reason=NO_NPM` / `reason=RESTART_NEEDED` → 把脚本输出里那条说明（含手动命令/重启提示）原样转达给 Creator，**停在这里等用户处理后重跑 /minus**，不要自己试错装环境。
- 其他 `failed reason=...` → 同样把脚本给的手动命令原样转达，停下。

⛔ 环境安装的所有逻辑以 `bootstrap-env.sh` 为准。**不要**在这里内联 `pnpm install` / `uv venv` / `corepack` / `npm i -g pnpm` 等命令——脚本已处理工具探测、Node 版本适配（不走 corepack）和跨平台安装。

## 2. 探测预览能力

在启动 dev server 之前，判断客户端类型（`CLAUDE_CODE_ENTRYPOINT` 环境变量：claude-desktop/vscode/jetbrains 为 Desktop，其余为 CLI）。
如果是 Desktop，调用 `ToolSearch("preview")` 搜索 `mcp__Claude_Preview__preview_start`。
记住探测结果，后续步骤根据结果分支。

## 3. 启动 dev server + 打开预览

### 分支 A：Desktop + Claude_Preview 可用

1. 后台启动后端（用 `Bash` 的 `run_in_background`）。启动逻辑已下沉到 `start-dev.sh`：
   ```bash
   PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/start-dev.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
   bash "$PLUGIN_ROOT/lib/start-dev.sh" backend
   ```
2. 生成 `.claude/launch.json`（幂等，已存在则跳过）：
   ```bash
   PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/generate-launch-json.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
   bash "$PLUGIN_ROOT/lib/generate-launch-json.sh"
   ```
3. 调用 `mcp__Claude_Preview__preview_start({"name": "frontend"})` — 右侧面板启动前端并预览
4. 从 `preview_start` 的返回结果中提取实际端口（`port` 字段）。`autoPort: true` 时实际端口可能与 launch.json 配置的 5173 不同，**必须以返回值为准**。如果返回结果中没有端口，才用 `detect-preview-port.sh` 兜底：
   ```bash
   PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/detect-preview-port.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
   PREVIEW_PORT=$(AUTO_OPEN=0 bash "$PLUGIN_ROOT/lib/detect-preview-port.sh" 2>/dev/null | head -1)
   echo "PREVIEW_PORT=${PREVIEW_PORT}"
   ```
5. 按端口输出（不改写）：
   - 拿到端口 →「预览已在右侧面板打开（http://localhost:{port}）。」
   - 没拿到端口 →「预览已在右侧面板打开。」

### 分支 B：CLI 或 Claude_Preview 不可用

1. 后台启动前后端（用 `Bash` 的 `run_in_background`）。启动逻辑已下沉到 `start-dev.sh`：
   ```bash
   PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/start-dev.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
   bash "$PLUGIN_ROOT/lib/start-dev.sh" full
   ```
2. 检测前端预览端口：
   ```bash
   PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/detect-preview-port.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
   DETECT_OUT=$(bash "$PLUGIN_ROOT/lib/detect-preview-port.sh" 2>/dev/null)
   PREVIEW_PORT=$(printf '%s\n' "$DETECT_OUT" | head -1)
   CLIENT=$(printf '%s\n' "$DETECT_OUT" | grep '^CLIENT=' | head -1 | cut -d= -f2)
   if [ -n "$PREVIEW_PORT" ] && [ "$PREVIEW_PORT" != "DETECT_FAILED" ]; then
     echo "PREVIEW_URL=http://localhost:${PREVIEW_PORT}"
     echo "CLIENT=${CLIENT:-cli}"
   else
     echo "PREVIEW_DETECT_FAILED"
   fi
   ```
   `detect-preview-port.sh` 会自动等待端口就绪（最多 15s）。**检测成功后脚本会自动打开预览**（CLI 打开浏览器，Desktop 只输出 URL），无需额外调用。
3. 按上面输出的 `CLIENT` 选对应文案**原样输出**（不改写、不合并两版、不要自己描述预览在哪）：
   - `CLIENT=cli` →「预览地址：http://localhost:{port} —— 已自动在浏览器打开。」
   - `CLIENT=desktop` →「预览已在右侧面板打开（http://localhost:{port}）。」

   端口检测失败（`PREVIEW_DETECT_FAILED`）时，让 Creator 自己从终端日志里找 vite 输出的地址。

## 4. dev server 异常处理

如果用户反馈预览打不开或 dev server 有问题：
- 执行下面的固定重启脚本（先清掉旧端口文件，再用 `Bash` 的 `run_in_background` 后台重启）：
  ```bash
  rm -f .minus/dev-ports.json
  PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/start-dev.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
  bash "$PLUGIN_ROOT/lib/start-dev.sh" full
  ```
- 用户没问就不要管——不要主动 kill 进程、不要手动启动 uvicorn/vite、不要手动分配端口

## 5. 版本自动恢复后重启

当 `skill_update` 返回内容包含 `[VERSION_CHANGED]` 时，说明本地版本已过期并被自动升级，dev server 的路由已失效。必须立即：
- 执行上面的固定重启脚本重启前后端 dev server
- 重新检测预览端口（步骤 3 分支 B）
- 然后继续原来的操作，不需要告知 Creator 版本发生了变化

## 6. dev server 门禁（硬性，不可跳过）

在进入「首次进入」或「非首次进入」之前，必须执行门禁脚本确认 dev server 已在运行且属于本项目：
```bash
PLUGIN_ROOT=$(find ~/.claude/plugins/cache -path "*/minus-creator/*/lib/check-dev-server.sh" -exec dirname {} \; 2>/dev/null | head -1 | xargs dirname)
bash "$PLUGIN_ROOT/lib/check-dev-server.sh"
```
- 输出 `GATE_PASSED` → 继续进入下面的「状态路由」。
- 输出 `GATE_FAILED`（退出码 1）→ 说明步骤 3 的启动被跳过或失败。⛔ 禁止进入结构设计/继续开发。必须回到步骤 2、3 重新探测并启动 dev server，启动后重跑本门禁，通过后才能继续。

## 7. 进入状态路由

门禁通过后，Read [dev-phase.md](dev-phase.md) 按其中指令执行。
