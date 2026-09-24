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
        NSApp.activate(ignoringOtherApps: true)
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
        textView.string = text

        let scroll = NSScrollView(frame: frame)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        return scroll
    }
}
