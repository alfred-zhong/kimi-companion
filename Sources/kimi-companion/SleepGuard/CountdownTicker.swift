import Foundation

/// 1Hz 倒计时驱动：`start(interval:onTick:)` 启动一个 Timer，`onTick` 周期性被调用；`stop()` 停。
///
/// 唯一的消费者是「菜单打开期间才存在」的倒计时行，因此由 `StatusBarController` 随菜单生命周期
/// 启停 —— 菜单关闭时 0 次唤醒。`SleepGuard` 不持有它（那边走一次性到期定时器）。
@MainActor
public protocol CountdownTicker: AnyObject {
    func start(interval: TimeInterval, onTick: @escaping @MainActor () -> Void)
    func stop()
}

/// 生产实现：`Timer` + `RunLoop.main` 的 `.common` 模式。`@MainActor` 化后无需显式指定 runloop。
@MainActor
public final class TimerCountdownTicker: CountdownTicker {
    private var timer: Timer?

    nonisolated public init() {}

    public func start(interval: TimeInterval, onTick: @escaping @MainActor () -> Void) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                onTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
