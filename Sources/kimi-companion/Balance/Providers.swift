import Foundation

public protocol BalanceProvider: Sendable {
    var id: ProviderID { get }
    /// 校验该 provider 是否有可用的鉴权凭据。
    func hasCredential(creds: any CredentialSource) -> Bool
    /// 拉取余额 / 配额。
    func fetch(creds: any CredentialSource, http: HTTPClient) async throws -> BalanceResult
}

/// 规范化 config.toml 的 `base_url`：去首尾空白、去尾部 `/`，并强制 HTTPS。
/// 不合格（空 / 非 https / 无 host）→ 回退到 `fallback`。
///
/// 去尾斜杠不只是洁癖：OpenCode Go 的 `…/v1/usage/`（带尾斜杠）会返回 **401**，
/// 而 `…/v1/usage` 才是 200。
func normalizeBaseURL(_ raw: String?, fallback: String) -> String {
    var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    guard let url = URL(string: s), url.scheme == "https", let host = url.host, !host.isEmpty else {
        return fallback
    }
    return s
}

// MARK: - DeepSeek

/// DeepSeek（`api.deepseek.com`）账户余额 provider：
/// `GET <base_url>/user/balance`，`Authorization: Bearer <api_key>`。
///
/// 响应形状：
/// ```json
/// {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"65.92",
///   "granted_balance":"0.00","topped_up_balance":"65.92"}]}
/// ```
/// - `total_balance` 是**字符串**（`"65.92"`）而非数字，必须 `Double(String)`；
/// - `is_available` 是真 bool；false 时金额仍然是真数据，但展示层会追加 ` ⚠`；
/// - 401 的 body 是纯文本 `Authentication Fails (governor)`，由 `HTTPClient` 统一转成 `.unauthorized`。
public struct DeepSeekProvider: BalanceProvider {
    public let id: ProviderID = .deepseek
    /// config.toml 的 `base_url`；nil / 空 / 不合格 → 官方默认。
    public let baseURL: String?

    public init(baseURL: String? = nil) {
        self.baseURL = baseURL
    }

    public static let defaultBaseURL = "https://api.deepseek.com"

    /// `<base_url>/user/balance`。
    public static func balanceURL(baseURL: String?) -> URL {
        URL(string: normalizeBaseURL(baseURL, fallback: defaultBaseURL) + "/user/balance")!
    }

    public func hasCredential(creds: any CredentialSource) -> Bool {
        creds.resolve(id.configSectionName) != nil
    }

    public func fetch(creds: any CredentialSource, http: HTTPClient) async throws -> BalanceResult {
        guard let key = creds.resolve(id.configSectionName) else {
            throw HTTPError.missingCredential
        }
        let (data, _) = try await http.get(
            url: Self.balanceURL(baseURL: baseURL),
            headers: ["Authorization": "Bearer \(key)"],
            timeoutSeconds: 10
        )
        return try Self.decode(data)
    }

    /// 解码响应。`balance_infos` 缺失 / 为空 / `total_balance` 不可解析 → `invalidResponse`
    /// （宁可报错，也不展示一个凭空的 `¥0.00`）。
    public static func decode(_ data: Data) throws -> BalanceResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = json["balance_infos"] as? [[String: Any]],
              let first = infos.first,
              let total = doubleValue(first["total_balance"]),
              total.isFinite
        else {
            throw HTTPError.invalidResponse
        }
        let currency = (first["currency"] as? String) ?? "CNY"
        return BalanceResult(
            provider: .deepseek,
            balance: total,
            currency: currency.uppercased() == "CNY" ? .cny : .usd,
            isAvailable: json["is_available"] as? Bool
        )
    }

    /// `total_balance` 可能是字符串（线上形状）也可能是数字（防御性兼容）。
    private static func doubleValue(_ v: Any?) -> Double? {
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}

// MARK: - OpenCode Go

/// OpenCode Go（`opencode.ai/zen/go` 订阅网关）配额 provider：
/// `GET <base_url>/usage`，`Authorization: Bearer <api_key>`。
///
/// 响应形状：
/// ```json
/// {"usage":{"rolling":{"status":"ok","percent":16,"resetsAt":"2026-09-22T11:17:56.356Z"},
///           "weekly":{"status":"ok","percent":22,"resetsAt":"..."},
///           "monthly":{"status":"ok","percent":13,"resetsAt":"..."}}}
/// ```
/// 三条实测坑：
/// 1. **尾部 `/` 会 401**（`…/v1/usage` → 200，`…/v1/usage/` → 401 `AuthError`），
///    故 base_url 先去掉尾斜杠再拼 `/usage`（`normalizeBaseURL`）。
/// 2. **`x-opencode-session` 头不需要**：带与不带该头的响应逐字节一致，
///    且响应声明的 `access-control-allow-headers` 里根本没有它 —— 因此不解析 `custom_headers`。
/// 3. `percent` 是 JSON 数字、含义是**已用**百分比（0-100）；`status` 原样保留，
///    `!= "ok"` 一律按已限流处理（菜单里进度条转红并带出原始状态串）。
///
/// 三窗口 all-or-nothing：任一窗口缺失 / malformed → `invalidResponse`，不返回半截报告。
public struct OpenCodeGoProvider: BalanceProvider {
    public let id: ProviderID = .opencodeGo
    public let baseURL: String?

    public init(baseURL: String? = nil) {
        self.baseURL = baseURL
    }

    public static let defaultBaseURL = "https://opencode.ai/zen/go/v1"

    /// `<base_url>/usage`；base_url 已去尾斜杠。
    public static func usageURL(baseURL: String?) -> URL {
        URL(string: normalizeBaseURL(baseURL, fallback: defaultBaseURL) + "/usage")!
    }

    public func hasCredential(creds: any CredentialSource) -> Bool {
        creds.resolve(id.configSectionName) != nil
    }

    public func fetch(creds: any CredentialSource, http: HTTPClient) async throws -> BalanceResult {
        guard let key = creds.resolve(id.configSectionName) else {
            throw HTTPError.missingCredential
        }
        let (data, _) = try await http.get(
            url: Self.usageURL(baseURL: baseURL),
            headers: ["Authorization": "Bearer \(key)"],
            timeoutSeconds: 10
        )
        return try Self.decode(data)
    }

    /// 窗口描述表：响应键 → (id, 展示标签)。顺序即菜单里的展示顺序。
    static let windowDescriptors: [(key: String, id: String, label: String)] = [
        ("rolling", "5h", "5h"),
        ("weekly", "7d", "7d"),
        ("monthly", "monthly", "月度"),
    ]

    public static func decode(_ data: Data) throws -> BalanceResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any]
        else {
            throw HTTPError.invalidResponse
        }
        let windows = try decodeWindows(usage)
        // 状态栏主窗口取 rolling（5h）。
        guard let rolling = windows.first(where: { $0.id == "5h" }) else {
            throw HTTPError.invalidResponse
        }
        return BalanceResult(
            provider: .opencodeGo,
            balance: rolling.usedPercent,
            currency: .percent,
            usedPercent: rolling.usedPercent,
            resetRemaining: max(0, rolling.resetsAt.timeIntervalSince(Date())),
            quotaWindows: windows
        )
    }

    static func decodeWindows(_ usage: [String: Any]) throws -> [QuotaWindow] {
        var out: [QuotaWindow] = []
        out.reserveCapacity(windowDescriptors.count)
        for descriptor in windowDescriptors {
            guard let raw = usage[descriptor.key] as? [String: Any],
                  let percentNumber = raw["percent"] as? NSNumber,
                  let status = raw["status"] as? String,
                  let resetsAtRaw = raw["resetsAt"] as? String,
                  let resetsAt = parseISO(resetsAtRaw)
            else {
                throw HTTPError.invalidResponse
            }
            let percent = percentNumber.doubleValue
            guard percent.isFinite, percent >= 0, percent <= 100 else {
                throw HTTPError.invalidResponse
            }
            out.append(QuotaWindow(
                id: descriptor.id,
                label: descriptor.label,
                usedPercent: percent,
                status: status,
                resetsAt: resetsAt
            ))
        }
        return out
    }

    /// ISO 时间戳解析：默认格式先试（`…T12:00:00Z`），失败再试带小数秒
    /// （live 响应形状 `…T13:02:42.270Z`，`ISO8601DateFormatter` 默认解析不了）。
    static func parseISO(_ s: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

// MARK: - Registry

public enum BalanceRegistry {
    /// 生产 provider 列表：顺序与 `ProviderID.supported` 一致，`base_url` 来自 config。
    public static func all(config: KimiConfig?) -> [BalanceProvider] {
        ProviderID.supported.compactMap { provider(for: $0, config: config) }
    }

    public static func provider(for id: ProviderID, config: KimiConfig?) -> BalanceProvider? {
        let baseURL = config?.provider(id.configSectionName)?.baseURL
        switch id {
        case .deepseek: return DeepSeekProvider(baseURL: baseURL)
        case .opencodeGo: return OpenCodeGoProvider(baseURL: baseURL)
        case .unknown: return nil
        }
    }
}
