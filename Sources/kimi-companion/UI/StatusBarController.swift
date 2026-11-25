import AppKit
import Combine
import Foundation
import QuartzCore

/// StatusBar controller：Timer / Combine 订阅 / 把 `StatusBarPresenter` 的输出写到 `NSStatusItem` + `NSMenu`。
/// 全部「AppState → 视觉」逻辑都在 `StatusBarPresenter`（纯函数），这里只做转发。
///
/// `@unchecked Sendable`：主线程独占（Timer block 跑在主 run loop、Combine 走 `RunLoop.main`、
/// 菜单回调都在主线程），所有可变字段只在这条线程上读写。
public final class StatusBarController: NSObject, NSMenuDelegate, @unchecked Sendable {
    private let statusItem: NSStatusItem
    private let controller: RefreshController
    private let state: AppState
    private let sleepGuard: SleepGuard
    private var timer: Timer?
    /// 1Hz 倒计时驱动：只在菜单打开且存在倒计时行时运行。
    private let countdownTicker: CountdownTicker
    private var cancellables: Set<AnyCancellable> = []
    private let onShowSettings: () -> Void
    private let onSelectProvider: (ProviderID) -> Void
    /// 用户从「菜单栏显示 ▸」选中「自动」。
    private let onSelectAuto: () -> Void
    private let cleanup: SessionCleanup
    /// 每次清理前现取一次策略（偏好面板随时可改，不在 init 时快照）。
    private let currentPolicy: () -> RetentionPolicy
    /// 峰谷切换点的精确唤醒（ADR-0011）：到点只重绘标题，不发网络请求。
    private var boundaryTimer: Timer?
    /// 已排程的切换点；同一个切换点不重复建 Timer。
    private var boundaryScheduledAt: Date?
    /// 同一批 `@Published` 变更的合并门闩（主线程读写）。
    private var refreshScheduled = false
    /// 上一次真正写进 status button 的内容：相同则跳过赋值，避免无谓的布局 / WindowServer 更新。
    private var lastTitle: NSAttributedString?
    private var lastChrome: StatusBarPresenter.ChromeSpec?
    private var lastLogoKey: String?
    /// 扫描 / 弹窗 / 删除期间的 in-flight 标志：再点菜单项不产生第二个弹窗。
    private var cleanupInFlight = false
    private var caffeinateHeaderItem: NSMenuItem?
    /// 按 provider + chrome 状态缓存 `NSImage`（caffeinate 激活时缓存白色副本）。
    /// key 形如 `provider.rawValue#idle|active`，避免每 tick 重新 lockFocus 渲染。
    private var logoCache: [String: NSImage] = [:]

    public init(
        controller: RefreshController,
        state: AppState,
        sleepGuard: SleepGuard,
        onShowSettings: @escaping () -> Void,
        onSelectProvider: @escaping (ProviderID) -> Void = { _ in },
        onSelectAuto: @escaping () -> Void = {},
        cleanup: SessionCleanup,
        currentPolicy: @escaping () -> RetentionPolicy,
        countdownTicker: CountdownTicker = TimerCountdownTicker()
    ) {
        self.controller = controller
        self.state = state
        self.sleepGuard = sleepGuard
        self.onShowSettings = onShowSettings
        self.onSelectProvider = onSelectProvider
        self.onSelectAuto = onSelectAuto
        self.cleanup = cleanup
        self.currentPolicy = currentPolicy
        self.countdownTicker = countdownTicker
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.title = "···"
        let menu = NSMenu()
        menu.autoenablesItems = false
        self.statusItem.menu = menu
        super.init()
        menu.delegate = self
        wireState()
        // 首次立即 tick 一次，外加 timer 的首次 fire：不主动去重（与 omp-companion 一致）。
        Task { @MainActor in
            await self.controller.tick()
        }
        startTimer()
    }

    deinit {
        timer?.invalidate()
        boundaryTimer?.invalidate()
    }

    /// 偏好面板切换刷新档位后调用。
    public func restartTimer() { startTimer() }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: controller.intervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.controller.tick() }
        }
        // 容忍 10% 抖动，让系统把这次唤醒与其他后台活动合并（timer coalescing / App Nap）。
        // 余额展示对几秒延迟无感知，而精确唤醒会阻止系统合并。
        t.tolerance = max(1, controller.intervalSeconds * 0.1)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func wireState() {
        // 一次 tick 会顺序写多个 `@Published`（余额 / configMissing / 日用量 / 日用量错误），
        // 逐个直接刷新等于同一次 tick 重建 4 次状态栏。这里把同一轮 run loop 内的变更合并成一次渲染。
        let bridge: () -> Void = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.scheduleRefresh() }
        }
        state.$configMissing.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$balances.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$daily.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$lastDailyError.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$caffeinateSession.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        // 用户显式切换菜单栏 provider 要即时生效，不走合并。
        state.$selectedProvider.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshAll() }
        }.store(in: &cancellables)
    }

    /// 把同一 run loop 轮次内的多次状态变更合并成一次渲染。
    @MainActor
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.refreshScheduled = false
                self.refreshAll()
            }
        }
    }

    private func currentInputs() -> StatusBarPresenter.Inputs {
        StatusBarPresenter.Inputs(
            configMissing: state.configMissing,
            selectedProvider: state.selectedProvider,
            balances: state.balances,
            daily: state.daily,
            lastDailyError: state.lastDailyError,
            caffeinateSession: state.caffeinateSession,
            autoEnabled: state.autoEnabled,
            autoFailure: state.autoFailure
        )
    }

    // MARK: - Render forwarding

    @MainActor
    private func refreshAll() {
        let inputs = currentInputs()
        let now = Date()
        // 值没变就不碰 `NSStatusItem`：赋同一个 title / chrome / image 仍会让 AppKit 走一遍
        // 布局与 WindowServer 更新，而余额在大多数 tick 里是恒定值。
        let title = StatusBarPresenter.renderTitle(inputs, now: now)
        if lastTitle != title {
            statusItem.button?.attributedTitle = title
            lastTitle = title
        }
        let chrome = StatusBarPresenter.renderChrome(inputs)
        if lastChrome != chrome {
            applyChrome(chrome)
            lastChrome = chrome
        }
        refreshLogo()
        scheduleBoundaryRefresh(now: now)
    }

    /// 在下一个峰谷切换点精确重绘一次标题。刷新周期最长 120s，
    /// 靠 tick 会滞后最多 2 分钟，而 09:00 / 18:00 恰好是「该不该现在跑批」的判断时刻。
    /// 只重绘、不抓取：真正需要网络的那次仍由常规 tick 负责。
    @MainActor
    private func scheduleBoundaryRefresh(now: Date) {
        guard state.selectedProvider == .deepseek, !state.configMissing,
              let next = DeepSeekPricing.nextTransition(after: now)
        else {
            cancelBoundaryRefresh()
            return
        }
        // 同一个切换点只排一次：每次刷新都重建 Timer 只是在扰动 run loop。
        if boundaryScheduledAt == next.date { return }
        cancelBoundaryRefresh()
        let timer = Timer.scheduledTimer(
            withTimeInterval: max(next.date.timeIntervalSince(now), 0.5),
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            // Timer 在主 run loop 上 fire，直接假定主线程隔离（与 `wireState` 的桥接同款）。
            MainActor.assumeIsolated {
                self.boundaryTimer = nil
                self.boundaryScheduledAt = nil
                self.refreshAll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
        boundaryScheduledAt = next.date
    }

    @MainActor
    private func cancelBoundaryRefresh() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        boundaryScheduledAt = nil
    }

    /// 把选中 provider 的 logo 写到 status button。`LogoCatalog` 内部已打 template 标记；
    /// 未知 provider 返回 nil，此时只留文字。
    /// caffeinate 激活时（template 在带背景色的 button 上渲染会失效）用一张预填白色的副本，
    /// 保证 logo 始终与胶囊文字同色。结果缓存到本地字段，避免每次刷新触发 I/O。
    @MainActor
    private func refreshLogo() {
        let pid = state.selectedProvider
        let active = state.caffeinateSession != nil
        let cacheKey = "\(pid.rawValue)#\(active ? "active" : "idle")"
        // 同一 key 对应的 image 永远相同，重复赋值只会让 button 重新布局。
        guard lastLogoKey != cacheKey else { return }
        let image: NSImage?
        if let cached = logoCache[cacheKey] {
            image = cached
        } else if let base = LogoCatalog.image(for: pid) {
            image = active ? Self.whiteFilled(template: base) : base
            logoCache[cacheKey] = image
        } else {
            image = nil
        }
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeft
        lastLogoKey = cacheKey
    }

    /// 把 template image 重新绘制成「alpha mask + 纯白」版本，得到非 template 的白色 image。
    /// 用于 caffeinate 激活期：`button.contentTintColor` 在带 backgroundColor 的状态下不可靠，
    /// 直接预乘白色更稳。
    private static func whiteFilled(template: NSImage) -> NSImage {
        let size = template.size
        let out = NSImage(size: size)
        out.lockFocus()
        defer { out.unlockFocus() }
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        template.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: size),
            operation: .destinationIn,
            fraction: 1.0
        )
        out.setValue(false, forKey: "template")
        return out
    }

    @MainActor
    private func applyChrome(_ spec: StatusBarPresenter.ChromeSpec) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        let h = max(button.bounds.height, 1)
        button.layer?.backgroundColor = spec.background.cgColor
        button.layer?.cornerRadius = spec == .clear
            ? 0
            : StatusBarChromeMetrics.cornerRadius(buttonHeight: h)
        button.contentTintColor = spec.contentTint
        // 去掉状态栏上的补间动画（闪现）。补间会受系统半透明材质干扰。
        button.layer?.removeAnimation(forKey: "caffeinateChrome.bg")
        button.layer?.removeAnimation(forKey: "caffeinateChrome.radius")
    }

    @MainActor
    private func refreshCaffeinateHeaderInPlace() {
        guard let item = caffeinateHeaderItem,
              let session = state.caffeinateSession else { return }
        let remaining = session.remainingSeconds(now: Date())
        item.title = "☕️ 阻止休眠 · 还剩 \(CountdownFormatter.format(remaining: remaining))"
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        caffeinateHeaderItem = nil
        let specs = StatusBarPresenter.renderMenu(currentInputs(), now: Date())
        for spec in specs {
            if let item = installItem(spec, into: menu), spec.tickable {
                caffeinateHeaderItem = item
            }
        }
        // 倒计时只在「菜单打开」期间需要走动：1Hz ticker 随菜单生命周期启停。
        if StatusBarPresenter.hasLiveCountdown(specs) {
            countdownTicker.start(interval: 1.0) { [weak self] in
                self?.refreshCaffeinateHeaderInPlace()
            }
        } else {
            countdownTicker.stop()
        }
    }

    public func menuDidClose(_ menu: NSMenu) {
        countdownTicker.stop()
        caffeinateHeaderItem = nil
    }

    // MARK: - MenuItem installation

    @MainActor
    private func installItem(_ spec: StatusBarPresenter.MenuItemSpec, into menu: NSMenu) -> NSMenuItem? {
        if let usageBar = spec.usageBar {
            let item = NSMenuItem()
            item.view = UsageBarMenuItemView(
                leftText: usageBar.leftText,
                value: usageBar.value,
                percentText: usageBar.percentText,
                resetText: usageBar.resetText,
                isOK: usageBar.isOK
            )
            item.isEnabled = false
            menu.addItem(item)
            return item
        }
        if spec.submenu == nil, spec.action == nil, spec.title.isEmpty {
            menu.addItem(NSMenuItem.separator())
            return nil
        }
        let item = NSMenuItem(
            title: spec.title,
            action: actionSelector(for: spec.action),
            keyEquivalent: spec.key
        )
        item.target = self
        item.isEnabled = spec.enabled
        if let bucket = spec.representedBucket {
            item.representedObject = bucket
        } else if let provider = spec.representedProvider {
            item.representedObject = provider
        }
        if let sub = spec.submenu {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in sub {
                _ = installItem(child, into: submenu)
            }
            item.submenu = submenu
        }
        menu.addItem(item)
        return item
    }

    private func actionSelector(for action: StatusBarPresenter.MenuItemSpec.MenuAction?) -> Selector? {
        switch action {
        case .forceRefresh: return #selector(forceRefresh)
        case .quit: return #selector(quit)
        case .showSettings: return #selector(showSettings)
        case .cleanupSessions: return #selector(cleanupSessions)
        case .selectProvider: return #selector(selectProvider(_:))
        case .selectAuto: return #selector(selectAuto)
        case .caffeinateBucket: return #selector(caffeinateBucket(_:))
        case .caffeinateCancel: return #selector(caffeinateCancel)
        case nil: return nil
        }
    }

    // MARK: - Actions

    @objc private func forceRefresh() {
        Task { @MainActor in await controller.tick() }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func showSettings() {
        onShowSettings()
    }

    @objc private func cleanupSessions() {
        MainActor.assumeIsolated { startCleanup() }
    }

    /// 扫描 → 预览 → 确认后执行 → 报告 → 完整刷新一次（与「立即刷新」同路径）。
    /// 全程由 `cleanupInFlight` 挡住重入：扫描 / 弹窗 / 删除期间再点菜单项不产生第二个弹窗。
    @MainActor
    private func startCleanup() {
        guard !cleanupInFlight else { return }
        cleanupInFlight = true
        Task { @MainActor in
            await runCleanup()
            cleanupInFlight = false
        }
    }

    @MainActor
    private func runCleanup() async {
        let now = Date()
        let policy = currentPolicy()
        let plan: CleanupPlan
        do {
            plan = try await cleanup.scan(now: now, policy: policy)
        } catch let error as SessionCleanupError {
            switch error {
            case .sessionsRootMissing(let path):
                CleanupAlertPresenter.present(CleanupPresenter.missingRootContent(path: path))
            case .scanFailed:
                CleanupAlertPresenter.present(CleanupPresenter.messageContent(error.message))
            }
            return
        } catch {
            CleanupAlertPresenter.present(CleanupPresenter.messageContent(error.localizedDescription))
            return
        }

        let desktopRunning = Self.isDesktopRunning()
        let preview = CleanupPresenter.previewContent(
            plan: plan,
            policy: policy,
            now: now,
            desktopRunning: desktopRunning
        )
        guard CleanupAlertPresenter.present(preview) else { return }

        // 预览到执行之间 desktop 可能被启动：执行前再判一次，工作区级写入一旦有竞争就跳过。
        let outcome = await cleanup.apply(
            plan: plan,
            now: Date(),
            allowWorkspaceRemoval: !Self.isDesktopRunning()
        )
        CleanupAlertPresenter.present(CleanupPresenter.completionContent(outcome))
        // 删掉的 session 会影响用量（也影响正在跑的会话），因此按「立即刷新」同路径完整刷新一次。
        await controller.tick()
    }

    /// Kimi Code 桌面端是否在运行。按 bundle id **精确匹配**（不按名字包含匹配，
    /// 也不读 `server/instances/*`）—— 只用来在预览里加一行警告。
    private static func isDesktopRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.kimi.code.desktop" }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pid = ProviderID(rawValue: raw),
              ProviderID.supported.contains(pid)
        else { return }
        MainActor.assumeIsolated {
            onSelectProvider(pid)
        }
    }

    /// 「菜单栏显示 ▸」里的「自动」：跟随 config.toml 的 `default_model`（ADR-0013）。
    @objc private func selectAuto() {
        MainActor.assumeIsolated {
            onSelectAuto()
        }
    }

    @objc private func caffeinateBucket(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let bucket = CaffeinateBucket(rawValue: raw) else { return }
        MainActor.assumeIsolated {
            _ = sleepGuard.start(bucket: bucket)
        }
    }

    @objc private func caffeinateCancel() {
        MainActor.assumeIsolated {
            sleepGuard.cancel()
        }
    }
}
