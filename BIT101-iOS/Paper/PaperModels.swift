//
//  PaperModels.swift
//  BIT101-iOS
//
import Foundation
import UIKit

/// 文章列表支持的排序方式。
///
/// 后端原生支持“更新时间 / 点赞数 / 评论数”三种排序。
/// 排序标题和接口参数在此统一定义，视图层读取对应值。
enum PaperSortOrder: CaseIterable, Identifiable, Hashable {
    case newest
    case like
    case comment

    var id: String { title }

    var title: String {
        switch self {
        case .newest:
            return "最新"
        case .like:
            return "高赞"
        case .comment:
            return "热评"
        }
    }

    var requestValue: String? {
        switch self {
        case .newest:
            return nil
        case .like:
            return "like"
        case .comment:
            return "comment"
        }
    }
}

/// 文章列表项。
///
/// 文章列表按摘要字段解码，模型保持轻量。
struct PaperSummary: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let intro: String
    let likeNum: Int
    let commentNum: Int
    let updateTime: String
}

/// 文章列表预览所需的作者摘要。
///
/// 文章列表接口本身不返回作者信息。
/// 列表页按需补拉单篇文章详情，并从详情字段构建作者摘要供视图层展示。
struct PaperPreviewMetadata: Equatable, Hashable {
    let authorName: String
    let avatarURL: URL?
}

/// 文章详情模型。
///
/// 详情页会额外显示编辑者、正文块、点赞状态和所有者状态。
struct PaperDetail: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let intro: String
    let content: String
    let createTime: String
    let updateTime: String
    let updateUser: GalleryUser
    let anonymous: Bool
    let likeNum: Int
    let commentNum: Int
    let publicEdit: Bool
    let like: Bool
    let own: Bool

    /// 返回替换点赞状态后的新详情对象。
    func updatingLike(_ like: Bool, likeNum: Int) -> PaperDetail {
        PaperDetail(
            id: id,
            title: title,
            intro: intro,
            content: content,
            createTime: createTime,
            updateTime: updateTime,
            updateUser: updateUser,
            anonymous: anonymous,
            likeNum: likeNum,
            commentNum: commentNum,
            publicEdit: publicEdit,
            like: like,
            own: own
        )
    }

    /// 生成列表预览使用的作者摘要。
    var previewMetadata: PaperPreviewMetadata {
        PaperPreviewMetadata(
            authorName: anonymous ? "匿名者" : updateUser.nickname,
            avatarURL: anonymous ? nil : updateUser.avatar.preferredRemoteURL
        )
    }
}

/// 文章列表分页状态。
struct PaperListState {
    var items: [PaperSummary] = []
    var status: GalleryFeedStatus = .idle
    var isLoadingMore = false
    var nextPage = 0
    var canLoadMore = true
}

extension PaperListState: PagedItemsState {}

/// 文章评论输入目标。
enum PaperCommentComposerTarget: Identifiable, Equatable {
    case paper(paperID: Int)
    case comment(mainComment: GalleryComment, targetComment: GalleryComment)

    var id: String {
        switch self {
        case let .paper(paperID):
            return "paper-\(paperID)"
        case let .comment(mainComment, targetComment):
            return "comment-\(mainComment.id)-\(targetComment.id)"
        }
    }

    var title: String {
        switch self {
        case .paper:
            return "发表评论"
        case let .comment(_, targetComment):
            return "回复 @\(targetCommentDisplayName(targetComment))"
        }
    }

    var placeholder: String {
        switch self {
        case .paper:
            return "写点什么吧"
        case let .comment(_, targetComment):
            return "回复 @\(targetCommentDisplayName(targetComment))"
        }
    }

    private func targetCommentDisplayName(_ comment: GalleryComment) -> String {
        comment.anonymous ? "匿名用户" : comment.user.nickname
    }

    var objectID: String {
        switch self {
        case let .paper(paperID):
            return "paper\(paperID)"
        case let .comment(mainComment, _):
            return "comment\(mainComment.id)"
        }
    }

    var replyObjectID: String? {
        switch self {
        case .paper:
            return nil
        case let .comment(mainComment, targetComment):
            guard mainComment.id != targetComment.id else { return nil }
            return "comment\(targetComment.id)"
        }
    }

    var replyUID: Int? {
        switch self {
        case .paper:
            return nil
        case let .comment(mainComment, targetComment):
            guard mainComment.id != targetComment.id else { return nil }
            return targetComment.user.id
        }
    }
}

/// Editor.js 正文块。
///
/// 网页端文章正文当前使用 Editor.js JSON。
/// iOS 端覆盖最常见的块类型，未知块静默忽略，阅读页面使用本地渲染路径。
enum PaperContentBlock: Identifiable {
    case header(id: String, text: AttributedString, level: Int)
    case paragraph(id: String, text: AttributedString)
    case quote(id: String, text: AttributedString, caption: AttributedString?)
    case list(id: String, items: [AttributedString], ordered: Bool)
    case image(id: String, image: PaperInlineImage)

    var id: String {
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
struct PaperInlineImage: Identifiable, Hashable {
    let id: String
    let url: String
    let lowURL: String
    let caption: AttributedString?

    var asGalleryImage: GalleryImage {
        GalleryImage(
            mid: id,
            url: validatedRemoteURL(from: url)?.absoluteString ?? "",
            lowUrl: validatedRemoteURL(from: lowURL)?.absoluteString ?? ""
        )
    }

    var preferredRemoteURL: URL? {
        makePreferredRemoteURL(lowURL: lowURL, originalURL: url)
    }
}

/// 文章编辑器正文序列化辅助。
///
/// 当前 iOS 端提供“纯文本编辑 -> 最小 Editor.js JSON”的本地转换。
/// 网页端和 iOS 端使用同一种正文格式读取，文章发布沿用本地转换流程。
enum PaperEditorContentBuilder {
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
    static func editorJSON(from plainText: String) -> String {
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

    static func plainText(from rawContent: String) -> String {
        PaperContentRenderer.blocks(from: rawContent).compactMap { block in
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
enum PaperContentRenderer {
    /// 从详情接口返回的 Editor.js JSON 字符串中恢复正文块。
    nonisolated static func blocks(from raw: String) -> [PaperContentBlock] {
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
    nonisolated static func attributedText(from html: String) -> AttributedString {
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
    nonisolated static func plainText(from html: String) -> String {
        String(attributedText(from: html).characters)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func makeBlock(from raw: [String: Any]) -> PaperContentBlock? {
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

    private nonisolated static func sanitizedHTML(_ html: String) -> String {
        var result = html
        for tag in ["script", "style", "iframe", "object", "embed"] {
            result = result.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result.replacingOccurrences(
            of: "<img\\b[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
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

extension GalleryImage {
    /// 文章模块优先使用低清图地址，低清图地址为空时使用原图地址。
    nonisolated var preferredRemoteURL: URL? {
        makePreferredRemoteURL(lowURL: lowUrl, originalURL: url)
    }
}

private nonisolated func makePreferredRemoteURL(lowURL: String, originalURL: String) -> URL? {
    validatedRemoteURL(from: lowURL) ?? validatedRemoteURL(from: originalURL)
}

private nonisolated func validatedRemoteURL(from rawURL: String) -> URL? {
    let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedURL),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host != nil
    else { return nil }
    return url
}
