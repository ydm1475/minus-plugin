// session.mjs — 单进程多轮 claude 会话（stream-json 双向流）
// 与真实用户的连续 session 对齐：一次进程启动、一次 SessionStart hook 注入、
// MCP server 全程不重启；每轮只是往 stdin 写一条 user 消息、等一个 result 事件。
// 协议为实证结论（2026-07-02 用 haiku 两轮冒烟验证，官方文档未覆盖 CLI 细节）：
//   stdin:  NDJSON，每行 {"type":"user","message":{"role":"user","content":"..."}}
//   stdout: NDJSON 事件流；每条 user 消息以一个 {"type":"result"} 事件收尾，
//           其中含 result 文本、session_id、usage、累计费用
//   退出:   stdin end 后进程正常退出；--max-budget-usd 对整个进程生效

import { spawn } from "node:child_process";

export function parseLine(line) {
  const t = String(line).trim();
  if (!t) return null;
  try {
    return JSON.parse(t);
  } catch {
    return null;
  }
}

export function extractResult(ev) {
  if (!ev || ev.type !== "result") return null;
  return {
    text: ev.result ?? "",
    subtype: ev.subtype || "",
    sessionId: ev.session_id || null,
    usage: {
      input: ev.usage?.input_tokens || 0,
      output: ev.usage?.output_tokens || 0,
    },
    costUsd: ev.total_cost_usd ?? null,
  };
}

export class ClaudeSession {
  /**
   * @param {object} opts
   *   command      可执行名（默认 claude；测试桩用 process.execPath）
   *   prependArgs  置于所有参数之前（测试桩的脚本路径）
   *   args         追加的 CLI 参数（--plugin-dir/--model/--max-budget-usd/...）
   *   cwd, env   子进程环境
   *   onEvent    每个解析成功的事件回调（落日志用）
   */
  constructor(opts = {}) {
    this.opts = opts;
    this.proc = null;
    this.buf = "";
    this.pending = null; // { resolve, reject, timer } —— 协议要求串行，一次只允许一个在途轮次
    this.exited = false;
    this.exitInfo = null;
  }

  start() {
    const args = [
      ...(this.opts.prependArgs || []),
      "-p",
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--verbose",
      ...(this.opts.args || []),
    ];
    this.proc = spawn(this.opts.command || "claude", args, {
      cwd: this.opts.cwd,
      env: this.opts.env || process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc.stdout.on("data", (chunk) => this.#consume(chunk));
    if (this.opts.onStderr) this.proc.stderr.on("data", (d) => this.opts.onStderr(String(d)));
    else this.proc.stderr.resume();
    this.proc.on("close", (code, signal) => {
      this.exited = true;
      this.exitInfo = { code, signal };
      if (this.pending) {
        const p = this.pending;
        this.pending = null;
        clearTimeout(p.timer);
        p.reject(new Error(`claude 进程在等待应答时退出（code=${code} signal=${signal || "无"}）`));
      }
    });
    this.proc.on("error", (err) => {
      this.exited = true;
      if (this.pending) {
        const p = this.pending;
        this.pending = null;
        clearTimeout(p.timer);
        p.reject(err);
      }
    });
    return this;
  }

  #consume(chunk) {
    this.buf += chunk;
    let nl;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      const ev = parseLine(line);
      if (!ev) continue;
      this.opts.onEvent?.(ev);
      const result = extractResult(ev);
      if (result && this.pending) {
        const p = this.pending;
        this.pending = null;
        clearTimeout(p.timer);
        p.resolve(result);
      }
    }
  }

  /** 发送一条用户消息，resolve 为该轮的 result（{text, sessionId, usage, costUsd}） */
  send(text, { timeoutMs = 15 * 60_000 } = {}) {
    if (this.exited) {
      return Promise.reject(new Error(`claude 进程已退出（code=${this.exitInfo?.code}），无法继续对话`));
    }
    if (this.pending) {
      return Promise.reject(new Error("上一轮尚未收到 result，stream-json 协议要求串行发送"));
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending = null;
        reject(new Error(`等待应答超时（${Math.round(timeoutMs / 60000)} 分钟），进程仍在运行`));
      }, timeoutMs);
      this.pending = { resolve, reject, timer };
      this.proc.stdin.write(
        JSON.stringify({ type: "user", message: { role: "user", content: text } }) + "\n",
        (err) => {
          if (err && this.pending) {
            const p = this.pending;
            this.pending = null;
            clearTimeout(p.timer);
            p.reject(err);
          }
        }
      );
    });
  }

  /** 正常收尾：关 stdin，等进程退出（超时则强杀） */
  close({ timeoutMs = 10_000 } = {}) {
    if (!this.proc || this.exited) return Promise.resolve();
    return new Promise((resolve) => {
      const killer = setTimeout(() => {
        try { this.proc.kill(); } catch {}
        resolve();
      }, timeoutMs);
      this.proc.on("close", () => {
        clearTimeout(killer);
        resolve();
      });
      this.proc.stdin.end();
    });
  }
}
