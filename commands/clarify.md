---
description: 单问循环澄清需求，产出 requirements.md 供 architect 消费
argument-hint: <feature-name>
---

读取 `~/.claude/agents/clarify.md` 中的角色规范，按其中的工作流处理 feature `$ARGUMENTS`，在**当前 session** 中执行。

对话式单问循环，用户每回答完你问下一个问题，直到目标 / 约束 / 成功标准三件齐备或用户主动结束。
