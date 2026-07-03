# Review Gate - Requirements

## Goal

给 sembr 的 digest 产出链路加一个**可选、按 intent 开关**的「复核门」（review gate）。开启后，在 digest 正文生成之后、对外分发之前，**额外跑一轮 LLM**，把 digest 正文与本批输入文章对照复核，找出幻觉 / 不准确之处并**自动修复**，再把修正后的版本发出去。

触发动作 → 预期结果：

- **某 intent 开启 review gate + 该 intent 出 digest（cron 定时 / 手动 fire / backfill 回填任一路径）** → 系统先正常生成 digest 正文，再用第二轮 LLM 对照输入文章复核；若发现问题，**只对有问题的局部做外科手术式修正**（不整篇重写），对外分发**修正后的干净版本**。
- **复核发现的问题被记入应用日志**（每处带「修正前 → 修正后」片段），但**对外产物不暴露**复核痕迹（"对外干净 + 对内审计"）。
- **某 intent 未开启** → 行为与现状完全一致，零额外 LLM 调用、零延迟变化。

要修复的错误类型**不设白名单**——凡是「digest 正文里、输入文章撑不起来」的内容都属于幻觉/不准确，都要修，包括但不限于：

1. **源/归属编造**：正文给某条事实安了个输入里没有的信源名或错误归属（动机案例：6/14 美联储宏观追踪 digest 里，信源 6 实际并非「沧海一土狗」，LLM 在正文补充信源时把它编造成了「沧海一土狗」）。
2. **跨文章事实错配**：把 A 文章里的数字/事实安到 B 事件/B 来源上。
3. **凭空事实**：正文里出现任何一篇输入文章都没有的事实。
4. **引用序号引错**：`[N]` 指向的文章并不支持该处陈述。

## Non-Goals (Constraints)

- **不实现「可查询的审计接口/UI」（未来 B）**：本期审计能力收口为 **A — 应用日志（stdout / docker logs，grep 可查）**。但**实现上不得堵死通往 B 的路**：审计记录须以「日后可落库、可按 intent 查询」为前提结构化 emit，未来加 B 时不必回炉重构。这是一条前瞻性约束，但 B **本期不做**。
- **history DB 只保留一份最新版本**（即修正后的版本）；**不保留旧版全文**、不在 DB 里存「原始 vs 修正」双份。审计完全落在日志上。
- **不整篇重写**：修复必须是局部的、只动有问题的片段；本来正确的内容必须原样保留（详见成功标准的「零误伤」）。
- **gate 自身失败时放行原版**（fail-open，不丢内容）：复核这轮 LLM 若超时/报错/返回不可用，**照常分发未复核的原始 digest**，仅在日志记一条「本次 gate 未执行/失败」。绝不因为 gate 跑不通而导致 digest 整条不发。沿用 sembr digest 链路「永不因下游异常而崩」（on_summary never-raise）的既有契约。
- **开关默认关闭（opt-in）**；未开启的 intent 必须零行为变化、零额外成本。
- **开关挂在 intent 上**：该 intent 的**所有出 digest 路径**（cron 定时、手动 fire、backfill 回填）只要开了就一律走 gate，不存在「手动触发绕过复核」的口子。
- **不改对外 digest 的可见形态**：不在正文/邮件里加「已修正 N 处」之类标注（那是被否决的「正文可见标注」方案）。对外只见干净的修正版。

## Success Criteria

按可验证标准列出，复核须做到**双向回归**（既要抓到该抓的，也要不误伤干净内容）：

- **黄金回归（抓得到）**：以 6/14「美联储宏观追踪」那条真实 digest 作为黄金样本，开 gate 重跑/回放后，「信源 6 = 沧海一土狗」这处编造归属被**修正或删除**——对外版本里不再出现该错误归属。
- **零误伤（不乱改）**：一条**本来就干净**的 digest 过一遍 gate 后，**对外正文保持不变**（gate 不得把正确内容改坏或无谓改写）。
- **其余错误类型可修**：构造含「跨文章数字错配 / 凭空事实 / `[N]` 序号引错」的样本，开 gate 后对应错误被修正。
- **审计可查**：每次有修正时，应用日志可被 `grep` 到，且每处修正带「修正前片段 → 修正后片段」+ 错误类别 + intent 标识 + 对得上 DB 那条记录的 id；并有一行汇总「intent X：review gate 修正 N 处」。仅凭日志即可判断 gate 这一刀砍得对不对（因为旧版全文不进 DB，日志是唯一证据）。
- **未开启零影响**：未开 gate 的 intent，digest 产出路径无任何额外 LLM 调用、无延迟/行为变化。
- **fail-open 可验证**：模拟复核 LLM 失败，原始 digest 仍照常分发，日志记一条 gate 失败。

## Context & Assumptions

已探索的相关代码区域及要点：

- **`sembr/summarizer/pipeline.py`** — `SummaryPipeline`。链路为 `on_match → compute_summary → _dispatch`。
  - `compute_summary`：渲染 prompt → `self._llm.summarize(prompt, system=...)` 出正文 → 用真实 `match.payload` 构造 `Citation` 列表 → 返回 `SummaryResult`。
  - `_dispatch`：先 `on_persist`（写 history），再 `pre_push_hook` + `on_summary`（发邮件/digest）。**review gate 自然落在 `compute_summary` 出正文之后、`_dispatch` 之前**。
  - 三个出口共用：`handle`（cron，never-raise）、`fire_handle`（手动 fire，never-raise）、以及 backfill 回放（`compute_summary(..., now=past_fire_time)`）。开关挂 intent → 这三条都要覆盖。
- **源名归属机制**：digest 正文里 LLM 只被 system 提示要求用 `[N]` 序号引用（`prompts/system/default.md`），**不写信源名**。结构化引用列表的 `source_name` 来自真实 `feed.name`（`pipeline.py:126` 的 `feed_name_map`），邮件渲染见 `sembr/notifier/email.py:158`（查不到才显示 "Unknown source"）。因此「沧海一土狗」这类编造**出在 LLM 正文里**（它违规自行写了源名/错误归属），不是结构化列表出错——正是「正文 vs 输入文章」复核能覆盖的范围。
- **prompt/模板体系**：`prompts/system/default.md` + `prompts/instruction/default.md`，渲染在 `sembr/summarizer/templates.py`。复核轮大概率需要新的 system/instruction 模板（架构阶段定）。
- **运行环境**：sembr 生产常驻一台服务器（Docker，Tailscale 可达），LLM 经 SiliconFlow / BGE-M3 体系；复核是额外一轮 LLM 调用，成本/延迟在「opt-in」前提下可接受。

用户澄清中明确的技术/产品假设：

- 第二轮 LLM 的**输入** = digest 正文 + 本批输入文章（含可对照的真实来源信息），**判据** = 正文是否被输入撑得起来。
- **复核轮使用与生成轮同一个 LLM backend**（用户 2026-06-19 拍板），不引入独立/更强的模型；复用 `self._llm`。
- 失败动作 = 自动局部修复；修复粒度 = 只动问题片段。
- 留痕 = 日志（A），DB 只留修正版一份。

## Open Questions (Deferred)

不影响当前 scope 决策、但架构阶段需再定的问题：

- ~~**复核轮用哪个 LLM**~~ — 已定：复用生成轮同一 backend（`self._llm`），不引入独立模型。
- **「只修问题片段」的落地机制**：是让复核 LLM 直接产出「整篇但只改问题处」的修正稿，还是产出「结构化的问题清单 + patch」由代码套用？两者对「零误伤」和「日志 before→after」的可得性影响不同，需 architect 在设计阶段权衡并给方案。
- **复核轮的 token/prompt 预算**：复核要同时塞进「digest 正文 + 全部输入文章」，可能逼近 `max_prompt_chars`；与现有 water-fill 截断（`pipeline.py:_build_articles_text`）如何协同，architect 评估。
- **审计记录的结构化形态**：为不堵死未来 B，记录字段/载体怎么组织（结构化 log record？预留落库 schema？），architect 给前瞻性设计但本期只接 A。
- **history「只留一份」与现有 summary_history 写入的关系**：修正版替换/覆盖的具体写法，architect 对照 `sembr/db/summary_history.py` 定。
