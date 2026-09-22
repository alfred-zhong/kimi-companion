import Foundation
import TOMLKit

/// config.toml 里单个 `[providers.<name>]` 段的可见字段。
public struct KimiProviderEntry: Sendable, Equatable {
    /// 段名，逐字（含空格，如 `OpenCode Go`）。
    public let name: String
    public let baseURL: String?
    /// 内联 `api_key`；空 / 全空白 → nil（等于「没有凭据」）。
    public let apiKey: String?
    /// 该段是否用 `api_key_env` 指定凭据。本 app 不解析环境变量，遇此标记视为凭据不可解析。
    public let usesAPIKeyEnv: Bool

    public init(name: String, baseURL: String?, apiKey: String?, usesAPIKeyEnv: Bool) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.usesAPIKeyEnv = usesAPIKeyEnv
    }
}

/// `~/.kimi-code/config.toml` 中本 app 关心的部分。
public struct KimiConfig: Sendable, Equatable {
    /// `default_model`，形如 `OpenCode Go/deepseek-v4.1-flash`。
    public let defaultModel: String?
    /// 段名 → 条目。段名保留原样大小写与空格。
    public let providers: [String: KimiProviderEntry]

    public init(defaultModel: String?, providers: [String: KimiProviderEntry]) {
        self.defaultModel = defaultModel
        self.providers = providers
    }

    public func provider(_ name: String) -> KimiProviderEntry? { providers[name] }
}

/// 一次 config.toml 读取的结果。
public enum KimiConfigLoad: Sendable, Equatable {
    case loaded(KimiConfig)
    /// 文件不存在 / 无权限 / 非 UTF-8；reason 是可直接展示的中文文案。
    case unreadable(String)
    /// 文件可读但 TOML 非法。
    case malformed

    public var config: KimiConfig? {
        if case .loaded(let c) = self { return c }
        return nil
    }
}

/// 读 kimi-code 的 `~/.kimi-code/config.toml`。
///
/// 只做一件事：把 `default_model` 与 `[providers.*]` 段里的 `base_url` / `api_key` 读出来。
/// **不读** `api_key_env`（不调用 `getenv`）、不读 Keychain、不读本地 kimi-code HTTP server
/// （`~/.kimi-code/server/instances/*.json`、`server.token`、`mcp.json` 一律不碰）。
public struct KimiConfigSource: Sendable {
    public let configPath: String

    public init(homeDir: String = NSHomeDirectory()) {
        self.configPath = "\(homeDir)/.kimi-code/config.toml"
    }

    /// 显式指定路径（SelfCheck 用临时文件）。
    public init(configPath: String) {
        self.configPath = configPath
    }

    public func load() -> KimiConfigLoad {
        guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return .unreadable("未找到 \(configPath)")
        }
        guard let root = try? TOMLTable(string: raw) else {
            return .malformed
        }
        var entries: [String: KimiProviderEntry] = [:]
        if let providersTable = root["providers"]?.table {
            for name in providersTable.keys {
                // `.table` 是 TOMLKit 的唯一正确取法；`as? TOMLTable` 恒为 nil（subscript 返回 TOMLValueConvertible?）。
                guard let entry = providersTable[name]?.table else { continue }
                let inlineKey = entry["api_key"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                let envName = entry["api_key_env"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                entries[name] = KimiProviderEntry(
                    name: name,
                    baseURL: entry["base_url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: (inlineKey?.isEmpty == false) ? inlineKey : nil,
                    usesAPIKeyEnv: (envName?.isEmpty == false)
                )
            }
        }
        return .loaded(KimiConfig(defaultModel: root["default_model"]?.string, providers: entries))
    }
}

/// 由已解析的 `KimiConfig` 提供 provider 凭据的 `CredentialSource`。
///
/// 与 omp-companion 的区别：那边凭据来自偏好面板（UserDefaults），这边只认 config.toml 的内联
/// `api_key`。协议形状保持不变（`resolve(_ name: String) -> String?`），
/// 因此 `BalanceProvider` 的实现可以保持平行。
/// `name` 是 `[providers.<name>]` 段名，逐字（如 `OpenCode Go`）。
public struct TomlCredentialSource: CredentialSource {
    public let config: KimiConfig?

    public init(config: KimiConfig?) {
        self.config = config
    }

    public func resolve(_ name: String) -> String? {
        config?.provider(name)?.apiKey
    }
}
