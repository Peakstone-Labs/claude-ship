# Review Gate - Retrospective

## Metrics Overview

| 指标 | 值 |
|------|-----|
| 总用时 | ~30 min（clarify → architect → dev/review/qa 3 loops） |
| 改动文件 | 12（8 修改 + 3 新建模块 + 1 新建测试） |
| 新增代码 | ~800 行（review.py ~350, tests ~450, 其余分布在 db/models/pipeline/main/frontend） |
| 测试总数 | 38（31 dev + 7 QA）+ 未受影响继续通过 78 |
| Review 发现 | 15 条（loop1: 8, loop2: 4, loop3: 3） |
| 🔴 阻断 | 1（never-raise 契约缺口） |
| 🟡 重要 | 5 |
| 🟢 轻微 | 6 |
| 💡 建议 | 3 |
| Third-party review 发现 | 7（6 采纳、1 拒绝） |
| Loop 轮数 | 3（loop1 被 🔴 阻断跳过 QA，loop2 被 🟡 阻断跳过 QA，loop3 全绿） |
| 设计偏差 | 2（NFC→NFKC、{digest}→{intent_text}） |
| 本轮未修 deferred | 3（🟡-3 context anchor for n=1、🟡-2 NFKC on zero corrections、💡-1 error_class enum） |

## Design vs Implementation Gap

### 功能性偏差

无——gate 落点、修复机制、审计 sink、fail-open 行为全部与 D1-D13 一致。

### 实现细节偏差（已在 implementation.md 记录）

| 偏差 | 原因 | 影响 |
|------|------|------|
| D13 NFC → NFKC | 全角→半角转换需要 NFKC 的 compatibility decomposition，NFC 不做这个。实现时实测 `unicodedata.normalize('NFC', '，')` 返回 `'，'`（不变），必须 NFKC。 | 零功能影响（NFKC 是 NFC 的超集，等价类更宽）；`_nfkc` 命名已对齐 |
| `{digest}` → `{intent_text}` 占位符 | `render_instruction_from_raw` 的 `_StrictMap` 只接受 `{intent_text}/{articles}/{history}`。用 `{intent_text}` 承载 digest 正文语义在此语境下成立 | 零影响——复核 LLM 看到的 prompt 结构等价 |
| Budget 日志缺 articles 分解 | `review_user` 在一个渲染模板中混合 digest + articles + instruction wrapper，无法精确拆出 articles 字符数 | 极低——operators 可从 `total - digest - system` 反推 |
| `run_at_str` 初版双重计算（已修） | 先写在 gate 分支内再写在外面，review 💡-4 指出后合并为顶部一次计算 | 已修复 |

## Issues Classification

### 全部 Review 发现按根因分类

**盲点（根本没想到）—— 5 条**

| 发现 | 序号 | 严重度 |
|------|------|--------|
| `_apply_corrections` 未被 try/except 包裹，但 docstring 承诺了（never-raise 是已知规则，这次在执行层面遗漏了） | 🔴-1 | 🔴 |
| `_nfc` 函数名做的是 NFKC——NFC 不能半角化，实现时才发现 | 🟡-1 | 🟡 |
| `review.md` template 的 `{language}` 测试只覆盖 zh 路径 | 🟡-2 | 🟡 |
| context anchor 只对 n>1 启用——单出现时 context 被忽略（设计时的条件过于保守） | 🟡-3 | 🟡 |
| audit loop not wrapped in try/except（loop2 新发现，说明第一次 never-raise 修复只覆盖了 step 6 忘了 step 7） | 🟡-1(L2) | 🟡 |

**遗漏（想到了但没做）—— 4 条**

| 发现 | 序号 | 严重度 |
|------|------|--------|
| budget 日志缺 articles 字段——design 写了五段，实现因模板混排只做了四段 | 🟢-1 | 🟢 |
| `_TRAILING_COMMA_RE` 不处理行注释——6 层恢复的容错设计覆盖了这层，但较脆弱 | 🟢-2 | 🟢 |
| `_apply_corrections` 缺 `isinstance(corr, dict)` 守卫 | 🟢-3 | 🟢 |
| `run_at_str` 双重计算 | 💡-4(L2) | 💡 |

**规则缺失（流程/规范未覆盖）—— 4 条**

| 发现 | 序号 | 严重度 |
|------|------|--------|
| `error_class` 枚举在 prompt 和代码中未联动（prompt 定义 4 个合法值，代码不校验） | 💡-1 | 💡 |
| 测试名 `test_apply_corrections_valueerror_nfc_fail` 误导——它测试的是正常路径不是异常 | 🟢-4(L2) | 🟢 |
| 测试名 `test_apply_nfc_normalization` 仍用旧 `_nfc` 命名——`_nfkc` 重命名时漏了测试名同步 | 🟢-5(L3) | 🟢 |
| ambiguous-quote 警告的 "Consider adding 'context'" 提示在 LLM 已提供 context 但锚定失败时仍然给出——日志措辞可改进 | 🟢-6(L3) | 🟢 |

**外部约束（不可抗力）—— 2 条（均来自 third-party review）**

| 发现 | 序号 | 严重度 |
|------|------|--------|
| `{digest}` 占位符 vs `_StrictMap` 只接受 `{intent_text}`/`{articles}`/`{history}` | — | — |
| `save_summary` 的 `run_at` 参数已存在——D12 的实现路径刚好可复用 | — | — |

### 根因分布

```
盲点 5/15 (33%) — never-raise 遗漏两次说明契约虽然文档化了但执行有薄弱点
遗漏 4/15 (27%) — 多数是 minor，修起来快
规则缺失 4/15 (27%) — 命名一致性是纯粹的疏忽
外部约束 2/15 (13%) — 顺水推舟
```

盲点占比最高，且两次 never-raise 遗漏（🔴-1 和 🟡-1 L2）说明问题：**sembr 的 never-raise 契约靠人"记得要 try/except"来执行，但没有结构化的检查点**。design.md 的 R7 写了"顶层 try/except 包全部逻辑"，但 `_apply_corrections` 和 audit loop 这两步在 review.py 中是"run_review_gate 内部的内部步骤"，容易被漏——因为 "顶层"这个措辞不够精确，实现者自然理解为"run_review_gate 函数体整体 try/except"，而不是"每个可能抛异常的子步骤都要包"。

## Process Efficiency

**做得好的：**

- **Third-party review 在 design 阶段拦截了 6 条问题**（F1-F6），尤其是 F1（audit join race）和 F4（JSON 6 层恢复），这两条如果在代码阶段才发现会被打成 🔴，改起来更贵。
- **pre-commitment predictions 命中了 2/5**（never-raise 缺口和 JSON parser），说明 review agent 的 memory 参照机制是有效的——它基于 `feedback_async_patterns` 和 `feedback_sqlite_pragmas` 来预测风险点。
- **D1 落点修正** 是 architect 阶段靠"完整走一遍所有调用链"发现的——如果按 requirements 字面实现会漏掉 backfill/external_fire 两路径，事后修的成本远高于设计阶段纠正。

**可改进的：**

- **never-raise 契约的验证是手动且不完整的**：review 靠 grep + 肉眼检查 try/except 配对，第一步发现了 `_apply_corrections` 缺口但漏了 audit loop——因为它被 `for entry in audit_entries` 的主体逻辑"掩盖"了。未来如果 sembr 新增一个 lint rule 或 convention（例如 "文件内每个 `def` 在调用链顶层都必须有 try/except 标记"），这种系统性防御会比人工更可靠。
- **命名同步**（`_nfc`→`_nfkc`、test 名更新）在 3 个 loop 中反复出现——如果 dev 在重命名时做一个全局 grep + replace-all，这些 🟢 就不会被 review 抓到。这不是重大缺陷（量极少），但反映了"命名一致性"在 workflow 中缺少自动化检查这层。

## Generalizable Lessons

1. **设计阶段的"全调用路径审计"比实现阶段的价值高 10x**：D1 追 `compute_summary` 的 5 条调用者（cron handle / fire_handle / backfill / external_fire / event flush）发现 backfill 绕过 `_dispatch`，纠正了 requirements 的字面落点。如果 arch 不做这件事、等 QA 在 `all_paths_covered` 测试中才发现，修正成本远高于设计阶段纠正。教训：design 阶段必须对每个新插入的步骤回答"它之前/之后是什么？这一段会被谁调用？"

2. **JSON prompt output 必须有容错层，且容错层应先于真实 LLM 试跑**：F4 的 6 层 JSON 恢复（剥围栏→截{...}→去尾逗号→json.loads→ast.literal_eval）在 third-party review 中加入，成本只有 40 行代码 + 5 个测试。如果没有这层，真实 LLM 的 JSON 成功率可能远低于预期——尾逗号 + preamble 是两个最常见的 LLM JSON 失败模式。教训：任何要求 LLM 输出 JSON 的 prompt，都应该假设 LLM 会在 JSON 外面加废话、在最后加逗号。

3. **"opt-in + fail-open" 是 LLM pipeline feature 的正确默认姿态**：review gate 默认 OFF、失败放行原版、未开启零成本。这个设计让 feature 可以安全地"先上车再调参"——即使 JSON 成功率不高或预算不够，也不会破坏现有的 digest 分发。反面是"默认 ON + fail-closed"——那样一个 JSON 解析失败就会丢掉整条 digest。

## Memory Candidates（三条准入过滤后）

### 候选 1：never-raise 契约的执行薄弱点——"顶层 try/except"不等于"每个子步骤都安全"

- **Non-Googleable**: ✅ 是 sembr 特有的 never-raise 设计模式，不是通用最佳实践
- **Codebase-Specific**: ✅ 指向 `review.py:96-97`（docstring 承诺 vs 实际代码）、`pipeline.py:398-445`（handle 的双 try 模式）
- **Hard-Won**: ✅ 本轮同一契约被 review 抓到两次缺口（🔴-1 和 🟡-1 L2），第二次是因为第一次修复只看了"run_review_gate 外层"而漏了内层的 audit loop——证明"顶层 try/except"的措辞有歧义，容易让人误以为外层包一次就够了

**建议**：合入已有 `feedback_async_patterns.md` 的 "never-raise wrapper dual-try" 规则，补充说明"文件级 helper 函数中的每个可能抛异常的步骤块都要独立包裹"。

### 候选 2：LLM JSON output prompt 的最低容错清单

- **Non-Googleable**: ✅ 是 sembr 的 prompt 体系 + `_StrictMap` 机制下的特有 JSON 解析上下文
- **Codebase-Specific**: ✅ 指向 `review.py:39-81`（`_parse_review_json` 的 6 层恢复）和 `templates.py:116-157`（`_StrictMap` 机制）
- **Hard-Won**: ⚠️ 部分满足——F4 和 6 层恢复是 third-party review 推的，不是自己踩坑后修的。但"要求 LLM 输出 JSON→要在代码端做多道容错"这条教训如果没记下来，下一个 feature 还会犯同样的错误。

**判定**：不满足 Hard-Won（还没在真实 LLM 上验证 JSON 成功率），但值得作为 Generalizable Lesson 留在 retro。建议真实 LLM 跑完后如果发现 JSON 解析频繁失败，再回来存这条 memory。

### 候选 3：D1 全调用路径审计

- **Non-Googleable**: ✅ 是 sembr `compute_summary` 的 5 条调用路径特有问题，无法泛化为通用原则
- **Codebase-Specific**: ✅ 指向 `backfill.py:190` 和 `external_fire.py:185` 直调 compute_summary 而绕过 handle
- **Hard-Won**: ❌ 这是在设计阶段就发现并修正的，没有造成实际 bug 或 debug 成本

**判定**：不满足 Hard-Won，留在 Generalizable Lessons。

## Process Documentation Updates

无需更新 CLAUDE.md 或流程文档——review-gate 遵循了既有 convention，没有发现需要修正的流程缺陷。

## Forward-Looking Warnings

1. **JSON 成功率未知**——所有 38 测试用 stub LLM 验证，`_parse_review_json` 的 5 条纯 JSON 测试覆盖了 recovery path，但**真实 LLM（SiliconFlow）出 JSON 的成功率**必须等 生产机 跑过才知道。如果成功率 < 80%，建议在 1.x 加 `response_format={"type": "json_object"}`（APIBackend 的 OpenAI 兼容端点支持，无需改 ABC）。这条影响 D4 和 R6 的残余风险。

2. **预算限制了长 digest 的覆盖率**——R5 已经记录：digest >= 3000 字时复核直接跳过（fail-open）。如果用户反馈"开了 gate 但从没见过修正"，第一件事应该查 `docker logs | grep review_gate` 看是不是预算超过触发的 skip。Debug 时先看 `budget exceeded` 再怀疑 gate 没跑。

3. **1.x 应考虑 `response_format={"type": "json_object"}`**——如果 JSON 成功率低，这是最小改动、最高收益的优化。只需在 `APIBackend` 的 `summarize` 调用中加入 `payload["response_format"] = {"type": "json_object"}`（可选，不要改 `BaseLLMBackend` ABC）。与 D4 的 6 层容错配合使用效果最佳。

4. **审计未来 B 的落地时机**——`_emit_review_correction` sink 已经打通，当前写日志。如果用户发现"日志被轮转掉了查不到改了什么"，那时候再做 B（查 audit 表 + dashboard UI）。现在不做是因为用户拍板了 A（轻量收口）。

## Conclusion

**质量评价**：review-gate 是"设计驱动、实现精准"的 feature。Third-party review 在设计阶段拦截了最贵的问题（F1 audit join race、F4 JSON 健壮性）；dev 实现严格跟 design，3 个 review loop 暴露的都是**细节层面的遗漏**（never-raise 双层衔接、命名一致、test 名同步），没有结构性设计缺陷。

**核心成功因素**：
- architect 阶段的"全调用路径审计"（D1）——纠正了 requirements 的字面落点，避免 backfill/external_fire 两个生产路径绕过复核
- third-party review——7 条发现 6 条采纳，且都发生在 design 阶段而不是 implement 后
- "opt-in + fail-open + never-raise" 三件套——让 feature 可以安全上线，即使 JSON 解析率低或预算不够也不会坏了现有 digest
- exact-substring patch 机制的"零误伤 by construction"——`corrections=[]` 时返回逐字相同的 digest，这是整个"对外干净"方案的根基
