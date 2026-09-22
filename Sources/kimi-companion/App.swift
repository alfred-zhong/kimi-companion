import AppKit
import Foundation

@main
public enum KimiCompanion {
    public static func main() {
        if CommandLine.arguments.contains("--self-check") {
            exit(Int32(SelfCheck.run()))
        }
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 关键：无 Dock 图标
        app.delegate = delegate
        app.run()
    }
}

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var settingsController: SettingsWindowController?
    private let state = AppState()
    private var refreshController: RefreshController?
    private var sleepGuard: SleepGuard?
    private var settingsStore: SettingsStore?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let home = NSHomeDirectory()

        // config.toml 是唯一凭据来源；只在启动时读一次用于推导菜单栏默认 provider。
        let configSource = KimiConfigSource(homeDir: home)
        let fallbackProvider = MenuBarSelection.deriveDefault(fromDefaultModel: configSource.load().config?.defaultModel)
        let settings = SettingsStore(fallbackProvider: fallbackProvider)
        self.settingsStore = settings
        state.setSelectedProvider(settings.selectedProvider)

        let reader = WireLogReader(sessionsRoot: "\(home)/.kimi-code/sessions")
        let balanceSource = LiveBalanceSource(config: configSource)
        let dailySource = LiveDailyUsageSource(reader: reader)
        let controller = RefreshController(
            balanceSource: balanceSource,
            dailySource: dailySource,
            state: state,
            intervalSeconds: settings.intervalSeconds.seconds
        )
        self.refreshController = controller

        let guard_ = SleepGuard(state: state)
        self.sleepGuard = guard_

        let settingsCtrl = SettingsWindowController(
            onIntervalChange: { [weak controller] newInterval in
                controller?.intervalSeconds = newInterval.seconds
            }
        )
        self.settingsController = settingsCtrl

        let bar = StatusBarController(
            controller: controller,
            state: state,
            sleepGuard: guard_,
            onShowSettings: { [weak settingsCtrl, weak settings] in
                guard let settings else { return }
                settingsCtrl?.show(store: settings)
            },
            onSelectProvider: { [weak settings, weak controller] pid in
                settings?.selectedProvider = pid
                controller?.selectProvider(pid)
            }
        )
        settingsCtrl.attachStatusBar(bar)
        self.statusBar = bar
    }

    /// 菜单栏 accessory 应用无默认主菜单：装一个最小 Edit 菜单，让偏好窗口能响应
    /// Cmd+A / Cmd+C / Cmd+V 等编辑快捷键（经 `paste:` 等路由到 first responder）。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 kimi-companion", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 kimi-companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSTextView.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSTextView.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSTextView.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSTextView.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // 退出时静默 release；SleepGuard.deinit 也会兜底。
        sleepGuard?.cancel()
    }
}
