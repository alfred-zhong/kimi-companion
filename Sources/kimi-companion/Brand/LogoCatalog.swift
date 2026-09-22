import AppKit
import Foundation

/// 状态栏 logo 查表：`ProviderID` → `NSImage`。资源在 `.app/Contents/Resources/` 下，
/// 由 `build.sh` 从 `Resources/*.png` 复制过去。
///
/// 加载时一次性 `setTemplate(true)`，让 AppKit 按系统菜单栏灰度重新着色（dark/light 自动跟随）。
///
/// **未知 / 未匹配 provider 返回 nil**：宁可只显示文字，也不借用别家 vendor 的 logo —— 那会误导用户。
/// 因此本项目没有 omp-companion 的 `.color.png` 兜底资源；caffeinate 激活时的白色副本由
/// `StatusBarController.whiteFilled(template:)` 在运行时从 template 派生。
///
/// Bundle URL 解析坑：`Bundle.main.url(forResource:withExtension:)` 不识别 `@2x`/`@3x`
/// scale suffix，故查找时先剥掉后缀；`.app` 进程里唯一可靠的兜底是 `Bundle.resourcePath`
/// （= `.app/Contents/Resources`）。
public enum LogoCatalog {

    /// provider → 资源基名；未知 provider 为 nil（有意为之）。
    static func assetBaseName(for id: ProviderID) -> String? {
        switch id {
        case .deepseek: return "provider_deepseek"
        case .opencodeGo: return "provider_opencode_go"
        case .unknown: return nil
        }
    }

    /// 在给定 bundle 里查 logo，命中后立即标记为 template。未命中返回 nil。
    /// 调用方约定把同一个 `NSImage` 缓存到自己的字段，避免每次刷新触发 I/O。
    public static func image(for id: ProviderID, bundle: Bundle = .main) -> NSImage? {
        guard let base = assetBaseName(for: id) else { return nil }

        // 1) 标准 Bundle API：剥掉 @2x/@3x 再查，NSImage 会按主屏 backing 自动选最匹配的 rep。
        for name in scaleCandidates(base: base) {
            let stripped = dropScaleSuffix(name)
            if let url = bundle.url(forResource: stripped, withExtension: "png")
                ?? bundle.url(forResource: stripped, withExtension: "png", subdirectory: "Resources"),
               let img = NSImage(contentsOf: url) {
                return markTemplate(img)
            }
        }

        // 2) 兜底：直接拼到 Bundle.resourcePath（.app/Contents/Resources）。
        guard let resourceDir = bundle.resourcePath else { return nil }
        for name in scaleCandidates(base: base) {
            let path = URL(fileURLWithPath: resourceDir).appendingPathComponent("\(name).png").path
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOf: URL(fileURLWithPath: path)) {
                return markTemplate(img)
            }
        }
        return nil
    }

    private static func markTemplate(_ img: NSImage) -> NSImage {
        img.size = NSSize(width: 16, height: 16)
        img.setValue(true, forKey: "template")
        return img
    }

    private static func scaleCandidates(base: String) -> [String] {
        let scale: Int = {
            if let s = NSScreen.main?.backingScaleFactor, s > 0 { return Int(s.rounded()) }
            return 2
        }()
        return scale >= 3 ? ["\(base)@3x", "\(base)@2x"] : ["\(base)@2x", "\(base)@3x"]
    }

    private static func dropScaleSuffix(_ name: String) -> String {
        for suffix in ["@3x", "@2x", "@1x"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// 给 SelfCheck 用：每个受支持 provider 的 logo 是否可从给定 bundle 取到。
    public static func debugAssertsAvailable(bundle: Bundle) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for id in ProviderID.allCases {
            out[String(describing: id)] = image(for: id, bundle: bundle) != nil
        }
        return out
    }
}
