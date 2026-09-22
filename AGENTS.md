# Repository Guidelines

> 面向 AI 助手的 kimi-companion 仓库协作手册。补充人类规范；不重复常识。

## Project Overview

`kimi-companion` 是 macOS 菜单栏常驻 app（LSUIElement，无 Dock 图标），展示 **kimi-code desktop 所用第三方 provider 的余额 / 配额**，以及一份**合并的** token 消耗统计（不区分 provider / model，ADR-0006）。每 30 / 60 / 120s 定时刷新（默认 60s）。错误降级永不空白：配置缺失、凭据缺失或网络失败时菜单栏显示 `?kimi` / `⚠︎<短标签>`，下拉菜单给出可照抄去改配置的中文说明。

- 支持 Provider：`DeepSeek`（账户余额，CNY）、`OpenCode Go`（5h / 7d / 月度三窗口配额，已用百分比）。
- 凭据来源：**只读** `~/.kimi-code/config.toml` 的 `[providers.<段名>].api_key`（ADR-0002）。本 app 没有自己的凭据存储，不读 Keychain，不读 `api_key_env`。
- 用量来源：`~/.kimi-code/sessions/<workspace>/<session>/agents/<agent>/wire.jsonl` 的 `usage.record` 行，**全部合并成一份**、不按 provider / model 区分（ADR-0006），进程内增量读取（ADR-0004）。
- 菜单栏展示哪个 provider 由用户显式选择并持久化，抓取失败时**不自动切换**（ADR-0005）。
- 有意不支持 first-party `managed:kimi-code` 账号：其 `api_key` 恒为空、走 OAuth，且本地 `oauth/usage` 端点只覆盖该账号（产品上已排除）。

## Architecture & Data Flow

```
@main KimiCompanion.main
   └─ AppDelegate.applicationDidFinishLaunching           ← DI 装配
       ├─ installMainMenu()                                ← 最小主菜单（含「编辑」），偏好窗口才能 Cmd+V
       ├─ KimiConfigSource(homeDir:)                        ← ~/.kimi-code/config.toml 只读
       │    └─ MenuBarSelection.deriveDefault(default_model) ← 首启菜单栏 provider 推导（仅此一次）
       ├─ SettingsStore(fallbackProvider:)                  ← UserDefaults 镜像（间隔 + 选中 provider）
       ├─ WireLogReader(sessionsRoot: "~/.kimi-code/sessions")
       ├─ LiveBalanceSource(config:)                        ← 两个 provider 各独立跑一遍
       ├─ LiveDailyUsageSource(reader:)                     ← reader + HourlyAggregator
       ├─ RefreshController(balanceSource:dailySource:state:intervalSeconds:)
       ├─ SleepGuard(state:)                                ← IOPMAssertion 单会话守护
       ├─ SettingsWindowController(onIntervalChange:)       ← SwiftUI 偏好面板（只有「刷新间隔」一项）
       └─ StatusBarController(controller:state:sleepGuard:onShowSettings:onSelectProvider:)
            ├─ Combine 订阅 AppState @Published × 6         ← UI 主线程刷新
            └─ Timer.scheduledTimer(.common)                ← 每 N 秒 fire tick

每个 tick (RefreshController.tick):
  balanceSource.capture(now:) → config.load() → 逐 provider[段查找 → 凭据检查 → fetch] → BalanceCapture
      └─ MainActor.run { state.applyBalance(balanceOutcome(for:)) }   ← 逐 provider advanced(previous:incoming:now:)
  dailySource.capture(now:)   → reader.events(now:) → aggregator.aggregate(...) → (DailyUsageSnapshot, nil)
      └─ MainActor.run { applyDaily(snap:err:) }
```

**关键决策（必须遵守，不是历史）**

- **凭据只有一个来源**：`~/.kimi-code/config.toml` 的内联 `api_key`（ADR-0002）。不新增偏好面板凭据字段、不读 Keychain、不读 `api_key_env`（不调用 `getenv`）、不读 kimi-code 本地 HTTP server（`~/.kimi-code/server/instances/*.json`、`server.token`、`mcp.json` 一律不碰）。
- **用量是合并的一份**（ADR-0006）：所有 `usage.record` 无条件求和，不按 provider / model 分组，`model` 字段**完全不被读取**。菜单里两个 provider section 只放余额 / 配额，用量块（`今日` / `近 5h`）独立成段放在两者之后、「菜单栏显示」之前。（历史依据：`llm.request.provider` 恒为 wire 协议类型 `"openai"`，两个 provider 都是它，本来也不能用于归属。）
- **无磁盘缓存层**：每个 tick 实时查 Provider + 增量读会话日志；Read Cursor 只在进程内（ADR-0004）。本 app 唯一的持久化是 UserDefaults（刷新间隔 + 选中 provider）。
- **菜单栏 provider 是显式选择**（ADR-0005）：`default_model` 推导只在首次运行用一次；此后用户选择优先；provider 失败绝不改 `selectedProvider`。
- **不 shell-out 任何上游 CLI**。新增 Provider 仅需枚举 case + 实现 `BalanceProvider.fetch`。
- `ProviderBalanceState.isStale` 是余额侧唯一的退化路径：失败但有旧值时保留旧值并标注。

## Key Directories

| 路径 | 用途 |
|---|---|
| `Sources/kimi-companion/` | 唯一可执行 target（`executableTarget`） |
| ↳ `App.swift` | `@main` 入口 + DI 装配 + `--self-check` 分派 + 最小主菜单 |
| ↳ `RefreshController.swift` | tick 编排 + `AppState`（`ObservableObject`，6 个 `@Published`） |
| ↳ `SelfCheck.swift` | 进程级断言入口（`static run() -> Int`，419 个 `check(...)` 调用点） |
| ↳ `Model/Models.swift` | 共享值类型：`ProviderID` / `MenuBarSelection` / `BalanceResult` / `QuotaWindow` / `ProviderFailure` / `ProviderCapture` / `ProviderBalanceState` / `TokenStats` / `HourBucket` / `DailyUsageSnapshot` / `CaffeinateBucket` / `CaffeinateSession` / `RefreshInterval` |
| ↳ `Balance/Providers.swift` | `BalanceProvider` 协议 + `DeepSeekProvider` + `OpenCodeGoProvider` + `BalanceRegistry` + `normalizeBaseURL` |
| ↳ `Balance/HTTPClient.swift` | `HTTPClient` 协议 + `URLSessionHTTPClient`（仅 HTTPS）+ `HTTPError` |
| ↳ `Balance/CredentialSource.swift` | provider 内联 key 来源协议（`resolve(_ name:) -> String?`） |
| ↳ `Balance/BalanceFormatter.swift` | 状态栏 / 菜单文案：`statusBarText` / `menuBarText` / `formatHMS` / `formatDuration` |
| ↳ `Config/KimiConfigSource.swift` | `config.toml` 读取（`KimiConfigLoad`）+ `TomlCredentialSource` |
| ↳ `Refresh/SnapshotError.swift` | `SnapshotError` + `BalanceCapture` / `BalanceSource` / `BalanceRefreshOutcome` / `DailyUsageSource` |
| ↳ `Refresh/LiveSources.swift` | 生产 `LiveBalanceSource` / `LiveDailyUsageSource` + `humanReadable(_:)` |
| ↳ `Refresh/Fakes.swift` | `FakeBalanceSource` / `FakeDailyUsageSource`（SelfCheck 用） |
| ↳ `Usage/WireLineParser.swift` | 单行 `usage.record` → `UsageEvent`（只取 `time` + `usage` 四个计数，**不读 `model`**），去重键 `"\(relPath):\(lineOffset)"` |
| ↳ `Usage/WireLogReader.swift` | 增量读取 + 进程内 Read Cursor + 保留窗口（ADR-0004） |
| ↳ `Usage/HourlyAggregator.swift` | 12 滑动小时桶（`HOUR_BUCKET_COUNT = 12`、`HOUR_MS = 3600 * 1000`，左开右闭）+ 合并 `today`；**不按 provider 分组** |
| ↳ `Usage/Formatting.swift` | `CompactFormatter.format(Int)` K/M/B + `999_500 → "1.0M"` |
| ↳ `SleepGuard/SleepGuard.swift` | 单会话 IOPMAssertion 守护；到期释放走**一次性** `SessionExpiryTimer` |
| ↳ `SleepGuard/IOPMAssertionAdapter.swift` | IOKit `IOPMAssertionCreateWithName` 封装（system + display 成对）+ Fake |
| ↳ `SleepGuard/SessionExpiryTimer.swift` | 一次性到期驱动（`LiveSessionExpiryTimer` / `RecordingSessionExpiryTimer`） |
| ↳ `SleepGuard/CountdownTicker.swift` | 1Hz 倒计时驱动，**只在菜单打开期间启停** |
| ↳ `SleepGuard/CountdownFormatter.swift` | 剩余时间文案：`≥1min → Xm`、`<1min → Xs` |
| ↳ `UI/StatusBarController.swift` | `NSStatusItem` + `NSMenu` + `Timer` + Combine sink；菜单打开时才拉起倒计时 ticker |
| ↳ `UI/StatusBarPresenter.swift` | 纯函数展示层：`renderTitle` / `renderChrome` / `renderMenu` + `MenuItemSpec` / `UsageBarSpec` |
| ↳ `UI/UsageBarMenuItemView.swift` | 自绘用量进度条菜单项（轨道 + 段色填充 + 重置倒计时） |
| ↳ `UI/SettingsWindow.swift` | `SettingsStore`（`@Published` × 镜像 UserDefaults）+ `NSHostingController<SettingsView>` |
| ↳ `Brand/LogoCatalog.swift` | `ProviderID` → `NSImage` 查表 + template 标记；未知 provider 返回 nil |
| `Resources/Info.plist` | bundle 元数据：**`LSUIElement=true`**、`CFBundleIdentifier=com.alfred-zhong.kimi-companion`、`LSMinimumSystemVersion=13.0` |
| `Resources/provider_*.png` | 菜单栏 logo（`@2x` / `@3x` 两张，无 `.color.png` 兜底） |
| `docs/adr/0001-0006-*.md` | 现行决策记录（0001 独立 app / 0002 凭据来自 config.toml / 0003 用量按 model 前缀归属 —— **已被 0006 取代** / 0004 wire 日志 Read Cursor / 0005 菜单栏 provider 显式 / 0006 用量合并统计） |

## Development Commands

```bash
make build              # swift build -c release + 拼 .app + ad-hoc 签名（= ./build.sh）
make run                # build 后 open build/kimi-companion.app
make test               # swift run kimi-companion --self-check（必跑）
make clean              # rm -rf build .build
```

`-c` 由 `CONFIG?=release` 控制；需要 debug 编译可 `CONFIG=debug make build`。

`build.sh` 等价步骤：

```bash
swift build -c release
swift build -c release --show-bin-path        # 取 .build/release/kimi-companion
mkdir -p build/kimi-companion.app/Contents/{MacOS,Resources}
cp .build/release/kimi-companion build/kimi-companion.app/Contents/MacOS/
cp Resources/Info.plist   build/kimi-companion.app/Contents/Info.plist
cp Resources/*.png        build/kimi-companion.app/Contents/Resources/   # LogoCatalog 查表用
codesign --force --deep --sign - build/kimi-companion.app                # ad-hoc
```

启动：`open build/kimi-companion.app`，或直接跑二进制 `build/kimi-companion.app/Contents/MacOS/kimi-companion`。

## Code Conventions & Common Patterns

### 异步

- **不引入 `DispatchQueue` / `actor`**（`WireLogReader` 用 `NSLock`，`SleepGuard` 用 `@MainActor`）。fetch 路径用 `async/await`，UI 跳主线程 `await MainActor.run { … }`，Combine 桥接 `MainActor.assumeIsolated { refreshAll() }`。
- tick 在 `Timer.scheduledTimer(withTimeInterval:repeats:)` 上调度（`RunLoop.main` + `.common`），每次 fire 包装在 `Task { @MainActor in await self.controller.tick() }`。
- `StatusBarController.init` 里会立刻 fire 一次首次 tick **加上** timer 首次 tick：不主动去重。
- `WireLogReader.events(now:)` 是**同步阻塞 I/O**：调用方保证不在主线程直接调用（生产路径在 cooperative 线程池里）。
- 例：

```swift
// RefreshController.tick
public func tick() async {
    let now = Date()
    let balanceCapture = await balanceSource.capture(now: now)
    let dailyCapture = await dailySource.capture(now: now)
    await MainActor.run {
        self.state.applyBalance(self.balanceOutcome(for: balanceCapture))
        self.applyDaily(snap: dailyCapture.0, err: dailyCapture.1)
    }
}
```

### 错误处理

- HTTP 层 `throws`，具体见 `enum HTTPError`：`timeout | unauthorized(status:) | rateLimited | server(status:) | invalidResponse | missingCredential`。非 2xx 在 `URLSessionHTTPClient` 里就转成 `.unauthorized` / `.rateLimited` / `.server`。
- 各 Provider 的 `decode` 宁可 `throw .invalidResponse`，也不展示凭空的 `¥0.00`：`balance_infos` 缺失 / 为空 / `total_balance` 不可解析 → 报错；OpenCode Go 三窗口 all-or-nothing。
- 配置 / 凭据加载用 `KimiConfigLoad` 枚举 + `Optional`，消费方 `switch` / `guard let` 降级；不用 `Result`（`Result` 只在 SelfCheck 的 async 桥接里出现）。
- 单 provider 失败被 `LiveBalanceSource.captureOne` 收敛成 `ProviderCapture(failure:)`，**不 throw 出 Source**：一个 provider 的失败绝不短路另一个。
- `LiveBalanceSource.humanReadable(_:)` 把 `HTTPError` 映射到中文状态文案（`请求超时 (10 秒)` / `鉴权失败 (401)` / `请求过快 (429)` / `服务异常 (5xx)` / `响应解析失败` / `凭据缺失`），缺省回退 `error.localizedDescription`。
- `ProviderFailure` 是类型化枚举而非裸字符串：菜单栏短标签（`⚠︎配置` / `⚠︎凭据`）与菜单长文案都由它纯函数派生，`StatusBarPresenter` 不需要嗅探文案内容。
- `SelfCheck.run()` 返回 `Int`（0=全部通过，1=有失败）；新加断言用一个闭包 `check(name, cond)`。

### 状态管理与 DI

- `AppState`（`final class : ObservableObject, @unchecked Sendable`）持有 **6 个** `@Published`：`configMissing`、`balances`、`daily`、`lastDailyError`、`caffeinateSession`、`selectedProvider`。**所有修改必须经过 setter**，setter 都在主线程被调用（`RefreshController` 走 `MainActor.run`）。
- 余额状态是 **per-provider 字典**（`[ProviderID: ProviderBalanceState]`），不是单个快照：一个 provider 失败不触碰另一个。逐 provider 的合并细节封在 `RefreshController.balanceOutcome(for:)`，不泄漏给 `AppState` 调用方。
- 倒计时不走 `AppState`：菜单侧 `CountdownTicker` 按秒 in-place 改 `NSMenuItem.title`，`SleepGuard` 只用一次性到期定时器。
- `RefreshController` 是 `final class, @unchecked Sendable`；`let` 协作对象 + `var intervalSeconds`（由偏好面板闭包写回）。
- `StatusBarController` 用 `Set<AnyCancellable>` 收 **6 个** `@Published`；`Timer` 在 `deinit` 与 `restartTimer()` 中 `invalidate()`。
- DI 通过构造器注入（`KimiConfigSource` / `SettingsStore` / `WireLogReader` / `BalanceSource` / `DailyUsageSource` / `IOPMAssertionAdapter` / `SessionExpiryTimer` / `CountdownTicker`）。不要引入 Service Locator 或全局单例。
- `SleepGuard` 与 `SettingsStore` 用 `@MainActor` / `@unchecked Sendable` 表达隔离，不引 `actor`。

### 命名 / 模板

- 类型命名沿用值类型优先（`struct BalanceResult` / `TokenStats` / `HourBucket` / `DailyUsageSnapshot`），行为 / 纯函数走 `enum SomeName` 单例（`BalanceRegistry` / `SelfCheck` / `CompactFormatter` / `BalanceFormatter` / `HourlyAggregator` / `StatusBarPresenter` / `LogoCatalog` / `MenuBarSelection`）。
- 所有跨任务类型 `Sendable`；跨线程持有者用 `@unchecked Sendable` + 命名 setter。
- Provider id 派生：`ProviderID.fromModelPrefix(_:)` 取首个 `/` 之前的前缀，逐字匹配 `configSectionName`（`"OpenCode Go"` 含空格）或匹配小写 `rawValue`；其余 → `.unknown`。**唯一调用方是 `fromDefaultModel`**（首启菜单栏 provider 推导，ADR-0005）——用量已不再按前缀归属（ADR-0006）。
- `ProviderID.supported`（`[.deepseek, .opencodeGo]`）是「菜单里永远都在的 provider」的唯一来源；`ProviderID.allCases` 含 `.unknown`，只用于 `default_model` 前缀未匹配的哨兵与 logo / 查表缺省分支。

### 日志 / 文案 / 状态栏标题

- 错误降级文案集中在 `ProviderFailure.menuText(provider:)` + `LiveBalanceSource.humanReadable(_:)`；新增错误显示分支请优先复用这两条路径。
- 状态栏标题优先级（`StatusBarPresenter.renderTitle`）：`configMissing("?kimi") > 选中 provider 的 result > 选中 provider 的 failure(⚠︎<短标签>) > "···"`。**只看选中 provider**。
- 所有分支统一在头部补两个 Thin Space（`\u{2009}\u{2009}`）拉开 logo 与文字间距；caffeinate 激活时在余额右侧追加 ` ☕`（`\u{2615}`，咖啡色 `#8B5A2B`）。
- 时间格式：`BalanceFormatter.formatHMS(_:)` → `HhMm`（状态栏 / 倒计时）；`formatDuration(_:)` → `≥24h` 用 `XdYh`、否则 `HhMm`，全程无空格。
- 日志：本 app **不写日志文件**，也不 `print` 运行时信息（`SelfCheck` 的 `print` 是唯一输出）。
- 用量行文案（`StatusBarPresenter.dailyLine`）：`今日 · ↑in · ↓out · ⚡cacheRead · 🎯hit%` 与 `近 5h · …`，两份都是**合并口径**。菜单里只有这两行用量，没有 per-provider 用量行，也没有「其他」行（ADR-0006）。

### 添加 Provider / Provider 字段

1. 在 `ProviderID` 加 `case`（`rawValue` 用小写连字符形式，如 `opencode-go`），并补 `configSectionName`（= config.toml 段名，逐字）+ `displayName`。
2. `Balance/Providers.swift` 加新 `struct XxxProvider: BalanceProvider`；实现 `hasCredential(creds: any CredentialSource) -> Bool` + `fetch(creds: any CredentialSource, http: HTTPClient) async throws -> BalanceResult`。凭据来源经 `CredentialSource`（由 `TomlCredentialSource` 实现，只读 config.toml），不新增凭据来源。
3. 在 `BalanceRegistry.provider(for:config:)` 补路由分支（`base_url` 从 `config?.provider(id.configSectionName)?.baseURL` 取，经 `normalizeBaseURL` 去尾斜杠 + 强制 HTTPS）。
4. 加入 `ProviderID.supported`（顺序即菜单 section 顺序）。
5. 若该 provider 是 percent 类型，`BalanceResult` 带 `quotaWindows`；`StatusBarPresenter.valueItems` 会自动把它渲染成进度条行。
6. `LogoCatalog.assetBaseName(for:)` 补 logo 基名，并把 `Resources/<基名>@2x.png` / `@3x.png` 落地（`build.sh` 会自动复制）。
7. `SelfCheck` 里加路由 / 解码 / URL 断言（按已有 `.unknown` 分支模式）。

### 进度条 / 时段桶不变量

- 12 个 `HourBucket`，索引 0 最旧、末位最新，区间左开右闭 `(startMs, endMs]`；末桶永远是完整一小时（`endMs = nowMs`）。
- `DailyUsageSnapshot.last5h` = `hourly.suffix(5)` 的并集，等价 `[now-5h, now]`。
- 事件 `tsMs < todayStartMs` 不算「今日」，但**仍可**进小时桶（窗口可跨零点）；`hoursAgo ∉ [0, 12)` 才丢。
- 去重键形如 `"\(relPath):\(lineOffset)"`，**不要**改成其它样式，否则会和去重语义冲突。
- 段色：`isOK == false` → 强制红；否则 `<70` 绿 / `70–90` 黄 / `>90` 红。进度条最短 60pt，视图宽度以 240pt 为底按需加宽。

## Important Files

| 文件 | 角色 |
|---|---|
| `Package.swift` | SwiftPM 入口；`swift-tools-version: 5.9`；macOS `.v13`；唯一外部依赖 `TOMLKit`（`from: 0.6.0`）；`executableTarget` 路径 `Sources/kimi-companion` |
| `Package.resolved` | 锁定 TOMLKit 0.6.0（revision `ec6198d3…`）；**未被 `.gitignore` 忽略，应随仓库提交** |
| `.gitignore` | `.build/`、`.swiftpm/`、`build/`、`.DS_Store`、`.idea/`、`.vscode/`、`*.swp`（不含 `Package.resolved`） |
| `Makefile` | `all` / `build` / `run` / `test` / `clean`，全部 `.PHONY` |
| `build.sh` | 构建 + 拼 `.app` + 复制 `Resources/*.png` + ad-hoc `codesign --force --deep --sign -` |
| `Resources/Info.plist` | bundle id、版本 `0.1.0`（build `1`）、`LSUIElement=true` |
| `Sources/kimi-companion/App.swift` | 进程入口，DI 在此装配 |
| `Sources/kimi-companion/RefreshController.swift` | tick 编排 + `AppState` |
| `Sources/kimi-companion/UI/StatusBarController.swift` | 菜单栏 + Timer + Combine |
| `Sources/kimi-companion/UI/StatusBarPresenter.swift` | 全部「AppState → 视觉」纯函数 |
| `docs/adr/0001-0006-*.md` | 现行决策（0001 独立 app、0002 凭据来源、0003 归属（**已被 0006 取代**）、0004 增量读取、0005 显式选择、0006 用量合并统计） |

## Runtime / Tooling Preferences

- **运行时**：macOS 13.0+；Apple Silicon / Intel 均可。系统无 Node / Bun / Python 依赖——纯 Swift in-process，零外部进程。
- **构建环境是 Command Line Tools only**（`xcode-select -p` → `/Library/Developer/CommandLineTools`）。`xcodebuild` **不可用**（报 `requires Xcode`）。实测工具链：macOS 27 SDK（`xcrun --show-sdk-version` → `27.0`）、Swift 6.4（`Target: arm64-apple-macosx27.0.0`）。
- **SwiftUI 代码不得依赖宏展开的 API**（`@State` / `@StateObject` / `@Environment` / `@Bindable`）：macOS 27 SDK 起它们是外部宏，插件 `libSwiftUIMacros.dylib` **只随 Xcode 提供**，CommandLineTools 里不存在（`/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/` 下只有 `libObservationMacros.dylib` / `libSwiftMacros.dylib`），编译会以 `plugin for module 'SwiftUIMacros' not found` 失败。视图内可变状态一律用 `ObservableObject` + `@ObservedObject`（普通 property wrapper，无需插件）。
- **包管理器**：SwiftPM（`Package.swift`）；唯一外部依赖 TOMLKit。不要新增 Conan / CocoaPods / Carthage。
- **签发**：仅本机 ad-hoc（`codesign --force --deep --sign -`），**不做 Developer ID 公证**，不在 release 流程加。
- **代码签名约束**：不新增 `LaunchAgent` plist，不在仓库里写 `~/Library/LaunchAgents/*.plist`；本 app 不自启。
- **凭据**：只读 `~/.kimi-code/config.toml` 的内联 `api_key`（ADR-0002）；**不写回该文件**、不读 Keychain、不读 `api_key_env`、不读 kimi-code 本地 HTTP server。
- **安全**：provider 请求走 `URLSession.shared`，未配 `NSAppTransportSecurity` 例外；新增端点必须 HTTPS（`normalizeBaseURL` 会拒掉非 https 的 `base_url` 并回退官方默认）。

## Testing & QA

- **测试方式**：SwiftPM 当前 `executableTarget` 缺 XCTest / Swift Testing 模块，测试以 **`SelfCheck` 进程级断言**形式存在，由 `--self-check` 调用（`swift run kimi-companion --self-check`）。`make test` 等价同命令。
- **断言规模**：`Sources/kimi-companion/SelfCheck.swift` 共 **419 个 `check(...)` 调用点**（`grep -c 'check('` 得 420，多出的一处是 `func check` 定义）。其中 4 处位于 4 次迭代的 logo 资源循环内，故运行期实际求值次数略多于调用点数。
- **新增断言**：在 `SelfCheck.run()` 内追加 `check("...", cond)`，纯函数 + `Bool` 条件；不要引入 XCTest。生产环境迁移 XCTest 时再移除 `SelfCheck`。
- **覆盖范围**（自检保证）：`TokenStats` 派生（含 cache-hit 0 除法）、`CompactFormatter`（K/M/B + `999_500 → 1.0M`）、`BalanceFormatter`（CNY / USD / percent / `formatHMS` / `formatDuration` 边界）、`DeepSeekProvider` 解码与 URL（含尾斜杠 / 空白 / http 拒绝）、`OpenCodeGoProvider` 三窗口解码（all-or-nothing、percent 越界、小数秒 ISO）、`HourlyAggregator`（今日合并合计、桶边界与不变量、跨零点）、`WireLineParser`（不读 `model`、未匹配前缀照常计数、去重键）、`WireLogReader`（增量契约：首读 / 追加 / 半行 / 截断 / 替换 / 删除 / mtime 剪枝 / 窗口 / 时钟回拨均与全量重扫一致）、`RefreshController.tick` 编排（成功 / 失败 / 恢复 / stale / 配置缺失）、`StatusBarPresenter` 三个渲染函数（含「只有一份合并用量块、没有「其他」行」的菜单结构断言）、`UsageBarMenuItemView` 段色与最小条宽、`SleepGuard` 到期与取消路径、`LogoCatalog` 资源落地。
- **退出码**：0 = 全部通过，输出 `[self-check] OK (全部通过)`；1 = 任意失败，输出 `[self-check] FAIL (N):` + 每条失败 label。
- **发布前必跑**：

```bash
swift build -c release && \
swift run kimi-companion --self-check   # 期望 [self-check] OK (全部通过)
./build.sh                              # 出 build/kimi-companion.app
```

- **手动烟测**：`open build/kimi-companion.app` 后看菜单栏是否渲染出选中 provider 的余额 / `¥X.XX` / `X%` 与 logo；「菜单栏显示」子菜单切换 provider 是否即时生效并带 ✓；「立即刷新」是否即时重抓；偏好面板切换刷新档位是否在 ~1 个 tick 内生效；「阻止系统休眠」启动后菜单栏是否变咖啡色胶囊 + ` ☕`、倒计时是否只在菜单打开时走动。
- **不要**靠 unit test 覆盖率衡量进度；当前靠 `SelfCheck` + 人工菜单栏检查。

## 提交前对照

1. 没有新增凭据来源：`api_key` 仍只来自 `~/.kimi-code/config.toml` 内联字段（ADR-0002）；没有 `getenv`、Keychain、kimi-code HTTP server 调用。
2. 用量仍是**合并的一份**（ADR-0006）：没有按 provider / model 分组、没有读 `model` 字段、没有 `UsageGroup` 或「其他」行。
3. 会话日志读取保持增量：Read Cursor 只在内存、不落盘；mtime 剪枝边界与保留窗口同值（ADR-0004）。
4. 菜单栏 provider 仍只由用户显式选择决定；没有让 provider 失败 / `default_model` 变化触发自动切换（ADR-0005）。
5. 没有新增对 `~/Library/Caches/<bundle-id>/` 的写盘逻辑；没有新增 `LaunchAgent` plist。
6. 没有引入宏展开的 SwiftUI API（`@State` / `@StateObject` / `@Environment` / `@Bindable`）；视图状态用 `ObservableObject` + `@ObservedObject`。
7. 没有新增外部依赖（仍只有 TOMLKit）；没有引入 Conan / CocoaPods / Carthage。
8. 新端点必须 HTTPS，且经 `normalizeBaseURL`（去尾斜杠 + 强制 https + 回退官方默认）。
9. `SelfCheck.run()` 通过、`build.sh` 成功、`build/kimi-companion.app` ad-hoc 签名通过 `codesign -dv` 校验。
10. `CHANGELOG.md` 已按项目规范补条目（只写新增特性 / 变更 / Bug 修复，不写常规版本迭代与依赖更新）。
