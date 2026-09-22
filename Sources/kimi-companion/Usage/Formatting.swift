import Foundation

/// token 数的紧凑文案：K/M/B 进位，始终保留 1 位小数。
public enum CompactFormatter {
    /// `999_950 → "1.0M"`（避免出现 `1000K`）。
    public static func format(_ n: Int) -> String {
        let absN = abs(n)
        if absN < 1_000 { return "\(n)" }
        if absN < 1_000_000 {
            if absN >= 999_500 { return "1.0M" }
            return trimNumber(String(Double(n) / 1_000)) + "K"
        }
        if absN < 1_000_000_000 {
            return trimNumber(String(Double(n) / 1_000_000)) + "M"
        }
        return trimNumber(String(Double(n) / 1_000_000_000)) + "B"
    }

    /// 只处理数字字符串，保留 1 位小数（`"1.0"` / `"1.5"` / `"12.3"`）。
    private static func trimNumber(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        let after = s.index(after: dot)
        let frac = s[after...]
        if frac.isEmpty { return String(s[..<dot]) }
        return String(s[..<after]) + String(frac.prefix(1))
    }
}
