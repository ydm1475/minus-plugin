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

// JSON-RPC helper to talk to MCP server via stdio
class McpClient {
  constructor() {
    this._id = 0;
    this._pending = new Map();
    this._buffer = "";
  }

  async start(env = {}) {
    this.proc = spawn("node", [MCP_SERVER], {
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
      "skill_update",
      "skill_version_get",
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
});
