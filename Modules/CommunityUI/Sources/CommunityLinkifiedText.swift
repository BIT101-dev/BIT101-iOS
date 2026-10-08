#if os(iOS)
import CommunityCore
import Foundation
import SwiftUI

private nonisolated final class CommunityAttributedStringBox: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

/// 链接扫描由独立 actor 串行执行，缓存登记正文与链接的字节成本。
private actor CommunityLinkifiedTextCache {
    static let shared = CommunityLinkifiedTextCache()
    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private let values: NSCache<NSString, CommunityAttributedStringBox> = {
        let cache = NSCache<NSString, CommunityAttributedStringBox>()
        cache.countLimit = 600
        cache.totalCostLimit = CommunityTextLimits.linkCacheBytes
        return cache
    }()

    func value(for text: String) -> AttributedString {
        let key = text as NSString
        if let cached = values.object(forKey: key) { return cached.value }
        let rendered = NSMutableAttributedString(string: text)
        guard let detector else { return AttributedString(text) }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches {
            if let url = match.url { rendered.addAttribute(NSAttributedString.Key("NSLink"), value: url, range: match.range) }
        }
        let result = (try? AttributedString(rendered, including: \.foundation)) ?? AttributedString(text)
        let cost = key.length * 4 + matches.reduce(0) { $0 + ($1.url?.absoluteString.utf16.count ?? 0) * 2 + MemoryLayout<NSRange>.stride }
        values.setObject(CommunityAttributedStringBox(result), forKey: key, cost: cost)
        return result
    }
}

public func communityLinkifiedText(_ text: String) async -> AttributedString {
    await CommunityLinkifiedTextCache.shared.value(for: CommunityTextLimits.displayText(text))
}

/// 普通文本立即呈现，完成链接解析后更新所属正文。
public struct CommunityLinkedText: View {
    private let text: String
    private let preview: Bool
    private let prefix: Text
    @State private var parsed: (source: String, value: AttributedString)?

    public init(_ text: String, preview: Bool = false, prefix: Text = Text("")) {
        self.text = text
        self.preview = preview
        self.prefix = prefix
    }

    public var body: some View {
        let source = CommunityTextLimits.displayText(text, preview: preview)
        (prefix + Text(parsed.flatMap { $0.source == source ? $0.value : nil } ?? AttributedString(source)))
            .task(id: source) {
                let value = await communityLinkifiedText(source)
                if !Task.isCancelled { parsed = (source, value) }
            }
    }
}
#endif
