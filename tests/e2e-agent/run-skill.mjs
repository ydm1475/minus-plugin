// run-skill.mjs — 真实运行产出的 skill
// 职责：dev server 生命周期、平台 session 创建、SSE 驱动 pipeline（含 confirm 推进）。
//
// 平台侧（创建 session）走 ~/.minus/credentials.json 的 api_base + 会话 cookie；
// 容器侧（stream/confirm）走 .minus/dev-ports.json 的 backend 端口。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const STREAM_TIMEOUT_MS = 5 * 60_000;

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function log(msg) {
  console.log(`  → ${msg}`);
}

// ── dev server ──

export async function ensureDevServer(projectDir, logDir) {
  // 无头验证只需要 backend（uvicorn）；dev-ports.json 由前端 vite 插件写，
  // 前端起不来（如 pnpm 缺失）时退化为从 package.json dev 脚本解析端口探活。
  const backendPort = resolveBackendPort(projectDir);
  if (backendPort && (await portAlive(backendPort))) {
    return { ports: { backend: backendPort }, child: null };
  }
  log("启动 dev server（npm run dev）...");
  const out = fs.openSync(path.join(logDir, "dev-server.log"), "a");
  const child = spawn("npm", ["run", "dev"], {
    cwd: projectDir,
    detached: true,
    stdio: ["ignore", out, out],
  });
  child.unref();
  const deadline = Date.now() + 90_000;
  while (Date.now() < deadline) {
    await sleep(2000);
    const port = resolveBackendPort(projectDir);
    if (port && (await portAlive(port))) {
      log(`dev server 就绪：backend=${port}`);
      return { ports: { backend: port }, child };
    }
  }
  throw new Error(
    `dev server 90 秒内未就绪，日志见 ${path.join(logDir, "dev-server.log")}`
  );
}

function resolveBackendPort(projectDir) {
  const portsFile = path.join(projectDir, ".minus", "dev-ports.json");
  if (fs.existsSync(portsFile)) {
    const port = readJson(portsFile).backend;
    if (port) return port;
  }
  const pkgFile = path.join(projectDir, "package.json");
  if (fs.existsSync(pkgFile)) {
    const dev = readJson(pkgFile).scripts?.dev || "";
    const m = dev.match(/--port\s+(\d+)/);
    if (m) return parseInt(m[1], 10);
  }
  return null;
}

export function stopDevServer(handle) {
  if (handle?.child?.pid) {
    try {
      process.kill(-handle.child.pid, "SIGTERM");
    } catch {
      try { handle.child.kill("SIGTERM"); } catch {}
    }
  }
}

async function portAlive(port) {
  try {
    await fetch(`http://localhost:${port}/`, { signal: AbortSignal.timeout(3000) });
    return true;
  } catch (err) {
    // 404/500 也算活着；只有连接失败才算死
    return err.name !== "TypeError" && err.name !== "TimeoutError" && err.name !== "AbortError";
  }
}

// ── 平台 session ──

function loadCredentials() {
  const p = path.join(os.homedir(), ".minus", "credentials.json");
  if (!fs.existsSync(p)) {
    throw new Error(`未登录：${p} 不存在，请先在插件中完成登录（auth_dev_session）`);
  }
  return readJson(p);
}

async function refreshSession(creds) {
  if (!creds.api_key) return creds.session_id;
  const resp = await fetch(`${creds.api_base}/api/auth/dev-session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ apiKey: creds.api_key }),
    signal: AbortSignal.timeout(15_000),
  });
  const setCookie = resp.headers.get("set-cookie") || "";
  const m = setCookie.match(/MINUS_AI_SID=([^;]+)/);
  return m ? m[1] : creds.session_id;
}

export async function createSession(projectDir, entryParams) {
  const creds = loadCredentials();
  const sid = await refreshSession(creds);
  const skillJson = readJson(path.join(projectDir, ".minus", "skill.json"));
  // 契约（openapi-bundled.yaml）：创建 session 走版本化端点
  const resp = await fetch(
    `${creds.api_base}/api/skills/${skillJson.skillId}/versions/${encodeURIComponent(skillJson.version)}/sessions`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Cookie: `MINUS_AI_SID=${sid}`,
      },
      body: JSON.stringify({ entryParams }),
      signal: AbortSignal.timeout(15_000),
    }
  );
  if (!resp.ok) {
    throw new Error(`创建 session 失败（HTTP ${resp.status}）: ${await resp.text()}`);
  }
  const data = await resp.json();
  log(`session 已创建: ${data.id}`);
  return { sessionId: data.id, sid };
}

function skillApiKey(projectDir) {
  const envFile = path.join(projectDir, ".env.local");
  if (!fs.existsSync(envFile)) return null;
  const m = fs.readFileSync(envFile, "utf8").match(/^MINUS_AI_SKILL_API_KEY=(.+)$/m);
  return m ? m[1].trim() : null;
}

// ── entry params 解析 ──
// 入参键名由 Agent 生成代码时自定，从 pipeline.py 的 ctx.entry_params.get("X") 提取。
// 剧本 final_input 中：显式键按名匹配；`default` 值赋给第一个未匹配的键。

export function resolveEntryParams(projectDir, finalInput = {}) {
  const pipelineFile = path.join(projectDir, "pipeline.py");
  const code = fs.existsSync(pipelineFile) ? fs.readFileSync(pipelineFile, "utf8") : "";
  const keys = [...new Set([...code.matchAll(/ctx\.entry_params\.get\(["'](\w+)["']/g)].map((m) => m[1]))];
  const { default: primary, ...explicit } = finalInput;
  const params = {};
  for (const k of keys) {
    if (explicit[k] !== undefined) params[k] = explicit[k];
  }
  if (primary !== undefined) {
    const firstUnmatched = keys.find((k) => params[k] === undefined);
    if (firstUnmatched) params[firstUnmatched] = primary;
    else if (!keys.length) params.input = primary;
  }
  return { ...explicit, ...params };
}

// ── SSE 驱动 ──

// 打开 stream 读消息事件，直到谓词命中或流自然结束。
async function readStream(backendPort, sessionId, headers, untilFn, lastEventId) {
  const url = new URL(`http://localhost:${backendPort}/api/sessions/${sessionId}/pipeline/stream`);
  if (lastEventId) url.searchParams.set("lastEventId", lastEventId);
  const resp = await fetch(url, { headers, signal: AbortSignal.timeout(STREAM_TIMEOUT_MS) });
  if (!resp.ok) {
    throw new Error(`pipeline/stream HTTP ${resp.status}: ${await resp.text()}`);
  }
  const messages = [];
  let hit = null;
  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let idx;
      while ((idx = buf.indexOf("\n\n")) >= 0) {
        const chunk = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        const msg = parseSseChunk(chunk);
        if (msg) {
          messages.push(msg);
          if (untilFn(msg)) {
            hit = msg;
          }
        }
      }
      if (hit) break;
    }
  } finally {
    try { await reader.cancel(); } catch {}
  }
  return { messages, hit };
}

export function parseSseChunk(chunk) {
  let data = null;
  for (const line of chunk.split("\n")) {
    if (line.startsWith("data:")) {
      data = (data ?? "") + line.slice(5).trim();
    }
  }
  if (!data) return null;
  try {
    return JSON.parse(data);
  } catch {
    return null; // marker（snapshot_begin/end 等）
  }
}

// 从生成的前端 main.tsx 按源码顺序提取所有 confirmedKey。
// 契约（node-dev.md）只要求前后端 confirmedKey 一致、用 camelCase，不规定具体名字——
// Agent 自由命名（selectedRows / selectedAsins / ...）。剧本无法预知，故运行时从代码探测，
// 与 "$select:N" 不写死行数据同一哲学（项目原则 #6 系统化工程化，别在剧本里钉死实现细节）。
// 返回数组按 step 顺序（第 N 个 input_required step 对应第 N 个 confirmedKey）。
export function detectConfirmedKeys(projectDir) {
  try {
    const src = fs.readFileSync(path.join(projectDir, "frontend/src/main.tsx"), "utf8");
    return [...src.matchAll(/confirmedKey:\s*['"]([^'"]+)['"]/g)].map((m) => m[1]);
  } catch {
    return [];
  }
}

// 确认数据支持魔法值 "$select:N"：从 input_required payload 的第一个数组字段里取前 N 行。
// 真实用户就是在 widget 展示的候选行里勾选，写死数据反而和生成代码的行结构对不上。
// actualKey：从生成代码探测到的真实 confirmedKey；"$select:N" 条目按它落键（剧本里的占位 key 忽略），
// 这样 Agent 取任何名字都不会假阴性。非 $select 的字面字段仍按剧本原 key 透传。
export function buildConfirmData(confirmSpec, payload, actualKey) {
  const out = {};
  for (const [k, v] of Object.entries(confirmSpec || {})) {
    const m = typeof v === "string" && v.match(/^\$select:(\d+)$/);
    if (m) {
      const rows = firstArray(payload?.data);
      out[actualKey || k] = rows.slice(0, parseInt(m[1], 10));
    } else {
      out[k] = v;
    }
  }
  return out;
}

function firstArray(obj) {
  if (Array.isArray(obj)) return obj;
  for (const v of Object.values(obj || {})) {
    if (Array.isArray(v) && v.length) return v;
  }
  return [];
}

async function confirmStep(backendPort, sessionId, headers, stepNumber, data) {
  const resp = await fetch(
    `http://localhost:${backendPort}/api/sessions/${sessionId}/pipeline/confirm`,
    {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({ stepNumber, data }),
      signal: AbortSignal.timeout(15_000),
    }
  );
  if (!resp.ok) {
    throw new Error(`pipeline/confirm HTTP ${resp.status}: ${await resp.text()}`);
  }
  log(`已提交 step${stepNumber} 确认数据`);
}

// 驱动 pipeline 直到 targetStep 出结果（step_complete 或 step_input_required）。
// targetStep 为 null 时驱动到 pipeline_complete，途中所有 input_required 用 confirmData 推进。
export async function runPipeline(projectDir, logDir, entryParams, opts = {}) {
  const { targetStep = null, confirmData = {} } = opts;
  const server = await ensureDevServer(projectDir, logDir);
  const resolvedParams = resolveEntryParams(projectDir, entryParams);
  log(`entryParams: ${JSON.stringify(resolvedParams)}`);
  const { sessionId, sid } = await createSession(projectDir, resolvedParams);
  // 用户端创建的 session 落在 live 工作区；容器中间件缺省 dev 会反查 404
  const headers = { Cookie: `MINUS_AI_SID=${sid}`, "X-Workspace-Mode": "live" };
  const ska = skillApiKey(projectDir);
  if (ska) headers["X-Skill-Api-Key"] = ska;

  const backend = server.ports.backend;
  // 探测生成代码里的真实 confirmedKey（按 step 顺序），每推进一次 input_required 取下一个
  const confirmedKeys = detectConfirmedKeys(projectDir);
  let confirmIdx = 0;
  const all = [];
  let lastEventId = null;
  const isTerminal = (m) => {
    const t = m.messageType;
    const step = m.payload?.stepNumber;
    if (t === "pipeline_error") return true;
    if (targetStep !== null) {
      return (
        (t === "step_complete" || t === "step_input_required") && step === targetStep
      ) || t === "pipeline_complete";
    }
    return t === "pipeline_complete";
  };

  for (let round = 0; round < 20; round++) {
    const { messages, hit } = await readStream(backend, sessionId, headers, isTerminal, lastEventId);
    all.push(...messages);
    if (messages.length) lastEventId = messages[messages.length - 1].id;
    for (const m of messages) {
      if (m.messageType) log(`pipeline 事件: ${m.messageType}${m.payload?.stepNumber ? ` (step ${m.payload.stepNumber})` : ""}`);
    }
    fs.writeFileSync(
      path.join(logDir, `pipeline-${sessionId}.json`),
      JSON.stringify(all, null, 2)
    );
    if (hit) {
      if (hit.messageType === "pipeline_error") {
        throw new Error(`pipeline 执行出错: ${JSON.stringify(hit.payload).slice(0, 500)}`);
      }
      if (hit.messageType === "step_input_required" && targetStep === null) {
        // 终验：用剧本数据推进确认，继续流
        const step = hit.payload?.stepNumber;
        await confirmStep(backend, sessionId, headers, step, buildConfirmData(confirmData, hit.payload, confirmedKeys[confirmIdx++]));
        continue;
      }
      return { sessionId, messages: all, terminal: hit, server };
    }
    // 流结束但没命中终点：可能是 input_required 后流关闭，看最后一条
    const last = all[all.length - 1];
    if (last?.messageType === "step_input_required") {
      if (targetStep !== null && last.payload?.stepNumber === targetStep) {
        return { sessionId, messages: all, terminal: last, server };
      }
      await confirmStep(backend, sessionId, headers, last.payload?.stepNumber, buildConfirmData(confirmData, last.payload, confirmedKeys[confirmIdx++]));
      continue;
    }
    await sleep(1500);
  }
  throw new Error("pipeline 驱动超过 20 轮 stream 仍未到达终点");
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}
