# Review Gate - Design

## Architecture Overview

复核门（review gate）是 `SummaryPipeline` 内的一个**可选后置步骤**：在 `compute_summary` 生成 digest 正文之后、返回 `SummaryResult` 之前，对开启了开关的 intent **再跑一轮 LLM**，把正文与本批输入文章对照，找出"输入撑不起来"的片段并**就地修正**，返回修正后的正文。

端到端数据流（开关 ON 时）：

```
matches → compute_summary:
    render prompt → llm.summarize() → 原始 digest 正文 summary_raw
    ── review gate（本 feature 新增，仅 ON 时）────────────────
    fetch review_gate flag(intent_id)            # 新增 fetcher
    若 ON：summary = _run_review_gate(            # never-raise，失败 fail-open 返回 summary_raw
              intent_id, summary_raw, articles_text, ordered, language, now)
           ├─ 预算检查超限 → 日志 + 返回 summary_raw
           ├─ llm.summarize(review_prompt, system=review_system)  # 复用同一 self._llm
           ├─ 解析 JSON corrections[]            # 解析失败 → 返回 summary_raw
           ├─ corrections 为空 → 原样返回 summary_raw（零误伤）
           ├─ 逐条 exact-substring 套补丁到 summary_raw
           └─ 每处 emit 审计记录（WARNING 日志，结构化 sink）
    ─────────────────────────────────────────────
    return SummaryResult(summary=<修正后>, citations=..., run_at=<统一的fire time>)   # 引用列表不变
```

**关键落点决策**：gate 放在 `compute_summary` **尾部**（不是放在 `handle`/`fire_handle` 的 compute 与 `_dispatch` 之间）。原因见 Decision D1——因为 **backfill 与 external_fire 直接调用 `compute_summary`、绕过 `handle`/`_dispatch`**，只有放进 `compute_summary` 才能让全部 5 条出 digest 路径统一覆盖，且持久化天然只存修正版（满足"history 只留一份"）。

**统一时间锚（`compute_summary` 顶部 `now`）**：`compute_summary` 在方法顶部设 `now = now or datetime.now(UTC)`，此后的 gate audit 与 `SummaryResult.run_at`（新增可选字段）共用同一个 `now`。`save_summary` 接收 `result.run_at`（优先于自生成 `now()`），消除 cron 路径下 gate 审计与 DB 行之间 `(intent_id, run_at)` join 的竞态。详见 D12。

涉及的 5 条出 digest 路径（全部经 `compute_summary`，自动获得 gate）：

| 路径 | 入口 | 调用 | 文件:行 |
|------|------|------|---------|
| cron 定时 | `pipeline.handle` (`on_match`) | `compute_summary` → `_dispatch`(persist) | `pipeline.py:398,428`；`main.py:311` |
| 手动 fire | `pipeline.fire_handle` | `compute_summary` → `_dispatch` | `api/fire.py:67`；`pipeline.py:482` |
| backfill 回填 | `backfill` 直调 | `compute_summary(now=past)` → `save_summary_or_skip` | `matcher/backfill.py:190,205` |
| external fire | `external_fire` 直调 | `compute_summary` → `save_summary` | `api/external_fire.py:185,210` |
| event-mode flush | `handle(persist=False)` | `compute_summary` → `_dispatch`(不 persist) | `main.py:313` |

## Technology Stack Constraints

- **never-raise 契约**（CLAUDE.md / 既有）：digest 链路任何下游异常都不得让 digest 整条不发。`_run_review_gate` 必须**自身永不抛**，任何失败 fail-open 返回原始正文。对应 requirements 的 fail-open 约束。
- **LLM 后端为 OpenAI-兼容 chat/completions**（`summarizer/llm/api.py`）。`BaseLLMBackend.summarize(prompt, *, system)` 返回**纯字符串**、空串即 `LLMError`（`api.py:73`）。复核轮**复用 `self._llm`**（用户已拍板），**不新增 ABC 方法**——结构化输出走"system 提示要求 JSON + 容错解析"（D3）。
- **prompt 字符预算**：`max_prompt_chars`（`base.py:13`），生成轮已用 `_BUDGET_SAFETY_RATIO=0.85`（`pipeline.py:43`）water-fill 文章。复核轮**复用已 water-fill 的 `articles_text`**（同一 `ordered`、同一 `[i]` 编号），保证复核看到的文章号与正文 `[N]` 一致（D4）。
- **SQLite 迁移**（`db/intents.py`）：新列必须**同时**写进 `_CREATE_INTENTS`（新库）和 `_MIGRATIONS` 的 `ALTER ADD COLUMN`（老库，异常抑制幂等）；`_DROP_COLUMNS` 不动。布尔以 INTEGER 存（沿用 `enabled`/`skip_seen` 惯例）。
- **列位置漂移陷阱**（memory: feedback_sqlite_pragmas）：`_row_to_intent`（`intents.py:208`）按**位置索引**解析，`_SELECT_INTENTS`（`intents.py:133`）列顺序、INSERT 列表（`intents.py:251`）、UPDATE（`intents.py:352,404`）必须四处同步加 `review_gate`，新列追加到**末尾**（created_at/updated_at 之前或之后需与 SELECT 顺序严格一致）。
- **前端三处 wiring**（memory: feedback_frontend / feedback_static_cache_buster）：后端给 intent 加字段，必须同步 `web/static/intents.js` 的 create/edit/render 三处 + `index.html` 控件 + `?v=N` cache-bust，否则用户够不到开关。
- **CI 四道门**（memory: feedback_ci_ruff_format）：push 前 `uvx ruff@0.15 format .`；私有引用 gate 禁 `sembr-dev-docs`/`design.md`/Dxx 编号进公共 `*.py|*.md`。

## Upstream Dependencies

- **`compute_summary` 的 skip/raise 语义**（`pipeline.py:177-396`）：None=配置级跳过，raise=模板/LLM 错。gate 不得改变这套语义——gate 自身失败**不 raise、不返回 None**，而是返回未复核正文（fail-open）。
- **`IntentPromptCtxFetcher` 5-tuple 契约**（`pipeline.py:131`）被 50+ 测试 ctx fixture 依赖（`tests/test_summarizer*.py` 等）。**不扩展此 tuple**（D2）。
- **`save_summary` / `save_summary_or_skip` / `on_persist` 写的是 `compute_summary` 返回的 result**（`summary_history.py:88,123`；`main.py:308`）。gate 改的是返回值的 `summary` 字段，故持久化、`{history}` 注入（`format_history_text`）天然只见修正版——"history 只留一份"由此**结构性满足**，无需改 DB 写入逻辑。
- **`_get_intent_prompt_ctx`**（`main.py:116`）已读取 `Intent` 对象——`review_gate` flag 从同一个 `get_intent` 结果取，无新增 DB 往返。

## Viable Options Considered

### 决策一：gate 落点（D1）

- **方案 1A（选用）— 放进 `compute_summary` 尾部。** 全部 5 条路径统一覆盖；持久化天然只存修正版；external_fire 的 HTTP 返回也是修正版（对外干净）。取舍：`compute_summary` 的"纯生成"职责被加了一步，但用 `if review_gate` 守卫 + 独立 helper 隔离，未开启零影响。
- **方案 1B（否决）— 放进 `handle`/`fire_handle` 的 compute 与 `_dispatch` 之间。** 否决理由：**backfill（`backfill.py:190`）与 external_fire（`external_fire.py:185`）直接调 `compute_summary`，根本不经过 `handle`/`_dispatch`**——这两条路径会绕过复核，违反 requirements"开关挂 intent、覆盖 backfill、无手动绕过口子"的硬约束。requirements 原文写的"compute_summary 之后、_dispatch 之前"在 cron 路径上等价，但放大到全路径只有 1A 成立。

### 决策二：开关 flag 怎么传到 pipeline（D2）

- **方案 2A（选用）— 新增独立 fetcher `get_review_gate: Callable[[int], Awaitable[bool]] | None`。** 构造器可选参数，默认 `None` → 视为 OFF。compute_summary 单独调用它。取舍：多一个注入点，但**纯加法**，不碰 5-tuple 契约，50+ 既有 ctx 测试零改动。
- **方案 2B（否决）— 把 `IntentPromptCtxFetcher` 扩成 6-tuple（加 review_gate）。** 否决理由：`pipeline.py:131` 的 Protocol 与 50+ 测试 fixture（`tests/test_summarizer.py`、`test_summary_history_pipeline.py` 等）都返回/解包 5-tuple，全部要改；收益为零（fetcher 拆分同样能拿到 flag），纯属把改动面放大并制造回归风险。

### 决策三：「只改问题片段」的修复机制（D3）—— 决定"零误伤 vs 抓得到"成败

- **方案 3A（选用）— 检测→代码套 exact-substring 补丁。** 复核 LLM **只输出结构化 JSON**：`{"corrections":[{"error_class","quote","replacement","cited":[N...],"context":<optional>}]}`，`quote` = 原正文里**逐字**要替换的子串，`replacement` = 改后文本（可为空串=删除该片段），可选 `context` = `quote` 前后 ~20 字符用于锚定消歧。代码先做 NFC Unicode 规范化（`unicodedata.normalize`），再对 `summary_raw` 逐条 `str.replace(quote, replacement, 1)`；`quote` 未命中则**跳过该条 + 日志告警**；多次出现则日志告警 "ambiguous"。若提供 `context`，拼接 `context_before+quote+context_after` 做锚定匹配优先于 first-occurrence。
  - **零误伤 by construction**：除被精确引用的子串外，正文字节级不变——直接满足"干净 digest 正文保持不变"成功标准（corrections 空时原样返回，连 LLM 回显都不取）。
  - 审计"修正前→修正后"= `(quote, replacement)`，**免费且精确**。
  - 删除场景（用户明确接受"修正或删除"）= 空 `replacement`。
  - 取舍/残余风险：(a) `quote` 与原文不逐字一致（空白/省略号/Unicode 差异）→ fix-miss，由 NFC 规范化 + 日志告警双缓解（见 R2）；(b) 同名片段在 digest 中多次出现时首次匹配可能错位，由 `context` 锚定 + `count>1` 告警缓解，残余 1.x 可引入 position-index。

- **方案 3B（否决，记为 1.x 候选）— LLM 直接产出"整篇但声称只改问题处"的修正稿 + 改动清单，代码做 diff 校验后采纳。** 能处理跨段重组类修复，但：要么**无条件信任**整篇回写（LLM 可能顺手改坏正确内容 → 违反零误伤），要么引入 diff-coverage 校验（实现复杂、易抖动）。在 requirements"零误伤同等重要"+ v1 简洁优先（memory: feedback_sembr_v1_simplicity）的权衡下推到 1.x；当前失败模式（局部编造）3A 已足够。
- **方案 3C（否决）— 不修复、只在正文标注"⚠️ 存疑"。** 直接违反 requirements 的核心目标"自动修复"（且"正文可见标注"已在澄清阶段被否）。

### 决策四：复核结构化输出怎么承载（D4）

- **方案 4A（选用）— 复用 `self._llm.summarize()`，system 提示强制输出 JSON，代码多层容错解析。** 不动 `BaseLLMBackend` ABC，所有后端零改动。`_parse_review_json()` 6 层恢复：剥围栏 → 截取首 `{` 至末 `}` → 去尾逗号 → `json.loads` → `ast.literal_eval` fallback（Python 单引号/`None`/`True`/`False`）。任一层失败 fail-open。
- **方案 4B（否决）— 给 ABC 加 `review()`/`complete_json()` 方法。** 否决理由：强制所有现存/未来后端实现新方法，为一个可选 feature 抬高 ABC 契约成本；`summarize` 已能携带任意 system + 返回字符串，JSON 在应用层解析即可。

## Decision Log

- **D1 落点**：gate 实现为 `SummaryPipeline._run_review_gate(...)`，在 `compute_summary` 中 `summary = await self._llm.summarize(...)`（`pipeline.py:387`）**之后**、构造 `citations`/`SummaryResult`（`pipeline.py:389`）**之前**调用。仅 `if review_gate` 时进入。→ 实现索引：`pipeline.py:387` 后插入。
    - **统一时间锚**（third-party review F1 采纳）：`compute_summary` 在方法顶部设 `effective_now = now or datetime.now(UTC)`。后续 `get_history_text`、gate audit `run_at`、`SummaryResult.run_at` 三个下游共用此值，消除 cron 路径下 gate 审计与 `save_summary` 各自调用 `datetime.now(UTC)` 导致的跨秒/跨分钟竞态。
- **D2 flag 传递**：`SummaryPipeline.__init__` 新增 `get_review_gate: Callable[[int], Awaitable[bool]] | None = None`（`pipeline.py:155-175`）。compute_summary 在拿到 `intent_id` 后、进入 gate 前 `review_gate = await self._get_review_gate(intent_id)`（None fetcher 或调用异常 → False，fail-open 关门）。`main.py:296` 构造处新增 `get_review_gate=lambda iid: _get_review_gate(iid)`；新增 `_get_review_gate` 读 `intent.review_gate`（复用 `get_intent`）。
- **D3 修复机制**：3A exact-substring patch。`_run_review_gate` 步骤：
    1. 预算检查（见 D5）。
    2. `llm.summarize(review_prompt, system=review_system)`。
    3. 解析 JSON（见 D4）：空 corrections → 原样返回原文（零误伤）。
    4. 对 `summary_raw` 和每条 `quote`/`replacement` 做 **NFC Unicode 规范化**（`unicodedata.normalize('NFC', ...)`）后再逐条 `replace(quote, replacement, 1)`——消除全角/半角、NFC/NFD 组合差异导致的 false fix-miss（third-party review F5 采纳，见 D13）。
    5. 逐条替换前检查 `summary_raw.count(quote)`：`==0` → 跳过 + `logger.warning("unmatched")`；`>1` → `logger.warning("ambiguous: N occurrences, replacing first")`（third-party review F2 采纳）。
    6. 复合消歧：LLM 在 JSON 里可附带可选字段 `context`（`quote` 前后 ~20 字符的原文片段）。代码在 `summary_raw` 中拼接 `context_before + quote + context_after` 做锚定匹配，命中则只替换该锚定位的 `quote`；未命中 fallback 到 first-occurrence `replace`。
    7. 每条命中 emit 审计（见 D6）。
    8. 返回修正文。**全程 try/except 包裹，任何异常 fail-open 返回 `summary_raw`**。
    - **顺序修正干扰**（third-party review F6 采纳）：复核 LLM 的 system 提示要求"邻接或重叠的修正合并为单条，`quote` 取完整跨段"，避免连续 `replace` 互相覆盖导致后条未命中。另可选：代码按位置从后往前套（扫描 `summary_raw.find(quote)` 收集 offsets → 按 offset DESC 排序后依次替换，保证前面的替换不改变后面 offset）。
- **D4 结构化输出**：复用 `summarize`，新增复核用 system/instruction 模板（见 D7），代码侧 `_parse_review_json()` 容错解析，按顺序尝试以下恢复层（third-party review F4 采纳）：
    1. 剥离 markdown 围栏（`` ```json `` / `` ``` ``）及首尾空白。
    2. 从第一个 `{` 到最后一个 `}` 截取（处理 preamble/postamble）。
    3. 正则去尾随逗号：`,(\s*[}\]])` → `$1`（兼容 JavaScript-style 尾逗号）。
    4. `json.loads`；成功则返回。
    5. 失败则 `ast.literal_eval` fallback（处理 Python 单引号/ `None`/`True`/`False`）。
    6. 仍失败 → 抛 `ValueError`，被外层捕获 → fail-open 返回原文 + 日志。
    - 实现后 生产机 真实回放时记录 JSON 成功率到 progress.md，占比低则 1.x 可加 `response_format={"type": "json_object"}`（APIBackend 无需改 ABC）。
- **D5 复核 prompt 组装**：复用 `compute_summary` 已生成的 `articles_text`（同 `ordered`、同 `[i]` 编号）与 `language`。review user prompt = 渲染 `{digest}`(=summary_raw) + `{articles}`(=articles_text) + 语言；review system prompt 含修复规则 + JSON schema 说明 + "只针对输入撑不起来的内容、保持其余逐字不变"。预算：`len(review_system)+len(review_user) > max_prompt_chars*0.85` → 日志 + fail-open 返回原文（不再二次截断，避免复核看残缺文章误删）。
    - **日志预算分解**（third-party review F3 采纳）：超限时 `logger.warning("review_gate budget exceeded: digest=%d system=%d articles=%d total=%d limit=%d", ...)`；budget 内正常进入时 `logger.debug` 同格式，便于诊断"开关 ON 却没有修正"——往往是 digest 自身太长吃掉预算、文章没塞进去（而非 gate 未执行）。→ R5。
- **D6 审计 sink（不堵死未来 B）**：所有审计经**单一函数** `_emit_review_correction(intent_id, run_at, error_class, before, after)` 出口（pipeline 内部或 `summarizer/audit.py`）。当前实现 = `logger.warning("review_gate_audit intent_id=%d run_at=%s class=%s before=%r after=%r", ...)`，外加一行汇总 `logger.warning("review_gate intent_id=%d corrections=%d", ...)`。未来 B 只需把这一个 sink 改成写表，调用点零改动。`run_at` 取值：来自 D1 的统一 `effective_now`（由 `compute_summary` 顶部一次性确定，再传入 `_run_review_gate`），与持久化 `SummaryResult.run_at` 完全一致。**注意**：gate 运行于持久化之前，拿不到 `summary_history.id`，故审计 join key = `(intent_id, run_at)`（summary_history 上恰有 `UNIQUE(intent_id, run_at)`，`summary_history.py:79`）。`effective_now` 在 `compute_summary` 顶部只调一次 `datetime.now(UTC)`，所有下游共享，杜绝 cron 路径跨秒/跨分钟竞态（third-party review F1 采纳，见 D12）。
- **D7 模板**：新增 `prompts/system/review.md` 与 `prompts/instruction/review.md`（占位 `{digest}`、`{articles}`、`{language}`）。复用 `templates.py` 的 `load_template`/`render_*from_raw` 机制（`templates.py:175`），与现有 system/instruction 同构。模板缺失 → fail-open（gate 内 try 捕获，不走 `on_template_error` 那套面向生成轮的告警）。
- **D8 flag 存储**：`intents` 表加 `review_gate INTEGER NOT NULL DEFAULT 0`。`_CREATE_INTENTS`（`intents.py:37`）追加列；`_MIGRATIONS`（`intents.py:64`）追加 `ALTER TABLE intents ADD COLUMN review_gate INTEGER NOT NULL DEFAULT 0`；`_SELECT_INTENTS`（`intents.py:133`）、`_row_to_intent`（`intents.py:208`，新增末位索引并更新索引注释）、create INSERT（`intents.py:251-269`）、update（`intents.py:352,404` 区）四处同步。
- **D9 模型**：`IntentCreate` 加 `review_gate: bool = False`（`models.py:250`）；`IntentUpdate` 加 `review_gate: bool | None = None`（`models.py:294`，None=no-op 沿用现状）；`Intent` 响应模型加 `review_gate: bool`（`models.py:358`）。无需新 validator。
- **D10 前端**：`web/static/index.html` intent 表单加 checkbox「复核门 / Review gate（开启后多一轮 LLM 校对，较慢）」；`intents.js` create payload、edit 预填、（可选）列表 render 三处 wiring；`index.html` 的 `intents.js?v=N`/相关静态 bump +1。
- **D11 默认与零影响**：`review_gate` 默认 0/False；fetcher 默认 None。未开启 intent：`_get_review_gate` 返回 False → 不进 gate → 零额外 LLM 调用、零延迟、行为与现状逐字一致。
- **D12 统一时间锚**（采纳 third-party review F1）：`compute_summary` 方法顶部设 `effective_now = now or datetime.now(UTC)`。gate audit `run_at` 和返回的 `SummaryResult.run_at`（新增可选字段 `run_at: str | None = None`，`summarizer/models.py:24`）共用此值。`on_persist` wrapper 在 `main.py:308` 改为 `lambda r: save_summary(get_conn(), r, run_at=r.run_at)`——`save_summary` 的 `run_at` 参数已存在（`summary_history.py:88`），若传入则用之、否则自生成（向后兼容）。`save_summary_or_skip` 在 backfill 已传显式 `run_at`，不受影响。**效果**：gate 审计日志的 `run_at` 与 `summary_history` 行的 `run_at` 逐字一致（同一秒），`grep` join 可靠。
- **D13 Unicode 规范化**（采纳 third-party review F5）：在 `_run_review_gate` 内，对 `summary_raw` 和每条 `quote`/`replacement` 执行 `unicodedata.normalize('NFC', ...)` 后再做子串替换。防止 LLM 与生成轮编码差异（全角/半角、NFC/NFD）导致逐字匹配失败。标准库 `unicodedata` 零新依赖。

## Risk & Mitigation

| 编号 | 风险 | 缓解 | 残余 |
|------|------|------|------|
| **R1** | 复核 LLM 自己判断错，把正确内容当幻觉，给出错误 `replacement` → 误伤 | 3A 仅替换被精确引用子串、空 corrections 原样返回；fail-open；审计日志逐条 before→after 可事后追责 | 错误 replacement 仍会被套用（v1 接受，可审计）；1.x 可加二次确认 |
| **R2** | (a) `quote` 与原文不逐字一致 → fix-miss，幻觉残留；(b) 同一文本在 digest 中出现多次（如"25个基点"），`replace(quote,...,1)` 可能命中错误位置（third-party review F2） | 未命中 `logger.warning("unmatched")`；多出现告警 `logger.warning("ambiguous: N occurrences")`；LLM 可选附带 `context` 字段做锚定匹配消歧 | 个别 fix 漏修或错位替换（v1 接受，可审计）；1.x 可引入 position-index 精准定位 |
| **R3** | 开启后 cron/fire 多一轮 LLM → 延迟与成本翻倍 | 默认 OFF、opt-in；UI 文案标注"较慢"；复核轮与生成轮共用后端不新增连接 | 开启的 intent 确实变慢（用户知情选择） |
| **R4** | `intents` 列位置漂移 → `_row_to_intent` 解析错位（memory 已记此类 bug） | 新列追加到 SELECT/INSERT/parse **末尾**且四处同步；更新 `intents.py:208` 索引注释；round-trip 测试断言 review_gate 正确回读 | — |
| **R5** | 复核 prompt 超过 `max_prompt_chars*0.85` → 跳过复核。**长 digest（≥3000 字）是常见触发**（非仅"超大批次"边缘）——复核 prompt = system + digest 自身 + articles，digest 自身吃掉的预算往往比 articles 多（third-party review F3） | D5 预算超限 fail-open + 日志附分解（digest/system/articles/total/limit）；`logger.debug` 正常进入时也记分解方便诊断"开关 ON 却无修正" | 长 digest 的 intent 复核被跳过（"发了但没过 gate"≠ "gate 跑了无修正"）；1.x 可对 digest 截断后分段复核 |
| **R6** | 解析 JSON 失败 / LLM 返回非 JSON（尾逗号、preamble、Python 单引号等） | `_parse_review_json` 6 层恢复（D4）→ fail-open 返回原文 + 日志 | 该次不复核（degrade 安全）；1.x 可加 `response_format={"type":"json_object"}` |
| **R7** | gate 内任意未预期异常冒泡，破坏 never-raise | `_run_review_gate` 顶层 `try/except Exception` 包全部逻辑，返回 `summary_raw` | — |
| **R8** | 扩 `__init__` 签名 / 新 fetcher 漏接到某条路径 | 因 D1 gate 在 compute_summary、全路径共用同一 pipeline 实例（`app.state.summary_pipeline`），fetcher 一处注入全路径生效；QA 五路径各验一次 | — |

## Test Strategy & Acceptance Criteria

复核轮用 **stub LLM 后端**（`BaseLLMBackend` 假实现，`summarize` 按调用序返回脚本化字符串：第 1 次=digest，第 2 次=复核 JSON），保证确定性、不依赖真实 LLM。

| 测试 | 设计来源 | Owner | 期望 |
|------|----------|-------|------|
| `test_review_gate_applies_correction` | D3 抓得到 | dev | stub 返回 1 条 correction(quote→replacement)，返回 summary 中该子串被替换，其余字节不变 |
| `test_review_gate_zero_corrections_verbatim` | D3 零误伤 | dev | stub 返回 `corrections:[]` → 返回值 `is`/`==` summary_raw 逐字不变 |
| `test_review_gate_delete_via_empty_replacement` | D3 删除 | dev | 空 `replacement` → 子串被删除 |
| `test_review_gate_unmatched_quote_skips_and_logs` | R2 | dev | quote 不在原文 → 该条跳过、其它条仍套用、warning 日志含 "unmatched" |
| `test_review_gate_llm_error_failopen` | fail-open/R7 | dev | 复核 `summarize` 抛 LLMError → 返回 summary_raw + 日志，不 raise/不 None |
| `test_review_gate_bad_json_failopen` | R6 | dev | 复核返回非 JSON / 半 JSON → fail-open 返回原文 |
| `test_review_gate_budget_overflow_skips` | D5/R5 | dev | 构造超 `max_prompt_chars` → 跳过复核、返回原文、日志 |
| `test_review_gate_off_no_second_llm_call` | D11 零影响 | dev | flag False（或 fetcher None）→ stub `summarize` 仅被调 1 次 |
| `test_review_gate_fetcher_exception_failopen` | D2 | dev | `get_review_gate` 抛异常 → 视为 OFF、不进 gate |
| `test_review_audit_emit_before_after` | D6 | dev | 命中 correction → 审计 sink 收到 (intent_id, error_class, before, after)；汇总行 corrections=N |
| `test_intent_review_gate_roundtrip` | D8/D9/R4 | dev | create review_gate=True → GET 回读 True；位置解析不错位；默认 create 为 False |
| `test_intent_update_review_gate_noop` | D9 | dev | IntentUpdate 不传 review_gate → 沿用原值；传 True/False → 落库 |
| `test_review_gate_golden_fed_6_14` | 成功标准·抓得到 | QA | 以 6/14「沧海一土狗」型样本（正文含编造源名归属）+ 脚本化复核 JSON → 修正版不再含该错误归属 |
| `test_review_gate_clean_digest_untouched` | 成功标准·零误伤 | QA | 干净 digest + stub 返回空 corrections → 对外正文逐字不变 |
| `test_review_gate_cross_article_number` | 错误类型2 | QA | 跨文章数字错配样本 → 对应数字被修 |
| `test_review_gate_fabricated_fact` | 错误类型3 | QA | 凭空事实片段 → 被删除/修正 |
| `test_review_gate_all_paths_covered` | R8/全路径 | QA | cron handle / fire_handle / backfill / external_fire 四入口各跑一次，flag ON 时复核均生效（stub 二次调用） |
| `test_review_gate_history_one_version` | history 只留一份 | QA | 开 gate 跑 cron → summary_history 该行存的是修正后正文（非原始） |
| `test_review_gate_frontend_toggle_e2e` | D10 | QA | 经 API 建带 review_gate 的 intent，dashboard 表单回填勾选态正确 |
| 真实 LLM 复核回放（生产机） | 成功标准·真实验证 | manual | runbook：`ssh <prod-host>`，对一条真实 intent 开 review_gate、replay/fire，观察修正 + `docker logs | grep review_gate_audit` 出 before→after；确认对外 digest 干净 |
| 复核成本/延迟实测 | R3 | manual | 生产机 上实测开/关 gate 的单 intent 端到端耗时差，记入 progress |

**验收标准（可测）**：

1. 6/14 型黄金样本开 gate → 编造源归属被修正或删除（`test_review_gate_golden_fed_6_14` + manual 真实回放）。
2. 干净 digest 过 gate → 对外正文字节级不变（`test_review_gate_clean_digest_untouched`）。
3. 跨文章数字错配 / 凭空事实 / 序号引错 三类各有样本被修（QA 三用例）。
4. 每次有修正，日志 `grep review_gate_audit` 得到逐处 before→after + error_class + intent_id + run_at；外加汇总 `corrections=N`（`test_review_audit_emit_before_after` + manual）。
5. flag OFF 的 intent：复核轮 LLM **零调用**、行为与现状逐字一致（`test_review_gate_off_no_second_llm_call`）。
6. 复核 LLM 失败/超预算/坏 JSON → 原始 digest 照常分发，日志记一条（fail-open 系列用例）。
7. 全部 5 条出 digest 路径在 flag ON 时复核生效（`test_review_gate_all_paths_covered`）。

## File & Responsibility Map

按依赖顺序（dev 实现顺序建议）：

1. **`sembr/db/intents.py`** — 加 `review_gate` 列（`_CREATE_INTENTS` + `_MIGRATIONS` + `_SELECT_INTENTS` + `_row_to_intent` 注释/索引 + create INSERT + update）。四处位置同步（R4）。
2. **`sembr/models.py`** — `IntentCreate`/`IntentUpdate`/`Intent` 三模型加 `review_gate`（D9）。
3. **`sembr/summarizer/models.py`** — `SummaryResult` 加 `run_at: str | None = None`（D12）。
4. **`prompts/system/review.md` + `prompts/instruction/review.md`** — 复核轮模板（D7），含 JSON schema + "只修正输入撑不起来的内容、合并邻接修正" + context 可选字段。
5. **`sembr/summarizer/pipeline.py`** — 核心：
   - `compute_summary` 顶部设 `effective_now = now or datetime.now(UTC)`（D12）；
   - `__init__` 加 `get_review_gate` 参数 + `self._get_review_gate`；
   - `compute_summary` 在 `summarize` 后插入 `if review_gate: summary = await self._run_review_gate(...)`；
   - 新增 `_run_review_gate`（never-raise）、`_parse_review_json`（6 层 JSON 恢复 + NFC 规范化）、审计 sink `_emit_review_correction`（D3/D4/D6/D13）。
   - 可选：审计 sink 与 JSON 解析拆到 **`sembr/summarizer/review.py`**（让 pipeline 不臃肿；dev 酌情）。
6. **`sembr/main.py`** — 新增 `_get_review_gate(intent_id)`（读 `intent.review_gate`）；`SummaryPipeline(...)` 构造处（`main.py:296`）注入 `get_review_gate=`（D2）；`on_persist` wrapper 改为 `lambda r: save_summary(get_conn(), r, run_at=r.run_at)`（D12）。
7. **`web/static/index.html` + `web/static/intents.js`** — checkbox 控件 + 三处 wiring + `?v=N` bump（D10）。
8. **`tests/`** — 上表 dev/QA 用例；新增 stub LLM 多轮脚本化 fixture。

**不改**：`summary_history.py`（持久化天然存修正版）、`notifier/email.py`（对外只见修正版正文，无需标注）、`backfill.py`/`external_fire.py`/`api/fire.py`（经 compute_summary 自动获得 gate，零改动）。

---
*基于 requirements.md（含 2026-06-19 澄清）设计；Open Questions 已在 D1–D11 给出方案。复核轮复用同一 LLM backend（用户拍板）。*
