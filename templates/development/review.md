# {FeatureName} - Review Report

## Pre-commitment Predictions
**读代码之前**列出的 3-5 个最可能的缺陷区域。

## Predictions vs Reality
- 预测命中的问题
- 预测未覆盖的问题（后者更重要，说明预判不足）

## Overall Verdict
通过 / 不通过 / 附条件通过。

## Decision Execution Verification
逐条核对 design.md 的 Decision Log 是否被正确实现（触发测试 + 代码位置）。

## Pitfalls Checklist
逐条核对 progress.md 的 Pitfalls 是否被落地。

## Missing Coverage
应该存在但没有的：错误处理、测试用例、边界条件、设计提了但没做的功能。

## Issues Found

按等级分组：

- 🔴 Critical（必须修复）
- 🟡 Important（建议修复）
- 🟢 Minor（可选）
- 💡 Suggestion（不阻塞）

**每条 🔴 和 🟡 必含**：
- 文件:行号
- 当前代码片段（代码块）
- 问题描述
- 修复建议（含代码）

无具体证据的发现 → 降级为 💡。

## Rework Plan
Dev 应执行的修复清单和 Review 复核要点。
