# 0001 — 独立菜单栏 app，不做 kimi-code 插件

kimi-code desktop 的插件系统能注册 skills / agents / MCP servers / hooks / slash commands / system prompt，但**没有任何 UI 扩展点**。因此「在菜单栏常驻显示余额」只能由独立 app 用 `NSStatusItem` 自己实现。

## Status

已采纳（Accepted）。

## Context

- 插件能力边界（对 `/Applications/Kimi Code.app/Contents/Resources/app.asar` 实测统计）：`skills` 517、`agents` 1263、`mcp` 2574、`hooks` 740、`slash` 507、`command` 1408、`systemPrompt` 147 处命中 —— 这些都能注册。
- 但 UI 侧是零：`statusline` / `statusBar` / `statusbar` / `status-item` 在同一个 asar 里**零命中**。插件系统不暴露任何在菜单栏 / 状态栏渲染内容的挂钩。
- kimi-code 自带的内置托盘菜单是硬编码实现，不构成插件扩展点。
- 产品需求（在系统菜单栏占一个槽位、拥有自己的下拉菜单、显示余额 / 配额与 token 用量）恰恰只能通过 UI 扩展点满足。
- 兄弟项目 omp-companion 也是独立 `NSStatusItem` app，形态与取舍可以平行复用。

## Considered Options

1. **做成 kimi-code 插件**（否决，不可行）：插件系统能注册 skills / agents / MCP servers / hooks / slash commands / system prompt，但没有 UI 扩展点，无法在菜单栏渲染任何东西。
2. **走 statusline / statusBar 挂钩**（否决，不存在）：该扩展点不是「不完善」，而是根本不存在（asar 零命中）。
3. **独立 `NSStatusItem` app**（选定）：自己占用一个菜单栏槽位、自己拥有下拉菜单，与 kimi-code 进程解耦。

## Decision

- 形态是独立 macOS app：`@main` + `NSApplication`，`setActivationPolicy(.accessory)`（无 Dock 图标），`Info.plist` 里 `LSUIElement=true`。
- 菜单栏槽位用 `NSStatusItem`（`variableLength`），下拉菜单用 `NSMenu`；`NSMenuDelegate.menuNeedsUpdate` 里整棵重建，`autoenablesItems = false`。
- 与 kimi-code 的集成**只通过文件**：读 `~/.kimi-code/config.toml`（凭据 / `base_url` / `default_model`）与 `~/.kimi-code/sessions/**/wire.jsonl`（用量）。
- 不注册插件、不调用 kimi-code 的本地 HTTP server、不依赖 kimi-code 是否在运行；不做进程内注入、不 hook kimi-code 进程、不要求 kimi-code 侧安装任何东西。
- 因为没有主窗口，额外装一个最小主菜单（应用菜单 + 「编辑」菜单），否则偏好窗口的 Cmd+C / Cmd+V 无法经 `paste:` 等路由到 first responder。

## Consequences

- 用户需要单独安装 / 启动本 app，没有「装个插件就出现」的路径。
- 因为只通过文件集成，读数与 kimi-code 的运行时状态可能不一致（例如会话内的临时模型切换不可见）——这是被接受的权衡。
- 反过来 app 与 kimi-code 完全解耦：kimi-code 未运行、插件未启用时依然能显示余额（余额来自远端 API）。
- 形态与 omp-companion 平行，两侧的 UI / 守护 / 格式化实现可以互相移植。
- 若 kimi-code 将来真的开放 UI 扩展点，本决策需要重审（届时插件路线会比独立 app 省一次安装）。
