import AppKit
import Foundation

/// 下拉菜单里的用量进度条行：左窗口标签 + 中进度条 + 紧贴条尾的百分比 + 右侧左对齐的状态 / 重置倒计时。
/// 仅用于 `MenuItemSpec.usageBar`，由 `StatusBarController.installItem` 装配。
///
/// 布局：
/// ```
/// 5h [████░░░░░░] 0%   3h56m 后重置
/// 月度 [██░░░░░░] 13%   rate-limited · 26d 后重置
/// ```
/// - 左半部分：`5h [进度条] 0%` —— 标签右对齐定宽 40pt；百分比区定宽 40pt（容纳 `100%`），
///   百分比左对齐紧贴条尾，进度条长度不随百分比位数变化，多行条长一致。
/// - 右半部分：定宽区**左对齐**（不右对齐：文本长短不一，右缘参差可接受），无内容时该区留白。
///   宽度取 168pt，容纳最长形态 `rate-limited · 5d3h 后重置`。
/// - 进度条最短 `minBarWidth`(60pt)：视图宽度以 240pt 为底、按需加宽到
///   `minimumWidth(hasLeftLabel:)`，由 `init` 保证。
///
/// 其余约束：
/// - view 设 `.width`，菜单自动拉满宽；行高由 `intrinsicContentSize`(20) 固定，
///   否则 view-based 菜单项会因 intrinsic 高度为 0 而塌成空行。
/// - 背景透明，选区由菜单原生绘制；高亮时仅把文本翻白。
/// - 段色：`isOK == false` → 强制红（窗口已限流）；否则 `<70` 绿 / `70–90` 黄 / `>90` 红。
/// - `value` 已由 Presenter clamp 到 [0,100]；这里再次防御性 clamp。
///
/// 注：`NSProgressIndicator` 在本 SDK 无 `contentTintColor`，三段色无法靠 tint 实现，
/// 故进度条直接绘制（圆角轨道 + 段色填充）。无子视图，全部在 `draw(_:)` 内完成，
/// 规避菜单项子视图渲染不稳的问题。
final class UsageBarMenuItemView: NSView {
    /// 进度条段色（纯枚举，便于 SelfCheck 断言而不触碰 `NSColor` 的动态色比较）。
    enum Segment: Equatable {
        case green
        case yellow
        case red
    }

    private let leftText: String?
    private let value: Double
    private let percentText: String
    private let resetText: String?
    private let fill: NSColor

    /// 布局常量（pt）：外边距 / 左标签定宽 / 标签-条-文本间隙 / 百分比区定宽 / 右区定宽 / 条高。
    private static let margin: CGFloat = 6
    private static let leftWidth: CGFloat = 40
    private static let gap: CGFloat = 8
    private static let percentRegionWidth: CGFloat = 40
    private static let trailingRegionWidth: CGFloat = 168
    private static let barHeight: CGFloat = 10

    /// 进度条最短长度（pt）：视图宽度不足时通过加宽自身保证，避免窄菜单里条太短。
    static let minBarWidth: CGFloat = 60

    init(leftText: String?, value: Double, percentText: String, resetText: String?, isOK: Bool) {
        let clamped = min(max(value, 0), 100)
        self.leftText = leftText
        self.value = clamped
        self.percentText = percentText
        self.resetText = resetText
        self.fill = Self.color(for: Self.segment(for: clamped, isOK: isOK))
        let hasLeftLabel = !(leftText?.isEmpty ?? true)
        let width = max(240, Self.minimumWidth(hasLeftLabel: hasLeftLabel))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        self.autoresizingMask = .width
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 段色决策：非 `ok` 的窗口无论已用多少都强制红（`value` 已是已用百分比）。
    static func segment(for value: Double, isOK: Bool) -> Segment {
        if !isOK { return .red }
        if value > 90 { return .red }
        if value >= 70 { return .yellow }
        return .green
    }

    static func color(for segment: Segment) -> NSColor {
        switch segment {
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return .systemRed
        }
    }

    /// 保证进度条 ≥ `minBarWidth` 所需的最小视图宽：
    /// 外边距×2 + 左标签区 + 三处间隙 + 最短条 + 百分比区 + 右区。视图默认 240pt，不足时加宽到该值。
    static func minimumWidth(hasLeftLabel: Bool) -> CGFloat {
        margin * 2 + (hasLeftLabel ? leftWidth : 0) + gap * 3 + minBarWidth + percentRegionWidth + trailingRegionWidth
    }

    /// 给定总宽下的进度条长度（与 `draw` 同一公式，供 SelfCheck 断言最小长度不变量）。
    static func barWidth(totalWidth: CGFloat, hasLeftLabel: Bool) -> CGFloat {
        let barX = margin + (hasLeftLabel ? leftWidth : 0) + gap
        return max(0, totalWidth - margin - barX - gap - percentRegionWidth - gap - trailingRegionWidth)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: highlighted ? NSColor.white : NSColor.labelColor,
        ]

        // 百分比先测量：进度条长度 = 剩余宽 - 百分比区 - 右区，百分比紧贴条尾。
        let percent = NSAttributedString(string: percentText, attributes: attr)
        let percentSize = percent.size()

        // 左标签（右对齐在固定宽度区内；nil / 空 → 宽度收缩为 0）
        var leftRegionWidth: CGFloat = 0
        if let left = leftText, !left.isEmpty {
            leftRegionWidth = Self.leftWidth
            let text = NSAttributedString(string: left, attributes: attr)
            let size = text.size()
            text.draw(at: NSPoint(x: Self.margin + Self.leftWidth - size.width, y: (bounds.height - size.height) / 2))
        }

        let barX = Self.margin + leftRegionWidth + Self.gap
        let barW = Self.barWidth(totalWidth: bounds.width, hasLeftLabel: leftRegionWidth > 0)
        if barW > 0 {
            let barY = (bounds.height - Self.barHeight) / 2
            let radius = Self.barHeight / 2
            let trackColor: NSColor = highlighted
                ? NSColor.white.withAlphaComponent(0.25)
                : NSColor.separatorColor
            let trackPath = NSBezierPath(
                roundedRect: NSRect(x: barX, y: barY, width: barW, height: Self.barHeight),
                xRadius: radius, yRadius: radius
            )
            trackColor.setFill()
            trackPath.fill()

            if value > 0 {
                let fillW = min(barW, max(radius * 2, barW * (value / 100)))
                let fillPath = NSBezierPath(
                    roundedRect: NSRect(x: barX, y: barY, width: fillW, height: Self.barHeight),
                    xRadius: radius, yRadius: radius
                )
                fill.setFill()
                fillPath.fill()
            }
        }
        // 百分比：左对齐在定宽区内，紧贴条尾（右缘随位数参差，可接受）。
        percent.draw(at: NSPoint(x: barX + barW + Self.gap, y: (bounds.height - percentSize.height) / 2))

        // 右区：状态串 / 重置倒计时，左对齐（无内容则留白）。
        if let resetText, !resetText.isEmpty {
            let trailing = NSAttributedString(string: resetText, attributes: attr)
            let size = trailing.size()
            trailing.draw(at: NSPoint(
                x: bounds.width - Self.margin - Self.trailingRegionWidth,
                y: (bounds.height - size.height) / 2
            ))
        }
    }
}
