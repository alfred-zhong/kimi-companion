# 0012 — 下拉菜单里把选中的 Provider 置顶

菜单栏显示的那个 Provider，其 section 在下拉菜单里排第一。这只改 section 之间的顺序，不改任何数据口径、不改「菜单栏显示 ▸」子菜单，也不引入新的持久化状态。

## Status

已采纳（Accepted）。不改变 [0005](0005-menubar-provider-is-explicit.md) 的「显式选择、失败不自动切换」与 [0006](0006-combined-usage.md) 的合并用量块位置；只影响 `StatusBarPresenter.renderMenu` 里三个 provider section 的排列。

## Context

- 菜单栏同一时刻只展示一个 Provider 的值（[0005](0005-menubar-provider-is-explicit.md)），但下拉菜单原来按 `ProviderID.supported` 固定顺序列出全部 section。用户最常见的动作是「看菜单栏那个数，然后到菜单里看它的明细」，而它可能排在第三位。
- 菜单项数量固定、section 高度不一（DeepSeek / Kimi 一行、OpenCode Go 三行进度条），所以「第几项」并不稳定，靠位置记忆没用；置顶能让「菜单栏那个值 ↔ 菜单第一段」形成直观对应。
- 顺序是渲染期的纯函数结果：菜单每次打开都重建，没有缓存，因此置顶天然跟着选择即时生效，不需要额外刷新或通知。
- 选择器本身（「菜单栏显示 ▸」子菜单）是另一件事：它是一个 radio 列表，如果也跟着置顶，点完一次再打开时条目会跳位，同一个位置第二次点就点到别的 Provider 上。

## Considered Options

1. **保持 `supported` 固定顺序**（否决）：与前一条 Context 的直觉冲突，且用户明确要求置顶。
2. **置顶 + 其余按「最近选过」排序**（否决）：要多存一份历史顺序，出现「顺序为什么又变了」的隐性状态；收益接近于零。
3. **主菜单与子菜单一起重排**（否决）：radio 选择器置顶会让条目在每次点击后跳位，误点概率上升。
4. **置顶 section 额外加 `✓` / 加粗 / 「当前」字样**（否决）：子菜单已有 `✓`，两套「选中」表达会互相稀释；header 也应保持「只有 Provider 名」的既有形态。
5. **选中者置顶、其余保持 `supported` 相对顺序**（选定）。

## Decision

- `StatusBarPresenter.orderedProviders(selected:)` 是 section 顺序的唯一来源：`[selected] + ProviderID.supported.filter { $0 != selected }`。`selected` 不在 `supported` 里（`SettingsStore` 会把脏值自愈回可用值，正常不会出现）时退化为 `supported` 原序，不丢 section。
- `renderMenu` 用这个顺序拼 section，分隔线仍然只夹在 section 之间，置顶后菜单不以分隔线开头。
- 「菜单栏显示 ▸」子菜单保持 `ProviderID.supported` 固定顺序（`DeepSeek` / `OpenCode Go` / `Kimi`），选中项带 `✓`。
- 用量块（`今日` / `近 5h`）位置不变：仍在全部 provider section 之后（[0006](0006-combined-usage.md)），因此置顶只是把选中的一段提到这组 section 的开头。
- 其余块（「菜单栏显示」、「阻止系统休眠」、「偏好… / 立即刷新」、「清理 session 文件…」、「退出」）的位置与顺序完全不变。
- 生效时机依赖既有的「每次打开菜单都重建」：点完子菜单里的另一项、菜单关闭，下次打开就是新顺序，不加「选中后主动重建已打开菜单」这类逻辑。
- section header 文案保持纯 Provider 名，不追加选中标记。

## Consequences

- 「顺序 = `ProviderID.supported`」这条旧约定作废：`supported` 现在只决定**其余** section 的相对顺序，以及子菜单 / 抓取循环 / `default_model` 前缀解析的顺序。启停 Provider 仍是改 `supported` 一行。
- `SelfCheck` 的菜单顺序断言改为「选中者第一 + 其余相对顺序不变 + 逐个 Provider 各断言一次 + 未知选中值退化为原序」，`Menu.headerOnlyProviderName` 之类的局部顺序断言仍用 `supported` 原序（默认选中 `DeepSeek`）。
- 手动烟测多一项：切换「菜单栏显示」后重新打开菜单，第一段应换成刚选的 Provider，且子菜单条目位置不动。

## Amendments

- 2026-11-25（[0013](0013-auto-menubar-provider.md)）：「菜单栏显示」新增第一项「自动」，子菜单固定顺序变为「自动 + `ProviderID.supported`」。自动模式下置顶对象是每 tick 解析出的 provider；解析失败时选中值为 `.unknown`，按本文既有的退化规则回落 `ProviderID.supported` 原序。
