import CommunityCore
import DesignSystemKit
//
//  PaperModels.swift
//  BIT101-iOS
//
import Foundation

/// 文章正文的块解析与富文本辅助。
enum PaperContentResourceLimits {
    static let maximumBodyBytes = 256 * 1_024
    static let maximumBlockBytes = 16 * 1_024
    static let maximumBlocks = 256
    static let maximumRenderNodes = maximumBlocks

    static func acceptsPreviewCache(_ detail: PaperDetail) -> Bool {
        let user = detail.updateUser
        let fields = [detail.title, detail.intro, detail.content, detail.createTime, detail.updateTime,
            user.createTime, user.nickname, user.motto, user.avatar.mid, user.avatar.url, user.avatar.lowUrl,
            user.identity.color, user.identity.text, user.identity.createTime, user.identity.updateTime,
            user.identity.deleteTime ?? ""]
        return fields.reduce(0) { $0 + $1.utf8.count } <= maximumBodyBytes
    }

    static func renderNodes(in block: [String: Any]) -> Int {
        let data = block["data"] as? [String: Any] ?? [:]
        switch block["type"] as? String {
        case "list": return (data["items"] as? [String])?.count ?? 1
        case "quote": return data["caption"] == nil ? 1 : 2
        default: return 1
        }
    }

    static func accepts(_ block: [String: Any]) -> Bool {
        guard let bytes = try? JSONSerialization.data(withJSONObject: block) else { return false }
        return bytes.count <= maximumBlockBytes
    }
}


/// 文章列表支持的排序方式。
///
/// 后端原生支持“更新时间 / 点赞数 / 评论数”三种排序。
/// 排序标题和接口参数在此统一定义，视图层读取对应值。
public enum PaperSortOrder: CaseIterable, Identifiable, Hashable {
    case newest
    case like
    case comment

    public var id: String { title }

    public var title: String {
        switch self {
        case .newest:
            return "最新"
        case .like:
            return "高赞"
        case .comment:
            return "热评"
        }
    }

    public var requestValue: String? {
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
public nonisolated struct PaperSummary: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let intro: String
    public let likeNum: Int
    public let commentNum: Int
    public let updateTime: String
}

/// 文章列表预览所需的作者摘要。
///
/// 文章列表接口本身不返回作者信息。
/// 列表页按需补拉单篇文章详情，并从详情字段构建作者摘要供视图层展示。
public struct PaperPreviewMetadata: Equatable, Hashable {
    public let authorName: String
    public let avatarURL: URL?
    public let isAnonymous: Bool
}

/// 文章详情模型。
///
/// 详情页会额外显示编辑者、正文块、点赞状态和所有者状态。
public nonisolated struct PaperDetail: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let intro: String
    public let content: String
    public let createTime: String
    public let updateTime: String
    public let updateUser: CommunityUser
    public let anonymous: Bool
    public let likeNum: Int
    public let commentNum: Int
    public let publicEdit: Bool
    public let like: Bool
    public let own: Bool

    /// 返回替换点赞状态后的新详情对象。
    public func updatingLike(_ like: Bool, likeNum: Int) -> PaperDetail {
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
    public var previewMetadata: PaperPreviewMetadata {
        PaperPreviewMetadata(
            authorName: anonymous ? AppUserPresentation.anonymousName : updateUser.nickname,
            avatarURL: anonymous ? nil : updateUser.avatar.preferredRemoteURL,
            isAnonymous: anonymous
        )
    }
}

/// 文章列表分页状态。
struct PaperListState {
    var paginationError: String?
    var pagedItems = CommunityPagedItems<PaperSummary>()
    var items: [PaperSummary] {
        get { pagedItems.items }
        set { pagedItems.replace(with: newValue) }
    }
    var status: CommunityLoadStatus = .idle
    var isLoadingMore = false
    var nextPage = 0
    var canLoadMore = true
}

extension PaperListState: PagedItemsState {}

extension CommunityImage {
    /// 文章模块优先使用低清图地址，低清图地址为空时使用原图地址。
    nonisolated var preferredRemoteURL: URL? {
        makePreferredRemoteURL(lowURL: lowUrl, originalURL: url)
    }
}

nonisolated func makePreferredRemoteURL(lowURL: String, originalURL: String) -> URL? {
    validatedRemoteURL(from: lowURL) ?? validatedRemoteURL(from: originalURL)
}

nonisolated func validatedRemoteURL(from rawURL: String) -> URL? {
    let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedURL),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host != nil
    else { return nil }
    return url
}
