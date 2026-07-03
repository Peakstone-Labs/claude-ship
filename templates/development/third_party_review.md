# {FeatureName} — Third-Party Design Review

> 由**未参与本设计**的第三方厂商模型驱动的独立 Claude Code 会话产出。
> 评审对象 = `design.md`（**设计层面**，代码尚未实现）。**建议性**，不阻断 `/ship`。

## Reviewer Context
- 第三方 provider / model：{provider} / {model}
- 评审输入：design.md / requirements.md / CLAUDE.md / <design 点名的现有源码>
- 评审日期：{YYYY-MM-DD}

## Overall Verdict
设计是否就绪进入实现：**通过 / 附条件通过 / 不通过** + 一句话理由。

## Challenged Assumptions
design.md 里**没明说但隐含**、且一旦不成立就会塌的假设。逐条：
- 假设 → 为何存疑 → 影响面（哪个模块/决策会受牵连）

## Option Space Gaps
- `Viable Options Considered` 是否漏了更优 / 更省的方案？
- 被否决方案的理由是否站得住（"不满足 X 约束"是否真成立）？
- 有没有「伪二选一」——把本可兼得的两条路写成互斥。

## Design-Level Issues
按等级分组（**设计视角，非代码行号**）：

- 🔴 Critical：数据正确性 / 领域红线 / 架构性错误 / 必然返工的设计缺陷
- 🟡 Important：风险未缓解、接口/schema 缺口、边界/失败模式遗漏、与 CLAUDE.md 既有决策冲突
- 🟢 Minor：命名、文档清晰度、可读性
- 💡 Suggestion：可选改进

**每条 🔴/🟡 必含**：
- 指向 design.md 的具体章节 / 决策编号 / File Map 条目（如 `D3` / `Risk R2` / `File Map 第 N 项`）
- 问题描述（为什么是问题、什么场景下爆）
- 具体修改建议

## Missing Coverage
应在设计里出现但缺失的：错误处理策略、边界条件、回滚/幂等、可测的验收标准、Owner 分配、
领域约定 / 存储约定对齐。

## Cross-Vendor Note（可选）
第三方模型视角与 Claude 架构师视角的**分歧点**——哪些是 Claude 可能因共有训练偏见而看不见的。
