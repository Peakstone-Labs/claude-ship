#!/usr/bin/env bash
# third-party-review.sh — 用第三方厂商模型驱动的 headless Claude Code，
# 对 <feature> 的 design.md 做独立第三方「设计层面」评审，产出 third_party_review.md。
#
# 架构：文本进、文本出。wrapper 把 design.md / requirements.md / 项目 CLAUDE.md 喂进 prompt，
# 子 claude 只需把完整报告作为最终回复输出到 stdout，**由本脚本落盘**——不依赖第三方模型
# 的 Write 工具可靠性（实测部分第三方模型会"口头声称写了"却不真正调用 Write）。
# 仍允许 Read/Glob/Grep，模型可按需查看 design 点名的源码（只读，不改任何文件）。
#
# 用法： cd 进目标 repo 后  ~/.claude/scripts/third-party-review.sh <feature-name> [provider] [model-override]
#   provider        : ~/.claude/providers/<provider>.env 里的 profile（默认 deepseek；另有 kimi）
#   model-override  : 覆盖 profile 的 TPR_MODEL（可选）
#   TPR_DOCS_ROOT   : env，docs 根相对路径（默认 docs/development）
set -euo pipefail

FEATURE="${1:?用法: third-party-review.sh <feature-name> [provider] [model-override]}"
PROVIDER="${2:-deepseek}"
MODEL_OVERRIDE="${3:-}"
DOCS_ROOT_REL="${TPR_DOCS_ROOT:-docs/development}"
REPO_ROOT="$(pwd)"
FEATURE_DIR="$REPO_ROOT/$DOCS_ROOT_REL/$FEATURE"
DESIGN="$FEATURE_DIR/design.md"
OUT="$FEATURE_DIR/third_party_review.md"

PROFILE_DIR="$HOME/.claude/providers"
CONFIG="$PROFILE_DIR/$PROVIDER.env"
AGENT_SPEC="$HOME/.claude/agents/third_party_review.md"
TEMPLATE="$HOME/.claude/templates/development/third_party_review.md"

avail() { ls "$PROFILE_DIR"/*.env 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.env$//' | tr '\n' ' '; }

[[ -f "$DESIGN" ]]     || { echo "ERROR: 找不到 ${DESIGN} —— 先跑 /architect ${FEATURE} 定稿设计。" >&2; exit 1; }
[[ -f "$CONFIG" ]]     || { echo "ERROR: 没有 provider profile '${PROVIDER}'（找 ${CONFIG}）。可用: $(avail)" >&2; exit 1; }
[[ -f "$AGENT_SPEC" ]] || { echo "ERROR: 缺少 agent 规范 ${AGENT_SPEC}" >&2; exit 1; }
[[ -f "$TEMPLATE" ]]   || { echo "ERROR: 缺少模板 ${TEMPLATE}" >&2; exit 1; }

# set -a：profile 里的 ANTHROPIC_* / TPR_* 全部自动 export，传给 headless 子 claude
# shellcheck disable=SC1090
set -a; source "$CONFIG"; set +a
[[ -n "$MODEL_OVERRIDE" ]] && TPR_MODEL="$MODEL_OVERRIDE"
: "${ANTHROPIC_BASE_URL:?profile ${CONFIG} 缺 ANTHROPIC_BASE_URL}"
: "${ANTHROPIC_AUTH_TOKEN:?profile ${CONFIG} 缺 ANTHROPIC_AUTH_TOKEN}"
: "${TPR_MODEL:?profile ${CONFIG} 缺 TPR_MODEL（或用第 3 参数传 model-override）}"

# —— 子进程走 profile 里的第三方 key，清掉可能干扰的 API key ——
unset ANTHROPIC_API_KEY 2>/dev/null || true

# 系统提示 = agent 规范（去掉 YAML frontmatter）
SYS_PROMPT="$(awk 'NR==1 && /^---[[:space:]]*$/ {f=1; next} f && /^---[[:space:]]*$/ {f=0; next} !f' "$AGENT_SPEC")"

# 评审材料喂进 prompt（design 为主，附 requirements + 项目 CLAUDE.md）
section() { [[ -f "$1" ]] || return 0; printf '===== %s (%s) =====\n' "$2" "$1"; cat "$1"; printf '\n\n'; }
INPUTS="$(
  section "$DESIGN" "DESIGN.md（评审主对象）"
  section "$FEATURE_DIR/requirements.md" "REQUIREMENTS.md"
  section "$REPO_ROOT/CLAUDE.md" "项目 CLAUDE.md（架构/约束/红线）"
)"

PROMPT="你是第三方设计评审，未参与本设计。feature='${FEATURE}'。
对下面的 design.md 做**设计层面**独立评审（代码尚未实现，别找代码 bug，要找设计缺陷）。
如需查看 design 点名的现有源码可用 Read/Glob/Grep（只读，可选）。

严格按下面的报告模板结构输出（章节、🔴/🟡/🟢/💡 分级、证据要求都遵守）：
===== 报告模板 =====
$(cat "$TEMPLATE")
===== 模板结束 =====

**输出要求（重要）**：把填好的完整报告作为你的**最终回复正文**直接输出，从 '# ${FEATURE} — Third-Party Design Review' 开头。
只输出报告 markdown 本身，不要任何前后缀寒暄、不要代码围栏、不要解释你在做什么。**不要尝试用工具写文件**——外层脚本会保存你的回复。
在 'Reviewer Context' 的「第三方 provider / model」处**据实填写**：${PROVIDER} / ${TPR_MODEL}（别写"独立评审会话"之类占位）。

===== 评审材料 =====
${INPUTS}
===== 评审材料结束 ====="

echo "[third_party_review] provider=${PROVIDER} (${ANTHROPIC_BASE_URL})  model=${TPR_MODEL}"
echo "[third_party_review] feature=${FEATURE}  →  ${OUT}"
echo "[third_party_review] 启动 headless 子会话…（第三方端点，可能比本地 Claude 慢）"

cd "$REPO_ROOT"
REPORT="$(claude -p "$PROMPT" \
  --model "$TPR_MODEL" \
  --append-system-prompt "$SYS_PROMPT" \
  --allowedTools Read Glob Grep \
  --permission-mode acceptEdits \
  --add-dir "$REPO_ROOT" \
  --output-format text < /dev/null 2>/dev/null)" || {
    echo "[third_party_review] ❌ headless claude 退出非零 —— 检查 profile '${PROVIDER}' 的端点/key/model。" >&2
    exit 2
  }

# 去掉模型偶尔加的 markdown 围栏
REPORT="${REPORT#\`\`\`markdown}"; REPORT="${REPORT#\`\`\`}"; REPORT="${REPORT%\`\`\`}"

if [[ -z "${REPORT//[[:space:]]/}" ]]; then
  echo "[third_party_review] ❌ 子会话返回空 —— 端点/模型可能没产出；换 provider 或查 key/额度。" >&2
  exit 3
fi

printf '%s\n' "$REPORT" > "$OUT"
echo "[third_party_review] ✅ 落盘：${OUT} （$(wc -l <"$OUT" | tr -d ' ') 行）"
