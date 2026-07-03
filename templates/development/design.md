# {FeatureName} - Design

## Architecture Overview
端到端架构、主要模块、依赖关系。

## Technology Stack Constraints
非默认配置陷阱和强制约束（从 CLAUDE.md 继承 + feature 特有）。

## Upstream Dependencies
已落地且本 feature 必须遵守的决策。

## Viable Options Considered
**非平凡设计必填**：列 ≥2 个方案，逐个说明取舍。被否决方案要具体到"不满足 X 约束"或"导致 Y 失败场景"，禁止说"更好"。

## Decision Log
逐条列出所有设计决策及其选择理由、实现索引（文件:行号）。

## Risk & Mitigation
已知设计风险和对应缓解方案。

## Legacy Behavior Audit（refactor / 合并类 feature 必填；非此类可省略）

列被合并/替换的旧类/函数。每个被搬运的方法必须显式审计，避免"默认沿用 = 连旧 bug 一起搬"：

| 方法 | 旧实现位置 | 已知/疑似缺陷 | 本次决定（沿用 / 修复） | 修复方案 / 沿用理由 |
|------|-----------|--------------|----------------------|--------------------|
| (例) `CachedCOSStorage._head_etag` | cached_cos.py:131 | 吞所有 CosServiceError（403/5xx 被当"不存在"） | 修复 | 只对 NoSuchKey/NoSuchResource 返 None，其他 re-raise |
| (例) `CachedCOSStorage._save_etag_index` | cached_cos.py:46 | 非原子 write_text，断电留半文件 | 修复 | tmp + os.replace |
| (例) `LocalStorage.read_json` | local.py:65 | 无 | 沿用 | 旧实现正确；新类 LOCAL 分支行为等价 |

至少覆盖 4 类 concern：**error handling / 原子性 / 日志级别 / 资源释放**。
不写入本表的方法默认视为"修复"（强制显式打勾"沿用"才算审计过）。

## Test Strategy & Acceptance Criteria

核心验证场景、安全关键测试、验收标准（90%+ 需可测）。

测试用例表**必含 `Owner` 列**，取值之一：

- **dev**：dev 阶段必须实施。锁定 🔴/🟡 修复路径、设计核心决策（D 编号字段）、新增 happy-path 的最少集合。dev loop 末未覆盖即视为未完成。
- **QA**：QA 阶段实施。边界保护、错误路径、跨字段交互、设计 Risk 表里 R 编号场景、coverage gap 补齐。
- **manual**：依赖 prod 数据 / 远端环境 / 无 e2e 测试栈 — 写明实施脚本路径或 runbook 章节，不计入 /ship gate。

模板：

| 测试 | 设计来源 | Owner | 期望 |
|------|----------|-------|------|
| (例) `test_post_X_happy_path` | D1 + (i) | dev | POST 200 + DB 一行 |
| (例) `test_post_X_4th_item_rejected` | (vi) 边界 | QA | 422 detail 指明 field |
| (例) `test_fire_X_e2e_recall_baseline` | (ii) 召回基线 | manual | `scripts/qa_X_recall.py`，依赖 prod data |

Owner 字段为强制 — 写完表后再 reviewer 抽检"dev 列是否锁住所有 🔴/🟡 修复 + 核心 D 决策"、"QA 列是否覆盖所有 R 编号风险与边界"。

## File & Responsibility Map
涉及的所有文件、模块间依赖顺序。
