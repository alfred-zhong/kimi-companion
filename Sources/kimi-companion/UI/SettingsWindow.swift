import AppKit
import SwiftUI

/// 偏好设置的持久化镜像（UserDefaults）：刷新间隔 + 菜单栏展示的 provider + 清理策略。
public final class SettingsStore: ObservableObject, @unchecked Sendable {
    static let intervalKey = "intervalSeconds"
    static let providerKey = "selectedProvider"
    static let cleanupKeepCountKey = "cleanupKeepCount"
    static let cleanupRetentionDaysKey = "cleanupRetentionDays"

    /// 工作区保留数的默认值与合法范围。
    public static let defaultCleanupKeepCount = 3
    public static let cleanupKeepCountRange = 1...20
    /// 保留天数的默认值与合法范围；`0` 表示「不限天数」。
    public static let defaultCleanupRetentionDays = 7
    public static let cleanupRetentionDaysRange = 0...365

    @Published public var intervalSeconds: RefreshInterval {
        didSet { defaults.set(intervalSeconds.rawValue, forKey: Self.intervalKey) }
    }

    /// 菜单栏展示哪个 provider 的值。用户在这里 / 菜单里显式选择，失败时不自动切换。
    @Published public var selectedProvider: ProviderID {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Self.providerKey) }
    }

    /// 每个工作区保留最近 N 个 session（清理用）。
    @Published public var cleanupKeepCount: Int {
        didSet { defaults.set(cleanupKeepCount, forKey: Self.cleanupKeepCountKey) }
    }

    /// 只删除最后更新早于 N 天的 session；`0` = 不限天数。
    @Published public var cleanupRetentionDays: Int {
        didSet { defaults.set(cleanupRetentionDays, forKey: Self.cleanupRetentionDaysKey) }
    }

    private let defaults: UserDefaults

    /// - Parameter fallbackProvider: 首次运行（UserDefaults 无有效记录）时的菜单栏 provider。
    ///   由调用方从 config.toml 的 `default_model` 前缀推导后注入（见 `MenuBarSelection`）。
    public init(defaults: UserDefaults = .standard, fallbackProvider: ProviderID = .deepseek) {
        self.defaults = defaults
        let restored = RefreshInterval.persisted(rawSeconds: defaults.double(forKey: Self.intervalKey))
        if restored.needsRewrite {
            // 存量脏值（例如手改过 plist）落回默认档并写回自愈。
            defaults.set(restored.interval.rawValue, forKey: Self.intervalKey)
        }
        self.intervalSeconds = restored.interval

        let stored = defaults.string(forKey: Self.providerKey).flatMap(ProviderID.init(rawValue:))
        self.selectedProvider = stored.flatMap { ProviderID.supported.contains($0) ? $0 : nil } ?? fallbackProvider

        // `integer(forKey:)` 对「从未设置」与「显式存 0」返回同一个 0，而 0 是保留天数的合法值
        // （不限天数）—— 因此必须区分「键不存在」与「值是 0」。
        let keep = defaults.object(forKey: Self.cleanupKeepCountKey) as? Int
        self.cleanupKeepCount = Self.clampKeepCount(keep ?? Self.defaultCleanupKeepCount)
        let days = defaults.object(forKey: Self.cleanupRetentionDaysKey) as? Int
        self.cleanupRetentionDays = Self.clampRetentionDays(days ?? Self.defaultCleanupRetentionDays)
    }

    /// 越界值夹回 `cleanupKeepCountRange`（下限 1：每工作区永远保留最新 1 个）。
    public static func clampKeepCount(_ value: Int) -> Int {
        min(max(value, cleanupKeepCountRange.lowerBound), cleanupKeepCountRange.upperBound)
    }

    /// 越界值夹回 `cleanupRetentionDaysRange`（下限 0 = 不限天数）。
    public static func clampRetentionDays(_ value: Int) -> Int {
        min(max(value, cleanupRetentionDaysRange.lowerBound), cleanupRetentionDaysRange.upperBound)
    }
}

/// 偏好窗口控制器。窗口内容：刷新间隔 + 清理策略两项。
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onIntervalChange: (RefreshInterval) -> Void
    private weak var statusBar: StatusBarController?

    public init(onIntervalChange: @escaping (RefreshInterval) -> Void) {
        self.onIntervalChange = onIntervalChange
    }

    public func attachStatusBar(_ bar: StatusBarController) {
        self.statusBar = bar
    }

    public func show(store: SettingsStore) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            store: store,
            onIntervalChange: { [weak self] interval in
                self?.onIntervalChange(interval)
                self?.statusBar?.restartTimer()
            }
        )
        let host = NSHostingController(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.contentViewController = host
        w.title = "kimi-companion 偏好"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// 偏好面板内容。
///
/// 刻意不用 `@State`：macOS 27 SDK 把 `@State` 变成宏展开，其插件（`libSwiftUIMacros.dylib`）
/// 只随 Xcode 提供，CommandLineTools-only 环境编不过（本仓库既定构建环境，实测报错
/// `plugin for module 'SwiftUIMacros' not found`）。`@ObservedObject` 是普通 property wrapper，不受影响。
private struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let onIntervalChange: (RefreshInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("刷新间隔")
                Picker("刷新间隔", selection: $store.intervalSeconds) {
                    ForEach(RefreshInterval.allCases, id: \.self) { option in
                        Text("\(option.rawValue)s").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: store.intervalSeconds) { newValue in
                    onIntervalChange(newValue)
                }
            }
            HStack {
                Text("工作区保留数").frame(width: 96, alignment: .leading)
                Stepper(
                    value: $store.cleanupKeepCount,
                    in: SettingsStore.cleanupKeepCountRange
                ) {
                    Text("\(store.cleanupKeepCount) 个")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .leading)
                }
            }
            HStack {
                Text("保留天数").frame(width: 96, alignment: .leading)
                Stepper(
                    value: $store.cleanupRetentionDays,
                    in: SettingsStore.cleanupRetentionDaysRange
                ) {
                    Text(store.cleanupRetentionDays == 0 ? "不限" : "\(store.cleanupRetentionDays) 天")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .leading)
                }
            }
            Text("清理 session 文件时，每个工作区保留最近 N 个；更老的 session 只在其最后更新早于 N 天时删除。保留天数填 0 表示不限天数。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420, height: 170, alignment: .topLeading)
    }
}
