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
    /// - 有可删除项 / 可移除的空工作区：汇总 + 明细 + 确定 / 取消。
    /// - 两者都没有：只给诊断文案，按钮只有一个「好」（不显示「无需清理」这种无信息的空话）。
    /// - Parameter desktopRunning: Kimi Code 桌面端是否在运行（由调用方用 `NSWorkspace` 判断后注入）。
    public static func previewContent(
        plan: CleanupPlan,
        policy: RetentionPolicy,
        now: Date,
        desktopRunning: Bool
    ) -> CleanupAlertContent {
        let hasSessions = plan.deletionCount > 0
        let hasWorkspaces = plan.workspaceRemovalCount > 0 || !plan.staleBucketIds.isEmpty
        guard hasSessions || hasWorkspaces else {
            return CleanupAlertContent(
                title: previewTitle,
                info: noDeletionDiagnostic(plan: plan, policy: policy),
                detail: nil,
                confirmable: false
            )
        }

        var info = hasSessions
            ? "将删除 \(plan.deletionCount) 个 session，释放 \(humanBytes(plan.reclaimableBytes))；"
                + "保留 \(plan.totalSessionCount - plan.deletionCount) 个。"
            : "没有可删除的 session。"
        if plan.workspaceRemovalCount > 0 {
            info += desktopRunning
                ? "\n有 \(plan.workspaceRemovalCount) 个空工作区可移除；Kimi Code 桌面端正在运行，本次跳过。"
                : "\n将移除 \(plan.workspaceRemovalCount) 个空工作区。"
        }
        if !plan.staleBucketIds.isEmpty {
            info += desktopRunning
                ? "\n有 \(plan.staleBucketIds.count) 个已移除工作区的空目录可清理；本次跳过。"
                : "\n将清理 \(plan.staleBucketIds.count) 个已移除工作区的空目录。"
        }
        if desktopRunning && hasSessions { info += "\n" + runningWarning() }
        if let issue = plan.workspaceCatalogIssue {
            info += "\n⚠ 工作区注册表读取失败，本次不会移除空工作区：\(issue)"
        }

        let detail = [deletionListing(plan: plan, now: now), workspaceListing(plan: plan, desktopRunning: desktopRunning)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return CleanupAlertContent(
            title: previewTitle,
            info: info,
            detail: detail.isEmpty ? nil : detail,
            confirmable: true
        )
    }

    /// 无可删除项时的诊断：说清「按什么策略没得清」以及「现存多少、多老」，
    /// 否则用户只会看到一句「无需清理」，无法判断是策略太宽还是真的干净。
    public static func noDeletionDiagnostic(plan: CleanupPlan, policy: RetentionPolicy) -> String {
        let head = "按当前策略（\(policyLabel(policy))）没有可清理的 session。"
        var text: String
        if plan.totalSessionCount > 0 {
            text = head
                + "现存 \(plan.totalSessionCount) 个，共 \(humanBytes(plan.totalBytes))，"
                + "最老的 \(String(format: "%.1f", plan.oldestAgeDays)) 天。"
        } else {
            text = head + "未找到任何 session。"
        }
        if let issue = plan.workspaceCatalogIssue {
            text += "\n工作区注册表读取失败：\(issue)"
        }
        return text
    }

    /// `每工作区保留 3 个 / 早于 7 天`；`keepCount == 0` 展示为「每工作区不保留」，
    /// `retentionDays == 0` 展示为「不限天数」。
    public static func policyLabel(_ policy: RetentionPolicy) -> String {
        let keep = policy.keepCount == 0 ? "每工作区不保留" : "每工作区保留 \(policy.keepCount) 个"
        let days = policy.retentionDays == 0 ? "不限天数" : "早于 \(policy.retentionDays) 天"
        return "\(keep) / \(days)"
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

    /// 将移除的空工作区 / 将清理的空目录（滚动区文本）。
    public static func workspaceListing(plan: CleanupPlan, desktopRunning: Bool = false) -> String {
        var lines: [String] = []
        if !plan.workspaceRemovals.isEmpty {
            lines.append("── 空工作区（\(plan.workspaceRemovals.count) 个）")
            let prefix = desktopRunning ? "[本次跳过]" : "[将移除]"
            for removal in plan.workspaceRemovals {
                var line = "\(prefix) \(removal.root)"
                if !removal.rootExists { line += "（目录已不存在）" }
                lines.append(line)
            }
        }
        if !plan.staleBucketIds.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("── 已移除工作区的空目录（\(plan.staleBucketIds.count) 个）")
            let prefix = desktopRunning ? "[本次跳过]" : "[将清理]"
            for id in plan.staleBucketIds { lines.append("\(prefix) \(id)") }
        }
        return lines.joined(separator: "\n")
    }

    /// 桌面端在运行时的一行警告。**只是警告，不禁用「确定」**（D4：清理由用户决定）。
    public static func runningWarning() -> String {
        "⚠ Kimi Code 桌面端正在运行，正在使用的会话可能受影响。"
    }

    /// 桌面端在运行时跳过工作区级动作的说明（预览 / 完成弹窗共用）。
    public static func workspaceSkipWarning() -> String {
        "Kimi Code 桌面端正在运行：本次不会移除空工作区，退出后再次清理即可。"
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
        var info = "已删除 \(outcome.deletedSessionCount) 个 session，"
            + "释放 \(humanBytes(outcome.reclaimedBytes))；"
            + "移除 \(outcome.removedWorkspaceCount) 个空工作区；"
            + "\(outcome.failures.count) 个操作失败\n"
            + "session_index.jsonl 移除 \(outcome.indexRecordsRemoved) 条记录；"
            + "file-history 清理 \(outcome.fileHistoryIdsRemoved) 条条目；"
            + "孤儿事件文件 \(outcome.deletedEventJournalCount) 个；"
            + "空 bucket \(outcome.deletedEmptyBucketCount) 个；"
            + "空账本 \(outcome.deletedEmptyLedgerCount) 个"
        if outcome.workspaceActionsSkipped { info += "\n" + workspaceSkipWarning() }
        if outcome.removedWorkspaceCount > 0 {
            info += "\n工作区列表可能需要重启 Kimi Code 后才会刷新。"
        }
        if let issue = outcome.workspaceCatalogIssue { info += "\n工作区注册表未改动：\(issue)" }
        if outcome.skippedWorkspaceCount > 0 {
            info += "\n\(outcome.skippedWorkspaceCount) 个工作区因仍有 session 未移除。"
        }
        let detail = outcome.failures.isEmpty
            ? nil
            : outcome.failures.prefix(3).map { "失败：\($0)" }.joined(separator: "\n")
        return CleanupAlertContent(title: completionTitle, info: info, detail: detail, confirmable: false)
    }
}
