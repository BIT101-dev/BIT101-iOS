//
//  PaperModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-01.
//

import Foundation
import SwiftUI
import UIKit

/// 文章列表支持的排序方式。
///
/// 后端原生支持“更新时间 / 点赞数 / 评论数”三种排序；
/// 这里把 UI 标题和接口参数集中起来，避免视图层自己判断 query string。
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
/// 文章列表只需要摘要信息，因此保持成轻量模型，避免为了列表页解完整正文。
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
/// 文章列表接口本身不返回作者信息，因此列表页会按需补拉单篇文章详情，
/// 再把真正需要显示的最小作者字段压缩进这一层，避免视图层直接依赖完整详情模型。
struct PaperPreviewMetadata: Equatable, Hashable {
    let authorID: Int?
    let authorName: String
    let avatarURL: URL?
    let anonymous: Bool
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

    /// 把详情里的作者信息压缩成列表预览可直接使用的最小摘要。
    var previewMetadata: PaperPreviewMetadata {
        PaperPreviewMetadata(
            authorID: anonymous ? nil : updateUser.id,
            authorName: anonymous ? "匿名者" : updateUser.nickname,
            // 文章详情页会继续展示服务端返回的头像地址；列表预览这里也保持一致，
            // 避免匿名文章在列表里被错误地强制回退成空头像。
            avatarURL: updateUser.avatar.preferredRemoteURL,
            anonymous: anonymous
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
            return "回复 @\(targetComment.user.nickname)"
        }
    }

    var placeholder: String {
        switch self {
        case .paper:
            return "写点什么吧"
        case let .comment(_, targetComment):
            return "回复 @\(targetComment.user.nickname)"
        }
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
/// 网页端文章正文目前存的是 Editor.js JSON。
/// iOS 端先覆盖最常见的块类型，未知块静默忽略，避免为了上线阅读能力引入 WebView。
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
        GalleryImage(mid: id, url: url, lowUrl: lowURL)
    }

    var preferredRemoteURL: URL? {
        let raw = lowURL.isEmpty ? url : lowURL
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

/// 文章编辑器正文序列化辅助。
///
/// 当前 iOS 端先提供“纯文本编辑 -> 最小 Editor.js JSON”的本地转换，
/// 这样网页端和 iOS 端都能按同一种正文格式读取，不需要为了发文章退回 WebView。
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
                data: BlockData(text: paragraph.replacingOccurrences(of: "\n", with: "<br>"))
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

        let blocks = rawBlocks.compactMap(makeBlock(from:))
        if blocks.isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [.paragraph(id: UUID().uuidString, text: AttributedString(trimmed))]
        }
        return blocks
    }

    /// 把后端 HTML 片段转换成 SwiftUI 可展示的富文本。
    ///
    /// Editor.js 段落和列表项里会混入 `<a>`、`<b>`、`<i>`、`<br>` 等标记。
    /// 这里交给系统 HTML 解析，让正文保持本地渲染而不是回退到 WebView。
    nonisolated static func attributedText(from html: String) -> AttributedString {
        let normalizedHTML = html
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "<br>", with: "<br/>")

        guard let data = "<span>\(normalizedHTML)</span>".data(using: .utf8) else {
            return AttributedString(normalizedHTML)
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
            return AttributedString(strippingHTML(from: normalizedHTML))
        }

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
            guard
                let file = data["file"] as? [String: Any],
                let url = file["url"] as? String,
                !url.isEmpty
            else {
                return nil
            }
            let lowURL = (file["low_url"] as? String) ?? ""
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
}

extension GalleryImage {
    /// 文章模块里优先低清图、失败时回退原图。
    nonisolated var preferredRemoteURL: URL? {
        let raw = lowUrl.isEmpty ? url : lowUrl
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}
