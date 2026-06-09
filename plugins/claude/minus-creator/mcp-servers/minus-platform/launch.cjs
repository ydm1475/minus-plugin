#!/usr/bin/env node
// minus-platform MCP launcher（跨平台 node 引导器）
//
// 为什么需要它：客户端 spawn MCP 时用 launchd/login PATH，老 node 可能排在新 node 前
// 遮挡它（实测有人 /usr/local/bin/node 是 v13，压过 Volta 的 24）。直接 command:"node"
// 会被老 node 接管 → bundle 自检退出 → 工具不可用。
//
// 故 .mcp.json 用 command:"node" 跑本引导器（纯 JS，老 node 也能解析执行），引导器再
// 按已知位置主动探测一个 >=floor 的 node 来跑 bundle，不依赖 PATH 顺序。node 是 Win/Mac
// 唯一都保证有的运行时（Claude Code 本身是 node 应用）。
//
// 文案口径与 build.mjs banner 一致：以「建议 Node 24」为主，20 为技术下限（mcp-remote 需 File API）。

const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const DIR = __dirname;
const BUNDLE = path.join(DIR, "dist", "minus-platform.cjs");

// 版本下限/推荐口径单源于 lib/toolchain.sh（相对本脚本固定为 ../../lib，源码与缓存布局一致）。
// 用正则读 KEY=value（toolchain.sh 是可 source 的 shell，node 侧一行正则消费，与 build.mjs 同法）。
// 找不到则兜底——本脚本在客户端 spawn 时跑、环境未知，兜底保证不致崩。
function readToolchain() {
  const out = { MIN_MAJOR: 20, NODE_RECO: 24 };
  try {
    const txt = fs.readFileSync(path.join(DIR, "..", "..", "lib", "toolchain.sh"), "utf8");
    const floor = txt.match(/^\s*NODE_RUNTIME_FLOOR\s*=\s*(\d+)/m);
    const reco = txt.match(/^\s*NODE_TARGET\s*=\s*(\d+)/m);
    if (floor) out.MIN_MAJOR = parseInt(floor[1], 10);
    if (reco) out.NODE_RECO = parseInt(reco[1], 10);
  } catch { /* 用兜底 */ }
  return out;
}
const { MIN_MAJOR, NODE_RECO } = readToolchain();

// 取某个 node 可执行文件的主版本号（取不到则 null）
function nodeMajor(bin) {
  try {
    const r = spawnSync(bin, ["-p", "process.versions.node.split('.')[0]"], {
      encoding: "utf8",
      timeout: 5000,
    });
    if (r.status !== 0) return null;
    const m = parseInt(String(r.stdout).trim(), 10);
    return Number.isFinite(m) ? m : null;
  } catch {
    return null;
  }
}

// 取某个 glob 目录下按 mtime 最新的 node 二进制（Volta/nvm 的 image 目录）
function newestInDir(dir, exe) {
  try {
    const entries = fs
      .readdirSync(dir)
      .map((name) => path.join(dir, name))
      .filter((p) => {
        try { return fs.statSync(p).isDirectory(); } catch { return false; }
      })
      .map((p) => ({ p, m: safeMtime(p) }))
      .sort((a, b) => b.m - a.m);
    for (const { p } of entries) {
      const cand = exe(p);
      if (cand && fs.existsSync(cand)) return cand;
    }
  } catch { /* 目录不存在 */ }
  return null;
}
function safeMtime(p) {
  try { return fs.statSync(p).mtimeMs; } catch { return 0; }
}

function candidates() {
  const home = os.homedir();
  const list = [process.execPath]; // 跑本引导器的 node，够新就直接用
  if (process.platform === "win32") {
    const localApp = process.env.LOCALAPPDATA || path.join(home, "AppData", "Local");
    const programFiles = process.env.ProgramFiles || "C:\\Program Files";
    // Volta image 真身
    list.push(
      newestInDir(path.join(localApp, "Volta", "tools", "image", "node"), (p) => path.join(p, "node.exe"))
    );
    list.push(path.join(programFiles, "nodejs", "node.exe"));
  } else {
    // Volta image 真身（不依赖 VOLTA_HOME/shim，最稳）
    list.push(
      newestInDir(path.join(home, ".volta", "tools", "image", "node"), (p) => path.join(p, "bin", "node"))
    );
    list.push(path.join(home, ".volta", "bin", "node"));
    list.push(
      newestInDir(path.join(home, ".nvm", "versions", "node"), (p) => path.join(p, "bin", "node"))
    );
    list.push("/opt/homebrew/bin/node");
    list.push("/usr/local/bin/node");
  }
  return list.filter(Boolean);
}

let picked = null;
for (const c of candidates()) {
  let exists = false;
  try { exists = fs.existsSync(c); } catch { exists = false; }
  if (!exists) continue;
  const m = nodeMajor(c);
  if (m !== null && m >= MIN_MAJOR) {
    picked = c;
    break;
  }
}

if (!picked) {
  process.stderr.write(
    `[minus-platform] 建议使用 Node ${NODE_RECO}（最低 ${MIN_MAJOR}）。未在常见位置找到符合要求的 node，请安装 Node ${NODE_RECO}（推荐 https://volta.sh）后重启 Claude Code。\n`
  );
  process.exit(1);
}

// 接管：JSON-RPC over stdio 直通，透传退出码
const child = spawnSync(picked, [BUNDLE], { stdio: "inherit" });
process.exit(child.status === null ? 1 : child.status);
