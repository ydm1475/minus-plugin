# Minus Creator Plugin

帮助 Creator 在 Claude Code 中开发和发布 Minus Skill 的插件。

## 安装

```bash
# 1. 注册本地 marketplace（首次，路径指向 plugins/claude/ 目录）
claude plugin marketplace add ~/minus-platform-develop/minus-plugin/plugins/claude

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

## 测试

```bash
# ── 单元测试 & 集成测试 ──
bash ~/minus-platform-develop/minus-plugin/tests/run-all.sh                      # 全部单元/集成测试（53+15+42 = 110 个）

bash ~/minus-platform-develop/minus-plugin/tests/shell-scripts.test.sh           # Shell 脚本单元测试（53 个）
node --test ~/minus-platform-develop/minus-plugin/tests/mcp-server.test.js       # MCP Server 单元测试（15 个）
node --test ~/minus-platform-develop/minus-plugin/tests/integration.test.js      # 集成测试 - mock API 完整流程（42 个）

# ── E2E 测试（真实调用 Claude API，需登录态）──
bash ~/minus-platform-develop/minus-plugin/tests/e2e-autostart.sh                # 自动启动：dev server 启动 + 预览地址输出
bash ~/minus-platform-develop/minus-plugin/tests/e2e-three-step.sh               # 两步法流程完整性
bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh                 # 开发全流程：两步法 + 四维度 + 结果呈现
bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh --phase 1       # 只测两步法（输入→步骤）
bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh --phase 2       # 只测逐节点四维度（数据→逻辑→输出→确认）
bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh --phase 3       # 只测结果呈现设计
E2E_KEEP=1 bash ~/minus-platform-develop/minus-plugin/tests/e2e-dev-flow.sh     # 保留临时项目不删（调试用）
```

## 项目注册表

```bash
PM=~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/lib/projects-manager.sh

bash $PM list                              # 列出所有 Skill 项目
bash $PM add "名称" "/路径"                  # 注册项目
bash $PM remove "/路径"                     # 移除项目
bash $PM find "名称"                        # 按名称查找路径
bash $PM touch "/路径"                      # 更新最后打开时间
```

## 开发辅助

```bash
LIB=~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/lib

bash $LIB/project-detector.sh              # 检测当前目录类型
bash $LIB/detect-client.sh                 # 检测客户端类型（cli / desktop）
bash $LIB/context-manager.sh check         # 上下文计数检查（Skill 项目目录下）
bash $LIB/context-manager.sh reset         # 重置计数器
bash $LIB/progress-saver.sh               # 保存开发进度到 Memory（Skill 项目目录下）
bash $LIB/env-manager.sh "package.json"    # 环境变更检测
```

## 启动器

```bash
bash ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/bin/minus.sh   # 启动 Claude Code 并自动触发 /minus
```

## 同步

```bash
# 改完源码后同步到 Claude Code 安装目录
bash ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/lib/sync-plugin.sh
```

## 打包（可分发 zip）

```bash
# 重建 MCP bundle 并打包成可分发 zip（默认输出到 ~/Desktop）
bash ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/lib/pack.sh

# 指定输出目录
bash ~/minus-platform-develop/minus-plugin/plugins/claude/minus-creator/lib/pack.sh /path/to/out
```

产物 `minus-creator-v{版本}.zip` 含 marketplace 根目录（`.claude-plugin/marketplace.json` + `minus-creator/`），
已内联 MCP 依赖、排除 `node_modules`。接收方解压后：`claude plugin marketplace add ./claude && claude plugin install minus-creator@minus-plugin`。

## 镜像源（国内加速）

环境初始化（`lib/bootstrap-env.sh`）**默认走国内镜像源**，避免国内开发者拉包慢到超时：

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
