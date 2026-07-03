# claude-ship

**Loop Engineering 方法论的可用实现** —— 一套在生产环境里跑了半年的 [Claude Code](https://claude.com/claude-code) 多 agent 开发流水线,装进 `~/.claude` 即可用。用工程约束对抗 AI 和人性的共同弱点：确认偏误、技术债积累、记忆衰退、审查疲劳。

不是"让 AI 循环写代码",而是把人类团队几十年攒下的治理手段(评审、测试、分权、留痕、复盘)搬到 agent 团队上。

> **TL;DR (EN)** — **claude-ship** is a battle-tested multi-agent dev pipeline for [Claude Code](https://claude.com/claude-code) that implements the *Loop Engineering* methodology: `clarify → architect → (third-party review) → ship → retro`. Each stage is an isolated subagent with its own role, model, and tool scope. The author never reviews their own code; a *different vendor's* model red-teams the design before any code exists; every run leaves an auditable paper trail; and a retro→memory loop makes the reviewer better over time. Prompts are Chinese-first. MIT licensed — copy it into `~/.claude/` and adapt.

---

## 流水线

```
/clarify ──▶ /architect ──▶ (/third_party_review) ──▶ /ship ─────────────▶ /retro
    │             │                   │                  │                    │
requirements   design.md      third_party_review.md   dev→review→qa       memory
   .md                          (可选·跨厂商评审)      循环到 🔴/🟡 gate 清    (事故模式)
                                                            │
                                        implementation / review / test_report / progress
```

产出统一落在 `<DOCS_ROOT>/<feature-name>/`,形成一套可追溯的文档("七件套 + 可选的第三方评审"):

`requirements` → `design` →（`third_party_review`)→ `implementation` → `review` → `test_report` → `progress` → `retro`

**核心理念:文档是 agent 之间的接口。** agent 是无状态的;这些文档才是系统的记忆与交接协议。

---

## 七个 agent

| Agent | 角色 | 模型 | 工具 |
|---|---|---|---|
| `clarify` | 单问循环澄清需求,产出 requirements.md | 默认 | 只读 + 写文档 |
| `architect` | 分解为技术设计,非平凡设计需列 ≥2 可行方案 | 默认 | 只读 + 写 + Bash |
| `third_party_review` | **跑在第三方厂商模型上**,对 design 做独立设计评审(建议性) | 第三方端点 | 只读 + 写 |
| `dev` | 按设计实现代码,**不得自我评审** | `sonnet` | 读写 + Bash |
| `review` | 同行评审,含预提交预测 | `opus` | 读写 + Bash |
| `qa` | 测试新功能 + 验证 review 修复 | `sonnet` | 读写 + Bash |
| `retro` | 复盘,按三条准入过滤 memory | 默认 | 只读 + 写文档 |

模型分配不是"哪个强用哪个",是"什么任务需要什么认知特征":review 用 Opus(高判断力),dev/qa 用 Sonnet(快速执行)。

---

## 四个反直觉的设计决策

1. **clarify 一次只问一个问题** —— 人的注意力是串行的,批量提问=批量敷衍。先读代码再提问,代码能回答的问题不该出现在对话里。有"够了/开始设计"退出机制 + 第 8 轮循环保护。
2. **review 读代码前先"猜"哪里会错** —— 先只读设计、列出 3-5 个最可能的缺陷区域,再带着预测去审。记录命中的、也记录**没预测到**的(后者是认知盲区)。预测起点来自 memory 里的历史事故模式。
3. **分级阻断 + 低风险即修** —— 🔴/🟡 阻断循环;🟢/💡 若满足"有据/无副作用/≤20 行单文件/免确认"四条则**必须修**。延后理由有白名单,模糊措辞(如"后续优化")照样阻断。
4. **retro 的 memory 三条准入** —— 必须同时满足 Non-Googleable / Codebase-Specific / Hard-Won 才存;总量硬性保持 5–8 条。噪音会毒化下一次 review 的预测命中率。

**跨厂商评审(`third_party_review`)** 是最新的一块:review 和 qa 跑在同一模型家族上,会共享盲区。所以在写任何代码之前,用**另一个厂商**的模型(通过 `ANTHROPIC_BASE_URL` 切端点)独立红队 design.md,专抓 Claude 因共有训练偏见看不见的设计缺陷。它是**建议性的,不阻断 `/ship`**。

> 更完整的设计动机见配套文章:**《Loop Engineering》**(链接待补)。

---

## 目录结构

```
loop-engineering/
├── commands/                   # slash 命令(/clarify /architect /ship ...)
├── agents/                     # subagent 人格定义(含模型/工具路由)
├── templates/development/      # 八个文档模板
├── scripts/third-party-review.sh
├── third-party-review.d/
│   └── provider.env.example    # 第三方端点配置模板(真 .env 已 gitignore)
├── examples/                   # 一个真实 feature 的七件套走查(建议补充)
└── install.sh
```

## 安装

```bash
git clone https://github.com/Peakstone-Labs/claude-ship.git
cd claude-ship
./install.sh          # 拷贝进 ~/.claude(可用 CLAUDE_HOME 覆盖目标)
```

之后在任意项目里:`/clarify <feature>` → `/architect <feature>` →(可选 `/third_party_review <feature>`)→ `/ship <feature>` → `/retro <feature>`。

## 前置要求

- **[Claude Code](https://claude.com/claude-code)**(slash 命令 + subagent)。
- 目标项目建议有一份 **`CLAUDE.md`**,可含 `## Documentation Paths` 段指定 `<DOCS_ROOT>`(缺省 `docs/development`)。所有 agent 的有效性取决于项目上下文的准确度——垃圾进垃圾出。
- **`/third_party_review` 额外需要**:一个 bash 环境(Windows 用 Git-Bash)+ 一个第三方 provider profile。复制 `third-party-review.d/provider.env.example` 为 `<provider>.env`(如 `deepseek.env`),填入兼容 Anthropic Messages API 的 `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `TPR_MODEL`。**真 `.env` 已被 gitignore,切勿提交 token。**

## 安全

- 仓库不含任何密钥。第三方端点凭证只存在于本地 `third-party-review.d/*.env`(已 gitignore)。
- 文档模板与提示词里的示例已脱敏为通用软件场景。

## License

[MIT](LICENSE) © 2026 Peakstone Labs
