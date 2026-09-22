# 0006 — 用量合并统计（不再按 Provider 归属）

token 用量只保留**一份**合并的数字，不再按 provider / model 区分。两个 provider 的菜单 section 只放各自的余额 / 配额，用量块（`今日` / `近 5h`）作为独立的一段放在两个 section 之后、「菜单栏显示」之前。取代 [0003](0003-usage-attribution-by-model-prefix.md)。

## Status

已采纳（Accepted）。取代 [0003](0003-usage-attribution-by-model-prefix.md)。

## Context

- 用户的要求：**用量统计不需要根据 provider 或者 model 区分，只显示一份，全部合在一起**。用户关心的是「今天用了多少」，而不是「每个 provider 各用了多少」——后者是把统计口径的复杂度转嫁给了读者。
- 归属本来就脆弱：唯一能用的依据是 `usage.record.model` 的 `<Provider>/<model>` **字符串前缀**（见 0003）。看起来更「正确」的 `llm.request.provider` 恒为 wire 协议类型 `"openai"`，两个 provider 都是它，根本不能用于归属。也就是说，归属从来不是协议给出的事实，而是对模型标识格式的一个约定。
- 那个约定会静默失效：kimi-code 换一种模型标识格式，或用户接了本 app 不支持的 provider，归属就整体落到「其他」桶。0003 已经承认这个风险（症状是尾行突然出现大量用量）。
- 归属带来的复杂度是实打实的：`UsageEvent.provider`、`WireLineParser` 里的前缀解析、`HourlyAggregator` 的 `order = supported + [.unknown]` 与按 provider 分键的字典、`UsageGroup`、菜单里的「其他」尾行，以及「其他桶非空才显示」的分支。

## Considered Options

1. **保留 per-provider 归属，只是把几份用量并排放在一起**（否决）：仍是按 provider 分组，只是显示上凑近一点；「其他」行也还得留着，没有真正满足「只显示一份」。
2. **保留归属，但只在展示层合并**（否决）：一行代码都删不掉——`model` 仍被读取、`UsageGroup` 仍在、未匹配桶仍然存在，只是把复杂度藏到 `StatusBarPresenter` 后面。
3. **彻底去掉归属，用量只算一份合计**（选定）：`UsageEvent` 只留时间戳 + 四个计数，parser 不读 `model`，聚合器只产出一份 `today` + 12 个合并小时桶，菜单里只有一个用量块。

## Decision

- `UsageEvent` 不再有 `provider` 字段；`WireLineParser` 完全不读 `model`，也不再依赖 `ProviderID`。去重键仍是 `"\(相对路径):\(行起始字节偏移)"`（未变）。
- `HourlyAggregator.aggregate` 返回**一份** `DailyUsageSnapshot`：`today: TokenStats` + 12 个合并的 `HourBucket`。桶不变量与 0003 时期完全一致：索引 0 最旧、末位最新、区间左开右闭 `(startMs, endMs]`、`HOUR_BUCKET_COUNT = 12`、`HOUR_MS = 3_600_000`、末桶是结束于 `nowMs` 的完整一小时。
- `DailyUsageSnapshot.last5h` = `hourly.suffix(5)` 的并集，等价 `[now − 5h, now]`。
- `UsageGroup` 删除；「其他」尾行删除（已经没有「未匹配」这个概念，也就没有需要兜底的桶）。
- 菜单结构：两个 provider section（只有余额 / 配额行）→ 合并用量块（`今日` / `近 5h`）→ 「菜单栏显示」→ 阻止休眠 → 底部动作。
- `ProviderID.fromModelPrefix(_:)` 保留，但唯一用途变成 `fromDefaultModel`（首启菜单栏 provider 推导，见 [0005](0005-menubar-provider-is-explicit.md)）；它不再参与任何用量计算。

## Consequences

- **再也分不出一个 token 是哪个 provider 花的。** 这是直接代价：菜单里的「今日」是两个 provider 的合计，无法拆开，也不打算提供拆分开关。
- `model` 字段在本 app 里**完全不再被读取**：模型标识格式怎么变都不影响用量统计，「其他」桶那类静默少算的失败模式一并消失。
- 0003 里仍然成立、继续承重的两条事实被原样继承：
  1. 每个 agent 的 `wire.jsonl` 完全独立、**跨文件零重复**（实测 600 条记录 600 个不同签名，0 条出现在多个文件里）——因此必须遍历全部 `agents/*/wire.jsonl`，只读 `main` 会严重漏计。这与归属无关，是读取层的不变量。
  2. `usage.record` 是**单次 LLM 调用的增量**而不是累计快照（同一 session 的 `output` 序列实测非单调：187 → 165 → 170 → 1654 → …）——因此直接按字段求和，不做差分。合并统计不会改变这一点。
- 0003 里「`llm.request.provider` 恒为 `"openai"`」的实测结论仍然成立，但现在只是**历史依据**：既然不做归属，这个字段连考虑都不需要考虑。
- 若将来又要按 provider 拆开用量，需要重新引入一个归属依据；现有的 `model` 前缀方案已被判定为「不值得为它维护一整套分组代码」。
