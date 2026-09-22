import Foundation

/// 一次 Snapshot 抓取的非致命信号。`nil`（在元组 / Optional 位置）表示成功且无异常。
public enum SnapshotError: Error, Sendable, Equatable {
    /// 会话日志扫描 / 解析失败；reason 已是 human-readable 中文。
    case scanError(String)

    /// 菜单里的中文说明。
    public var menuText: String {
        switch self {
        case .scanError(let reason): return reason
        }
    }
}

/// 一次余额采集的完整事实。
///
/// `BalanceSource` 只负责采集，不决定状态迁移：每个 provider 各带一份结果，
/// `RefreshController` 再逐 provider 推进 `AppState`。
public struct BalanceCapture: Sendable {
    /// `ProviderID.supported` 全部有键；缺键按 `.providerMissing` 处理。
    public let perProvider: [ProviderID: ProviderCapture]
    /// config.toml 不可读 / 非法 → 全局降级，菜单栏显示 `?kimi`。
    public let configMissing: Bool
    /// 本次的 `default_model`（仅诊断 / 首启推导用）。
    public let defaultModel: String?
    public let capturedAt: Date

    public init(
        perProvider: [ProviderID: ProviderCapture],
        configMissing: Bool,
        defaultModel: String?,
        capturedAt: Date
    ) {
        self.perProvider = perProvider
        self.configMissing = configMissing
        self.defaultModel = defaultModel
        self.capturedAt = capturedAt
    }

    public func capture(for provider: ProviderID) -> ProviderCapture {
        perProvider[provider] ?? ProviderCapture(failure: .providerMissing)
    }

    /// 一次采集里全部 provider 都是同一个失败原因（config.toml 级失败）。
    public static func allFailed(_ failure: ProviderFailure, now: Date, defaultModel: String? = nil) -> BalanceCapture {
        var out: [ProviderID: ProviderCapture] = [:]
        for pid in ProviderID.supported { out[pid] = ProviderCapture(failure: failure) }
        return BalanceCapture(perProvider: out, configMissing: true, defaultModel: defaultModel, capturedAt: now)
    }
}

/// `BalanceSource`：对 `RefreshController` 暴露的一次余额采集 seam。
///
/// 把 config 读取 + 凭据解析 + provider 路由 + HTTP + 错误文本化都封在实现里。
public protocol BalanceSource: Sendable {
    func capture(now: Date) async -> BalanceCapture
}

/// 一次余额刷新后提交给 `AppState` 的完整显示状态，由 `RefreshController` 计算。
public struct BalanceRefreshOutcome: Sendable {
    public let balances: [ProviderID: ProviderBalanceState]
    public let configMissing: Bool
    public let defaultModel: String?

    public init(balances: [ProviderID: ProviderBalanceState], configMissing: Bool, defaultModel: String?) {
        self.balances = balances
        self.configMissing = configMissing
        self.defaultModel = defaultModel
    }
}

/// `DailyUsageSource`：对 `RefreshController` 暴露的「一次日用量聚合」最小 seam。
public protocol DailyUsageSource: Sendable {
    func capture(now: Date) async -> (DailyUsageSnapshot?, SnapshotError?)
}
