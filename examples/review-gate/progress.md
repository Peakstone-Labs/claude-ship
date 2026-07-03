# Review Gate - Progress

## Overview
给 sembr digest 链路加一个可选、按 intent 开关的「复核门」：开启后在正文生成后、对外分发前额外跑一轮 LLM，对照输入文章自动修复幻觉/错配（只动问题片段），对外发干净修正版、对内日志审计。

## Status
- 需求澄清: 完成 (2026-06-19)
- 设计 (architect): 完成 (2026-06-19)；已吸纳 third-party review F1-F6（见下方）
- 实现 (dev): done (2026-06-19)
- 评审 (review): ✅ 通过 — Loop 3 🔴0 🟡0
- 测试 (qa): ✅ 通过 — 38/38 passed, 🔴0 🟡0
- 测试 (qa): 未开始
- 回顾 (retro): 完成 (2026-06-19)

## Key Decisions / Highlights
- **D1 落点修正**：gate 放进 `compute_summary` **尾部**（非 handle/_dispatch 之间）——因为 backfill/external_fire 直调 compute_summary 绕过 _dispatch，只有放 compute_summary 才覆盖全部 5 条出 digest 路径，且持久化天然只存修正版。
- **D2 flag 传递**：新增独立 fetcher `get_review_gate`（不扩 5-tuple ctx，避免改 50+ 测试 fixture）。
- **D3 修复机制**：检测→代码套 **exact-substring 补丁**（LLM 只出 JSON `{quote,replacement}`，代码 `replace(quote,replacement,1)`）。零误伤 by construction + 审计 before→after 免费；fix-miss 风险靠日志暴露。整篇回写式（3B）推 1.x。
- **D4**：复用 `self._llm.summarize` + system 提示要 JSON + 容错解析，不动 ABC。
- **D12 统一时间锚**（采纳 F1）：`compute_summary` 顶部一次性 `effective_now` → gate audit + `SummaryResult.run_at` + `save_summary` 共用，消除 audit join 竞态。
- **D13 Unicode 规范化**（采纳 F5）：`unicodedata.normalize('NFC')` 防止全角/半角、NFC/NFD 导致逐字匹配失败。
- **D6 审计 sink**：单一 `_emit_review_correction` 出口（当前 WARNING 日志），未来 B 改这一处即可落库；join key=(intent_id, run_at)（已由 D12 消除竞态）。
- 失败/坏 JSON/超预算一律 fail-open 返回原文，never-raise。
- history「只留一份」由"持久化写 compute_summary 返回值"结构性满足，不改 DB。

## Role-Specific Onboarding
- **dev 必读**：design.md 的 Decision Log（D1–D13）、Risk 表（尤其 R4 列位置漂移、R5 预算 fail-open）、File & Responsibility Map（实现顺序 1→8）。强制：never-raise 契约、四处 SQLite 列同步、前端三处 wiring + cache-bust、D12 三文件协同（`pipeline.py`/`models.py`/`main.py`）、D4 6 层 JSON 恢复。dev 列测试必须全覆盖。
- **review/QA 必读**：Test Strategy 表的 Owner 分工；QA 重点 = 全路径覆盖 + 黄金回归 + 零误伤。

## Implementation Checklist
1. `db/intents.py` 加 `review_gate` 列（四处位置同步：CREATE/MIGRATIONS/SELECT/parse+INSERT+UPDATE）。
2. `models.py` 三模型（Create/Update/Intent）加 `review_gate`。
3. `prompts/{system,instruction}/review.md` 复核模板（含 JSON schema + 只改撑不起来内容规则）。
4. `pipeline.py`：`__init__` 加 `get_review_gate`；`compute_summary` summarize 后插 gate；新增 `_run_review_gate`/`_parse_review_json`/`_emit_review_correction`（可拆 `summarizer/review.py`）。
5. `main.py`：`_get_review_gate` + 构造处注入。
6. `web/static/{index.html,intents.js}`：checkbox + 三处 wiring + `?v=N` bump。
7. `tests/`：dev/QA 用例 + 多轮脚本化 stub LLM fixture。

## Pitfalls & Gotchas
- digest 正文只用 `[N]`，源名出自真实 `feed_name_map`；「编造源名」出在 LLM 正文里，复核须吃到正文 + 输入文章 + 真实来源对照。
- never-raise 契约：gate 任何异常都不能让 digest 整条不发。
- 复核轮 prompt 要同时容纳正文+全部输入文章，注意 `max_prompt_chars` 与 water-fill 截断协同。

## Dependencies
- `sembr/summarizer/pipeline.py`、`sembr/summarizer/templates.py`、`prompts/{system,instruction}/`、`sembr/db/summary_history.py`、`sembr/notifier/email.py`。

## Outstanding TODOs
- 未来 B：按 intent 可查询的修正审计接口/UI（本期不做，预留扩展）。

## Loop Log (by /ship)
- loop 1: review=🔴1r(block) 🟡3r(block), qa=SKIPPED (review gate blocked), duration=~2m
- loop 2: review=🔴0r 🟡1r(block), qa=SKIPPED (review gate blocked), duration=~2m
- loop 3: review=🔴0r 🟡0r, qa=🔴0q 🟡0q, duration=~4m

## Third-Party Review (2026-06-19)

Reviewed by Claude (deepseek). **7 findings, 6 accepted**:

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| F1 | Med-High | D6 audit join key race: two `datetime.now(UTC)` calls (gate audit vs `save_summary`) can cross second/minute boundary, breaking `(intent_id, run_at)` join | **Accepted** → D12 (unified `effective_now` at top of `compute_summary` → `SummaryResult.run_at` → `save_summary`) |
| F2 | Medium | `str.replace(quote,...,1)` first-occurrence ambiguity when text repeats | **Accepted** → D3 (add optional `context` anchor + `count>1` warning) |
| F3 | Medium | Digest self-length dominates review budget; long digests (≥3000 chars) are a common trigger, not just large batches | **Accepted** → D5/R5 (budget breakdown log; R5 now documents long-digest case) |
| F4 | Med-Low | JSON parsing naive — trailing commas, preamble, Python dict literals not handled | **Accepted** → D4 (6-layer recovery: strip fences → first `{`-to-last `}` → trailing comma → `json.loads` → `ast.literal_eval` fallback) |
| F5 | Low | Chinese Unicode normalization gap (fullwidth/halfwidth, NFC/NFD) | **Accepted** → D13 (`unicodedata.normalize('NFC', ...)` on quote, replacement, summary_raw) |
| F6 | Low | Sequential `str.replace` can interfere (correction 1's `replacement` breaks correction 3's `quote`) | **Accepted** → D3 (system prompt tells LLM to merge adjacent fixes; code-side optional reverse-offset apply) |
| F7 | Low | Redundant `get_intent` call (once for ctx, once for gate flag) | **Rejected** — two PK SELECTs negligible; fixing would require expanding 50+ test fixtures (cost >> benefit) |

## Closing Note
设计已吸纳 third-party review F1-F6。D12（统一时间锚）和 D4（6 层 JSON 恢复）是 dev 实现时必须严格对照的地方——F1 涉及 `pipeline.py`/`models.py`/`main.py` 三文件协同，F4 决定 feature 的实际 JSON 成功率。
