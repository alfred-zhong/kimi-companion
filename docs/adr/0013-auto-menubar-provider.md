# 0013 — 菜单栏可跟随 `default_model`（「自动」模式）

「菜单栏显示 ▸」新增第四个选项「自动」：每个刷新周期按 `~/.kimi-code/config.toml` 的 `default_model` 前缀解析 provider 并展示它。它是**用户显式开启的模式**，不是新的默认行为；解析不出受支持 provider 时菜单栏显示 `⚠︎模型`，不做兜底。

## Status

已采纳（Accepted）。补充而非取代 [0005](0005-menubar-provider-is-explicit.md)：默认仍是显式选择，抓取失败仍不自动切换。[0012](0012-selected-provider-first-in-menu.md) 的置顶规则在自动模式下按解析结果生效，解析失败时回落 `ProviderID.supported` 原序。

## Context

- [0005](0005-menubar-provider-is-explicit.md) 否决了「持续从 `default_model` 推导」，理由有两条：无条件跟随会让读数在用户无操作时跳变；若再把「显示谁」与「谁抓取成功」耦合，一次网络抖动就会二次跳变。
- 但用户在 kimi-code 里换了常用模型后要手动切一次菜单栏，这个成本是真实存在的。把跟随做成**用户主动选择的模式**，0005 的两条反对理由都不再成立：跳变是用户自己开的；健康度依然不参与切换。
- 每 tick 的 `BalanceCapture` 已经携带 `defaultModel`（此前只用于首启推导与诊断），实现不需要新增配置读取。
- 一个真实会遇到的边界：默认模型可能指向本 app 有意不支持的 first-party `managed:kimi-code`（[0008](0008-kimi-balance-scope-and-currency.md)），或任何未知第三方前缀。此时任何「挑一个 provider 顶上」的兜底都是在替用户换源，与 0005 的「不擅自换源」相悖。

## Considered Options

1. **持续跟随、不给开关**（0005 已否决）：读数会在用户无操作时跳变。
2. **自动 + 解析失败回退到上次 provider / `DeepSeek`**（否决）：用户会在毫无察觉的情况下看到另一个 provider 的读数，比显示明确的失败标记更糟。
3. **自动 + 解析失败显示明确标记**（选定）：失败可见、可解释，且随时可一键切回显式 provider。

## Decision

- 子菜单第一项为 `自动（跟随默认模型）`，持久化到 UserDefaults 键 `menuBarAuto`（默认关闭）。新装仍按 `default_model` 推导一次并存成显式选择，自动需要用户主动选。
- 自动模式下只有「自动」带 `✓`，三个 provider 都不带——两个「选中」表达会互相稀释。
- 每 tick 由 `MenuBarSelection.resolveAuto(fromDefaultModel:)` 解析：
  - 成功 → `selectedProvider` 换成该 provider，并清空失败原因；
  - 失败 → `selectedProvider = .unknown` + `autoFailure`（`.missingDefaultModel` / `.unmatched(前缀)`）。
- `.unknown` 只存在于内存，永不落盘；`SettingsStore.selectedProvider` 始终是最后一次显式选择，关掉自动就精确回到它。
- 菜单栏标题优先级：`configMissing("?kimi") > .unknown("⚠︎模型") > 余额 > ⚠︎<短标签> > "···"`。两个「无 provider」分支都不追加 ` ☕`，也不显示 logo（`LogoCatalog` 对 `.unknown` 返回 nil）。
- `config.toml` 不可读 / 非法的 tick 不产生新的 `default_model` 事实，因此保留上一次解析结果与展示值（此刻菜单栏由 `?kimi` 分支渲染）。
- 抓取失败绝不换源：自动只改变「`default_model` 指向谁」，不读任何健康度信号。
- 显式选择 provider 即退出自动；点「自动」立即用最近一次可读的 `default_model` 解析，不必等下一个 tick。
- section 顺序仍由 `orderedProviders(selected:)` 决定：解析成功时该 provider 置顶；解析失败时选中值是 `.unknown`，天然回落 `ProviderID.supported` 原序。
- 偏好面板不加开关：菜单是 provider 选择的唯一入口（0005 的既有约定）。

## Consequences

- 默认模型指向 first-party / 未知 provider 的用户开启自动后会**长期**看到 `⚠︎模型`，一个数字都没有，直到改配置或手动选一个 provider。这是刻意的诚实降级：菜单里始终给出未匹配的前缀 / `未设置 default_model`，一键可切回显式 provider。
- 换默认模型后最多滞后一个刷新周期（30 / 60 / 120s）才切换；「立即刷新」可手动催一次。
- 新增视觉词汇 `⚠︎模型`；`?kimi` 的语义不变（config 本身不可用）。
- 新增持久化键 `menuBarAuto`；`selectedProvider` 的含义收窄为「最后一次显式选择」。
