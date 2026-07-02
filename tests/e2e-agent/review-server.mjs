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
      let body = "";
      req.on("data", (d) => (body += d));
      req.on("end", () => {
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
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: false, error: err.message }));
        }
      });
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
