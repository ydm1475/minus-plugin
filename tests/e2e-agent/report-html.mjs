// report-html.mjs — 单文件对话回放报告
// 左侧完整对话（带轮次号气泡），右侧全部断言/评判结果；
// 点击带轮次的评判项直接跳转并高亮它引用的那轮对话，证据核验状态用角标标出。
//
// driver.mjs 每次 run 结束自动生成 report.html；历史日志可手动补生成：
//   node tests/e2e-agent/report-html.mjs <logDir>
// 读 report.json + transcript.json（旧日志没有 transcript.json 时回退解析 transcript.md）。

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

const VERIFIED_BADGE = {
  round: ["ok", "✓ 证据已核验：逐字命中所标轮次"],
  transcript: ["warn", "△ 证据命中对话原文，但不在所标轮次"],
  miss: ["bad", "⚠ 证据未命中对话原文，需人工复核"],
};

// 语义评判类判定才开放网页复核（B/C 系列或带证据核验字段的）；
// 硬断言（H/R/D 系列）错了是断言脚本的 bug，该改 assert.mjs，不走人工裁定通道。
// 另一个原因：硬断言 ID 会在多个步骤间重复（如 H2/H4），按 ID 裁定会误伤同名项。
export function isJudgedItem(item) {
  return item.verified !== undefined || /^[BC]/.test(item.id);
}

// 人工裁定叠加：同一 ID 多次裁定以最后一次为准；汇总统计按人工裁定后的有效结果算
export function applyOverrides(items, overrides = []) {
  const byId = new Map();
  for (const o of overrides) byId.set(o.id, o);
  return items.map((it) => {
    const o = byId.get(it.id);
    return o ? { ...it, effectivePass: o.pass, override: o } : { ...it, effectivePass: it.pass };
  });
}

export function renderHtml({ scenario, transcript = [], items = [], overrides = [], round = 0, tokensTotal = 0, projectDir = null }) {
  items = applyOverrides(items, overrides);
  const msgs = transcript
    .map((t, i) => {
      const who = t.role === "agent" ? "Agent" : "模拟用户";
      return `<div class="msg ${t.role === "agent" ? "agent" : "user"}" id="round-${i + 1}">
  <div class="meta">第 ${i + 1} 轮 · ${who}</div>
  <div class="bubble">${esc(t.text)}</div>
</div>`;
    })
    .join("\n");

  const rows = items
    .map((it, idx) => {
      const badge = it.verified ? VERIFIED_BADGE[it.verified] : null;
      const jump = Number.isInteger(it.round)
        ? ` <button class="jump" data-round="${it.round}">第 ${it.round} 轮 ↗</button>`
        : "";
      const o = it.override;
      const overrideBlock = o
        ? `<div class="override">人工复核${o.overturned ? "推翻" : "确认"} judge 判定 → <b>${o.pass ? "✓ pass" : "✗ fail"}</b><br>理由: ${esc(o.reason)}<span class="at">${esc((o.at || "").slice(0, 10))}</span></div>`
        : "";
      const reviewForm = isJudgedItem(it)
        ? `<details class="review"><summary>复核此判定</summary>
    <div class="review-body" data-id="${esc(it.id)}">
      <label><input type="radio" name="rv-${idx}" value="pass"> 实际应为 pass</label>
      <label><input type="radio" name="rv-${idx}" value="fail"> 实际应为 fail</label>
      <input class="reason" placeholder="理由（必填）：你在原文里看到了什么">
      <button class="submit">提交裁定</button>
      <span class="review-msg"></span>
    </div>
  </details>`
        : "";
      return `<div class="item ${it.effectivePass ? "pass" : "fail"}">
  <div class="head"><span class="mark">${it.pass ? "✓" : "✗"}</span> <b>[${esc(it.id)}]</b> ${esc(it.label)}${jump}</div>
  ${it.detail ? `<div class="detail">${esc(it.detail)}</div>` : ""}
  ${badge ? `<div class="badge ${badge[0]}">${badge[1]}</div>` : ""}
  ${overrideBlock}
  ${reviewForm}
</div>`;
    })
    .join("\n");

  const passCount = items.filter((i) => i.effectivePass).length;
  const failCount = items.length - passCount;
  const overrideCount = items.filter((i) => i.override).length;

  return `<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>E2E 报告 — ${esc(scenario)}</title>
<style>
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.6 -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; background: #f5f6f8; color: #1f2328; }
  header { padding: 12px 20px; background: #fff; border-bottom: 1px solid #e3e5e8; position: sticky; top: 0; z-index: 2; display: flex; gap: 16px; align-items: baseline; flex-wrap: wrap; }
  header h1 { font-size: 16px; margin: 0; }
  header .stat { color: #57606a; font-size: 13px; }
  header .stat b.ok { color: #1a7f37; } header .stat b.bad { color: #cf222e; }
  main { display: flex; gap: 0; align-items: flex-start; }
  #chat { flex: 1 1 60%; padding: 16px 20px 60px; min-width: 0; }
  #panel { flex: 0 0 40%; max-width: 560px; padding: 16px 20px 60px; position: sticky; top: 49px; max-height: calc(100vh - 49px); overflow-y: auto; }
  .msg { margin: 10px 0; max-width: 92%; }
  .msg.user { margin-left: auto; }
  .msg .meta { font-size: 12px; color: #8b949e; margin: 0 6px 2px; }
  .msg.user .meta { text-align: right; }
  .msg .bubble { padding: 10px 14px; border-radius: 10px; background: #fff; border: 1px solid #e3e5e8; white-space: pre-wrap; word-break: break-word; }
  .msg.user .bubble { background: #dcf1dd; border-color: #c3e6c5; }
  .msg.hl .bubble { outline: 3px solid #f5a623; outline-offset: 1px; }
  .item { background: #fff; border: 1px solid #e3e5e8; border-left: 4px solid #1a7f37; border-radius: 8px; padding: 10px 12px; margin: 8px 0; }
  .item.fail { border-left-color: #cf222e; }
  .item .mark { font-weight: 700; }
  .item.pass .mark { color: #1a7f37; } .item.fail .mark { color: #cf222e; }
  .item .detail { margin-top: 6px; padding: 8px 10px; background: #f6f8fa; border-radius: 6px; font-size: 13px; color: #424a53; white-space: pre-wrap; word-break: break-word; }
  .badge { display: inline-block; margin-top: 6px; font-size: 12px; padding: 2px 8px; border-radius: 10px; }
  .badge.ok { background: #dafbe1; color: #1a7f37; }
  .badge.warn { background: #fff8c5; color: #7d4e00; }
  .badge.bad { background: #ffebe9; color: #cf222e; }
  .jump { font-size: 12px; border: 1px solid #d0d7de; background: #f6f8fa; border-radius: 6px; padding: 1px 8px; cursor: pointer; color: #0969da; }
  .jump:hover { background: #eef1f4; }
  .override { margin-top: 6px; padding: 8px 10px; background: #f0ecff; border: 1px solid #d8ccff; border-radius: 6px; font-size: 13px; color: #4c3d99; }
  .override .at { float: right; color: #8b80b8; font-size: 12px; }
  .review { margin-top: 6px; font-size: 13px; }
  .review summary { color: #0969da; cursor: pointer; }
  .review-body { margin-top: 6px; display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
  .review-body label { color: #424a53; }
  .review-body .reason { flex: 1 1 100%; padding: 5px 8px; border: 1px solid #d0d7de; border-radius: 6px; font-size: 13px; }
  .review-body .submit { border: 1px solid #d0d7de; background: #f6f8fa; border-radius: 6px; padding: 3px 12px; cursor: pointer; color: #1a7f37; font-weight: 600; }
  .review-body .submit:hover { background: #eef1f4; }
  .review-msg { font-size: 12px; color: #cf222e; }
  .review-msg.ok { color: #1a7f37; }
  #cleanup { margin-top: 20px; padding: 12px; background: #fff; border: 1px dashed #d0d7de; border-radius: 8px; }
  #cleanup button { border: 1px solid #cf222e; color: #cf222e; background: #fff; border-radius: 6px; padding: 5px 14px; cursor: pointer; font-weight: 600; }
  #cleanup button.armed { background: #cf222e; color: #fff; }
  #cleanup .hint { margin-top: 6px; font-size: 12px; color: #8b949e; word-break: break-all; }
  #cleanup-msg { margin-left: 8px; font-size: 12px; color: #cf222e; }
  #cleanup-msg.ok { color: #1a7f37; }
  h2 { font-size: 14px; color: #57606a; margin: 4px 0 8px; }
</style>
</head>
<body>
<header>
  <h1>${esc(scenario)}</h1>
  <span class="stat"><b class="ok">${passCount} passed</b> / <b class="bad">${failCount} failed</b>（共 ${items.length} 项${overrideCount ? `，含 ${overrideCount} 项人工复核` : ""}）</span>
  <span class="stat">对话 ${round} 轮 · tokens ~${tokensTotal}</span>
</header>
<main>
  <section id="chat">
    <h2>对话回放（${transcript.length} 条消息）</h2>
${msgs || '<p style="color:#8b949e">（无对话记录）</p>'}
  </section>
  <aside id="panel">
    <h2>断言与评判（点击轮次号跳转高亮）</h2>
${rows || '<p style="color:#8b949e">（无断言结果）</p>'}
${projectDir ? `    <div id="cleanup">
      <button id="cleanup-btn">复核完成，清理临时项目</button>
      <span id="cleanup-msg"></span>
      <div class="hint">将删除 ${esc(projectDir)} 并停掉其 dev server。前提：所有 ✗ 项与 ⚠ 证据存疑项都已人工裁定，否则会被拒绝。日志与报告（logs/ 目录）永久保留，不受影响。</div>
    </div>` : ""}
  </aside>
</main>
<script>
document.querySelectorAll("[data-round]").forEach(function (el) {
  el.addEventListener("click", function () {
    var t = document.getElementById("round-" + el.dataset.round);
    if (!t) return;
    document.querySelectorAll(".msg.hl").forEach(function (m) { m.classList.remove("hl"); });
    t.classList.add("hl");
    t.scrollIntoView({ behavior: "smooth", block: "center" });
  });
});
// 网页复核：经 review-server 打开时直接 POST 落盘；file:// 直开时退化为复制 CLI 命令
document.querySelectorAll(".review-body .submit").forEach(function (btn) {
  btn.addEventListener("click", async function () {
    var box = btn.closest(".review-body");
    var msg = box.querySelector(".review-msg");
    var sel = box.querySelector("input[type=radio]:checked");
    var reason = box.querySelector(".reason").value.trim();
    msg.className = "review-msg";
    if (!sel) { msg.textContent = "请先选 pass 或 fail"; return; }
    if (!reason) { msg.textContent = "理由必填——写下你在原文里看到了什么"; return; }
    var id = box.dataset.id;
    if (location.protocol === "file:") {
      var cmd = 'node tests/e2e-agent/feedback.mjs <logDir> ' + id + " " + sel.value + ' "' + reason.replace(/"/g, "'") + '"';
      try { await navigator.clipboard.writeText(cmd); } catch (e) {}
      msg.textContent = "此页面是直接打开的文件，无法写盘。命令已复制到剪贴板；要网页直接提交，请用 review-server 打开报告。";
      return;
    }
    btn.disabled = true;
    try {
      var r = await fetch("/api/override", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: id, pass: sel.value === "pass", reason: reason }),
      });
      var text = await r.text();
      var data;
      try { data = JSON.parse(text); }
      catch (pe) { throw new Error("HTTP " + r.status + "，响应非 JSON: " + text.slice(0, 80)); }
      if (!data.ok) throw new Error(data.error + "（HTTP " + r.status + "）");
      msg.className = "review-msg ok";
      msg.textContent = "已落盘，刷新中…";
      setTimeout(function () { location.reload(); }, 600);
    } catch (e) {
      btn.disabled = false;
      msg.textContent = "提交失败: " + e.message;
    }
  });
});
// 复核完成 → 清理临时项目（两次点击确认；服务端还有"全部复核完毕"门禁兜底）
var cleanupBtn = document.getElementById("cleanup-btn");
if (cleanupBtn) {
  var cleanupMsg = document.getElementById("cleanup-msg");
  var armed = false, armTimer = null;
  cleanupBtn.addEventListener("click", async function () {
    if (location.protocol === "file:") {
      cleanupMsg.textContent = "此页面是直接打开的文件，请用 review-server 打开后再清理。";
      return;
    }
    if (!armed) {
      armed = true;
      cleanupBtn.classList.add("armed");
      cleanupBtn.textContent = "再点一次确认删除";
      armTimer = setTimeout(function () {
        armed = false;
        cleanupBtn.classList.remove("armed");
        cleanupBtn.textContent = "复核完成，清理临时项目";
      }, 5000);
      return;
    }
    clearTimeout(armTimer);
    cleanupBtn.disabled = true;
    cleanupMsg.className = "";
    try {
      var r = await fetch("/api/cleanup", { method: "POST" });
      var text = await r.text();
      var data;
      try { data = JSON.parse(text); }
      catch (pe) { throw new Error("HTTP " + r.status + "，响应非 JSON: " + text.slice(0, 80)); }
      if (!data.ok) throw new Error(data.error + (data.unresolved ? "：" + data.unresolved.join("、") : ""));
      cleanupMsg.className = "ok";
      cleanupMsg.textContent = "已清理临时项目。日志与报告保留在 logs/ 下。";
      cleanupBtn.textContent = "已清理";
    } catch (e) {
      cleanupBtn.disabled = false;
      armed = false;
      cleanupBtn.classList.remove("armed");
      cleanupBtn.textContent = "复核完成，清理临时项目";
      cleanupMsg.textContent = "未清理: " + e.message;
    }
  });
}
</script>
</body>
</html>
`;
}

// 旧日志兜底：transcript.json 出现之前的 run 只有 transcript.md，
// 按 record() 的固定格式（## 角色 块 + --- 分隔）解析回结构化对话。
export function parseTranscriptMd(md) {
  const out = [];
  for (const block of String(md).split(/\n---\n\n/)) {
    const m = block.match(/^## (Agent|模拟用户)\n\n([\s\S]*?)\s*$/);
    if (m) out.push({ role: m[1] === "Agent" ? "agent" : "user", text: m[2] });
  }
  return out;
}

export function generateReport(logDir) {
  const reportFile = path.join(logDir, "report.json");
  const report = JSON.parse(fs.readFileSync(reportFile, "utf8"));
  let transcript = [];
  const tj = path.join(logDir, "transcript.json");
  const tm = path.join(logDir, "transcript.md");
  if (fs.existsSync(tj)) transcript = JSON.parse(fs.readFileSync(tj, "utf8"));
  else if (fs.existsSync(tm)) transcript = parseTranscriptMd(fs.readFileSync(tm, "utf8"));
  const overridesFile = path.join(logDir, "overrides.json");
  const overrides = fs.existsSync(overridesFile)
    ? JSON.parse(fs.readFileSync(overridesFile, "utf8"))
    : [];
  const out = path.join(logDir, "report.html");
  fs.writeFileSync(
    out,
    renderHtml({
      scenario: report.scenario,
      transcript,
      items: report.items || [],
      overrides,
      round: report.round || 0,
      tokensTotal: report.tokensTotal || 0,
      // 项目现场还在才显示清理入口（旧格式 report.json 无此字段 → 不显示）
      projectDir: report.projectDir && fs.existsSync(report.projectDir) ? report.projectDir : null,
    })
  );
  return out;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const logDir = process.argv[2];
  if (!logDir) {
    console.error("用法: node report-html.mjs <logDir>");
    process.exit(2);
  }
  console.log(generateReport(path.resolve(logDir)));
}
