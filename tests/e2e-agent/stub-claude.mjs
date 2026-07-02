// stub-claude.mjs — harness 测试用的 claude 桩（零 token）
// 模仿 stream-json 双向流协议：每收到一条 user 消息，回一个 assistant + 一个 result 事件。
// 特殊指令（user content）:
//   "CRASH"  → 进程立即异常退出（测试进程死亡路径）
//   "SLOW"   → 不应答（测试超时路径）
// 其余消息 → result.result = "echo: <content>"

process.stdin.setEncoding("utf8");
let buf = "";
let turns = 0;

console.log(JSON.stringify({ type: "system", subtype: "init", session_id: "stub-session-1" }));

process.stdin.on("data", (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    const content = msg?.message?.content;
    if (content === "CRASH") process.exit(3);
    if (content === "SLOW") continue;
    turns++;
    console.log(JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: `echo: ${content}` }] } }));
    console.log(JSON.stringify({
      type: "result",
      subtype: "success",
      result: `echo: ${content}`,
      session_id: "stub-session-1",
      num_turns: turns,
      usage: { input_tokens: 10, output_tokens: 5 },
      total_cost_usd: 0.001 * turns,
    }));
  }
});

process.stdin.on("end", () => process.exit(0));
