import Foundation

/// 测试用 Fake `BalanceSource`：可编程式指定返回的 `BalanceCapture`。
public final class FakeBalanceSource: BalanceSource, @unchecked Sendable {
    public var next: BalanceCapture
    public var callCount = 0

    public init(next: BalanceCapture) {
        self.next = next
    }

    public func capture(now: Date) async -> BalanceCapture {
        callCount += 1
        return next
    }
}

/// 测试用 Fake `DailyUsageSource`：同上。
public final class FakeDailyUsageSource: DailyUsageSource, @unchecked Sendable {
    public var next: (DailyUsageSnapshot?, SnapshotError?)
    public var callCount = 0

    public init(next: (DailyUsageSnapshot?, SnapshotError?) = (nil, nil)) {
        self.next = next
    }

    public func capture(now: Date) async -> (DailyUsageSnapshot?, SnapshotError?) {
        callCount += 1
        return next
    }
}
