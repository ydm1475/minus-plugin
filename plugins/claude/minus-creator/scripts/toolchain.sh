#!/bin/sh
# toolchain.sh — 工具链版本的唯一真相源（single source of truth）
#
# 这里是全平台「唯一」写死版本号的地方。升级某个工具 = 改这里一个值，
# 全平台（bootstrap-env.sh / launch.sh / resolve-node.sh / create-skill 模板）生效。
# 勿在别处再写死版本号——那会重新散落，违反单源化原则。
#
# 为什么是「可 source 的 KEY=value」而不是 JSON：
# bootstrap-env.sh / launch.sh / resolve-node.sh 都可能在「Node 尚未就绪」时运行，
# 此刻没有任何 JSON 解析器可用。纯 shell 可 source 的格式零依赖、零解析器。
# node 侧消费者（create-skill）可用一行正则读同一文件。
#
# 命名为 .sh 是为了被 sync-plugin.sh 的 rsync 和打包流程自动带上。

# ── Node ───────────────────────────────────────────────
# NODE_TARGET：要安装/pin 的推荐版本（Volta 装这个）。
# NODE_FLOOR ：容忍「复用用户已有 node」的硬下限；低于它才会动手装。
#
# ⚠ NODE_FLOOR 不能低于 20：Node<20 的 autoSelectFamily 默认 false，macOS 上
#   localhost 先解析 IPv6 ::1、而本地后端只绑 IPv4 → dev 代理连 ::1 秒回 504。
#   故当前 floor 与 target 同为 24。将来 target 升到 25 时，floor 可滞后到 24
#   以平滑灰度，但永远 >=20。
# 注：minus-platform 的 create-skill（独立 npm 包）也持有同一 major（其 index.mjs 的
# NODE_MAJOR_FLOOR）。两仓各自写死同一 24——create-skill 发布时读不到本文件，故不做运行时
# 跨仓耦合；一致性由 tests/shell-scripts.test.sh 的 agreement 测试（双仓并列时）守住。
NODE_TARGET=24
NODE_FLOOR=24

# NODE_RUNTIME_FLOOR：跑「已打包好的 MCP bundle」和第三方 MCP 服务（如 mcp-remote）
# 所需的最低 node 主版本。mcp-remote 依赖 undici 的 File API（Node 20+），故下限 20。
NODE_RUNTIME_FLOOR=20

# ── pnpm ───────────────────────────────────────────────
# pin 死版本，不用 @latest：pnpm 次版本有破坏性策略变更（如 onlyBuiltDependencies
# → allowBuilds、忽略构建脚本时硬报错 ERR_PNPM_IGNORED_BUILDS）。只在验证过后才 bump。
PNPM_TARGET=11.4.0

# ── Python（uv venv 用）────────────────────────────────
PYTHON_TARGET=3.12
