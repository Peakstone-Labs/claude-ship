---
description: 用第三方厂商模型对 design.md 做独立第三方设计评审（建议性，不阻断 ship）
argument-hint: <feature-name> [provider: deepseek|kimi]
---

为 feature `$ARGUMENTS` 跑一次**第三方设计评审**：启动一个由**第三方厂商模型**驱动的 headless Claude Code 子会话，
读 design.md → 独立思考 → 写 `third_party_review.md`。**在当前 session 中按下列步骤编排**——你自己不评审，只负责选 provider + 拉起子会话 + 校验落盘。

## 解析参数

- **feature**：`$ARGUMENTS` 第一个 token。
- **provider**：默认 `deepseek`。若用户在参数或对话里指明（"用 kimi" / "deepseek" / "用 flash 档"），据此选：
  - 可用 profile = `~/.claude/providers/*.env`——每个 profile 指向一个**兼容 Anthropic Messages API** 的第三方端点（示例：`deepseek`、`kimi`；你在各自 `.env` 里填 BASE_URL / TOKEN / MODEL）。
  - 若用户点名了具体模型档，作为 **model-override** 传第 3 参数（该 profile 支持的某个 model id）。

## 前置检查

- 必须先 `cd` 进目标 repo；本命令用 `pwd` 作仓库根。
- `<DOCS_ROOT>`：读本 repo `CLAUDE.md` 的 `## Documentation Paths` 段；缺失则用默认 `docs/development`。
- `<DOCS_ROOT>/<feature>/design.md` 不存在 → **停**，提示先 `/architect <feature>` 定稿。
- 选定 provider 的 profile（`~/.claude/providers/<provider>.env`）不存在 → **停**，列出可用 profile。

## 执行

运行（provider 默认 deepseek 时可省略；`<DOCS_ROOT>` 非默认时加 `TPR_DOCS_ROOT=<rel>` 前缀）：

    ~/.claude/scripts/third-party-review.sh "<feature>" [provider] [model-override]

例：

    ~/.claude/scripts/third-party-review.sh my-feat                                # 默认 provider profile
    ~/.claude/scripts/third-party-review.sh my-feat kimi                           # 换用另一个 provider profile
    ~/.claude/scripts/third-party-review.sh my-feat deepseek <model-id>            # 覆盖该 profile 的默认模型

脚本会：用该 profile 的 `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` 把子 `claude -p` 指到第三方厂商 →
仅允许 Read/Glob/Grep + Write → 自动落盘 `<DOCS_ROOT>/<feature>/third_party_review.md`。

## 校验 + 汇报

- 脚本返回后 `ls -la <DOCS_ROOT>/<feature>/third_party_review.md` 确认落盘。**不存在** → 报告失败原因
  （profile 的 endpoint/key/model 不可用，或子模型没遵守写文件指令），**不要自己代写**那份评审。
- 读该文件，向用户**简短**汇报：用了哪个 provider/model + Overall Verdict + 🔴/🟡 计数 + top 3 标题。
- 末尾提醒：**建议性产出，`/ship` 不读它**。是否回 `/architect <feature>` 修 design 由用户决定；改完可直接 `/ship <feature>`。
