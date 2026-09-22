import Foundation

/// 会话到期驱动：`schedule(at:onFire:)` 在指定时刻唤醒一次（只一次）；`cancel()` 撤销。
///
/// `SleepGuard` 用它释放 IOPMAssertion ——「到期」是一次性事件，不是周期性轮询。
/// 先前若用 1Hz ticker，最长 120 分钟的会话会白造 7200 次唤醒，只为发现这一件事。
@MainActor
public protocol SessionExpiryTimer: AnyObject {
    /// 排程到期回调；重复调用以后一次为准（旧的排程被撤销）。
    func schedule(at date: Date, onFire: @escaping @MainActor () -> Void)
    func cancel()
}

/// 生产实现：`Timer`（一次性）+ `RunLoop.main` 的 `.common` 模式。
@MainActor
public final class LiveSessionExpiryTimer: SessionExpiryTimer {
    private var timer: Timer?

    nonisolated public init() {}

    public func schedule(at date: Date, onFire: @escaping @MainActor () -> Void) {
        cancel()
        // systemUptime 基准的 Timer 在系统睡眠后会立即补触发，正是这里想要的语义。
        let t = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { onFire() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

/// 测试用 Fake：不启 Timer，只记录排程时刻与回调，由测试手动 `fire()`。
/// `cancelCount` 只数显式 `cancel()`，`schedule(at:)` 覆盖旧排程不计入。
@MainActor
public final class RecordingSessionExpiryTimer: SessionExpiryTimer {
    public private(set) var scheduledAt: Date?
    public private(set) var scheduleCount = 0
    public private(set) var cancelCount = 0
    private var onFire: (@MainActor () -> Void)?

    public init() {}

    public func schedule(at date: Date, onFire: @escaping @MainActor () -> Void) {
        scheduleCount += 1
        scheduledAt = date
        self.onFire = onFire
    }

    public func cancel() {
        cancelCount += 1
        scheduledAt = nil
        onFire = nil
    }

    /// 模拟「到点了」：调用当前排程的回调。
    public func fire() {
        onFire?()
    }
}
