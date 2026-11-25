import Combine
import Foundation

/// 菜单栏所需的状态：每个 provider 自己的余额状态（互不影响）+ 日用量 + 阻止休眠会话 +
/// 当前菜单栏展示的 provider。
///
/// 所有修改必须经过 setter，且 setter 都在主线程被调用（`RefreshController` 走 `MainActor.run`）。
public final class AppState: ObservableObject, @unchecked Sendable {
    /// config.toml 不可读 / 非法（全局降级 → 菜单栏 `?kimi`）。
    @Published public private(set) var configMissing: Bool = false
    /// provider → 该 provider 的余额状态。`ProviderID.supported` 全部有键。
    @Published public private(set) var balances: [ProviderID: ProviderBalanceState] = [:]
    @Published public private(set) var daily: DailyUsageSnapshot?
    @Published public private(set) var lastDailyError: String?
    @Published public private(set) var caffeinateSession: CaffeinateSession?
    /// 菜单栏展示哪个 provider 的值。显式选择，或「自动」模式下由 `default_model` 解析出的值；
    /// 自动解析失败时为 `.unknown`（只存在于内存，永不落盘）。**失败时不自动切换**。
    @Published public private(set) var selectedProvider: ProviderID = .deepseek
    /// 菜单栏是否跟随 config.toml 的 `default_model`（ADR-0013）。
    @Published public private(set) var autoEnabled: Bool = false
    /// 自动解析失败的原因；解析成功或关闭自动时为 nil。
    @Published public private(set) var autoFailure: MenuBarAutoFailure?

    /// 最近一次**可读** config 的 `default_model`（configMissing 的 tick 不覆盖它）；
    /// 用户点「自动」时据此立即解析，不必等下一个 tick。
    private var lastDefaultModel: String?
    private var sawDefaultModel = false

    public init() {}

    /// 一次写入完整 Balance Refresh Outcome；逐 provider 的合并细节不泄漏给调用方。
    public func applyBalance(_ outcome: BalanceRefreshOutcome) {
        self.balances = outcome.balances
        self.configMissing = outcome.configMissing
        // config 读不到时「default_model 是什么」没有新事实：保留上一次的解析结果与展示值，
        // 菜单栏由 `configMissing` 分支渲染 `?kimi`。
        guard !outcome.configMissing else { return }
        lastDefaultModel = outcome.defaultModel
        sawDefaultModel = true
        if autoEnabled { applyAutoResolution(defaultModel: outcome.defaultModel) }
    }

    public func setDaily(_ snap: DailyUsageSnapshot?) { self.daily = snap }
    public func setDailyError(_ msg: String?) { self.lastDailyError = msg }
    public func setCaffeinateSession(_ s: CaffeinateSession?) { self.caffeinateSession = s }
    public func setSelectedProvider(_ p: ProviderID) { self.selectedProvider = p }

    /// 开关「自动」。开启时用最近一次可读 config 的 `default_model` 立即解析一次；
    /// `defaultModel` 非 nil 时顺带把它作为种子（启动路径用）。从未读到过 config 时保持当前展示值，
    /// 等下一次 tick 落地（此刻菜单栏显示 `?kimi`）。
    public func setAutoEnabled(_ enabled: Bool, defaultModel: String? = nil) {
        autoEnabled = enabled
        guard enabled else {
            autoFailure = nil
            return
        }
        if let defaultModel {
            lastDefaultModel = defaultModel
            sawDefaultModel = true
        }
        guard sawDefaultModel else { return }
        applyAutoResolution(defaultModel: lastDefaultModel)
    }

    /// 自动模式的唯一解析入口：成功 → 换成该 provider；失败 → `.unknown` + 失败原因。
    /// 解析结果每 tick 重算，成功后立即清空失败原因。
    private func applyAutoResolution(defaultModel: String?) {
        switch MenuBarSelection.resolveAuto(fromDefaultModel: defaultModel) {
        case .provider(let pid):
            if autoFailure != nil { autoFailure = nil }
            if selectedProvider != pid { selectedProvider = pid }
        case .failure(let failure):
            if autoFailure != failure { autoFailure = failure }
            if selectedProvider != .unknown { selectedProvider = .unknown }
        }
    }

    /// 单个 provider 的状态；尚未采集过时返回空态（result / failure 皆 nil）。
    public func balance(for provider: ProviderID) -> ProviderBalanceState {
        balances[provider] ?? ProviderBalanceState(provider: provider)
    }
}

/// 定时刷新编排：每次 tick 从两个 Source 抓快照，根据采集事实落 `AppState`。
/// 抓取细节（config / creds / http / reader / aggregate）由 Source 实现封进。
public final class RefreshController: @unchecked Sendable {
    public let balanceSource: BalanceSource
    public let dailySource: DailyUsageSource
    public let state: AppState
    public var intervalSeconds: TimeInterval

    public init(
        balanceSource: BalanceSource,
        dailySource: DailyUsageSource,
        state: AppState,
        intervalSeconds: TimeInterval = 60
    ) {
        self.balanceSource = balanceSource
        self.dailySource = dailySource
        self.state = state
        self.intervalSeconds = intervalSeconds
    }

    public func tick() async {
        let now = Date()
        let balanceCapture = await balanceSource.capture(now: now)
        let dailyCapture = await dailySource.capture(now: now)
        await MainActor.run {
            self.state.applyBalance(self.balanceOutcome(for: balanceCapture))
            self.applyDaily(snap: dailyCapture.0, err: dailyCapture.1)
        }
    }

    public func refreshBalance() async {
        let capture = await balanceSource.capture(now: Date())
        await MainActor.run {
            self.state.applyBalance(self.balanceOutcome(for: capture))
        }
    }

    public func refreshDaily() async {
        let (snap, err) = await dailySource.capture(now: Date())
        await MainActor.run {
            self.applyDaily(snap: snap, err: err)
        }
    }

    /// 用户从菜单显式选择菜单栏 provider：同时退出「自动」（ADR-0013）。
    @MainActor
    public func selectProvider(_ provider: ProviderID) {
        state.setAutoEnabled(false)
        state.setSelectedProvider(provider)
    }

    /// 用户从菜单选择「自动」：立即按最近一次可读的 `default_model` 解析。
    @MainActor
    public func enableAuto() {
        state.setAutoEnabled(true)
    }

    /// 逐 provider 推进状态：一个 provider 的失败绝不触碰另一个，
    /// 也绝不改变 `selectedProvider`（网络抖动不能覆盖用户的显式选择）。
    private func balanceOutcome(for capture: BalanceCapture) -> BalanceRefreshOutcome {
        var merged: [ProviderID: ProviderBalanceState] = [:]
        for pid in ProviderID.supported {
            merged[pid] = ProviderBalanceState.advanced(
                provider: pid,
                previous: state.balances[pid],
                incoming: capture.capture(for: pid),
                now: capture.capturedAt
            )
        }
        return BalanceRefreshOutcome(
            balances: merged,
            configMissing: capture.configMissing,
            defaultModel: capture.defaultModel
        )
    }

    private func applyDaily(snap: DailyUsageSnapshot?, err: SnapshotError?) {
        self.state.setDaily(snap)
        if let err {
            self.state.setDailyError(err.menuText)
        } else {
            self.state.setDailyError(nil)
        }
    }
}
