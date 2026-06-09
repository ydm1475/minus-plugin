#!/usr/bin/env node
// launch-mcp-remote.cjs — 跨平台 mcp-remote 引导器
//
// 与 launch.cjs 相同模式：用低版本 node 跑本引导器，探测 >=NODE_RUNTIME_FLOOR 的
// node 再用它的 npx 启动 mcp-remote。

const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

// 版本下限单源于 toolchain.sh
function readFloor() {
  try {
    const txt = fs.readFileSync(path.join(__dirname, "toolchain.sh"), "utf8");
    const m = txt.match(/^\s*NODE_RUNTIME_FLOOR\s*=\s*(\d+)/m);
    if (m) return parseInt(m[1], 10);
  } catch {}
  return 20;
}
const MIN_MAJOR = readFloor();

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
  } catch {}
  return null;
}

function safeMtime(p) {
  try { return fs.statSync(p).mtimeMs; } catch { return 0; }
}

function candidates() {
  const home = os.homedir();
  const list = [process.execPath];
  if (process.platform === "win32") {
    const localApp = process.env.LOCALAPPDATA || path.join(home, "AppData", "Local");
    const programFiles = process.env.ProgramFiles || "C:\\Program Files";
    list.push(
      newestInDir(path.join(localApp, "Volta", "tools", "image", "node"), (p) => path.join(p, "node.exe"))
    );
    list.push(path.join(programFiles, "nodejs", "node.exe"));
  } else {
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
  try { if (!fs.existsSync(c)) continue; } catch { continue; }
  const m = nodeMajor(c);
  if (m !== null && m >= MIN_MAJOR) {
    picked = c;
    break;
  }
}

if (!picked) {
  process.stderr.write(
    `[mcp-remote] 需要 Node >= ${MIN_MAJOR}（mcp-remote 依赖 File API）。` +
    `请安装 Node 24（推荐 https://volta.sh）后重启 Claude Code。\n`
  );
  process.exit(1);
}

// 将找到的 node 目录前置到 PATH，确保 npx 及其子进程都用同一版本
const pickedDir = path.dirname(picked);
const env = { ...process.env, PATH: pickedDir + path.delimiter + (process.env.PATH || "") };
const npxBin = path.join(pickedDir, process.platform === "win32" ? "npx.cmd" : "npx");
const child = spawn(picked, [npxBin, ...process.argv.slice(2)], { stdio: "inherit", env });
child.on("exit", (code) => process.exit(code ?? 1));
