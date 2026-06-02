import { describe, it, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import fs from "node:fs/promises";
import os from "node:os";

const MCP_SERVER = path.resolve(
  import.meta.dirname,
  "../plugins/claude/minus-creator/mcp-servers/minus-platform/index.js"
);

// 出厂产物（esbuild 自包含 bundle）—— .mcp.json 实际指向它，必须单独冒烟测试，
// 才能抓住打包回归（如顶层 await 没去干净、依赖没内联）。
const MCP_BUNDLE = path.resolve(
  import.meta.dirname,
  "../plugins/claude/minus-creator/mcp-servers/minus-platform/dist/minus-platform.cjs"
);

// launcher —— .mcp.json 的 command:"node" 实际跑它（node launch.cjs），它探测 >=18 node
// 再 re-exec bundle（跨平台）。冒烟测试保证整条「客户端入口」链路能起、能列工具。
const MCP_LAUNCHER = path.resolve(
  import.meta.dirname,
  "../plugins/claude/minus-creator/mcp-servers/minus-platform/launch.cjs"
);

// JSON-RPC helper to talk to MCP server via stdio
class McpClient {
  constructor() {
    this._id = 0;
    this._pending = new Map();
    this._buffer = "";
  }

  async start(env = {}, serverPath = MCP_SERVER, command = "node") {
    this.proc = spawn(command, [serverPath], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, ...env },
    });
    this.proc.stdout.on("data", (chunk) => this._onData(chunk));
    this.proc.stderr.on("data", (chunk) => {
      // Swallow stderr (MCP SDK logs)
    });

    // MCP requires initialize handshake
    const initResult = await this.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "test-client", version: "0.1.0" },
    });
    assert.ok(initResult.protocolVersion, "MCP initialize should return protocolVersion");

    // Send initialized notification
    this.notify("notifications/initialized", {});
    return initResult;
  }

  async stop() {
    if (this.proc) {
      this.proc.stdin.end();
      this.proc.kill();
      this.proc = null;
    }
  }

  request(method, params = {}) {
    const id = ++this._id;
    const msg = { jsonrpc: "2.0", id, method, params };
    return new Promise((resolve, reject) => {
      this._pending.set(id, { resolve, reject });
      this.proc.stdin.write(JSON.stringify(msg) + "\n");
      setTimeout(() => {
        if (this._pending.has(id)) {
          this._pending.delete(id);
          reject(new Error(`Request ${method} timed out`));
        }
      }, 10000);
    });
  }

  notify(method, params = {}) {
    const msg = { jsonrpc: "2.0", method, params };
    this.proc.stdin.write(JSON.stringify(msg) + "\n");
  }

  async callTool(name, args = {}) {
    const result = await this.request("tools/call", { name, arguments: args });
    return result;
  }

  async listTools() {
    return this.request("tools/list", {});
  }

  _onData(chunk) {
    this._buffer += chunk.toString();
    const lines = this._buffer.split("\n");
    this._buffer = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const msg = JSON.parse(line);
        if (msg.id && this._pending.has(msg.id)) {
          const { resolve, reject } = this._pending.get(msg.id);
          this._pending.delete(msg.id);
          if (msg.error) {
            reject(new Error(msg.error.message));
          } else {
            resolve(msg.result);
          }
        }
      } catch {
        // ignore non-JSON lines
      }
    }
  }
}

// ── Test Suite ──

const MCP_JSON = path.resolve(
  import.meta.dirname,
  "../plugins/claude/minus-creator/.mcp.json"
);

const VALID_MCP_TYPES = new Set(["stdio", "http", "sse"]);

describe("MCP Config - .mcp.json validation", () => {
  let config;

  before(async () => {
    const raw = await fs.readFile(MCP_JSON, "utf8");
    config = JSON.parse(raw);
  });

  it("should be valid JSON with at least one server", () => {
    assert.ok(Object.keys(config).length > 0, "should have at least one MCP server");
  });

  it("each server with explicit type should use a valid transport (stdio/http/sse)", () => {
    for (const [name, server] of Object.entries(config)) {
      if (server.type) {
        assert.ok(
          VALID_MCP_TYPES.has(server.type),
          `${name}: type "${server.type}" is invalid, must be one of: ${[...VALID_MCP_TYPES].join(", ")}`
        );
      }
    }
  });

  it("stdio servers should have command field", () => {
    for (const [name, server] of Object.entries(config)) {
      if (!server.type || server.type === "stdio") {
        if (!server.url) {
          assert.ok(server.command, `${name}: stdio server must have "command" field`);
        }
      }
    }
  });

  it("minus-platform launches via node launch.cjs (跨平台引导器，非 /bin/sh、非裸 bundle)", () => {
    const mp = config["minus-platform"];
    assert.ok(mp, "minus-platform server must exist");
    assert.equal(mp.command, "node", "command 必须是 node（跨平台），不再是 /bin/sh");
    assert.ok(Array.isArray(mp.args) && mp.args.length === 1, "args 应只指向 launcher");
    assert.match(mp.args[0], /launch\.cjs$/, "args 必须指向 launch.cjs 引导器（而非裸 dist bundle）");
    assert.ok(!/launch\.sh/.test(mp.args[0]), "不应再引用 launch.sh");
  });

  it("http/sse servers should have url field", () => {
    for (const [name, server] of Object.entries(config)) {
      if (server.type === "http" || server.type === "sse") {
        assert.ok(server.url, `${name}: ${server.type} server must have "url" field`);
      }
    }
  });
});

describe("MCP Server - Tool Registration", () => {
  let client;

  before(async () => {
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: "http://127.0.0.1:19999", // non-existent, we test registration not API
    });
  });

  after(async () => {
    await client.stop();
  });

  it("should list all expected tools", async () => {
    const result = await client.listTools();
    const names = result.tools.map((t) => t.name).sort();
    assert.deepEqual(names, [
      "auth_dev_session",
      "auth_login",
      "auth_logout",
      "auth_register",
      "auth_status",
      "auth_vcode",
      "file_upload",
      "session_create",
      "session_list",
      "skill_list",
      "skill_tag_list",
      "skill_update",
      "skill_version_create",
      "skill_version_get",
      "skill_version_submit",
    ]);
  });

  it("each tool should have a description", async () => {
    const result = await client.listTools();
    for (const tool of result.tools) {
      assert.ok(tool.description, `${tool.name} should have description`);
    }
  });
});

describe("MCP Server - Auth Tools (no credentials)", () => {
  let client;
  let tmpHome;

  before(async () => {
    // Use temp dir as HOME so no real credentials interfere
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "mcp-test-"));
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: "http://127.0.0.1:19999",
      HOME: tmpHome,
    });
  });

  after(async () => {
    await client.stop();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("auth_status should report not logged in when no credentials", async () => {
    const result = await client.callTool("auth_status");
    const text = result.content[0].text;
    assert.ok(text.includes("未登录"), `Expected '未登录' in: ${text}`);
  });

  it("skill_list should fail when not logged in", async () => {
    const result = await client.callTool("skill_list");
    const text = result.content[0].text;
    assert.ok(
      text.includes("未登录") || text.includes("NOT_LOGGED_IN"),
      `Expected auth error in: ${text}`
    );
  });

  it("skill_create should not exist (removed, use create-skill CLI)", async () => {
    const tools = await client.listTools();
    const names = tools.tools.map((t) => t.name);
    assert.ok(!names.includes("skill_create"), "skill_create should not be registered");
  });
});

describe("MCP Server - Auth Tools (with mock credentials)", () => {
  let client;
  let tmpHome;

  before(async () => {
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "mcp-test-"));
    // Write fake credentials
    const minusDir = path.join(tmpHome, ".minus");
    await fs.mkdir(minusDir, { recursive: true });
    await fs.writeFile(
      path.join(minusDir, "credentials.json"),
      JSON.stringify({
        session_id: "fake-session-id",
        user_id: "user123",
        team_id: "team456",
        api_base: "http://127.0.0.1:19999",
      })
    );
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: "http://127.0.0.1:19999",
      HOME: tmpHome,
    });
  });

  after(async () => {
    await client.stop();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("auth_status with fake creds should attempt API call and fail gracefully", async () => {
    const result = await client.callTool("auth_status");
    const text = result.content[0].text;
    // Should fail because 127.0.0.1:19999 is not running, but not crash
    assert.ok(text, "Should return some text response");
  });

  it("auth_logout should clear credentials", async () => {
    const result = await client.callTool("auth_logout");
    const text = result.content[0].text;
    assert.ok(text.includes("已登出"), `Expected '已登出' in: ${text}`);

    // Verify credentials file was deleted
    const credPath = path.join(tmpHome, ".minus", "credentials.json");
    try {
      await fs.access(credPath);
      assert.fail("credentials.json should have been deleted");
    } catch (e) {
      assert.equal(e.code, "ENOENT");
    }
  });
});

describe("MCP Server - Vcode & Register (network errors handled)", () => {
  let client;
  let tmpHome;

  before(async () => {
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "mcp-test-"));
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: "http://127.0.0.1:19999",
      HOME: tmpHome,
    });
  });

  after(async () => {
    await client.stop();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("auth_vcode should handle connection refused gracefully", async () => {
    const result = await client.callTool("auth_vcode", {
      channel: "phone",
      target: "+8613800000001",
      purpose: "login",
    });
    const text = result.content[0].text;
    assert.ok(
      text.includes("失败") || text.includes("网络连接"),
      `Expected failure/network message in: ${text}`
    );
  });

  it("auth_register should handle connection refused gracefully", async () => {
    const result = await client.callTool("auth_register", {
      channel: "phone",
      target: "+8613800000001",
      code: "123456",
    });
    const text = result.content[0].text;
    assert.ok(
      text.includes("失败") || text.includes("网络连接"),
      `Expected failure/network message in: ${text}`
    );
  });

  it("auth_login should handle connection refused gracefully", async () => {
    const result = await client.callTool("auth_login", {
      grantType: "phone_code",
      identifier: "+8613800000001",
      credential: "123456",
    });
    const text = result.content[0].text;
    assert.ok(
      text.includes("失败") || text.includes("网络连接"),
      `Expected failure/network message in: ${text}`
    );
  });

  it("auth_dev_session should handle connection refused gracefully", async () => {
    const result = await client.callTool("auth_dev_session", {
      apiKey: "mdk_" + "a".repeat(40),
    });
    const text = result.content[0].text;
    assert.ok(
      text.includes("失败") || text.includes("网络连接"),
      `Expected failure/network message in: ${text}`
    );
  });

  it("skill_version_create should handle connection refused gracefully", async () => {
    // Need fake credentials for this tool (uses apiRequest which checks auth)
    const credDir = path.join(tmpHome, ".minus");
    await fs.mkdir(credDir, { recursive: true });
    await fs.writeFile(
      path.join(credDir, "credentials.json"),
      JSON.stringify({ session_id: "fake_sid", auth_type: "api_key", api_key: "mdk_" + "a".repeat(40) })
    );
    const result = await client.callTool("skill_version_create", {
      skillId: "skl_test123",
    });
    const text = result.content[0].text;
    assert.ok(
      text.includes("失败") || text.includes("网络连接"),
      `Expected failure/network message in: ${text}`
    );
  });

  it("skill_version_submit should reject non-project directory", async () => {
    const result = await client.callTool("skill_version_submit", {
      skillId: "skl_test123",
      projectDir: tmpHome,
    });
    const text = result.content[0].text;
    assert.ok(
      text.includes("不是 Minus Skill 项目"),
      `Expected project validation error in: ${text}`
    );
  });
});

// 出厂产物冒烟测试：直接跑 .mcp.json 指向的 bundle，确认它能起、能列工具。
// 覆盖源码测试照不到的打包环节（TLA、依赖内联）。run-all.sh 会先 npm run build。
describe("MCP Server - bundle (dist/minus-platform.cjs)", () => {
  let client;

  before(async () => {
    await fs.access(MCP_BUNDLE); // 不存在直接抛错，提示需先 npm run build
    client = new McpClient();
    await client.start({ MINUS_API_BASE: "http://127.0.0.1:19999" }, MCP_BUNDLE);
  });

  after(async () => {
    if (client) await client.stop();
  });

  it("bundle should initialize and expose the same tool set as source", async () => {
    const result = await client.listTools();
    const names = result.tools.map((t) => t.name).sort();
    assert.deepEqual(names, [
      "auth_dev_session",
      "auth_login",
      "auth_logout",
      "auth_register",
      "auth_status",
      "auth_vcode",
      "file_upload",
      "session_create",
      "session_list",
      "skill_list",
      "skill_tag_list",
      "skill_update",
      "skill_version_create",
      "skill_version_get",
      "skill_version_submit",
    ]);
  });
});

// launcher 冒烟测试：跑 .mcp.json 真正的入口（node launch.cjs），确认它能挑到
// 当前 node（测试环境本身 >=18）并把 bundle 起起来。覆盖「客户端 command 链路」。
describe("MCP Server - launcher (launch.cjs → bundle)", () => {
  let client;

  before(async () => {
    await fs.access(MCP_LAUNCHER);
    await fs.access(MCP_BUNDLE); // launcher 会跑它，需先 npm run build
    client = new McpClient();
    await client.start(
      { MINUS_API_BASE: "http://127.0.0.1:19999" },
      MCP_LAUNCHER,
      "node"
    );
  });

  after(async () => {
    if (client) await client.stop();
  });

  it("launcher should boot the bundle and expose the full tool set", async () => {
    const result = await client.listTools();
    const names = result.tools.map((t) => t.name).sort();
    assert.deepEqual(names, [
      "auth_dev_session",
      "auth_login",
      "auth_logout",
      "auth_register",
      "auth_status",
      "auth_vcode",
      "file_upload",
      "session_create",
      "session_list",
      "skill_list",
      "skill_tag_list",
      "skill_update",
      "skill_version_create",
      "skill_version_get",
      "skill_version_submit",
    ]);
  });
});
