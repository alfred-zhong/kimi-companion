import AppKit
import Foundation

/// 自检入口：纯函数断言 + 集成断言（含 HTTP 解码、增量读取契约、tick 状态机）。
/// `swift run kimi-companion --self-check` 调用；**不做任何真实网络请求**，也不碰真实 UI。
public enum SelfCheck {
    public static func run() -> Int {
        var failures: [String] = []

        func check(_ name: String, _ cond: Bool) {
            if !cond { failures.append(name) }
        }

        // 等 async 结果时泵主 runloop，让 RefreshController 能在 MainActor 上发布。
        func sync<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
            let sema = DispatchSemaphore(value: 0)
            let box = UncheckedSendableBox<T>(nil)
            Task.detached {
                let v = await op()
                box.set(v)
                sema.signal()
            }
            while sema.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            }
            return box.get()!
        }

        func syncResult<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
            let sema = DispatchSemaphore(value: 0)
            let box = UncheckedSendableBox<Result<T, Error>>(nil)
            Task.detached {
                do { box.set(.success(try await op())) }
                catch { box.set(.failure(error)) }
                sema.signal()
            }
            while sema.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
            }
            return box.get()!
        }

        /// 内存凭据源：绕过 config.toml，直接指定「段名 → key」。
        struct MapCredentialSource: CredentialSource {
            let values: [String: String]
            init(values: [String: String] = [:]) { self.values = values }
            func resolve(_ name: String) -> String? {
                guard let v = values[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
                    return nil
                }
                return v
            }
        }

        // 固定响应的 fake HTTP（可选回传 statusCode 以模拟 401）。
        struct FixedHTTP: HTTPClient {
            let body: String
            var statusCode: Int = 200
            func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
                let resp = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(body.utf8), resp)
            }
        }

        // 记录请求的 fake HTTP：用于断言 URL 归一化与 Authorization 头。
        final class RecordingHTTP: HTTPClient, @unchecked Sendable {
            var calls = 0
            var requestedURLs: [String] = []
            var requestedHeaders: [String: String] = [:]
            var body: String = "{}"
            var statusCode: Int = 200

            func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
                calls += 1
                requestedURLs.append(url.absoluteString)
                requestedHeaders = headers
                let resp = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(body.utf8), resp)
            }
        }

        let now = Date()

        // MARK: - TokenStats

        do {
            let s = TokenStats(inputTokens: 100, outputTokens: 50, cacheCreationTokens: 20, cacheReadTokens: 30)
            check("TokenStats.totalInput", s.totalInputTokens == 150)
            check("TokenStats.realConsumption", s.realConsumptionTokens == 200)
            check("TokenStats.cacheHitRate", abs(TokenStats(inputTokens: 100, cacheReadTokens: 400).cacheHitRate - 0.8) < 1e-9)
            check("TokenStats.zeroHit", TokenStats().cacheHitRate == 0)
            check("TokenStats.isEmpty", TokenStats().isEmpty && !TokenStats(outputTokens: 1).isEmpty)
            var acc = TokenStats()
            acc += TokenStats(inputTokens: 1, outputTokens: 2, cacheCreationTokens: 3, cacheReadTokens: 4)
            check("TokenStats.plusEquals", acc == TokenStats(inputTokens: 1, outputTokens: 2, cacheCreationTokens: 3, cacheReadTokens: 4))
        }

        // MARK: - CompactFormatter

        check("Compact.0", CompactFormatter.format(0) == "0")
        check("Compact.999", CompactFormatter.format(999) == "999")
        check("Compact.1K", CompactFormatter.format(1_000) == "1.0K")
        check("Compact.1.5K", CompactFormatter.format(1_500) == "1.5K")
        check("Compact.18.9K", CompactFormatter.format(18_938) == "18.9K")
        check("Compact.1M", CompactFormatter.format(1_000_000) == "1.0M")
        check("Compact.2.5M", CompactFormatter.format(2_500_000) == "2.5M")
        check("Compact.1B", CompactFormatter.format(1_000_000_000) == "1.0B")
        check("Compact.rollover", CompactFormatter.format(999_950) == "1.0M")
        check("Compact.negative", CompactFormatter.format(-1_500) == "-1.5K")

        // MARK: - BalanceFormatter

        let cny = BalanceResult(provider: .deepseek, balance: 65.92, currency: .cny, isAvailable: true)
        check("Balance.CNY.2dp", BalanceFormatter.statusBarText(cny) == "¥65.92")
        check("Balance.CNY.rounds", BalanceFormatter.statusBarText(BalanceResult(provider: .deepseek, balance: 12.5, currency: .cny)) == "¥12.50")
        check("Balance.menuBarTextCNY", BalanceFormatter.menuBarText(cny) == "¥65.92")
        check("Balance.USD", BalanceFormatter.statusBarText(BalanceResult(provider: .deepseek, balance: 3.5, currency: .usd)) == "$3.50")
        let pct = BalanceResult(provider: .opencodeGo, balance: 16, currency: .percent, usedPercent: 16)
        check("Balance.percent", BalanceFormatter.statusBarText(pct) == "16%")
        check("Balance.percentRounds", BalanceFormatter.statusBarText(BalanceResult(provider: .opencodeGo, balance: 22.6, currency: .percent, usedPercent: 22.6)) == "23%")
        check("Balance.percentFallsBackToBalance", BalanceFormatter.statusBarText(BalanceResult(provider: .opencodeGo, balance: 8, currency: .percent)) == "92%")
        check("Balance.hms0", BalanceFormatter.formatHMS(0) == "0h0m")
        check("Balance.hms125", BalanceFormatter.formatHMS(125) == "0h2m")
        check("Balance.hms3661", BalanceFormatter.formatHMS(3661) == "1h1m")
        check("Duration.hms", BalanceFormatter.formatDuration(3 * 3600 + 15 * 60) == "3h15m")
        check("Duration.23h59m", BalanceFormatter.formatDuration(86_399) == "23h59m")
        check("Duration.1d", BalanceFormatter.formatDuration(86_400) == "1d")
        check("Duration.5d3h", BalanceFormatter.formatDuration(5 * 86_400 + 3 * 3600) == "5d3h")
        check("Duration.26d", BalanceFormatter.formatDuration(26 * 86_400) == "26d")

        // MARK: - ProviderID（default_model 前缀推导 + 段名 / logo 查表路由）

        // `fromModelPrefix` 现在唯一的调用方是 `fromDefaultModel`（首启菜单栏 provider 推导）；
        // 用量已不再按 `model` 前缀归属（ADR-0006），这里覆盖的是推导路径本身。
        check("Provider.deepseek.verbatim", ProviderID.fromModelPrefix("DeepSeek") == .deepseek)
        check("Provider.openCodeGo.verbatim", ProviderID.fromModelPrefix("OpenCode Go") == .opencodeGo)
        check("Provider.openCodeGo.rawValue", ProviderID.fromModelPrefix("opencode-go") == .opencodeGo)
        check("Provider.unknown", ProviderID.fromModelPrefix("agent-loop") == .unknown)
        check("Provider.empty", ProviderID.fromModelPrefix("") == .unknown)
        check("Provider.fromDefaultModel", ProviderID.fromDefaultModel("OpenCode Go/deepseek-v4.1-flash") == .opencodeGo)
        check("Provider.fromDefaultModel.deepseek", ProviderID.fromDefaultModel("DeepSeek/deepseek-flash") == .deepseek)
        check("Provider.fromDefaultModel.noSlash", ProviderID.fromDefaultModel("deepseek-flash") == .unknown)
        check("Provider.fromDefaultModel.nil", ProviderID.fromDefaultModel(nil) == .unknown)
        check("Provider.sectionName.space", ProviderID.opencodeGo.configSectionName == "OpenCode Go")
        check("Provider.displayName", ProviderID.deepseek.displayName == "DeepSeek")
        check("Provider.supportedOrder", ProviderID.supported == [.deepseek, .opencodeGo])
        check("Provider.supportedExcludesUnknown", !ProviderID.supported.contains(.unknown))

        // MARK: - MenuBarSelection（首启默认 provider）

        check("Selection.fromConfig", MenuBarSelection.deriveDefault(fromDefaultModel: "OpenCode Go/deepseek-v4.1-flash") == .opencodeGo)
        check("Selection.deepseek", MenuBarSelection.deriveDefault(fromDefaultModel: "DeepSeek/deepseek-flash") == .deepseek)
        check("Selection.fallbackOnUnknown", MenuBarSelection.deriveDefault(fromDefaultModel: "zenmux/foo") == .deepseek)
        check("Selection.fallbackOnNil", MenuBarSelection.deriveDefault(fromDefaultModel: nil) == .deepseek)

        // MARK: - ProviderFailure 文案

        do {
            check("Failure.missingSection", ProviderFailure.providerMissing.menuText(provider: .opencodeGo)
                == "config 中未找到 provider \"OpenCode Go\"")
            check("Failure.credentialEmpty", ProviderFailure.credentialEmpty.menuText(provider: .deepseek)
                == "provider \"DeepSeek\" 的 api_key 为空")
            check("Failure.credentialEnv.containsEnv", ProviderFailure.credentialEnv.menuText(provider: .deepseek).contains("api_key_env"))
            check("Failure.fetchPassthrough", ProviderFailure.fetch("鉴权失败 (401)").menuText(provider: .deepseek) == "鉴权失败 (401)")
            check("Failure.tag.config", ProviderFailure.providerMissing.statusBarTag == "配置")
            check("Failure.tag.cred", ProviderFailure.credentialEmpty.statusBarTag == "凭据")
            check("Failure.tag.credEnv", ProviderFailure.credentialEnv.statusBarTag == "凭据")
            check("Failure.tag.fetchEmpty", ProviderFailure.fetch("x").statusBarTag.isEmpty)
        }

        // MARK: - HTTPError → 中文

        check("Human.timeout", LiveBalanceSource.humanReadable(HTTPError.timeout) == "请求超时 (10 秒)")
        check("Human.unauthorized", LiveBalanceSource.humanReadable(HTTPError.unauthorized(status: 401)) == "鉴权失败 (401)")
        check("Human.rateLimited", LiveBalanceSource.humanReadable(HTTPError.rateLimited) == "请求过快 (429)")
        check("Human.server", LiveBalanceSource.humanReadable(HTTPError.server(status: 500)) == "服务异常 (500)")
        check("Human.invalidResponse", LiveBalanceSource.humanReadable(HTTPError.invalidResponse) == "响应解析失败")
        check("Human.missingCredential", LiveBalanceSource.humanReadable(HTTPError.missingCredential) == "凭据缺失")

        // MARK: - DeepSeek 解码 / URL

        do {
            // 线上真实形状：total_balance 是**字符串**。
            let body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"65.92","granted_balance":"0.00","topped_up_balance":"65.92"}]}"#
            let result = try? DeepSeekProvider.decode(Data(body.utf8))
            check("DeepSeek.decode.string", result?.balance == 65.92)
            check("DeepSeek.decode.provider", result?.provider == .deepseek)
            check("DeepSeek.decode.currency", result?.currency == .cny)
            check("DeepSeek.decode.isAvailable", result?.isAvailable == true)

            // is_available: false —— 金额仍解析出来，由展示层追加 ⚠。
            let unavailable = #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00"}]}"#
            let na = try? DeepSeekProvider.decode(Data(unavailable.utf8))
            check("DeepSeek.decode.unavailable.amount", na?.balance == 0)
            check("DeepSeek.decode.unavailable.flag", na?.isAvailable == false)

            // 数字型 total_balance 也容忍（防御性）。
            let numeric = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":12.34}]}"#
            check("DeepSeek.decode.numeric", (try? DeepSeekProvider.decode(Data(numeric.utf8)))?.balance == 12.34)

            // 非 CNY 币种。
            let usd = #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"9.99"}]}"#
            check("DeepSeek.decode.usd", (try? DeepSeekProvider.decode(Data(usd.utf8)))?.currency == .usd)

            // 空 balance_infos / 不可解析金额 → invalidResponse（不返回凭空的 ¥0.00）。
            let empty = #"{"is_available":true,"balance_infos":[]}"#
            check("DeepSeek.decode.emptyThrows",
                  syncResult { try DeepSeekProvider.decode(Data(empty.utf8)) }.failure == HTTPError.invalidResponse)
            let junk = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"abc"}]}"#
            check("DeepSeek.decode.junkThrows",
                  syncResult { try DeepSeekProvider.decode(Data(junk.utf8)) }.failure == HTTPError.invalidResponse)

            // URL：base_url + /user/balance，尾部斜杠折叠。
            check("DeepSeek.url.default", DeepSeekProvider.balanceURL(baseURL: nil).absoluteString == "https://api.deepseek.com/user/balance")
            check("DeepSeek.url.plain", DeepSeekProvider.balanceURL(baseURL: "https://api.deepseek.com").absoluteString == "https://api.deepseek.com/user/balance")
            check("DeepSeek.url.trailingSlash", DeepSeekProvider.balanceURL(baseURL: "https://api.deepseek.com/").absoluteString == "https://api.deepseek.com/user/balance")
            check("DeepSeek.url.whitespace", DeepSeekProvider.balanceURL(baseURL: "  https://api.deepseek.com  ").absoluteString == "https://api.deepseek.com/user/balance")
            // 非 HTTPS / 乱值 → 回退官方默认（本 app 只允许 HTTPS）。
            check("DeepSeek.url.rejectsHTTP", DeepSeekProvider.balanceURL(baseURL: "http://api.deepseek.com").absoluteString == "https://api.deepseek.com/user/balance")
            check("DeepSeek.url.rejectsJunk", DeepSeekProvider.balanceURL(baseURL: "not a url").absoluteString == "https://api.deepseek.com/user/balance")
        }

        // MARK: - OpenCode Go 解码 / URL

        do {
            let p = OpenCodeGoProvider()
            let body = #"{"usage":{"rolling":{"status":"ok","percent":16,"resetsAt":"2026-09-22T11:17:56.356Z"},"weekly":{"status":"ok","percent":22,"resetsAt":"2026-09-28T00:00:00.000Z"},"monthly":{"status":"ok","percent":13,"resetsAt":"2026-10-19T13:23:15.000Z"}}}"#
            let result = try? OpenCodeGoProvider.decode(Data(body.utf8))
            check("OpenCode.decode.provider", result?.provider == .opencodeGo)
            check("OpenCode.decode.currency", result?.currency == .percent)
            check("OpenCode.decode.rolling.main", result?.usedPercent == 16)
            check("OpenCode.decode.rolling.balance", result?.balance == 16)
            check("OpenCode.decode.windowCount", result?.quotaWindows?.count == 3)
            check("OpenCode.decode.windowOrder", result?.quotaWindows?.map(\.id) == ["5h", "7d", "monthly"])
            check("OpenCode.decode.windowLabels", result?.quotaWindows?.map(\.label) == ["5h", "7d", "月度"])
            check("OpenCode.decode.percents", result?.quotaWindows?.map(\.usedPercent) == [16, 22, 13])
            check("OpenCode.decode.allOK", result?.quotaWindows?.allSatisfy(\.isOK) == true)
            // 小数秒必须能解析（默认 ISO8601DateFormatter 解析不了）。
            let expected = ISO8601DateFormatter().date(from: "2026-09-22T11:17:56Z")
            let parsed = result?.quotaWindows?[0].resetsAt
            check("OpenCode.decode.fractionalSeconds",
                  abs((parsed?.timeIntervalSince1970 ?? 0) - (expected?.timeIntervalSince1970 ?? -1)) < 1)
            check("OpenCode.decode.fractionalSeconds.millisKept",
                  abs((parsed?.timeIntervalSince1970 ?? 0) - ((expected?.timeIntervalSince1970 ?? 0) + 0.356)) < 0.001)

            // 非 "ok"：原样保留 status 串，并按已限流处理。
            let limited = #"{"usage":{"rolling":{"status":"rate-limited","percent":99,"resetsAt":"2026-09-22T11:17:56Z"},"weekly":{"status":"ok","percent":5,"resetsAt":"2026-09-28T00:00:00Z"},"monthly":{"status":"weird-future-value","percent":7,"resetsAt":"2026-10-19T00:00:00Z"}}}"#
            let lim = try? OpenCodeGoProvider.decode(Data(limited.utf8))
            check("OpenCode.decode.limited.status", lim?.quotaWindows?[0].status == "rate-limited")
            check("OpenCode.decode.limited.isOK", lim?.quotaWindows?[0].isOK == false)
            check("OpenCode.decode.limited.isRateLimited", lim?.quotaWindows?[0].isRateLimited == true)
            check("OpenCode.decode.unknownStatusPreserved", lim?.quotaWindows?[2].status == "weird-future-value")
            check("OpenCode.decode.unknownStatusRateLimited", lim?.quotaWindows?[2].isRateLimited == true)

            // percent 是小数也接受。
            let fractional = #"{"usage":{"rolling":{"status":"ok","percent":16.5,"resetsAt":"2026-09-22T11:17:56Z"},"weekly":{"status":"ok","percent":1,"resetsAt":"2026-09-28T00:00:00Z"},"monthly":{"status":"ok","percent":2,"resetsAt":"2026-10-19T00:00:00Z"}}}"#
            check("OpenCode.decode.fractionalPercent", (try? OpenCodeGoProvider.decode(Data(fractional.utf8)))?.usedPercent == 16.5)

            // all-or-nothing：缺窗口 / 越界 / 缺 usage → invalidResponse。
            let missingWindow = #"{"usage":{"rolling":{"status":"ok","percent":10,"resetsAt":"2026-09-22T11:17:56Z"},"weekly":{"status":"ok","percent":10,"resetsAt":"2026-09-28T00:00:00Z"}}}"#
            check("OpenCode.decode.missingWindowThrows",
                  syncResult { try OpenCodeGoProvider.decode(Data(missingWindow.utf8)) }.failure == HTTPError.invalidResponse)
            let outOfRange = #"{"usage":{"rolling":{"status":"ok","percent":150,"resetsAt":"2026-09-22T11:17:56Z"},"weekly":{"status":"ok","percent":1,"resetsAt":"2026-09-28T00:00:00Z"},"monthly":{"status":"ok","percent":2,"resetsAt":"2026-10-19T00:00:00Z"}}}"#
            check("OpenCode.decode.outOfRangeThrows",
                  syncResult { try OpenCodeGoProvider.decode(Data(outOfRange.utf8)) }.failure == HTTPError.invalidResponse)
            let noUsage = #"{"error":{"type":"AuthError"}}"#
            check("OpenCode.decode.noUsageThrows",
                  syncResult { try OpenCodeGoProvider.decode(Data(noUsage.utf8)) }.failure == HTTPError.invalidResponse)

            // URL 归一化：**带尾斜杠会 401**，所以拼 /usage 之前必须先去掉尾斜杠。
            check("OpenCode.url.configBase", OpenCodeGoProvider.usageURL(baseURL: "https://opencode.ai/zen/go/v1").absoluteString
                == "https://opencode.ai/zen/go/v1/usage")
            check("OpenCode.url.trailingSlashFolded", OpenCodeGoProvider.usageURL(baseURL: "https://opencode.ai/zen/go/v1/").absoluteString
                == "https://opencode.ai/zen/go/v1/usage")
            check("OpenCode.url.multipleTrailingSlashes", OpenCodeGoProvider.usageURL(baseURL: "https://opencode.ai/zen/go/v1///").absoluteString
                == "https://opencode.ai/zen/go/v1/usage")
            check("OpenCode.url.neverTrailingSlash", !OpenCodeGoProvider.usageURL(baseURL: "https://opencode.ai/zen/go/v1/").absoluteString.hasSuffix("/"))
            check("OpenCode.url.default", OpenCodeGoProvider.usageURL(baseURL: nil).absoluteString == "https://opencode.ai/zen/go/v1/usage")
            check("OpenCode.url.rejectsHTTP", OpenCodeGoProvider.usageURL(baseURL: "http://opencode.ai/zen/go/v1").absoluteString == "https://opencode.ai/zen/go/v1/usage")
            check("OpenCode.baseURLUsed", p.id == .opencodeGo)
        }

        // MARK: - Provider fetch（请求头 / 走 fake HTTP）

        do {
            let http = RecordingHTTP()
            http.body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"65.92"}]}"#
            let p = DeepSeekProvider(baseURL: "https://api.deepseek.com")
            let result = syncResult { try await p.fetch(creds: MapCredentialSource(values: ["DeepSeek": "sk-test"]), http: http) }
            check("Fetch.deepseek.ok", result.value?.balance == 65.92)
            check("Fetch.deepseek.url", http.requestedURLs == ["https://api.deepseek.com/user/balance"])
            check("Fetch.deepseek.auth", http.requestedHeaders["Authorization"] == "Bearer sk-test")

            let ocHTTP = RecordingHTTP()
            ocHTTP.body = #"{"usage":{"rolling":{"status":"ok","percent":16,"resetsAt":"2026-09-22T11:17:56Z"},"weekly":{"status":"ok","percent":22,"resetsAt":"2026-09-28T00:00:00Z"},"monthly":{"status":"ok","percent":13,"resetsAt":"2026-10-19T00:00:00Z"}}}"#
            let oc = OpenCodeGoProvider(baseURL: "https://opencode.ai/zen/go/v1/")
            _ = syncResult { try await oc.fetch(creds: MapCredentialSource(values: ["OpenCode Go": "oc_test"]), http: ocHTTP) }
            check("Fetch.opencode.urlNoTrailingSlash", ocHTTP.requestedURLs == ["https://opencode.ai/zen/go/v1/usage"])
            check("Fetch.opencode.auth", ocHTTP.requestedHeaders["Authorization"] == "Bearer oc_test")

            // 无凭据：不发请求。
            let noCredHTTP = RecordingHTTP()
            let thrown = syncResult { try await DeepSeekProvider().fetch(creds: MapCredentialSource(), http: noCredHTTP) }
            check("Fetch.noCredential.throws", thrown.failure == HTTPError.missingCredential)
            check("Fetch.noCredential.noRequest", noCredHTTP.calls == 0)

            // 401（body 是纯文本，与 omp 不同）→ URLSessionHTTPClient 统一抛 unauthorized；这里用 fake 模拟抛错路径。
            check("Fetch.401.mapsToChinese", LiveBalanceSource.humanReadable(HTTPError.unauthorized(status: 401)) == "鉴权失败 (401)")
        }

        // MARK: - config.toml 解析

        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("kimi-companion-config-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: root) }
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            func write(_ name: String, _ text: String) -> String {
                let url = root.appendingPathComponent(name)
                try? Data(text.utf8).write(to: url)
                return url.path
            }

            // 真实形状：含空格引号段名、无空格段名、空 api_key 段、内联 table、`#` 在字符串里。
            let real = """
            default_model = "OpenCode Go/deepseek-v4.1-flash"

            [providers."managed:kimi-code"]
            base_url = "https://api.kimi.com/coding/v1"
            type = "kimi"
            api_key = ""

            [providers.DeepSeek]
            base_url = "https://api.deepseek.com"
            type = "openai"
            api_key = "sk-0123456789abcdef0123456789abcdef"

            [providers."OpenCode Go"]
            base_url = "https://opencode.ai/zen/go/v1"
            type = "openai"
            api_key = "oc_sk_a#b_0123456789"
            custom_headers = { x-opencode-session = "4DD877B9-056A-4015-A1F2-421430DAA7D3" }
            """
            let source = KimiConfigSource(configPath: write("real.toml", real))
            guard case .loaded(let cfg) = source.load() else {
                check("Config.loaded", false)
                return finish(&failures)
            }
            check("Config.loaded", true)
            check("Config.defaultModel", cfg.defaultModel == "OpenCode Go/deepseek-v4.1-flash")
            check("Config.providerKeys", Set(cfg.providers.keys) == ["managed:kimi-code", "DeepSeek", "OpenCode Go"])
            // 带空格的引号段名逐字命中，且 `.table` 是唯一正确取法（`as? TOMLTable` 恒为 nil）。
            check("Config.quotedKeyWithSpace", cfg.provider("OpenCode Go") != nil)
            check("Config.quotedKeyBaseURL", cfg.provider("OpenCode Go")?.baseURL == "https://opencode.ai/zen/go/v1")
            check("Config.quotedKeyAPIKey", cfg.provider("OpenCode Go")?.apiKey == "oc_sk_a#b_0123456789")
            check("Config.hashInsideString", cfg.provider("OpenCode Go")?.apiKey?.contains("#") == true)
            check("Config.dotInsideKey", cfg.provider("DeepSeek")?.apiKey?.count == 35)
            check("Config.inlineTableDoesNotBreak", cfg.provider("OpenCode Go")?.usesAPIKeyEnv == false)
            // 空字符串 api_key == 无凭据。
            check("Config.emptyAPIKeyIsNil", cfg.provider("managed:kimi-code")?.apiKey == nil)
            // 不存在的段。
            check("Config.missingSection", cfg.provider("MiniMax") == nil)
            check("Config.missingSectionGuard", ProviderID.supported.allSatisfy { cfg.provider($0.configSectionName) != nil })
            // 未使用 api_key_env。
            check("Config.noEnvKey", cfg.provider("DeepSeek")?.usesAPIKeyEnv == false)

            // CredentialSource 只认内联 api_key。
            let creds = TomlCredentialSource(config: cfg)
            check("Creds.resolve", creds.resolve("OpenCode Go") == "oc_sk_a#b_0123456789")
            check("Creds.resolveEmpty", creds.resolve("managed:kimi-code") == nil)
            check("Creds.resolveMissing", creds.resolve("MiniMax") == nil)

            // api_key_env 段：凭据不可解析（不调用 getenv）。
            let envToml = """
            [providers.DeepSeek]
            base_url = "https://api.deepseek.com"
            api_key_env = "DEEPSEEK_API_KEY"
            """
            let envSource = KimiConfigSource(configPath: write("env.toml", envToml))
            let envCfg = envSource.load().config
            check("Config.apiKeyEnv.flag", envCfg?.provider("DeepSeek")?.usesAPIKeyEnv == true)
            check("Config.apiKeyEnv.keyNil", envCfg?.provider("DeepSeek")?.apiKey == nil)
            check("Creds.apiKeyEnv.unresolvable", TomlCredentialSource(config: envCfg).resolve("DeepSeek") == nil)

            // 全空白 api_key 视为缺失。
            let blankToml = """
            [providers.DeepSeek]
            api_key = "   "
            """
            let blankCfg = KimiConfigSource(configPath: write("blank.toml", blankToml)).load().config
            check("Config.blankKeyIsNil", blankCfg?.provider("DeepSeek")?.apiKey == nil)

            // 无 providers 段 / 空文件：仍可加载，只是没有条目。
            let bareCfg = KimiConfigSource(configPath: write("bare.toml", "default_model = \"DeepSeek/x\"\n")).load().config
            check("Config.noProvidersTable", bareCfg?.providers.isEmpty == true)
            check("Config.noProvidersTable.defaultModel", bareCfg?.defaultModel == "DeepSeek/x")

            // 非法 TOML / 不存在的文件。
            if case .malformed = KimiConfigSource(configPath: write("bad.toml", "this is [not toml")).load() {
                check("Config.malformed", true)
            } else {
                check("Config.malformed", false)
            }
            if case .unreadable(let reason) = KimiConfigSource(configPath: "\(root.path)/nope.toml").load() {
                check("Config.unreadable", reason.contains("nope.toml"))
            } else {
                check("Config.unreadable", false)
            }
        }

        // MARK: - LiveBalanceSource：逐 provider 独立

        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("kimi-companion-source-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: root) }
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            let configPath = root.appendingPathComponent("config.toml").path

            let goodKey = String(repeating: "k", count: 40)
            let both = """
            default_model = "OpenCode Go/deepseek-v4.1-flash"

            [providers.DeepSeek]
            base_url = "https://api.deepseek.com"
            api_key = "\(goodKey)"

            [providers."OpenCode Go"]
            base_url = "https://opencode.ai/zen/go/v1"
            api_key = "\(goodKey)"
            """
            try? Data(both.utf8).write(to: URL(fileURLWithPath: configPath))

            // 两个都成功。
            final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
                var urls: [String] = []
                var statusByHost: [String: Int] = [:]
                var bodyByPath: [String: String] = [:]
                func get(url: URL, headers: [String: String], timeoutSeconds: Double) async throws -> (Data, HTTPURLResponse) {
                    urls.append(url.absoluteString)
                    let status = statusByHost[url.host ?? ""] ?? 200
                    if status != 200 {
                        throw HTTPError.unauthorized(status: status)
                    }
                    let body = bodyByPath[url.path] ?? "{}"
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (Data(body.utf8), resp)
                }
            }

            let http = ScriptedHTTP()
            http.bodyByPath["/user/balance"] = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"65.92"}]}"#
            http.bodyByPath["/zen/go/v1/usage"] = #"{"usage":{"rolling":{"status":"ok","percent":16,"resetsAt":"2026-09-22T11:17:56Z"},"weekly":{"status":"ok","percent":22,"resetsAt":"2026-09-28T00:00:00Z"},"monthly":{"status":"ok","percent":13,"resetsAt":"2026-10-19T00:00:00Z"}}}"#

            let source = LiveBalanceSource(config: KimiConfigSource(configPath: configPath), http: http)
            let capture = sync { await source.capture(now: now) }
            check("Source.bothSucceed.count", capture.perProvider.count == 2)
            check("Source.deepseek.value", capture.capture(for: .deepseek).result?.balance == 65.92)
            check("Source.opencode.value", capture.capture(for: .opencodeGo).result?.usedPercent == 16)
            check("Source.notConfigMissing", capture.configMissing == false)
            check("Source.defaultModel", capture.defaultModel == "OpenCode Go/deepseek-v4.1-flash")
            check("Source.usedConfigBaseURL", Set(http.urls) == ["https://api.deepseek.com/user/balance", "https://opencode.ai/zen/go/v1/usage"])

            // 只让 OpenCode Go 失败：DeepSeek 必须不受影响。
            http.statusByHost["opencode.ai"] = 401
            let partial = sync { await source.capture(now: now) }
            check("Source.independent.deepseekStillOK", partial.capture(for: .deepseek).result?.balance == 65.92)
            check("Source.independent.opencodeFailed", partial.capture(for: .opencodeGo).result == nil)
            check("Source.independent.opencodeReason",
                  partial.capture(for: .opencodeGo).failure == .fetch("鉴权失败 (401)"))
            check("Source.independent.deepseekNoFailure", partial.capture(for: .deepseek).failure == nil)

            // 段缺失：只有该 provider 报 providerMissing。
            let onlyDeepSeek = """
            [providers.DeepSeek]
            api_key = "\(goodKey)"
            """
            try? Data(onlyDeepSeek.utf8).write(to: URL(fileURLWithPath: configPath))
            http.statusByHost.removeAll()
            let missing = sync { await source.capture(now: now) }
            check("Source.sectionMissing.deepseekOK", missing.capture(for: .deepseek).result?.balance == 65.92)
            check("Source.sectionMissing.opencode", missing.capture(for: .opencodeGo).failure == .providerMissing)

            // 空 api_key。
            let emptyKey = """
            [providers.DeepSeek]
            api_key = ""

            [providers."OpenCode Go"]
            api_key = ""
            """
            try? Data(emptyKey.utf8).write(to: URL(fileURLWithPath: configPath))
            let empty = sync { await source.capture(now: now) }
            check("Source.emptyKey.deepseek", empty.capture(for: .deepseek).failure == .credentialEmpty)
            check("Source.emptyKey.opencode", empty.capture(for: .opencodeGo).failure == .credentialEmpty)

            // api_key_env：凭据不可解析，且明确与「空」区分。
            let envKey = """
            [providers.DeepSeek]
            api_key_env = "DEEPSEEK_API_KEY"

            [providers."OpenCode Go"]
            api_key = "\(goodKey)"
            """
            try? Data(envKey.utf8).write(to: URL(fileURLWithPath: configPath))
            let envCapture = sync { await source.capture(now: now) }
            check("Source.envKey.deepseek", envCapture.capture(for: .deepseek).failure == .credentialEnv)
            check("Source.envKey.opencodeOK", envCapture.capture(for: .opencodeGo).result != nil)

            // config.toml 不可读 → 全局降级，两个都带 configUnreadable。
            let missingConfig = LiveBalanceSource(config: KimiConfigSource(configPath: "\(root.path)/gone.toml"), http: http)
            let unreadable = sync { await missingConfig.capture(now: now) }
            check("Source.configMissing.flag", unreadable.configMissing == true)
            check("Source.configMissing.deepseek", unreadable.capture(for: .deepseek).failure?.statusBarTag == "配置")
            check("Source.configMissing.opencode", unreadable.capture(for: .opencodeGo).failure?.statusBarTag == "配置")
            check("Source.configMissing.noHTTP", unreadable.capture(for: .deepseek).result == nil)
        }

        // MARK: - WireLineParser（usage.record 解析）

        do {
            let p = WireLineParser()
            let line = #"{"type":"usage.record","agentId":"main","model":"DeepSeek/deepseek-flash","usage":{"inputOther":18938,"output":187,"inputCacheRead":145024,"inputCacheCreation":0},"usageScope":"turn","time":1790065336874}"#
            let ev = p.parse(line: line, relPath: "w/s/agents/main/wire.jsonl", lineOffset: 128)
            check("Wire.parsed", ev != nil)
            check("Wire.tsMs", ev?.tsMs == 1790065336874)
            check("Wire.inputOther", ev?.inputOther == 18_938)
            check("Wire.output", ev?.output == 187)
            check("Wire.cacheRead", ev?.cacheRead == 145_024)
            check("Wire.cacheCreation", ev?.cacheCreation == 0)
            check("Wire.dedupeKey", ev?.dedupeKey == "w/s/agents/main/wire.jsonl:128")

            // `model` 不参与解析：另一个前缀的记录产出形状完全相同的 UsageEvent（只有时间与计数）。
            let ocLine = #"{"type":"usage.record","agentId":"agent-3","model":"OpenCode Go/deepseek-v4.1-flash","usage":{"inputOther":1057,"output":279,"inputCacheRead":164224,"inputCacheCreation":0},"usageScope":"turn","time":1790069954636}"#
            let ocEvent = p.parse(line: ocLine, relPath: "a", lineOffset: 0)
            check("Wire.otherPrefixParsed", ocEvent?.inputOther == 1_057 && ocEvent?.cacheRead == 164_224)

            // 未匹配任何受支持 provider 的 `model` 前缀照常计数（没有任何东西被丢弃）。
            let unknownLoad = #"{"type":"usage.record","agentId":"main","model":"zenmux/foo","usage":{"inputOther":1,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1}"#
            check("Wire.unmatchedPrefixCounted",
                  p.parse(line: unknownLoad, relPath: "a", lineOffset: 0)?.stats == TokenStats(inputTokens: 1, outputTokens: 1))
            // 连 `model` 字段都没有也是一条合法记录（parser 不再读它）。
            let noModel = #"{"type":"usage.record","agentId":"main","usage":{"inputOther":4,"output":2,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":9}"#
            check("Wire.noModelFieldStillParsed",
                  p.parse(line: noModel, relPath: "a", lineOffset: 0)?.stats == TokenStats(inputTokens: 4, outputTokens: 2))

            // 非 usage.record 一律不计（含 metadata / llm.request / agent.message.appended / token_counting.measured）。
            let metadata = #"{"type":"metadata","protocol_version":"1.5","created_at":1790069942091}"#
            check("Wire.skip.metadata", p.parse(line: metadata, relPath: "a", lineOffset: 0) == nil)
            let llmRequest = #"{"type":"llm.request","provider":"openai","modelAlias":"OpenCode Go/deepseek-v4.1-flash","agentId":"main","time":1}"#
            check("Wire.skip.llmRequest", p.parse(line: llmRequest, relPath: "a", lineOffset: 0) == nil)
            let appended = #"{"type":"agent.message.appended","kind":"text","agentId":"main","model":"agent-loop","message":{},"time":1}"#
            check("Wire.skip.agentMessage", p.parse(line: appended, relPath: "a", lineOffset: 0) == nil)
            let tokenCounting = #"{"type":"token_counting.measured","agentId":"main","tokens":123456,"time":1}"#
            check("Wire.skip.tokenCounting", p.parse(line: tokenCounting, relPath: "a", lineOffset: 0) == nil)

            // 缺 time → 不计（不能用别的字段凑时间）。
            let noTime = #"{"type":"usage.record","agentId":"main","model":"DeepSeek/x","usage":{"inputOther":1,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn"}"#
            check("Wire.skip.noTime", p.parse(line: noTime, relPath: "a", lineOffset: 0) == nil)
            // 缺 usage → 仍然是一条记录，字段按 0 计。
            let noUsage = #"{"type":"usage.record","agentId":"main","model":"DeepSeek/x","usageScope":"turn","time":7}"#
            let zeroed = p.parse(line: noUsage, relPath: "a", lineOffset: 0)
            check("Wire.noUsage.zeroed", zeroed?.tsMs == 7 && (zeroed?.stats.isEmpty ?? false))
            check("Wire.stats.mapping", ev?.stats == TokenStats(inputTokens: 18_938, outputTokens: 187, cacheCreationTokens: 0, cacheReadTokens: 145_024))
        }

        // MARK: - HourlyAggregator（桶边界 + 合并口径）

        do {
            let nowMs: Int64 = 24 * HOUR_MS
            let todayStartMs: Int64 = 0
            func event(_ id: String, _ tsMs: Int64, input: Int = 10, output: Int = 1, cacheRead: Int = 0, cacheCreation: Int = 0) -> UsageEvent {
                UsageEvent(tsMs: tsMs, inputOther: input, output: output,
                           cacheRead: cacheRead, cacheCreation: cacheCreation, dedupeKey: id)
            }
            let events: [UsageEvent] = [
                event("a", nowMs - HOUR_MS / 2, input: 5),
                event("b", nowMs - 6 * HOUR_MS, input: 10),
                event("c", nowMs - 14 * HOUR_MS, input: 100),
                event("d", -HOUR_MS, input: 999),
                event("e", nowMs - HOUR_MS / 2, input: 7),
                event("f", nowMs - 4 * HOUR_MS, input: 3),
            ]
            let snap = HourlyAggregator().aggregate(events: events, nowMs: nowMs, todayStartMs: todayStartMs)

            check("Agg.buckets.count", snap.hourly.count == HOUR_BUCKET_COUNT)
            // 合并口径：a+b+c+e+f = 125 全部并入同一份合计；d 在今日零点之前，不计。
            check("Agg.today.combined", snap.today.inputTokens == 125)
            check("Agg.droppedBeforeToday", snap.today.inputTokens != 1_124)
            // 桶：30min 前 → hoursAgo=0.5 → idx = 12-1-0 = 11；6h 前 → idx 5；4h 前 → idx 7；14h 前 → 不入 12 桶
            check("Agg.bucket11", snap.hourly[11].stats.inputTokens == 12)
            check("Agg.bucket7", snap.hourly[7].stats.inputTokens == 3)
            check("Agg.bucket5", snap.hourly[5].stats.inputTokens == 10)
            check("Agg.bucket.outOfWindow", snap.hourly[0].stats.inputTokens == 0)
            check("Agg.bucket.allEventsKept", snap.hourly.reduce(0) { $0 + $1.stats.inputTokens } == 25)
            // last5h = 后 5 桶（idx 7..11）= 3 + 12 = 15；idx 5 的 10 不在其中。
            check("Agg.last5h", snap.last5h.inputTokens == 15)
            check("Agg.last5h.excludesOlder", snap.hourly[5].stats.inputTokens == 10 && snap.last5h.inputTokens != 25)
            var union = TokenStats()
            for bucket in snap.hourly.suffix(5) { union += bucket.stats }
            check("Agg.last5h.equalsUnionOfLast5Buckets", snap.last5h == union && union.inputTokens == 15)

            // 桶结构不变量：12 桶、步长 1h、索引 0 最旧 / 末位最新、左开右闭、末桶是完整一小时。
            check("Agg.bucket.endMsAxis",
                  snap.hourly.map(\.endMs) == (0..<HOUR_BUCKET_COUNT).map { nowMs - Int64(HOUR_BUCKET_COUNT - 1 - $0) * HOUR_MS })
            check("Agg.bucket.eachSpansOneHour", snap.hourly.allSatisfy { $0.endMs - $0.startMs == HOUR_MS })
            check("Agg.bucket.lastIsCompleteHourEndingNow", snap.hourly[HOUR_BUCKET_COUNT - 1].endMs == nowMs)

            // 桶区间左开右闭。
            let edge: [UsageEvent] = [
                event("at-now", nowMs, input: 1),
                event("exactly-1h", nowMs - HOUR_MS, input: 2),
                event("just-inside-left", nowMs - 11 * HOUR_MS - 1, input: 4),
                event("exactly-12h", nowMs - 12 * HOUR_MS, input: 8),
            ]
            let edgeSnap = HourlyAggregator().aggregate(events: edge, nowMs: nowMs, todayStartMs: todayStartMs)
            let hours = edgeSnap.hourly
            check("Agg.boundary.nowInLastBucket", hours[11].stats.inputTokens == 1)
            check("Agg.boundary.exactly1hInBucket10", hours[10].stats.inputTokens == 2)
            check("Agg.boundary.justInsideInBucket0", hours[0].stats.inputTokens == 4)
            check("Agg.boundary.exactly12hExcluded", hours.reduce(0) { $0 + $1.stats.inputTokens } == 7)
            check("Agg.boundary.leftOpenRightClosed", hours[11].endMs == nowMs && hours[11].startMs == nowMs - HOUR_MS)
            check("Agg.boundary.oldestFirst", hours[0].endMs == nowMs - 11 * HOUR_MS)
            // 6h 前的桶 idx=5 的右端是 now-6h
            check("Agg.bucketIndexAxis", hours[5].endMs == nowMs - 6 * HOUR_MS)

            // 空事件：结构完整、全零。
            let emptySnap = HourlyAggregator().aggregate(events: [], nowMs: nowMs, todayStartMs: todayStartMs)
            check("Agg.empty.structure", emptySnap.hourly.count == HOUR_BUCKET_COUNT)
            check("Agg.empty.zeroed", emptySnap.today.isEmpty && emptySnap.last5h.isEmpty
                && emptySnap.hourly.allSatisfy { $0.stats.isEmpty })
        }

        // MARK: - WireLogReader：增量契约 == 全量重扫

        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory
                .appendingPathComponent("kimi-companion-reader-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: root) }

            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            let boundary = WireLogReader(sessionsRoot: root.path).boundaryMs(now: now)
            check("Reader.boundaryIsMinOf", boundary == min(WireLogReader(sessionsRoot: root.path).todayStartMs(now: now),
                                                           nowMs - Int64(HOUR_BUCKET_COUNT) * HOUR_MS))

            func line(_ model: String, _ tsMs: Int64, output: Int = 1) -> String {
                #"{"type":"usage.record","agentId":"main","model":"\#(model)","usage":{"inputOther":10,"output":\#(output),"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":\#(tsMs)}"# + "\n"
            }
            func write(_ rel: String, _ content: String, mtime: Date = now) {
                let url = root.appendingPathComponent(rel)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(content.utf8).write(to: url)
                try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            }
            func append(_ rel: String, _ content: String) {
                guard let handle = try? FileHandle(forWritingTo: root.appendingPathComponent(rel)) else { return }
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(content.utf8))
            }
            func keys(_ events: [UsageEvent]) -> Set<String> { Set(events.map(\.dedupeKey)) }
            /// 期望值：同一份文件状态，换一个全新 reader 全量读取。
            func oracle(_ rel: String, now: Date = now) -> Set<String> {
                keys(WireLogReader(sessionsRoot: root.appendingPathComponent(rel).path).events(now: now))
            }

            // 真实路径形状：sessions/<workspace>/<session>/agents/<agent>/wire.jsonl
            write("incremental/wd_x_aaaaaaaaaaaa/session_1/agents/main/wire.jsonl",
                  line("DeepSeek/deepseek-flash", nowMs - 120_000) + line("DeepSeek/deepseek-flash", nowMs - 60_000))
            write("incremental/wd_x_aaaaaaaaaaaa/session_1/agents/agent-3/wire.jsonl",
                  line("OpenCode Go/deepseek-v4.1-flash", nowMs - 30_000))
            // 只有 wire.jsonl 会被读取；同目录下的其它 .jsonl 忽略。
            write("incremental/wd_x_aaaaaaaaaaaa/session_1/agents/main/other.jsonl",
                  line("DeepSeek/deepseek-flash", nowMs - 10_000))
            let reader = WireLogReader(sessionsRoot: root.appendingPathComponent("incremental").path)
            let first = reader.events(now: now)
            check("Reader.initialCount", first.count == 3)
            check("Reader.initialParity", keys(first) == oracle("incremental"))
            // 每个 agent 的文件都必须被读到（跨文件零重复；只读 main 会严重漏计）。
            check("Reader.multiAgentFiles",
                  first.contains { $0.dedupeKey.hasPrefix("wd_x_aaaaaaaaaaaa/session_1/agents/agent-3/wire.jsonl:") }
                  && first.contains { $0.dedupeKey.hasPrefix("wd_x_aaaaaaaaaaaa/session_1/agents/main/wire.jsonl:") })

            // 增量：第二次读取是「窗口内全量」而不是「本轮新增」，且与全量结果一致。
            append("incremental/wd_x_aaaaaaaaaaaa/session_1/agents/main/wire.jsonl",
                   line("DeepSeek/deepseek-flash", nowMs - 10_000) + line("DeepSeek/deepseek-flash", nowMs - 5_000))
            let second = reader.events(now: now)
            check("Reader.incrementalCount", second.count == 5)
            check("Reader.incrementalParity", keys(second) == oracle("incremental"))

            // 写入中的半行：不补齐就不计入，补上换行后恰好计一次。
            append("incremental/wd_x_aaaaaaaaaaaa/session_1/agents/main/wire.jsonl",
                   String(line("DeepSeek/deepseek-flash", nowMs - 2_000).dropLast()))
            let pending = reader.events(now: now)
            check("Reader.partialLinePending", pending.count == 5 && keys(pending) == oracle("incremental"))
            append("incremental/wd_x_aaaaaaaaaaaa/session_1/agents/main/wire.jsonl", "\n")
            let completed = reader.events(now: now)
            check("Reader.partialLineCompleted", completed.count == 6 && keys(completed) == oracle("incremental"))

            // 截断：已计入的事件随重读一起作废，结果仍等于全量。
            write("rewrite/wd_y_bbbbbbbbbbbb/session_2/agents/main/wire.jsonl",
                  line("DeepSeek/deepseek-flash", nowMs - 180_000) + line("DeepSeek/deepseek-flash", nowMs - 120_000))
            let rewriting = WireLogReader(sessionsRoot: root.appendingPathComponent("rewrite").path)
            check("Reader.rewriteBefore", rewriting.events(now: now).count == 2)
            write("rewrite/wd_y_bbbbbbbbbbbb/session_2/agents/main/wire.jsonl",
                  line("DeepSeek/deepseek-flash", nowMs - 60_000))
            let rewritten = rewriting.events(now: now)
            check("Reader.truncationCount", rewritten.count == 1)
            check("Reader.truncationParity", keys(rewritten) == oracle("rewrite"))

            // 删除：游标退休，不再贡献事件。
            write("deletion/wd_z_cccccccccccc/session_3/agents/main/wire.jsonl", line("DeepSeek/deepseek-flash", nowMs - 30_000))
            let deleting = WireLogReader(sessionsRoot: root.appendingPathComponent("deletion").path)
            check("Reader.deleteBefore", deleting.events(now: now).count == 1)
            try? fm.removeItem(at: root.appendingPathComponent("deletion/wd_z_cccccccccccc/session_3/agents/main/wire.jsonl"))
            let deleted = deleting.events(now: now)
            check("Reader.deletionParity", deleted.isEmpty && oracle("deletion").isEmpty)

            // mtime 剪枝：文件 mtime 早于边界时，再新的事件也不计（记录按时间序追加）。
            write("prune/wd_p_dddddddddddd/session_4/agents/main/wire.jsonl",
                  line("DeepSeek/deepseek-flash", nowMs - 30_000),
                  mtime: Date(timeIntervalSince1970: Double(boundary) / 1000 - 3600))
            let pruned = WireLogReader(sessionsRoot: root.appendingPathComponent("prune").path).events(now: now)
            check("Reader.mtimePrune", pruned.isEmpty && oracle("prune").isEmpty)

            // 窗口过滤 + 时钟回拨：两者都必须仍与全量一致。
            write("window/wd_w_eeeeeeeeeeee/session_5/agents/main/wire.jsonl",
                  line("DeepSeek/deepseek-flash", boundary - 60_000, output: 100) + line("OpenCode Go/x", nowMs - 30_000, output: 200))
            let rolling = WireLogReader(sessionsRoot: root.appendingPathComponent("window").path)
            let windowed = rolling.events(now: now)
            check("Reader.windowEviction", windowed.count == 1)
            check("Reader.windowEviction.content", windowed.first?.output == 200)
            check("Reader.windowParity", keys(windowed) == oracle("window"))
            let earlier = Date(timeIntervalSince1970: TimeInterval(nowMs - HOUR_MS) / 1000)
            let rolledBack = rolling.events(now: earlier)
            check("Reader.clockRollbackParity", keys(rolledBack) == oracle("window", now: earlier))

            // 不存在的 sessions 根目录：返回空，不崩。
            check("Reader.missingRoot", WireLogReader(sessionsRoot: "\(root.path)/nope").events(now: now).isEmpty)

            // 空行不该让游标偏移错位（去重键稳定性）：同一文件里插空行后仍与全量一致。
            write("blank/wd_b_ffffffffffff/session_6/agents/main/wire.jsonl", "\n\n" + line("DeepSeek/x", nowMs - 20_000) + "\n")
            let blankReader = WireLogReader(sessionsRoot: root.appendingPathComponent("blank").path)
            check("Reader.blankLines.count", blankReader.events(now: now).count == 1)
            check("Reader.blankLines.parity", keys(blankReader.events(now: now)) == oracle("blank"))
        }

        // MARK: - LiveDailyUsageSource（reader + aggregator 串起来）

        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("kimi-companion-daily-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: root) }
            let nowMs = Int64(now.timeIntervalSince1970 * 1000)
            let file = root.appendingPathComponent("wd_d_111111111111/session_7/agents/main/wire.jsonl")
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = [
                #"{"type":"usage.record","agentId":"main","model":"DeepSeek/deepseek-flash","usage":{"inputOther":10,"output":5,"inputCacheRead":90,"inputCacheCreation":0},"usageScope":"turn","time":\#(nowMs - 30_000)}"#,
                #"{"type":"usage.record","agentId":"agent-0","model":"OpenCode Go/deepseek-v4.1-flash","usage":{"inputOther":20,"output":7,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":\#(nowMs - 20_000)}"#,
                #"{"type":"usage.record","agentId":"main","model":"agent-loop","usage":{"inputOther":3,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":\#(nowMs - 10_000)}"#,
            ].joined(separator: "\n") + "\n"
            try? Data(content.utf8).write(to: file)

            let source = LiveDailyUsageSource(reader: WireLogReader(sessionsRoot: root.path))
            let (snap, err) = sync { await source.capture(now: now) }
            check("DailySource.noError", err == nil)
            check("DailySource.snapshot", snap != nil)
            // 三条记录各带不同的 `model` 前缀（DeepSeek / OpenCode Go / 不匹配任何 Provider 的 agent-loop），
            // 全部并入同一份合计：input 10+20+3 = 33，output 5+7+1 = 13，cacheRead 90。
            check("DailySource.combined",
                  snap?.today == TokenStats(inputTokens: 33, outputTokens: 13, cacheReadTokens: 90))
            check("DailySource.combined.bothKnownPrefixesCounted", snap?.today.inputTokens == 10 + 20 + 3)
            check("DailySource.combined.unmatchedPrefixNotDropped", snap?.today.inputTokens != 10 + 20)
            check("DailySource.combined.notSinglePrefix", snap?.today.inputTokens != 20 + 3)
            check("DailySource.hitRate", abs((snap?.today.cacheHitRate ?? 0) - 90.0 / 123.0) < 1e-9)
        }

        // MARK: - Caffeinate / Countdown

        check("Bucket.count", CaffeinateBucket.allCases.count == 3)
        check("Bucket.thirty", CaffeinateBucket.thirtyMinutes.minutes == 30)
        check("Bucket.sixty", CaffeinateBucket.sixtyMinutes.minutes == 60)
        check("Bucket.120", CaffeinateBucket.oneTwentyMinutes.minutes == 120)
        check("Bucket.labels", CaffeinateBucket.allCases.map(\.label) == ["30 分钟", "60 分钟", "120 分钟"])
        check("Bucket.default", CaffeinateBucket.default == .sixtyMinutes)
        check("Bucket.raw30", CaffeinateBucket(rawValue: 30) == .thirtyMinutes)
        check("Bucket.invalid5", CaffeinateBucket(rawValue: 5) == nil)

        do {
            let session = CaffeinateSession(bucket: .sixtyMinutes, startedAt: now, endAt: now.addingTimeInterval(60))
            check("Session.active", session.isActive(now: now))
            check("Session.remaining", abs(session.remainingSeconds(now: now) - 60) < 1e-6)
            let expired = CaffeinateSession(bucket: .thirtyMinutes, startedAt: now.addingTimeInterval(-120), endAt: now.addingTimeInterval(-60))
            check("Session.expired", !expired.isActive(now: now))
            check("Session.expiredNegativeRemaining", expired.remainingSeconds(now: now) < 0)
        }

        check("Countdown.0", CountdownFormatter.format(remaining: 0) == "0s")
        check("Countdown.negative", CountdownFormatter.format(remaining: -5) == "0s")
        check("Countdown.0.5", CountdownFormatter.format(remaining: 0.5) == "1s")
        check("Countdown.59", CountdownFormatter.format(remaining: 59) == "59s")
        check("Countdown.60", CountdownFormatter.format(remaining: 60) == "1m")
        check("Countdown.3540", CountdownFormatter.format(remaining: 3540) == "59m")
        check("Countdown.3600", CountdownFormatter.format(remaining: 3600) == "60m")
        check("Countdown.7200", CountdownFormatter.format(remaining: 7200) == "120m")

        // MARK: - RefreshInterval 校验

        check("Interval.count", RefreshInterval.allCases.count == 3)
        check("Interval.values", RefreshInterval.allCases.map(\.rawValue) == [30, 60, 120])
        check("Interval.seconds", RefreshInterval.seconds30.seconds == 30 && RefreshInterval.seconds120.seconds == 120)
        check("Interval.default", RefreshInterval.default == .seconds60)
        check("Interval.raw30", RefreshInterval(rawValue: 30) == .seconds30)
        check("Interval.invalid999", RefreshInterval(rawValue: 999) == nil)
        // 存量值校验：0 → 未设置（不回写）；命中档位 → 采用；脏值 → 落默认并要求写回自愈。
        let unset = RefreshInterval.persisted(rawSeconds: 0)
        check("Interval.persisted.unset", unset.interval == .seconds60 && unset.needsRewrite == false)
        let valid = RefreshInterval.persisted(rawSeconds: 120)
        check("Interval.persisted.valid", valid.interval == .seconds120 && valid.needsRewrite == false)
        let dirty = RefreshInterval.persisted(rawSeconds: 45)
        check("Interval.persisted.dirty", dirty.interval == .seconds60 && dirty.needsRewrite)
        let truncated = RefreshInterval.persisted(rawSeconds: 30.7)
        check("Interval.persisted.truncates", truncated.interval == .seconds30 && truncated.needsRewrite == false)
        let negative = RefreshInterval.persisted(rawSeconds: -1)
        check("Interval.persisted.negative", negative.interval == .seconds60 && negative.needsRewrite == false)

        // MARK: - ProviderBalanceState.advanced（独立演化 / stale 保留）

        do {
            let dsOK = BalanceResult(provider: .deepseek, balance: 65.92, currency: .cny, isAvailable: true)

            // 首次成功。
            let s1 = ProviderBalanceState.advanced(provider: .deepseek, previous: nil, incoming: ProviderCapture(result: dsOK), now: now)
            check("State.firstSuccess.value", s1.result?.balance == 65.92)
            check("State.firstSuccess.notStale", s1.isStale == false && s1.failure == nil)

            // 首次即失败：只有 failure，没有 result（不凭空造钱）。
            let s2 = ProviderBalanceState.advanced(provider: .deepseek, previous: nil, incoming: ProviderCapture(failure: .credentialEmpty), now: now)
            check("State.firstFailure.noResult", s2.result == nil)
            check("State.firstFailure.failure", s2.failure == .credentialEmpty)

            // 有旧值再失败：保留旧值 + 标 stale + 记 failure。
            let s3 = ProviderBalanceState.advanced(provider: .deepseek, previous: s1, incoming: ProviderCapture(failure: .fetch("请求超时 (10 秒)")), now: now)
            check("State.stale.keepsValue", s3.result?.balance == 65.92)
            check("State.stale.isStale", s3.isStale == true)
            check("State.stale.recordsFailure", s3.failure == .fetch("请求超时 (10 秒)"))
            check("State.stale.keepsCapturedAt", s3.capturedAt == s1.capturedAt)

            // 恢复：清 failure 与 stale。
            let s4 = ProviderBalanceState.advanced(provider: .deepseek, previous: s3,
                                                  incoming: ProviderCapture(result: BalanceResult(provider: .deepseek, balance: 20, currency: .cny)),
                                                  now: now)
            check("State.recovered.value", s4.result?.balance == 20)
            check("State.recovered.notStale", s4.isStale == false && s4.failure == nil)

            check("State.emptyState", ProviderBalanceState(provider: .opencodeGo).result == nil
                && ProviderBalanceState(provider: .opencodeGo).failure == nil)
        }

        // MARK: - StatusBarPresenter.renderTitle（优先级链）

        do {
            let dsOK = BalanceResult(provider: .deepseek, balance: 65.92, currency: .cny, isAvailable: true)
            let ocOK = BalanceResult(
                provider: .opencodeGo, balance: 16, currency: .percent, usedPercent: 16,
                quotaWindows: [QuotaWindow(id: "5h", label: "5h", usedPercent: 16, status: "ok", resetsAt: now.addingTimeInterval(3600))]
            )
            let dsState = ProviderBalanceState(provider: .deepseek, result: dsOK, capturedAt: now)
            let ocState = ProviderBalanceState(provider: .opencodeGo, result: ocOK, capturedAt: now)

            // 1) configMissing 最高优先级，压过一切可用余额；且不追加 ☕。
            let cfgMissing = StatusBarPresenter.Inputs(
                configMissing: true,
                selectedProvider: .deepseek,
                balances: [.deepseek: dsState, .opencodeGo: ocState],
                caffeinateSession: CaffeinateSession(bucket: .sixtyMinutes, startedAt: now, endAt: now.addingTimeInterval(3600))
            )
            check("Title.configMissing.dominant", StatusBarPresenter.renderTitle(cfgMissing).string == "\u{2009}\u{2009}?kimi")
            check("Title.configMissing.noCoffee", !StatusBarPresenter.renderTitle(cfgMissing).string.contains("\u{2615}"))

            // 2) 选中 DeepSeek：CNY 2 位小数。
            let dsSelected = StatusBarPresenter.Inputs(selectedProvider: .deepseek, balances: [.deepseek: dsState, .opencodeGo: ocState])
            check("Title.deepseek", StatusBarPresenter.renderTitle(dsSelected).string == "\u{2009}\u{2009}¥65.92")

            // 3) 选中 OpenCode Go：rolling 百分比、无标签。
            let ocSelected = StatusBarPresenter.Inputs(selectedProvider: .opencodeGo, balances: [.deepseek: dsState, .opencodeGo: ocState])
            check("Title.opencode.percent", StatusBarPresenter.renderTitle(ocSelected).string == "\u{2009}\u{2009}16%")
            check("Title.opencode.noLabel", !StatusBarPresenter.renderTitle(ocSelected).string.contains("5h"))

            // 4) 选中 provider 失败且无旧值 → ⚠︎ + 短标签。**绝不切到另一个 provider。**
            let dsFailed = ProviderBalanceState(provider: .deepseek, failure: .credentialEmpty)
            let failedInputs = StatusBarPresenter.Inputs(selectedProvider: .deepseek, balances: [.deepseek: dsFailed, .opencodeGo: ocState])
            check("Title.selectedFailure.tag", StatusBarPresenter.renderTitle(failedInputs).string == "\u{2009}\u{2009}⚠︎凭据")
            check("Title.selectedFailure.doesNotBorrowOther", !StatusBarPresenter.renderTitle(failedInputs).string.contains("16%"))
            let dsMissingSection = ProviderBalanceState(provider: .deepseek, failure: .providerMissing)
            check("Title.selectedFailure.configTag",
                  StatusBarPresenter.renderTitle(.init(selectedProvider: .deepseek, balances: [.deepseek: dsMissingSection])).string
                  == "\u{2009}\u{2009}⚠︎配置")
            let dsFetchFail = ProviderBalanceState(provider: .deepseek, failure: .fetch("响应解析失败"))
            check("Title.selectedFailure.noTagForFetch",
                  StatusBarPresenter.renderTitle(.init(selectedProvider: .deepseek, balances: [.deepseek: dsFetchFail])).string
                  == "\u{2009}\u{2009}⚠︎")
            // 另一个 provider 挂了，不影响选中 provider 的标题。
            let otherFailed = ProviderBalanceState(provider: .opencodeGo, failure: .fetch("x"))
            check("Title.otherFailureIgnored",
                  StatusBarPresenter.renderTitle(.init(selectedProvider: .deepseek, balances: [.deepseek: dsState, .opencodeGo: otherFailed])).string
                  == "\u{2009}\u{2009}¥65.92")

            // 5) 尚未采集 → "···"。
            check("Title.empty", StatusBarPresenter.renderTitle(.init()).string == "\u{2009}\u{2009}···")
            check("Title.notSelected.showsPlaceholder",
                  StatusBarPresenter.renderTitle(.init(selectedProvider: .opencodeGo, balances: [.deepseek: dsState])).string
                  == "\u{2009}\u{2009}···")

            // 6) caffeinate：补空格 + ☕ 咖啡色结尾。
            let session = CaffeinateSession(bucket: .sixtyMinutes, startedAt: now, endAt: now.addingTimeInterval(3600))
            let active = StatusBarPresenter.renderTitle(.init(selectedProvider: .deepseek, balances: [.deepseek: dsState], caffeinateSession: session))
            check("Title.active.padded", active.string == "\u{2009}\u{2009} ¥65.92  \u{2615}")
            check("Title.active.coffeeAtEnd", active.string.hasSuffix(" \u{2615}"))
            if let idx = active.string.range(of: "\u{2615}")?.lowerBound {
                let offset = active.string.distance(from: active.string.startIndex, to: idx)
                check("Title.active.coffeeColor",
                      (active.attributes(at: offset, effectiveRange: nil)[.foregroundColor] as? NSColor) == StatusBarPresenter.caffeinateColor)
            } else {
                check("Title.active.coffeeColor", false)
            }
            // 失败分支也带 ☕（与 omp 的 balanceUnavailable 分支一致）。
            let activeFailure = StatusBarPresenter.renderTitle(.init(selectedProvider: .deepseek, balances: [.deepseek: dsFetchFail], caffeinateSession: session))
            check("Title.active.failureCoffee", activeFailure.string == "\u{2009}\u{2009} ⚠︎  \u{2615}")
        }

        // MARK: - StatusBarPresenter.renderChrome

        do {
            check("Chrome.empty", StatusBarPresenter.renderChrome(.init()) == .clear)
            let session = CaffeinateSession(bucket: .thirtyMinutes, startedAt: now, endAt: now.addingTimeInterval(1800))
            let spec = StatusBarPresenter.renderChrome(.init(caffeinateSession: session))
            check("Chrome.active.bg", spec.background == StatusBarPresenter.caffeinateColor)
            check("Chrome.active.tint", spec.contentTint == .white)
            check("Chrome.active.radius", spec.cornerRadius > 0)
            check("Chrome.metrics", StatusBarChromeMetrics.cornerRadius(buttonHeight: 18) == 9)
            check("Chrome.metrics.minimum", StatusBarChromeMetrics.cornerRadius(buttonHeight: 0) == 0.5)
        }

        // MARK: - StatusBarPresenter.renderMenu

        do {
            let dsOK = BalanceResult(provider: .deepseek, balance: 65.92, currency: .cny, isAvailable: true)
            let windows = [
                QuotaWindow(id: "5h", label: "5h", usedPercent: 16, status: "ok", resetsAt: now.addingTimeInterval(3 * 3600 + 15 * 60)),
                QuotaWindow(id: "7d", label: "7d", usedPercent: 22, status: "ok", resetsAt: now.addingTimeInterval(5 * 86_400 + 3 * 3600)),
                QuotaWindow(id: "monthly", label: "月度", usedPercent: 13, status: "ok", resetsAt: now.addingTimeInterval(26 * 86_400)),
            ]
            let ocOK = BalanceResult(provider: .opencodeGo, balance: 16, currency: .percent, usedPercent: 16, quotaWindows: windows)
            // 用量只有合并的一份：today 与「后 5 桶」刻意给不同值，好把两行区分开。
            let lastBucketStats = TokenStats(inputTokens: 1_000, outputTokens: 20, cacheReadTokens: 4_000)
            let daily = DailyUsageSnapshot(
                today: TokenStats(inputTokens: 18_938, outputTokens: 187, cacheReadTokens: 145_024),
                hourly: (0..<HOUR_BUCKET_COUNT).map { index in
                    HourBucket(startMs: 0, endMs: 0,
                               stats: index == HOUR_BUCKET_COUNT - 1 ? lastBucketStats : TokenStats())
                },
                capturedAt: now
            )

            let inputs = StatusBarPresenter.Inputs(
                selectedProvider: .deepseek,
                balances: [
                    .deepseek: ProviderBalanceState(provider: .deepseek, result: dsOK, capturedAt: now),
                    .opencodeGo: ProviderBalanceState(provider: .opencodeGo, result: ocOK, capturedAt: now),
                ],
                daily: daily
            )
            let items = StatusBarPresenter.renderMenu(inputs, now: now)
            let titles = items.map(\.title)

            // 两个 provider 永远都在，顺序固定，header 只有 provider 名（不追加模型名）。
            check("Menu.order.deepseekFirst", titles.first == "DeepSeek")
            check("Menu.hasOpenCodeGo", titles.contains("OpenCode Go"))
            check("Menu.headerOnlyProviderName", titles.firstIndex(of: "DeepSeek")! < titles.firstIndex(of: "OpenCode Go")!)
            check("Menu.headerNoModel", !titles.contains { $0.hasPrefix("DeepSeek (") || $0.hasPrefix("OpenCode Go (") })
            check("Menu.hasBothProvidersEvenIfOneMissing",
                  Array(StatusBarPresenter.renderMenu(.init()).map(\.title).filter { $0 == "DeepSeek" || $0 == "OpenCode Go" }) == ["DeepSeek", "OpenCode Go"])

            // DeepSeek 余额行。
            check("Menu.deepseek.balanceLine", titles.contains("余额 ¥65.92"))
            // OpenCode Go 三窗口进度条（顺序与标签固定）。
            let bars = items.compactMap(\.usageBar)
            check("Menu.opencode.barCount", bars.count == 3)
            check("Menu.opencode.labels", bars.map(\.leftText) == ["5h", "7d", "月度"])
            check("Menu.opencode.percentTexts", bars.map(\.percentText) == ["16%", "22%", "13%"])
            check("Menu.opencode.values", bars.map(\.value) == [16, 22, 13])
            check("Menu.opencode.allOK", bars.allSatisfy(\.isOK))
            check("Menu.opencode.resetTexts", bars.map(\.resetText) == [
                "3h15m 后重置", "5d3h 后重置", "26d 后重置",
            ])

            // 用量：只有一份合并块，位于两个 provider section 之后、「菜单栏显示」之前。
            let todayRow = "今日 · ↑18.9K · ↓187 · ⚡145.0K · 🎯88%"
            let last5hRow = "近 5h · ↑1.0K · ↓20 · ⚡4.0K · 🎯80%"
            check("Menu.usage.todayRow", titles.contains(todayRow))
            check("Menu.usage.last5hRow", titles.contains(last5hRow))
            check("Menu.usage.exactlyOneTodayRow", titles.filter { $0.hasPrefix("今日") }.count == 1)
            check("Menu.usage.exactlyOneLast5hRow", titles.filter { $0.hasPrefix("近 5h") }.count == 1)
            // provider section 里不再有各自的用量行：全菜单只有这两行用量。
            check("Menu.usage.noPerProviderUsage",
                  titles.filter { $0.hasPrefix("今日") || $0.hasPrefix("近 5h") }.count == 2)
            // 「其他」行彻底消失（已经没有「未匹配」这个概念）。
            check("Menu.usage.noOtherRow", !titles.contains { $0.contains("其他") })
            check("Menu.usage.noUnmatchedBucketRow", !titles.contains { $0.hasPrefix("其他 ·") })
            if let todayIdx = titles.firstIndex(of: todayRow),
               let ocIdx = titles.firstIndex(of: "OpenCode Go"),
               let barIdx = titles.firstIndex(of: "菜单栏显示") {
                check("Menu.usage.afterBothProviderSections", todayIdx > ocIdx)
                check("Menu.usage.beforeMenuBarSelection", todayIdx < barIdx)
                check("Menu.usage.last5hDirectlyAfterToday", titles[todayIdx + 1] == last5hRow)
                // 用量块之后再没有进度条行 —— 用量行确实脱离了 provider section。
                check("Menu.usage.noBarsAfterUsageBlock", items[todayIdx...].allSatisfy { $0.usageBar == nil })
            } else {
                check("Menu.usage.blockLocated", false)
            }

            // 空用量也照常渲染一份合并块（全零），不会因为「没有归属」而消失。
            let emptyDaily = DailyUsageSnapshot(today: TokenStats(), hourly: [], capturedAt: now)
            let emptyTitles = StatusBarPresenter.renderMenu(.init(daily: emptyDaily), now: now).map(\.title)
            check("Menu.usage.emptyStillRendersCombined",
                  emptyTitles.contains("今日 · ↑0 · ↓0 · ⚡0 · 🎯0%")
                  && emptyTitles.contains("近 5h · ↑0 · ↓0 · ⚡0 · 🎯0%"))

            // is_available: false → 仍展示金额，并追加 ⚠。
            let unavailable = BalanceResult(provider: .deepseek, balance: 65.92, currency: .cny, isAvailable: false)
            let naItems = StatusBarPresenter.renderMenu(
                .init(balances: [.deepseek: ProviderBalanceState(provider: .deepseek, result: unavailable)]),
                now: now
            )
            check("Menu.deepseek.isAvailableFalse", naItems.map(\.title).contains("余额 ¥65.92 ⚠"))

            // 非 "ok" 窗口：进度条转红 + 行内带出原始 status 串。
            let limitedWindows = [
                QuotaWindow(id: "5h", label: "5h", usedPercent: 16, status: "ok", resetsAt: now.addingTimeInterval(3600)),
                QuotaWindow(id: "7d", label: "7d", usedPercent: 22, status: "ok", resetsAt: now.addingTimeInterval(3600)),
                QuotaWindow(id: "monthly", label: "月度", usedPercent: 13, status: "rate-limited", resetsAt: now.addingTimeInterval(3600)),
            ]
            let limited = BalanceResult(provider: .opencodeGo, balance: 16, currency: .percent, usedPercent: 16, quotaWindows: limitedWindows)
            let limitedBars = StatusBarPresenter.renderMenu(
                .init(balances: [.opencodeGo: ProviderBalanceState(provider: .opencodeGo, result: limited)]),
                now: now
            ).compactMap(\.usageBar)
            check("Menu.limited.okFlags", limitedBars.map(\.isOK) == [true, true, false])
            check("Menu.limited.rawStatusVisible", limitedBars[2].resetText == "rate-limited · 1h0m 后重置")
            check("Menu.limited.okRowUnchanged", limitedBars[0].resetText == "1h0m 后重置")
            check("Menu.limited.segmentRed", UsageBarMenuItemView.segment(for: 13, isOK: false) == .red)
            check("Menu.limited.segmentWouldBeGreen", UsageBarMenuItemView.segment(for: 13, isOK: true) == .green)

            // 段色三档。
            check("Segment.green", UsageBarMenuItemView.segment(for: 0, isOK: true) == .green)
            check("Segment.greenEdge", UsageBarMenuItemView.segment(for: 69.9, isOK: true) == .green)
            check("Segment.yellowLow", UsageBarMenuItemView.segment(for: 70, isOK: true) == .yellow)
            check("Segment.yellowHigh", UsageBarMenuItemView.segment(for: 90, isOK: true) == .yellow)
            check("Segment.redEdge", UsageBarMenuItemView.segment(for: 90.1, isOK: true) == .red)
            check("Segment.red", UsageBarMenuItemView.segment(for: 100, isOK: true) == .red)

            // 进度条最短长度不变量：视图宽取 `minimumWidth` 时条长恰好落在 `minBarWidth` 上。
            let labeledFloor = UsageBarMenuItemView.minTrailingRegionWidth
            check("Menu.bar.minLength.labeled",
                  UsageBarMenuItemView.barWidth(
                      totalWidth: UsageBarMenuItemView.minimumWidth(hasLeftLabel: true, trailingWidth: labeledFloor),
                      hasLeftLabel: true,
                      trailingWidth: labeledFloor
                  ) >= UsageBarMenuItemView.minBarWidth)
            check("Menu.bar.minLength.unlabeled",
                  UsageBarMenuItemView.barWidth(
                      totalWidth: UsageBarMenuItemView.minimumWidth(hasLeftLabel: false, trailingWidth: labeledFloor),
                      hasLeftLabel: false,
                      trailingWidth: labeledFloor
                  ) >= UsageBarMenuItemView.minBarWidth)
            check("Menu.bar.minBarWidth", UsageBarMenuItemView.minBarWidth == 150)
            // 右区文本不得比其他菜单项更贴边：留白 ≥ 菜单内容缩进（分隔线 / 快捷键列停在 ~15pt）。
            check("Menu.bar.trailingRightMargin", UsageBarMenuItemView.trailingRightMargin >= 15)

            // 右区预留宽度：无文本 → 0；短文本落回下限；长文本（含原始 status）按实测加宽且不挤掉进度条。
            check("Menu.bar.trailingNone", UsageBarMenuItemView.trailingWidth(for: nil) == 0)
            check("Menu.bar.trailingEmpty", UsageBarMenuItemView.trailingWidth(for: "") == 0)
            check("Menu.bar.trailingFloor",
                  UsageBarMenuItemView.trailingWidth(for: "1h0m 后重置") == UsageBarMenuItemView.minTrailingRegionWidth)
            let longTrailing = UsageBarMenuItemView.trailingWidth(for: "rate-limited · 26d 后重置")
            check("Menu.bar.trailingLongWidens", longTrailing > UsageBarMenuItemView.minTrailingRegionWidth)
            check("Menu.bar.trailingLongKeepsMinBar",
                  UsageBarMenuItemView.barWidth(
                      totalWidth: UsageBarMenuItemView.minimumWidth(hasLeftLabel: true, trailingWidth: longTrailing),
                      hasLeftLabel: true,
                      trailingWidth: longTrailing
                  ) >= UsageBarMenuItemView.minBarWidth)
            // 三窗口正常形态共用下限 → 条长一致（多行对齐）。
            let normalTrailings = ["4h17m 后重置", "5d3h 后重置", "26d 后重置"].map(UsageBarMenuItemView.trailingWidth(for:))
            check("Menu.bar.normalRowsShareFloor", normalTrailings.allSatisfy { $0 == UsageBarMenuItemView.minTrailingRegionWidth })

            // 失败状态：每个 provider 自己的中文文案出现在自己的 section 里。
            let mixed = StatusBarPresenter.renderMenu(
                .init(
                    selectedProvider: .opencodeGo,
                    balances: [
                        .deepseek: ProviderBalanceState(provider: .deepseek, result: dsOK),
                        .opencodeGo: ProviderBalanceState(provider: .opencodeGo, failure: .providerMissing),
                    ],
                    daily: daily
                ),
                now: now
            )
            let mixedTitles = mixed.map(\.title)
            check("Menu.independent.deepseekStillShown", mixedTitles.contains("余额 ¥65.92"))
            check("Menu.independent.opencodeError", mixedTitles.contains("config 中未找到 provider \"OpenCode Go\""))
            check("Menu.independent.order", (mixedTitles.firstIndex(of: "config 中未找到 provider \"OpenCode Go\"") ?? 0)
                > (mixedTitles.firstIndex(of: "DeepSeek") ?? 0))
            check("Menu.independent.noPlaceholderWhenFailed",
                  mixedTitles.filter { $0 == "余额: ···" }.count == 0)

            // 空凭据文案 + 未采集占位。
            let credEmpty = StatusBarPresenter.renderMenu(
                .init(balances: [.deepseek: ProviderBalanceState(provider: .deepseek, failure: .credentialEmpty)]),
                now: now
            ).map(\.title)
            check("Menu.credEmpty.text", credEmpty.contains("provider \"DeepSeek\" 的 api_key 为空"))
            check("Menu.pending.placeholder", StatusBarPresenter.renderMenu(.init(), now: now).map(\.title).contains("余额: ···"))

            // stale：保留旧值 + 明说「旧值」。
            let stale = StatusBarPresenter.renderMenu(
                .init(balances: [.deepseek: ProviderBalanceState(
                    provider: .deepseek, result: dsOK, failure: .fetch("请求超时 (10 秒)"), isStale: true, capturedAt: now
                )]),
                now: now
            ).map(\.title)
            check("Menu.stale.keepsValue", stale.contains("余额 ¥65.92"))
            check("Menu.stale.labelsOldValue", stale.contains("⚠ 旧值 · 请求超时 (10 秒)"))

            // 「菜单栏显示 ▸」子菜单：两个 radio 项，选中带 ✓。
            guard let displayIdx = items.firstIndex(where: { $0.title == "菜单栏显示" }),
                  let displaySub = items[displayIdx].submenu else {
                check("Menu.menuBarSelection.exists", false)
                return finish(&failures)
            }
            check("Menu.menuBarSelection.exists", true)
            check("Menu.menuBarSelection.count", displaySub.count == 2)
            check("Menu.menuBarSelection.titles", displaySub.map(\.title) == ["DeepSeek ✓", "OpenCode Go"])
            check("Menu.menuBarSelection.actions", displaySub.allSatisfy { $0.action == .selectProvider })
            check("Menu.menuBarSelection.represented", displaySub.map(\.representedProvider) == ["deepseek", "opencode-go"])
            let ocSelectedItems = StatusBarPresenter.renderMenu(.init(selectedProvider: .opencodeGo), now: now)
            let ocDisplaySub = ocSelectedItems.first { $0.title == "菜单栏显示" }?.submenu
            check("Menu.menuBarSelection.checkMoves", ocDisplaySub?.map(\.title) == ["DeepSeek", "OpenCode Go ✓"])

            // Caffeinate 子菜单 + 倒计时行 + 取消守护。
            let caffSub = items.first { $0.title == "阻止系统休眠" }?.submenu
            check("Menu.caffeinate.submenu", caffSub?.map(\.title) == ["30 分钟", "60 分钟", "120 分钟"])
            check("Menu.caffeinate.buckets", caffSub?.map(\.representedBucket) == [30, 60, 120])
            check("Menu.caffeinate.noHeaderWithoutSession", !items.contains { $0.tickable })
            check("Menu.caffeinate.noCancelWithoutSession", !items.contains { $0.action == .caffeinateCancel })
            check("Menu.countdown.notLive", StatusBarPresenter.hasLiveCountdown(items) == false)

            let session = CaffeinateSession(bucket: .sixtyMinutes, startedAt: now, endAt: now.addingTimeInterval(3600))
            let activeItems = StatusBarPresenter.renderMenu(.init(caffeinateSession: session), now: now)
            check("Menu.caffeinate.header", activeItems.contains { $0.title == "☕️ 阻止休眠 · 还剩 60m" && $0.tickable })
            check("Menu.caffeinate.checkedBucket", activeItems.first { $0.title == "阻止系统休眠" }?.submenu?.map(\.title).contains("60 分钟 ✓") == true)
            check("Menu.caffeinate.cancel", activeItems.contains { $0.action == .caffeinateCancel })
            check("Menu.countdown.liveOnlyWithSession", StatusBarPresenter.hasLiveCountdown(activeItems))

            // 底部动作与分隔线。
            check("Menu.actions.settings", items.contains { $0.action == .showSettings && $0.key == "," })
            check("Menu.actions.refresh", items.contains { $0.action == .forceRefresh && $0.key == "r" })
            check("Menu.actions.quitLast", items.last?.action == .quit && items.last?.key == "q")
            check("Menu.hasSepArators", items.contains { $0.title.isEmpty && $0.action == nil && $0.submenu == nil && $0.usageBar == nil })
            check("Menu.usageErrorWhenNoDaily",
                  StatusBarPresenter.renderMenu(.init(lastDailyError: "扫描失败"), now: now).map(\.title).contains("用量: 扫描失败"))
        }

        // MARK: - RefreshController：tick 驱动的状态迁移

        do {
            let daily = DailyUsageSnapshot(
                today: TokenStats(inputTokens: 100, outputTokens: 50, cacheReadTokens: 200),
                hourly: [],
                capturedAt: now
            )
            let dsOK = BalanceResult(provider: .deepseek, balance: 65.92, currency: .cny, isAvailable: true)
            let ocOK = BalanceResult(provider: .opencodeGo, balance: 16, currency: .percent, usedPercent: 16)

            let dsCapture = ProviderCapture(result: dsOK)
            let ocCapture = ProviderCapture(result: ocOK)

            let balanceSource = FakeBalanceSource(next: BalanceCapture(
                perProvider: [.deepseek: dsCapture, .opencodeGo: ocCapture],
                configMissing: false, defaultModel: "OpenCode Go/x", capturedAt: now
            ))
            let dailySource = FakeDailyUsageSource(next: (daily, nil))
            let state = AppState()
            let rc = RefreshController(balanceSource: balanceSource, dailySource: dailySource, state: state)

            sync { await rc.tick() }
            check("Refresh.tick.balanceCalls", balanceSource.callCount == 1)
            check("Refresh.tick.dailyCalls", dailySource.callCount == 1)
            check("Refresh.tick.deepseek", state.balance(for: .deepseek).result?.balance == 65.92)
            check("Refresh.tick.opencode", state.balance(for: .opencodeGo).result?.usedPercent == 16)
            check("Refresh.tick.daily", state.daily?.today.inputTokens == 100)
            check("Refresh.tick.noConfigMissing", state.configMissing == false)
            check("Refresh.tick.selectedProviderUnchanged", state.selectedProvider == .deepseek)

            // config.toml 不可读 → 全局降级，两个都失败，但**不切换菜单栏 provider**。
            balanceSource.next = .allFailed(.configUnreadable("未找到 /x/config.toml"), now: now)
            sync { await rc.tick() }
            check("Refresh.configMissing.flag", state.configMissing == true)
            check("Refresh.configMissing.deepseek", state.balance(for: .deepseek).failure == .configUnreadable("未找到 /x/config.toml"))
            check("Refresh.configMissing.opencode", state.balance(for: .opencodeGo).failure?.statusBarTag == "配置")
            check("Refresh.configMissing.noAutoSwitch", state.selectedProvider == .deepseek)
            // 旧值被保留并标 stale（配置读不到时仍能看到最后一次的钱，但文案说明是旧值）。
            check("Refresh.configMissing.keepsStaleValue", state.balance(for: .deepseek).result?.balance == 65.92
                && state.balance(for: .deepseek).isStale)

            // 安装新值：失败不污染另一个 provider。
            balanceSource.next = BalanceCapture(
                perProvider: [
                    .deepseek: ProviderCapture(failure: .credentialEmpty),
                    .opencodeGo: ProviderCapture(result: BalanceResult(provider: .opencodeGo, balance: 22, currency: .percent, usedPercent: 22)),
                ],
                configMissing: false, defaultModel: nil, capturedAt: now
            )
            sync { await rc.tick() }
            check("Refresh.independent.deepseekFailure", state.balance(for: .deepseek).failure == .credentialEmpty)
            check("Refresh.independent.opencodeUpdated", state.balance(for: .opencodeGo).result?.usedPercent == 22)
            check("Refresh.independent.opencodeNoFailure", state.balance(for: .opencodeGo).failure == nil)
            check("Refresh.independent.configRecovered", state.configMissing == false)

            // 缺键 = providerMissing（防御性）。
            balanceSource.next = BalanceCapture(
                perProvider: [.deepseek: dsCapture],
                configMissing: false, defaultModel: nil, capturedAt: now
            )
            sync { await rc.tick() }
            check("Refresh.missingKey.opencode", state.balance(for: .opencodeGo).failure == .providerMissing)
            check("Refresh.missingKey.deepseek", state.balance(for: .deepseek).result?.balance == 65.92)

            // 用户切换菜单栏 provider：tick 不会把它改回去。
            state.setSelectedProvider(.opencodeGo)
            balanceSource.next = BalanceCapture(
                perProvider: [.deepseek: dsCapture, .opencodeGo: ProviderCapture(failure: .fetch("请求超时 (10 秒)"))],
                configMissing: false, defaultModel: nil, capturedAt: now
            )
            sync { await rc.tick() }
            check("Refresh.userChoicePreserved", state.selectedProvider == .opencodeGo)
            check("Refresh.userChoice.stale", state.balance(for: .opencodeGo).isStale)
            check("Refresh.userChoice.otherUnaffected", state.balance(for: .deepseek).result?.balance == 65.92)

            // reader / aggregator 异常走 lastDailyError，不影响余额。
            dailySource.next = (nil, .scanError("扫描失败"))
            balanceSource.next = BalanceCapture(perProvider: [.deepseek: dsCapture, .opencodeGo: ocCapture],
                                                configMissing: false, defaultModel: nil, capturedAt: now)
            sync { await rc.tick() }
            check("Refresh.dailyError", state.lastDailyError == "扫描失败")
            check("Refresh.dailyError.keepsBalance", state.balance(for: .deepseek).result?.balance == 65.92)
            dailySource.next = (daily, nil)
            sync { await rc.refreshDaily() }
            check("Refresh.dailyErrorCleared", state.lastDailyError == nil && state.daily != nil)

            // refreshBalance 只走余额管线。
            let dailyCallsBefore = dailySource.callCount
            sync { await rc.refreshBalance() }
            check("Refresh.refreshBalance.doesNotTouchDaily", dailySource.callCount == dailyCallsBefore)
        }

        // MARK: - SleepGuard（FakeIOPMAssertionAdapter + RecordingSessionExpiryTimer）

        MainActor.assumeIsolated {
            do {
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                let expiry = RecordingSessionExpiryTimer()
                let sleepGuard = SleepGuard(state: state, adapter: adapter, expiry: expiry)
                let session = sleepGuard.start(bucket: .sixtyMinutes)
                check("SleepGuard.start.active", sleepGuard.isActive)
                check("SleepGuard.start.stateSession", state.caffeinateSession?.bucket == .sixtyMinutes)
                check("SleepGuard.start.schedulesExpiryAtEnd", expiry.scheduledAt == session.endAt)
                check("SleepGuard.start.acquiredOnce", adapter.acquired.count == 1)
                check("SleepGuard.start.duration", abs(session.endAt.timeIntervalSince(session.startedAt) - 3600) < 1e-6)
            }
            do {
                // 到期：一次唤醒即释放，不依赖任何周期性 ticker。
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                let expiry = RecordingSessionExpiryTimer()
                var clock = Date()
                let sleepGuard = SleepGuard(state: state, adapter: adapter, expiry: expiry, now: { clock })
                let session = sleepGuard.start(bucket: .thirtyMinutes)
                clock = session.endAt.addingTimeInterval(1)
                expiry.fire()
                check("SleepGuard.expiry.releases", adapter.released.count == 1)
                check("SleepGuard.expiry.inactive", sleepGuard.isActive == false)
                check("SleepGuard.expiry.stateClear", state.caffeinateSession == nil)
            }
            do {
                // 提前触发（时钟回拨）不误释放：按剩余时间重排。
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                let expiry = RecordingSessionExpiryTimer()
                let clock = Date()
                let sleepGuard = SleepGuard(state: state, adapter: adapter, expiry: expiry, now: { clock })
                let session = sleepGuard.start(bucket: .thirtyMinutes)
                expiry.fire()
                check("SleepGuard.earlyFire.keepsSession", sleepGuard.isActive && state.caffeinateSession != nil)
                check("SleepGuard.earlyFire.reschedules", expiry.scheduleCount == 2 && expiry.scheduledAt == session.endAt)
                check("SleepGuard.earlyFire.noRelease", adapter.released.isEmpty)
            }
            do {
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                let expiry = RecordingSessionExpiryTimer()
                let sleepGuard = SleepGuard(state: state, adapter: adapter, expiry: expiry)
                _ = sleepGuard.start(bucket: .thirtyMinutes)
                sleepGuard.cancel()
                check("SleepGuard.cancel.inactive", sleepGuard.isActive == false)
                check("SleepGuard.cancel.stateClear", state.caffeinateSession == nil)
                check("SleepGuard.cancel.noPendingExpiry", expiry.scheduledAt == nil)
                check("SleepGuard.cancel.released", adapter.released.count == 1)
            }
            do {
                // acquire 失败：不持有 assertion、不暴露 session、也不留下任何排程。
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                adapter.failNext = true
                let expiry = RecordingSessionExpiryTimer()
                let sleepGuard = SleepGuard(state: state, adapter: adapter, expiry: expiry)
                _ = sleepGuard.start(bucket: .sixtyMinutes)
                check("SleepGuard.acquireFail.inactive", sleepGuard.isActive == false)
                check("SleepGuard.acquireFail.stateClear", state.caffeinateSession == nil)
                check("SleepGuard.acquireFail.noSchedule", expiry.scheduleCount == 0)
                check("SleepGuard.acquireFail.noRelease", adapter.released.isEmpty)
            }
            do {
                // 覆盖到新档位：释放旧 assertion 并按新 endAt 重排。
                let state = AppState()
                let adapter = FakeIOPMAssertionAdapter()
                let expiry = RecordingSessionExpiryTimer()
                let sleepGuard = SleepGuard(state: state, adapter: adapter, expiry: expiry)
                _ = sleepGuard.start(bucket: .thirtyMinutes)
                let firstPair = adapter.acquired.last!
                let second = sleepGuard.start(bucket: .oneTwentyMinutes)
                check("SleepGuard.restart.released", adapter.released.contains { $0.system == firstPair.system })
                check("SleepGuard.restart.acquiredTwice", adapter.acquired.count == 2)
                check("SleepGuard.restart.bucket", state.caffeinateSession?.bucket == .oneTwentyMinutes)
                check("SleepGuard.restart.reschedules", expiry.scheduleCount == 2 && expiry.scheduledAt == second.endAt)
            }
        }

        // MARK: - LogoCatalog / 落地资源

        do {
            let repoRoot = FileManager.default.currentDirectoryPath
            let needed: [(ProviderID, String)] = [
                (.deepseek, "Resources/provider_deepseek@2x.png"),
                (.deepseek, "Resources/provider_deepseek@3x.png"),
                (.opencodeGo, "Resources/provider_opencode_go@2x.png"),
                (.opencodeGo, "Resources/provider_opencode_go@3x.png"),
            ]
            let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            for (pid, name) in needed {
                let url = URL(fileURLWithPath: "\(repoRoot)/\(name)")
                guard let data = try? Data(contentsOf: url), data.count >= 8 else {
                    check("Logo.present.\(pid.rawValue).\(name)", false)
                    continue
                }
                check("Logo.signature.\(name)", [UInt8](data.prefix(8)) == png)
                let img = NSImage(contentsOf: url)
                check("Logo.nsimage.\(name)", img != nil)
                if let img {
                    img.setValue(true, forKey: "template")
                    // 注意：NSImage 的 KVC key 是 'template' 而不是 'isTemplate'（ObjC property 名）。
                    check("Logo.template.\(name)", img.isTemplate)
                }
            }
            // 未匹配 provider → nil（宁可只显示文字，也不借用别家 logo）。
            check("Logo.baseName.deepseek", LogoCatalog.assetBaseName(for: .deepseek) == "provider_deepseek")
            check("Logo.baseName.opencodeGo", LogoCatalog.assetBaseName(for: .opencodeGo) == "provider_opencode_go")
            check("Logo.baseName.unknownNil", LogoCatalog.assetBaseName(for: .unknown) == nil)
            check("Logo.image.unknownNil", LogoCatalog.image(for: .unknown) == nil)
            // 无 Resources 的裸二进制（swift run）下不应崩，且未知 provider 仍为 nil。
            let availability = LogoCatalog.debugAssertsAvailable(bundle: .main)
            check("Logo.debugAsserts.keys", Set(availability.keys) == Set(ProviderID.allCases.map { String(describing: $0) }))
        }

        return finish(&failures)
    }

    /// 统一收尾：0 = 全部通过，1 = 有失败。
    private static func finish(_ failures: inout [String]) -> Int {
        if failures.isEmpty {
            print("[self-check] OK (全部通过)")
            return 0
        }
        print("[self-check] FAIL (\(failures.count)):")
        for f in failures { print("  - \(f)") }
        return 1
    }
}

/// SelfCheck 内 async 桥接用的单槽盒子。
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    private var v: T?
    private let lock = NSLock()
    init(_ initial: T?) { self.v = initial }
    func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return v }
}

private extension Result {
    /// 成功时的值（`check` 断言用）。
    var value: Success? {
        if case .success(let v) = self { return v }
        return nil
    }

    /// 失败时的 `HTTPError`（断言网络 / 解码失败用）；成功或非 HTTP 错误时为 nil。
    var failure: HTTPError? {
        if case .failure(let e) = self { return e as? HTTPError }
        return nil
    }
}
