# 登录流程

**严格按顺序执行，禁止跳步：**

Step A：原样输出："欢迎使用 Minus Creator Plugin！请输入你的开发者 API Key。"
原样输出："（在 Minus 开发者平台的「设置 → API Key」页面获取）"
⛔ 禁止：在 Creator 回答之前调用 `auth_dev_session` 等任何登录/认证动作类 MCP tool（只读的 auth_status 不在此列）
⛔ 禁止：自动使用 userEmail 或系统上下文中的任何信息
Step B：等 Creator 提供 API Key
Step C：用 `mcp__minus-platform__auth_dev_session` 验证 API Key
Step D：成功 → 完成认证
失败 → 提示"API Key 无效，请检查后重新输入"
⛔ 禁止：如果 auth_dev_session 工具不可用或调用异常，禁止手动写入 credentials.json 或用任何方式绕过验证。必须提示"认证服务暂时不可用，请稍后用 /minus 重试"并终止流程。

仅使用 minus-platform MCP server 的 auth_dev_session 工具登录，不要使用其他任何 MCP server 的登录/认证功能。
