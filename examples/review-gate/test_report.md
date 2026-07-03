# Review Gate - Test Report

## Loop 1 — 2026-06-19

## Overview

First QA loop for the review gate feature. Executed 7 QA-owned test cases covering golden regression, zero false positive, cross-article number mismatch, fabricated fact deletion, all 4 digest output paths, history one-version guarantee, and frontend toggle round-trip. All existing 31 dev-owned tests remain green. Review fix verification confirmed 1/2 Loop 3 findings fixed, 1 accepted-defer.

New test count: +7 QA-owned (total 38).
Defects found: 0 new (review findings already tracked in review.md).
Regression status: none (all 3 related test suites 76/76 pass).

## Review Fix Verification

Verification of Loop 3 review.md findings (top-of-file chapter):

| Finding | Severity | Claimed Status | Verified | Evidence |
|---------|----------|----------------|----------|----------|
| 🟡-1: Step 7 audit loop not wrapped in try/except | 🟡 | ✅ fixed | ✅ Fixed | `sembr/summarizer/review.py:306-339` — audit loop and summary log wrapped in `try/except Exception`. Lines 306-333 emit corrections, lines 334-339 catch and log, line 341 always returns `corrected`. |
| 🟡-2: `_apply_corrections` returns NFKC-normalized text when zero corrections effectively applied | 🟡 | accepted-defer | ❌ Not fixed | `sembr/summarizer/review.py:100-102` still unconditionally NFKC-normalizes `summary_raw` before checking whether any corrections survive guard clauses. Dev documented acceptance: "pathological case, all non-dict corrections would mean all get skipped, NFKC applied to empty text is a no-op." Not code-changed. |

**Summary**: 1 fixed, 1 accepted-defer, 0 regressed, 0 still-open.

Additional verification of Loop 2 findings fixed in Loop 3:

| Finding | Severity | Status | Verification |
|---------|----------|--------|-------------|
| 🟢-4: Test name `test_apply_corrections_valueerror_nfc_fail` misleading | 🟢 | ✅ Fixed | Renamed to `test_apply_corrections_happy_path` at `tests/test_review_gate.py:335`. |
| 💡-4: `run_at_str` double compute | 💡 | ✅ Fixed | `run_at_str` computed once at `pipeline.py:396`, before gate block, used in both branch and return. |

## Test Results (Loop 1)

**38/38 passed (100%)** — 31 dev-owned + 7 QA-owned.

### Existing tests (dev-owned) — all pass
31 tests from first implementation covering D3 (correction mechanics), D4 (JSON parsing), D5 (budget), D6 (audit), D11 (zero-impact), D12 (unified now), D13 (Unicode). All pass without changes.

### New test cases (QA-owned, added this loop)

| Test | File:Line | Design Source | Status |
|------|-----------|---------------|--------|
| `test_review_gate_golden_fed_6_14` | `tests/test_review_gate.py:522` | Golden regression (6/14 source attribution) | PASS |
| `test_review_gate_clean_digest_untouched` | `tests/test_review_gate.py:551` | Zero false positive | PASS |
| `test_review_gate_cross_article_number` | `tests/test_review_gate.py:577` | Error type 2 (cross-article numbers) | PASS |
| `test_review_gate_fabricated_fact` | `tests/test_review_gate.py:603` | Error type 3 (fabricated fact) | PASS |
| `test_review_gate_all_paths_covered` | `tests/test_review_gate.py:629` | R8 / 4 digest output paths | PASS |
| `test_review_gate_history_one_version` | `tests/test_review_gate.py:711` | History stores only corrected version | PASS |
| `test_review_gate_frontend_toggle_e2e` | `tests/test_review_gate.py:742` | D10 frontend round-trip | PASS |

### Test details

**test_review_gate_golden_fed_6_14**: Simulates the "沧海一土狗" golden sample where digest attributes a statement to a fabricated source name. Stub LLM returns correction replacing `沧一土狗` with `建行金融市场部`. Verifies fabricated name removed, correct name present, citation preserved.

**test_review_gate_clean_digest_untouched**: Clean digest with empty corrections. Verifies byte-identical return (`result is summary`).

**test_review_gate_cross_article_number**: Digest with wrong citation numbers `[2]` and `[3]` instead of correct `[1]` and `[2]`. Stub returns two corrections fixing both numbers.

**test_review_gate_fabricated_fact**: Digest contains a claim ("government announced a 10% stimulus package") not found in any article. Stub returns correction deleting the fabricated clause. Verifies deletion with surrounding text preserved.

**test_review_gate_all_paths_covered**: Tests 4 distinct pipeline entry points:
1. `compute_summary()` — backfill/external_fire direct call: LLM called 2x, correction applied
2. `handle()` — cron path (persist=True): LLM called 2x, correction persisted
3. `fire_handle()` — manual fire (persist=False): LLM called 2x, no persist, dispatch called
4. `handle(persist=False)` — event-mode flush: LLM called 2x, no persist, dispatch called

All 4 verify the gate ran (LLM called twice, source attribution fixed).

**test_review_gate_history_one_version**: Pipeline with gate ON, `on_persist` mocked to capture the SummaryResult. Verifies the persisted summary is the corrected version (no `SourceX`, has `SourceB`), not the raw digest.

**test_review_gate_frontend_toggle_e2e**: DB-layer round-trip test simulating the dashboard form flow:
1. Create intent with `review_gate=True` → confirmed True on return
2. Read back via `get_intent` → confirmed True preserved
3. Default (no `review_gate` field) → confirmed False
4. Explicit False → confirmed False stored

### New failures found

None. All 7 QA-owned tests passed on first run. No new defects discovered.

### Manual tests (not automated)

| Test | Script/Path | Reason for no automation |
|------|-------------|--------------------------|
| Real LLM review replay (the prod host) | `ssh <prod-host>` → enable gate → fire → `docker logs \| grep review_gate_audit` | Requires running docker deployment with real LLM backend. Not suitable for ci/unit-test. |
| Review cost/latency measurement | `ssh <prod-host>` → timer before/after gate ON vs OFF | Performance measurement, not a correctness test. Requires real deployment. |

## Coverage Matrix

| Dimension | Count | Notes |
|-----------|-------|-------|
| Normal path (correction applied) | 6 | Single, multiple, delete, golden, cross-article, fabricated |
| Zero corrections (no-op) | 2 | Empty list, clean digest verbatim |
| Fail-open (LLM error) | 1 | `test_gate_llm_error_failopen` |
| Fail-open (bad JSON) | 1 | `test_gate_bad_json_failopen` |
| Fail-open (budget exceeded) | 1 | `test_gate_budget_exceeded_skips` |
| Fail-open (template missing) | 1 | `test_gate_template_missing_failopen` |
| Fail-open (fetcher exception) | 1 | `test_pipeline_gate_fetcher_exception_treated_off` |
| Zero-impact (gate OFF) | 2 | Fetcher returns False, no fetcher injected |
| Context anchor disambiguation | 1 | `test_apply_context_anchor_disambiguates` |
| Ambiguous quote (count>1) | 1 | `test_apply_ambiguous_quote_warns` |
| Unicode normalization (NFKC) | 2 | Fullwidth→halfwidth; golden sample with Chinese chars |
| JSON parsing (6 layers) | 6 | Plain, fenced, preamble, trailing comma, Python dict, empty string |
| Non-dict entries in corrections | 1 | `test_apply_corrections_skips_non_dict_entries` |
| Unmatched quote | 1 | `test_apply_unmatched_quote_skipped` |
| Audit emission | 2 | Per-correction log + summary log |
| Pipeline integration | 8 | Gate ON/OFF/exception/no fetcher, run_at, 4 entry paths, history version |
| Frontend toggle round-trip | 1 | Create/read-back True/False/Default via DB layer |
| Cross-article number | 1 | `test_review_gate_cross_article_number` |
| Fabricated fact deletion | 1 | `test_review_gate_fabricated_fact` |
| **Total** | **38** | |

## Defects Found

No new defects found this loop. Two review findings from Loop 3 remain:
- 🟡-2 (NFKC on zero-effective corrections): accepted-defer, pathological case
- 🟢-6 (ambiguous-quote log wording): accepted-defer, minor log polish

## Key Verifications

1. **Golden regression passes**: 6/14 "沧海一土狗" type fabricated source attribution is correctly fixed by the review gate when correction JSON is provided.
2. **Zero false positive holds**: Clean digest with empty corrections passes through byte-identical (`result is summary`). This property is structural (corrections-based repair) and verified.
3. **All digest output paths covered**: The gate activates through `compute_summary` (backfill/external_fire), `handle()` (cron/on_match with and without persist), and `fire_handle()` (manual fire) — all 4 paths verified.
4. **History stores only corrected version**: `on_persist` receives the gate-modified SummaryResult, not the raw digest. Structural guarantee verified.
5. **Frontend toggle round-trips correctly**: `review_gate=True` survives create-read round-trip; default is `False`.
6. **never-raise contract maintained**: Step 6 (apply corrections) and Step 7 (audit loop) both wrapped in try/except. No unguarded code paths in `run_review_gate`.
7. **No regressions**: All 76 related tests pass.

## Test Files

- `tests/test_review_gate.py` — 38 tests (31 dev-owned + 7 QA-owned)

No new test files added; all QA-owned tests appended to the existing test module.

## Conclusion

**通过** — review gate is fully testable and passing 38/38 automated tests. QA column from design.md's Test Strategy table: **7/7 implemented, 0 remaining**. No blocking defects found. Ready for retro / ship.

### QA Column Completion

| Test | Owner | Status |
|------|-------|--------|
| `test_review_gate_golden_fed_6_14` | QA | ✅ Implemented |
| `test_review_gate_clean_digest_untouched` | QA | ✅ Implemented |
| `test_review_gate_cross_article_number` | QA | ✅ Implemented |
| `test_review_gate_fabricated_fact` | QA | ✅ Implemented |
| `test_review_gate_all_paths_covered` | QA | ✅ Implemented |
| `test_review_gate_history_one_version` | QA | ✅ Implemented |
| `test_review_gate_frontend_toggle_e2e` | QA | ✅ Implemented |
| Real LLM review replay (the prod host) | manual | Not automated — runbook documented |
| Review cost/latency measurement | manual | Not automated — requires deployment |

**7/7 QA items complete.**
