import Foundation

/// 正文按 UTF-8 字节适配预览与阅读，详情原始正文承接编辑和分享。
public nonisolated enum CommunityTextLimits {
    public static let maximumDisplayBytes = 64 * 1_024
    public static let maximumPreviewBytes = 1_024
    public static let linkCacheBytes = 8 * 1_024 * 1_024

    public static func requiresFullReading(_ text: String) -> Bool {
        text.utf8.index(text.utf8.startIndex, offsetBy: maximumDisplayBytes + 1, limitedBy: text.utf8.endIndex) != nil
    }

    public static func displayText(_ text: String, preview: Bool = false) -> String {
        let limit = preview ? maximumPreviewBytes : maximumDisplayBytes
        guard text.utf8.index(text.utf8.startIndex, offsetBy: limit + 1, limitedBy: text.utf8.endIndex) != nil else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: limit - "…".utf8.count)
        while end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end]) + "…"
    }
}
