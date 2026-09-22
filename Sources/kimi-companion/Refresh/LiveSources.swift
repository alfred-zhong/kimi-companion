import Foundation

/// 生产 `BalanceSource`：持有 config 读取 + HTTP 客户端。
///
/// 内部对**每个 provider 独立跑一遍**：config 段查找 → 凭据检查 → fetch。
/// 一个 provider 的失败绝不短路另一个，产出恒为「两个 provider 各有键」的完整事实。
public struct LiveBalanceSource: BalanceSource {
    public let config: KimiConfigSource
    public let http: HTTPClient

    public init(config: KimiConfigSource = KimiConfigSource(), http: HTTPClient = URLSessionHTTPClient()) {
        self.config = config
        self.http = http
    }

    public func capture(now: Date) async -> BalanceCapture {
        switch config.load() {
        case .unreadable(let reason):
            return .allFailed(.configUnreadable(reason), now: now)
        case .malformed:
            return .allFailed(.configUnreadable("config.toml 解析失败"), now: now)
        case .loaded(let cfg):
            let creds = TomlCredentialSource(config: cfg)
            var out: [ProviderID: ProviderCapture] = [:]
            for pid in ProviderID.supported {
                out[pid] = await captureOne(pid, cfg: cfg, creds: creds)
            }
            return BalanceCapture(
                perProvider: out,
                configMissing: false,
                defaultModel: cfg.defaultModel,
                capturedAt: now
            )
        }
    }

    private func captureOne(_ pid: ProviderID, cfg: KimiConfig, creds: any CredentialSource) async -> ProviderCapture {
        guard let entry = cfg.provider(pid.configSectionName),
              let provider = BalanceRegistry.provider(for: pid, config: cfg)
        else {
            return ProviderCapture(failure: .providerMissing)
        }
        // 段用 api_key_env 且没有内联 key → 凭据不可解析。刻意不调用 getenv（产品取舍）。
        if entry.apiKey == nil, entry.usesAPIKeyEnv {
            return ProviderCapture(failure: .credentialEnv)
        }
        guard provider.hasCredential(creds: creds) else {
            return ProviderCapture(failure: .credentialEmpty)
        }
        do {
            return ProviderCapture(result: try await provider.fetch(creds: creds, http: http))
        } catch {
            return ProviderCapture(failure: .fetch(Self.humanReadable(error)))
        }
    }

    /// 把 `HTTPError` 映射到中文状态文案，缺省回退 `error.localizedDescription`。
    public static func humanReadable(_ error: Error) -> String {
        if let http = error as? HTTPError {
            switch http {
            case .timeout: return "请求超时 (10 秒)"
            case .unauthorized(let status): return "鉴权失败 (\(status))"
            case .rateLimited: return "请求过快 (429)"
            case .server(let status): return "服务异常 (\(status))"
            case .invalidResponse: return "响应解析失败"
            case .missingCredential: return "凭据缺失"
            }
        }
        return error.localizedDescription
    }
}

/// 生产 `DailyUsageSource`：持有 `WireLogReader` + `HourlyAggregator`。
public struct LiveDailyUsageSource: DailyUsageSource {
    public let reader: WireLogReader
    public let aggregator: HourlyAggregator

    public init(reader: WireLogReader, aggregator: HourlyAggregator = HourlyAggregator()) {
        self.reader = reader
        self.aggregator = aggregator
    }

    public func capture(now: Date) async -> (DailyUsageSnapshot?, SnapshotError?) {
        let events = reader.events(now: now)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let todayStartMs = reader.todayStartMs(now: now)
        let snapshot = aggregator.aggregate(events: events, nowMs: nowMs, todayStartMs: todayStartMs)
        return (snapshot, nil)
    }
}
