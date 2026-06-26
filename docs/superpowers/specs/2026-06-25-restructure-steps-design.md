# 步骤结构变更：多文件原子同步重构

## 问题

步骤结构变更（insert/delete/append/swap/generate）需要同时修改多个文件：

| 数据源 | 内容 |
|--------|------|
| `pipeline.py` | `step_N` 方法定义和编号 |
| `frontend/src/main.tsx` | `buildSteps` 数组的渲染项 |
| `.minus/progress.json` | 步骤名称、状态、currentStep、phase |
| `.minus/total-steps` | 步骤总数 |
| `.minus/dev-progress/step_N_name` | 步骤名称文件 |

当前实现由 3 个独立进程串行执行，没有共享内存、没有事务性：

```
generate-steps.sh（shell 胶水）
  → node restructure-pipeline.cjs   写 pipeline.py
  → node restructure-frontend.cjs   写 main.tsx（失败时 exit 0）
  → bash update-progress.sh         内嵌 node -e 写 progress.json
                                     shell 写 total-steps + step_N_name
```

结构性缺陷：
1. 任何一步失败或静默跳过（exit 0），后续继续执行，数据源裂开
2. "当前有几步"有多个真相来源（total-steps 文件 vs progress.json keys vs grep pipeline.py），可能不一致
3. 每新增一个操作类型，要在 3 个文件里各写一份逻辑，改漏一处就是 bug

**进度操作（step-done、set-phase、touch 等）不存在这个问题**——它们只写 progress.json，天然原子，当前实现是稳定的。

## 方案

**只把需要多文件原子同步的操作收进一个 Node.js 模块 `restructure.cjs`，其他不动。**

### 边界划分

| 操作 | 归属 | 理由 |
|------|------|------|
| insert / delete / append / swap | `restructure.cjs`（新建） | 需要原子修改 pipeline.py + main.tsx + progress.json + total-steps + step_N_name |
| generate（全量生成） | `restructure.cjs`（新建） | 同上 |
| step-done / set-phase / touch / init-design / design-done / confirm-test / rename / show | `update-progress.sh`（不重写） | 只写 progress.json，天然原子，当前实现稳定 |
| input-type 处理、输出 node-dev.md | `generate-steps.sh`（保留） | 非步骤管理逻辑，不搬 |

### 架构

```
restructure.cjs <op> [args]
├── 一次读取声明的数据源
├── 内存操作
├── 一致性校验（写前）
└── 一次写回
```

`generate-steps.sh` 的变化：从"串三个独立进程"变成"调一个 restructure.cjs + 保留自己的非步骤逻辑"。

之前：
```
generate-steps.sh --insert-at 2 "名称"
  → node restructure-pipeline.cjs insert 2 3 "名称"    # 进程 1
  → node restructure-frontend.cjs insert 2 "名称"      # 进程 2
  → bash update-progress.sh insert-step 2 "名称"       # 进程 3（内嵌 node -e）
```

之后：
```
generate-steps.sh --insert-at 2 "名称"
  → node restructure.cjs insert 2 "名称"               # 一个进程，原子完成全部写入
```

`update-progress.sh` 的变化：
- 删除 `insert-step` 和 `delete-step` 分支（不再被调用，restructure.cjs 直接写 progress.json）
- 修复 3 个具体 bug：shebang `#!/bin/bash` → `#!/usr/bin/env bash`、step_name() 的 shell 内插、delete 覆盖 completed 状态（虽然 delete 分支被删，但修复逻辑体现在 restructure.cjs 中）
- 其余全部不动

### restructure.cjs 内部结构

每个操作声明自己需要哪些数据源，执行器根据声明动态组合读→执行→校验→写：

```js
const SOURCES = {
  pipeline:   { read: readPipeline,   write: writePipeline },
  frontend:   { read: readFrontend,   write: writeFrontend },
  progress:   { read: readProgress,   write: writeProgress },
  totalSteps: { read: readTotalSteps, write: writeTotalSteps },
  stepNames:  { read: readStepNames,  write: writeStepNames },
};

const ops = {
  insert: {
    reads:  ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
    writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
    run(sources, pos, name) { /* ... */ }
  },
  delete: {
    reads:  ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
    writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
    run(sources, pos) { /* ... */ }
  },
  append: {
    reads:  ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
    writes: ['pipeline', 'frontend', 'progress', 'totalSteps', 'stepNames'],
    run(sources, names) { /* ... */ }
  },
  swap: {
    reads:  ['pipeline', 'frontend', 'progress', 'stepNames'],
    writes: ['pipeline', 'frontend', 'progress', 'stepNames'],
    run(sources, a, b) { /* ... */ }
  },
  generate: {
    reads:  ['pipeline', 'frontend'],
    writes: ['pipeline', 'frontend', 'progress', 'totalSteps'],
    run(sources, names, inputType) { /* ... */ }
  },
};

function execute(opName, args) {
  const op = ops[opName];
  const sources = {};
  for (const key of op.reads) sources[key] = SOURCES[key].read();
  const result = op.run(sources, ...args);
  validateConsistency(result);  // 写前校验步骤数一致
  for (const key of op.writes) SOURCES[key].write(result[key]);
}
```

### 共享工具函数

从 restructure-pipeline.cjs 和 restructure-frontend.cjs 搬入，作为 restructure.cjs 内部函数：

| 函数 | 来源 | 用途 |
|------|------|------|
| `renumberPipeline(code, from, to)` | restructure-pipeline.cjs | pipeline.py 方法重编号 |
| `insertPipelineSkeleton(code, pos, name)` | restructure-pipeline.cjs | 插入骨架方法 |
| `deletePipelineMethod(code, pos)` | restructure-pipeline.cjs | 删除方法 |
| `extractPipelineMethod(code, pos)` | 新增 | 提取方法体（swap 用） |
| `findNthBuildStep(code, n)` | restructure-frontend.cjs | main.tsx 数组项定位 |
| `insertBuildStep(code, pos, name)` | restructure-frontend.cjs | 插入渲染项 |
| `deleteBuildStep(code, pos)` | restructure-frontend.cjs | 删除渲染项 |
| `validateConsistency(result)` | 新增 | 校验步骤数一致 |

### 关键设计决策

**1. swap 同时交换代码（修复已知 bug）**

当前 swap-steps 只交换 progress.json，pipeline.py 和 main.tsx 不动。新方案中 swap 在一个进程内同时交换全部数据源。

**2. main.tsx 不存在时的处理**

- insert / delete / append / swap：main.tsx 不存在 → **报错退出**，不写任何文件
- generate（全量生成）：main.tsx 不存在 → **跳过前端，只写 pipeline.py + progress**（初次生成时前端可能还没创建）

**3. delete 时 currentStep 调整（修复已知 bug）**

删除当前步骤后，移入该位置的步骤如果已是 completed，不覆盖其状态。只有 status 不是 completed 时才设为 in_progress。

**4. 一致性校验规则**

`validateConsistency(result)` 在写回前检查：
- pipeline.py 中 `async def step_N` 方法数 === totalSteps
- main.tsx 中 buildSteps 数组项数 === totalSteps（main.tsx 存在时）
- progress.json 的 keys 数 === totalSteps
- 不一致时报错并打印差异，不写任何文件

### 文件变更清单

| 操作 | 文件 |
|------|------|
| 新建 | `skills/minus-structure/scripts/restructure.cjs` |
| 删除 | `skills/minus-structure/scripts/restructure-pipeline.cjs`（逻辑并入 restructure.cjs） |
| 删除 | `skills/minus-structure/scripts/restructure-frontend.cjs`（逻辑并入 restructure.cjs） |
| 精简 | `skills/minus-structure/scripts/generate-steps.sh`（insert/delete/append 模式改为调 restructure.cjs 一次调用；全量生成模式也改为调 restructure.cjs generate；input-type 和 node-dev.md 输出逻辑保留） |
| 小修 | `scripts/update-progress.sh`（删除 insert-step/delete-step 分支；修 shebang） |
| 更新 | `tests/shell-scripts.test.sh`（现有测试保留，新增 restructure.cjs 直接调用测试） |
| 不改 | 所有 `.md` 文件（CLI 接口不变） |

### 迁移步骤

**第一步：写 restructure.cjs，跑通现有测试**

1. 新建 restructure.cjs，搬入 restructure-pipeline.cjs 和 restructure-frontend.cjs 的代码
2. 添加 progress.json / total-steps / step_N_name 的读写逻辑（从 update-progress.sh 的 insert-step/delete-step 分支提取）
3. 实现执行器（声明式依赖 + 动态组合读写）
4. 实现 validateConsistency
5. generate-steps.sh 的 insert/delete/append 模式改为调用 `node restructure.cjs <op>`
6. 全量生成模式也改为调用 `node restructure.cjs generate`
7. 运行 `bash tests/run-all.sh` 确保全部通过

**第二步：清理 + 修 bug + 补测试**

1. update-progress.sh 删除 insert-step/delete-step 分支，修 shebang
2. 修复 delete 覆盖 completed 状态的 bug（在 restructure.cjs 的 delete op 中）
3. 实现 swap 的全数据源同步
4. 删除 restructure-pipeline.cjs 和 restructure-frontend.cjs
5. 补测试：一致性校验拦截、delete 不覆盖 completed、swap 同步代码
6. 运行全部测试
