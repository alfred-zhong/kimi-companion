import Foundation

/// DeepSeek 峰谷计价：纯本地时钟推断，不参与任何 provider 抓取，也不进 `BalanceResult`。
///
/// 规则来源：DeepSeek 官方定价页（2026-08-23 起生效）——
/// 峰时 = 工作日（周一至周五）北京时间 `09:00–12:00`、`14:00–18:00`；
/// 其余全部为低谷，**包括 `12:00–14:00`、周末全天与中国法定节假日全天**；峰时单价为低谷的 2 倍。
///
/// 时区固定 `Asia/Shanghai`（计费按 UTC 定义，北京 = UTC+8 无夏令时），不跟随本机时区。
/// 节假日表只覆盖 2026 / 2027（`docs/adr/0011-deepseek-pricing-period.md`）：
/// 表外年份一律返回 `.unknown`，界面显式说明，绝不猜。
public enum DeepSeekPricing {

    /// 峰谷三态。`.unknown` 只表示「该年份不在内置节假日表内」，不是抓取失败。
    public enum Period: Equatable, Sendable {
        case peak
        case offPeak
        case unknown
    }

    /// 峰时段（当日分钟数，左闭右开）。
    static let peakWindows: [Range<Int>] = [9 * 60..<12 * 60, 14 * 60..<18 * 60]

    /// 全部可能的状态切换点（当日分钟数）：零点（工作日 / 节假日切换）+ 四个窗口边界。
    static let boundaryMinutes: [Int] = [0, 9 * 60, 12 * 60, 14 * 60, 18 * 60]

    public static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    // MARK: - 节假日表

    /// 年份 → 放假日期（`MM-DD`）。只收「放假」的日子：调休上班的周末不在此表，
    /// 因为 DeepSeek 明确周末全天空闲，周末判定独立成立。
    ///
    /// 来源：国办发明电〔2025〕7 号（2026）、国办发明电〔2026〕10 号（2027）。
    /// 每年 11 月前后国务院公布次年安排，届时补表并升版本。
    static let holidayTable: [Int: Set<String>] = [
        2026: [
            // 元旦 1/1–1/3
            "01-01", "01-02", "01-03",
            // 春节 2/15–2/23
            "02-15", "02-16", "02-17", "02-18", "02-19", "02-20", "02-21", "02-22", "02-23",
            // 清明 4/4–4/6
            "04-04", "04-05", "04-06",
            // 劳动节 5/1–5/5
            "05-01", "05-02", "05-03", "05-04", "05-05",
            // 端午 6/19–6/21
            "06-19", "06-20", "06-21",
            // 中秋 9/25–9/27
            "09-25", "09-26", "09-27",
            // 国庆 10/1–10/7
            "10-01", "10-02", "10-03", "10-04", "10-05", "10-06", "10-07",
        ],
        2027: [
            // 元旦 1/1–1/3
            "01-01", "01-02", "01-03",
            // 春节 2/5–2/13
            "02-05", "02-06", "02-07", "02-08", "02-09", "02-10", "02-11", "02-12", "02-13",
            // 清明 4/3–4/5
            "04-03", "04-04", "04-05",
            // 劳动节 5/1–5/5
            "05-01", "05-02", "05-03", "05-04", "05-05",
            // 端午 6/9
            "06-09",
            // 中秋 9/15
            "09-15",
            // 国庆 10/1–10/7
            "10-01", "10-02", "10-03", "10-04", "10-05", "10-06", "10-07",
        ],
    ]

    // MARK: - 判定

    /// 某时刻属于峰时 / 低谷 / 未知。周末与节假日一律低谷，与具体小时无关。
    public static func period(at date: Date) -> Period {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday,
              let holidays = holidayTable[year]
        else { return .unknown }

        // `weekday`：1 = 周日，7 = 周六（与 firstWeekday 无关）。
        if weekday == 1 || weekday == 7 { return .offPeak }
        if holidays.contains(String(format: "%02d-%02d", month, day)) { return .offPeak }

        let minutes = hour * 60 + minute
        return peakWindows.contains { $0.contains(minutes) } ? .peak : .offPeak
    }

    /// 严格晚于 `date` 的下一个状态切换点。表外年份可能一路 `.unknown`，此时返回 nil。
    ///
    /// 所有切换都落在整分（零点 + 四个窗口边界），因此只需枚举未来 8 天里的这几个时刻，
    /// 比较「切换前一秒」与「切换时刻」的状态即可，不必逐分钟扫描。
    public static func nextTransition(after date: Date) -> (date: Date, period: Period)? {
        let startOfDay = calendar.startOfDay(for: date)
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else { continue }
            for minutes in boundaryMinutes {
                guard let instant = calendar.date(byAdding: .minute, value: minutes, to: day),
                      instant > date
                else { continue }
                let after = period(at: instant)
                if period(at: instant.addingTimeInterval(-1)) != after {
                    return (instant, after)
                }
            }
        }
        return nil
    }

    // MARK: - 文案

    /// 菜单 / tooltip 用的状态名。低谷刻意不叫「空闲」，与字形 `谷` 一一对应。
    public static func label(_ period: Period) -> String {
        switch period {
        case .peak: return "高峰"
        case .offPeak: return "低谷"
        case .unknown: return "未知"
        }
    }

    /// 菜单栏字形。`.unknown` 返回 nil：宁可静默，也不让 `?` 与失败态 `⚠︎` 抢语义。
    public static func glyph(_ period: Period) -> String? {
        switch period {
        case .peak: return "峰"
        case .offPeak: return "谷"
        case .unknown: return nil
        }
    }

    /// 该时刻所在年份（北京时间）。
    public static func year(at date: Date) -> Int {
        calendar.component(.year, from: date)
    }

    public static func tableCovers(_ year: Int) -> Bool {
        holidayTable[year] != nil
    }
}
