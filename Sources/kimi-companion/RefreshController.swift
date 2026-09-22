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
    /// 菜单栏展示哪个 provider 的值。用户显式选择，**失败时不自动切换**。
    @Published public private(set) var selectedProvider: ProviderID = .deepseek

    public init() {}

    /// 一次写入完整 Balance Refresh Outcome；逐 provider 的合并细节不泄漏给调用方。
    public func applyBalance(_ outcome: BalanceRefreshOutcome) {
        self.balances = outcome.balances
        self.configMissing = outcome.configMissing
    }

    public func setDaily(_ snap: DailyUsageSnapshot?) { self.daily = snap }
    public func setDailyError(_ msg: String?) { self.lastDailyError = msg }
    public func setCaffeinateSession(_ s: CaffeinateSession?) { self.caffeinateSession = s }
    public func setSelectedProvider(_ p: ProviderID) { self.selectedProvider = p }

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

    /// 用户从菜单显式选择菜单栏 provider。
    @MainActor
    public func selectProvider(_ provider: ProviderID) {
        state.setSelectedProvider(provider)
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
