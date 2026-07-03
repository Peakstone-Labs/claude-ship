# Review Gate — Third-Party Design Review

**Reviewed by**: Claude (deepseek)  
**Date**: 2026-06-19  
**Source**: `sembr-dev-docs/development/review-gate/design.md`  
**Cross-referenced against**: `requirements.md`, `sembr/sembr/summarizer/pipeline.py`, `sembr/sembr/db/intents.py`, `sembr/sembr/db/summary_history.py`, `sembr/sembr/models.py`, `sembr/sembr/main.py`, `sembr/sembr/summarizer/llm/base.py`

---

## Summary

The design is **solid and well-reasoned**. D1 (gate placement in `compute_summary`) is the pivotal decision and it's correct — verified against all 5 code paths. The risk table (R1–R8) is thorough, the test strategy is concrete, and the design consistently respects existing contracts (never-raise, 5-tuple fetcher, SQLite migration conventions, frontend wiring requirements). **One medium-severity issue (D6 audit join key race) and several medium-low issues warrant attention before implementation.**

---

## Finding 1 (Medium-High): D6 audit join key `(intent_id, run_at)` — race condition in cron path

**What the design says** (line 90):

> gate 运行于持久化之前，拿不到 `summary_history.id`，故审计 join key = `(intent_id, run_at)`（summary_history 上恰有 `UNIQUE(intent_id, run_at)`，`summary_history.py:79`）

**The problem**: The cron path (`handle` → `compute_summary`) passes `now=None`. Inside the gate, `run_at` would be computed as `datetime.now(UTC)`. Then `_dispatch` → `save_summary(get_conn(), r)` also generates `run_at = datetime.now(UTC).strftime(_RUN_AT_FORMAT)` (summary_history.py:99-100). These are **two separate `datetime.now(UTC)` calls at different times** — they can differ by seconds or cross a minute boundary, breaking the `(intent_id, run_at)` join between the audit log and `summary_history`.

**Why it matters**: The audit is the only evidence of what the gate changed (requirements: "日志是唯一证据"). If you can't reliably join audit entries back to `summary_history` rows for the cron path, you lose traceability for the most common production path.

**Backfill is fine**: `backfill.py:190` calls `compute_summary(matches, now=past_fire_time)`, and `save_summary_or_skip` receives the same `past_fire_time` string. Both sides agree.

**Recommendation**:

- **Option A (simpler)**: In `compute_summary`, when `now is None`, set `now = datetime.now(UTC)` at the top of the method. Then pass it through to the gate (audit) AND include it in `SummaryResult` (new optional field `run_at`). Then `_dispatch` → `save_summary` uses `result.run_at` instead of generating its own. This makes `run_at` deterministic within a single `compute_summary` invocation for all paths.
- **Option B (less invasive)**: Have `handle()` and `fire_handle()` generate `now = datetime.now(UTC)` before calling `compute_summary(matches, now=now)`, making the cron path consistent with the backfill pattern.
- **Option C (punt)**: Document the race explicitly in R5/R7, accept that cron-path audit join is best-effort (grep by `intent_id` + approximate time), and fix properly when audit gets its own DB table (future B).

I recommend **Option A** — it fixes the root cause and costs one optional field on `SummaryResult`.

---

## Finding 2 (Medium): D3 `str.replace(quote, replacement, 1)` — first-occurrence ambiguity

**What the design says** (line 70):

> 代码对 `summary_raw` 逐条 `str.replace(quote, replacement, 1)`；`quote` 未命中则**跳过该条 + 日志告警**

**The problem**: `str.replace(quote, replacement, 1)` replaces the **first** occurrence of `quote`. If the same text (e.g., "美联储加息 25bp") appears twice in the digest and only one instance is wrong, the replacement hits the wrong one. The risk table R2 only covers "quote not found" — it doesn't cover "quote found but ambiguous."

**Real-world likelihood**: Low for long, distinctive quotes, but non-trivial for short factual fragments (numbers, entity names) that may repeat. Example: a digest covering two articles about the same Fed rate hike could use "25 个基点" in two contexts; the LLM might correctly flag one as misattributed, but the code replaces the first occurrence.

**Recommendation**:

- Add a note to risk R2 documenting the ambiguity case.
- Consider having the LLM include **surrounding context** (~20 chars before/after `quote`) in the JSON, and use that context to disambiguate the match location. The context itself doesn't get replaced — it just narrows the match window. Fallback to first-occurrence if context doesn't match either.
- At minimum, log a warning when `summary_raw.count(quote) > 1` ("review_gate ambiguous quote: N occurrences in digest, replacing first").

---

## Finding 3 (Medium): D5 budget check — digest self-length is the dominant consumer

**What the design says** (line 89):

> 预算：`len(review_system)+len(review_user) > max_prompt_chars*0.85` → 日志 + fail-open 返回原文

**The problem**: `review_user` includes the full `summary_raw` (the digest), which can be thousands of chars. Unlike the generation round where the prompt budget is dominated by articles, the review round's budget is **dominated by the digest itself**. A 3000-char digest plus a 1500-char system prompt already consumes 4500 chars — potentially >85% of budget before a single article is included. This means review gate will **silently skip for most intents that produce long digests**, not just the "超大批次" edge case described in R5.

**What this means operationally**: The feature's effective coverage may be narrow — it works for short digests (1-2 short articles) but silently degrades for rich digests covering 5+ articles. The design's fail-open semantics are correct, but users may be confused about why their flag is ON but no corrections appear.

**Recommendation**:

- R5 should explicitly mention that **long digests are a common trigger**, not just large article batches.
- Consider logging the budget breakdown at `DEBUG` level (digest_chars=N, articles_chars=M, system_chars=S) so operators can diagnose skips.
- For 1.x: consider truncating the digest in the review prompt (keeping the first N chars + last M chars) rather than skipping entirely, or doing a two-pass review (split digest into chunks).

---

## Finding 4 (Medium-Low): D4 JSON reliability — no structured output enforcement

**What the design says** (line 80):

> 复用 `self._llm.summarize()`，system 提示强制输出 JSON，代码容错解析（剥离 ```json 围栏、首尾非 JSON 噪声）

**The problem**: `BaseLLMBackend.summarize()` returns free-text strings (base.py:32). The design relies entirely on prompt engineering to get valid JSON. Common LLM JSON failure modes beyond markdown fences:

1. **Trailing commas** — `{"corrections": [{"quote": "x", "replacement": "y",},]}` — valid in JavaScript, invalid in JSON. `json.loads` rejects this.
2. **Unescaped quotes in values** — if the digest contains `"`, the LLM may not escape it properly in the JSON `quote` field.
3. **Explanatory preamble/postamble** — the LLM may output "Here are the corrections: {...}" even with strong system instructions.
4. **Single quotes instead of double** — some models default to Python-style dicts.

The `_parse_review_json` is described as "剥围栏 + `json.loads`" — these failure modes would all cause `json.loads` to raise, triggering fail-open. If this happens frequently, the feature is effectively non-functional for the models in use.

**Recommendation**:

- Add lightweight JSON recovery heuristics beyond fence-stripping:
  - Strip trailing commas before `json.loads` (regex: `,(\s*[}\]])` → `$1`)
  - Try `json.loads` on the substring from first `{` to last `}` (handles preamble/postamble)
  - Consider `ast.literal_eval` as a fallback for Python-style dicts, or a small regex-based extraction
- Document the JSON success rate in progress.md after real-LLM testing on the prod host.
- For 1.x: consider adding `response_format={"type": "json_object"}` to the LLM backend (OpenAI-compatible endpoints support this), or add a `complete_json()` method to the ABC.

---

## Finding 5 (Low): Unicode normalization gap in exact substring matching

**The problem**: Chinese text can have different Unicode representations:
- Fullwidth vs. halfwidth punctuation (`，` vs `,`, `＂` vs `"`)
- Composed vs. decomposed forms (NFC vs. NFD)
- Different whitespace characters (ideographic space `　` vs ASCII space ` `)

If the LLM's `quote` uses a different Unicode normalization than `summary_raw`, the exact substring match fails even though the text is semantically identical. This is a subset of R2 but more subtle — it's not that the LLM "made up" a quote, it's that the serialization differs.

**Recommendation**:

- Apply `unicodedata.normalize('NFC', ...)` to both `quote` and `summary_raw` before matching, and to the replacement text before inserting.
- Add a test case with fullwidth/halfwidth variation.

---

## Finding 6 (Low): Sequential correction interference

**The problem**: Corrections are applied sequentially via `str.replace`. If correction 1's `replacement` alters text that overlaps with correction 3's `quote`, correction 3 fails to match (degraded to R2 skip). This is a low-probability edge case (corrections should target disjoint text spans), but the design doesn't acknowledge it.

**Recommendation**:

- Document in the implementation: if corrections may overlap, the LLM should output them as a single correction with a larger `quote` span. The system prompt for the review LLM should instruct it to merge adjacent/overlapping fixes.
- Alternatively, apply corrections in reverse order of position (from end of text to beginning), which preserves earlier positions. But this requires knowing the position of each `quote` in `summary_raw`, which `str.replace` doesn't give you.

---

## Finding 7 (Low): Redundant `get_intent` DB call

**The problem**: Each `compute_summary` invocation would trigger two separate `get_intent` calls: one via `_get_intent_prompt_ctx` (existing, for the 5-tuple) and one via `_get_review_gate` (new, for the boolean flag). Both read the same `intents` row. The design acknowledges this ("复用 `get_intent`") but it's not actually reused — it's called twice.

**Why this is acceptable**: The design's D2 decision to avoid expanding the 5-tuple is correct — touching 50+ test fixtures for a single boolean would be disproportionate. The extra DB call is a trivial `SELECT` by primary key. Not worth fixing now; just be aware of it.

---

## Other Observations

### Correct and well-verified claims

| Claim | Location | Verified |
|-------|----------|----------|
| Backfill calls `compute_summary` directly (bypasses `handle`) | backfill.py:190 | ✅ |
| External fire calls `compute_summary` directly | external_fire.py:185 | ✅ |
| `IntentPromptCtxFetcher` is a 5-tuple Protocol | pipeline.py:131-134 | ✅ |
| `_row_to_intent` uses positional indexing | intents.py:208-230 | ✅ |
| `_RUN_AT_FORMAT` is second-precision | summary_history.py:22 | ✅ |
| `max_prompt_chars` is an ABC property on `BaseLLMBackend` | base.py:13-29 | ✅ |
| `summarize()` returns plain string, empty = error | base.py:32-38 | ✅ |
| `_BUDGET_SAFETY_RATIO = 0.85` | pipeline.py:43 | ✅ |
| UNIQUE(intent_id, run_at) exists on summary_history | summary_history.py:77-79 | ✅ |
| `_update_intent_raw_in_txn` also needs review_gate added | intents.py:401-423 (line 404 area referenced) | ✅ Covered by D8 |

### Line number references in design

The file:line references are accurate for the current codebase state:
- `pipeline.py:387` — `summary = await self._llm.summarize(...)` ✅
- `pipeline.py:131` — `IntentPromptCtxFetcher` Protocol ✅
- `pipeline.py:155-175` — `__init__` signature ✅
- `main.py:296` — `SummaryPipeline(...)` construction ✅
- `intents.py:208` — `_row_to_intent` with index comment ✅
- `summary_history.py:79` — UNIQUE index ✅
- `summary_history.py:88,123` — `save_summary` / `save_summary_or_skip` ✅

### Design strengths worth highlighting

1. **D1 analysis is the lynchpin** — catching that backfill and external_fire bypass `handle`/`_dispatch` is the kind of thing that's easy to miss and would create a silent bypass. The 5-path table is clear and verifiable.

2. **"零误伤 by construction"** (D3) is genuinely elegant — using exact substring replacement means unchanged text is byte-identical to the original. No diff, no "LLM rewrote it slightly differently," no false positives from diff algorithms.

3. **The audit sink indirection** (D6: "所有审计经单一函数出口") is good forward-engineering — when future B arrives, only one function body changes.

4. **The test strategy** maps each test case to a design decision or risk, making coverage auditable. The golden-sample test (`test_review_gate_golden_fed_6_14`) is the right kind of regression test for an LLM feature.

5. **"不改" section** (line 165) is explicit about zero-touch files — prevents over-engineering and makes the blast radius reviewable.

### Templates path note

The design references `prompts/system/review.md` and `prompts/instruction/review.md`. The `PROMPTS_DIR` in production is `/app/prompts` (pipeline.py:163, main.py:92 imports `PROMPTS_DIR` from templates.py). These files must be placed at `sembr/prompts/system/review.md` and `sembr/prompts/instruction/review.md` in the repo (alongside existing `default.md` files), and the Dockerfile must COPY them (or the Dockerfile already globs `prompts/` — verify at build time).

---

## Recommendations Summary

| # | Severity | Finding | Action |
|---|----------|---------|--------|
| 1 | **Medium-High** | D6 audit join key race on cron path | Pass deterministic `now` through `SummaryResult` (Option A above) |
| 2 | **Medium** | D3 first-occurrence ambiguity | Add R2 note; consider context-window disambiguation |
| 3 | **Medium** | D5 digest self-length dominates budget | Expand R5; add DEBUG-level budget breakdown log |
| 4 | **Medium-Low** | D4 no structured output enforcement | Add trailing-comma + first-`{`-to-last-`}` recovery; track real-LLM JSON success rate |
| 5 | **Low** | Unicode normalization gap | Apply NFC normalization before matching |
| 6 | **Low** | Sequential correction interference | Document in system prompt (merge overlapping fixes) |
| 7 | **Low** | Redundant `get_intent` call | Accept; document in implementation.md |

---

## Verdict

**Proceed with implementation.** The design is thorough, correctly anchored in the actual codebase, and the decisions (D1–D11) have clear rationales with trade-offs acknowledged. Finding 1 (audit join race) should be addressed before or during implementation — the others are manageable within the risk budget the design already accepts (fail-open, R1–R8).

The feature's real-world effectiveness will ultimately depend on two things that can only be validated on the the prod host with real LLM calls: (a) how often the review LLM produces valid JSON, and (b) whether the 0.85× budget leaves enough room for articles after the digest. Both are covered by the manual test plan (line 135-136) — those results should be recorded in `progress.md` and may inform 1.x tuning.
