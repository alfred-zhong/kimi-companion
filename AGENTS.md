# kimi-companion — Agent 手册

> 面向 AI 助手的仓库协作手册。补充人类规范；不重复常识。决策缘由见 `docs/adr/0001-0008`（0003 已被 0006 取代）。

macOS 菜单栏常驻 app（LSUIElement，无 Dock 图标），展示 kimi-code desktop 所用第三方 provider 的余额 / 配额，加一份**合并的** token 用量（不区分 provider / model）。每 30 / 60 / 120s 刷新（默认 60s）。抓取失败永不空白：菜单栏显示 `?kimi` / `⚠︎<短标签>`，菜单给出可照抄去改配置的中文说明。

- **Provider**：`DeepSeek`（账户余额 CNY）、`OpenCode Go`（5h / 7d / 月度三窗口配额，已用百分比）、`Kimi`（Moonshot 开放平台可用余额 CNY，单行 `余额 ¥49.59`，`available_balance ≤ 0` 时该行追加 ` ⚠`）。
- 有意不支持 first-party `managed:kimi-code` 账号（`api_key` 恒空、走 OAuth，本地 `oauth/usage` 端点只覆盖该账号）。

## 硬性不变量

- **凭据**：只读 `~/.kimi-code/config.toml` 的内联 `api_key`（ADR-0002）。通用来源 `[providers.<段名>]`；`[services.moonshot_search]` / `[services.moonshot_fetch]` 是**只服务 `Kimi` 的例外**（ADR-0008），不得扩展成通用凭据通道。不写回该文件、不读 Keychain、不读 `api_key_env`（不 `getenv`）、不碰 kimi-code 本地 HTTP server（`server/instances/*.json`、`server.token`、`mcp.json`）。
- **用量是合并的一份**（ADR-0006）：所有 `usage.record` 无条件求和，不按 provider / model 分组，`model` 字段完全不读。菜单里 provider section 只放余额 / 配额；用量块（`今日` / `近 5h`）独立成段，放在所有 section 之后。
- **无磁盘缓存**：每 tick 实时查 provider + 增量读会话日志，Read Cursor 只在进程内（ADR-0004）。不写 `~/Library/Caches/<bundle-id>/`。唯一持久化是 UserDefaults（刷新间隔 / 选中 provider / 清理策略）。
- **菜单栏 provider 是显式选择**（ADR-0005）：`default_model` 推导只在首启用一次，此后用户选择优先，provider 失败绝不自动切换 `selectedProvider`。
- **不 shell-out 任何上游 CLI**。新增 provider 只需枚举 case + `BalanceProvider.fetch`，外加在 `LiveBalanceSource.captureOne` 的穷尽 `switch` 里声明凭据来源（漏了会编译失败）。
- `ProviderBalanceState.isStale` 是余额侧唯一的退化路径：失败但有旧值时保留旧值并标注。

## 唯一的破坏性能力：清理 Chat Session（ADR-0007）

菜单 `清理 session 文件…` → 后台扫描 → Cleanup Preview → 用户点「确定」才真删（点「取消」什么都不做）→ 结果弹窗 + 完整刷新一次。机制是**直接删文件系统**，不走 kimi-code 本地 HTTP 删除接口、不 shell-out 任何外部进程。策略是**合取**（Keep Count ∧ 30 分钟活跃保护 ∧ Retention Days），参数在偏好面板，30 分钟活跃保护是写死的常量。**删除不可撤销**。

绝不触碰：`server/instances/`、`server.token`、`mcp.json`、`search-index/`、`sessions/.index-cache/`、`sessions/.index-dirty/`、`workspaces.json`、`config.toml`、`server/events/__global__.jsonl`。`session_index.jsonl` 修剪只摘「有 `sessionDir` 字段且该目录不存在」的行；墓碑行（无 `sessionDir`）与不可解析的行原样保留；有改动才写，写前备份为 `…bak-<时间戳>`。

## 架构 / 数据流

```
@main KimiCompanion.main → AppDelegate.applicationDidFinishLaunching（DI 装配）
  installMainMenu · KimiConfigSource · SettingsStore · WireLogReader
  LiveBalanceSource（ProviderID.supported 各独立跑一遍）· LiveDailyUsageSource
  RefreshController · SessionCleanup · SleepGuard · SettingsWindowController · StatusBarController

tick: balanceSource.capture → config.load → 逐 provider[凭据来源判定 → 凭据检查 → fetch] → BalanceCapture
        → MainActor.run { state.applyBalance(balanceOutcome(for:)) }
      dailySource.capture → reader.events → aggregator.aggregate → (DailyUsageSnapshot, nil)
        → MainActor.run { applyDaily(snap:err:) }
清理: cleanup.scan(now:policy:) → CleanupPlan → CleanupPresenter.previewContent → NSAlert
        → 用户「确定」→ cleanup.apply(plan:now:) → CleanupOutcome → 结果 → controller.tick()
```

DI 全走构造器注入，无 Service Locator / 全局单例。

## 命令

```bash
make build   # = ./build.sh：swift build -c release + 拼 .app + ad-hoc codesign
make run     # build 后 open build/kimi-companion.app
make test    # swift run kimi-companion --self-check（必跑）
make clean   # rm -rf build .build
```

`CONFIG=debug make build` 可编 debug。发布前必跑：`swift build -c release && swift run kimi-companion --self-check`（期望 `[self-check] OK (全部通过)`）`&& ./build.sh`。

## 约定

### 异步
- 不引入 `DispatchQueue` / `actor`（`WireLogReader` 用 `NSLock`，`SleepGuard` 用 `@MainActor`）。fetch 用 `async/await`，回主线程 `await MainActor.run { … }`，Combine 桥接 `MainActor.assumeIsolated`。
- tick 在 `Timer.scheduledTimer`（`RunLoop.main` + `.common`）上调度，每次 fire 包 `Task { @MainActor in await controller.tick() }`。`StatusBarController.init` 会 fire 首次 tick **加上** timer 首次 tick，不去重。
- `WireLogReader.events(now:)` 是同步阻塞 I/O：调用方保证不在主线程直接调。

### 错误处理
- `HTTPError`：`timeout | unauthorized(status:) | rateLimited | server(status:) | invalidResponse | missingCredential`；非 2xx 在 `URLSessionHTTPClient` 里就分类。
- 各 provider 的 `decode` 宁可 `throw .invalidResponse` 也不展示凭空的 `¥0.00`：DeepSeek 的 `balance_infos` 缺失 / 为空 / 不可解析 → 报错；OpenCode Go 三窗口 all-or-nothing；`Kimi` 的 `code != 0` / `status != true` / 三个余额字段（`available_balance` / `voucher_balance` / `cash_balance`）任一不可解析 → 报错（`jsonDouble` 兼容字符串与数字两种数值形状）。
- 单 provider 失败被 `LiveBalanceSource.captureOne` 收敛成 `ProviderCapture(failure:)`，**不 throw 出 Source**：一个 provider 的失败绝不短路另一个。
- `LiveBalanceSource.humanReadable(_:)` 把 `HTTPError` 映射成中文文案（`请求超时 (10 秒)` / `鉴权失败 (401)` / `请求过快 (429)` / `服务异常 (5xx)` / `响应解析失败` / `凭据缺失`），缺省回退 `localizedDescription`。
- `ProviderFailure` 是类型化枚举而非裸字符串：菜单栏短标签（`⚠︎配置` / `⚠︎凭据`）与菜单长文案都由它纯函数派生。`.credentialSection(reason)` 目前只有 `Kimi` 走到（段不存在 / `api_key` 为空 / 只用 `api_key_env`），中文 reason 由 `KimiProvider.credentialPreflight` 拼好，短标签仍是 `⚠︎凭据`。

### 状态 / DI
- `AppState`（`final class : ObservableObject, @unchecked Sendable`）持 6 个 `@Published`：`configMissing` / `balances` / `daily` / `lastDailyError` / `caffeinateSession` / `selectedProvider`。所有修改必须经过 setter，setter 都在主线程被调用。
- 余额是 **per-provider 字典** `[ProviderID: ProviderBalanceState]`，不是单个快照；逐 provider 的合并细节封在 `RefreshController.balanceOutcome(for:)`。
- 倒计时不走 `AppState`：菜单侧 `CountdownTicker` 按秒 in-place 改 `NSMenuItem.title`，`SleepGuard` 只用一次性到期定时器。
- 所有跨任务类型 `Sendable`；跨线程持有者用 `@unchecked Sendable` + 命名 setter。

### 命名 / 模板
- 值类型优先（`struct BalanceResult` / `TokenStats` / `HourBucket` / `DailyUsageSnapshot`），行为 / 纯函数走 `enum` 单例（`BalanceRegistry` / `SelfCheck` / `CompactFormatter` / `BalanceFormatter` / `HourlyAggregator` / `StatusBarPresenter` / `LogoCatalog` / `MenuBarSelection`）。
- `ProviderID.supported`（`[.deepseek, .opencodeGo, .kimi]`，顺序即菜单 section 顺序）是「菜单里永远都在的 provider」的唯一来源；`allCases` 含 `.unknown`，只作 `default_model` 前缀未匹配的哨兵与 logo / 查表缺省分支。`Kimi` 的 `configSectionName`（`"Kimi"`）只承担展示名与前缀匹配，**不代表存在 `[providers.Kimi]` 段**（凭据走 `[services.*]`）。

### 文案 / 标题
- 错误文案集中在 `ProviderFailure.menuText(provider:)` + `LiveBalanceSource.humanReadable(_:)`，新增错误显示分支优先复用。
- `renderTitle` 优先级：`configMissing("?kimi") > 选中 provider 的 result > 其 failure(⚠︎<短标签>) > "···"`，**只看选中 provider**。所有分支头部补两个 Thin Space（`\u{2009}\u{2009}`）拉开 logo 与文字间距；caffeinate 激活时余额右侧追加 ` ☕`（`\u{2615}`，咖啡色 `#8B5A2B`）。
- 时间：`formatHMS(_:)` → `HhMm`；`formatDuration(_:)` → `≥24h` 用 `XdYh`、否则 `HhMm`，全程无空格。
- 用量行（`StatusBarPresenter.dailyLine`）：`今日 · ↑in · ↓out · ⚡cacheRead · 🎯hit%` 与 `近 5h · …`，两份都是**合并口径**；菜单里只有这两行，没有 per-provider 用量行，也没有「其他」行。
- 本 app **不写日志文件**，也不 `print` 运行时信息（`SelfCheck` 的 `print` 是唯一输出）。

### 用量桶 / 进度条不变量
- 12 个 `HourBucket`，索引 0 最旧、末位最新，区间左开右闭 `(startMs, endMs]`；末桶永远是完整一小时（`endMs = nowMs`）。`DailyUsageSnapshot.last5h` = `hourly.suffix(5)` 的并集 = `[now-5h, now]`。
- 事件 `tsMs < todayStartMs` 不算「今日」但**仍可**进小时桶（窗口可跨零点）；`hoursAgo ∉ [0, 12)` 才丢。去重键 `"\(relPath):\(lineOffset)"`，不要改成其它样式。
- 段色：`isOK == false` → 强制红；否则 `<70` 绿 / `70–90` 黄 / `>90` 红。
- 进度条行宽：右区（状态串 / 重置倒计时）按本行文本实测预留（`trailingWidth(for:)`，无文本 0，下限 `minTrailingRegionWidth` 84pt），条长下限 `minBarWidth` 150pt，右区文本距视图右缘 `trailingRightMargin` 20pt；视图宽度取 `minimumWidth(hasLeftLabel:trailingWidth:)`，整行铺满、三窗口正常形态条长一致。**不要**退回「固定预留宽度 + 240pt 底宽」的写法。

### 添加 Provider
1. `ProviderID` 加 `case`（`rawValue` 小写连字符，如 `opencode-go`）+ `configSectionName`（逐字段名）+ `displayName`。像 `Kimi` 一样没有 `[providers.*]` 段时，`configSectionName` 只承担展示名与前缀匹配。
2. `Balance/Providers.swift` 加 `struct XxxProvider: BalanceProvider`，实现 `hasCredential(creds:)` + `fetch(creds:http:) async throws`。凭据经 `CredentialSource`（`TomlCredentialSource` 实现，只读 config.toml），默认读自己的 `[providers.<段名>]`。**provider 可以刻意偏离**（`Kimi` 读 `[services.*]`、端点写死，ADR-0008），但偏离必须（a）在 `captureOne` 的穷尽 `switch` 里显式声明凭据来源，（b）单独记一条 ADR。
3. `BalanceRegistry.provider(for:config:)` 补路由（`base_url` 从 `config?.provider(id.configSectionName)?.baseURL` 取，经 `normalizeBaseURL` 去尾斜杠 + 强制 HTTPS；写死端点的 provider 不读 `base_url`）。
4. 加入 `ProviderID.supported`（顺序即菜单 section 顺序）。
5. percent 型给 `quotaWindows`（`StatusBarPresenter.valueItems` 自动渲染成进度条行）；金额型给 `balance` + `currency`，`isAvailable == false` 时余额行自动追加 ` ⚠`。
6. `LogoCatalog.assetBaseName(for:)` 补 logo 基名，并把 `Resources/<基名>@2x.png` / `@3x.png` 落地（`build.sh` 自动复制）。
7. `SelfCheck` 补路由 / 解码 / URL / 凭据预检断言（`Kimi` 的解码与凭据预检三分支、config `[services.*]` 解析是现成模板）。

## 关键文件

| 文件 | 角色 |
|---|---|
| `App.swift` | `@main` 入口 + DI 装配 + `--self-check` 分派 + 最小主菜单（含「编辑」，偏好窗口才能 Cmd+V） |
| `RefreshController.swift` | tick 编排 + `AppState`（`ObservableObject`，6 个 `@Published`） |
| `SelfCheck.swift` | 进程级断言入口（`static run() -> Int`，697 个 `check(...)` 调用点） |
| `Model/Models.swift` | 共享值类型：`ProviderID` / `MenuBarSelection` / `BalanceResult` / `QuotaWindow` / `ProviderFailure` / `ProviderCapture` / `ProviderBalanceState` / `TokenStats` / `HourBucket` / `DailyUsageSnapshot` / `CaffeinateBucket` / `CaffeinateSession` / `RefreshInterval` |
| `Balance/Providers.swift` | `BalanceProvider` 协议 + `DeepSeekProvider` + `OpenCodeGoProvider` + `KimiProvider` + `jsonDouble` + `BalanceRegistry` + `normalizeBaseURL` |
| `Balance/CredentialSource.swift` | 凭据路径解析（`resolve(_ name:)`）：裸段名查 `[providers.*]`，`services.<段名>` 查 `[services.*]`（`Kimi` 专用） |
| `Balance/HTTPClient.swift` | `HTTPClient` 协议 + `URLSessionHTTPClient`（仅 HTTPS）+ `HTTPError` |
| `Balance/BalanceFormatter.swift` | 状态栏 / 菜单文案：`statusBarText` / `menuBarText` / `formatHMS` / `formatDuration` |
| `Config/KimiConfigSource.swift` | `config.toml` 读取（`KimiConfigLoad` / `KimiConfig.credentialSection(_:)`，`[providers.*]` 与 `[services.*]` 两张表）+ `TomlCredentialSource` |
| `Refresh/LiveSources.swift` | 生产 `LiveBalanceSource` / `LiveDailyUsageSource` + `humanReadable(_:)` |
| `Refresh/SnapshotError.swift` | `SnapshotError` + `BalanceCapture` / `BalanceSource` / `BalanceRefreshOutcome` / `DailyUsageSource` |
| `Refresh/Fakes.swift` | `FakeBalanceSource` / `FakeDailyUsageSource`（SelfCheck 用） |
| `Usage/WireLineParser.swift` | 单行 `usage.record` → `UsageEvent`（只取 `time` + `usage` 四个计数，不读 `model`） |
| `Usage/WireLogReader.swift` | 增量读取 + 进程内 Read Cursor + 保留窗口（ADR-0004） |
| `Usage/HourlyAggregator.swift` | 12 滑动小时桶 + 合并 `today`；不按 provider 分组 |
| `Usage/Formatting.swift` | `CompactFormatter.format(Int)` K/M/B + `999_500 → "1.0M"` |
| `SleepGuard/*.swift` | `SleepGuard`（单会话 IOPMAssertion）/ `IOPMAssertionAdapter`（system + display 成对）/ `SessionExpiryTimer`（一次性到期）/ `CountdownTicker`（1Hz，只在菜单打开期间启停）/ `CountdownFormatter` |
| `Cleanup/SessionCleanup.swift` | 扫描 + 执行清理（唯一破坏性能力，ADR-0007）；纯 Foundation，`Sendable` 值类型上的 `async` 包装 |
| `Cleanup/CleanupPresenter.swift` | 清理的全部用户可见文案（纯函数、无 AppKit）：`humanBytes` / `previewContent` / `noDeletionDiagnostic` / `completionContent` |
| `UI/StatusBarController.swift` | `NSStatusItem` + `NSMenu` + `Timer` + Combine sink；`cleanupSessions()` 编排「扫描 → 预览 → 执行 → 结果」，带 `cleanupInFlight` 重入闸 |
| `UI/StatusBarPresenter.swift` | 纯函数展示层：`renderTitle` / `renderChrome` / `renderMenu` + `MenuItemSpec` / `UsageBarSpec` |
| `UI/UsageBarMenuItemView.swift` | 自绘用量进度条菜单项（轨道 + 段色填充 + 重置倒计时） |
| `UI/CleanupAlertPresenter.swift` | `NSAlert` 接线（预览 / 结果 / 固定 220pt 可滚动等宽详情区）；LSUIElement 下弹窗前自己抢焦点 |
| `UI/SettingsWindow.swift` | `SettingsStore`（`@Published` × 镜像 UserDefaults）+ `NSHostingController<SettingsView>`（刷新间隔 + 清理策略两项 `Stepper`） |
| `Brand/LogoCatalog.swift` | `ProviderID` → `NSImage` 查表 + template 标记；未知 provider 返回 nil |
| `Resources/Info.plist` | **`LSUIElement=true`**、`CFBundleIdentifier=com.alfred-zhong.kimi-companion`、`CFBundleIconFile=AppIcon`、`LSMinimumSystemVersion=13.0`、版本 `0.3.0`（build `3`，与 `META` 同步） |
| `Resources/provider_*.png` | 菜单栏 logo（`@2x` / `@3x`，无 `.color.png` 兜底） |
| `Resources/AppIcon.icns` | app 图标（`CFBundleIconFile` 指向；Finder / `NSAlert` 用）。由 `Tools/make-appicon.swift` 生成，勿手改 |
| `Tools/make-appicon.swift` | 图标生成脚本（不在 SwiftPM target 里，`swift Tools/make-appicon.swift` 直接跑；改设计改这里再重新生成） |
| `docs/adr/0001-0008-*.md` | 现行决策记录（见文首） |
| `Package.swift` / `Package.resolved` / `Makefile` / `build.sh` | SwiftPM 入口（`swift-tools-version: 5.9`，macOS `.v13`，唯一外部依赖 `TOMLKit`）/ 锁定 TOMLKit 0.6.0（随仓库提交）/ 常用命令 / 构建 + 拼 `.app`（复制 `Resources/*.png` + `*.icns`）+ ad-hoc 签名 |

## 运行 / 工具链

- macOS 13.0+，Apple Silicon / Intel 均可。纯 Swift in-process，无 Node / Python / 外部进程依赖。
- **构建环境是 Command Line Tools only**（`xcode-select -p` → `/Library/Developer/CommandLineTools`），`xcodebuild` 不可用。实测工具链：macOS 27 SDK、Swift 6.4。
- CLT-only 下每次链接都会有两行 `ld: warning: search path '…/CommandLineTools/Developer/…' not found`（`…/Developer/usr/lib` 与 `…/Developer/Library/Frameworks`）：`xcrun --show-sdk-platform-path` 在只装 CLT 的机器上查不到（`unable to lookup item 'PlatformPath' from command line tools installation`），SwiftPM 于是拿 `xcode-select -p` 当平台目录拼出这两个并不存在的路径。**与本仓库代码无关**——同一台机器上任何 SwiftPM 包（含 `swift build` 新建的空包）都这样。要真修掉，一次性把目录建出来即可（ld 只对「不存在」的搜索路径告警，建出来的空目录没有任何副作用）：`sudo mkdir -p /Library/Developer/CommandLineTools/Developer/usr/lib /Library/Developer/CommandLineTools/Developer/Library/Frameworks`。不要为了消这两行往 `Package.swift` 塞 `-Xlinker -w`（那是压掉**全部**链接告警，在有 Xcode 的机器上纯属多余）。
- **SwiftUI 代码不得依赖宏展开的 API**（`@State` / `@StateObject` / `@Environment` / `@Bindable`）：macOS 27 SDK 起它们是外部宏，插件 `libSwiftUIMacros.dylib` 只随 Xcode 提供，CLT 下编译会以 `plugin for module 'SwiftUIMacros' not found` 失败。视图内可变状态一律用 `ObservableObject` + `@ObservedObject`。
- 包管理 SwiftPM；唯一外部依赖 `TOMLKit`（`from: 0.6.0`）。不新增 Conan / CocoaPods / Carthage。
- 签发只做本机 ad-hoc（`codesign --force --deep --sign -`），不做 Developer ID 公证。不新增 `LaunchAgent` plist，app 不自启。
- provider 请求走 `URLSession.shared`，未配 `NSAppTransportSecurity` 例外；新增端点必须 HTTPS 且经 `normalizeBaseURL`（去尾斜杠 + 强制 https + 回退官方默认）。`Kimi` 的端点是写死的 https 国内站 `api.moonshot.cn`，不经 `normalizeBaseURL`。

## 测试

- 无 XCTest / Swift Testing：测试以 **`SelfCheck` 进程级断言**形式存在，由 `--self-check` 调用（`make test` 等价）。
- 新增断言：在 `SelfCheck.run()` 内追加 `check("...", cond)`（纯函数 + `Bool` 条件）。不要引入 XCTest。
- 退出码：0 = 全部通过（`[self-check] OK (全部通过)`）；1 = 任意失败（`[self-check] FAIL (N):` + 失败 label）。
- 覆盖：各 provider 解码 / URL / 凭据预检（含 `Kimi` 三分支与 config `[services.*]` 解析）、`TokenStats` / `CompactFormatter` / `BalanceFormatter` 边界、`HourlyAggregator` 桶边界与跨零点、`WireLineParser` / `WireLogReader` 增量契约、`RefreshController.tick` 编排（成功 / 失败 / 恢复 / stale / 配置缺失）、`StatusBarPresenter` 三渲染函数与菜单结构、`UsageBarMenuItemView` 段色与最小条宽、`SleepGuard` 到期与取消、`LogoCatalog` 资源、app 图标（icns 落地 / magic / `CFBundleIconFile` 同名 / 尺寸档位）、清理（合取四分支 / `humanBytes` / 预览与完成文案 / `session_index.jsonl` 修剪 / 临时目录端到端）。
- 手动烟测：`open build/kimi-companion.app` 看菜单栏是否渲染出选中 provider 的余额 / `¥X.XX` / `X%` 与 logo；Finder 里 `build/kimi-companion.app` 是否显示自绘图标（不是通用图标）；「菜单栏显示」三个选项切换是否即时生效并带 ✓；「立即刷新」是否即时重抓；偏好面板档位是否 ~1 个 tick 内生效；「阻止系统休眠」是否变咖啡色胶囊 + ` ☕`、倒计时是否只在菜单打开时走动；「清理 session 文件…」是否弹出预览、点「取消」是否什么都没删。`Kimi` 凭据来自 `[services.moonshot_search]`：改掉 / 删掉那把 `api_key` 应看到 `⚠︎凭据` + 中文说明，而不是空白或 `¥0.00`。
- **不要**靠 unit test 覆盖率衡量进度；当前靠 `SelfCheck` + 人工菜单栏检查。

## 提交前

- 上文「硬性不变量」「清理」全部仍成立。
- `SelfCheck` 通过、`build.sh` 成功、`build/kimi-companion.app` ad-hoc 签名通过 `codesign -dv` 校验。
- `CHANGELOG.md` 已按项目规范补条目（只写新增特性 / 变更 / Bug 修复，不写常规版本迭代与依赖更新）；`META` 与 `Resources/Info.plist` 的版本号同步。
- 改过图标设计（`Tools/make-appicon.swift`）后重新生成 `Resources/AppIcon.icns`，别只改脚本不落产物。
