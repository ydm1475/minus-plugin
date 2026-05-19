import { describe, it, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import http from "node:http";
import path from "node:path";
import fs from "node:fs/promises";
import os from "node:os";

const MCP_SERVER = path.resolve(
  import.meta.dirname,
  "../plugins/claude/minus-creator/mcp-servers/minus-platform/index.js"
);

// ── Mock Minus API Server ──

function createMockApi() {
  const state = {
    users: {},
    skills: [],
    sessions: [],
    vcodes: {},
    nextSkillId: 1,
  };

  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const json = body ? JSON.parse(body) : {};
      const url = req.url;
      const method = req.method;

      res.setHeader("Content-Type", "application/json");

      // ── Auth: send vcode ──
      if (method === "POST" && url === "/api/auth/vcode/send") {
        state.vcodes[json.target] = "123456";
        res.end(JSON.stringify({ ok: true }));
        return;
      }

      // ── Auth: register ──
      if (method === "POST" && url === "/api/auth/register") {
        if (json.code !== state.vcodes[json.target]) {
          res.statusCode = 400;
          res.end(JSON.stringify({ code: "VCODE_INVALID", message: "验证码错误" }));
          return;
        }
        const userId = `user_${Date.now()}`;
        const teamId = `team_${Date.now()}`;
        state.users[userId] = {
          userId,
          nickname: "TestUser",
          primaryPhone: json.target,
          currentTeam: { id: teamId, name: "Personal", plan: "free" },
        };
        const sid = `sid_${Date.now()}`;
        state.users[sid] = userId;
        res.setHeader("Set-Cookie", `MINUS_AI_SID=${sid}; Path=/`);
        res.end(JSON.stringify({ userId, personalTeamId: teamId }));
        return;
      }

      // ── Auth: login ──
      if (method === "POST" && url === "/api/auth/login") {
        if (json.grantType === "phone_code" && json.credential !== state.vcodes[json.identifier]) {
          res.statusCode = 401;
          res.end(JSON.stringify({ code: "VCODE_INVALID", message: "验证码错误" }));
          return;
        }
        const userId = `user_${Date.now()}`;
        const teamId = `team_${Date.now()}`;
        state.users[userId] = {
          userId,
          nickname: "TestUser",
          primaryEmail: json.identifier,
          currentTeam: { id: teamId, name: "Personal", plan: "free" },
        };
        const sid = `sid_${Date.now()}`;
        state.users[sid] = userId;
        res.setHeader("Set-Cookie", `MINUS_AI_SID=${sid}; Path=/`);
        res.end(JSON.stringify({ userId, currentTeamId: teamId }));
        return;
      }

      // ── Auth: me ──
      if (method === "GET" && url === "/api/me") {
        const cookie = req.headers.cookie || "";
        const sidMatch = cookie.match(/MINUS_AI_SID=([^;]+)/);
        if (!sidMatch || !state.users[sidMatch[1]]) {
          res.statusCode = 401;
          res.end(JSON.stringify({ code: "UNAUTHORIZED", message: "未授权" }));
          return;
        }
        const userId = state.users[sidMatch[1]];
        const user = state.users[userId];
        res.end(JSON.stringify(user));
        return;
      }

      // ── Auth: logout ──
      if (method === "POST" && url === "/api/auth/logout") {
        res.statusCode = 204;
        res.end();
        return;
      }

      // ── Skills: list ──
      if (method === "GET" && url === "/api/me/skills") {
        const cookie = req.headers.cookie || "";
        const sidMatch = cookie.match(/MINUS_AI_SID=([^;]+)/);
        if (!sidMatch || !state.users[sidMatch[1]]) {
          res.statusCode = 401;
          res.end(JSON.stringify({ code: "UNAUTHORIZED", message: "未授权" }));
          return;
        }
        res.end(JSON.stringify(state.skills));
        return;
      }

      // ── Skills: create ──
      if (method === "POST" && url === "/api/skills") {
        const cookie = req.headers.cookie || "";
        const sidMatch = cookie.match(/MINUS_AI_SID=([^;]+)/);
        if (!sidMatch || !state.users[sidMatch[1]]) {
          res.statusCode = 401;
          res.end(JSON.stringify({ code: "UNAUTHORIZED", message: "未授权" }));
          return;
        }
        const skill = {
          id: `sk_${state.nextSkillId++}`,
          currentVersionId: `ver_1`,
          apiKey: `ak_${Date.now()}`,
          displayName: json.displayName,
          description: json.description,
          version: json.version || "1.0.0",
        };
        state.skills.push(skill);
        res.statusCode = 201;
        res.end(JSON.stringify(skill));
        return;
      }

      // ── Skills: update ──
      if (method === "PATCH" && url.match(/^\/api\/skills\/[^/]+$/)) {
        const skillId = url.split("/")[3];
        const skill = state.skills.find((s) => s.id === skillId);
        if (!skill) {
          res.statusCode = 404;
          res.end(JSON.stringify({ code: "NOT_FOUND", message: "Skill 不存在" }));
          return;
        }
        Object.assign(skill, json);
        res.end(JSON.stringify(skill));
        return;
      }

      // ── Skills: endpoint set ──
      if (method === "PUT" && url.match(/^\/api\/admin\/skills\/.+\/endpoint$/)) {
        const skillId = url.split("/")[4];
        const skill = state.skills.find((s) => s.id === skillId);
        if (!skill) {
          res.statusCode = 404;
          res.end(JSON.stringify({ code: "NOT_FOUND", message: "Skill 不存在" }));
          return;
        }
        skill.endpointUrl = json.endpointUrl;
        res.end(JSON.stringify({ version: skill.currentVersionId, endpointUrl: json.endpointUrl }));
        return;
      }

      // ── Sessions: create ──
      if (method === "POST" && url.match(/^\/api\/me\/skills\/.+\/sessions$/)) {
        const sessionId = `sess_${Date.now()}`;
        state.sessions.push({ id: sessionId, entryParams: json.entryParams });
        res.statusCode = 201;
        res.end(JSON.stringify({ id: sessionId }));
        return;
      }

      // ── Sessions: list ──
      if (method === "GET" && url.match(/^\/api\/me\/skills\/.+\/sessions/)) {
        res.end(JSON.stringify({ items: state.sessions, cursor: null }));
        return;
      }

      res.statusCode = 404;
      res.end(JSON.stringify({ code: "NOT_FOUND", message: "Unknown endpoint" }));
    });
  });

  return { server, state };
}

// ── MCP Client (reuse from mcp-server.test.js) ──

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
    this.proc.stderr.on("data", () => {});

    const initResult = await this.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "test-client", version: "0.1.0" },
    });
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
    return this.request("tools/call", { name, arguments: args });
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
          if (msg.error) reject(new Error(msg.error.message));
          else resolve(msg.result);
        }
      } catch {}
    }
  }
}

// ── Helper ──

function getText(result) {
  return result.content[0].text;
}

// ══════════════════════════════════════════════════════
// Integration Tests
// ══════════════════════════════════════════════════════

describe("Flow 1: 注册 → 登录 → 查看状态", () => {
  let mockApi, apiPort, client, tmpHome;

  before(async () => {
    mockApi = createMockApi();
    await new Promise((resolve) => {
      mockApi.server.listen(0, () => {
        apiPort = mockApi.server.address().port;
        resolve();
      });
    });
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "integ-"));
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: `http://127.0.0.1:${apiPort}`,
      HOME: tmpHome,
    });
  });

  after(async () => {
    await client.stop();
    mockApi.server.close();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("1. 初始状态：未登录", async () => {
    const r = await client.callTool("auth_status");
    assert.ok(getText(r).includes("未登录"));
  });

  it("2. 发送验证码", async () => {
    const r = await client.callTool("auth_vcode", {
      channel: "phone",
      target: "+8613800000001",
      purpose: "register",
    });
    assert.ok(getText(r).includes("已发送"));
  });

  it("3. 用错误验证码注册 → 失败", async () => {
    const r = await client.callTool("auth_register", {
      channel: "phone",
      target: "+8613800000001",
      code: "000000",
    });
    assert.ok(getText(r).includes("失败"));
  });

  it("4. 用正确验证码注册 → 成功", async () => {
    const r = await client.callTool("auth_register", {
      channel: "phone",
      target: "+8613800000001",
      code: "123456",
    });
    const text = getText(r);
    assert.ok(text.includes("注册成功"), `Expected '注册成功' in: ${text}`);
  });

  it("5. 注册后自动登录 → auth_status 返回用户信息", async () => {
    const r = await client.callTool("auth_status");
    const text = getText(r);
    const data = JSON.parse(text);
    assert.equal(data.logged_in, true);
    assert.equal(data.phone, "+8613800000001");
  });

  it("6. 凭证文件已写入", async () => {
    const credPath = path.join(tmpHome, ".minus", "credentials.json");
    const cred = JSON.parse(await fs.readFile(credPath, "utf8"));
    assert.ok(cred.session_id, "should have session_id");
    assert.ok(cred.user_id, "should have user_id");
    assert.ok(cred.team_id, "should have team_id");
  });
});

describe("Flow 2: 登录 → 创建 Skill → 查询列表", () => {
  let mockApi, apiPort, client, tmpHome;

  before(async () => {
    mockApi = createMockApi();
    await new Promise((resolve) => {
      mockApi.server.listen(0, () => {
        apiPort = mockApi.server.address().port;
        resolve();
      });
    });
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "integ-"));
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: `http://127.0.0.1:${apiPort}`,
      HOME: tmpHome,
    });

    // Pre-login
    await client.callTool("auth_vcode", {
      channel: "phone",
      target: "+8613800000001",
      purpose: "login",
    });
    await client.callTool("auth_login", {
      grantType: "phone_code",
      identifier: "+8613800000001",
      credential: "123456",
    });
  });

  after(async () => {
    await client.stop();
    mockApi.server.close();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("1. 登录后 skill_list 返回空数组", async () => {
    const r = await client.callTool("skill_list");
    const data = JSON.parse(getText(r));
    assert.ok(Array.isArray(data));
    assert.equal(data.length, 0);
  });

  it("2. skill_create MCP tool 已移除", async () => {
    const tools = await client.request("tools/list", {});
    const names = tools.tools.map((t) => t.name);
    assert.ok(!names.includes("skill_create"), "skill_create should not exist");
  });

  it("3. 通过 mock API 直接注册 Skill 后 skill_list 能查到", async () => {
    // 模拟 create-skill CLI 往后端注册的效果
    mockApi.state.skills.push({
      id: "sk_test1", currentVersionId: "ver_1", apiKey: "ak_test1",
      displayName: "关键词调研", description: "帮你做亚马逊关键词调研", version: "1.0.0",
    });
    mockApi.state.skills.push({
      id: "sk_test2", currentVersionId: "ver_1", apiKey: "ak_test2",
      displayName: "竞品监控", description: "自动监控竞品动态", version: "0.1.0",
    });

    const r = await client.callTool("skill_list");
    const data = JSON.parse(getText(r));
    assert.equal(data.length, 2);
    assert.equal(data[0].displayName, "关键词调研");
    assert.equal(data[1].displayName, "竞品监控");
  });
});

describe("Flow 3: 创建 Skill → 设置 Endpoint → 创建 Session", () => {
  let mockApi, apiPort, client, tmpHome;
  let skillId;

  before(async () => {
    mockApi = createMockApi();
    await new Promise((resolve) => {
      mockApi.server.listen(0, () => {
        apiPort = mockApi.server.address().port;
        resolve();
      });
    });
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "integ-"));
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: `http://127.0.0.1:${apiPort}`,
      HOME: tmpHome,
    });

    // Pre-login
    await client.callTool("auth_vcode", {
      channel: "phone",
      target: "+8613800000002",
      purpose: "register",
    });
    await client.callTool("auth_register", {
      channel: "phone",
      target: "+8613800000002",
      code: "123456",
    });
    // 模拟 create-skill CLI 注册 Skill
    skillId = "sk_flow3";
    mockApi.state.skills.push({
      id: skillId, currentVersionId: "ver_1", apiKey: "ak_flow3",
      displayName: "测试 Skill", description: "E2E 测试", version: "1.0.0",
    });
  });

  after(async () => {
    await client.stop();
    mockApi.server.close();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("1. Skill 已注册", () => {
    assert.ok(skillId, "Should have skillId");
  });

  it("2. 设置 Endpoint", async () => {
    const r = await client.callTool("skill_endpoint_set", {
      skillId,
      endpointUrl: "https://my-skill.example.com",
    });
    const text = getText(r);
    assert.ok(text.includes("已更新"), `Expected '已更新' in: ${text}`);
    assert.ok(text.includes("my-skill.example.com"));
  });

  it("3. 创建运行 Session", async () => {
    const r = await client.callTool("session_create", {
      skillId,
      entryParams: { keyword: "wireless earbuds", market: "US" },
    });
    const text = getText(r);
    assert.ok(text.includes("Session 已创建"), `Expected 'Session 已创建' in: ${text}`);
    assert.ok(text.includes("sess_"));
  });

  it("4. 查询 Session 列表", async () => {
    const r = await client.callTool("session_list", {
      skillId,
    });
    const data = JSON.parse(getText(r));
    assert.ok(data.items.length >= 1, "Should have at least 1 session");
    assert.equal(data.items[0].entryParams.keyword, "wireless earbuds");
  });
});

describe("Flow 3b: skill_update — 三步法写入 input/steps", () => {
  let mockApi, apiPort, client, tmpHome;
  const skillId = "sk_update_test";

  before(async () => {
    mockApi = createMockApi();
    await new Promise((resolve) => {
      mockApi.server.listen(0, () => {
        apiPort = mockApi.server.address().port;
        resolve();
      });
    });
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "integ-"));
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: `http://127.0.0.1:${apiPort}`,
      HOME: tmpHome,
    });

    // Pre-login
    await client.callTool("auth_vcode", {
      channel: "phone",
      target: "+8613800000010",
      purpose: "register",
    });
    await client.callTool("auth_register", {
      channel: "phone",
      target: "+8613800000010",
      code: "123456",
    });

    // Pre-create skill in mock state
    mockApi.state.skills.push({
      id: skillId, currentVersionId: "ver_1", apiKey: "ak_test",
      displayName: "关键词调研", description: "测试", version: "1.0.0",
    });
  });

  after(async () => {
    await client.stop();
    mockApi.server.close();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("1. 写入输入定义", async () => {
    const r = await client.callTool("skill_update", {
      skillId,
      updates: {
        input: {
          type: "keyword",
          label: "主关键词",
          placeholder: "如：wireless earbuds",
          required: true,
        },
      },
    });
    assert.ok(getText(r).includes("已更新"));
    const skill = mockApi.state.skills.find((s) => s.id === skillId);
    assert.equal(skill.input.type, "keyword");
    assert.equal(skill.input.label, "主关键词");
  });

  it("2. 写入步骤结构", async () => {
    const r = await client.callTool("skill_update", {
      skillId,
      updates: {
        steps: [
          { stepNumber: 1, stepName: "关键词数据采集", status: "pending" },
          { stepNumber: 2, stepName: "竞争度分析", status: "pending" },
          { stepNumber: 3, stepName: "长尾词推荐", status: "pending" },
        ],
      },
    });
    assert.ok(getText(r).includes("已更新"));
    const skill = mockApi.state.skills.find((s) => s.id === skillId);
    assert.equal(skill.steps.length, 3);
    assert.equal(skill.steps[0].stepName, "关键词数据采集");
  });

  it("3. 更新步骤状态（节点开发完成）", async () => {
    const r = await client.callTool("skill_update", {
      skillId,
      updates: {
        steps: [
          { stepNumber: 1, stepName: "关键词数据采集", status: "completed" },
          { stepNumber: 2, stepName: "竞争度分析", status: "in_progress" },
          { stepNumber: 3, stepName: "长尾词推荐", status: "pending" },
        ],
      },
    });
    assert.ok(getText(r).includes("已更新"));
    const skill = mockApi.state.skills.find((s) => s.id === skillId);
    assert.equal(skill.steps[0].status, "completed");
    assert.equal(skill.steps[1].status, "in_progress");
  });

  it("4. 更新不存在的 Skill 返回错误", async () => {
    const r = await client.callTool("skill_update", {
      skillId: "sk_nonexistent",
      updates: { displayName: "test" },
    });
    assert.ok(getText(r).includes("失败") || getText(r).includes("不存在"));
  });
});

describe("Flow 4: 登出 → 再登录", () => {
  let mockApi, apiPort, client, tmpHome;

  before(async () => {
    mockApi = createMockApi();
    await new Promise((resolve) => {
      mockApi.server.listen(0, () => {
        apiPort = mockApi.server.address().port;
        resolve();
      });
    });
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "integ-"));
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: `http://127.0.0.1:${apiPort}`,
      HOME: tmpHome,
    });

    // Register first
    await client.callTool("auth_vcode", {
      channel: "phone",
      target: "+8613800000003",
      purpose: "register",
    });
    await client.callTool("auth_register", {
      channel: "phone",
      target: "+8613800000003",
      code: "123456",
    });
  });

  after(async () => {
    await client.stop();
    mockApi.server.close();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("1. 确认已登录", async () => {
    const r = await client.callTool("auth_status");
    const data = JSON.parse(getText(r));
    assert.equal(data.logged_in, true);
  });

  it("2. 登出", async () => {
    const r = await client.callTool("auth_logout");
    assert.ok(getText(r).includes("已登出"));
  });

  it("3. 登出后 auth_status 显示未登录", async () => {
    const r = await client.callTool("auth_status");
    assert.ok(getText(r).includes("未登录"));
  });

  it("4. 登出后 skill_list 被拒绝", async () => {
    const r = await client.callTool("skill_list");
    assert.ok(getText(r).includes("未登录"));
  });

  it("5. 重新登录", async () => {
    await client.callTool("auth_vcode", {
      channel: "phone",
      target: "+8613800000003",
      purpose: "login",
    });
    const r = await client.callTool("auth_login", {
      grantType: "phone_code",
      identifier: "+8613800000003",
      credential: "123456",
    });
    assert.ok(getText(r).includes("登录成功"));
  });

  it("6. 重新登录后 skill_list 正常", async () => {
    const r = await client.callTool("skill_list");
    const data = JSON.parse(getText(r));
    assert.ok(Array.isArray(data));
  });
});

describe("Flow 5: project-detector → MCP 联动（完整初始化场景）", () => {
  let mockApi, apiPort, tmpHome, tmpProject;

  before(async () => {
    mockApi = createMockApi();
    await new Promise((resolve) => {
      mockApi.server.listen(0, () => {
        apiPort = mockApi.server.address().port;
        resolve();
      });
    });
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "integ-"));
    tmpProject = path.join(tmpHome, "minus", "test-skill");
  });

  after(async () => {
    mockApi.server.close();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("1. project-detector 在空目录下输出「不是 Minus 项目」", async () => {
    await fs.mkdir(path.join(tmpHome, ".minus"), { recursive: true });
    const PD = path.resolve(
      import.meta.dirname,
      "../plugins/claude/minus-creator/lib/project-detector.sh"
    );
    const { stdout } = await runBash(`HOME="${tmpHome}" bash "${PD}"`, tmpHome);
    assert.ok(stdout.includes("当前目录不是 Minus 项目"));
    assert.ok(stdout.includes("登录状态：false"));
  });

  it("2. 写入凭证后 project-detector 检测为已登录", async () => {
    // Register via MCP to get real session, then write creds
    const client = new McpClient();
    await client.start({
      MINUS_API_BASE: `http://127.0.0.1:${apiPort}`,
      HOME: tmpHome,
    });
    await client.callTool("auth_vcode", {
      channel: "phone",
      target: "+8613800000004",
      purpose: "register",
    });
    await client.callTool("auth_register", {
      channel: "phone",
      target: "+8613800000004",
      code: "123456",
    });
    await client.stop();

    const PD = path.resolve(
      import.meta.dirname,
      "../plugins/claude/minus-creator/lib/project-detector.sh"
    );
    const { stdout } = await runBash(`HOME="${tmpHome}" bash "${PD}"`, tmpHome);
    assert.ok(stdout.includes("登录状态：true"), `Expected 登录状态：true in: ${stdout}`);
  });

  it("3. 创建 Skill 项目目录后 project-detector 识别为项目", async () => {
    await fs.mkdir(path.join(tmpProject, ".minus"), { recursive: true });
    await fs.writeFile(
      path.join(tmpProject, ".minus", "skill.json"),
      JSON.stringify({ skillId: "sk_e2e_test", displayName: "E2E Test" })
    );

    const PD = path.resolve(
      import.meta.dirname,
      "../plugins/claude/minus-creator/lib/project-detector.sh"
    );
    const { stdout } = await runBash(`HOME="${tmpHome}" bash "${PD}"`, tmpProject);
    assert.ok(
      stdout.includes("当前目录是 Minus Skill 项目"),
      `Expected project detection in: ${stdout}`
    );
    assert.ok(stdout.includes("sk_e2e_test"));
  });

  it("4. 在 Workspace 目录下检测到子项目", async () => {
    const wsDir = path.join(tmpHome, "minus");
    await fs.mkdir(wsDir, { recursive: true });
    await fs.writeFile(path.join(wsDir, ".minus-workspace"), "");

    const PD = path.resolve(
      import.meta.dirname,
      "../plugins/claude/minus-creator/lib/project-detector.sh"
    );
    const { stdout } = await runBash(`HOME="${tmpHome}" bash "${PD}"`, wsDir);
    assert.ok(stdout.includes("Workspace") || stdout.includes("test-skill"));
  });
});

describe("Flow 6: MCP 登录 → create-skill 共享凭证 → scaffold", () => {
  let mockApi, apiPort, client, tmpHome, tmpWorkspace, fakeBinDir;

  before(async () => {
    mockApi = createMockApi();
    await new Promise((resolve) => {
      mockApi.server.listen(0, () => {
        apiPort = mockApi.server.address().port;
        resolve();
      });
    });
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "integ-"));
    tmpWorkspace = path.join(tmpHome, "minus");
    await fs.mkdir(tmpWorkspace, { recursive: true });

    // Create fake uv/npm to skip slow dependency install
    fakeBinDir = path.join(tmpHome, "fakebin");
    await fs.mkdir(fakeBinDir, { recursive: true });
    await fs.writeFile(path.join(fakeBinDir, "uv"), '#!/bin/bash\necho "fake uv ok"', { mode: 0o755 });
    await fs.writeFile(path.join(fakeBinDir, "npm"), '#!/bin/bash\necho "fake npm ok"', { mode: 0o755 });

    // Login via MCP
    client = new McpClient();
    await client.start({
      MINUS_API_BASE: `http://127.0.0.1:${apiPort}`,
      HOME: tmpHome,
    });
    await client.callTool("auth_vcode", {
      channel: "phone",
      target: "+8613800000005",
      purpose: "register",
    });
    await client.callTool("auth_register", {
      channel: "phone",
      target: "+8613800000005",
      code: "123456",
    });
  });

  after(async () => {
    await client.stop();
    mockApi.server.close();
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("1. MCP 登录后凭证文件格式正确", async () => {
    const credPath = path.join(tmpHome, ".minus", "credentials.json");
    const creds = JSON.parse(await fs.readFile(credPath, "utf8"));
    assert.ok(creds.session_id, "should have session_id");
    assert.ok(creds.user_id, "should have user_id");
    assert.ok(creds.api_base, "should have api_base");
  });

  it("2. create-skill check-session 能读到 MCP 写的凭证", async () => {
    const { stdout } = await runBash(
      `HOME="${tmpHome}" create-skill check-session --platform "http://127.0.0.1:${apiPort}"`,
      tmpWorkspace
    );
    const result = JSON.parse(stdout.trim());
    assert.equal(result.ok, true, `Expected ok:true, got: ${stdout}`);
    assert.ok(result.sid, "should return sid");
  });

  it("3. create-skill 非交互模式创建项目（scaffold 产物验证）", async () => {
    // PATH 前置 fake bin，跳过 uv venv / npm install
    await runBash(
      `HOME="${tmpHome}" PATH="${fakeBinDir}:$PATH" create-skill "测试Skill" --platform "http://127.0.0.1:${apiPort}" --non-interactive 2>&1`,
      tmpWorkspace
    );

    // 即使 uv 是假的，文件应该已经生成（create-skill 先写文件再装依赖）
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测試Skill") || d.includes("测试Skill") || d.startsWith("sk_"));
    assert.ok(skillDir, `Expected skill dir in ${tmpWorkspace}, found: ${dirs}`);
    // folder 应该基于 displayName，不是 skillId
    assert.ok(!skillDir.startsWith("sk_"), `Folder should be displayName-based, not skillId: ${skillDir}`);
  });

  it("3b. 后端确实注册了 Skill（mock API state 验证）", () => {
    assert.ok(mockApi.state.skills.length >= 1, "Backend should have at least 1 skill");
    const skill = mockApi.state.skills[mockApi.state.skills.length - 1];
    assert.equal(skill.displayName, "测试Skill", "Backend skill displayName should match");
    assert.ok(skill.id, "Backend skill should have id");
    assert.ok(skill.apiKey, "Backend skill should have apiKey");
  });

  it("4. scaffold 产物：.minus/skill.json 的 skillId 与后端一致", async () => {
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测试Skill") || d.startsWith("sk_"));

    const skillJson = JSON.parse(
      await fs.readFile(path.join(tmpWorkspace, skillDir, ".minus", "skill.json"), "utf8")
    );
    assert.ok(skillJson.skillId, "skill.json should have skillId");

    // 与后端注册的 skillId 一致
    const backendSkill = mockApi.state.skills[mockApi.state.skills.length - 1];
    assert.equal(skillJson.skillId, backendSkill.id, "Local skillId should match backend");
  });

  it("5. scaffold 产物：pipeline.py 存在", async () => {
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测试Skill") || d.startsWith("sk_"));
    await fs.access(path.join(tmpWorkspace, skillDir, "pipeline.py"));
  });

  it("6. scaffold 产物：前端代码存在", async () => {
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测试Skill") || d.startsWith("sk_"));
    await fs.access(path.join(tmpWorkspace, skillDir, "frontend", "src", "main.tsx"));
  });

  it("6a. scaffold 产物：CLAUDE.md 存在且内容正确", async () => {
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测试Skill") || d.startsWith("sk_"));
    const content = await fs.readFile(path.join(tmpWorkspace, skillDir, "CLAUDE.md"), "utf8");
    assert.ok(content.includes("测试Skill"), "CLAUDE.md should contain project name");
    assert.ok(content.includes("/minus"), "CLAUDE.md should list /minus command");
    assert.ok(content.includes(".minus/skill.json"), "CLAUDE.md should reference skill.json");
  });

  it("6b-1. scaffold 产物：frontend/assets/ 和 tests/ 目录存在", async () => {
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测试Skill") || d.startsWith("sk_"));
    const base = path.join(tmpWorkspace, skillDir);
    await fs.access(path.join(base, "frontend", "assets", ".gitkeep"));
    await fs.access(path.join(base, "tests", ".gitkeep"));
  });

  it("6b. scaffold 产物完整性：server.py、pyproject.toml、.gitignore、.env.local", async () => {
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测试Skill") || d.startsWith("sk_"));
    const base = path.join(tmpWorkspace, skillDir);
    await fs.access(path.join(base, "server.py"));
    await fs.access(path.join(base, "pyproject.toml"));
    await fs.access(path.join(base, ".gitignore"));
    const envLocal = await fs.readFile(path.join(base, ".env.local"), "utf8");
    assert.ok(envLocal.includes("MINUS_AI_SKILL_API_KEY="), "should contain api key");
  });

  it("7. project-detector 识别 scaffold 产物为 Skill 项目", async () => {
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测试Skill") || d.startsWith("sk_"));
    const projectPath = path.join(tmpWorkspace, skillDir);

    const PD = path.resolve(
      import.meta.dirname,
      "../plugins/claude/minus-creator/lib/project-detector.sh"
    );
    const { stdout } = await runBash(`HOME="${tmpHome}" bash "${PD}"`, projectPath);
    assert.ok(
      stdout.includes("当前目录是 Minus Skill 项目"),
      `Expected project detection in: ${stdout}`
    );
  });

  it("8. project-detector 环境检查：已登录 + 有 package.json 无 node_modules → 提示安装依赖", async () => {
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测试Skill") || d.startsWith("sk_"));
    const projectPath = path.join(tmpWorkspace, skillDir);

    // scaffold 生成了 package.json 但 fake npm 没有真的装 node_modules
    const PD = path.resolve(
      import.meta.dirname,
      "../plugins/claude/minus-creator/lib/project-detector.sh"
    );
    const { stdout } = await runBash(`HOME="${tmpHome}" bash "${PD}"`, projectPath);
    assert.ok(stdout.includes("已登录"), `Expected 已登录 in: ${stdout}`);
    assert.ok(
      stdout.includes("需要安装") || stdout.includes("已就绪"),
      `Expected dependency status in: ${stdout}`
    );
  });

  it("9. project-detector 环境检查：首次进入标记正确", async () => {
    const dirs = await fs.readdir(tmpWorkspace);
    const skillDir = dirs.find((d) => d.includes("测试Skill") || d.startsWith("sk_"));
    const projectPath = path.join(tmpWorkspace, skillDir);

    const PD = path.resolve(
      import.meta.dirname,
      "../plugins/claude/minus-creator/lib/project-detector.sh"
    );
    const { stdout } = await runBash(`HOME="${tmpHome}" bash "${PD}"`, projectPath);
    assert.ok(
      stdout.includes("首次进入：true"),
      `Expected first entry flag in: ${stdout}`
    );
  });
});

describe("Flow 7: create-skill 注册失败场景", () => {
  let tmpHome, tmpWorkspace;

  before(async () => {
    tmpHome = await fs.mkdtemp(path.join(os.tmpdir(), "integ-"));
    tmpWorkspace = path.join(tmpHome, "minus");
    await fs.mkdir(tmpWorkspace, { recursive: true });
    // 写入凭证（指向不存在的服务）
    const minusDir = path.join(tmpHome, ".minus");
    await fs.mkdir(minusDir, { recursive: true });
    await fs.writeFile(
      path.join(minusDir, "credentials.json"),
      JSON.stringify({ session_id: "fake", user_id: "u1", team_id: "t1", api_base: "http://127.0.0.1:1" })
    );
  });

  after(async () => {
    await fs.rm(tmpHome, { recursive: true, force: true });
  });

  it("1. 网络不通时 create-skill 报错中止，不生成文件", async () => {
    const { stdout, code } = await runBash(
      `HOME="${tmpHome}" create-skill "失败测试" --platform "http://127.0.0.1:1" --sid "fake-sid" --non-interactive 2>&1`,
      tmpWorkspace
    );
    assert.notEqual(code, 0, "Should exit with non-zero code");
    assert.ok(
      stdout.includes("无效") || stdout.includes("过期") || stdout.includes("登录"),
      `Expected auth/network error in: ${stdout}`
    );
    const dirs = await fs.readdir(tmpWorkspace);
    assert.equal(dirs.length, 0, `Should not create any files, found: ${dirs}`);
  });

  it("2. 服务器 500 时 create-skill 报错中止", async () => {
    // /api/me 返回 200（session 有效），/api/skills 返回 500
    const badServer = http.createServer((req, res) => {
      if (req.url === "/api/me") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ userId: "u1", nickname: "test" }));
        return;
      }
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ code: "INTERNAL_ERROR", message: "Internal server error" }));
    });
    const port = await new Promise((resolve) => {
      badServer.listen(0, () => resolve(badServer.address().port));
    });

    try {
      const { stdout, code } = await runBash(
        `HOME="${tmpHome}" create-skill "失败测试500" --platform "http://127.0.0.1:${port}" --sid "fake-sid" --non-interactive 2>&1`,
        tmpWorkspace
      );
      assert.notEqual(code, 0, "Should exit with non-zero code");
      assert.ok(
        stdout.includes("平台暂时有问题") || stdout.includes("稍后重试"),
        `Expected server error message in: ${stdout}`
      );
    } finally {
      badServer.close();
    }
  });
});

// ── Bash helper ──

function runBash(command, cwd) {
  return new Promise((resolve, reject) => {
    const proc = spawn("bash", ["-c", command], {
      cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d));
    proc.stderr.on("data", (d) => (stderr += d));
    proc.on("close", (code) => resolve({ stdout, stderr, code }));
    proc.on("error", reject);
  });
}
