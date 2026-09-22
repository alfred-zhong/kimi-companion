import Foundation

/// `wire.jsonl` 单行解析：只认 `usage.record`。
///
/// 记录形状（顶层键恒为 `type, agentId, model, usage, usageScope, time`）：
/// ```json
/// {"type":"usage.record","agentId":"main","model":"DeepSeek/deepseek-flash",
///  "usage":{"inputOther":18938,"output":187,"inputCacheRead":145024,"inputCacheCreation":0},
///  "usageScope":"turn","time":1790065336874}
/// ```
/// 三条实测结论：
/// 1. `time` 是 **epoch 毫秒**；文件里没有任何 ISO 时间字段（`usage.record` 上尤其没有）。
/// 2. `usage.record` 是**单次 LLM 调用的增量**，不是累计快照
///    （同一 session 的 `output` 序列实测非单调：187 → 165 → 170 → 1654 → …）。
///    因此直接按其字段求和，**不做差分**。
/// 3. 归属只能看 `model` 的 `<Provider>/<model>` 前缀。**不能**用 `llm.request.provider` ——
///    那里的值是 wire 协议类型 `"openai"`，两个 provider 都是它。
public struct WireLineParser: Sendable {
    public init() {}

    /// 解析单行。返回 `nil` 表示不计入统计。
    /// - Parameters:
    ///   - line: 原始一行（不含换行符）
    ///   - relPath: 相对 sessions 根目录的 POSIX 路径，用作去重键的 file 段
    ///   - lineOffset: 该行在文件中的起始字节偏移，用作去重键的稳定序号
    public func parse(line: String, relPath: String, lineOffset: UInt64) -> UsageEvent? {
        // 行预过滤：必须含 "usage.record" 子串（一行可达 21 KB，先做零解析的拒否）
        guard line.contains("\"usage.record\"") else { return nil }
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (json["type"] as? String) == "usage.record" else { return nil }
        guard let model = json["model"] as? String else { return nil }
        guard let tsMs = int64Value(json["time"]) else { return nil }

        let usage = json["usage"] as? [String: Any] ?? [:]
        return UsageEvent(
            tsMs: tsMs,
            provider: ProviderID.fromModelPrefix(prefix(of: model)),
            inputOther: intValue(usage["inputOther"]),
            output: intValue(usage["output"]),
            cacheRead: intValue(usage["inputCacheRead"]),
            cacheCreation: intValue(usage["inputCacheCreation"]),
            dedupeKey: "\(relPath):\(lineOffset)"
        )
    }

    /// `"OpenCode Go/deepseek-v4.1-flash"` → `"OpenCode Go"`（含空格，逐字保留）。
    private func prefix(of model: String) -> String {
        guard let slash = model.firstIndex(of: "/") else { return model }
        return String(model[..<slash])
    }

    private func intValue(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s) { return i }
        return 0
    }

    private func int64Value(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let i = Int64(s) { return i }
        return nil
    }
}

public struct UsageEvent: Sendable, Equatable {
    public let tsMs: Int64
    /// 由 `model` 前缀解析出的归属；未匹配受支持 provider 时为 `.unknown`（归入「其他」）。
    public let provider: ProviderID
    public let inputOther: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheCreation: Int
    public let dedupeKey: String

    public init(
        tsMs: Int64,
        provider: ProviderID,
        inputOther: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        dedupeKey: String
    ) {
        self.tsMs = tsMs
        self.provider = provider
        self.inputOther = inputOther
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.dedupeKey = dedupeKey
    }

    public var stats: TokenStats {
        TokenStats(
            inputTokens: inputOther,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead
        )
    }
}
