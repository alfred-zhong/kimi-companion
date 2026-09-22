import Foundation

/// provider 内联 `api_key` 的来源。由 `TomlCredentialSource` 从 config.toml 实现。
///
/// 与 omp-companion 的差别：那边由偏好面板（`SettingsStore` / UserDefaults）实现，
/// 这边只认 config.toml。协议形状刻意保持一致（`resolve(_ name: String) -> String?`），
/// 使 `BalanceProvider` 的实现保持平行。
///
/// `name` 是 `[providers.<name>]` 段名，逐字（`"OpenCode Go"` 含空格）。
/// 空 / 全空白 / 仅 `api_key_env` 一律返回 nil（等于「没有凭据」）。
public protocol CredentialSource: Sendable {
    func resolve(_ name: String) -> String?
}
