# SDK 改进建议

来源：Plugin 侧审计，识别出两个应由 SDK 解决的问题。

---

## 1. confirmedKey mismatch 静默失败

**优先级：中高**

### 问题

`defineWidgetStep` 的 `confirmedKey` 如果和后端 payload 的 key 不一致（拼写错误、驼峰/下划线混用），readonly 回放时数据丢失，**没有任何报错或 warning**。

当前代码（`widget-framework/src/defineWidgetStep.tsx` 约第 78 行）：

```typescript
const userVal = ctx.userInput?.[confirmedKey] as C | undefined;
const confirmed = (userVal ?? fallback) as C;
```

`userInput` 里有数据，但 key 名不匹配时：
- `userVal` 得到 `undefined`
- 没有 `confirmedFallback` 时 `confirmed` 直接是 `undefined as C`
- Widget 收到 undefined，渲染空白或异常
- 开发者看不到任何提示，排查成本高

### 典型出错场景

```typescript
// 后端 payload
StepOutcome.input_required(payload={ "selected_keywords": [...] })

// 前端 confirmedKey 拼错了
defineWidgetStep({
  confirmedKey: 'selectedKeywords',  // 驼峰，但后端是下划线
  ...
})
```

结果：交互态正常（因为走的是 onResolve 写入），但回放时读不到数据。

### 建议改法

dev mode 下加 console.warn：

```typescript
// defineWidgetStep.tsx readonly 分支内
if (process.env.NODE_ENV !== 'production'
    && ctx.userInput
    && Object.keys(ctx.userInput).length > 0
    && !(confirmedKey in ctx.userInput)
    && !confirmedFallback) {
  console.warn(
    `[defineWidgetStep] confirmedKey "${confirmedKey}" not found in userInput.\n` +
    `  Available keys: ${Object.keys(ctx.userInput).join(', ')}\n` +
    `  This will cause empty data in readonly replay.`
  );
}
```

production build 不影响性能，dev mode 下第一时间发现问题。

---

## 2. dev-server 启动时校验前后端步骤数

**优先级：中**

### 问题

前后端步骤数不一致时，当前只有 FlowApp runtime 校验（`FlowApp.tsx` 约第 586 行）：

```typescript
if (update.pipelineTotalSteps !== stepsRef.current.length) {
  throw new Error(`steps.length=${stepsRef.current.length} but backend reported totalSteps=${update.pipelineTotalSteps}`);
}
```

这意味着 Creator 要输入数据、跑完前面的步骤、等到 SSE 事件到达才能看到报错。反馈周期太长。

### 典型出错场景

Creator 在 pipeline.py 加了一个 step_4，但忘了更新 main.tsx 的 buildSteps。dev server 启动正常，看不到问题，直到实际运行才崩。

### 建议改法

dev server 启动时做一次静态检查：

```javascript
// dev-server 启动脚本或 vite plugin
const pipelineSource = fs.readFileSync('pipeline.py', 'utf-8');
const backendSteps = (pipelineSource.match(/async def step_\d+/g) || []).length;

const mainSource = fs.readFileSync('frontend/src/main.tsx', 'utf-8');
const frontendSteps = (mainSource.match(/defineWidgetStep/g) || []).length;

if (backendSteps !== frontendSteps) {
  console.error(
    `\n  Step count mismatch!\n` +
    `  pipeline.py: ${backendSteps} steps\n` +
    `  main.tsx: ${frontendSteps} steps\n` +
    `  Fix before continuing.\n`
  );
  process.exit(1);
}
```

位置建议放在 `run-skill.mjs` 或作为 vite plugin 的 buildStart hook。正则可能需要根据实际代码风格调整（比如后端 step 方法命名约定）。

### 收益

| 指标 | 改前 | 改后 |
|------|------|------|
| 发现时机 | 运行到不一致步骤时 | 启动 dev server 时 |
| 排查成本 | 高（要理解 SSE 错误） | 低（启动直接报行数） |
| 影响范围 | 阻断用户流程 | 阻断开发者启动 |
