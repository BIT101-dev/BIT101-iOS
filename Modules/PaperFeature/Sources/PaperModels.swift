import CommunityCore
import DesignSystemKit
//
//  PaperModels.swift
//  BIT101-iOS
//
import Foundation

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
    var items: [PaperSummary] = []
    var status: CommunityLoadStatus = .idle
    var isLoadingMore = false
    var nextPage = 0
    var canLoadMore = true
}

extension PaperListState: PagedItemsState {}

/// 文章评论输入目标。
public enum PaperCommentComposerTarget: Identifiable, Equatable {
    case paper(paperID: Int)
    case comment(mainComment: CommunityComment, targetComment: CommunityComment)

    public var id: String {
        switch self {
        case let .paper(paperID):
            return "paper-\(paperID)"
        case let .comment(mainComment, targetComment):
            return "comment-\(mainComment.id)-\(targetComment.id)"
        }
    }

    public var title: String {
        switch self {
        case .paper:
            return "发表评论"
        case let .comment(_, targetComment):
            return "回复 @\(targetCommentDisplayName(targetComment))"
        }
    }

    public var placeholder: String {
        switch self {
        case .paper:
            return "写点什么吧"
        case let .comment(_, targetComment):
            return "回复 @\(targetCommentDisplayName(targetComment))"
        }
    }

    private func targetCommentDisplayName(_ comment: CommunityComment) -> String {
        comment.anonymous ? AppUserPresentation.anonymousName : comment.user.nickname
    }

    public var objectID: String {
        switch self {
        case let .paper(paperID):
            return "paper\(paperID)"
        case let .comment(mainComment, _):
            return "comment\(mainComment.id)"
        }
    }

    public var replyObjectID: String? {
        switch self {
        case .paper:
            return nil
        case let .comment(mainComment, targetComment):
            guard mainComment.id != targetComment.id else { return nil }
            return "comment\(targetComment.id)"
        }
    }

    public var replyUID: Int? {
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

