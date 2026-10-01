import CommunityCore
//
//  GalleryModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 画廊首页的 feed 类型。
///
/// feed 类型统一提供顶部分类、请求参数和本地机器人分栏定义。
public enum GalleryFeedKind: String, CaseIterable, Identifiable, Hashable {
    case follow
    case recommend
    case newest
    case hot
    case bot

    /// 供 `ForEach` 和本地持久化使用的稳定标识。
    public var id: String { rawValue }

    /// 当前 feed 在 UI 上展示的标题。
    public var title: String {
        switch self {
        case .follow:
            return "关注"
        case .recommend:
            return "推荐"
        case .newest:
            return "最新"
        case .hot:
            return "最热"
        case .bot:
            return "机器人"
        }
    }

    /// 返回 feed 对应的后端 `mode` 参数。
    ///
    /// 推荐流使用默认接口参数，机器人流由本地过滤处理。
    public var requestMode: String? {
        switch self {
        case .follow:
            return "follow"
        case .recommend:
            return nil
        case .newest:
            return "search"
        case .hot:
            return "hot"
        case .bot:
            return nil
        }
    }

    /// 对应后端 `order` 参数。
    public var requestOrder: String? {
        switch self {
        case .newest:
            return "new"
        default:
            return nil
        }
    }

    /// 返回 feed 请求所需的 `uid` 参数。
    ///
    /// 最新流复用搜索接口并使用 `-1`，保持公开帖子语义。
    public var requestUID: Int? {
        switch self {
        case .newest:
            return -1
        default:
            return nil
        }
    }

    /// 机器人流从公开帖子流中本地筛选机器人标签。
    public var isBotFeed: Bool {
        self == .bot
    }
}

/// 搜索页支持的排序方式。
public enum GallerySearchOrder: String, CaseIterable, Identifiable, Hashable {
    case similar
    case like
    case newest = "new"

    /// 供菜单 `Picker` 直接绑定的稳定标识。
    public var id: String { rawValue }

    /// 搜索页排序控件展示的中文标题。
    public var title: String {
        switch self {
        case .similar:
            return "相似"
        case .like:
            return "高赞"
        case .newest:
            return "最新"
        }
    }
}

/// 搜索页的文本和排序条件。
///
/// 值类型便于整体传递查询条件，并保留排序和输入框状态。
public struct GallerySearchQuery: Equatable {
    public var text = ""
    public var order: GallerySearchOrder = .newest
    public init(text: String = "", order: GallerySearchOrder = .newest) {
        self.text = text
        self.order = order
    }
}

/// 帖子详情模型。
///
/// 详情包含当前用户的点赞、归属和插件字段。
public nonisolated struct GalleryPosterDetail: Decodable, Identifiable, Hashable, Sendable {
    public let anonymous: Bool
    public let claim: CommunityClaim
    public let commentNum: Int
    public let createTime: String
    public let editTime: String
    public let id: Int
    public let images: [CommunityImage]
    public let like: Bool
    public let likeNum: Int
    public let own: Bool
    public let plugins: String
    public let `public`: Bool
    public let tags: [String]
    public let text: String
    public let title: String
    public let updateTime: String
    public let user: CommunityUser

    /// 将详情模型转换为列表卡片模型，供“我的帖子”等列表复用。
    public var asPoster: CommunityPoster {
        CommunityPoster(
            anonymous: anonymous,
            claim: claim,
            commentNum: commentNum,
            createTime: createTime,
            editTime: editTime,
            id: id,
            images: images,
            likeNum: likeNum,
            public: `public`,
            tags: tags,
            text: text,
            title: title,
            updateTime: updateTime,
            user: user
        )
    }

    /// 返回替换点赞状态和数量的详情副本。
    public func updatingLike(_ like: Bool, likeNum: Int) -> GalleryPosterDetail {
        GalleryPosterDetail(
            anonymous: anonymous,
            claim: claim,
            commentNum: commentNum,
            createTime: createTime,
            editTime: editTime,
            id: id,
            images: images,
            like: like,
            likeNum: likeNum,
            own: own,
            plugins: plugins,
            public: `public`,
            tags: tags,
            text: text,
            title: title,
            updateTime: updateTime,
            user: user
        )
    }
}

extension GalleryPosterDetail {
    /// 根据列表卡片构造占位详情。
    ///
    /// 消息页可以先展示卡片数据，详情请求完成后替换对象。
    init(poster: CommunityPoster) {
        self.init(
            anonymous: poster.anonymous,
            claim: poster.claim,
            commentNum: poster.commentNum,
            createTime: poster.createTime,
            editTime: poster.editTime,
            id: poster.id,
            images: poster.images,
            like: false,
            likeNum: poster.likeNum,
            own: false,
            plugins: "[]",
            public: poster.public,
            tags: poster.tags,
            text: poster.text,
            title: poster.title,
            updateTime: poster.updateTime,
            user: poster.user
        )
    }
}

/// 单个 feed 的整体加载状态。
///
/// 分页加载状态由 `GalleryFeedState.isLoadingMore` 管理。
struct GalleryFeedState {
    /// 当前已经加载到客户端的帖子列表。
    var posters: [CommunityPoster] = []
    /// 列表当前所处的加载状态。
    var status: CommunityLoadStatus = .idle
    /// 是否正在请求下一页。
    var isLoadingMore = false
    /// 下一次分页请求的页码。
    var nextPage = 0
    /// 后端是否还有更多内容可翻。
    var canLoadMore = true
}

extension GalleryFeedState: PagedItemsState {
    var items: [CommunityPoster] {
        get { posters }
        set { posters = newValue }
    }
}

public nonisolated struct GalleryReportType: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let text: String

    public static let fallback: [GalleryReportType] = [
        GalleryReportType(id: 1, text: "政治敏感"),
        GalleryReportType(id: 2, text: "色情低俗"),
        GalleryReportType(id: 3, text: "人身攻击"),
        GalleryReportType(id: 4, text: "侵犯隐私"),
        GalleryReportType(id: 5, text: "散布谣言"),
        GalleryReportType(id: 6, text: "滥用产品"),
        GalleryReportType(id: 7, text: "其他")
    ]
}

public enum GalleryReportTarget: Identifiable, Hashable {
    case poster(Int)
    case comment(Int)

    public var id: String {
        switch self {
        case let .poster(id): return "poster-\(id)"
        case let .comment(id): return "comment-\(id)"
        }
    }

    public var objectID: String {
        switch self {
        case let .poster(id): return "poster\(id)"
        case let .comment(id): return "comment\(id)"
        }
    }

    public var title: String {
        switch self {
        case .poster: return "举报帖子"
        case .comment: return "举报评论"
        }
    }
}

extension GalleryMessageType {
    /// 当前类型对应的动作文案。
    public func actionText(for message: GalleryMessage) -> String {
        switch self {
        case .comment:
            return message.obj.hasPrefix("comment") ? "回复了你的评论" : "评论了你的帖子"
        case .like:
            return message.obj.hasPrefix("comment") ? "点赞了你的评论" : "点赞了你的帖子"
        case .follow:
            return "关注了你"
        case .system:
            return "系统通知"
        }
    }
}

/// 消息发送者头像。
///
/// 消息接口里的 `from_user` 可能为空对象，字段按可选值解码并使用空字符串默认值。
public nonisolated struct GalleryMessageAvatar: Decodable, Hashable, Sendable {
    public let url: String
    public let lowUrl: String

    public init(url: String = "", lowUrl: String = "") {
        self.url = url
        self.lowUrl = lowUrl
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case lowUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        lowUrl = try container.decodeIfPresent(String.self, forKey: .lowUrl) ?? ""
    }

    /// 返回低清地址，低清地址为空时使用原图地址。
    ///
    /// 消息列表头像尺寸较小，低清地址可以减少图片数据量。
    public var preferredURL: URL? {
        let raw = lowUrl.isEmpty ? url : lowUrl
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

/// 消息发送者。
///
/// 系统消息返回空用户对象，字段提供展示默认值。
public nonisolated struct GalleryMessageUser: Decodable, Hashable, Sendable {
    public let id: Int
    public let nickname: String
    public let avatar: GalleryMessageAvatar

    private enum CodingKeys: String, CodingKey {
        case id
        case nickname
        case avatar
    }

    public init(id: Int = 0, nickname: String = "", avatar: GalleryMessageAvatar = GalleryMessageAvatar()) {
        self.id = id
        self.nickname = nickname
        self.avatar = avatar
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        avatar = try container.decodeIfPresent(GalleryMessageAvatar.self, forKey: .avatar) ?? GalleryMessageAvatar()
    }

    /// 返回消息列表展示名称。
    ///
    /// `id` 为 0 时返回系统消息，昵称为空时返回未知用户。
    public var displayName: String {
        if id == 0 {
            return "系统消息"
        }
        return nickname.isEmpty ? "未知用户" : nickname
    }
}

/// 各消息分类的未读数。
///
/// 服务端返回分类未读数，ViewModel 基于数量推断最新前 N 条的本地伪未读状态。
public nonisolated struct GalleryMessageUnreadCounts: Decodable, Equatable, Sendable {
    public var comment: Int
    public var follow: Int
    public var like: Int
    public var system: Int

    public init(comment: Int = 0, follow: Int = 0, like: Int = 0, system: Int = 0) {
        self.comment = comment
        self.follow = follow
        self.like = like
        self.system = system
    }

    private enum CodingKeys: String, CodingKey {
        case comment
        case follow
        case like
        case system
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comment = try container.decodeIfPresent(Int.self, forKey: .comment) ?? 0
        follow = try container.decodeIfPresent(Int.self, forKey: .follow) ?? 0
        like = try container.decodeIfPresent(Int.self, forKey: .like) ?? 0
        system = try container.decodeIfPresent(Int.self, forKey: .system) ?? 0
    }

    /// 返回消息类型对应的未读数。
    public func unreadCount(for type: GalleryMessageType) -> Int {
        switch type {
        case .comment:
            return comment
        case .follow:
            return follow
        case .like:
            return like
        case .system:
            return system
        }
    }
}

/// 单条消息模型。
///
/// 消息数据通过 `obj/link_obj` 字段关联目标帖子。
public nonisolated struct GalleryMessage: Decodable, Identifiable, Hashable, Sendable {
    public let fromUser: GalleryMessageUser
    public let id: Int
    public let linkObj: String
    public let obj: String
    public let text: String
    public let updateTime: String

    /// 解析消息指向的帖子 ID。
    public var linkedPosterID: Int? {
        Self.posterID(from: linkObj) ?? Self.posterID(from: obj)
    }

    private static func posterID(from raw: String) -> Int? {
        guard raw.hasPrefix("poster") else { return nil }
        return Int(raw.dropFirst("poster".count))
    }
}

/// 单个消息分类的列表状态。
///
/// 列表、分页游标和加载状态按消息类型统一存放。
nonisolated struct GalleryMessageListState {
    /// 当前已经加载到客户端的消息列表。
    var items: [GalleryMessage] = []
    /// 列表当前所处的加载状态。
    var status: CommunityLoadStatus = .idle
    /// 是否正在请求下一页。
    var isLoadingMore = false
    /// 下一次分页请求要带的最后一条消息 ID。
    var nextCursor: Int?
    /// 服务端是否还有更多历史消息。
    var canLoadMore = true
}

extension GalleryMessageListState: CursorPagedItemsState {}

extension CommunityClaim {
    /// 返回占位帖子使用的空 claim。
    static var placeholder: CommunityClaim {
        CommunityClaim(id: 0, text: "")
    }
}

extension CommunityPoster {
    /// 构造消息页详情请求完成前使用的占位帖子。
    static func placeholder(id: Int, title: String = "正在打开帖子") -> CommunityPoster {
        CommunityPoster(
            anonymous: false,
            claim: .placeholder,
            commentNum: 0,
            createTime: "",
            editTime: "",
            id: id,
            images: [],
            likeNum: 0,
            public: true,
            tags: [],
            text: "",
            title: title,
            updateTime: "",
            user: .placeholder()
        )
    }
}

