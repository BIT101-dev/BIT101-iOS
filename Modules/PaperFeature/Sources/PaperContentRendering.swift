#if os(iOS)
import Foundation
import UIKit
import CommunityCore

public enum PaperContentBlock: Identifiable {
    case header(id: String, text: AttributedString, level: Int)
    case paragraph(id: String, text: AttributedString)
    case quote(id: String, text: AttributedString, caption: AttributedString?)
    case list(id: String, items: [AttributedString], ordered: Bool)
    case image(id: String, image: PaperInlineImage)

    public var id: String {
        switch self {
        case let .header(id, _, _),
             let .paragraph(id, _),
             let .quote(id, _, _),
             let .list(id, _, _),
             let .image(id, _):
            return id
        }
    }
}

/// 文章正文中的图片块。
public struct PaperInlineImage: Identifiable, Hashable {
    public let id: String
    public let url: String
    public let lowURL: String
    public let caption: AttributedString?

    public var asCommunityImage: CommunityImage {
        CommunityImage(
            mid: id,
            url: validatedRemoteURL(from: url)?.absoluteString ?? "",
            lowUrl: validatedRemoteURL(from: lowURL)?.absoluteString ?? ""
        )
    }

    public var preferredRemoteURL: URL? {
        makePreferredRemoteURL(lowURL: lowURL, originalURL: url)
    }
}

/// 文章编辑器正文序列化辅助。
///
/// 当前 iOS 端提供“纯文本编辑 -> 最小 Editor.js JSON”的本地转换。
/// 网页端和 iOS 端使用同一种正文格式读取，文章发布沿用本地转换流程。
public enum PaperEditorContentBuilder {
    private struct Root: Encodable {
        let time: Int64
        let blocks: [Block]
        let version: String
    }

    private struct Block: Encodable {
        let id: String
        let type: String
        let data: BlockData
    }

    private struct BlockData: Encodable {
        let text: String
    }

    /// 把多段纯文本包装成最小可用的 Editor.js 段落数组。
    public static func editorJSON(from plainText: String) -> String {
        let paragraphs = plainText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let blocks = (paragraphs.isEmpty ? [plainText] : paragraphs).map { paragraph in
            Block(
                id: UUID().uuidString.prefix(8).lowercased(),
                type: "paragraph",
                data: BlockData(text: htmlEscapedText(paragraph).replacingOccurrences(of: "\n", with: "<br>"))
            )
        }

        let root = Root(
            time: Int64(Date().timeIntervalSince1970 * 1000),
            blocks: blocks,
            version: "2.28.2"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(root), let json = String(data: data, encoding: .utf8) else {
            return plainText
        }
        return json
    }

    private static func htmlEscapedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 纯文本编辑能力由原始结构决定，格式与扩展数据保持完整。
    static func canEditAsPlainText(_ rawContent: String) -> Bool {
        guard let data = rawContent.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[")
        }
        guard let root = object as? [String: Any],
              Set(root.keys).isSubset(of: ["time", "version", "blocks"]),
              let blocks = root["blocks"] as? [[String: Any]] else { return false }
        return blocks.allSatisfy { block in
            guard Set(block.keys).isSubset(of: ["id", "type", "data"]),
                  block["type"] as? String == "paragraph",
                  let data = block["data"] as? [String: Any], Set(data.keys) == ["text"],
                  let text = data["text"] as? String else { return false }
            return text.replacingOccurrences(of: #"<br\s*/?>"#, with: "", options: [.regularExpression, .caseInsensitive])
                .range(of: #"<[^>]+>"#, options: .regularExpression) == nil
        }
    }

    @MainActor public static func plainText(from rawContent: String) -> String {
        plainText(from: PaperContentRenderer.blocks(from: rawContent))
    }

    static func plainText(from blocks: [PaperContentBlock]) -> String {
        blocks.compactMap { block in
            switch block {
            case let .header(_, text, _), let .paragraph(_, text), let .quote(_, text, _):
                return String(text.characters)
            case let .list(_, items, _):
                return items.map { String($0.characters) }.joined(separator: "\n")
            case .image:
                return nil
            }
        }
        .joined(separator: "\n\n")
    }
}

/// 文章正文的块解析与富文本辅助。
@MainActor enum PaperContentRenderer {
    /// 从详情接口返回的 Editor.js JSON 字符串中恢复正文块。
    static func blocks(from raw: String) -> [PaperContentBlock] {
        guard
            let data = raw.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawBlocks = root["blocks"] as? [[String: Any]]
        else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [.paragraph(id: UUID().uuidString, text: AttributedString(trimmed))]
        }

        return rawBlocks.compactMap(makeBlock(from:))
    }

    /// 把后端 HTML 片段转换成 SwiftUI 可展示的富文本。
    ///
    /// Editor.js 段落和列表项里会混入 `<a>`、`<b>`、`<i>`、`<br>` 等标记。
    /// 系统 HTML 解析将这些标记转换为 SwiftUI 可展示的富文本，正文沿用本地渲染路径。
    static func attributedText(from html: String) -> AttributedString {
        let normalizedHTML = html
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "<br>", with: "<br/>")
        let safeHTML = sanitizedHTML(normalizedHTML)

        guard let data = "<span>\(safeHTML)</span>".data(using: .utf8) else {
            return AttributedString(strippingHTML(from: safeHTML))
        }

        guard
            let attributed = try? NSMutableAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            )
        else {
            return AttributedString(strippingHTML(from: safeHTML))
        }

        sanitizeLinks(in: attributed)
        return (try? AttributedString(attributed, including: \.uiKit)) ?? AttributedString(attributed.string)
    }

    /// 生成富文本的纯文本版本，用于辅助信息或可访问性文案。
    static func plainText(from html: String) -> String {
        String(attributedText(from: html).characters)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeBlock(from raw: [String: Any]) -> PaperContentBlock? {
        let id = (raw["id"] as? String) ?? UUID().uuidString
        guard let type = raw["type"] as? String else { return nil }
        let data = raw["data"] as? [String: Any] ?? [:]

        switch type {
        case "header":
            guard let text = data["text"] as? String else { return nil }
            let level = data["level"] as? Int ?? 1
            return .header(id: id, text: attributedText(from: text), level: max(1, min(level, 4)))
        case "paragraph":
            guard let text = data["text"] as? String else { return nil }
            return .paragraph(id: id, text: attributedText(from: text))
        case "quote":
            guard let text = data["text"] as? String else { return nil }
            let caption = data["caption"] as? String
            let renderedCaption: AttributedString?
            if let caption, !plainText(from: caption).isEmpty {
                renderedCaption = attributedText(from: caption)
            } else {
                renderedCaption = nil
            }
            return .quote(id: id, text: attributedText(from: text), caption: renderedCaption)
        case "list":
            guard let items = data["items"] as? [String], !items.isEmpty else { return nil }
            let ordered = (data["style"] as? String) == "ordered"
            return .list(id: id, items: items.map(attributedText(from:)), ordered: ordered)
        case "image":
            guard let file = data["file"] as? [String: Any] else { return nil }
            let url = (file["url"] as? String) ?? ""
            let lowURL = (file["low_url"] as? String) ?? ""
            guard makePreferredRemoteURL(lowURL: lowURL, originalURL: url) != nil else { return nil }
            let rawCaption = (data["caption"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let caption = rawCaption.isEmpty ? nil : attributedText(from: rawCaption)
            return .image(id: id, image: PaperInlineImage(id: id, url: url, lowURL: lowURL, caption: caption))
        default:
            return nil
        }
    }

    private nonisolated static func strippingHTML(from html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func sanitizedHTML(_ html: String) -> String {
        var result = html
        for tag in ["script", "style", "iframe", "object", "embed"] {
            result = result.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let inlineTags: Set<String> = ["a", "b", "strong", "i", "em", "u", "s", "strike", "br", "p", "ul", "ol", "li",
            "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "sub", "sup", "code", "pre", "span", "div"]
        for match in result.matches(of: #/<[^>]*(?:>|$)/#).reversed() {
            let tag = String(match.output)
            var replacement = ""
            if let header = tag.firstMatch(of: #/<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9]*)/#) {
                let name = header.output.2.lowercased()
                if inlineTags.contains(name) {
                    replacement = "<\(header.output.1)\(name)>"
                    if name == "a", header.output.1.isEmpty,
                       let link = tag.firstMatch(of: #/(?i)\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/#),
                       let value = link.output.1 ?? link.output.2 ?? link.output.3 {
                        let escaped = value.replacingOccurrences(of: "\"", with: "&quot;")
                            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                        replacement = "<a href=\"\(escaped)\">"
                    }
                }
            }
            result.replaceSubrange(match.range, with: replacement)
        }
        return result
    }

    private nonisolated static func sanitizeLinks(in attributed: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        var unsafeRanges: [NSRange] = []
        attributed.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard let value else { return }
            guard let url = linkURL(from: value), isAllowedRemoteURL(url) else {
                unsafeRanges.append(range)
                return
            }
        }

        for range in unsafeRanges {
            attributed.removeAttribute(.link, range: range)
        }
    }

    private nonisolated static func linkURL(from value: Any) -> URL? {
        if let url = value as? URL {
            return url
        }
        if let url = value as? NSURL {
            return url as URL
        }
        if let string = value as? String {
            return URL(string: string)
        }
        return nil
    }

    private nonisolated static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else { return false }
        return true
    }
}

#endif
