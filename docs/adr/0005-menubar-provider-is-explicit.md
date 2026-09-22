# 0005 — 菜单栏展示哪个 Provider 是显式选择

菜单栏展示哪个 provider 由用户从下拉菜单显式选择、持久化，且**永不自动改写**。兄弟项目 omp-companion 是持续从宿主配置的默认模型推导；本 app 只在**首次运行**借用该推导一次，用来挑一个合理的初值，此后用户的选择优先。

## Status

已采纳（Accepted）。

## Context

- 兄弟项目 omp-companion 的菜单栏展示项持续跟随宿主的 `modelRoles.default`：宿主换默认模型，菜单栏就换 provider。
- 那条路线在本 app 的场景下有两个不可接受的后果：
  1. **读数会自己跳**：用户在会话里改了默认模型（或 kimi-code 侧 `default_model` 变了），菜单栏显示的数字会在用户没做任何操作的情况下换成另一个 provider 的量。
  2. **失败会引发二次跳变**：若把「当前该显示谁」与「谁抓取成功」耦合起来，一次网络抖动就可能把菜单栏切到另一个 provider——用户看到「A 的读数」变成「B 的读数」而没意识到来源变了，这比显示一个明确的失败标记更糟。
- 但完全不做初值推导也不行：首次运行时两个 provider 都还没采集过，随便挑一个会让用户以为配错了。
- 两个 provider 本来就各自独立演化（`ProviderBalanceState` 按 provider 分键），所以「显示谁」与「谁健康」在数据结构上本就是两件事。

## Considered Options

1. **持续从 `default_model` 推导**（否决）：读数会在用户无操作时跳变；一旦与抓取成功与否耦合，还会引发自动切换。
2. **始终显示固定的一个 provider**（否决）：用户没法看另一个，也没有初值推导的余地。
3. **显式选择 + 持久化 + 首次运行推导一次初值**（选定）：初值合理，之后完全由用户控制。

## Decision

- 选择项是 `AppState.selectedProvider`，只能由 `RefreshController.selectProvider(_:)` 改写，唯一调用方是「菜单栏显示 ▸」子菜单（`StatusBarController.selectProvider(_:)`）。
- 选择持久化到 UserDefaults（键 `selectedProvider`）；重启后恢复。存量非法值（不在 `ProviderID.supported` 里）回退到推导初值。
- **首次运行**（UserDefaults 无有效记录）时，用 `MenuBarSelection.deriveDefault(fromDefaultModel:)` 从 `config.toml` 的 `default_model` 前缀推导一次；推导不出（缺配置 / 未匹配）回退 `DeepSeek`。这是该推导在本 app 里**唯一**的用途。
- 菜单栏标题只看选中 provider（`StatusBarPresenter.renderTitle`）：另一个 provider 的状态再糟也不影响菜单栏。
- **抓取失败绝不改变 `selectedProvider`**：失败只在该 provider 的 section 里显示（`⚠︎配置` / `⚠︎凭据` / 远端错误文案）；选中 provider 有旧值时保留旧值并标注「旧值」，同时显示失败原因。
- 「菜单栏显示 ▸」的两项永远都在菜单里，当前项带 ✓。

## Consequences

- **菜单栏可能显示一个过期或失败的读数，而另一个 provider 完全健康——这是有意行为**。用户看到的是他自己选的那个 provider 的真实状态，而不是 app 替他挑的「看起来更好」的那个。
- 用户需要自己意识到「另一个 provider 的 section 里可能有更新的数据」；两个 section 永远都在菜单里，所以这个信息一直可见。
- 不再需要「当前该显示谁」的状态机：`selectedProvider` 是唯一事实，没有任何采集结果路径会改写它。
- 代价是菜单栏不再自动反映 kimi-code 侧默认模型的变化；用户在 kimi-code 里换了常用 provider 后，需要手动切一次。
