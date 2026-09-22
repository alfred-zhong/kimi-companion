import Foundation

// MARK: - Provider

/// kimi-code 经 `~/.kimi-code/config.toml` 的 `[providers.*]` 配置的第三方模型服务商。
///
/// 只支持两个：`DeepSeek`（账户余额，CNY）与 `OpenCode Go`（三窗口配额，百分比）。
/// first-party `managed:kimi-code` 有意不支持：它的 `api_key` 恒为空、走 OAuth，
/// 且本地 `oauth/usage` 端点只覆盖该账号（产品上已排除）。
public enum ProviderID: String, CaseIterable, Sendable {
    case deepseek
    case opencodeGo = "opencode-go"
    /// 未匹配任何受支持 provider；只用作 `default_model` 前缀推导的失败哨兵与 logo 缺省分支。
    case unknown

    /// config.toml 里的段名，**逐字**使用（`"OpenCode Go"` 含空格）。
    public var configSectionName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .opencodeGo: return "OpenCode Go"
        // `.unknown` 不是配置段：查表路径一律遍历 `ProviderID.supported`，走不到这里。
        case .unknown: return rawValue
        }
    }

    /// 面向用户的展示名（菜单 section header）。与段名同值。
    public var displayName: String { configSectionName }

    /// 下拉菜单里始终展示的 provider，顺序固定：DeepSeek → OpenCode Go。
    public static let supported: [ProviderID] = [.deepseek, .opencodeGo]

    /// 由 `usage.record.model` 的 `<Provider>/<model>` 前缀解析 provider。
    /// 段名逐字匹配（含空格），另接受 rawValue 小写形式；其余一律 `.unknown`。
    public static func fromModelPrefix(_ prefix: String) -> ProviderID {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .unknown }
        let lowered = trimmed.lowercased()
        for pid in supported where pid.configSectionName == trimmed || pid.rawValue == lowered {
            return pid
        }
        return .unknown
    }

    /// 由 `default_model = "OpenCode Go/deepseek-v4.1-flash"` 的前缀解析 provider。
    public static func fromDefaultModel(_ model: String?) -> ProviderID {
        guard let model, let slash = model.firstIndex(of: "/") else { return .unknown }
        return fromModelPrefix(String(model[..<slash]))
    }
}

/// 首次运行时菜单栏 provider 的推导规则。
public enum MenuBarSelection {
    /// 由 config.toml `default_model` 前缀推导；推导不出（缺配置 / 未匹配）回退 `DeepSeek`。
    public static func deriveDefault(fromDefaultModel model: String?) -> ProviderID {
        let pid = ProviderID.fromDefaultModel(model)
        return pid == .unknown ? .deepseek : pid
    }
}

// MARK: - Balance

public enum BalanceCurrency: String, Sendable {
    case cny = "CNY"
    /// DeepSeek 账户币种理论上可配；线上实测为 CNY。
    case usd = "USD"
    case percent = "PERCENT"
}

/// 余额 / 配额查询结果。
public struct BalanceResult: Equatable, Sendable {
    public let provider: ProviderID
    /// CNY 时是金额；percent 时是窗口已用百分比（与 `usedPercent` 同值，保留兼容）。
    public let balance: Double
    public let currency: BalanceCurrency
    /// 已用百分比（0-100，服务端原样，展示层不换算）。
    public let usedPercent: Double?
    public let resetRemaining: TimeInterval?
    /// 额度窗口：OpenCode Go 三窗口（5h / 7d / 月度）；DeepSeek 为 nil。
    public let quotaWindows: [QuotaWindow]?
    /// DeepSeek `is_available`；nil = 该 provider 不返回此字段。
    public let isAvailable: Bool?

    public init(
        provider: ProviderID,
        balance: Double,
        currency: BalanceCurrency,
        usedPercent: Double? = nil,
        resetRemaining: TimeInterval? = nil,
        quotaWindows: [QuotaWindow]? = nil,
        isAvailable: Bool? = nil
    ) {
        self.provider = provider
        self.balance = balance
        self.currency = currency
        self.usedPercent = usedPercent
        self.resetRemaining = resetRemaining
        self.quotaWindows = quotaWindows
        self.isAvailable = isAvailable
    }
}

// MARK: - Quota Window (OpenCode Go)

/// 一个额度窗口：OpenCode Go 的 5h 滚动 / 7d / 月度（订阅周年重置）。
public struct QuotaWindow: Equatable, Sendable {
    /// 窗口标识：`"5h"` | `"7d"` | `"monthly"`。
    public let id: String
    /// 展示标签：`"5h"` | `"7d"` | `"月度"`。
    public let label: String
    public let usedPercent: Double
    /// 服务端原样状态串（实测只有 `"ok"`）。`!= "ok"` 一律按已限流处理。
    public let status: String
    public let resetsAt: Date

    public init(id: String, label: String, usedPercent: Double, status: String, resetsAt: Date) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.status = status
        self.resetsAt = resetsAt
    }

    public var isOK: Bool { status == "ok" }
    public var isRateLimited: Bool { !isOK }
}

// MARK: - Provider Failure / Balance State

/// 单个 provider 的一次失败原因。
///
/// 类型化而非裸字符串：菜单栏短标签（`⚠︎配置` / `⚠︎凭据`）与菜单长文案都由它纯函数派生，
/// 因此 `StatusBarPresenter` 不需要嗅探文案内容。
public enum ProviderFailure: Equatable, Sendable {
    /// config.toml 不可读 / 非法（全局失败，两个 provider 各带一份）。
    case configUnreadable(String)
    /// config.toml 可读但不存在该 `[providers.<name>]` 段。
    case providerMissing
    /// 段的 `api_key` 为空 / 全空白。
    case credentialEmpty
    /// 段用 `api_key_env` 指定凭据；本 app 只读内联 key，不解析环境变量。
    case credentialEnv
    /// 远端 / 网络 / 解析失败；reason 已是中文。
    case fetch(String)

    /// 菜单栏短标签，跟在 `⚠︎` 之后。
    public var statusBarTag: String {
        switch self {
        case .configUnreadable, .providerMissing: return "配置"
        case .credentialEmpty, .credentialEnv: return "凭据"
        case .fetch: return ""
        }
    }

    /// 菜单里的中文说明（`provider` 用于拼出段名，保证用户能照抄去改配置）。
    public func menuText(provider: ProviderID) -> String {
        switch self {
        case .configUnreadable(let reason):
            return reason
        case .providerMissing:
            return "config 中未找到 provider \"\(provider.configSectionName)\""
        case .credentialEmpty:
            return "provider \"\(provider.configSectionName)\" 的 api_key 为空"
        case .credentialEnv:
            return "provider \"\(provider.configSectionName)\" 使用 api_key_env，本 app 只读内联 api_key"
        case .fetch(let reason):
            return reason
        }
    }
}

/// 一次余额采集里单个 provider 的原始事实：`result` 与 `failure` 至多一个非 nil。
public struct ProviderCapture: Sendable, Equatable {
    public let result: BalanceResult?
    public let failure: ProviderFailure?

    public init(result: BalanceResult? = nil, failure: ProviderFailure? = nil) {
        self.result = result
        self.failure = failure
    }
}

/// 单个 provider 的展示状态。两个 provider 各自独立演化 —— 一个失败绝不触碰另一个，
/// 菜单栏也绝不因此自动切到另一个（用户的显式选择高于网络抖动）。
public struct ProviderBalanceState: Equatable, Sendable {
    public let provider: ProviderID
    /// 最近一次成功的余额 / 配额；从未成功时为 nil。
    public let result: BalanceResult?
    /// 最近一次失败原因；本轮回合成功时为 nil。
    public let failure: ProviderFailure?
    /// `result` 是否为「抓取失败后保留的上一次值」。
    public let isStale: Bool
    public let capturedAt: Date?

    public init(
        provider: ProviderID,
        result: BalanceResult? = nil,
        failure: ProviderFailure? = nil,
        isStale: Bool = false,
        capturedAt: Date? = nil
    ) {
        self.provider = provider
        self.result = result
        self.failure = failure
        self.isStale = isStale
        self.capturedAt = capturedAt
    }

    /// 用本次采集结果推进一个 provider 的状态：
    /// - 成功 → 覆盖为新值并清空 failure；
    /// - 失败且有旧值 → 保留旧值、标 `isStale`，同时记下 failure（钱是真数据，但必须能看到为什么没更新）；
    /// - 失败且无旧值 → 只有 failure。
    public static func advanced(
        provider: ProviderID,
        previous: ProviderBalanceState?,
        incoming: ProviderCapture,
        now: Date
    ) -> ProviderBalanceState {
        if let result = incoming.result {
            return ProviderBalanceState(provider: provider, result: result, failure: nil, isStale: false, capturedAt: now)
        }
        if let kept = previous?.result {
            return ProviderBalanceState(
                provider: provider,
                result: kept,
                failure: incoming.failure,
                isStale: true,
                capturedAt: previous?.capturedAt
            )
        }
        return ProviderBalanceState(provider: provider, result: nil, failure: incoming.failure, isStale: false, capturedAt: nil)
    }
}

// MARK: - Token Usage

/// 一段时间窗口的 token 聚合。
public struct TokenStats: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var totalInputTokens: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }

    public var realConsumptionTokens: Int {
        totalInputTokens + outputTokens
    }

    /// 缓存命中率：`inputCacheRead / (inputOther + inputCacheCreation + inputCacheRead)`。
    public var cacheHitRate: Double {
        guard totalInputTokens > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(totalInputTokens)
    }

    public var isEmpty: Bool {
        inputTokens == 0 && outputTokens == 0 && cacheCreationTokens == 0 && cacheReadTokens == 0
    }

    public static func += (lhs: inout TokenStats, rhs: TokenStats) {
        lhs.inputTokens += rhs.inputTokens
        lhs.outputTokens += rhs.outputTokens
        lhs.cacheCreationTokens += rhs.cacheCreationTokens
        lhs.cacheReadTokens += rhs.cacheReadTokens
    }
}

/// 单小时滑动桶。
public struct HourBucket: Equatable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public var stats: TokenStats

    public init(startMs: Int64, endMs: Int64, stats: TokenStats = TokenStats()) {
        self.startMs = startMs
        self.endMs = endMs
        self.stats = stats
    }
}

/// 日用量快照：全部会话合并成**一份**，不按 provider / model 区分（ADR-0006）。
public struct DailyUsageSnapshot: Sendable, Equatable {
    /// 当日（本地零点至 `capturedAt`）全部会话的 token 合计。
    public let today: TokenStats
    /// 长度 12，index 0 最旧、末位最新；区间左开右闭 `(startMs, endMs]`；末桶是完整一小时。
    public let hourly: [HourBucket]
    public let capturedAt: Date

    public init(today: TokenStats, hourly: [HourBucket], capturedAt: Date) {
        self.today = today
        self.hourly = hourly
        self.capturedAt = capturedAt
    }

    /// 后 5 个小时桶的并集，等价于 `[now-5h, now]`。
    public var last5h: TokenStats {
        var sum = TokenStats()
        for bucket in hourly.suffix(5) {
            sum += bucket.stats
        }
        return sum
    }
}

// MARK: - Caffeinate (阻止系统休眠)

/// 阻止系统休眠的预设档位。
public enum CaffeinateBucket: Int, CaseIterable, Sendable {
    case thirtyMinutes = 30
    case sixtyMinutes = 60
    case oneTwentyMinutes = 120

    public var minutes: Int { rawValue }
    public var label: String { "\(rawValue) 分钟" }

    public static let `default`: CaffeinateBucket = .sixtyMinutes
}

/// 一次 IOPMAssertion 守护会话。
public struct CaffeinateSession: Equatable, Sendable {
    public let bucket: CaffeinateBucket
    public let startedAt: Date
    public let endAt: Date

    public init(bucket: CaffeinateBucket, startedAt: Date, endAt: Date) {
        self.bucket = bucket
        self.startedAt = startedAt
        self.endAt = endAt
    }

    /// 现在到 endAt 的剩余秒数；<= 0 表示已到期。
    public func remainingSeconds(now: Date) -> TimeInterval {
        endAt.timeIntervalSince(now)
    }

    public func isActive(now: Date) -> Bool {
        endAt > now
    }
}

// MARK: - RefreshInterval (刷新间隔)

/// 偏好面板的刷新间隔档位：固定三档，默认 60s。
public enum RefreshInterval: Int, CaseIterable, Sendable {
    case seconds30 = 30
    case seconds60 = 60
    case seconds120 = 120

    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public static let `default`: RefreshInterval = .seconds60

    /// 校验 UserDefaults 里存下的秒数：只有恰好命中三档才采用，否则落回默认档。
    /// `needsRewrite = true` 表示存量脏值（例如手改过 plist），调用方应写回自愈。
    /// `rawSeconds <= 0` 视为「从未设置」，不回写。
    public static func persisted(rawSeconds: Double) -> (interval: RefreshInterval, needsRewrite: Bool) {
        guard rawSeconds > 0 else { return (.default, false) }
        guard let interval = RefreshInterval(rawValue: Int(rawSeconds)) else { return (.default, true) }
        return (interval, false)
    }
}
