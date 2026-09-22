import Foundation

public let HOUR_BUCKET_COUNT = 12
public let HOUR_MS: Int64 = 3600 * 1000

/// 把 usage 事件流按「当日」+「12 个滑动小时桶」聚合成**一份合并快照**。
///
/// 不按 provider / model 区分：所有事件无条件求和（ADR-0006）。
public struct HourlyAggregator: Sendable {
    public init() {}

    public func aggregate(events: [UsageEvent], nowMs: Int64, todayStartMs: Int64) -> DailyUsageSnapshot {
        // 桶边界：index 0 最旧（endMs = nowMs − 11h），末位最新（endMs = nowMs），
        // 区间左开右闭 (startMs, endMs]。与下面的 `idx = 11 - floor(hoursAgo)` 同向：
        // 最新的事件落 index 11（最新桶），最旧的仍可入桶的事件落 index 0。
        let boundaries: [(startMs: Int64, endMs: Int64)] = (0..<HOUR_BUCKET_COUNT).map { index in
            let endMs = nowMs - Int64(HOUR_BUCKET_COUNT - 1 - index) * HOUR_MS
            return (endMs - HOUR_MS, endMs)
        }

        var today = TokenStats()
        var slots = Self.emptySlots()

        for ev in events {
            // 当日计入：事件 time ≥ 本地零点。
            guard ev.tsMs >= todayStartMs else { continue }
            let stats = ev.stats
            today += stats

            // 小时桶落位：hoursAgo ∈ [0, 12)
            let hoursAgo = Double(nowMs - ev.tsMs) / Double(HOUR_MS)
            guard hoursAgo >= 0, hoursAgo < Double(HOUR_BUCKET_COUNT) else { continue }
            let idx = HOUR_BUCKET_COUNT - 1 - Int(floor(hoursAgo))
            guard idx >= 0, idx < HOUR_BUCKET_COUNT else { continue }
            slots[idx] += stats
        }

        let hours = boundaries.enumerated().map { offset, bounds in
            HourBucket(startMs: bounds.startMs, endMs: bounds.endMs, stats: slots[offset])
        }

        return DailyUsageSnapshot(
            today: today,
            hourly: hours,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)
        )
    }

    private static func emptySlots() -> [TokenStats] {
        Array(repeating: TokenStats(), count: HOUR_BUCKET_COUNT)
    }
}
