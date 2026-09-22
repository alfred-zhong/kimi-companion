# 0003 — 用量按 `model` 的 `<Provider>/` 前缀归属

per-provider 的 token 用量按 `usage.record.model` 的 `<Provider>/` 前缀归属，逐字匹配（其中一个 provider 名含空格）。`llm.request` 事件的 `provider` 字段**恒为 `"openai"`**，是 wire 协议类型而非 provider 身份，不能用于归属。未匹配任何已知 provider 的用量在菜单尾行单独成行，不丢弃。

## Status

已采纳（Accepted）。

## Context

- `wire.jsonl` 里 `usage.record` 行的 `model` 形如 `"DeepSeek/deepseek-flash"` / `"OpenCode Go/deepseek-v4.1-flash"`：首个 `/` 之前就是 provider 段名，与 `config.toml` 的 `[providers.<段名>]` 逐字一致（`"OpenCode Go"` 含空格）。
- 看起来更「正确」的字段是 `llm.request` 事件里的 `provider`，但实测它**两个 provider 都是 `"openai"`**——那是 wire 协议类型（OpenAI 兼容协议），不是 provider 身份。用它归属会把两个 provider 的用量混成一桶。
- 一条 `usage.record` 是**单次 LLM 调用的增量**，不是累计快照：同一 session 的 `output` 序列实测非单调（187 → 165 → 170 → 1654 → …）。因此直接按字段求和，不做差分。
- 每个 agent 的 `wire.jsonl` 完全独立、跨文件零重复（实测 600 条记录 600 个不同签名，0 条出现在多个文件里）。归属不需要跨文件协调，只需要一条稳定去重键。
- 归属不可能 100% 覆盖：模型标识前缀可能与任何已配置 provider 都不匹配（用户接了别的 provider，或 kimi-code 引入新 provider）。丢掉这些用量会让「今日总量」悄悄少算——对读数类 app 来说静默少算是最糟的失败方式。

## Considered Options

1. **按 `llm.request.provider` 归属**（否决）：该字段恒为 `"openai"`，两个 provider 无法区分。
2. **只统计两个受支持 provider，其余丢弃**（否决）：用户看到的「今日」会比自己实际消耗少，且没有任何提示。
3. **按 `model` 前缀归属 + 未匹配项单独成行**（选定）：前缀逐字匹配 provider 段名，未匹配的进「其他」桶并在菜单尾行展示。

## Decision

- 归属规则：取 `model` 首个 `/` 之前的前缀（trim 后非空），逐字匹配 `configSectionName`（`"DeepSeek"` / `"OpenCode Go"`），另接受 `rawValue` 小写形式（`"deepseek"` / `"opencode-go"`）；其余一律 `.unknown`。
- `ProviderID.supported`（`[.deepseek, .opencodeGo]`）决定菜单里永远存在的两个 section；`.unknown` 只用于「其他」桶与 logo 缺省分支。
- 未匹配的用量**不丢弃**：当日「其他」桶非空时，在菜单尾行追加 `其他 · ↑… · ↓… · ⚡… · 🎯…%`。
- 去重键为 `"\(相对路径):\(行起始字节偏移)"`：路径区分文件，偏移在文件内稳定——增量读取重读某文件时同一事件不会重复计入。
- 行预过滤：必须含 `"usage.record"` 子串才进入 JSON 解析（单行可达数百 KB，先做零解析的拒否）。
- 每个 provider 各有一份独立的用量聚合（`UsageGroup`：`today` + 12 个小时桶），与余额状态一样按 provider 分键、互不影响。

## Consequences

- 归属正确性依赖「模型标识前缀 == provider 段名」这一约定。kimi-code 若改用别的模型标识格式，归属会整体落到「其他」——症状明显（尾行突然出现大量用量），不会静默错分。
- 用户新增一个本 app 未支持的第三方 provider 时，其用量出现在「其他」行而不是消失；代价是「其他」行没有余额 / 配额可查（本 app 只支持两个 provider 的余额端点）。
- 前缀含空格的 provider 名必须逐字匹配，不能用「按空白切分」之类的近似规则，否则 `OpenCode Go` 会被切成 `OpenCode`。
- 若 kimi-code 将来让 `llm.request.provider` 携带真实 provider 身份，本 ADR 需要重审（届时它会是比前缀更直接的依据）。
