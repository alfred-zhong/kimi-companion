import Foundation

/// 一次清理弹窗的全部内容（预览 / 完成 / 说明）。`NSAlert` 接线在 `CleanupAlertPresenter`，
/// 这里只做纯字符串推导，因此 `SelfCheck` 可以完全不碰 AppKit 地断言全部文案。
public struct CleanupAlertContent: Equatable, Sendable {
    /// `NSAlert.messageText`。
    public let title: String
    /// `NSAlert.informativeText`。
    public let info: String
    /// 详情（可滚动等宽文本区）；nil 表示不带 accessory view。
    public let detail: String?
    /// true → 「确定」/「取消」；false → 只有一个「好」（无可清理项 / 只是告知）。
    public let confirmable: Bool

    public init(title: String, info: String, detail: String?, confirmable: Bool) {
        self.title = title
        self.info = info
        self.detail = detail
        self.confirmable = confirmable
    }
}

/// 清理相关的全部用户可见文案（中文，风格对齐 `ProviderFailure.menuText` / `humanReadable`）。
public enum CleanupPresenter {

    public static let previewTitle = "清理 session 文件"
    public static let completionTitle = "清理完成"

    // MARK: - 大小格式化

    /// 字节数 → `B` / `KB` / `MB` / `GB` / `TB`；`B` 无小数，其余保留 1 位。
    /// 刻意不复用 `CompactFormatter`（那是 token 计数用的 K/M/B 进位，语义不同）。
    public static func humanBytes(_ bytes: Int) -> String {
        var n = Double(bytes)
        for unit in ["B", "KB", "MB", "GB", "TB"] {
            if abs(n) < 1024 || unit == "TB" {
                return unit == "B" ? String(format: "%.0f B", n) : String(format: "%.1f %@", n, unit)
            }
            n /= 1024
        }
        return String(format: "%.1f TB", n)
    }

    /// `session_10b4773e-4a3c-…` → `session_10b4773e`（列表里只留可辨认的前 8 位）。
    public static func shortSessionId(_ id: String) -> String {
        let prefix = "session_"
        guard id.hasPrefix(prefix) else { return String(id.prefix(22)) }
        return prefix + id.dropFirst(prefix.count).prefix(8)
    }

    // MARK: - 预览

    /// 预览弹窗内容。
    ///
    /// - 有可删除项：汇总一行 + 按工作区分组的明细（**只列将删除的 session**）+ 确定 / 取消。
    /// - 无可删除项：只给诊断文案，按钮只有一个「好」（不显示「无需清理」这种无信息的空话）。
    /// - Parameter desktopRunning: Kimi Code 桌面端是否在运行（由调用方用 `NSWorkspace` 判断后注入）。
    public static func previewContent(
        plan: CleanupPlan,
        policy: RetentionPolicy,
        now: Date,
        desktopRunning: Bool
    ) -> CleanupAlertContent {
        guard plan.deletionCount > 0 else {
            return CleanupAlertContent(
                title: previewTitle,
                info: noDeletionDiagnostic(plan: plan, policy: policy),
                detail: nil,
                confirmable: false
            )
        }
        var info = "将删除 \(plan.deletionCount) 个 session，释放 \(humanBytes(plan.reclaimableBytes))；"
            + "保留 \(plan.totalSessionCount - plan.deletionCount) 个。"
        if desktopRunning { info += "\n" + runningWarning() }
        return CleanupAlertContent(
            title: previewTitle,
            info: info,
            detail: deletionListing(plan: plan, now: now),
            confirmable: true
        )
    }

    /// 无可删除项时的诊断：说清「按什么策略没得清」以及「现存多少、多老」，
    /// 否则用户只会看到一句「无需清理」，无法判断是策略太宽还是真的干净。
    public static func noDeletionDiagnostic(plan: CleanupPlan, policy: RetentionPolicy) -> String {
        let head = "按当前策略（\(policyLabel(policy))）没有可清理的 session。"
        guard plan.totalSessionCount > 0 else { return head + "未找到任何 session。" }
        return head
            + "现存 \(plan.totalSessionCount) 个，共 \(humanBytes(plan.totalBytes))，"
            + "最老的 \(String(format: "%.1f", plan.oldestAgeDays)) 天。"
    }

    /// `每工作区保留 3 个 / 早于 7 天`；`retentionDays == 0` 展示为「不限天数」。
    public static func policyLabel(_ policy: RetentionPolicy) -> String {
        let days = policy.retentionDays == 0 ? "不限天数" : "早于 \(policy.retentionDays) 天"
        return "每工作区保留 \(policy.keepCount) 个 / \(days)"
    }

    /// 将删除 session 的分组明细（滚动区文本）。
    public static func deletionListing(plan: CleanupPlan, now: Date) -> String {
        var lines: [String] = []
        for group in plan.groups {
            let items = group.deletionItems
            guard !items.isEmpty else { continue }
            let bytes = items.reduce(0) { $0 + $1.record.byteSize }
            lines.append("── \(group.workspace)（\(items.count) 个 · \(humanBytes(bytes))）")
            for item in items {
                let age = String(format: "%.1f", item.record.ageDays(now: now))
                lines.append("[将删除] \(age) 天前 · \(humanBytes(item.record.byteSize))"
                    + " · \(shortSessionId(item.record.id))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 桌面端在运行时的一行警告。**只是警告，不禁用「确定」**（D4：清理由用户决定）。
    public static func runningWarning() -> String {
        "⚠ Kimi Code 桌面端正在运行，正在使用的会话可能受影响。"
    }

    // MARK: - 告知（无「确定 / 取消」）

    /// `sessions` 根目录不存在。
    public static func missingRootContent(path: String) -> CleanupAlertContent {
        CleanupAlertContent(
            title: previewTitle,
            info: "未找到 session 目录：\(path)\n没有可清理的内容。",
            detail: nil,
            confirmable: false
        )
    }

    /// 扫描失败等一次性说明。
    public static func messageContent(_ message: String) -> CleanupAlertContent {
        CleanupAlertContent(title: previewTitle, info: message, detail: nil, confirmable: false)
    }

    // MARK: - 完成

    /// 完成弹窗内容：一行结果 + 一行产物计数（可为 0）+ 有失败时列出前 3 条失败路径。
    public static func completionContent(_ outcome: CleanupOutcome) -> CleanupAlertContent {
        let info = "已删除 \(outcome.deletedSessionCount) 个 session，"
            + "释放 \(humanBytes(outcome.reclaimedBytes))；\(outcome.failures.count) 个删除失败\n"
            + "session_index.jsonl 移除 \(outcome.indexRecordsRemoved) 条记录；"
            + "file-history 清理 \(outcome.fileHistoryIdsRemoved) 条条目；"
            + "孤儿事件文件 \(outcome.deletedEventJournalCount) 个"
        let detail = outcome.failures.isEmpty
            ? nil
            : outcome.failures.prefix(3).map { "失败：\($0)" }.joined(separator: "\n")
        return CleanupAlertContent(title: completionTitle, info: info, detail: detail, confirmable: false)
    }
}
