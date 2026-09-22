import Foundation

/// 守护会话剩余时间文案。
///
/// - `≥ 1 分钟`：显示 `Xm`（逐分钟，分钟整数）
/// - `< 1 分钟`：显示 `Xs`（逐秒，至少 1s）
public enum CountdownFormatter {
    public static func format(remaining: TimeInterval) -> String {
        if remaining <= 0 { return "0s" }
        if remaining < 60 {
            return "\(max(1, Int(remaining.rounded())))s"
        }
        return "\(Int(remaining / 60))m"
    }
}
