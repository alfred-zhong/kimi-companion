import Foundation

/// 一天有多少毫秒。清理的「年龄」计算只有这一处，避免两处各写一个常量。
private let cleanupDayMs: Double = 86_400_000

// MARK: - 策略

/// 清理策略：每个工作区保留多少个 session、多少天内的 session 不删。
///
/// 判定是**合取**（AND）：名额内 → 保留；否则最近活跃 → 保留；否则在保留天数内 → 保留；
/// 三条都不成立才删。因此调大任一参数都只会删得更少。
public struct RetentionPolicy: Equatable, Sendable {
    /// 每个工作区保留最近 N 个 session。`0` 表示不保留任何 session（名额门槛消失），
    /// 但 30 分钟活跃保护与 Retention Days 仍然生效。
    public var keepCount: Int
    /// 只删除最后更新早于 N 天的 session；`0` 表示不限天数（越老越删）。
    public var retentionDays: Int
    /// 最近 N 分钟内更新过的 session 一律不删。
    /// **写死的常量**，不进偏好设置：它保护的是「正在写日志的会话」这个事实，不是用户的偏好。
    public static let protectMinutes = 30

    public static let `default` = RetentionPolicy()

    public init(keepCount: Int = 3, retentionDays: Int = 7) {
        self.keepCount = max(keepCount, 0)
        self.retentionDays = max(retentionDays, 0)
    }
}

// MARK: - 扫描结果值类型

/// 一个本地 session 目录（`sessions/<桶>/<session_*>`）。
public struct ChatSessionRecord: Equatable, Sendable {
    /// 目录名，形如 `session_10b4773e-…`。
    public let id: String
    /// 绝对路径。
    public let directory: URL
    /// 分组键：`state.json` 的 `cwd`，缺失时用桶目录名（`wd_<名>_<hash>`）。
    public let workspace: String
    /// 毫秒时间戳：`state.json.updatedAt` → `createdAt` → 目录 mtime。
    public let updatedAtMs: Int64
    /// 目录内全部文件的字节数合计。
    public let byteSize: Int

    public init(id: String, directory: URL, workspace: String, updatedAtMs: Int64, byteSize: Int) {
        self.id = id
        self.directory = directory
        self.workspace = workspace
        self.updatedAtMs = updatedAtMs
        self.byteSize = byteSize
    }

    /// 距 `now` 的天数（`updatedAtMs` 在未来时为负）。
    public func ageDays(now: Date) -> Double {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return Double(nowMs - updatedAtMs) / cleanupDayMs
    }
}

/// 一个 session 的处置结论。前三个都是「保留」，只有 `.delete` 会被删。
public enum CleanupVerdict: Equatable, Sendable {
    /// 在「每工作区保留 N 个」的名额内。
    case keepInKeepCount
    /// 最近 `RetentionPolicy.protectMinutes` 分钟内活跃过。
    case keepRecentlyActive
    /// 还在保留天数内。
    case keepWithinRetentionDays
    case delete

    public var isDelete: Bool { self == .delete }
}

public struct CleanupPlanItem: Equatable, Sendable {
    public let record: ChatSessionRecord
    public let verdict: CleanupVerdict

    public init(record: ChatSessionRecord, verdict: CleanupVerdict) {
        self.record = record
        self.verdict = verdict
    }

    public var isDelete: Bool { verdict.isDelete }
}

/// 一个工作区（分组键 = `cwd` 或桶名）下的全部 session。
public struct WorkspaceGroup: Equatable, Sendable {
    public let workspace: String
    /// 按 `updatedAtMs` 降序（最新在前），名次即「每工作区保留 N 个」里的 rank。
    public let items: [CleanupPlanItem]

    public init(workspace: String, items: [CleanupPlanItem]) {
        self.workspace = workspace
        self.items = items
    }

    public var deletionItems: [CleanupPlanItem] { items.filter(\.isDelete) }
    public var deletionBytes: Int { deletionItems.reduce(0) { $0 + $1.record.byteSize } }
}

/// 一个需要在 `workspaces.json` 里注销的空工作区。
///
/// 空 = 该 root 对应的所有 alias bucket 里都没有任何 Chat Session 目录。
/// `aliasIds` 包含注册表条目 id 与 `session_index.jsonl` 推导出的 bucket id；
/// 注销时它们会一起写进 `deleted_workspace_ids`，防止 desktop 启动时从 index 自动补录回来。
public struct WorkspaceRemoval: Equatable, Sendable {
    /// 注册表里代表该 root 的 id（同 root 多条目时优先无尾斜杠者，再按 id 字典序）。
    public let id: String
    /// `workspaces.json` 的 `root`，原样保留。
    public let root: String
    public let name: String
    /// 同 root 的全部 id（注册表 alias + index 推导出的 bucket id）。
    public let aliasIds: [String]
    /// root 目录当前是否存在；不存在也算空，只用于预览文案。
    public let rootExists: Bool

    public init(id: String, root: String, name: String, aliasIds: [String], rootExists: Bool) {
        self.id = id
        self.root = root
        self.name = name
        self.aliasIds = aliasIds
        self.rootExists = rootExists
    }
}

/// 一次扫描的完整计划（相当于脚本的 dry-run 结果）。
public struct CleanupPlan: Equatable, Sendable {
    /// 全部工作区；含一个都不删的组（诊断文案要用到总数 / 总体积）。
    public let groups: [WorkspaceGroup]
    /// 无对应 session 目录的 `server/events/session_*.jsonl`。
    public let orphanEventJournals: [URL]
    /// `file-history/<桶>` 里目录已不存在的 session id。
    public let fileHistoryZombieIds: [String]
    public let totalSessionCount: Int
    public let totalBytes: Int
    /// 现存最老 session 的天数；没有 session 时为 0。
    public let oldestAgeDays: Double
    public let deletionCount: Int
    public let reclaimableBytes: Int
    /// 将要从 `workspaces.json` 注销的空工作区（按 root 去重）。
    public let workspaceRemovals: [WorkspaceRemoval]
    /// `deleted_workspace_ids` 里、磁盘上仍留有空的 bucket 的 id。
    public let staleBucketIds: [String]
    /// 读 `workspaces.json` 失败的原因；nil = 已成功读取。读失败时不做工作区移除。
    public let workspaceCatalogIssue: String?

    public init(
        groups: [WorkspaceGroup],
        orphanEventJournals: [URL],
        fileHistoryZombieIds: [String],
        totalSessionCount: Int,
        totalBytes: Int,
        oldestAgeDays: Double,
        deletionCount: Int,
        reclaimableBytes: Int,
        workspaceRemovals: [WorkspaceRemoval] = [],
        staleBucketIds: [String] = [],
        workspaceCatalogIssue: String? = nil
    ) {
        self.groups = groups
        self.orphanEventJournals = orphanEventJournals
        self.fileHistoryZombieIds = fileHistoryZombieIds
        self.totalSessionCount = totalSessionCount
        self.totalBytes = totalBytes
        self.oldestAgeDays = oldestAgeDays
        self.deletionCount = deletionCount
        self.reclaimableBytes = reclaimableBytes
        self.workspaceRemovals = workspaceRemovals
        self.staleBucketIds = staleBucketIds
        self.workspaceCatalogIssue = workspaceCatalogIssue
    }

    /// 将被删除的全部 session（按组顺序展开）。
    public var deletionItems: [CleanupPlanItem] {
        groups.flatMap(\.deletionItems)
    }

    public var workspaceRemovalCount: Int { workspaceRemovals.count }
}

/// 一次真正执行的结果。逐项 best-effort：单项失败不中断整次清理，只累进 `failures`。
public struct CleanupOutcome: Equatable, Sendable {
    public let deletedSessionCount: Int
    public let deletedEventJournalCount: Int
    /// 真正删掉的 session 的字节数合计（删除失败的项不计入）。
    public let reclaimedBytes: Int
    public let fileHistoryIdsRemoved: Int
    public let indexRecordsRemoved: Int
    /// 从 `workspaces.json` 注销的工作区数（按 root 计，不按 alias 条目计）。
    public let removedWorkspaceCount: Int
    /// 删掉的空 bucket 目录数。
    public let deletedEmptyBucketCount: Int
    /// 删掉的空 `file-history/<bucket>` 账本数。
    public let deletedEmptyLedgerCount: Int
    /// 复审时发现「已经有 session 了」而跳过的工作区数（预览与执行之间状态变化）。
    public let skippedWorkspaceCount: Int
    /// true = 因为 Kimi Code 桌面端在运行，本次跳过了全部工作区级动作。
    public let workspaceActionsSkipped: Bool
    /// `workspaces.json` 未改动的原因（缺失 / 损坏 / 写入失败）；nil = 正常。
    public let workspaceCatalogIssue: String?
    /// 失败项的可读描述（路径 + 原因），供完成弹窗列出前几条。
    public let failures: [String]

    public init(
        deletedSessionCount: Int,
        deletedEventJournalCount: Int,
        reclaimedBytes: Int,
        fileHistoryIdsRemoved: Int,
        indexRecordsRemoved: Int,
        failures: [String],
        removedWorkspaceCount: Int = 0,
        deletedEmptyBucketCount: Int = 0,
        deletedEmptyLedgerCount: Int = 0,
        skippedWorkspaceCount: Int = 0,
        workspaceActionsSkipped: Bool = false,
        workspaceCatalogIssue: String? = nil
    ) {
        self.deletedSessionCount = deletedSessionCount
        self.deletedEventJournalCount = deletedEventJournalCount
        self.reclaimedBytes = reclaimedBytes
        self.fileHistoryIdsRemoved = fileHistoryIdsRemoved
        self.indexRecordsRemoved = indexRecordsRemoved
        self.failures = failures
        self.removedWorkspaceCount = removedWorkspaceCount
        self.deletedEmptyBucketCount = deletedEmptyBucketCount
        self.deletedEmptyLedgerCount = deletedEmptyLedgerCount
        self.skippedWorkspaceCount = skippedWorkspaceCount
        self.workspaceActionsSkipped = workspaceActionsSkipped
        self.workspaceCatalogIssue = workspaceCatalogIssue
    }
}

/// 扫描失败原因。照 `SnapshotError` 的风格：类型化枚举 + 中文文案，调用方 `switch` 降级。
public enum SessionCleanupError: Error, Sendable, Equatable {
    /// `~/.kimi-code/sessions` 不存在 / 不是目录。调用方据此显示「没有可清理的内容」。
    case sessionsRootMissing(String)
    /// 根目录存在但读不了；reason 已是可直接展示的中文。
    case scanFailed(String)

    /// 可直接展示的中文文案。
    public var message: String {
        switch self {
        case .sessionsRootMissing(let path): return "未找到 session 目录：\(path)"
        case .scanFailed(let reason): return reason
        }
    }
}

// MARK: - SessionCleanup

/// kimi-code 本地 session 数据的清理器：扫描（dry-run）+ 执行。
///
/// **直接操作文件系统**，复刻 `kimi-sessions-cleanup.py` 的能力：不走 kimi-code 本地 HTTP
/// server、不 shell-out、不启任何外部进程。只碰 session 目录、孤儿事件 journal、
/// `session_index.jsonl`、`file-history/<桶>` 账本，以及**空工作区**在 `workspaces.json`
/// 里的注册条目与 `deleted_workspace_ids` 墓碑（受控写入见 ADR-0009）。
/// 其余（`server/instances/`、`server.token`、`mcp.json`、`search-index/`、`config.toml`、
/// `events/__global__.jsonl`、`workspace-trust/`）一律不碰。
///
/// 两个方法都是**同步阻塞 I/O 的 `async` 包装**（照 `LiveDailyUsageSource.capture` 的先例）：
/// 调用方在非主线程 await 即可离开主线程，不引入 `DispatchQueue` / `actor`。
public struct SessionCleanup: Sendable {
    /// kimi-code 数据根目录（`~/.kimi-code`）。由调用方注入，本类型不读环境变量。
    public let kimiCodeHome: URL

    public init(kimiCodeHome: URL) {
        self.kimiCodeHome = kimiCodeHome
    }

    /// 用户 home → kimi-code 数据根目录（`~/.kimi-code`）。
    ///
    /// app 里**唯一**的拼接点：清理器的数据根与 `WireLogReader` 的 sessionsRoot 都从这里派生。
    /// 调用方一律传用户 home，不要自己拼 `.kimi-code`。
    public static func dataHome(userHome: String) -> URL {
        URL(fileURLWithPath: userHome, isDirectory: true)
            .appendingPathComponent(".kimi-code", isDirectory: true)
    }

    /// `~/.kimi-code/sessions`。
    public var sessionsRoot: URL { kimiCodeHome.appendingPathComponent("sessions", isDirectory: true) }
    private var eventsDirectory: URL {
        kimiCodeHome.appendingPathComponent("server", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }
    private var indexURL: URL { kimiCodeHome.appendingPathComponent("session_index.jsonl") }
    private var fileHistoryDirectory: URL {
        kimiCodeHome.appendingPathComponent("file-history", isDirectory: true)
    }
    /// `~/.kimi-code/workspaces.json`（kimi-code desktop 的工作区注册表）。
    private var workspacesURL: URL { kimiCodeHome.appendingPathComponent("workspaces.json") }

    // MARK: - 扫描

    /// 扫描（不删除任何东西）。
    public func scan(now: Date, policy: RetentionPolicy) async throws -> CleanupPlan {
        try scanSync(now: now, policy: policy)
    }

    private func scanSync(now: Date, policy: RetentionPolicy) throws -> CleanupPlan {
        guard isDirectory(sessionsRoot) else {
            throw SessionCleanupError.sessionsRootMissing(sessionsRoot.path)
        }
        let records = try collectSessions()

        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var groups: [WorkspaceGroup] = []
        for (workspace, members) in Dictionary(grouping: records, by: \.workspace) {
            let sorted = members.sorted {
                $0.updatedAtMs == $1.updatedAtMs ? $0.id < $1.id : $0.updatedAtMs > $1.updatedAtMs
            }
            let items = sorted.enumerated().map { rank, record in
                CleanupPlanItem(
                    record: record,
                    verdict: Self.verdict(
                        rank: rank,
                        updatedAtMs: record.updatedAtMs,
                        nowMs: nowMs,
                        policy: policy
                    )
                )
            }
            groups.append(WorkspaceGroup(workspace: workspace, items: items))
        }
        // 组顺序：可回收体积降序（体积相同按路径字典序），保证同一次扫描的顺序稳定。
        groups.sort {
            $0.deletionBytes == $1.deletionBytes ? $0.workspace < $1.workspace : $0.deletionBytes > $1.deletionBytes
        }

        let liveIds = Set(records.map(\.id))
        let totalBytes = records.reduce(0) { $0 + $1.byteSize }
        let oldest = records.map { $0.ageDays(now: now) }.max() ?? 0
        let deletions = groups.flatMap(\.deletionItems)
        let plannedDeletionPaths = Set(deletions.map(\.record.directory.path))
        let workspaceScan = scanWorkspaces(
            remaining: records.filter { !plannedDeletionPaths.contains($0.directory.path) }
        )

        return CleanupPlan(
            groups: groups,
            orphanEventJournals: orphanEventJournals(liveIds: liveIds),
            fileHistoryZombieIds: ledgerZombieIds(),
            totalSessionCount: records.count,
            totalBytes: totalBytes,
            oldestAgeDays: oldest,
            deletionCount: deletions.count,
            reclaimableBytes: deletions.reduce(0) { $0 + $1.record.byteSize },
            workspaceRemovals: workspaceScan.removals,
            staleBucketIds: workspaceScan.staleBucketIds,
            workspaceCatalogIssue: workspaceScan.issue
        )
    }

    /// 单个 session 的处置结论（合取策略）。
    /// - Parameter rank: 组内按 `updatedAtMs` 降序的名次，0 为最新。
    public static func verdict(
        rank: Int,
        updatedAtMs: Int64,
        nowMs: Int64,
        policy: RetentionPolicy
    ) -> CleanupVerdict {
        if rank < policy.keepCount { return .keepInKeepCount }
        let ageMs = nowMs - updatedAtMs
        // 最近活跃（含 updatedAt 落在未来这种时钟异常）：绝不删。
        if ageMs < Int64(RetentionPolicy.protectMinutes) * 60_000 { return .keepRecentlyActive }
        let ageDays = Double(ageMs) / cleanupDayMs
        if policy.retentionDays > 0 && ageDays < Double(policy.retentionDays) {
            return .keepWithinRetentionDays
        }
        return .delete
    }

    // MARK: - 工作区注册表（workspaces.json）

    private struct WorkspaceCatalog {
        var raw: [String: Any]
        var workspaces: [String: [String: Any]]
        var deletedIds: [String]
    }

    private struct IndexWorkDir {
        let bucket: String
        let workDir: String
    }

    private struct WorkspaceScanResult {
        let removals: [WorkspaceRemoval]
        let staleBucketIds: [String]
        let issue: String?
    }

    /// 与 kimi-code desktop 的 `workspaceRootKey()` 对齐：反斜杠转 `/`、去尾部 `/`、
    /// Windows 形状（盘符 / UNC）转小写；**不**展开 `~`、不解析符号链接、不做 `.`/`..` 归一化。
    public static func workspaceRootKey(_ root: String) -> String {
        let slashed = root.replacingOccurrences(of: "\\", with: "/")
        let windowsShaped = slashed.range(of: #"^([A-Za-z]:/|//)"#, options: .regularExpression) != nil
        var trimmed = slashed
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == "/" { trimmed = "" }
        return windowsShaped ? trimmed.lowercased() : trimmed
    }

    private static func bucketId(of sessionDirectory: URL) -> String {
        sessionDirectory.deletingLastPathComponent().lastPathComponent
    }

    /// 读 `workspaces.json`；缺失 / 损坏 / 形状不对都返回 issue（调用方跳过工作区移除）。
    private func readWorkspaceCatalog() -> (catalog: WorkspaceCatalog?, issue: String?) {
        guard FileManager.default.fileExists(atPath: workspacesURL.path) else {
            return (nil, "未找到 \(workspacesURL.path)")
        }
        guard let data = try? Data(contentsOf: workspacesURL) else {
            return (nil, "无法读取 \(workspacesURL.path)")
        }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, "\(workspacesURL.path) 不是合法的 JSON 对象")
        }
        guard let workspaces = raw["workspaces"] as? [String: [String: Any]] else {
            return (nil, "\(workspacesURL.path) 缺少 workspaces 字段")
        }
        let deleted = (raw["deleted_workspace_ids"] as? [String]) ?? []
        return (WorkspaceCatalog(raw: raw, workspaces: workspaces, deletedIds: deleted), nil)
    }

    /// 从 `session_index.jsonl` 取「bucket id + workDir」对；只用于补齐同 root 的 alias id。
    private func readIndexWorkDirs() -> [IndexWorkDir] {
        guard let raw = try? String(contentsOf: indexURL, encoding: .utf8) else { return [] }
        var out: [IndexWorkDir] = []
        for line in Self.splitLines(raw) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let dir = object["sessionDir"] as? String, dir.hasPrefix("/"),
                  let workDir = object["workDir"] as? String,
                  !workDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let bucket = URL(fileURLWithPath: dir).deletingLastPathComponent().lastPathComponent
            guard !bucket.isEmpty else { continue }
            out.append(IndexWorkDir(bucket: bucket, workDir: workDir))
        }
        return out
    }

    /// 扫描空工作区：
    /// - 按注册表 root 去重（同 root 的多个 alias 条目算一个工作区）；
    /// - 空 = `remaining`（本次删除计划执行后仍存活的 session）里没有任何一个属于该 root；
    /// - `deleted_workspace_ids` 里仍留有**空** bucket 的 id 单独列为待清理目录。
    private func scanWorkspaces(remaining: [ChatSessionRecord]) -> WorkspaceScanResult {
        let loaded = readWorkspaceCatalog()
        guard let catalog = loaded.catalog else {
            return WorkspaceScanResult(removals: [], staleBucketIds: [], issue: loaded.issue)
        }
        let indexDirs = readIndexWorkDirs()

        var entriesByRoot: [String: [(id: String, root: String, name: String)]] = [:]
        for (id, entry) in catalog.workspaces {
            guard let root = (entry["root"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !root.isEmpty
            else { continue }
            let name = (entry["name"] as? String) ?? URL(fileURLWithPath: root).lastPathComponent
            entriesByRoot[Self.workspaceRootKey(root), default: []].append((id, root, name))
        }

        var indexIdsByRoot: [String: Set<String>] = [:]
        for entry in indexDirs {
            indexIdsByRoot[Self.workspaceRootKey(entry.workDir), default: []].insert(entry.bucket)
        }

        var removals: [WorkspaceRemoval] = []
        var registeredIds = Set<String>()
        for (rootKey, entries) in entriesByRoot {
            // 展示用 root 优先选不带尾斜杠的条目，再按 id 字典序，保证跨次扫描稳定。
            let sorted = entries.sorted {
                let lhsClean = !$0.root.hasSuffix("/") && !$0.root.hasSuffix("\\")
                let rhsClean = !$1.root.hasSuffix("/") && !$1.root.hasSuffix("\\")
                if lhsClean != rhsClean { return lhsClean }
                return $0.id < $1.id
            }
            guard let canonical = sorted.first else { continue }
            var aliasIds = Set(sorted.map(\.id))
            aliasIds.formUnion(indexIdsByRoot[rootKey] ?? [])
            registeredIds.formUnion(aliasIds)

            let stillHasSession = remaining.contains { record in
                aliasIds.contains(Self.bucketId(of: record.directory))
                    || Self.workspaceRootKey(record.workspace) == rootKey
            }
            guard !stillHasSession else { continue }
            removals.append(WorkspaceRemoval(
                id: canonical.id,
                root: canonical.root,
                name: canonical.name,
                aliasIds: aliasIds.sorted(),
                rootExists: isDirectory(URL(fileURLWithPath: canonical.root))
            ))
        }
        removals.sort { $0.root < $1.root }

        var stale: [String] = []
        for id in Set(catalog.deletedIds) where !registeredIds.contains(id) {
            let bucket = sessionsRoot.appendingPathComponent(id, isDirectory: true)
            guard isDirectory(bucket), isEmptyDirectoryIgnoringHidden(bucket) else { continue }
            stale.append(id)
        }
        stale.sort()

        return WorkspaceScanResult(removals: removals, staleBucketIds: stale, issue: nil)
    }

    /// 目录里除隐藏项外没有任何内容（`.DS_Store` 不算内容）。
    private func isEmptyDirectoryIgnoringHidden(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        return entries.isEmpty
    }

    /// 枚举 `sessions/<桶>/<session>`。隐藏项（`.index-cache` / `.index-dirty` / `.DS_Store`）直接跳过。
    private func collectSessions() throws -> [ChatSessionRecord] {
        let fm = FileManager.default
        let buckets: [URL]
        do {
            buckets = try fm.contentsOfDirectory(
                at: sessionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw SessionCleanupError.scanFailed("无法读取 session 目录：\(sessionsRoot.path)")
        }

        var out: [ChatSessionRecord] = []
        for bucket in buckets.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard isDirectory(bucket) else { continue }
            let entries = (try? fm.contentsOfDirectory(
                at: bucket,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard isDirectory(entry) else { continue }
                let state = Self.readState(entry.appendingPathComponent("state.json"))
                // 回退链：updatedAt → createdAt → 目录 mtime。
                let updatedAtMs = state.updatedAtMs ?? Self.directoryMtimeMs(entry) ?? 0
                out.append(ChatSessionRecord(
                    id: entry.lastPathComponent,
                    directory: entry,
                    workspace: state.cwd ?? bucket.lastPathComponent,
                    updatedAtMs: updatedAtMs,
                    byteSize: Self.directorySize(entry)
                ))
            }
        }
        return out
    }

    // MARK: - 执行

    /// 执行一个扫描计划。逐项 best-effort：一个删不掉不影响其余的。
    ///
    /// - Parameters:
    ///   - now: 备份文件名的时间戳（本地时区 `yyyyMMddHHmmss`）。
    ///   - allowWorkspaceRemoval: false 时只删 session / 修剪索引与账本，不写 `workspaces.json`、
    ///     不删空 bucket / 空账本。调用方在 Kimi Code 桌面端运行时传 false，避免与其写盘竞争。
    public func apply(
        plan: CleanupPlan,
        now: Date,
        allowWorkspaceRemoval: Bool = true
    ) async -> CleanupOutcome {
        applySync(plan: plan, now: now, allowWorkspaceRemoval: allowWorkspaceRemoval)
    }

    private func applySync(
        plan: CleanupPlan,
        now: Date,
        allowWorkspaceRemoval: Bool
    ) -> CleanupOutcome {
        let fm = FileManager.default
        var failures: [String] = []
        var deletedSessions = 0
        var reclaimed = 0

        // 1. session 目录整目录删除。
        for item in plan.deletionItems {
            let path = item.record.directory.path
            guard fm.fileExists(atPath: path) else { continue }
            do {
                try fm.removeItem(at: item.record.directory)
                deletedSessions += 1
                reclaimed += item.record.byteSize
            } catch {
                failures.append("\(path)（\(error.localizedDescription)）")
            }
        }

        // 2. 孤儿事件 journal：删完 session 目录后**重新枚举**一次，
        //    这样本次删掉的 session 的 journal 也会被判定为孤儿。
        let liveIds = Set(((try? collectSessions()) ?? []).map(\.id))
        var deletedJournals = 0
        for url in orphanEventJournals(liveIds: liveIds) {
            do {
                try fm.removeItem(at: url)
                deletedJournals += 1
            } catch {
                failures.append("\(url.path)（\(error.localizedDescription)）")
            }
        }

        // 3. session_index.jsonl 修剪（只摘掉指向已消失目录的行）。
        let indexRemoved = pruneIndex(now: now, failures: &failures)
        // 4. file-history 账本修剪。
        let ledgerRemoved = pruneFileHistory(failures: &failures)

        // 5. 工作区级动作：注销空工作区 + 清空 bucket / 空账本。
        var workspaceResult = WorkspaceApplyResult()
        var workspaceActionsSkipped = false
        if !allowWorkspaceRemoval {
            workspaceActionsSkipped = !plan.workspaceRemovals.isEmpty || !plan.staleBucketIds.isEmpty
            workspaceResult.issue = plan.workspaceCatalogIssue
        } else if !plan.workspaceRemovals.isEmpty || !plan.staleBucketIds.isEmpty {
            workspaceResult = applyWorkspaceRemovals(plan: plan, now: now, failures: &failures)
        } else {
            workspaceResult.issue = plan.workspaceCatalogIssue
        }

        return CleanupOutcome(
            deletedSessionCount: deletedSessions,
            deletedEventJournalCount: deletedJournals,
            reclaimedBytes: reclaimed,
            fileHistoryIdsRemoved: ledgerRemoved,
            indexRecordsRemoved: indexRemoved,
            failures: failures,
            removedWorkspaceCount: workspaceResult.removedWorkspaces,
            deletedEmptyBucketCount: workspaceResult.deletedBuckets,
            deletedEmptyLedgerCount: workspaceResult.deletedLedgers,
            skippedWorkspaceCount: workspaceResult.skipped,
            workspaceActionsSkipped: workspaceActionsSkipped,
            workspaceCatalogIssue: workspaceResult.issue
        )
    }

    // MARK: - 工作区级执行

    private struct WorkspaceApplyResult {
        var removedWorkspaces = 0
        var deletedBuckets = 0
        var deletedLedgers = 0
        var skipped = 0
        var issue: String?
    }

    /// 按「预览后重新读取 + 重新校验」的纪律执行工作区移除（ADR-0009）。
    /// 不把扫描时的整份快照覆盖回磁盘；只删此刻仍注册、且此刻仍为空的工作区。
    private func applyWorkspaceRemovals(
        plan: CleanupPlan,
        now: Date,
        failures: inout [String]
    ) -> WorkspaceApplyResult {
        var result = WorkspaceApplyResult()
        let loaded = readWorkspaceCatalog()
        guard var catalog = loaded.catalog else {
            result.issue = loaded.issue
            return result
        }

        let currentRecords = (try? collectSessions()) ?? []
        let indexDirs = readIndexWorkDirs()

        var registryIdsByRoot: [String: Set<String>] = [:]
        for (id, entry) in catalog.workspaces {
            guard let root = (entry["root"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !root.isEmpty
            else { continue }
            registryIdsByRoot[Self.workspaceRootKey(root), default: []].insert(id)
        }
        var indexIdsByRoot: [String: Set<String>] = [:]
        for entry in indexDirs {
            indexIdsByRoot[Self.workspaceRootKey(entry.workDir), default: []].insert(entry.bucket)
        }

        var tombstones = catalog.deletedIds
        var tombstoneSet = Set(tombstones)
        var bucketIds = Set<String>()

        for removal in plan.workspaceRemovals {
            let rootKey = Self.workspaceRootKey(removal.root)
            guard let currentRegistryIds = registryIdsByRoot[rootKey], !currentRegistryIds.isEmpty else {
                // 预览之后已经被 desktop 移除（或没有对应注册条目）：不重复计数。
                result.skipped += 1
                continue
            }
            var aliasIds = currentRegistryIds
            aliasIds.formUnion(indexIdsByRoot[rootKey] ?? [])
            aliasIds.formUnion(removal.aliasIds)

            let stillHasSession = currentRecords.contains { record in
                aliasIds.contains(Self.bucketId(of: record.directory))
                    || Self.workspaceRootKey(record.workspace) == rootKey
            }
            guard !stillHasSession else {
                result.skipped += 1
                continue
            }

            for id in aliasIds {
                bucketIds.insert(id)
                if tombstoneSet.insert(id).inserted { tombstones.append(id) }
            }
            catalog.workspaces = catalog.workspaces.filter { _, entry in
                guard let root = (entry["root"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !root.isEmpty
                else { return true }
                return Self.workspaceRootKey(root) != rootKey
            }
            result.removedWorkspaces += 1
        }

        // 已撤销注册、但磁盘上仍留有空的 bucket：只清目录，不动注册表。
        var remainingRoots = Set<String>()
        for (_, entry) in catalog.workspaces {
            guard let root = (entry["root"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !root.isEmpty
            else { continue }
            remainingRoots.insert(Self.workspaceRootKey(root))
        }
        var registeredIds = Set<String>()
        for rootKey in remainingRoots {
            registeredIds.formUnion(registryIdsByRoot[rootKey] ?? [])
            registeredIds.formUnion(indexIdsByRoot[rootKey] ?? [])
        }
        for id in Set(catalog.deletedIds).union(plan.staleBucketIds) where !registeredIds.contains(id) {
            let bucket = sessionsRoot.appendingPathComponent(id, isDirectory: true)
            guard isDirectory(bucket), isEmptyDirectoryIgnoringHidden(bucket) else { continue }
            bucketIds.insert(id)
        }

        let entriesChanged = result.removedWorkspaces > 0
        let tombstonesChanged = tombstones.count != catalog.deletedIds.count
        if entriesChanged || tombstonesChanged {
            guard writeWorkspaceCatalog(catalog, tombstones: tombstones, now: now, failures: &failures) else {
                // 注册表写失败时不继续删 bucket / 账本：宁可留空目录，也不让注册表与磁盘进一步不一致。
                return result
            }
        }

        let fm = FileManager.default
        for id in bucketIds.sorted() {
            let bucket = sessionsRoot.appendingPathComponent(id, isDirectory: true)
            guard isDirectory(bucket), isEmptyDirectoryIgnoringHidden(bucket) else { continue }
            do {
                try fm.removeItem(at: bucket)
                result.deletedBuckets += 1
            } catch {
                failures.append("\(bucket.path)（\(error.localizedDescription)）")
            }
        }

        for id in bucketIds.sorted() {
            let ledger = fileHistoryDirectory.appendingPathComponent(id)
            guard let sessions = Self.readLedgerSessions(ledger), sessions.isEmpty else { continue }
            do {
                try fm.removeItem(at: ledger)
                result.deletedLedgers += 1
            } catch {
                failures.append("\(ledger.path)（\(error.localizedDescription)）")
            }
        }

        return result
    }

    /// 原子写 `workspaces.json`：有改动才调用；写前备份为 `workspaces.json.bak-<yyyyMMddHHmmss>`。
    private func writeWorkspaceCatalog(
        _ catalog: WorkspaceCatalog,
        tombstones: [String],
        now: Date,
        failures: inout [String]
    ) -> Bool {
        var raw = catalog.raw
        raw["workspaces"] = catalog.workspaces
        raw["deleted_workspace_ids"] = tombstones
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) else {
            failures.append("\(workspacesURL.path)（无法序列化）")
            return false
        }
        let fm = FileManager.default
        let backup = Self.backupURL(for: workspacesURL, now: now)
        do {
            try fm.copyItem(at: workspacesURL, to: backup)
        } catch {
            failures.append("\(workspacesURL.path)（备份失败：\(error.localizedDescription)）")
            return false
        }
        let tmp = URL(fileURLWithPath: workspacesURL.path + ".tmp")
        do {
            try data.write(to: tmp)
            _ = try fm.replaceItemAt(workspacesURL, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            failures.append("\(workspacesURL.path)（写入失败：\(error.localizedDescription)）")
            return false
        }
        return true
    }

    /// 同一秒内重复清理时不要让备份互相覆盖：已存在则追加 `-2`、`-3`…
    private static func backupURL(for url: URL, now: Date) -> URL {
        let base = url.path + ".bak-\(timestamp(now))"
        let fm = FileManager.default
        guard fm.fileExists(atPath: base) else { return URL(fileURLWithPath: base) }
        var suffix = 2
        while fm.fileExists(atPath: "\(base)-\(suffix)") { suffix += 1 }
        return URL(fileURLWithPath: "\(base)-\(suffix)")
    }

    /// 无对应 session 目录的 `server/events/session_*.jsonl`。
    ///
    /// 铁律：`__global__.jsonl` 永不入选（它不以 `session_` 开头），不匹配 `session_*.jsonl`
    /// 的文件也永不入选。
    private func orphanEventJournals(liveIds: Set<String>) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )) ?? []
        return entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("session_"), name.hasSuffix(".jsonl") else { return false }
            let stem = String(name.dropLast(".jsonl".count))
            return !liveIds.contains(stem)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - session_index.jsonl

    /// 只移除「有 `sessionDir` 字段且该目录已不存在」的行。
    /// 墓碑行（无 `sessionDir`）与不可解析的行**原样保留**（逐字写回，不重新序列化）；
    /// `sessionDir` 不是非空绝对路径的行也原样保留 —— 路径形态不对时无法判定「该目录」是否存在，
    /// 这种情况下保留一行只是留个残条，删掉一行却可能丢掉一个活着的 session。
    /// 有改动才写：先备份 `session_index.jsonl.bak-<yyyyMMddHHmmss>`（本地时区），再原子替换。
    private func pruneIndex(now: Date, failures: inout [String]) -> Int {
        let fm = FileManager.default
        guard let raw = try? String(contentsOf: indexURL, encoding: .utf8) else { return 0 }
        let hadTrailingNewline = raw.hasSuffix("\n")

        var kept: [String] = []
        var removed = 0
        for line in Self.splitLines(raw) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let dir = object["sessionDir"] as? String,
                  dir.hasPrefix("/")
            else {
                kept.append(line)
                continue
            }
            if isDirectory(URL(fileURLWithPath: dir)) {
                kept.append(line)
            } else {
                removed += 1
            }
        }
        guard removed > 0 else { return 0 }

        let backup = URL(fileURLWithPath: indexURL.path + ".bak-\(Self.timestamp(now))")
        do {
            try fm.copyItem(at: indexURL, to: backup)
        } catch {
            // 备份不成功就不改原文件：宁可不清理，也不留下不可回退的改动。
            failures.append("\(indexURL.path)（备份失败：\(error.localizedDescription)）")
            return 0
        }

        let text = kept.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
        let tmp = URL(fileURLWithPath: indexURL.path + ".tmp")
        do {
            try Data(text.utf8).write(to: tmp)
            _ = try fm.replaceItemAt(indexURL, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            failures.append("\(indexURL.path)（写入失败：\(error.localizedDescription)）")
            return 0
        }
        return removed
    }

    // MARK: - file-history 账本

    /// `<桶>/<id>` 目录已不存在的条目数（含脚本以前遗留的僵尸条目）。
    /// 解析失败的文件一律不动，也不计入。
    private func ledgerZombieIds() -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: fileHistoryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var out: [String] = []
        for file in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let sessions = Self.readLedgerSessions(file) else { continue }
            let bucket = file.lastPathComponent
            for entry in sessions {
                guard let id = entry["id"] as? String, !id.isEmpty else { continue }
                if !isDirectory(sessionDirectory(bucket: bucket, id: id)) { out.append(id) }
            }
        }
        return out
    }

    /// 摘掉账本里目录已不存在的条目；全部条目被摘掉时写成 `{"sessions":[]}`（不删文件）。
    /// 有改动才写，原子替换，不备份（文件很小）。
    private func pruneFileHistory(failures: inout [String]) -> Int {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: fileHistoryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var removedTotal = 0
        for file in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: file),
                  var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessions = root["sessions"] as? [[String: Any]]
            else { continue }

            let bucket = file.lastPathComponent
            let kept = sessions.filter { entry in
                guard let id = entry["id"] as? String, !id.isEmpty else { return true }
                return isDirectory(sessionDirectory(bucket: bucket, id: id))
            }
            let removed = sessions.count - kept.count
            guard removed > 0 else { continue }
            root["sessions"] = kept
            guard let out = try? JSONSerialization.data(withJSONObject: root, options: []) else { continue }

            let tmp = URL(fileURLWithPath: file.path + ".tmp")
            do {
                try out.write(to: tmp)
                _ = try fm.replaceItemAt(file, withItemAt: tmp)
                removedTotal += removed
            } catch {
                try? fm.removeItem(at: tmp)
                failures.append("\(file.path)（\(error.localizedDescription)）")
            }
        }
        return removedTotal
    }

    // MARK: - 文件系统小工具

    private func sessionDirectory(bucket: String, id: String) -> URL {
        sessionsRoot.appendingPathComponent(bucket, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 目录内全部文件的字节数合计（`lstat` 语义，不跟随符号链接）。
    private static func directorySize(_ url: URL) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total = 0
        for case let child as URL in walker {
            guard let attrs = try? fm.attributesOfItem(atPath: child.path),
                  (attrs[.type] as? FileAttributeType) != .typeDirectory
            else { continue }
            total += (attrs[.size] as? NSNumber)?.intValue ?? 0
        }
        return total
    }

    private static func directoryMtimeMs(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// `state.json` 的 `cwd` 与毫秒时间戳（`updatedAt` → `createdAt`）。
    private static func readState(_ url: URL) -> (cwd: String?, updatedAtMs: Int64?) {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return (nil, nil) }
        let cwd = (json["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = int64Value(json["updatedAt"]) ?? int64Value(json["createdAt"])
        return (cwd?.isEmpty == false ? cwd : nil, (stamp ?? 0) == 0 ? nil : stamp)
    }

    /// 账本文件的 `sessions` 数组；解析失败 / 形状不对 → nil（调用方跳过该文件）。
    private static func readLedgerSessions(_ url: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return root["sessions"] as? [[String: Any]]
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String, let i = Int64(s) { return i }
        return nil
    }

    /// 按 `\n` 切行；丢掉末尾换行产生的空尾元素（写回时再补一个换行）。
    private static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// 本地时区的 `yyyyMMddHHmmss`（备份文件名用；固定名字会覆盖历史备份）。
    private static func timestamp(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: now)
    }
}
