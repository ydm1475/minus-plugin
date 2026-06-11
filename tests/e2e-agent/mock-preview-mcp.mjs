#!/usr/bin/env node
// mock-preview-mcp.mjs
// 模拟 Claude Desktop 的 Claude_Preview MCP server，供 e2e 在 claude -p 下
// 走通 Desktop 分支 A（preview_start → record-preview-port → 门禁）。
//
// 行为对齐真实 Desktop（schema 取证自 session-export 真实返回）：
// - preview_start {name} → 起 HTTP server（高位随机端口，模拟 autoPort），
//   返回 {serverId, port, name, reused}；同 name 再次调用幂等返回 reused:true
// - preview_list / preview_stop 可用
// - eval/snapshot/screenshot 等工具存在但返回明确的 "mock 不支持" 错误
//
// 跨轮存活：claude -p 每轮重新拉起本 MCP 进程，而真实 Desktop 的 preview 跨轮存活。
// 因此 HTTP server 以 detached 子进程运行（不随 MCP 进程退出而死），
// 状态记录在 cwd（= claude 的项目目录）下 .minus/mock-preview-state.json，
// 二次 start / list / stop 据此恢复。清理：driver/run.sh 按状态文件 kill。
//
// 边界：mock 子进程对 lsof 可见且 cwd 在项目内（真 Desktop 完全不可见）。
// 它验证的是 Agent 行为链（是否按 env-init.md 调 record-preview-port——
// 高位端口下门禁通过的唯一途径）；「PID 不可见」的降级路径由 shell 桩测试覆盖。
//
// 用法（claude -p）: --mcp-config '{"mcpServers":{"Claude_Preview":{"command":"node","args":["<本文件>"]}}}'

import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import crypto from "node:crypto";
import readline from "node:readline";
import { spawn } from "node:child_process";

const STATE_FILE = process.env.MOCK_PREVIEW_STATE
  || path.join(process.cwd(), ".minus", "mock-preview-state.json");

function readState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, "utf8")); } catch { return {}; }
}
function writeState(state) {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + "\n");
}
function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

function jsonText(obj, extra = "") {
  return { content: [{ type: "text", text: JSON.stringify(obj, null, 2) + (extra ? "\n" + extra : "") }] };
}
function errText(msg) {
  return { content: [{ type: "text", text: msg }], isError: true };
}

// 取一个空闲高位端口（监听 0 再关闭；e2e 场景下竞态可忽略）
function freePort() {
  return new Promise((resolve, reject) => {
    const srv = http.createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

async function waitReachable(port, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const ok = await new Promise((resolve) => {
      const req = http.get({ host: "127.0.0.1", port, timeout: 500 }, (res) => {
        res.resume(); resolve(true);
      });
      req.on("error", () => resolve(false));
      req.on("timeout", () => { req.destroy(); resolve(false); });
    });
    if (ok) return true;
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
}

async function startServer(name) {
  const state = readState();
  const entry = state[name];
  if (entry && pidAlive(entry.pid) && (await waitReachable(entry.port, 1000))) {
    return jsonText({ serverId: entry.serverId, port: entry.port, name, reused: true },
      `Server already running. The preview is available at http://localhost:${entry.port}.`);
  }
  const port = await freePort();
  // detached 子进程跑 HTTP server，存活期跨越本 MCP 进程（即跨 claude -p 轮次）
  const child = spawn(process.execPath, ["-e", `
    require("http").createServer((req, res) => {
      res.writeHead(200, {"Content-Type": "text/html"});
      res.end("<html><body>mock preview: ${name}</body></html>");
    }).listen(${port}, "127.0.0.1");
  `], { detached: true, stdio: "ignore", cwd: process.cwd() });
  child.unref();
  if (!(await waitReachable(port))) {
    try { process.kill(child.pid); } catch {}
    return errText(`Failed to start mock server on port ${port}`);
  }
  const serverId = crypto.randomUUID();
  state[name] = { serverId, port, pid: child.pid };
  writeState(state);
  return jsonText({ serverId, port, name, reused: false },
    `Server started successfully. Configured port 5173 was in use, so port ${port} was assigned instead (autoPort is enabled). The preview is available at http://localhost:${port}.`);
}

const TOOLS = [
  {
    name: "preview_start",
    description: "Start a dev server preview from .claude/launch.json by name. Returns the assigned port (autoPort).",
    inputSchema: { type: "object", properties: { name: { type: "string", description: "Server name from launch.json" } }, required: ["name"] },
    handler: (args) => startServer(args.name || "frontend"),
  },
  {
    name: "preview_list",
    description: "List running preview servers.",
    inputSchema: { type: "object", properties: {} },
    handler: () => {
      const state = readState();
      return jsonText(Object.entries(state)
        .filter(([, s]) => pidAlive(s.pid))
        .map(([name, s]) => ({ serverId: s.serverId, port: s.port, name })));
    },
  },
  {
    name: "preview_stop",
    description: "Stop a preview server by serverId.",
    inputSchema: { type: "object", properties: { serverId: { type: "string" } }, required: ["serverId"] },
    handler: (args) => {
      const state = readState();
      for (const [name, s] of Object.entries(state)) {
        if (s.serverId === args.serverId) {
          try { process.kill(s.pid); } catch {}
          delete state[name];
          writeState(state);
          return jsonText({ stopped: true, serverId: args.serverId });
        }
      }
      return errText(`No server with serverId ${args.serverId}`);
    },
  },
  // 真实 Desktop 还有这些工具；mock 声明它们以免 Agent 因工具缺失走偏，但调用时明确报不支持
  ...["preview_eval", "preview_snapshot", "preview_screenshot", "preview_console_logs", "preview_resize", "preview_click"].map((name) => ({
    name,
    description: "(mock) Not supported in e2e mock; do not rely on this tool.",
    inputSchema: { type: "object", properties: {} },
    handler: () => errText(`${name} is not supported by the e2e mock Claude_Preview server.`),
  })),
];

// ── 最小 MCP stdio 协议（JSON-RPC 2.0，行分隔） ──

const rl = readline.createInterface({ input: process.stdin });
function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

rl.on("line", async (line) => {
  line = line.trim();
  if (!line) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  const { id, method, params } = msg;
  if (method === "initialize") {
    send({ jsonrpc: "2.0", id, result: {
      protocolVersion: params?.protocolVersion || "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "Claude_Preview", version: "0.0.1-mock" },
    }});
  } else if (method === "tools/list") {
    send({ jsonrpc: "2.0", id, result: { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) } });
  } else if (method === "tools/call") {
    pending++;
    const tool = TOOLS.find((t) => t.name === params?.name);
    let result;
    try {
      result = tool ? await tool.handler(params?.arguments || {}) : errText(`Unknown tool: ${params?.name}`);
    } catch (e) {
      result = errText(`Tool failed: ${e.message}`);
    }
    send({ jsonrpc: "2.0", id, result });
    pending--;
    maybeExit();
  } else if (method === "ping") {
    send({ jsonrpc: "2.0", id, result: {} });
  } else if (id !== undefined) {
    // 未实现的 request 一律回空结果，避免客户端卡等待；notification 静默忽略
    send({ jsonrpc: "2.0", id, result: {} });
  }
});

// stdin 关闭后等 in-flight 的 tools/call 全部完成再退出（否则异步 handler 被中途杀掉）
let pending = 0;
let stdinClosed = false;
function maybeExit() {
  if (stdinClosed && pending === 0) process.exit(0);
}
process.stdin.on("end", () => { stdinClosed = true; maybeExit(); });
