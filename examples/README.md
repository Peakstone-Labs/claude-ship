# Examples

放一个真实（或脱敏）feature 的完整「七件套」走查，让别人一眼看到产出长什么样：

```
examples/<feature-name>/
├── requirements.md
├── design.md
├── third_party_review.md   # 可选（跨厂商设计评审）
├── implementation.md
├── review.md               # 含 # Loop 1 / # Loop 2 迭代历史
├── test_report.md
├── progress.md
└── retro.md
```

> TODO: 挑一个不含敏感信息的 feature，把它的 `<DOCS_ROOT>/<feature>/` 目录整个拷进来。
> 这是 README 之外最有说服力的东西——读者能看到 review 的预提交预测、loop 收敛、以及第三方评审实际抓到了什么。
