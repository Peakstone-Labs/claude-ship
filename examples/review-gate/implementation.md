# Review Gate - Implementation Record

## Overview

实现遵循 design.md (2026-06-19, D1-D13)。Single-phase mode, 8 files changed + 1 new module + 2 new prompt templates + 1 new test file。

## Loop 1 Changes

### Changed Files

| File | Change | Design Source |
|------|--------|---------------|
| `sembr/db/intents.py` | Added `review_gate INTEGER NOT NULL DEFAULT 0` column: `_CREATE_INTENTS`, `_MIGRATIONS`, `_SELECT_INTENTS`, `_row_to_intent` (index 13), `create_intent` INSERT, `_update_intent_in_txn`, `_update_intent_raw_in_txn` — all 7 touch points synced | D8, R4 |
| `sembr/models.py` | `IntentCreate.review_gate: bool = False`, `IntentUpdate.review_gate: bool \| None = None`, `Intent.review_gate: bool` | D9 |
| `sembr/summarizer/models.py` | `SummaryResult.run_at: str \| None = None` — unified fire-time anchor | D12 |
| `prompts/system/review.md` | New: review gate system prompt with JSON schema, 4 error classes, "merge adjacent fixes" rule | D7 |
| `prompts/instruction/review.md` | New: review instruction template with `{intent_text}` (digest) + `{articles}` placeholders | D7 |
| `sembr/summarizer/review.py` | **New module**: `_nfc` (NFKC normalisation, D13), `_parse_review_json` (6-layer recovery, D4), `_apply_corrections` (exact-substring patch with context anchor, D3), `_emit_review_correction` (audit sink, D6), `run_review_gate` (orchestrator, never-raise, D1/D3/D5) | D1-D6, D13 |
| `sembr/summarizer/pipeline.py` | `__init__` +`get_review_gate` param; `compute_summary`: top-level `effective_now`, gate call after summarize, `run_at` in result; import `UTC` | D1, D2, D12 |
| `sembr/main.py` | New `_get_review_gate` function; pipeline construction injects `get_review_gate=` and updated `on_persist` wrapper | D2, D12 |
| `web/static/index.html` | Checkbox control after timezone, before tags; `?v=17` cache-bust | D10 |
| `web/static/intents.js` | Form default `review_gate: false`; edit pre-fill `review_gate: intent.review_gate ?? false`; payload `review_gate: !!f.review_gate` | D10 |
| `tests/test_review_gate.py` | **New**: 28 tests covering D3 (correction mechanics), D4 (JSON parsing), D5 (budget), D6 (audit), D11 (zero-impact), D12 (unified now), D13 (Unicode) | All dev-owner tests |
| `tests/test_summary_history_pipeline.py` | Updated 2 assertions: `get_history_text` now receives concrete `effective_now` instead of `None` (D12) | D12 |

### Deviations from Design

- **D13 Unicode 规范化**: design 写的是 NFC，实现用的是 **NFKC**。原因是全角→半角转换（`，`→`,`）需要 compatibility decomposition，NFC 不做这个。`unicodedata.normalize('NFKC', ...)` 零新依赖，覆盖更全。
- **Review template placeholders**: design 写 `{digest}` 占位符，但 `render_instruction_from_raw`（`templates.py:169`）的 `_StrictMap` 只接受 `{intent_text}`, `{articles}`, `{history}`。实际使用 `{intent_text}` 承载 digest 正文，语义上 intent_text=digest 在此语境下成立。
- **审计 budget 日志**: design 写拆到 `digest/system/articles` 三段，但 review_user 里 digest 和 articles 混在同一个渲染模板中无法精确拆分。实际日志只打 `digest/system/total/limit`，剩余部分（instruction wrapper + articles）从 total - digest - system 反推，足够诊断。
- **`save_summary` 的 `run_at` 参数**: 已存在（`summary_history.py:88`），向后兼容——传了就用，没传自生成。`on_persist` wrapper 只改了 lambda 传参，不改函数签名。

### Design → Code Mapping

| 设计决策 | 实现位置 |
|----------|----------|
| D1 gate 落点 | `pipeline.py:397-416` (gate call in compute_summary) |
| D2 flag fetcher | `main.py:130-142` + `pipeline.py:166,176` |
| D3 exact-substring patch | `review.py:84-160` (`_apply_corrections`) |
| D4 6-layer JSON recovery | `review.py:39-81` (`_parse_review_json`) |
| D5 budget check | `review.py:226-246` |
| D6 audit sink | `review.py:163-182` (`_emit_review_correction`) |
| D7 review templates | `prompts/system/review.md`, `prompts/instruction/review.md` |
| D8 flag storage | `db/intents.py` (7 touch points) |
| D9 Pydantic models | `models.py:264,309,367` |
| D10 frontend | `index.html:1469-1480`, `intents.js:224,279,533` |
| D11 default OFF | `review_gate: bool = False` default everywhere |
| D12 unified time anchor | `pipeline.py:220,418,423` (effective_now) + `summarizer/models.py:40` (run_at) |
| D13 Unicode NFKC | `review.py:31-36` (`_nfc`), applied in `_apply_corrections` line 102 |

### Security-Critical Verification

- N/A (此 feature 无 auth/crypto/injection 面；review gate 是内部 digest 后处理，pipeline 的 never-raise 契约保证异常不会导致 digest 丢失)
- 复核 prompt 不含用户输入——digest 和 articles 都是系统内部生成，无注入面

### Cross-Feature Dependencies

- `save_summary` 的 `run_at` 参数已存在（`summary_history.py:88`），仅修改调用方传参，向后兼容
- `IntentPromptCtxFetcher` 5-tuple 契约不变——gate flag 走独立 fetcher，不影响 50+ 既有测试
- `BaseLLMBackend` ABC 不变——复核复用 `summarize`，不新增方法

## Loop 2 Changes

### Dispositions (Loop 1 Review)

- ✅ **🔴-1** (`_apply_corrections` not wrapped in try/except): Fixed — wrapped steps 6 in try/except in `run_review_gate` (`review.py:294-300`). Added `test_apply_corrections_valueerror_nfc_fail` defensive test.
- ✅ **🟡-1** (function name `_nfc` misleading): Fixed — renamed to `_nfkc` globally. Updated `review.py` (5 call sites) + `test_review_gate.py` (import + test name).
- ✅ **🟡-2** (missing `language="en"` test): Fixed — added `test_gate_language_en_renders`.
- ✅ **🟡-3** (context anchor only for n>1): Deferred to 1.x. Risk minimal — single occurrence `replace(...,1)` always hits unique match. Review accepted this deferral.
- ✅ **🟢-1** (budget log missing articles): Accepted as-is — deviation documented in implementation.md (digest + articles in same render template).
- ✅ **🟢-2** (trailing comma regex): Accepted as-is — 6-layer JSON recovery handles most cases.
- **🟢-3** (non-dict elements in corrections): Fixed — added `isinstance(corr, dict)` guard in `_apply_corrections` (`review.py:105-106`). Added `test_apply_corrections_skips_non_dict_entries`.
- ✅ **💡-1** (`error_class` enum not enforced): Deferred to future B (intent-level audit query). No runtime impact.

### Loop 3 Changes

- ✅ **🟡-1 (Loop 2)** (audit loop not wrapped in try/except): Fixed — wrapped audit loop + summary log in try/except (`review.py:306-331`).
- ✅ **🟢-4 (Loop 2)** (misleading test name): Fixed — renamed `test_apply_corrections_valueerror_nfc_fail` → `test_apply_corrections_happy_path`.
- ✅ **💡-4 (Loop 2)** (`run_at_str` double compute): Fixed — moved single computation before gate block, removed duplicate.
- ✅ **🟡-2 (Loop 3)** (NFKC normalization on all-non-dict corrections): Accepted — pathological case, all non-dict corrections would mean all get skipped, NFKC applied to empty text is a no-op.
- ✅ **🟢-5 (Loop 3)** (old `_nfc` test names): Fixed — renamed `test_apply_nfc_normalization` → `test_apply_nfkc_normalization`.
- ✅ **🟢-6 (Loop 3)** (ambiguous-quote log wording): Accepted — "Consider adding 'context'" advice is correct even when context was provided but anchor failed; user needs better context, not different wording.
