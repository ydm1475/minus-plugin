# 结果呈现设计

**所有 pipeline 节点开发完成后**，执行 `generate-result-design.sh` 进入结果呈现设计。

**调用方式：**

```bash
minus-lib generate-result-design
```

脚本会：

1. 门禁检查——所有步骤四维度必须全部完成，否则拒绝执行
2. 从 pipeline.py 提取各步骤的 payload 数据全景
3. 输出两维度引导模板（结果摘要 + 下载内容）

⛔ 禁止跳过脚本直接引导 Creator，门禁检查是硬性的。
⛔ 最后一步的 `generate-node-code.sh` 会提示调用此脚本，不要忽略。
⛔ 即使某个步骤已经包含摘要（如步骤内的大模型分析），也必须向 Creator 确认结果页是否还需要单独的总结摘要。禁止自行判断"步骤里有了就不需要了"而跳过摘要维度。
