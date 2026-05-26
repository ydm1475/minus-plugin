import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "fs/promises";
import path from "path";
import os from "os";
import { ZipArchive } from "archiver";

const API_BASE = process.env.MINUS_API_BASE || "http://47.107.144.22:18990";
const CREDENTIALS_PATH = path.join(os.homedir(), ".minus", "credentials.json");

// ─── Credential Management ───

async function loadCredentials() {
  try {
    const data = await fs.readFile(CREDENTIALS_PATH, "utf8");
    return JSON.parse(data);
  } catch {
    return null;
  }
}

async function saveCredentials(creds) {
  const dir = path.dirname(CREDENTIALS_PATH);
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(CREDENTIALS_PATH, JSON.stringify(creds, null, 2), "utf8");
}

async function clearCredentials() {
  try {
    await fs.unlink(CREDENTIALS_PATH);
  } catch {}
}

function extractSessionCookie(headers) {
  const setCookie = headers.get("set-cookie") || "";
  const match = setCookie.match(/MINUS_AI_SID=([^;]+)/);
  return match ? match[1] : null;
}

// ─── Dev Session Refresh ───

async function refreshDevSession(apiKey) {
  try {
    const response = await fetch(`${API_BASE}/api/auth/dev-session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ apiKey }),
    });
    if (response.status === 204) {
      const sessionId = extractSessionCookie(response.headers);
      if (sessionId) {
        const creds = await loadCredentials();
        if (creds) {
          creds.session_id = sessionId;
          await saveCredentials(creds);
        }
        return sessionId;
      }
    }
  } catch {}
  return null;
}

// ─── HTTP Client ───

async function apiRequest(method, endpoint, { body, needsAuth = true, _retried = false } = {}) {
  const url = `${API_BASE}${endpoint}`;
  const headers = { "Content-Type": "application/json" };

  let creds = null;
  if (needsAuth) {
    creds = await loadCredentials();
    if (!creds?.session_id) {
      return {
        error: true,
        code: "NOT_LOGGED_IN",
        message: "未登录。请先使用 auth_dev_session 工具输入开发者 API Key。",
      };
    }
    headers["Cookie"] = `MINUS_AI_SID=${creds.session_id}`;
  }

  const options = { method, headers };
  if (body) options.body = JSON.stringify(body);

  let response;
  try {
    response = await fetch(url, options);
  } catch (err) {
    return {
      error: true,
      code: "NETWORK_ERROR",
      message: `网络连接失败：${err.message}`,
    };
  }

  const sessionId = extractSessionCookie(response.headers);

  if (response.status === 204) {
    return { ok: true, sessionId };
  }

  let data;
  try {
    data = await response.json();
  } catch {
    data = null;
  }

  if (!response.ok) {
    if (response.status === 401 && !_retried && creds?.auth_type === "api_key" && creds?.api_key) {
      const newSessionId = await refreshDevSession(creds.api_key);
      if (newSessionId) {
        return apiRequest(method, endpoint, { body, needsAuth, _retried: true });
      }
      await clearCredentials();
      return {
        error: true,
        code: "SESSION_EXPIRED",
        message: "API Key 已失效，请重新输入。",
      };
    }

    return {
      error: true,
      status: response.status,
      code: data?.code || "UNKNOWN",
      message: data?.message || `HTTP ${response.status}`,
      details: data?.details,
      sessionId,
    };
  }

  return { ok: true, data, sessionId };
}

// ─── Version Recovery ───

async function ensureDraftVersion(skillId, currentVersion, projectDir) {
  const check = await apiRequest("GET", `/api/skills/${skillId}/versions/${currentVersion}`);
  if (check.ok && check.data.status === "draft") {
    return { version: currentVersion, changed: false };
  }

  const create = await apiRequest("POST", `/api/skills/${skillId}/versions`);
  if (create.error) return { error: true, message: create.message };
  const newVersion = create.data.draftVersion;

  if (projectDir) {
    const skillJsonPath = path.join(projectDir, ".minus", "skill.json");
    try {
      const raw = await fs.readFile(skillJsonPath, "utf8");
      const skillJson = JSON.parse(raw);
      skillJson.version = newVersion;
      await fs.writeFile(skillJsonPath, JSON.stringify(skillJson, null, 2) + "\n");
    } catch {}

    try {
      const pidFile = path.join(projectDir, ".minus", "dev.pid");
      const raw = await fs.readFile(pidFile, "utf8");
      const pid = parseInt(raw.trim(), 10);
      if (pid > 0) {
        try { process.kill(-pid, "SIGTERM"); } catch {
          try { process.kill(pid, "SIGTERM"); } catch {}
        }
      }
      await fs.unlink(pidFile).catch(() => {});
      await fs.unlink(path.join(projectDir, ".minus", "dev-ports.json")).catch(() => {});
    } catch {}
  }

  return { version: newVersion, changed: true };
}

// ─── MCP Server ───

const server = new McpServer({
  name: "minus-platform",
  version: "0.1.0",
});

// ── Auth Tools ──

server.tool(
  "auth_vcode",
  "发送验证码到手机（用于注册或登录）",
  {
    channel: z.enum(["phone"]).describe("验证码发送渠道（仅支持手机）"),
    target: z.string().describe("手机号（E.164 格式如 +8613800000000）"),
    purpose: z
      .enum(["register", "login", "reset", "bind"])
      .describe("用途"),
  },
  async ({ channel, target, purpose }) => {
    const result = await apiRequest("POST", "/api/auth/vcode/send", {
      body: { channel, target, purpose },
      needsAuth: false,
    });

    if (result.error) {
      return {
        content: [
          {
            type: "text",
            text: `发送验证码失败：${result.message}`,
          },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: `验证码已发送到 ${target}。请让 Creator 查收并提供验证码。`,
        },
      ],
    };
  }
);

server.tool(
  "auth_register",
  "注册新 Minus 账户（注册即登录）",
  {
    channel: z.enum(["phone"]).describe("注册通道（仅支持手机）"),
    target: z.string().describe("手机号（E.164 格式如 +8613800000000）"),
    code: z.string().describe("6 位数字验证码"),
    password: z
      .string()
      .optional()
      .describe("密码（可选，不传则仅验证码登录模式）"),
  },
  async ({ channel, target, code, password }) => {
    const body = { channel, target, code };
    if (password) body.password = password;

    const result = await apiRequest("POST", "/api/auth/register", {
      body,
      needsAuth: false,
    });

    if (result.error) {
      return {
        content: [
          {
            type: "text",
            text: `注册失败：${result.message}`,
          },
        ],
      };
    }

    if (result.sessionId) {
      await saveCredentials({
        session_id: result.sessionId,
        user_id: result.data.userId,
        team_id: result.data.personalTeamId,
        api_base: API_BASE,
      });
    }

    return {
      content: [
        {
          type: "text",
          text: `注册成功！用户 ID: ${result.data.userId}。已自动登录。`,
        },
      ],
    };
  }
);

server.tool(
  "auth_login",
  "登录 Minus 平台（支持手机号 + 密码/验证码）",
  {
    grantType: z
      .enum(["phone_password", "phone_code"])
      .describe("登录方式"),
    identifier: z.string().describe("手机号（E.164 格式如 +8613800000000）"),
    credential: z.string().describe("密码或 6 位验证码"),
    rememberMe: z
      .boolean()
      .optional()
      .default(true)
      .describe("记住登录状态（默认 true，30 天有效）"),
  },
  async ({ grantType, identifier, credential, rememberMe }) => {
    const result = await apiRequest("POST", "/api/auth/login", {
      body: { grantType, identifier, credential, rememberMe },
      needsAuth: false,
    });

    if (result.error) {
      const hints = {
        PASSWORD_INCORRECT: "密码错误，请重试。",
        IDENTITY_NOT_FOUND: "该账号未注册，需要先注册。",
        ACCOUNT_LOCKED: "账户被锁定，请稍后重试。",
        VCODE_INVALID: "验证码错误，请重新输入。",
        VCODE_EXPIRED: "验证码已过期，请重新发送。",
      };
      const hint = hints[result.code] || result.message;
      return {
        content: [{ type: "text", text: `登录失败：${hint}` }],
      };
    }

    if (result.sessionId) {
      await saveCredentials({
        session_id: result.sessionId,
        user_id: result.data.userId,
        team_id: result.data.currentTeamId,
        api_base: API_BASE,
      });
    }

    return {
      content: [
        {
          type: "text",
          text: `登录成功！用户 ID: ${result.data.userId}`,
        },
      ],
    };
  }
);

server.tool(
  "auth_status",
  "检查当前登录状态和用户信息",
  {},
  async () => {
    const creds = await loadCredentials();
    if (!creds?.session_id) {
      return {
        content: [
          {
            type: "text",
            text: "未登录。请使用 auth_dev_session 输入开发者 API Key。",
          },
        ],
      };
    }

    const result = await apiRequest("GET", "/api/me");

    if (result.error) {
      if (result.code === "UNAUTHORIZED") {
        await clearCredentials();
        return {
          content: [
            {
              type: "text",
              text: "登录已过期，请重新登录。",
            },
          ],
        };
      }
      return {
        content: [
          { type: "text", text: `查询失败：${result.message}` },
        ],
      };
    }

    const user = result.data;
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              logged_in: true,
              user_id: user.userId,
              nickname: user.nickname,
              phone: user.primaryPhone,
              email: user.primaryEmail,
              team: user.currentTeam?.name,
              plan: user.currentTeam?.plan,
              phone_required: user.phoneRequired,
            },
            null,
            2
          ),
        },
      ],
    };
  }
);

server.tool(
  "auth_logout",
  "登出 Minus 平台",
  {},
  async () => {
    await apiRequest("POST", "/api/auth/logout");
    await clearCredentials();
    return {
      content: [{ type: "text", text: "已登出。" }],
    };
  }
);

server.tool(
  "auth_dev_session",
  "使用开发者 API Key 登录 Minus 平台",
  {
    apiKey: z.string().regex(/^mdk_[A-Za-z0-9]{30,80}$/).describe("开发者 API Key（mdk_ 开头）"),
  },
  async ({ apiKey }) => {
    const result = await apiRequest("POST", "/api/auth/dev-session", {
      body: { apiKey },
      needsAuth: false,
    });

    if (result.error) {
      const hint = result.status === 401
        ? "API Key 无效，请检查后重新输入。"
        : result.message;
      return {
        content: [{ type: "text", text: `验证失败：${hint}` }],
      };
    }

    const sessionId = result.sessionId || apiKey;

    const tmpCreds = { auth_type: "api_key", api_key: apiKey, session_id: sessionId, api_base: API_BASE };
    await saveCredentials(tmpCreds);

    const meResult = await apiRequest("GET", "/api/me");
    const user = meResult.ok ? meResult.data : {};

    await saveCredentials({
      auth_type: "api_key",
      api_key: apiKey,
      session_id: sessionId,
      user_id: user.userId || "",
      display_name: user.nickname || user.primaryEmail || "",
      email: user.primaryEmail || "",
      api_base: API_BASE,
    });

    const name = user.nickname || user.primaryEmail || user.userId || "";
    return {
      content: [{ type: "text", text: `验证成功！欢迎，${name}。` }],
    };
  }
);

// ── Skill Tools ──

server.tool(
  "skill_list",
  "列出当前用户的所有 Skill",
  {},
  async () => {
    const result = await apiRequest("GET", "/api/me/skills");

    if (result.error) {
      return {
        content: [
          { type: "text", text: `查询失败：${result.message}` },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(result.data, null, 2),
        },
      ],
    };
  }
);

// skill_create 已移除 — 创建 Skill 必须通过 Bash 执行 `create-skill` CLI
// create-skill 内部会调用 POST /api/skills 注册并生成项目结构

server.tool(
  "skill_update",
  `编辑草稿版本（PATCH /api/skills/{skillId}/versions/{version}）。
仅 status=draft 的版本可编辑，否则返回 409。
可更新字段：displayName(string)、description(string)、iconFileId(string)、steps(array)、useCases(array)、tags(array)。
steps 格式：[{ stepNumber: 1, stepName: "步骤名" }, ...]，stepNumber 从 1 严格递增。
部分更新：字段缺失则不修改，传值则覆盖。
skillId 和 version 从 .minus/skill.json 读取。
API 文档见 .claude/api/openapi-bundled.yaml`,
  {
    skillId: z.string().describe("Skill ID（如 skl_xxx）"),
    version: z.string().describe("版本号（如 1.0-alpha.1），从 .minus/skill.json 读取"),
    updates: z.record(z.unknown()).describe("要更新的字段，格式参照 PATCH /api/skills/{skillId}/versions/{version} 的 requestBody"),
    projectDir: z.string().optional().describe("Skill 项目根目录的绝对路径（传入后可自动恢复过期版本）"),
  },
  async ({ skillId, version, updates, projectDir }) => {
    let result = await apiRequest("PATCH", `/api/skills/${skillId}/versions/${version}`, {
      body: updates,
    });

    if (result.error && (result.status === 409 || result.status === 404) && projectDir) {
      const recovery = await ensureDraftVersion(skillId, version, projectDir);
      if (recovery.error) {
        return { content: [{ type: "text", text: `更新失败：${recovery.message}` }] };
      }
      if (recovery.changed) {
        result = await apiRequest("PATCH", `/api/skills/${skillId}/versions/${recovery.version}`, {
          body: updates,
        });
        if (result.error) {
          return { content: [{ type: "text", text: `更新失败：${result.message}` }] };
        }
        return {
          content: [
            {
              type: "text",
              text: `Skill 草稿已更新（${recovery.version}）。\n[VERSION_CHANGED] 版本已从 ${version} 升级到 ${recovery.version}，需要重启开发服务器。`,
            },
          ],
        };
      }
    }

    if (result.error) {
      return {
        content: [
          { type: "text", text: `更新失败：${result.message}` },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: `Skill 草稿已更新（${version}）。`,
        },
      ],
    };
  }
);

// skill_endpoint_set 已移除 — PUT /api/admin/skills/{skillId}/endpoint 接口已下线

server.tool(
  "skill_version_get",
  `获取草稿版本详情（GET /api/skills/{skillId}/versions/{version}）。
返回完整元数据：displayName、description、steps、useCases、tags、status、endpointUrl 等。
仅作者或 admin 可调用。
API 文档见 .claude/api/openapi-bundled.yaml`,
  {
    skillId: z.string().describe("Skill ID（如 skl_xxx）"),
    version: z.string().describe("版本号（如 1.0-alpha.1），从 .minus/skill.json 读取"),
  },
  async ({ skillId, version }) => {
    const result = await apiRequest("GET", `/api/skills/${skillId}/versions/${version}`);

    if (result.error) {
      return {
        content: [
          { type: "text", text: `查询失败：${result.message}` },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(result.data, null, 2),
        },
      ],
    };
  }
);

server.tool(
  "skill_version_create",
  `创建新草稿版本（POST /api/skills/{skillId}/versions）。
后端基于当前 PUBLISHED 版本自动 bump，默认 minor +1。
返回新草稿的 draftVersionId、draftVersion、status。
API 文档见 .claude/api/openapi-bundled.yaml`,
  {
    skillId: z.string().describe("Skill ID（如 skl_xxx）"),
    version: z
      .string()
      .optional()
      .describe("目标版本号（如 1.1），仅 major.minor 两段；不传则默认 minor +1"),
  },
  async ({ skillId, version }) => {
    const body = version ? { version } : undefined;
    const result = await apiRequest("POST", `/api/skills/${skillId}/versions`, { body });

    if (result.error) {
      return {
        content: [
          { type: "text", text: `创建版本失败：${result.message}` },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(result.data, null, 2),
        },
      ],
    };
  }
);

server.tool(
  "skill_version_submit",
  `打包项目源码并提交审核（POST /api/skills/{skillId}/versions/submit）。
自动将 projectDir 打包为 zip（排除 node_modules/.git/__pycache__/.venv 等），
上传至后端进行审核。后端自动决策版本号并创建 next draft。
API 文档见 .claude/api/openapi-bundled.yaml`,
  {
    skillId: z.string().describe("Skill ID（如 skl_xxx）"),
    projectDir: z.string().describe("Skill 项目根目录的绝对路径"),
  },
  async ({ skillId, projectDir }) => {
    try {
      await fs.access(path.join(projectDir, ".minus", "skill.json"));
    } catch {
      return {
        content: [
          { type: "text", text: "当前目录不是 Minus Skill 项目（未找到 .minus/skill.json）。" },
        ],
      };
    }

    const creds = await loadCredentials();
    if (!creds?.session_id) {
      return {
        content: [
          { type: "text", text: "未登录，请先登录。" },
        ],
      };
    }

    const zipBuffer = await new Promise((resolve, reject) => {
      const chunks = [];
      const archive = new ZipArchive({ zlib: { level: 9 } });
      archive.on("data", (chunk) => chunks.push(chunk));
      archive.on("end", () => resolve(Buffer.concat(chunks)));
      archive.on("error", reject);
      archive.glob("**/*", {
        cwd: projectDir,
        ignore: [
          "node_modules/**",
          ".git/**",
          "__pycache__/**",
          ".venv/**",
          "*.pyc",
          ".DS_Store",
        ],
        dot: true,
      });
      archive.finalize();
    });

    const formData = new FormData();
    formData.append(
      "sourcePackage",
      new Blob([zipBuffer], { type: "application/zip" }),
      "source.zip"
    );
    let response;
    try {
      response = await fetch(
        `${API_BASE}/api/skills/${skillId}/versions/submit`,
        {
          method: "POST",
          headers: {
            Cookie: `MINUS_AI_SID=${creds.session_id}`,
          },
          body: formData,
        }
      );
    } catch (err) {
      return {
        content: [
          { type: "text", text: `网络连接失败：${err.message}` },
        ],
      };
    }

    if (!response.ok) {
      const err = await response.json().catch(() => null);
      return {
        content: [
          {
            type: "text",
            text: `提交失败：${err?.message || `HTTP ${response.status}`}`,
          },
        ],
      };
    }

    const data = await response.json();

    // 后端已自动创建 next draft，用响应中的 nextDraftVersion 更新本地 skill.json
    if (data.nextDraftVersion && projectDir) {
      const skillJsonPath = path.join(projectDir, ".minus", "skill.json");
      try {
        const raw = await fs.readFile(skillJsonPath, "utf8");
        const skillJson = JSON.parse(raw);
        skillJson.version = data.nextDraftVersion;
        await fs.writeFile(skillJsonPath, JSON.stringify(skillJson, null, 2) + "\n");
      } catch {}
    }

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(data, null, 2),
        },
      ],
    };
  }
);

// ── Session Tools ──

server.tool(
  "session_create",
  "创建 Skill 运行 Session（测试用）",
  {
    skillId: z.string().describe("Skill ID"),
    entryParams: z
      .record(z.unknown())
      .describe("Skill 入参（JSON 对象，透传给 Skill 容器）"),
  },
  async ({ skillId, entryParams }) => {
    const result = await apiRequest(
      "POST",
      `/api/me/skills/${skillId}/sessions`,
      { body: { entryParams } }
    );

    if (result.error) {
      return {
        content: [
          { type: "text", text: `创建 Session 失败：${result.message}` },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: `Session 已创建：${result.data.id}`,
        },
      ],
    };
  }
);

server.tool(
  "session_list",
  "查看 Skill 的历史 Session 列表",
  {
    skillId: z.string().describe("Skill ID"),
    limit: z.number().optional().default(10).describe("每页条数"),
    cursor: z.string().optional().describe("翻页游标"),
  },
  async ({ skillId, limit, cursor }) => {
    let endpoint = `/api/me/skills/${skillId}/sessions?limit=${limit}`;
    if (cursor) endpoint += `&cursor=${encodeURIComponent(cursor)}`;

    const result = await apiRequest("GET", endpoint);

    if (result.error) {
      return {
        content: [
          { type: "text", text: `查询失败：${result.message}` },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(result.data, null, 2),
        },
      ],
    };
  }
);

// ── File Tools ──

server.tool(
  "file_upload",
  "上传文件到 Minus 平台",
  {
    filePath: z.string().describe("本地文件路径"),
  },
  async ({ filePath }) => {
    const creds = await loadCredentials();
    if (!creds?.session_id) {
      return {
        content: [
          { type: "text", text: "未登录，请先登录。" },
        ],
      };
    }

    const fileBuffer = await fs.readFile(filePath);
    const fileName = path.basename(filePath);

    const formData = new FormData();
    formData.append("file", new Blob([fileBuffer]), fileName);

    const response = await fetch(`${API_BASE}/api/me/files`, {
      method: "POST",
      headers: {
        Cookie: `MINUS_AI_SID=${creds.session_id}`,
      },
      body: formData,
    });

    if (!response.ok) {
      const err = await response.json().catch(() => null);
      return {
        content: [
          {
            type: "text",
            text: `上传失败：${err?.message || `HTTP ${response.status}`}`,
          },
        ],
      };
    }

    const data = await response.json();
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(data, null, 2),
        },
      ],
    };
  }
);

// ─── Start Server ───

const transport = new StdioServerTransport();
await server.connect(transport);
