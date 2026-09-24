import AppKit
import Combine
import Foundation
import QuartzCore

/// StatusBar controller：Timer / Combine 订阅 / 把 `StatusBarPresenter` 的输出写到 `NSStatusItem` + `NSMenu`。
/// 全部「AppState → 视觉」逻辑都在 `StatusBarPresenter`（纯函数），这里只做转发。
public final class StatusBarController: NSObject, NSMenuDelegate {
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
    private let cleanup: SessionCleanup
    /// 每次清理前现取一次策略（偏好面板随时可改，不在 init 时快照）。
    private let currentPolicy: () -> RetentionPolicy
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
        cleanup: SessionCleanup,
        currentPolicy: @escaping () -> RetentionPolicy,
        countdownTicker: CountdownTicker = TimerCountdownTicker()
    ) {
        self.controller = controller
        self.state = state
        self.sleepGuard = sleepGuard
        self.onShowSettings = onShowSettings
        self.onSelectProvider = onSelectProvider
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
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func wireState() {
        let bridge: () -> Void = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshAll() }
        }
        state.$configMissing.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$balances.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$daily.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$lastDailyError.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$caffeinateSession.receive(on: RunLoop.main).sink { _ in bridge() }.store(in: &cancellables)
        state.$selectedProvider.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.refreshAll()
                self.refreshLogo()
            }
        }.store(in: &cancellables)
    }

    private func currentInputs() -> StatusBarPresenter.Inputs {
        StatusBarPresenter.Inputs(
            configMissing: state.configMissing,
            selectedProvider: state.selectedProvider,
            balances: state.balances,
            daily: state.daily,
            lastDailyError: state.lastDailyError,
            caffeinateSession: state.caffeinateSession
        )
    }

    // MARK: - Render forwarding

    @MainActor
    private func refreshAll() {
        let inputs = currentInputs()
        statusItem.button?.attributedTitle = StatusBarPresenter.renderTitle(inputs)
        applyChrome(StatusBarPresenter.renderChrome(inputs))
        refreshLogo()
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

        let preview = CleanupPresenter.previewContent(
            plan: plan,
            policy: policy,
            now: now,
            desktopRunning: Self.isDesktopRunning()
        )
        guard CleanupAlertPresenter.present(preview) else { return }

        let outcome = await cleanup.apply(plan: plan, now: Date())
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
