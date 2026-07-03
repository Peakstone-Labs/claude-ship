# Loop 3 — 2026-06-19

## Delta vs Loop 2

### 🟡 Important

#### 🟡-1: Step 7 audit loop not wrapped in try/except
- **Status**: ✅ fixed
- **Evidence**: `sembr/summarizer/review.py:306-339` — audit loop (`for entry in audit_entries`) and summary log now wrapped in `try/except Exception`. Corrections are applied in step 6 before the audit loop, so the `corrected` variable remains in scope even if audit logging fails. `return corrected` at line 341 always executes.
- **Verification**: Step 6 try/except (lines 295-302) establishes `corrected`. Step 7 try/except (lines 306-339) is independent — if it catches, the except logs "corrections still applied, fail-open" and falls through to `return corrected`. Correct behavior.
- **One observation**: The `corrected` variable is assigned inside step 6 try block (line 296) and used at line 341 after step 7's try/except. This works because step 6's except returns `summary_raw` (early return), so the only path reaching step 7 has `corrected` bound. But a future refactor that restructures the try blocks could break this implicit scoping chain. Minor structural note — current code is correct.

### 🟢 Minor

#### 🟢-4: `test_apply_corrections_valueerror_nfc_fail` — misleading test name
- **Status**: ❌ still open — no disposition recorded in implementation.md Loop 3 changes section. Test name still unchanged at `tests/test_review_gate.py:334`.
- **Dev action**: Either rename to `test_apply_corrections_normal_case` or delete (since `test_apply_single_correction` covers the same logic). This is 🟢, not blocking.

### 💡 Suggestion

#### 💡-4: `run_at_str` in `pipeline.py` computed twice
- **Status**: ❌ still open — no disposition recorded. The double computation remains at `pipeline.py:409` and `pipeline.py:420`. No functional impact (both from same `effective_now`), purely cosmetic. Non-blocking.

---

### Delta Summary

| Severity | fixed | accepted-defer | still-open | rejected-defer | regressed |
|----------|-------|----------------|------------|----------------|-----------|
| 🔴 | 0 | 0 | 0 | 0 | 0 |
| 🟡 | 1 | 0 | 0 | 0 | 0 |
| 🟢 | 0 | 0 | 1 | 0 | 0 |
| 💡 | 0 | 0 | 1 | 0 | 0 |

🟢/💡 disposition 完整率: **0/2 (0%)** — neither 🟢-4 nor 💡-4 from Loop 2 have dispositions recorded in implementation.md.

---

## New Findings (Loop 3)

### Pre-commitment Predictions

- 参照: feedback_async_patterns.md (never-raise wrapper dual-try) — Loop 2 🟡-1 fix nested try/except: is `corrected` variable scoping safe after the double-try refactor?
- 参照: feedback_review_patterns.md (alias-literal regression) — `_nfkc` rename in Loop 2: any leftover `_nfc` references in comments, docstrings, or test names?
- 参照: feedback_fix_eagerly.md (fix issues eagerly) — 🟢-4 and 💡-4 from Loop 2 still unresolved; are there new issues that should be fixed this round?
- 预测: `_apply_corrections` returns NFKC-normalized text even when zero corrections are applied (all entries skipped by guards) — violates zero-touch promise for edge case `corrections = [non-dict, non-dict, ...]`
- 预测: Ambiguous-quote warning at line 146 tells user "Consider adding 'context'" even when context WAS provided but anchor match failed — misleading log message

### Predictions vs Reality

| Prediction | Hit? | Finding |
|-----------|------|---------|
| `corrected` scoping after double-try | No | Scoping is correct — step 6 except early-returns, so `corrected` always bound when reaching step 7 and line 341 |
| Leftover `_nfc` references | **Yes** | 🟢-5: Two test names still use `_nfc` (`test_apply_nfc_normalization`, `test_apply_corrections_valueerror_nfc_fail`) |
| New eagerly-fixable issues | **Yes** | 🟢-6: Ambiguous warning misleading when context provided; 🟢-7: NFKC normalization on zero-effective-corrections |
| NFKC on skip-all-edits | **Yes** | 🟡-2: `_apply_corrections` returns NFKC-normalized text even when ALL corrections are skipped by guards |
| Misleading "add context" log | **Yes** | 🟢-6: merged into same finding |

---

### 🔴 Critical

None.

---

### 🟡 Important

#### 🟡-2: `_apply_corrections` returns NFKC-normalized text even when zero corrections are effectively applied

- **文件:行号**: `sembr/summarizer/review.py:84-162`
- **当前代码**:

```python
def _apply_corrections(summary_raw: str, corrections: list[dict]) -> tuple[str, list[dict]]:
    result = _nfkc(summary_raw)  # line 102 — always NFKC-normalizes

    for corr in corrections:
        if not isinstance(corr, dict):
            continue  # line 106 — non-dict entries silently skipped
        ...
        if not quote_raw:
            continue  # line 112-113 — falsy quotes skipped

    return result, audit_entries  # line 162 — returns NFKC-normalized result even if ALL entries skipped
```

- **问题描述**: When the LLM returns a non-empty `corrections` list but every entry is skipped by guard clauses (e.g., `[null, 123, "string"]` — all non-dict), `_apply_corrections` still NFKC-normalizes the entire `summary_raw`. The returned text may differ from the input (NFKC can change fullwidth→halfwidth chars like `，`→`,`).

  The early-return at line 290-291 (`if not corrections: return summary_raw`) correctly handles the empty-list case. But a non-empty list with all entries skipped bypasses this guard.

  Impact: Very low — pathological scenario (LLM returning non-dict entries in a JSON array). NFKC changes are generally invisible or cosmetic. But the "zero corrections → zero touch" guarantee is violated in this edge case.

  Note: Even with valid corrections, the entire output is NFKC-normalized (by design, D13). This finding is specifically about the case where zero corrections take effect but the output is still modified.

- **修复建议**: Add an early check — if no entries pass the `isinstance(corr, dict)` and `quote_raw` guards, return `(summary_raw, audit_entries)` un-normalized:

```python
    result = _nfkc(summary_raw)
    audit_entries: list[dict] = []
    any_applied = False

    for corr in corrections:
        if not isinstance(corr, dict):
            continue
        quote_raw = corr.get("quote", "")
        if not quote_raw:
            continue
        any_applied = True
        # ... rest of correction logic ...

    if not any_applied:
        return summary_raw, audit_entries
    return result, audit_entries
```

  Alternatively, normalize only when at least one correction would be applied. This preserves the "zero effective corrections → verbatim" behavior while maintaining NFKC normalization for actual corrections.

- **影响评估**: Pathological LLM output only. NFKC changes are cosmetic (fullwidth→halfwidth). **不阻塞 v1**。可在 1.x 统一改进（或当轮顺手修，fix_eagerly 偏好）。

---

### 🟢 Minor

#### 🟢-5: Test names still use `_nfc` after `_nfkc` rename

- **文件:行号**: `tests/test_review_gate.py:189, 334`
- **当前代码**:

```python
def test_apply_nfc_normalization():    # line 189
def test_apply_corrections_valueerror_nfc_fail():  # line 334
```

- **问题描述**: Loop 2 renamed `_nfc` → `_nfkc` in production code. Two test names still reference the old name. `grep "_nfc"` in the codebase still returns these hits, which could confuse future readers into thinking NFC (not NFKC) is the active normalization.

- **修复建议**: Rename:
  - `test_apply_nfc_normalization` → `test_apply_nfkc_normalization`
  - `test_apply_corrections_valueerror_nfc_fail` → `test_apply_corrections_normal_case` (also addresses 🟢-4 misleading name)

#### 🟢-6: Ambiguous-quote warning misleading when context was provided but anchor failed

- **文件:行号**: `sembr/summarizer/review.py:143-150`
- **当前代码**:

```python
        if not matched:
            result = result.replace(quote, replacement, 1)
            if n_occurrences > 1:
                logger.warning(
                    "review_gate ambiguous quote: %d occurrences in digest, replacing first. "
                    "Consider adding 'context' to the correction JSON for disambiguation.",
                    n_occurrences,
                )
```

- **问题描述**: When LLM provides a `context` field but the anchor match fails (`result.find(context + quote) == -1`), `matched` stays False. The code falls through to `replace(quote, replacement, 1)` and logs "Consider adding 'context'" — but context WAS already provided. The misleading log wastes operator time investigating why context wasn't used.

  This also means the operator can't distinguish between "LLM didn't provide context" and "LLM provided bad context" from the log alone.

- **修复建议**: Differentiate the two cases:

```python
        if not matched:
            result = result.replace(quote, replacement, 1)
            if n_occurrences > 1:
                if context:
                    logger.warning(
                        "review_gate ambiguous quote: %d occurrences, context anchor failed, "
                        "replacing first occurrence",
                        n_occurrences,
                    )
                else:
                    logger.warning(
                        "review_gate ambiguous quote: %d occurrences, replacing first. "
                        "Consider adding 'context' for disambiguation.",
                        n_occurrences,
                    )
```

  Non-blocking. The correction is still applied correctly either way.

#### 🟢-7: `_nfkc` redundant call when `summary_raw` is already NFKC-normalized

- **文件:行号**: `sembr/summarizer/review.py:102, 115-117`
- **问题描述**: `_nfkc(summary_raw)` at line 102 normalizes the entire text. But for each correction, `_nfkc(quote_raw)` and `_nfkc(replacement_raw)` are also called (lines 115-116). If `quote`/`replacement` are already in NFKC form (common for halfwidth English text and Chinese characters), these are redundant.

  `unicodedata.normalize` is fast (pure C in CPython) — not a performance concern for typical digest lengths. Purely cosmetic.

---

### 💡 Suggestion

None new beyond the still-open Loop 2 items (💡-4).

---

## Overall Verdict

**通过** — 无阻断项。

Loop 2 🟡-1 已正确修复（audit loop try/except）。本轮发现仅有 🟡-2（NFKC normalization on all-skipped corrections，病理场景）和 🟢-5/🟢-6/🟢-7（测试命名遗留 + 日志措辞改进），均不阻塞 v1。

Two Loop 2 findings (🟢-4 misleading test name, 💡-4 run_at_str double compute) remain open without dispositions — dev should record a decision in implementation.md (fix or defer) before QA.

## Decision Verification (Re-check)

Loop 2 changes only touched `review.py` (loop 3: audit loop try/except). No design decisions altered. Re-verifying key decisions:

| Decision | Status | Notes |
|----------|--------|-------|
| D1 gate 落点 | ✅ unchanged | `pipeline.py:396-418` |
| D3 exact-substring | ✅ unchanged | `_apply_corrections` logic unchanged |
| D6 audit sink | ✅ unchanged | `_emit_review_correction` unchanged |
| D8 column sync | ✅ unchanged | All 5 positions confirmed at index 13 |
| D12 unified time anchor | ✅ unchanged | `effective_now` at line 221 |
| D13 NFKC | ✅ unchanged | `_nfkc` function and 5 call sites verified |

## SQLite Column Sync Verification

`_SELECT_INTENTS` (13th column) + `_row_to_intent` index comment (13=review_gate) + INSERT (line 257, 13th position) + `_update_intent_in_txn` (line 361, 13th position) + `_update_intent_raw_in_txn` (line 415, 13th position) — all 5 points consistently at position 13. No changes to `intents.py` in Loop 2 or Loop 3.

---

# Loop 2 — 2026-06-19

## Delta vs Loop 1

### 🔴 Critical

#### 🔴-1: `_apply_corrections` not wrapped in try/except
- **Status**: ✅ fixed
- **Evidence**: `sembr/summarizer/review.py:295-302` — step 6 now wrapped in `try/except Exception`, returns `summary_raw` on failure with `logger.exception`.
- **Test**: `test_apply_corrections_valueerror_nfc_fail` added at `tests/test_review_gate.py:334-338` (though test scope is narrow — see New Finding 🟡-1).

### 🟡 Important

#### 🟡-1: Function name `_nfc` misleading (does NFKC not NFC)
- **Status**: ✅ fixed
- **Evidence**: `sembr/summarizer/review.py:31` — renamed to `_nfkc`. All 5 call sites and test imports updated. Zero grep hits for old `_nfc` name in production code.

#### 🟡-2: Missing `language="en"` test coverage
- **Status**: ✅ fixed
- **Evidence**: `tests/test_review_gate.py:311-318` — `test_gate_language_en_renders` added. Verifies template renders + gate completes with `language="en"` (zero corrections path).

#### 🟡-3: Context anchor only for `n_occurrences > 1`
- **Status**: ✅ accepted-defer
- **Reason**: Deferred to 1.x. Single-occurrence `replace(..., 1)` always hits unique match. Review itself suggested deferral as "risk extremely low" in Loop 1.

### 🟢 Minor

#### 🟢-1: Budget log missing articles field
- **Status**: ✅ accepted-as-is. Deviation documented in implementation.md (digest + articles in same render template). No runtime impact.

#### 🟢-2: `_TRAILING_COMMA_RE` doesn't handle inline comments
- **Status**: ✅ accepted-as-is. 6-layer JSON recovery handles most LLM outputs. No runtime impact.

#### 🟢-3: Non-dict entries in `corrections` list not guarded
- **Status**: ✅ fixed
- **Evidence**: `sembr/summarizer/review.py:105-106` — `if not isinstance(corr, dict): continue` guard added. Test `test_apply_corrections_skips_non_dict_entries` at `tests/test_review_gate.py:321-331`.

### 💡 Suggestion

#### 💡-1: `error_class` enum not enforced
- **Status**: ✅ accepted-defer to future B. No runtime impact.

#### 💡-2: No independent budget config for review round
- **Status**: ✅ accepted-defer to future B. No runtime impact.

#### 💡-3: Audit log WARNING level noise
- **Status**: ✅ accepted-defer to future B. No runtime impact.

### Delta Summary

| Severity | fixed | accepted-defer | still-open | rejected-defer | regressed |
|----------|-------|----------------|------------|----------------|-----------|
| 🔴 | 1 | 0 | 0 | 0 | 0 |
| 🟡 | 2 | 1 | 0 | 0 | 0 |
| 🟢 | 1 | 2 | 0 | 0 | 0 |
| 💡 | 0 | 3 | 0 | 0 | 0 |

🟢/💡 disposition 完整率: **6/6 (100%)** — all 3 🟢 and 3 💡 have explicit dispositions in implementation.md.

---

## New Findings (Loop 2)

### Pre-commitment Predictions

- 参照: feedback_async_patterns.md (never-raise wrapper dual-try) — `run_review_gate` now wraps step 6 in try/except; does the audit loop (step 7) also need wrapping?
- 参照: feedback_sqlite_pragmas.md (SQLite 列位置漂移) — `_nfkc` rename: any leftover `_nfc` references?
- 预测: `test_apply_corrections_valueerror_nfc_fail` 测试名暗示测试异常场景但实际只测正常输入
- 预测: `run_at_str` 在 pipeline.py:409 和 :420 双重计算——gate ON 分支内调一次、外部调一次，虽然同源 `effective_now` 不会发散，但代码重复有未来漂移风险
- 预测: `_emit_review_correction` 在步骤 7 审计循环中未被 try/except 包裹——如果 logger 写入失败会违反 never-raise

### Predictions vs Reality

| Prediction | Hit? | Finding |
|-----------|------|---------|
| Audit loop never-raise gap | **Yes** | 🟡-1: `_emit_review_correction` and unmatched-warning log (lines 306-323) not wrapped in try/except |
| Leftover `_nfc` references | No | Zero grep hits — rename clean |
| Misleading test name | **Yes** | 🟢-4: `test_apply_corrections_valueerror_nfc_fail` tests normal/happy path, not error path |
| `run_at_str` double computation | No | Both derive from same `effective_now` object; `strftime` is deterministic |
| Logger failure → never-raise | **Yes** (merged into 🟡-1) | Same analysis — logger.warning/exception could theoretically fail (disk full / fd exhaustion) |

---

### 🔴 Critical

None.

---

### 🟡 Important

#### 🟡-1: Step 7 audit loop not wrapped in try/except — incomplete never-raise coverage

- **文件:行号**: `sembr/summarizer/review.py:304-333`
- **当前代码**:

```python
    n_matched = 0
    n_unmatched = 0
    for entry in audit_entries:
        if entry["matched"]:
            _emit_review_correction(
                intent_id,
                run_at,
                entry["error_class"],
                entry["before"],
                entry["after"],
            )
            n_matched += 1
        else:
            logger.warning(
                "review_gate unmatched quote intent_id=%d class=%s quote=%r",
                intent_id,
                entry["error_class"],
                entry["before"][:120],
            )
            n_unmatched += 1

    if n_matched > 0 or n_unmatched > 0:
        logger.warning(
            "review_gate intent_id=%d corrections=%d matched=%d unmatched=%d",
            intent_id,
            len(corrections),
            n_matched,
            n_unmatched,
        )
```

- **问题描述**: Step 6 (`_apply_corrections`) 现已正确被 try/except 包裹（🔴-1 修复），但接下来的 step 7 审计循环（遍历 `audit_entries`、调用 `_emit_review_correction` 和 `logger.warning`）**未被 try/except 包裹**。虽然 `logger.warning` 和 `logger.exception` 在 Python 标准库 logging 中极少抛异常（除非 SysLogHandler 远端不可达 / RotatingFileHandler 磁盘满时 handler 自身 emit 失败），但 `_emit_review_correction` 的 docstring 写明 "Future B replaces this one function with a DB write"，如果未来 B 改成了 DB 写入而忘记在此处加 try/except，就会违反 never-raise 契约。

  更严重的是：如果 step 7 中任何一条日志抛异常（例如 `entry["before"][:120]` 切片操作在 `before` 为 `None` 时抛 `TypeError`），当前代码会让异常冒泡出 `run_review_gate`，而 `corrected` 已经计算好了但未被返回——**digest 整条丢失**。

  实际上 `entry["before"][:120]` 能否为 `None`？审计条目 `before` 来自 `quote_raw = corr.get("quote", "")`（line 107），理论上不会是 `None`。但审计条目的结构在 `_apply_corrections` 中构建（lines 124-131 和 153-159），如果未来有人改了结构，这里就可能出错。

  代码意图是明确的（never-raise 注释在 step 6 上方），但 never-raise 范围止于 step 6，step 7 审计日志被视为"安全操作"——这个假设在今天是成立的，但设计上不满足完整防护。

- **修复建议**: 将审计日志循环也纳入 never-raise 保护范围，或者将整个 step 6-7 用一个大 try/except 包裹，保证 `corrected` 一定返回：

```python
    # 6-7. Apply corrections + audit (never-raise; R7).
    try:
        corrected, audit_entries = _apply_corrections(summary_raw, corrections)
        n_matched = 0
        n_unmatched = 0
        for entry in audit_entries:
            if entry["matched"]:
                _emit_review_correction(
                    intent_id, run_at,
                    entry["error_class"], entry["before"], entry["after"],
                )
                n_matched += 1
            else:
                logger.warning(
                    "review_gate unmatched quote intent_id=%d class=%s quote=%r",
                    intent_id, entry["error_class"], entry.get("before", "")[:120],
                )
                n_unmatched += 1
        if n_matched > 0 or n_unmatched > 0:
            logger.warning(
                "review_gate intent_id=%d corrections=%d matched=%d unmatched=%d",
                intent_id, len(corrections), n_matched, n_unmatched,
            )
    except Exception:
        logger.exception(
            "review_gate audit loop failed for intent_id=%d; returning corrected summary",
            intent_id,
        )
        # corrected was already computed before audit entries, so we can still return it
        # BUT in current code structure, corrected is not in scope outside step 6 try block
    return corrected
```

  注意：如果采用此修复，需要确保 `corrected` 变量在 try/except 之外也可见。当前 `corrected` 作用域在 step 6 的 try 块内（line 296）。

- **影响评估**: 当前风险**极低**——Python logging 几乎不抛异常，审计条目字段从未为 `None`。建议在 future B（加 DB write 到 `_emit_review_correction`）之前修复，或至少在那时把整个 block 包裹。

  本题**不阻塞 v1 合并**，因为：
  1. `_emit_review_correction` 当前仅为 `logger.warning`，不抛异常
  2. 如果 logger 真的抛了，Python 的 `logging.raiseExceptions` 默认在非生产环境会打印 `sys.stderr` 但不中止进程
  3. 唯一可通过 `entry["before"][:120]` 触发的场景（`before=None`）在当前代码路径不可能

  降级为 🟡（Important，但在当前 logging-only 实现下可接受 defer）。

---

### 🟢 Minor

#### 🟢-4: `test_apply_corrections_valueerror_nfc_fail` — misleading test name

- **文件:行号**: `tests/test_review_gate.py:334-338`
- **当前代码**:

```python
def test_apply_corrections_valueerror_nfc_fail():
    """_apply_corrections is safe even with problematic input (defensive)."""
    result, audit = _apply_corrections("valid text", [_make_correction("valid", "ok")])
    assert len(audit) == 1
    assert audit[0]["matched"] is True
```

- **问题描述**: 测试名声称测试 `valueerror_nfc_fail`（即 NFKC 规范化导致 `ValueError` 的场景），但 test body 只用完全正常的输入测试基本的 correction 应用。如果 dev 将来搜索 "valueerror" 找这个测试来理解异常场景，会发现它根本不测异常。名字会误导维护者。

  实际上，Python 的 `unicodedata.normalize('NFKC', ...)` 在实践中不抛 `ValueError`（即使 lone surrogate U+D800 也静默通过），所以真正的 `ValueError` 测试可能永远不需要。但测试名应反映其真实意图。

- **修复建议**: 重命名为 `test_apply_corrections_normal_case` 或 `test_apply_corrections_returns_matched`，docstring 改为 "Normal correction applied and audit reports matched"。

  或者（更好的做法）：删除此测试，因为 `test_apply_single_correction`（line 122）已覆盖相同逻辑。当前测试无独立价值。

  不阻塞。

---

### 💡 Suggestion

#### 💡-4: `run_at_str` in `pipeline.py` computed twice — future drift vector

- **文件:行号**: `sembr/summarizer/pipeline.py:409, 420`
- **当前代码**:

```python
                run_at_str = effective_now.strftime("%Y-%m-%dT%H:%M:%SZ")  # line 409 (inside gate ON branch)
                ...
        run_at_str = effective_now.strftime("%Y-%m-%dT%H:%M:%SZ")          # line 420 (unconditional)
```

- **问题描述**: `run_at_str` 在 gate ON 分支内（line 409）计算一次，然后在分支外（line 420）再计算一次。两者都从 `effective_now` 派生，值相同（`strftime` 对同一 `datetime` 对象是确定性的），所以不是 bug。但 line 409 的计算本身是**冗余的**——gate OFF 时 line 409 不执行，line 420 覆盖所有路径。

  如果未来有人 refactor 时把 line 420 改成从 `summary` 或别处取时间（例如"取 LLM 返回的时间戳"），而忘记同样更新 gate ON 分支内的 line 409，就会导致 gate audit `run_at` 与 `SummaryResult.run_at` 不一致，打破 D12 联系。

- **修复建议**: 改为只计算一次，在 gate 块之前或之后统一赋值：

```python
        run_at_str = effective_now.strftime("%Y-%m-%dT%H:%M:%SZ")  # compute once, before gate
        if gate_on:
            from sembr.summarizer.review import run_review_gate  # noqa: PLC0415
            summary = await run_review_gate(
                ...,
                run_at=run_at_str,
                ...
            )
```

  不阻塞 v1。当前行为正确，仅代码风格改进。

---

### 🔴/🟡 Disposition from Loop 1: All Confirmed

All Loop 1 🔴/🟡 findings have been addressed with correct evidence. No regressions detected in the fix code.

### Frontend Verification

- `?v=17` cache-bust unchanged from Loop 1 (correct — no new frontend changes in Loop 2).
- `index.html` checkbox + `intents.js` three-point wiring unchanged from Loop 1.

### SQLite Column Sync Verification

- `_SELECT_INTENTS` (13th column, 0-indexed) + `_row_to_intent` index comment (13=review_gate) + INSERT (line 257, 13th position) + `_update_intent_in_txn` (line 361, 13th position) + `_update_intent_raw_in_txn` (line 415, 13th position) — all 5 points consistently at position 13. Verified in this loop — no regressions.

---

## Design Decision Verification (Re-check)

Loop 2 changes only touched `review.py` and `test_review_gate.py`. No design decisions were altered. Re-verifying key decisions against current code:

| Decision | Status | Notes |
|----------|--------|-------|
| D1 gate 落点 | ✅ unchanged | `pipeline.py:396-418` |
| D12 unified time anchor | ✅ unchanged | `effective_now` computed once at line 221; gate + SummaryResult share it |
| D13 NFKC | ✅ unchanged | `_nfkc` rename verified — zero `_nfc` remnants |
| D3 exact-substring | ✅ unchanged | Try/except added per 🔴-1 fix, no logic changes |
| D8 column sync | ✅ unchanged | All 5 positions confirmed at index 13 |

---

## Overall Verdict

**通过** — 无阻断项。Loop 1 🔴-1 已修复并测试覆盖。新发现仅有 🟡-1（审计循环缺少 try/except，但当前 logging-only 实现下无实际风险）和 🟢-4（测试命名误导），均不阻塞 v1。

---
---

# Loop 1 — 2026-06-19

## Delta vs Loop 0

First review loop — no prior findings to track.

## New Findings (Loop 1)

### Pre-commitment Predictions

Read before code review, based on sembr memory patterns:

- 参照: feedback_sqlite_pragmas.md (SQLite 列位置漂移) — `_row_to_intent` 索引注释是否与 SELECT 列顺序一致
- 参照: feedback_async_patterns.md (never-raise wrapper dual-try) — `_apply_corrections` 是否被 try/except 包裹
- 参照: feedback_frontend.md (前端三处 wiring + cache-bust) — `review_gate` 是否在 create/edit/render 三处 + `index.html` 控件 + `?v=N` 同步
- 预测: JSON parser 尾逗号/围栏对中文/Unicode 内容的处理
- 预测: 模板文件缺失时 `render_system` 是否能正确 fail-open

### Predictions vs Reality

| Prediction | Hit? | Finding |
|-----------|------|---------|
| SQLite 列位置漂移 | No | `_row_to_intent` index 13 与 `_SELECT_INTENTS` 第 14 列(0-indexed:13) 严格对齐，INSERT/UPDATE 四处同步正确 |
| Never-raise violation | **Yes** | 🔴-1: `_apply_corrections` 调用处无 try/except 包裹 |
| Frontend wiring | No | create/edit/payload 三处 wiring + checkbox + `?v=17` 全部正确 |
| JSON parser edge case | No | 6 层恢复覆盖良好，测试通过 |
| Template fail-open | No | `run_review_gate` 正确捕获 `TemplateNotFoundError`/`TemplateRenderError`/`FileNotFoundError` |

---

### 🔴 Critical

#### 🔴-1: `run_review_gate` 未包裹 `_apply_corrections` 调用 — never-raise 契约缺口

- **文件:行号**: `sembr/summarizer/review.py:292`
- **当前代码**:

```python
    # 6. Apply corrections + audit
    corrected, audit_entries = _apply_corrections(summary_raw, corrections)
```

- **问题描述**: `run_review_gate` 的 docstring 声明 "Never raises — every failure path returns *summary_raw* unchanged"。steps 1-4（模板渲染、预算检查、LLM 调用、JSON 解析）各自有 try/except 防护，但 step 6 `_apply_corrections` 没有 try/except 包裹。虽然 `_apply_corrections` 目前只做纯字符串操作（`str.replace`/`str.find`/`str.count`/`unicodedata.normalize`），理论上不易抛异常，但 `unicodedata.normalize` 对某些极端的 surrogate pair 或无效 Unicode 序列可能抛 `ValueError`，且 audit loop 中 `_emit_review_correction` 也可能意外抛异常。按 design.md R7 的 never-raise 要求，这一步应被包裹。

  `_apply_corrections` 的 docstring（review.py:96-97）明确写 "The caller (`_run_review_gate`) wraps this in a try/except so any unexpected failure degrades safely to the original summary"，但实际代码未实现此承诺。

- **修复建议**:

```python
    # 6. Apply corrections + audit
    try:
        corrected, audit_entries = _apply_corrections(summary_raw, corrections)
    except Exception:
        logger.exception(
            "review_gate _apply_corrections failed for intent_id=%d; fail-open",
            intent_id,
        )
        return summary_raw
```

---

### 🟡 Important

#### 🟡-1: 函数名 `_nfc` 与实际行为不一致 — 做的是 NFKC 而非 NFC

- **文件:行号**: `sembr/summarizer/review.py:31-36`
- **当前代码**:

```python
def _nfc(text: str) -> str:
    """Normalize to NFKC so fullwidth/halfwidth and composed/decomposed
    differences don't break exact-substring matching (D13).
    NFKC (rather than NFC) is used because fullwidth→halfwidth conversion
    (e.g. `，` → `,`) requires compatibility decomposition."""
    return unicodedata.normalize("NFKC", text)
```

- **问题描述**: 函数名为 `_nfc`，但实际执行 `unicodedata.normalize("NFKC", ...)`。docstring 解释了为什么用 NFKC（全角→半角需要 compatibility decomposition），这是正确的技术选择。但函数名 `_nfc` 对阅读者产生误导——看到 `_nfc(...)` 会以为在做 NFC normalization。调用处（review.py:102）的注释也写 "NFKC-normalised space"，与函数名矛盾。design.md D13 原定 NFC，实现偏差到 NFKC 已在 implementation.md 记录，但函数名应该反映实际行为。

- **修复建议**: 重命名为 `_nfkc`，同步更新所有调用处及注释：

```python
def _nfkc(text: str) -> str:
    """Normalize to NFKC so fullwidth/halfwidth and composed/decomposed
    differences don't break exact-substring matching (D13)."""
    return unicodedata.normalize("NFKC", text)
```

调用处同步：`result = _nfkc(summary_raw)` (line 102), `quote = _nfkc(quote_raw)` (line 113), `replacement = _nfkc(replacement_raw)` (line 114), `context = _nfkc(context_raw)` (line 115)。测试中的 `_nfc` 引用也同步改为 `_nfkc`。

---

#### 🟡-2: `review.md` system prompt 模板缺少 `{language}` 替换验证 — 若模板缺此占位符会静默通过但 LLM 看不到语言指令

- **文件:行号**: `prompts/system/review.md:49`
- **当前代码**:

```
Respond in: {language}. Error class names and JSON keys are always in English.
```

- **问题描述**: `render_system`（templates.py:123-137）使用 `_StrictMap(language=language)` 做严格占位符检查——如果模板不含 `{language}` 会抛 `KeyError` 触发 `TemplateRenderError`。这点设计是正确的。但 review.md 模板中的 `{language}` 出现在最后一行 "Respond in: {language}"——如果用户编辑模板时意外删除了这一行，render 会因 `_StrictMap` 严格检查而失败。这本身是好的保护。**但**模板里没有再提到 `{language}` 以外的条件——如果 LLM 输出是中文而语言标记为英文，gate 无法区分。这不是代码缺陷，但测试应覆盖 `language="en"` 时的模板渲染（尤其是非中文场景下的 prompt 是否仍要求 JSON 输出）。

  当前 `test_review_gate.py` 所有测试都用 `"zh"` 做 language 参数。英文/其他语言路径未经测试。降低为 Minor：language 参数在 run_review_gate 中透传到 `render_system`，路径无逻辑分支，但缺乏覆盖。

- **修复建议**: 在 `test_review_gate.py` 中增加一条 `language="en"` 的集成测试，确保英文模板渲染不报错。

---

#### 🟡-3: `_apply_corrections` context anchor 仅检查 n_occurrences > 1 — 单次出现时忽略 context 字段

- **文件:行号**: `sembr/summarizer/review.py:133`
- **当前代码**:

```python
        # Context-anchored match (D3)
        if context and n_occurrences > 1:
            needle = context + quote
            idx = result.find(needle)
            if idx != -1:
                start = idx + len(context)
                result = result[:start] + replacement + result[start + len(quote) :]
                matched = True
```

- **问题描述**: 当 `n_occurrences == 1` 时（quote 在文中只出现一次），即使 LLM 提供了 `context` 字段，代码也直接跳到 `first-occurrence replace`。这在当前实现下是正确的——因为只有 1 次出现，`replace(...1)` 总能命中。但如果存在 edge case：NFKC 规范化后的文本中 quote 出现了 1 次，但 LLM 提供的 `context` 锚定到的位置与实际不同（例如 LLM 用半角逗号而 digest 用全角），`replace(...1)` 可能替换到错误位置（虽然有 `context` 锚定本可更精确）。当前 `context` 只在多出现时启用，单出现时不验证。实际上单出现时也可以走 `context + quote` 锚定以消除位置歧义。

  不过当前风险极低——单出现时 `replace(...1)` 总能命中唯一实例。建议仅在 1.x 改为始终用 anchor（若有 context）以保持一致性和防御性。

- **修复建议**: 可将 context 检查提升到 n_occurrences 判断之前（Defer to 1.x，风险极低）：

```python
        if context:
            needle = context + quote
            idx = result.find(needle)
            if idx != -1:
                start = idx + len(context)
                result = result[:start] + replacement + result[start + len(quote) :]
                matched = True
        if not matched:
            result = result.replace(quote, replacement, 1)
```

---

### 🟢 Minor

#### 🟢-1: `run_review_gate` 预算超限日志与设计偏差 — 缺少 articles 字段

- **文件:行号**: `sembr/summarizer/review.py:241-259`
- **当前代码**:

```python
        logger.warning(
            "review_gate budget exceeded for intent_id=%d: "
            "digest=%d system=%d total=%d limit=%d; "
            ...
```

- **问题描述**: design.md D5/R5 要求日志分解为 `digest/system/articles/total/limit` 五段，但实现只有 `digest/system/total/limit` 四段。implementation.md 已记录此偏差（"digest 和 articles 混在同一个渲染模板中无法精确拆分"），这是合理的简化——`articles = total - digest - system` 可反推。但 budget 正常进入时的 `logger.debug` 也缺少 articles 分解，使得诊断"开关 ON 却无修正"时需手动反推。

- **建议**: 在 debug 日志里加 `articles (est)` 推估值（`total - digest - system`），或保持现状。不阻塞。

#### 🟢-2: `_TRAILING_COMMA_RE` 正则未处理行内注释或空值

- **文件:行号**: `sembr/summarizer/review.py:28`
- **当前代码**:

```python
_TRAILING_COMMA_RE = re.compile(r",(\s*[}\]])")
```

- **问题描述**: 当 LLM 输出 `"key": "value", // comment` 这种 JavaScript-style 尾逗号（带行注释），正则无法处理。不过 `json.loads` / `ast.literal_eval` 已覆盖大部分 real-world 场景，且 6 层恢复有 fallback。实测所有 28 测试通过。不阻塞。

#### 🟢-3: `corrections` 字段在非 list 时返回原文但未检查 entries 的具体结构

- **文件:行号**: `sembr/summarizer/review.py:279-285`
- **当前代码**:

```python
    corrections = parsed.get("corrections", [])
    if not isinstance(corrections, list):
        logger.warning(
            "review_gate 'corrections' is not a list for intent_id=%d; fail-open",
            intent_id,
        )
        return summary_raw
```

- **问题描述**: 通过了 `isinstance(corrections, list)` 检查后，每个 element 被当作 dict 使用（`.get("quote", "")` 等）。若 LLM 返回 `{"corrections": [null, "string", 123]}`，`_apply_corrections` 中 `.get("quote")` 会在非 dict 元素上抛 `AttributeError`。这在 🔴-1 未修复时有潜在风险；修复后 fallback 到 fail-open。

- **建议**: 在 `_apply_corrections` 循环开头加一句类型守卫（或通过 🔴-1 的 try/except 间接覆盖）：

```python
    for corr in corrections:
        if not isinstance(corr, dict):
            continue
        ...
```

---

### 💡 Suggestion

#### 💡-1: `review.md` system prompt 中的 `error_class` 枚举值与代码未联动

- **文件:行号**: `prompts/system/review.md:25` vs `sembr/summarizer/review.py` (全文件)
- **问题描述**: system prompt 定义了 4 种 error_class：`source_attribution | cross_article | fabricated_fact | wrong_citation`。代码中 `_apply_corrections` 仅从 JSON 读取 `error_class` 并透传到审计日志，不做校验。如果 LLM 输出无效 error_class（如拼写错误），审计日志会出现不规范分类。当前无运行时校验，但也不影响功能（fail-open 设计）。Future B 如有能力做 intent-level 审计查询，不一致分类会成为问题。

- **建议**: 在 1.x 添加 `error_class` 的运行时校验（可选常数集合），不合规值 default 到 `"unknown"` 并日志告警。v1 不阻塞。

#### 💡-2: 复核 prompt 可与生成 prompt 共用 `max_prompt_chars` 上限 — 但复核轮无独立配置

- **问题描述**: 复核轮复用 `llm.max_prompt_chars * _BUDGET_SAFETY_RATIO (0.85)` 作为预算上限，与生成轮相同。如果生成轮已接近上限（长 digest + 多文章），复核轮大概率超预算被跳过。这是 design.md R5 已记录的 trade-off。当前无独立配置项可调。

- **建议**: 1.x 可加 `SEMBR_REVIEW_MAX_PROMPT_CHARS` 环境变量做独立预算覆盖，让用户可给复核轮更大预算。v1 不阻塞。

#### 💡-3: 审计日志仅 WARNING 级别 — 对下游日志系统可能有噪音

- **文件:行号**: `sembr/summarizer/review.py:175, 317`
- **问题描述**: `_emit_review_correction` 和汇总日志都用 `logger.warning` 级别。对于正常运行的 gate（期望会有一些修正），每条修正打 WARNING 会让日志系统出现告警噪音。INFO 可能更合适——因为 gate 正常运作不是异常。

- **建议**: 将审计日志降为 `logger.info`，仅在异常路径（unmatched/ambiguous/unexpected）保留 WARNING。Future B 有了 DB 落库后可全部降为 INFO。

---

## Design Decision Verification

逐条核对 design.md 的 Decision Log：

| Decision | 验证结果 | 说明 |
|----------|----------|------|
| D1 gate 落点 | ✅ 正确 | `pipeline.py:396-418`，在 `summarize` 后、`SummaryResult` 构造前 |
| D2 flag fetcher | ✅ 正确 | `main.py:130-142` + `pipeline.py:166,177,396-405`，独立 fetcher 不改 5-tuple |
| D3 exact-substring patch | ✅ 正确 | `review.py:84-160`，逐条 replace+context 锚定+occurrence 告警 |
| D4 6-layer JSON recovery | ✅ 正确 | `review.py:39-81`，围栏→截取→尾逗号→json→ast，测试覆盖 |
| D5 budget check | ✅ 正确 | `review.py:226-259`，超限 fail-open + 日志 |
| D6 audit sink | ✅ 正确 | `review.py:163-182`，单一出口 `_emit_review_correction` + 汇总行 |
| D7 review templates | ✅ 正确 | `prompts/system/review.md` + `prompts/instruction/review.md` |
| D8 flag storage | ✅ 正确 | `db/intents.py` 7 处 touch point（CREATE/MIGRATIONS/SELECT/_row_to_intent/create/_update_in_txn/_update_raw_in_txn）全部同步 |
| D9 Pydantic models | ✅ 正确 | `models.py:264,310,369`，`IntentCreate`/`IntentUpdate`/`Intent` 三模型 |
| D10 frontend | ✅ 正确 | `index.html:1469-1480` checkbox + `intents.js:224,279,533` 三处 wiring + `?v=17` |
| D11 default OFF | ✅ 正确 | `review_gate: bool = False` 默认，fetcher None → 不进 gate |
| D12 unified time anchor | ✅ 正确 | `pipeline.py:221` effective_now → gate run_at → `SummaryResult.run_at` |
| D13 Unicode NFKC | ✅ 正确 | `review.py:31-36`，NFKC 而非 NFC 已在 implementation.md 记录偏差 |

**全部 13 个 Decision 正确实现。**

## Missing Coverage

- **`_apply_corrections` 异常路径测试缺失**: 设计明确要求此函数被 try/except 包裹，但既无包裹也无对应 fail-open 测试。参见 🔴-1。
- **Language="en" 的模板渲染测试缺失**: 所有 28 个测试都用 `"zh"`，无英文/其他语言路径覆盖。参见 🟡-2。
- **`corrections` 列表中非 dict 元素的容错测试缺失**: 参见 🟢-3。

## Overall Verdict

**附条件通过** — 🔴-1 必须修复后方可通过 review gate。

阻塞项: 🔴-1 (`_apply_corrections` 未包裹 try/except，违反 never-raise 契约)。
非阻塞项: 🟡-1 (函数名 `_nfc` → `_nfkc`)、🟡-2 (language 测试覆盖)、🟡-3 (context anchor 单出现时不启用)。
