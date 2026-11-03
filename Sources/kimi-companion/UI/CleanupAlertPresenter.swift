import AppKit

/// `NSAlert` 接线：预览（确定 / 取消）与结果（好）两个弹窗 + 可滚动详情区。
///
/// 刻意薄到没什么可测：全部文案由 `CleanupPresenter` 的纯函数给出，这里只负责按钮与视图摆放，
/// 以及「LSUIElement app 的弹窗必须自己抢焦点」这件事（`NSApp.activate(ignoringOtherApps:)`）。
@MainActor
public enum CleanupAlertPresenter {

    /// 详情列表的固定高度与宽度（可滚动）。
    public static let detailHeight: CGFloat = 220
    public static let detailWidth: CGFloat = 500

    /// 弹出弹窗并等待用户响应。
    /// - Returns: 用户是否点了「确定」。非确认形态（只有一个「好」）恒为 false。
    @discardableResult
    public static func present(_ content: CleanupAlertContent) -> Bool {
        let alert = makeAlert(content)
        positionWindow(alert)
        // LSUIElement app 从状态栏菜单弹出面板时，`NSApp.activate(ignoringOtherApps:)`（macOS 14 起
        // 已废弃）经常不生效：面板显示在最上层，但 app 仍不是前台、窗口也不是 key —— 键盘交互和
        // 滚动都会被系统按「非活动 app」降级。补一次显式激活 + 把面板显式设成 key。
        NSApp.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        alert.window.makeKeyAndOrderFront(nil)
        return isConfirmed(content: content, response: alert.runModal())
    }

    /// 把 modal 响应折成「用户是否确认执行」。
    ///
    /// 非确认形态只有一个「好」按钮，而它就是 `.alertFirstButtonReturn` —— 因此必须先看内容
    /// 是否可确认，否则「看完告知点掉」会被误判成「确认执行」。
    nonisolated public static func isConfirmed(
        content: CleanupAlertContent,
        response: NSApplication.ModalResponse
    ) -> Bool {
        content.confirmable && response == .alertFirstButtonReturn
    }

    /// 把弹窗摆到系统常态位置（水平居中、略高于垂直中线）。
    ///
    /// `NSAlert` 的定位在 `runModal()` 内部完成，而本 app 为了给 LSUIElement 的弹窗拿到 key 焦点，
    /// 必须先 `makeKeyAndOrderFront` —— 窗口一上屏 `runModal()` 就不再挪动它，弹窗会停在 `NSAlert`
    /// 窗口的默认 frame 上（屏幕左上，且与内容尺寸无关，只有 `layout()` 之后的尺寸变化），实测在这台
    /// 1470×956 的屏幕上左右留白 211 / 727。因此把「先布局、再居中」提前到上屏之前，得到的位置与
    /// `runModal()` 自己算出的一致（`center()` 在 alert 窗口上给出的是水平居中 + 上方留 1/4、下方留
    /// 3/4 的剩余高度，不是几何中心）。
    public static func positionWindow(_ alert: NSAlert) {
        alert.layout()
        alert.window.center()
    }

    /// 按内容装配 `NSAlert`（不含 modal 循环）。
    ///
    /// 拆出来是为了让 `SelfCheck` 能断言按钮映射与详情区，而不必真的弹出窗口：
    /// 「确定」必须是第一个按钮（即 `.alertFirstButtonReturn`），「取消」是第二个。
    public static func makeAlert(_ content: CleanupAlertContent) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.info
        alert.alertStyle = .informational
        if let detail = content.detail, !detail.isEmpty {
            alert.accessoryView = detailScrollView(text: detail)
        }
        if content.confirmable {
            alert.addButton(withTitle: "确定")   // .alertFirstButtonReturn
            alert.addButton(withTitle: "取消")   // .alertSecondButtonReturn
        } else {
            alert.addButton(withTitle: "好")
        }
        return alert
    }

    /// 等宽字体的固定高度滚动区。行可能很长（绝对路径），因此只允许纵向滚动 + 按宽度换行。
    ///
    /// `NSAlert` 自己的视图（图标 / 文本 / 按钮）都带 layer，唯独 `accessoryView` 传进去的这棵子树
    /// 默认没有任何 layer —— 而 alert 窗口是 `isOpaque == false` 的半透明面板。结果是详情区每次滚动
    /// 都走传统 `drawRect` 路径：在窗口后备存储上重绘刚露出的那块区域，再交给 window server 与面板
    /// 材质重新合成，触控板上手感发顿。给 `NSScrollView` 打开 layer 后 clip view 变成可平移的 layer
    /// 纹理，滚动帧只需移动纹理，不再逐帧重绘 + 重新合成（绘制本身只有 ~0.4ms/帧，瓶颈在合成侧）。
    ///
    /// `allowsNonContiguousLayout` 是给超长明细留的余量：TextKit 1 默认从文档开头顺序排版，
    /// 明细有几万行时首次滚到底会明显卡一下（实测 3000 行 ~100ms），打开后按需分段排版。
    private static func detailScrollView(text: String) -> NSScrollView {
        let frame = NSRect(x: 0, y: 0, width: detailWidth, height: detailHeight)
        let textView = NSTextView(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: detailWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = text

        let scroll = NSScrollView(frame: frame)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.wantsLayer = true
        scroll.documentView = textView
        return scroll
    }
}
