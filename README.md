# Minus Creator Plugin

帮助 Creator 在 Claude Code 中开发和发布 Minus Skill 的插件。

## Skill 一览

| Skill             | 职责                                              | 典型触发语                     |
| ----------------- | ------------------------------------------------- | ------------------------------ |
| `minus`           | 总入口 + 状态路由（登录/建项目/环境/进度调度）    | "打开 Minus"、"继续"           |
| `minus-structure` | 结构设计：输入定义、步骤拆/增/删/重排、结果呈现页 | "重新拆步骤"、"改结果页"       |
| `minus-step`      | 单个 pipeline 步骤的四维度开发/修改               | "开发步骤 2"、"改第三步的界面" |
| `minus-auth`      | 账号会话：登录、登出、切换账号、查状态            | "退出登录"、"我登录了吗"       |
| `minus-publish`   | 发布到 Minus 平台                                 | "发布"、"上线"                 |
| `minus-diagnose`  | 错误诊断统一入口：体检分类（登录/项目/环境/dev server/Python 依赖）后自动修或路由 | "报错了"、"预览打不开"、"白屏" |

子 skill 直达时由 `scripts/gate.sh` 门禁兜底（未登录/无项目/环境未就绪会当场衔接补救流程）。

## 安装

```bash
# 1. 注册本地 marketplace（首次，路径指向仓库根，marketplace.json 在 .claude-plugin/ 下）
claude plugin marketplace add ~/minus-platform-develop/minus-plugin

# 源码改动后，先刷新 marketplace 再 update
claude plugin marketplace update minus-plugin

# 2. 安装插件
claude plugin install minus-creator@minus-plugin

# 临时加载（仅当次会话，不写入全局配置，适合调试）
claude --plugin-dir ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator

# 验证插件
claude plugin validate ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator

# 查看已安装插件
claude plugin list

# 更新插件（源码改动后）
claude plugin update minus-creator@minus-plugin

# 卸载
claude plugin uninstall minus-creator
# 或用脚本卸载（交互式，可选清理凭证和项目）
bash ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/uninstall.sh
```

> **Windows 首次安装报 EPERM？** `claude plugin install` 解压到 `cache/temp_local_*` 后 rename，撞上残留目录会失败。补救：`rm -rf ~/.claude/plugins/cache/temp_local_*` 后重装。已安装用户的升级场景由 SessionStart 自检（`scripts/post-install-check.sh`）自动清理残留，无需手动处理。

## 测试

```bash
# ── 单元测试 & 集成测试 ──
bash ~/minus-platform-develop/minus-plugin/tests/run-all.sh                      # 全部单元/集成测试（53+15+42 = 110 个）

bash ~/minus-platform-develop/minus-plugin/tests/shell-scripts.test.sh           # Shell 脚本单元测试（53 个）
node --test ~/minus-platform-develop/minus-plugin/tests/mcp-server.test.js       # MCP Server 单元测试（15 个）
node --test ~/minus-platform-develop/minus-plugin/tests/integration.test.js      # 集成测试 - mock API 完整流程（42 个）

# ── 环境矩阵测试（OS × Node 状态边界，全量在 GitHub Actions 跑）──
bash ~/minus-platform-develop/minus-plugin/tests/env-matrix/run.sh               # local scope：CI-only/不可屏蔽场景自动 skip
bash ~/minus-platform-develop/minus-plugin/tests/env-matrix/run.sh --only 03     # 只跑指定编号场景（调试）

# ── E2E 测试（真实调用 Claude API，需登录态）──
bash ~/minus-platform-develop/minus-plugin/tests/e2e-autostart.sh                # 自动启动：dev server 启动 + 预览地址输出
bash ~/minus-platform-develop/minus-plugin/tests/e2e-three-step.sh               # 两步法流程完整性
bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh                 # 开发全流程：两步法 + 四维度 + 结果呈现
bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh --phase 1       # 只测两步法（输入→步骤）
bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh --phase 2       # 只测逐节点四维度（数据→逻辑→输出→确认）
bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh --phase 3       # 只测结果呈现设计
E2E_KEEP=1 bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh     # 保留临时项目不删（调试用）

# ── E2E Agent 剧本测试（真实 Agent + LLM 模拟用户，token 消耗大，手动按需触发）──
bash ~/minus-platform-develop/minus-plugin/tests/e2e-agent/run.sh keyword-to-asin   # 跑指定剧本（scenarios/ 下的文件名）
E2E_SKIP_RUN=1 bash tests/e2e-agent/run.sh keyword-to-asin                          # 只测对话流程，跳过真实运行验证
E2E_KEEP=1 E2E_MAX_ROUNDS=80 E2E_AGENT_MODEL=opus bash tests/e2e-agent/run.sh ...   # 可覆盖的参数
E2E_DESKTOP=1 bash tests/e2e-agent/run.sh keyword-to-asin                           # Desktop 模式：mock Claude_Preview 验证分支 A
                                                                                    # （preview_start → record-preview-port → 门禁）行为链
                                                                                    # 真实 Desktop 冒烟见 References/Desktop Smoke Checklist.md
node --test ~/minus-platform-develop/minus-plugin/tests/e2e-agent/harness.test.mjs  # harness 自身单测（不消耗 token）
```

环境矩阵测试：在真实 Windows/macOS runner（`.github/workflows/env-matrix.yml`）上验证插件在各种 Node 环境（无 node / 老 node / Volta / nvm / PATH 错序 / 真实 Volta 自动安装 / `install.sh` 插件识别）下的安装与运行，零 API key。Node 状态用受控 PATH + 假 HOME 在 job 内构造（见 `tests/env-matrix/lib.sh` 头注释），本机跑 local scope 时破坏性场景自动 skip。

E2E Agent 剧本测试：用 `claude -p` 真实驱动 Creator Agent 走完"结构设计 → 逐节点四维度 → 真实运行"全流程，haiku 扮演用户按剧本口径应答。断言分两层：硬断言（H 系列，状态机/产物机械检查 + 逐节点真实执行 + 终验完整跑通）写在剧本 `expect` 段；行为规则（B 系列，两步法顺序、不跳维、最后一步不问维度 ④ 等）写在剧本 `transcript_rules` 段，由评判模型看 transcript 逐条判定。每轮对话实时打印（`[Agent]`/`[模拟用户]`），完整 transcript 与报告落盘在 `tests/e2e-agent/logs/`。新增测试场景 = 在 `tests/e2e-agent/scenarios/` 新增一个 YAML 剧本，不用写代码。

## 项目注册表

```bash
PM=~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/scripts/projects-manager.sh

bash $PM list                              # 列出所有 Skill 项目
bash $PM add "名称" "/路径"                  # 注册项目
bash $PM remove "/路径"                     # 移除项目
bash $PM find "名称"                        # 按名称查找路径
bash $PM touch "/路径"                      # 更新最后打开时间
```

## 开发辅助

```bash
LIB=~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/scripts

bash $LIB/project-detector.sh              # 检测当前目录类型
bash $LIB/detect-client.sh                 # 检测客户端类型（cli / desktop）
bash $LIB/context-manager.sh check         # 上下文计数检查（Skill 项目目录下）
bash $LIB/context-manager.sh reset         # 重置计数器
bash $LIB/update-progress.sh <init-design|design-done|append-steps|step-done|set-phase|touch|show>
                                           # progress.json 唯一写入入口（Skill 项目目录下）
bash $LIB/progress-check.sh                # 进度自愈：按硬产物收敛 progress.json（SessionStart/Stop hook 自动跑）

SKL=~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/skills/minus/scripts
bash $SKL/record-preview-port.sh <port>    # 记录 Claude Preview 返回的前端端口到 .minus/dev-ports.json
                                           # （Desktop 分支 A：Preview 托管进程对 lsof 不可见，门禁靠此识别）
bash $SKL/resume-env.sh <desktop|cli>      # 开发环境一键恢复：状态检查 + 后台起 dev server + 门禁 +
                                           # 进度摘要一次跑完，输出 KEY=VALUE 状态块供 agent 直接路由
                                           # （替代 env-init.md 旧版散步执行，开机链 20+ 次往返 → 1 次）
```

## 同步

```bash
# 改完源码后同步到 Claude Code 安装目录
bash ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/scripts/sync-plugin.sh
```

## 打包（可分发 zip）

```bash
# 重建 MCP bundle 并打包成可分发 zip（默认输出到 ~/Desktop）
bash ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/scripts/pack.sh

# 指定输出目录
bash ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/scripts/pack.sh /path/to/out
```

产物 `minus-creator-v{版本}.zip` 含 marketplace 根目录（`.claude-plugin/marketplace.json` + `minus-creator/`），
已内联 MCP 依赖、排除 `node_modules`。接收方解压后：`claude plugin marketplace add ./claude && claude plugin install minus-creator@minus-plugin`。

## 镜像源（国内加速）

环境初始化（`scripts/bootstrap-env.sh`）**默认走国内镜像源**，避免国内开发者拉包慢到超时：

- npm（`pnpm install`、`create-skill` 自身的全局安装）→ `https://registry.npmmirror.com`（阿里）
- PyPI（`uv pip install`）→ `https://pypi.tuna.tsinghua.edu.cn/simple`（清华）

首次安装通过 `export` 环境变量生效（不写工具全局配置）；镜像源偶发滞后（个别新包未同步）时，会自动回退官方源重试一次。

**后续升级依赖也走国内源**：bootstrap 还会在项目里落盘两个**带 minus 标记、已 gitignore**（不入库、不污染发布产物）的配置文件，这样之后手动 `pnpm add` / `pnpm update` / `uv pip install -U` / `uv add` 同样走镜像：

- `.npmrc` → `registry=<npm 源>`
- `uv.toml` → `[[index]]`（同时覆盖 `uv pip` 与 `uv add/sync`）

`MINUS_MIRROR=off` 时这两个托管文件会被自动移除；用户**自己写的** `.npmrc` / `uv.toml`（无 minus 标记）一律不动。

通过环境变量调整（均可选）：

```bash
MINUS_MIRROR=off                                  # 关闭镜像，全部走官方源（海外开发者）
MINUS_NPM_REGISTRY=https://your.registry          # 自定义 npm registry（覆盖默认 npmmirror）
MINUS_PYPI_INDEX=https://your/simple              # 自定义 PyPI index（覆盖默认清华）
```

> 已显式设置 `npm_config_registry` / `UV_DEFAULT_INDEX` 的用户一律被尊重，不会被覆盖。
> 注：Volta 的 Node 二进制（nodejs.org）与 uv 的 Python 解释器下载暂无干净的镜像 env，仍走官方源——这两处是已知剩余慢点。
