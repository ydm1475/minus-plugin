# Minus Creator Plugin

帮助 Creator 在 Claude Code 中开发和发布 Minus Skill 的插件。

## 安装

```bash
# 1. 注册本地 marketplace（首次，路径指向 plugins/ 目录）
claude plugin marketplace add ~/minus-plugin/plugins

# 2. 安装插件
claude plugin install minus-creator@minus-plugin

# 临时加载（仅当次会话，不写入全局配置，适合调试）
claude --plugin-dir ~/minus-plugin/plugins/claude/minus-creator

# 验证插件
claude plugin validate ~/minus-plugin/plugins/claude/minus-creator

# 查看已安装插件
claude plugin list

# 更新插件（源码改动后）
claude plugin update minus-creator@minus-plugin

# 卸载
claude plugin uninstall minus-creator
# 或用脚本卸载（交互式，可选清理凭证和项目）
bash ~/minus-plugin/plugins/claude/minus-creator/lib/uninstall.sh
```

## 测试

```bash
# ── 单元测试 & 集成测试 ──
bash ~/minus-plugin/tests/run-all.sh                      # 全部单元/集成测试（53+15+42 = 110 个）

bash ~/minus-plugin/tests/shell-scripts.test.sh           # Shell 脚本单元测试（53 个）
node --test ~/minus-plugin/tests/mcp-server.test.js       # MCP Server 单元测试（15 个）
node --test ~/minus-plugin/tests/integration.test.js      # 集成测试 - mock API 完整流程（42 个）

# ── E2E 测试（真实调用 Claude API，需登录态）──
bash ~/minus-plugin/tests/e2e-autostart.sh                # 自动启动：dev server 启动 + 预览地址输出
bash ~/minus-plugin/tests/e2e-three-step.sh               # 三步法流程完整性
bash ~/minus-plugin/tests/e2e-dev-flow.sh                 # 开发全流程：三步法 + 四维度 + 结果呈现
bash ~/minus-plugin/tests/e2e-dev-flow.sh --phase 1       # 只测三步法（输入→步骤→输出）
bash ~/minus-plugin/tests/e2e-dev-flow.sh --phase 2       # 只测逐节点四维度（数据→逻辑→输出→确认）
bash ~/minus-plugin/tests/e2e-dev-flow.sh --phase 3       # 只测结果呈现设计
E2E_KEEP=1 bash ~/minus-plugin/tests/e2e-dev-flow.sh     # 保留临时项目不删（调试用）
```

## 项目注册表

```bash
PM=~/minus-plugin/plugins/claude/minus-creator/lib/projects-manager.sh

bash $PM list                              # 列出所有 Skill 项目
bash $PM add "名称" "/路径"                  # 注册项目
bash $PM remove "/路径"                     # 移除项目
bash $PM find "名称"                        # 按名称查找路径
bash $PM touch "/路径"                      # 更新最后打开时间
```

## 开发辅助

```bash
LIB=~/minus-plugin/plugins/claude/minus-creator/lib

bash $LIB/project-detector.sh              # 检测当前目录类型
bash $LIB/detect-client.sh                 # 检测客户端类型（cli / desktop）
bash $LIB/context-manager.sh check         # 上下文计数检查（Skill 项目目录下）
bash $LIB/context-manager.sh reset         # 重置计数器
bash $LIB/progress-saver.sh               # 保存开发进度到 Memory（Skill 项目目录下）
bash $LIB/env-manager.sh "package.json"    # 环境变更检测
```

## 启动器

```bash
bash ~/minus-plugin/plugins/claude/minus-creator/bin/minus.sh   # 启动 Claude Code 并自动触发 /minus
```

## 同步

```bash
# 改完源码后同步到 Claude Code 安装目录
bash ~/minus-plugin/plugins/claude/minus-creator/lib/sync-plugin.sh
```
