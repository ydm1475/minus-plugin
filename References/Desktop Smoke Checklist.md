# Desktop 人工冒烟清单（约 5 分钟）

自动化测不到的最后一层：Claude Desktop 真实运行时（右侧面板渲染、Preview 进程托管方式、权限弹窗）。
发版前或改动 env-init.md 分支 A / detect-preview-port.sh / record-preview-port.sh 后过一遍。

模拟测试覆盖边界（为什么需要这张清单）：
- `E2E_DESKTOP=1` 剧本验证的是 **Agent 行为链**（preview_start → record-preview-port → 门禁），
  mock 的 server 进程对 lsof 可见且 cwd 在项目内——与真实 Desktop 不同
- 「Preview 进程对 lsof 不可见」的降级路径由 `tests/shell-scripts.test.sh` 的桩测试覆盖
- 真实 Desktop 的进程托管形态只能在 Desktop 里观察

## 步骤

环境：Claude Desktop（不是 CLI/终端），已安装 minus-creator 插件，已登录 Minus。

1. **进入项目跑 /minus**
   - [ ] 打开一个已有 Minus Skill 项目，输入 `/minus`
   - [ ] 环境初始化走完，无报错停顿

2. **预览面板**
   - [ ] 右侧面板自动弹出预览（分支 A：`preview_start`）
   - [ ] Agent 播报文案是「预览已在右侧面板打开（http://localhost:{port}）」，端口与面板实际地址一致

3. **端口记录（本次修复的核心链路）**
   - [ ] 项目下 `.minus/dev-ports.json` 的 `frontend` 字段 = preview 实际端口（尤其当端口不是 5173 时）
   - [ ] 终端跑 `minus-lib check-dev-server` → `GATE_PASSED` + 正确端口

4. **进程形态取证（为放宽策略积累证据）**
   - [ ] 终端跑 `lsof -iTCP:<preview端口> -sTCP:LISTEN` ——记录结果：
     - 完全不可见 → 与现有降级策略假设一致 ✓
     - 可见但 cwd 不在项目内 → 记录 cwd 实际值，回报到 plugin 仓库（这是调整 trusted 策略的证据门槛）

5. **断线重连**
   - [ ] 关掉会话重新进入，`/minus` 后预览能恢复（reused 或重新 start），门禁仍通过

任何一项失败：导出会话 zip + `.minus/dev-ports.json` 内容，按 CONTRACT.md 评估流程定位归属。
