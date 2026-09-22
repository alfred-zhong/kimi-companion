import Foundation

/// kimi-code 会话记录增量读取：`sessions/<workspace>/<session>/agents/<agent>/wire.jsonl`。
///
/// **契约**：`events(now:)` 返回「保留窗口内的 usage 事件集合」，等价于
/// 「按当前文件系统状态完整重扫一遍得到的同一集合」。
/// 保留窗口 = `tsMs >= min(当日零点, now − 12h)`，与 mtime 剪枝边界同值。
///
/// **实现**：进程内持有每个文件的 Read Cursor（已消费偏移 + 指纹 + 未成行的尾部字节），
/// 每次调用只读取自上次以来被追加的字节；窗口内事件与去重键随 `now` 前进淘汰。不落盘。
///
/// **为什么必须遍历全部 `agents/*/wire.jsonl`**：每个 agent 的文件完全独立、跨文件零重复
/// （实测 600 条记录 600 个不同签名，0 条出现在多个文件里）。只读 `main` 会严重漏计
/// （实测某 session 的 output：main 48k，全部 agent 合计 123k）。
///
/// 同步阻塞 I/O：调用方保证不在主线程上直接调用。
/// 线程安全：整个 `events(now:)` 由内部 `NSLock` 串行化 —— 60s timer tick 与菜单「立即刷新」
/// 可能产生两个重叠的 `Task`。
public final class WireLogReader: @unchecked Sendable {
    public let sessionsRoot: String
    public let parser: WireLineParser

    private let lock = NSLock()
    /// 每文件读取状态，键为相对 sessions 根的 POSIX 路径。
    private var cursors: [String: FileCursor] = [:]
    /// 保留窗口内的事件（插入序；`retainedHead` 之前的部分已淘汰、等待压缩）。
    private var retained: [UsageEvent] = []
    private var retainedHead = 0
    /// `retained` 内事件去重键的索引。文件失效重读时防止同一事件被重复计入。
    private var seenKeys: Set<String> = []
    /// 上一次的窗口边界；用于识别时钟回拨。
    private var lastBoundaryMs: Int64?

    public init(sessionsRoot: String, parser: WireLineParser = WireLineParser()) {
        self.sessionsRoot = sessionsRoot
        self.parser = parser
    }

    /// 本机时区当日零点（ms）。
    public func todayStartMs(now: Date) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let startOfDay = cal.date(from: comps) ?? now
        return Int64(startOfDay.timeIntervalSince1970 * 1000)
    }

    /// 保留窗口下界（ms）= `min(当日零点, now − 12h)`；同时是 mtime 剪枝边界。
    public func boundaryMs(now: Date) -> Int64 {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return min(todayStartMs(now: now), nowMs - Int64(HOUR_BUCKET_COUNT) * HOUR_MS)
    }

    /// 推进所有游标，返回保留窗口内的事件。返回顺序未定义。
    public func events(now: Date = Date()) -> [UsageEvent] {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsRoot) else {
            resetAll()
            return []
        }

        let boundary = boundaryMs(now: now)
        // 淘汰的正确性依赖边界单调不减；倒退说明时钟被改过，游标与窗口都不可信 → 全量重来一次。
        if let last = lastBoundaryMs, boundary < last {
            resetAll()
        }
        lastBoundaryMs = boundary

        var touched: Set<String> = []
        collect(dir: sessionsRoot, relPath: "", boundaryMs: boundary, touched: &touched)

        // walk 没见到的文件：已删除，或 mtime 已滑出剪枝边界（后者的事件必然也已滑出窗口）。
        let stale = cursors.keys.filter { !touched.contains($0) }
        for key in stale {
            cursors.removeValue(forKey: key)
            purgeRetained(path: key)
        }

        evict(below: boundary)
        return Array(retained[retainedHead...])
    }

    // MARK: - 文件状态

    /// 单文件读取游标。`offset` 始终停在某个完整行之后；`carry` 持有其后已读入但尚未成行的字节。
    private struct FileCursor {
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var mtimeMs: Int64 = 0
        /// 文件身份（APFS inode）；文件被替换时它与旧值不等。
        var identity: NSObject?
        var carry = Data()
    }

    private static let scanKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey,
    ]

    private func collect(dir: String, relPath: String, boundaryMs: Int64, touched: inout Set<String>) {
        let fm = FileManager.default
        // 一次性预取本 tick 需要的全部属性，下面每次 resourceValues 都是缓存命中（不再走 syscall）。
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: Array(Self.scanKeys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            let childRel = relPath.isEmpty ? name : "\(relPath)/\(name)"
            guard let values = try? entry.resourceValues(forKeys: Self.scanKeys) else { continue }
            if values.isDirectory == true {
                collect(dir: entry.path, relPath: childRel, boundaryMs: boundaryMs, touched: &touched)
                continue
            }
            guard name == "wire.jsonl" else { continue }
            let mtimeMs = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            // mtime 剪枝：早于边界的文件，其全部记录按时间序也必然在窗口之外，整file跳过。
            guard mtimeMs >= boundaryMs else { continue }
            touched.insert(childRel)
            processFile(
                path: entry.path,
                relPath: childRel,
                size: UInt64(max(values.fileSize ?? 0, 0)),
                mtimeMs: mtimeMs,
                identity: values.fileResourceIdentifier as? NSObject,
                boundaryMs: boundaryMs
            )
        }
    }

    private func processFile(
        path: String,
        relPath: String,
        size: UInt64,
        mtimeMs: Int64,
        identity: NSObject?,
        boundaryMs: Int64
    ) {
        let existing = cursors[relPath]
        var cursor = existing ?? FileCursor()

        if let e = existing {
            let readPoint = e.offset + UInt64(e.carry.count)
            if let prev = e.identity, let now = identity, !prev.isEqual(now) {
                // 文件被替换：旧 inode 的内容整体作废。
                purgeRetained(path: relPath)
                cursor = FileCursor()
            } else if size < readPoint {
                // 被截断：已读位置之后的内容作废。
                purgeRetained(path: relPath)
                cursor = FileCursor()
            } else if size == readPoint && mtimeMs > e.mtimeMs {
                // 长度不变而 mtime 前进 = 原地改写（追加必然改变长度）。
                purgeRetained(path: relPath)
                cursor = FileCursor()
            }
        }

        cursor.size = size
        cursor.mtimeMs = mtimeMs
        cursor.identity = identity

        let readFrom = cursor.offset + UInt64(cursor.carry.count)
        if size > readFrom, let chunk = read(path: path, from: readFrom, maxBytes: size - readFrom) {
            ingest(chunk, relPath: relPath, cursor: &cursor, boundaryMs: boundaryMs)
        }
        cursors[relPath] = cursor
    }

    private func read(path: String, from offset: UInt64, maxBytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        // 只读 stat 时点之前的那一段：期间新追加的字节留给下一次调用。
        return (try? handle.read(upToCount: Int(maxBytes))) ?? nil
    }

    /// 消费一段新读入的字节：补上未成行的 carry，按行解析，把剩下的尾部留作新的 carry。
    private func ingest(_ chunk: Data, relPath: String, cursor: inout FileCursor, boundaryMs: Int64) {
        var buffer = cursor.carry
        buffer.append(chunk)
        cursor.carry = Data()

        // 游标只推进到最后一个完整换行：写入中的半行留到下一次拼接，否则那行会被永久跳过。
        guard let lastNewline = buffer.lastIndex(of: 0x0a) else {
            cursor.carry = buffer
            return
        }
        let complete = buffer[buffer.startIndex...lastNewline]
        if lastNewline < buffer.index(before: buffer.endIndex) {
            cursor.carry = Data(buffer[buffer.index(after: lastNewline)...])
        }

        var lineStart = complete.startIndex
        for index in complete.indices where complete[index] == 0x0a {
            let lineBytes = complete.distance(from: lineStart, to: index)
            if lineBytes > 0 {
                ingestLine(
                    Data(complete[lineStart..<index]),
                    relPath: relPath,
                    lineOffset: cursor.offset,
                    boundaryMs: boundaryMs
                )
            }
            // 空行也推进游标，否则偏移会与真实行首位置错位（进而让去重键不稳定）。
            cursor.offset += UInt64(lineBytes) + 1
            lineStart = complete.index(after: index)
        }
    }

    private func ingestLine(_ line: Data, relPath: String, lineOffset: UInt64, boundaryMs: Int64) {
        guard let text = String(data: line, encoding: .utf8) else { return }
        guard let event = parser.parse(line: text, relPath: relPath, lineOffset: lineOffset) else { return }
        guard event.tsMs >= boundaryMs else { return }
        guard seenKeys.insert(event.dedupeKey).inserted else { return }
        retained.append(event)
    }

    // MARK: - 窗口淘汰

    private func evict(below boundaryMs: Int64) {
        while retainedHead < retained.count, retained[retainedHead].tsMs < boundaryMs {
            seenKeys.remove(retained[retainedHead].dedupeKey)
            retainedHead += 1
        }
        // 头部空洞过大时压缩，避免数组无限增长。
        if retainedHead >= 1024, retainedHead * 2 >= retained.count {
            retained.removeFirst(retainedHead)
            retainedHead = 0
        }
    }

    /// 丢弃某个文件贡献的全部保留事件（文件被截断 / 替换 / 删除 / mtime 剪掉时）。
    private func purgeRetained(path: String) {
        if retainedHead > 0 {
            retained.removeFirst(retainedHead)
            retainedHead = 0
        }
        guard !retained.isEmpty else { return }
        let prefix = "\(path):"
        var kept: [UsageEvent] = []
        kept.reserveCapacity(retained.count)
        for event in retained {
            if event.dedupeKey.hasPrefix(prefix) {
                seenKeys.remove(event.dedupeKey)
            } else {
                kept.append(event)
            }
        }
        retained = kept
    }

    private func resetAll() {
        cursors.removeAll()
        retained.removeAll()
        retainedHead = 0
        seenKeys.removeAll()
        lastBoundaryMs = nil
    }
}
