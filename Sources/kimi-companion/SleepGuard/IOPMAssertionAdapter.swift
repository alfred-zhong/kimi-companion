import Foundation
import IOKit.pwr_mgt

/// IOPMAssertion 资源 adapter：把 system / display 两条 assertion 合并为一个 acquire。
/// 只有两条都成功才返回非零 ID 对，否则 release 已建的部分并返回 (0, 0)。
public protocol IOPMAssertionAdapter: Sendable {
    /// 同时建 system + display 两条 assertion。name 用于 IOPMAssertionCreateWithName 的 debug 字符串。
    /// 失败时保证不留下半成品。
    func acquire(name: String) -> (system: UInt32, display: UInt32)
    /// 释放已建的两条。允许传 (0, 0) —— 直接无操作。
    func release(system: UInt32, display: UInt32)
}

/// 生产实现：走 IOKit `IOPMAssertionCreateWithName` / `IOPMAssertionRelease`。
public final class LiveIOPMAssertionAdapter: IOPMAssertionAdapter, @unchecked Sendable {
    public init() {}

    public func acquire(name: String) -> (system: UInt32, display: UInt32) {
        let sys = acquireOne(
            type: "PreventUserIdleSystemSleep" as CFString,
            name: "\(name) · 阻止系统休眠"
        )
        let dis = acquireOne(
            type: "PreventUserIdleDisplaySleep" as CFString,
            name: "\(name) · 阻止显示器休眠"
        )
        if sys == 0 || dis == 0 {
            // rollback 任意已建立的。
            if sys != 0 { IOPMAssertionRelease(sys) }
            if dis != 0 { IOPMAssertionRelease(dis) }
            return (0, 0)
        }
        return (sys, dis)
    }

    public func release(system: UInt32, display: UInt32) {
        if system != 0 { IOPMAssertionRelease(system) }
        if display != 0 { IOPMAssertionRelease(display) }
    }

    private func acquireOne(type: CFString, name: String) -> UInt32 {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : 0
    }
}

/// 测试用 Fake：对每次 acquire 顺序生成新 ID；release 记录到数组。
public final class FakeIOPMAssertionAdapter: IOPMAssertionAdapter, @unchecked Sendable {
    public private(set) var acquired: [(system: UInt32, display: UInt32)] = []
    public private(set) var released: [(system: UInt32, display: UInt32)] = []
    public var failNext: Bool = false
    private var nextID: UInt32 = 1
    private let lock = NSLock()

    public init() {}

    public func acquire(name: String) -> (system: UInt32, display: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if failNext { failNext = false; return (0, 0) }
        let pair = (system: nextID, display: nextID + 1)
        nextID += 2
        acquired.append(pair)
        return pair
    }

    public func release(system: UInt32, display: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if system == 0 && display == 0 { return }
        released.append((system: system, display: display))
    }
}
