# Examples

一个**真实 feature** 跑完整条流水线后留下的产物,轻度脱敏后原样收录——让你看到"七件套 + 第三方评审"实际长什么样,而不是玩具示例。

## `review-gate/`

来自 [sembr](https://github.com/Peakstone-Labs/sembr) 的一个真实 feature:给 LLM 生成的 digest 加一道**可选、fail-open 的复核门**。~30 分钟从 clarify 跑到 retro,3 个 review loop,改动 12 文件 / ~800 行 / 38 测试。

> 脱敏说明:仅把生产机的 SSH host alias 替换为 `<prod-host>`;其余(模块名、设计决策编号、发现的 bug、SiliconFlow/Docker 等技术栈)保留原样,因为**过程的真实性正是它的价值**。sembr 本身是开源项目。

### 想看这套流水线好在哪,重点读这几处

| 文件 | 看什么 |
|---|---|
| `review.md` | **预提交预测**——`### Pre-commitment Predictions` 里 reviewer 先只读设计"猜"哪里会错,并**引用 memory**(`参照: feedback_async_patterns.md`);`### Predictions vs Reality` 表逐条对命中。还有 **Loop 1→2→3** 的收敛:Loop 2 有个 🔴 阻断,Loop 3 清零。 |
| `third_party_review.md` | **跨厂商设计评审**在写代码前抓到 7 条(6 采纳),其中 F1(audit join race)、F4(JSON 健壮性)若拖到代码阶段会被打成 🔴、改起来更贵。 |
| `retro.md` | **学习循环**:15 条发现按根因分类(盲点/遗漏/规则缺失/外部约束);预测命中 2/5 的复盘;**Memory Candidates** 逐条用三条准入(Non-Googleable / Codebase-Specific / Hard-Won)判定存不存。 |
| `design.md` | architect 的"全调用路径审计"(D1)纠正了 requirements 的字面落点;Test Strategy 表带 **Owner 列**(dev/QA/manual)。 |

七件套的其余(`requirements` / `implementation` / `test_report` / `progress`)串起完整链路。
