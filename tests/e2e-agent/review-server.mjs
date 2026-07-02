// review-server.mjs — 回放报告的网页复核服务
// 在浏览器里直接对评判结果做人工裁定（选 pass/fail + 填理由 + 提交），
// 落盘逻辑与 feedback.mjs CLI 完全同源（recordOverride）：
// overrides.json 追加、judge 校准用例沉淀、报告即时更新。
//
// 用法:
//   node tests/e2e-agent/review-server.mjs <logDir> [port]
// 默认随机端口并自动打开浏览器（AUTO_OPEN=0 禁止自动打开）。只监听 127.0.0.1。

import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";

import { recordOverride } from "./feedback.mjs";
import { generateReport } from "./report-html.mjs";

// 清理门禁：证据链必须活到复核完成。
// "未复核" = 判定失败（✗）或证据核验未命中（⚠）、且没有任何人工裁定的项。
// 有裁定即视为已复核——无论裁定结论是推翻还是确认。
export function unresolvedItems(items = [], overrides = []) {
  const ruled = new Set(overrides.map((o) => o.id));
  const ids = [];
  for (const it of items) {
    if ((it.pass === false || it.verified === "miss") && !ruled.has(it.id)) ids.push(it.id);
  }
  return [...new Set(ids)];
}

async function cleanupProject(projectDir) {
  // 只删 E2E 临时项目（目录名硬约束），杜绝误删任何真实项目
  if (!/^e2e-agent-/.test(path.basename(projectDir))) {
    throw new Error(`拒绝清理：${projectDir} 不是 e2e-agent-* 临时项目`);
  }
  if (!fs.existsSync(projectDir)) return "（项目目录已不存在）";
  // 先杀干净再删：dev server（concurrently+vite+uvicorn）不死就 rm 会残留空壳目录
  const pidFile = path.join(projectDir, ".minus", "dev.pid");
  try {
    const pid = parseInt(fs.readFileSync(pidFile, "utf8").replace(/\D/g, ""), 10);
    if (pid) {
      try { process.kill(-pid); } catch { try { process.kill(pid); } catch {} }
    }
  } catch {}
  await new Promise((resolve) => {
    execFile("pkill", ["-f", projectDir], () => resolve());
  });
  // 等进程真正退出（最多 ~5s）
  for (let i = 0; i < 10; i++) {
    const alive = await new Promise((resolve) => {
      execFile("pgrep", ["-f", projectDir], (err) => resolve(!err));
    });
    if (!alive) break;
    await new Promise((r) => setTimeout(r, 500));
  }
  fs.rmSync(projectDir, { recursive: true, force: true });
  if (fs.existsSync(projectDir)) {
    throw new Error(`清理未完成，残留: ${projectDir}（可能仍有进程占用）`);
  }
  return "已删除";
}

export function createReviewServer(logDir, { calibrationDir } = {}) {
  return http.createServer((req, res) => {
    if (req.method === "GET" && (req.url === "/" || req.url === "/report.html")) {
      // 每次都重新渲染，裁定后刷新即见最新叠加
      try {
        const file = generateReport(logDir);
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end(fs.readFileSync(file));
      } catch (err) {
        res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
        res.end(`报告生成失败: ${err.message}`);
      }
      return;
    }
    if (req.method === "POST" && req.url === "/api/override") {
      // 按 Buffer 收集再整体解码：字符串拼接会在分片边界切坏多字节 UTF-8（中文理由必踩）
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        try {
          const { id, pass, reason } = JSON.parse(body || "{}");
          if (!id || typeof pass !== "boolean" || !String(reason || "").trim()) {
            throw new Error("缺少 id / pass / reason");
          }
          const { override, caseFile } = recordOverride(
            logDir, id, pass, String(reason).trim(),
            ...(calibrationDir ? [calibrationDir] : [])
          );
          console.log(
            `✓ [${id}] 人工${override.overturned ? "推翻" : "确认"} → ${pass ? "pass" : "fail"}` +
              (caseFile ? `（校准用例: ${path.basename(caseFile)}）` : "")
          );
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: true, overturned: override.overturned }));
        } catch (err) {
          // 400 也必须留痕，否则"提交失败"在服务端无迹可查
          console.log(`✗ POST /api/override 400: ${err.message}（body ${body.length}B: ${body.slice(0, 120)}）`);
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: false, error: err.message }));
        }
      });
      return;
    }
    if (req.method === "POST" && req.url === "/api/cleanup") {
      (async () => {
        try {
          const report = JSON.parse(fs.readFileSync(path.join(logDir, "report.json"), "utf8"));
          const overridesFile = path.join(logDir, "overrides.json");
          const overrides = fs.existsSync(overridesFile)
            ? JSON.parse(fs.readFileSync(overridesFile, "utf8"))
            : [];
          const unresolved = unresolvedItems(report.items, overrides);
          if (unresolved.length) {
            console.log(`✗ 清理被门禁拒绝：${unresolved.length} 项未复核（${unresolved.join("、")}）`);
            res.writeHead(409, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ ok: false, error: `还有 ${unresolved.length} 项未复核`, unresolved }));
            return;
          }
          if (!report.projectDir) {
            throw new Error("该 run 未记录项目目录（旧格式报告），请手动清理");
          }
          const result = await cleanupProject(report.projectDir);
          console.log(`✓ 复核完成，临时项目${result}: ${report.projectDir}`);
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: true, result }));
        } catch (err) {
          console.log(`✗ 清理失败: ${err.message}`);
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: false, error: err.message }));
        }
      })();
      return;
    }
    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("not found");
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const logDirArg = process.argv[2];
  if (!logDirArg) {
    console.error("用法: node review-server.mjs <logDir> [port]");
    process.exit(2);
  }
  const logDir = path.resolve(logDirArg);
  if (!fs.existsSync(path.join(logDir, "report.json"))) {
    console.error(`✗ ${logDir} 下没有 report.json（不是一个 run 日志目录？）`);
    process.exit(2);
  }
  const port = parseInt(process.argv[3] || "0", 10);
  const server = createReviewServer(logDir);
  server.listen(port, "127.0.0.1", () => {
    const url = `http://127.0.0.1:${server.address().port}/`;
    console.log(`→ 复核服务已启动: ${url}`);
    console.log(`  日志目录: ${logDir}`);
    console.log(`  在页面里展开"复核此判定"提交裁定，Ctrl+C 结束`);
    if (process.env.AUTO_OPEN !== "0" && process.platform === "darwin") {
      execFile("open", [url], () => {});
    }
  });
}
