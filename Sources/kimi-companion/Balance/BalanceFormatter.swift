import Foundation

/// 余额文案格式化：`statusBarText` 给状态栏标题（精简），`menuBarText` 给下拉菜单。
public enum BalanceFormatter {
    /// 状态栏标题文案：CNY → `¥65.92`（2 位小数）；percent → `16%`（只显示**已用**，不带标签、不带重置时间）。
    public static func statusBarText(_ result: BalanceResult) -> String {
        switch result.currency {
        case .cny:
            return String(format: "¥%.2f", result.balance)
        case .usd:
            return String(format: "$%.2f", result.balance)
        case .percent:
            let used = Int((result.usedPercent ?? max(0, 100 - result.balance)).rounded())
            return "\(used)%"
        }
    }

    /// 下拉菜单里的数值文案；当前与状态栏同形（百分比不带重置时间，重置另起一列由 `UsageBarMenuItemView` 画）。
    public static func menuBarText(_ result: BalanceResult) -> String {
        statusBarText(result)
    }

    public static func formatHMS(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return "\(h)h\(m)m"
    }

    /// 倒计时文案：≥24h 用 `XdYh`（避免 weekly 窗口显示 `167h59m`），否则 `HhMm`；无空格，与状态栏 `YhYm` 同风格。
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let day = total / 86400
        if day >= 1 {
            let h = (total % 86400) / 3600
            return h > 0 ? "\(day)d\(h)h" : "\(day)d"
        }
        return formatHMS(TimeInterval(total))
    }
}
