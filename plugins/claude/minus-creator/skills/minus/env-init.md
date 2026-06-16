# 环境初始化与 Dev Server

**每次进入有项目的开发环境都执行以下步骤。** 确定性步骤已全部下沉到 `resume-env.sh` 一次执行——禁止散步重做它内部的事（check-project-state / start-dev / detect-preview-port / check-dev-server / 读 progress.json 都已包含）。

## 1. 一键恢复环境

```bash
minus-lib resume-env
```
不需要传分支参数——脚本自动通过 `CLAUDE_CODE_ENTRYPOINT` 判断 Desktop/CLI。调用时给 `Bash` 传 `timeout: 120000`。按输出处理：

**`NEED_BOOTSTRAP=1`** → 先原样告诉 Creator「正在准备开发环境，首次安装依赖可能需要几分钟，请稍候」，再前台执行（`timeout: 600000`）：
```bash
minus-lib bootstrap-env
```
读取最后一行 `BOOTSTRAP_RESULT`：
- `ok` → 重跑 `minus-lib resume-env` 继续。
- `failed reason=NO_NODE` / `NO_NPM` / `RESTART_NEEDED` → 把脚本输出里那条说明（含手动命令/重启提示）原样转达给 Creator，**停在这里等用户处理后重跑 /minus**，不要自己试错装环境。
- 其他 `failed reason=...` → 同样原样转达脚本给的手动命令，停下。

⛔ 环境安装的所有逻辑以 `bootstrap-env.sh` 为准，**不要**内联 `pnpm install` / `uv venv` / `corepack` 等命令。

**`ENV=failed`** → 把 `FAIL_REASON` 和 `LOG:` 行作为线索自行修复（对 Creator 只说"我来修"），修复后重跑 resume-env。

**`ENV=ready`** → 按分支收尾：

### 分支 desktop（输出含 `NEED_PREVIEW_START=1`）

1. 调用 `mcp__Claude_Preview__preview_start({"name": "frontend"})` — 右侧面板启动前端并预览
2. 从返回结果中提取实际端口（`port` 字段）。`autoPort: true` 时实际端口可能与 launch.json 配置的 5173 不同，**必须以返回值为准**。拿到端口后**立即执行**（Preview 托管的进程对端口检测不可见，不记录则后续门禁必失败）：
   ```bash
   minus-lib record-preview-port <port>
   ```
   返回结果没有端口才用兜底：`AUTO_OPEN=0 minus-lib detect-preview-port`
3. 按端口输出（不改写）：
   - 拿到端口 →「预览已在右侧面板打开（http://localhost:{port}）。」
   - 没拿到端口 →「预览已在右侧面板打开。」

### 分支 cli（输出含 `PREVIEW_PORT=` 和 `CLIENT=`）

预览已由脚本自动打开。按 `CLIENT` 选文案**原样输出**（不改写、不合并两版）：
- `CLIENT=cli` →「预览地址：http://localhost:{port} —— 已自动在浏览器打开。」
- `CLIENT=desktop` →「预览已在右侧面板打开（http://localhost:{port}）。」

## 2. 进入状态路由

resume-env 的输出已带路由所需全部字段（`INITIALIZED=` / `PHASE=` / `DESIGN_STAGE=` / `CURRENT_STEP=` / `STEPS_TOTAL=` / `STEPS_DONE=` / `STEP_STATUS=` / `RESULT_DESIGN=` / `TEST_CONFIRMED=`）。Read [dev-phase.md](dev-phase.md)，直接用这些字段分发，**不要再自己 Read progress.json / skill.json 重复判断**（skill.json 只在需要 skillId/version 传给 MCP tool 时读）。

## 3. dev server 异常处理

如果用户反馈预览打不开或 dev server 有问题：
- 执行下面的固定重启命令（用 `Bash` 的 `run_in_background` 后台运行；`MINUS_DEV_RESTART=1` 会先清掉归属本项目的残留进程和旧端口记录，再强制重启）：
  ```bash
  minus-lib resume-env restart
  ```
- 用户没问就不要管——不要主动 kill 进程、不要手动启动 uvicorn/vite、不要手动分配端口。重启时的旧进程清理由 start-dev 脚本硬编码处理（带归属校验），Agent 自己永远不许 kill

## 4. 版本自动恢复后重启

当 `skill_update` 返回内容包含 `[VERSION_CHANGED]` 时，说明本地版本已过期并被自动升级，dev server 的路由已失效。必须立即：
- 执行上面的固定重启命令重启 dev server
- 重新检测预览端口：`minus-lib detect-preview-port`
- 然后继续原来的操作，不需要告知 Creator 版本发生了变化

## 5. dev server 门禁（硬性，不可跳过）

`resume-env` 的 `ENV=ready` 已包含门禁校验。若跳过了 resume-env 或中途重启过 dev server，进入结构设计/继续开发前必须重跑：
```bash
minus-lib check-dev-server
```
- `GATE_PASSED` → 继续。
- `GATE_FAILED`（退出码 1）→ ⛔ 禁止进入结构设计/继续开发。回到步骤 2 重跑 resume-env，通过后才能继续。
