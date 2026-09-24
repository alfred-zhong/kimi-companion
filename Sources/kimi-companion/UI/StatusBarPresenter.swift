import AppKit
import Foundation

/// StatusBar 展示层：把 `AppState` 转成 `NSAttributedString` / `ChromeSpec` / `[MenuItemSpec]`。
///
/// interface 收敛为三个纯函数，`StatusBarController` 只剩 Timer、Combine 订阅、转发到 `NSStatusItem`。
/// `SelfCheck` 因此可以完全不碰真实 UI 地断言全部渲染逻辑。
/// - `renderTitle` 处理菜单栏标题优先级链
/// - `renderChrome` 输出胶囊外观参数
/// - `renderMenu` 重建弹出菜单（两个 provider section + 合并用量块 + 菜单栏选择 + caffeinate）
public enum StatusBarPresenter {

    // MARK: - Inputs

    /// 状态栏 / 菜单渲染所需的状态聚合。Controller 负责从 `AppState` 拉平后传入。
    public struct Inputs: Sendable {
        public let configMissing: Bool
        /// 菜单栏展示哪个 provider 的值（用户显式选择）。
        public let selectedProvider: ProviderID
        /// provider → 余额状态；缺键按「尚未采集」处理。
        public let balances: [ProviderID: ProviderBalanceState]
        public let daily: DailyUsageSnapshot?
        public let lastDailyError: String?
        public let caffeinateSession: CaffeinateSession?

        public init(
            configMissing: Bool = false,
            selectedProvider: ProviderID = .deepseek,
            balances: [ProviderID: ProviderBalanceState] = [:],
            daily: DailyUsageSnapshot? = nil,
            lastDailyError: String? = nil,
            caffeinateSession: CaffeinateSession? = nil
        ) {
            self.configMissing = configMissing
            self.selectedProvider = selectedProvider
            self.balances = balances
            self.daily = daily
            self.lastDailyError = lastDailyError
            self.caffeinateSession = caffeinateSession
        }

        /// 单个 provider 的状态（缺键 → 空态）。
        public func balance(for provider: ProviderID) -> ProviderBalanceState {
            balances[provider] ?? ProviderBalanceState(provider: provider)
        }
    }

    // MARK: - ChromeSpec

    /// 状态栏 button 的视觉参数。Controller 负责套到 `NSButton` 上，Presenter 不知道 `NSButton` 的存在。
    public struct ChromeSpec: Equatable, Sendable {
        public let background: NSColor
        public let cornerRadius: CGFloat
        public let contentTint: NSColor?

        public static let clear = ChromeSpec(background: .clear, cornerRadius: 0, contentTint: nil)
    }

    // MARK: - MenuSpec

    /// 渲染菜单项：含可挂回调的钩子，Controller 用来 in-place 刷新倒计时文字。
    public struct MenuItemSpec {
        public let title: String
        public let enabled: Bool
        public let key: String
        /// 是否需要 in-place tick；Controller 会把这个 item 存为 `caffeinateHeaderItem` 并每 tick 调一次。
        public let tickable: Bool
        /// `representedObject == CaffeinateBucket.rawValue` 时勾选。
        public let representedBucket: Int?
        /// `representedObject == ProviderID.rawValue` 时用于「菜单栏显示」子菜单。
        public let representedProvider: String?
        public let submenu: [MenuItemSpec]?
        /// 用量进度条（自定义 view）：非 nil 时 Controller 用 `UsageBarMenuItemView` 渲染，取代纯文本百分比行。
        public let usageBar: UsageBarSpec?

        public enum MenuAction: Equatable, Sendable {
            case forceRefresh
            case quit
            case showSettings
            /// 「清理 session 文件…」：扫描 → 预览 → 确认后删除。
            case cleanupSessions
            /// 「菜单栏显示 ▸」里选中某个 provider。
            case selectProvider
            case caffeinateBucket
            case caffeinateCancel
        }

        /// `title` 为空且无 action / submenu / usageBar 时 Controller 装成分隔线。
        public let action: MenuAction?

        public static let separator = MenuItemSpec(
            title: "", enabled: true, key: "", action: nil, tickable: false,
            representedBucket: nil, representedProvider: nil, submenu: nil, usageBar: nil
        )

        public init(
            title: String,
            enabled: Bool = true,
            key: String = "",
            action: MenuAction? = nil,
            tickable: Bool = false,
            representedBucket: Int? = nil,
            representedProvider: String? = nil,
            submenu: [MenuItemSpec]? = nil,
            usageBar: UsageBarSpec? = nil
        ) {
            self.title = title
            self.enabled = enabled
            self.key = key
            self.action = action
            self.tickable = tickable
            self.representedBucket = representedBucket
            self.representedProvider = representedProvider
            self.submenu = submenu
            self.usageBar = usageBar
        }

        /// 用量进度条菜单项：`leftText` 为窗口标签（`5h` / `7d` / `月度`），
        /// `value` 为已用百分比（0...100），`percentText` 紧贴条尾，`resetText` 为条右侧左对齐的说明。
        /// `isOK == false` 时进度条强制红色（与已用百分比无关）。
        public static func usageBar(
            leftText: String? = nil,
            value: Double,
            percentText: String,
            resetText: String? = nil,
            isOK: Bool = true
        ) -> MenuItemSpec {
            MenuItemSpec(
                title: "",
                enabled: false,
                usageBar: UsageBarSpec(
                    leftText: leftText,
                    value: value,
                    percentText: percentText,
                    resetText: resetText,
                    isOK: isOK
                )
            )
        }
    }

    /// 用量进度条数据。`value` 为已用百分比（调用方已 clamp）；`isOK == false` → 强制红条。
    public struct UsageBarSpec: Sendable {
        public let leftText: String?
        public let value: Double
        public let percentText: String
        public let resetText: String?
        public let isOK: Bool

        public init(leftText: String?, value: Double, percentText: String, resetText: String?, isOK: Bool) {
            self.leftText = leftText
            self.value = value
            self.percentText = percentText
            self.resetText = resetText
            self.isOK = isOK
        }
    }

    // MARK: - Constants

    /// 咖啡色近似值（#8B5A2B），与 macOS Control Center 模块同色系。
    public static let caffeinateColor = NSColor(
        calibratedRed: 0x8B / 255.0,
        green: 0x5A / 255.0,
        blue: 0x2B / 255.0,
        alpha: 1.0
    )

    /// 所有分支统一在头部补两个 Thin Space（≈0.5pt），拉开 logo 与文字的间距。
    private static let logoTextGap: String = "\u{2009}\u{2009}"
    private static let caffeinateSuffix: String = " \u{2615}"

    // MARK: - renderTitle

    /// 菜单栏标题优先级链：
    /// `configMissing("?kimi") > 选中 provider 的余额 > 选中 provider 的失败(⚠︎<短标签>) > "···"`。
    ///
    /// **只看选中 provider**：另一个 provider 的状态再糟也不影响菜单栏，网络抖动更不会把菜单栏
    /// 自动切到另一个 provider。
    ///
    /// 守护激活时在余额右侧追加 ` ☕`（咖啡色），并把数值两侧补空格避免胶囊裁切 ——
    /// 视觉焦点留给主信息。
    public static func renderTitle(_ inputs: Inputs) -> NSAttributedString {
        let active = inputs.caffeinateSession != nil

        if inputs.configMissing {
            // 与 omp-companion 一致：配置缺失分支不追加 ☕（此时连 provider 都没得谈）。
            return NSAttributedString(string: "\(logoTextGap)?kimi")
        }

        let state = inputs.balance(for: inputs.selectedProvider)
        if let result = state.result {
            let text = BalanceFormatter.statusBarText(result)
            return compose(body: active ? " \(text) " : text, caffeinateActive: active)
        }
        if let failure = state.failure {
            let tag = failure.statusBarTag
            let body = active ? " ⚠︎\(tag) " : "⚠︎\(tag)"
            return compose(body: body, caffeinateActive: active)
        }
        return NSAttributedString(string: "\(logoTextGap)···")
    }

    private static func compose(body: String, caffeinateActive: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\(logoTextGap)\(body)")
        guard caffeinateActive else { return result }
        result.append(NSAttributedString(
            string: caffeinateSuffix,
            attributes: [.foregroundColor: caffeinateColor]
        ))
        return result
    }

    // MARK: - renderChrome

    /// 状态栏 button 胶囊参数。`active = caffeinateSession != nil`。
    public static func renderChrome(_ inputs: Inputs) -> ChromeSpec {
        if inputs.caffeinateSession != nil {
            return ChromeSpec(
                background: caffeinateColor,
                cornerRadius: StatusBarChromeMetrics.cornerRadius(buttonHeight: 18),
                contentTint: .white
            )
        }
        return .clear
    }

    // MARK: - renderMenu

    /// 弹出菜单。
    ///
    /// 结构（固定顺序，两个 provider 永远都在；用量只有**一份合并**的，不按 provider 分）：
    /// ```
    /// DeepSeek
    ///   余额 ¥65.92 [⚠]
    /// ──────
    /// OpenCode Go
    ///   [5h ███ 16% 4h17m 后重置]
    ///   [7d ███ 22% 5d3h 后重置]
    ///   [月度 ██ 13% 26d 后重置]
    /// ──────
    /// 今日 · ↑… · ↓… · ⚡… · 🎯…%
    /// 近 5h · …
    /// ──────
    /// 菜单栏显示 ▸ (DeepSeek / OpenCode Go，选中打 ✓)
    /// ──────
    /// 阻止系统休眠 ▸ (30 / 60 / 120 分钟) + 倒计时行 + 取消守护
    /// ──────
    /// 偏好… / 立即刷新
    /// ──────
    /// 清理 session 文件…
    /// ──────
    /// 退出
    /// ```
    public static func renderMenu(_ inputs: Inputs, now: Date = Date()) -> [MenuItemSpec] {
        var items: [MenuItemSpec] = []

        for (index, pid) in ProviderID.supported.enumerated() {
            if index > 0 { items.append(.separator) }
            items.append(contentsOf: providerSection(pid, inputs, now: now))
        }

        // 两个 provider section 之后、菜单栏选择之前：一份合并的用量块。
        let usage = usageItems(inputs)
        if !usage.isEmpty {
            items.append(.separator)
            items.append(contentsOf: usage)
        }

        items.append(.separator)

        let sub = ProviderID.supported.map { pid in
            MenuItemSpec(
                title: "\(pid.displayName)\(inputs.selectedProvider == pid ? " ✓" : "")",
                action: .selectProvider,
                representedProvider: pid.rawValue
            )
        }
        items.append(MenuItemSpec(title: "菜单栏显示", submenu: sub))

        items.append(.separator)
        items.append(contentsOf: caffeinateItems(inputs, now: now))

        items.append(.separator)
        items.append(MenuItemSpec(title: "偏好…", key: ",", action: .showSettings))
        items.append(MenuItemSpec(title: "立即刷新", key: "r", action: .forceRefresh))
        items.append(.separator)
        // 清理不依赖任何状态（不显示进度 / 计数），因此每次打开菜单都重建为「可用」即可。
        items.append(MenuItemSpec(title: "清理 session 文件…", action: .cleanupSessions))
        items.append(.separator)
        items.append(MenuItemSpec(title: "退出", key: "q", action: .quit))
        return items
    }

    /// 单个 provider 的 section：header（只有 provider 名，不带模型名）+ 余额 / 配额行。
    /// 用量行不在这里 —— 用量是全局合并的一份，见 `usageItems`。
    private static func providerSection(_ pid: ProviderID, _ inputs: Inputs, now: Date) -> [MenuItemSpec] {
        var items: [MenuItemSpec] = [MenuItemSpec(title: pid.displayName, enabled: false)]
        let state = inputs.balance(for: pid)

        if let result = state.result {
            items.append(contentsOf: valueItems(result, now: now))
        } else if state.failure == nil {
            items.append(MenuItemSpec(title: "余额: ···", enabled: false))
        }

        if let failure = state.failure {
            // 有旧值（stale）时把「这是旧值」说清楚，否则用户会以为抓取成功了。
            let text = failure.menuText(provider: pid)
            items.append(MenuItemSpec(
                title: state.isStale ? "⚠ 旧值 · \(text)" : text,
                enabled: false
            ))
        }

        return items
    }

    /// 合并用量块：今日 + 近 5h，不区分 provider / model。
    /// 快照缺失时退化为错误行；两者都没有则不占位（调用方不追加分隔线）。
    private static func usageItems(_ inputs: Inputs) -> [MenuItemSpec] {
        if let daily = inputs.daily {
            return [
                MenuItemSpec(title: dailyLine(prefix: "今日", stats: daily.today), enabled: false),
                MenuItemSpec(title: dailyLine(prefix: "近 5h", stats: daily.last5h), enabled: false),
            ]
        }
        if let err = inputs.lastDailyError {
            return [MenuItemSpec(title: "用量: \(err)", enabled: false)]
        }
        return []
    }

    /// 余额 / 配额的数值行。
    private static func valueItems(_ result: BalanceResult, now: Date) -> [MenuItemSpec] {
        switch result.currency {
        case .cny, .usd:
            // `is_available: false` 时金额仍是真数据，但要能看出当前不可用。
            var text = "余额 \(BalanceFormatter.menuBarText(result))"
            if result.isAvailable == false { text += " ⚠" }
            return [MenuItemSpec(title: text, enabled: false)]
        case .percent:
            guard let windows = result.quotaWindows, !windows.isEmpty else {
                // 无窗口明细（不应发生）：回退纯文本用量行。
                return [MenuItemSpec(title: percentFallbackRow(result), enabled: false)]
            }
            return windows.map { windowItem($0, now: now) }
        }
    }

    private static func percentFallbackRow(_ result: BalanceResult) -> String {
        var s = "已用 \(BalanceFormatter.menuBarText(result))"
        if let reset = result.resetRemaining, reset > 0 {
            s += " · \(BalanceFormatter.formatDuration(reset)) 后重置"
        }
        return s
    }

    private static func windowItem(_ w: QuotaWindow, now: Date) -> MenuItemSpec {
        let remain = w.resetsAt.timeIntervalSince(now)
        let countdown = remain > 0 ? "\(BalanceFormatter.formatDuration(remain)) 后重置" : nil
        // 非 "ok"：进度条转红，并把服务端**原始** status 串带在行内 ——
        // 否则用户只会看到一个无法解释的红条。
        let resetText: String?
        if w.isOK {
            resetText = countdown
        } else {
            resetText = [w.status, countdown].compactMap { $0 }.joined(separator: " · ")
        }
        return .usageBar(
            leftText: w.label,
            value: w.usedPercent,
            percentText: "\(Int(w.usedPercent.rounded()))%",
            resetText: resetText,
            isOK: w.isOK
        )
    }

    /// `今日 · ↑in · ↓out · ⚡cacheRead · 🎯hit%`
    private static func dailyLine(prefix: String, stats: TokenStats) -> String {
        let hit = CompactFormatter.format(Int((stats.cacheHitRate * 100).rounded()))
        return "\(prefix) · ↑\(CompactFormatter.format(stats.inputTokens))"
            + " · ↓\(CompactFormatter.format(stats.outputTokens))"
            + " · ⚡\(CompactFormatter.format(stats.cacheReadTokens))"
            + " · 🎯\(hit)%"
    }

    /// 菜单里是否存在「活着」的倒计时行。Controller 据此决定是否启动 1Hz 刷新：
    /// 倒计时的生命周期 = 菜单的生命周期，菜单关闭时 0 次唤醒。
    public static func hasLiveCountdown(_ items: [MenuItemSpec]) -> Bool {
        items.contains { $0.tickable }
    }

    private static func caffeinateItems(_ inputs: Inputs, now: Date) -> [MenuItemSpec] {
        var items: [MenuItemSpec] = []
        if let session = inputs.caffeinateSession {
            let remaining = session.remainingSeconds(now: now)
            items.append(MenuItemSpec(
                title: "☕️ 阻止休眠 · 还剩 \(CountdownFormatter.format(remaining: remaining))",
                enabled: false,
                tickable: true
            ))
        }
        let activeBucket = inputs.caffeinateSession?.bucket
        let sub = CaffeinateBucket.allCases.map { bucket in
            MenuItemSpec(
                title: "\(bucket.label)\(activeBucket == bucket ? " ✓" : "")",
                action: .caffeinateBucket,
                representedBucket: bucket.rawValue
            )
        }
        items.append(MenuItemSpec(title: "阻止系统休眠", submenu: sub))
        if inputs.caffeinateSession != nil {
            items.append(MenuItemSpec(title: "取消守护", action: .caffeinateCancel))
        }
        return items
    }
}

/// 胶囊圆角：取 button 当前高度一半。
public enum StatusBarChromeMetrics {
    public static func cornerRadius(buttonHeight: CGFloat) -> CGFloat {
        max(buttonHeight, 1) / 2
    }
}
