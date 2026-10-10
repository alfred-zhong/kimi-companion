import Foundation

/// provider 内联 `api_key` 的来源。由 `TomlCredentialSource` 从 config.toml 实现。
///
/// 与 omp-companion 的差别：那边由偏好面板（`SettingsStore` / UserDefaults）实现，
/// 这边只认 config.toml。协议形状刻意保持一致（`resolve(_ name: String) -> String?`），
/// 使 `BalanceProvider` 的实现保持平行。
///
/// `name` 是**凭据路径**：裸段名（`"OpenCode Go"` 含空格，逐字）查 `[providers.<段名>]`；
/// `services.<段名>` 查 kimi-code 的内置工具服务段（`[services.moonshot_search]`）——
/// 后者是给 `Kimi` 开的例外（ADR-0008），不是通用凭据来源。
/// 空 / 全空白 / 仅 `api_key_env` 一律返回 nil（等于「没有凭据」）。
public protocol CredentialSource: Sendable {
    func resolve(_ name: String) -> String?
}
