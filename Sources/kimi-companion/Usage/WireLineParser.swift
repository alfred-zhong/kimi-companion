import Foundation

/// `wire.jsonl` 单行解析：认 `usage.record` 与 `llm.request` 两种行。
///
/// 一次模型调用在 wire 里留两条行（形状如下，`llm.request` 在前、`usage.record` 在后）：
/// ```json
/// {"type":"llm.request","agentId":"main","provider":"openai","model":"deepseek-v4.1-flash",
///  "modelAlias":"OpenCode Go/deepseek-v4.1-flash","kind":"loop","turnStep":"0.1","time":1791598954798}
/// {"type":"usage.record","agentId":"main","model":"OpenCode Go/deepseek-v4.1-flash",
///  "usage":{"inputOther":18938,"output":187,"inputCacheRead":145024,"inputCacheCreation":0},
///  "usageScope":"turn","time":1791598959387}
/// ```
/// 五条实测结论：
/// 1. `time` 是 **epoch 毫秒**；文件里没有任何 ISO 时间字段（`usage.record` 上尤其没有）。
/// 2. `usage.record` 是**单次 LLM 调用的增量**，不是累计快照
///    （同一 session 的 `output` 序列实测非单调：187 → 165 → 170 → 1654 → …）。
///    因此直接按其字段求和，**不做差分**。
/// 3. `llm.request` 在**发起前**落盘（`time` = 发起时刻），`usage.record` 在**返回后**落盘（`time` = 返回时刻）。
///    两者对同一次调用配对，但**不是一一对应**：重试（`turn.step.retrying`）与被中断
///    （`turn.step.interrupted` / `turn.cancel` / `prompt.aborted`）的尝试只有 `llm.request`。
///    因此 `llm.request` 行数 ≥ `usage.record` 行数（本机 83 个 wire 文件实测 3133 : 3103）。
/// 4. `llm.request` 只贡献 `requestCount = 1`（token 计数全 0），`usage.record` 只贡献 token
///    （`requestCount = 0`）——一条行只产出一个 `UsageEvent`，两种事实各自求和。
/// 5. 不读 `model` / `modelAlias`：用量与请求数都已合并统计、不归属到 provider（ADR-0006），
///    parser 不解析任何归属字段。（历史依据：`llm.request.provider` 的值是 wire 协议类型 `"openai"`，
///    所有 provider 都是它，本来也不能用于归属。）
public struct WireLineParser: Sendable {
    public init() {}

    /// 解析单行。返回 `nil` 表示不计入统计。
    /// - Parameters:
    ///   - line: 原始一行（不含换行符）
    ///   - relPath: 相对 sessions 根目录的 POSIX 路径，用作去重键的 file 段
    ///   - lineOffset: 该行在文件中的起始字节偏移，用作去重键的稳定序号
    public func parse(line: String, relPath: String, lineOffset: UInt64) -> UsageEvent? {
        // 行预过滤：必须含两种行标识之一（一行可达 21 KB，先做零解析的拒否）。
        // 嵌入在 `context.append_loop_event` 里的同名字符串会通过这一关，但被下面的 `type` 判定挡掉。
        guard line.contains("\"usage.record\"") || line.contains("\"llm.request\"") else { return nil }
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let tsMs = int64Value(json["time"]) else { return nil }

        switch json["type"] as? String {
        case "usage.record":
            let usage = json["usage"] as? [String: Any] ?? [:]
            return UsageEvent(
                tsMs: tsMs,
                inputOther: intValue(usage["inputOther"]),
                output: intValue(usage["output"]),
                cacheRead: intValue(usage["inputCacheRead"]),
                cacheCreation: intValue(usage["inputCacheCreation"]),
                requestCount: 0,
                dedupeKey: "\(relPath):\(lineOffset)"
            )
        case "llm.request":
            return UsageEvent(
                tsMs: tsMs,
                inputOther: 0,
                output: 0,
                cacheRead: 0,
                cacheCreation: 0,
                requestCount: 1,
                dedupeKey: "\(relPath):\(lineOffset)"
            )
        default:
            return nil
        }
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
    public let inputOther: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheCreation: Int
    /// `1` = 一条 `llm.request`（发起一次调用）；`0` = 一条 `usage.record`（拿到一次调用的 usage）。
    public let requestCount: Int
    public let dedupeKey: String

    public init(
        tsMs: Int64,
        inputOther: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        requestCount: Int = 0,
        dedupeKey: String
    ) {
        self.tsMs = tsMs
        self.inputOther = inputOther
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.requestCount = requestCount
        self.dedupeKey = dedupeKey
    }

    public var stats: TokenStats {
        TokenStats(
            inputTokens: inputOther,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            requestCount: requestCount
        )
    }
}
