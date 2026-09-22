import Foundation

/// 阻止系统睡眠 / 显示器睡眠的守护：基于 IOPMAssertion。
///
/// 单会话模型：调 `start(bucket:)` 即创建 / 续期会话；调 `cancel()` 立即释放。
/// 不持久化；进程退出即结束。
///
/// `@MainActor` 化后所有方法同步在主线程，无需 NSLock / `DispatchQueue.main.async`。
/// 资源管理走 `IOPMAssertionAdapter`，到期释放走 `SessionExpiryTimer`（一次性唤醒，不轮询）。
@MainActor
public final class SleepGuard {
    private let state: AppState
    private let adapter: IOPMAssertionAdapter
    private let expiry: SessionExpiryTimer
    private let now: () -> Date
    private var currentAssertions: (system: UInt32, display: UInt32) = (0, 0)

    public init(
        state: AppState,
        adapter: IOPMAssertionAdapter = LiveIOPMAssertionAdapter(),
        expiry: SessionExpiryTimer = LiveSessionExpiryTimer(),
        now: @escaping () -> Date = Date.init
    ) {
        self.state = state
        self.adapter = adapter
        self.expiry = expiry
        self.now = now
    }

    /// 当前是否持有活跃 assertion。
    public var isActive: Bool {
        currentAssertions.system != 0 || currentAssertions.display != 0
    }

    /// 启动或覆盖到指定档位（`endAt = now + duration`）。
    @discardableResult
    public func start(bucket: CaffeinateBucket) -> CaffeinateSession {
        // 先撤销旧排程并释放旧 assertion。
        expiry.cancel()
        if isActive {
            adapter.release(system: currentAssertions.system, display: currentAssertions.display)
            currentAssertions = (0, 0)
        }
        let start = now()
        let end = start.addingTimeInterval(TimeInterval(bucket.minutes) * 60)
        let pair = adapter.acquire(name: "kimi-companion: \(bucket.minutes) 分钟")
        currentAssertions = pair
        if pair.system == 0 || pair.display == 0 {
            // acquire 失败：不暴露 session，也不留下任何排程。
            state.setCaffeinateSession(nil)
            return CaffeinateSession(bucket: bucket, startedAt: start, endAt: end)
        }
        let session = CaffeinateSession(bucket: bucket, startedAt: start, endAt: end)
        state.setCaffeinateSession(session)
        scheduleExpiry(at: end)
        return session
    }

    /// 立即释放当前会话（无操作时安全）。
    public func cancel() {
        expiry.cancel()
        if isActive {
            adapter.release(system: currentAssertions.system, display: currentAssertions.display)
            currentAssertions = (0, 0)
        }
        state.setCaffeinateSession(nil)
    }

    /// 到期释放：一次唤醒，不是每秒轮询（ADR-0010）。
    /// 若被提前触发（时钟回拨 / 定时器提前），按新的剩余时间重排，而不是误释放。
    private func scheduleExpiry(at end: Date) {
        expiry.schedule(at: end) { [weak self] in
            guard let self else { return }
            guard let session = self.state.caffeinateSession, session.isActive(now: self.now()) else {
                self.cancel()
                return
            }
            self.scheduleExpiry(at: session.endAt)
        }
    }
}
