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
enum GalleryFeedKind: String, CaseIterable, Identifiable, Hashable {
    case follow
    case recommend
    case newest
    case hot
    case bot

    /// 供 `ForEach` 和本地持久化使用的稳定标识。
    var id: String { rawValue }

    /// 当前 feed 在 UI 上展示的标题。
    var title: String {
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
    var requestMode: String? {
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
    var requestOrder: String? {
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
    var requestUID: Int? {
        switch self {
        case .newest:
            return -1
        default:
            return nil
        }
    }

    /// 机器人流从公开帖子流中本地筛选机器人标签。
    var isBotFeed: Bool {
        self == .bot
    }
}

/// 搜索页支持的排序方式。
enum GallerySearchOrder: String, CaseIterable, Identifiable, Hashable {
    case similar
    case like
    case newest = "new"

    /// 供菜单 `Picker` 直接绑定的稳定标识。
    var id: String { rawValue }

    /// 搜索页排序控件展示的中文标题。
    var title: String {
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
struct GallerySearchQuery: Equatable {
    var text = ""
    var order: GallerySearchOrder = .newest
}

/// 图片资源。
///
/// 后端同时返回原图和低清图。列表优先使用低清图，大图浏览使用原图。
struct GalleryImage: Decodable, Identifiable, Hashable {
    let mid: String
    let url: String
    let lowUrl: String

    /// 图片资源的稳定标识。
    var id: String { mid }
}

/// 用户身份标签。
///
/// 模型保留服务端返回的完整字段，供昵称旁的 badge 和身份展示使用。
struct GalleryIdentity: Decodable, Hashable {
    let id: Int
    let color: String
    let text: String
    let createTime: String
    let updateTime: String
    let deleteTime: String?
}

/// 话廊用户模型。
///
/// 帖子、评论等话廊模块共用这份基础用户结构。
struct GalleryUser: Decodable, Identifiable, Hashable {
    let id: Int
    let createTime: String
    let nickname: String
    let avatar: GalleryImage
    let motto: String
    let identity: GalleryIdentity
}

/// 帖子所属 claim。
///
/// claim 用于发帖选择、帖子卡片和详情展示。
struct GalleryClaim: Codable, Hashable, Identifiable {
    let id: Int
    let text: String
}

/// 信息流帖子卡片模型。
///
/// 模型包含列表渲染所需字段，详情状态由 `GalleryPosterDetail` 提供。
struct GalleryPoster: Decodable, Identifiable, Hashable {
    let anonymous: Bool
    let claim: GalleryClaim
    let commentNum: Int
    let createTime: String
    let editTime: String
    let id: Int
    let images: [GalleryImage]
    let likeNum: Int
    let `public`: Bool
    let tags: [String]
    let text: String
    let title: String
    let updateTime: String
    let user: GalleryUser
}

/// 帖子详情模型。
///
/// 详情包含当前用户的点赞、归属和插件字段。
struct GalleryPosterDetail: Decodable, Identifiable, Hashable {
    let anonymous: Bool
    let claim: GalleryClaim
    let commentNum: Int
    let createTime: String
    let editTime: String
    let id: Int
    let images: [GalleryImage]
    let like: Bool
    let likeNum: Int
    let own: Bool
    let plugins: String
    let `public`: Bool
    let tags: [String]
    let text: String
    let title: String
    let updateTime: String
    let user: GalleryUser

    /// 将详情模型转换为列表卡片模型，供“我的帖子”等列表复用。
    var asPoster: GalleryPoster {
        GalleryPoster(
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
    func updatingLike(_ like: Bool, likeNum: Int) -> GalleryPosterDetail {
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
    init(poster: GalleryPoster) {
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

/// 评论列表的排序方式。
enum GalleryCommentOrder: String, CaseIterable, Identifiable {
    case newest = "new"
    case oldest = "old"
    case like

    /// 供评论排序菜单绑定的稳定标识。
    var id: String { rawValue }

    /// 评论排序菜单展示的标题。
    var title: String {
        switch self {
        case .newest:
            return "最新"
        case .oldest:
            return "最旧"
        case .like:
            return "高赞"
        }
    }
}

/// 话廊评论模型。
///
/// 顶层评论和子评论使用同一结构，`sub` 保存子评论树。
struct GalleryComment: Decodable, Identifiable, Hashable {
    let id: Int
    let obj: String
    let images: [GalleryImage]
    let user: GalleryUser
    let anonymous: Bool
    let createTime: String
    let updateTime: String
    let like: Bool
    let likeNum: Int
    let commentNum: Int
    let own: Bool
    let rate: Int
    let replyUser: GalleryUser
    let replyObj: String
    let text: String
    let sub: [GalleryComment]

    /// 返回替换子评论列表的评论副本。
    nonisolated func replacingSubComments(_ sub: [GalleryComment]) -> GalleryComment {
        GalleryComment(
            id: id,
            obj: obj,
            images: images,
            user: user,
            anonymous: anonymous,
            createTime: createTime,
            updateTime: updateTime,
            like: like,
            likeNum: likeNum,
            commentNum: commentNum,
            own: own,
            rate: rate,
            replyUser: replyUser,
            replyObj: replyObj,
            text: text,
            sub: sub
        )
    }

    /// 返回替换点赞状态和数量的评论副本。
    func updatingLike(_ like: Bool, likeNum: Int) -> GalleryComment {
        GalleryComment(
            id: id,
            obj: obj,
            images: images,
            user: user,
            anonymous: anonymous,
            createTime: createTime,
            updateTime: updateTime,
            like: like,
            likeNum: likeNum,
            commentNum: commentNum,
            own: own,
            rate: rate,
            replyUser: replyUser,
            replyObj: replyObj,
            text: text,
            sub: sub
        )
    }
}

/// 点赞接口返回的点赞状态和数量。
///
/// 点赞请求只返回这两个字段，模型保持接口边界。
struct GalleryLikeResult: Decodable {
    let like: Bool
    let likeNum: Int
}

/// 单个 feed 的整体加载状态。
///
/// 分页加载状态由 `GalleryFeedState.isLoadingMore` 管理。
enum GalleryFeedStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 单个 feed 的状态快照。
///
/// 列表、加载状态和分页信息按 feed 键统一存放。
struct GalleryFeedState {
    /// 当前已经加载到客户端的帖子列表。
    var posters: [GalleryPoster] = []
    /// 列表当前所处的加载状态。
    var status: GalleryFeedStatus = .idle
    /// 是否正在请求下一页。
    var isLoadingMore = false
    /// 下一次分页请求的页码。
    var nextPage = 0
    /// 后端是否还有更多内容可翻。
    var canLoadMore = true
}

extension GalleryFeedState: PagedItemsState {
    var items: [GalleryPoster] {
        get { posters }
        set { posters = newValue }
    }
}

/// 消息中心的消息类型。
///
/// 类型集中提供标题、动作文案和状态字典键。
enum GalleryMessageType: String, CaseIterable, Identifiable, Hashable {
    case comment
    case like
    case follow
    case system

    /// 供 `Picker` 和状态字典使用的稳定标识。
    var id: String { rawValue }

    /// 分段控件展示的中文标题。
    var title: String {
        switch self {
        case .comment:
            return "评论"
        case .like:
            return "点赞"
        case .follow:
            return "关注"
        case .system:
            return "系统"
        }
    }

    /// 当前类型对应的动作文案。
    func actionText(for message: GalleryMessage) -> String {
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
struct GalleryMessageAvatar: Decodable, Hashable {
    let url: String
    let lowUrl: String

    init(url: String = "", lowUrl: String = "") {
        self.url = url
        self.lowUrl = lowUrl
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case lowUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        lowUrl = try container.decodeIfPresent(String.self, forKey: .lowUrl) ?? ""
    }

    /// 返回低清地址，低清地址为空时使用原图地址。
    ///
    /// 消息列表头像尺寸较小，低清地址可以减少图片数据量。
    var preferredURL: URL? {
        let raw = lowUrl.isEmpty ? url : lowUrl
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

/// 消息发送者。
///
/// 系统消息返回空用户对象，字段提供展示默认值。
struct GalleryMessageUser: Decodable, Hashable {
    let id: Int
    let nickname: String
    let avatar: GalleryMessageAvatar

    private enum CodingKeys: String, CodingKey {
        case id
        case nickname
        case avatar
    }

    init(id: Int = 0, nickname: String = "", avatar: GalleryMessageAvatar = GalleryMessageAvatar()) {
        self.id = id
        self.nickname = nickname
        self.avatar = avatar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        avatar = try container.decodeIfPresent(GalleryMessageAvatar.self, forKey: .avatar) ?? GalleryMessageAvatar()
    }

    /// 返回消息列表展示名称。
    ///
    /// `id` 为 0 时返回系统消息，昵称为空时返回未知用户。
    var displayName: String {
        if id == 0 {
            return "系统消息"
        }
        return nickname.isEmpty ? "未知用户" : nickname
    }
}

/// 各消息分类的未读数。
///
/// 服务端返回分类未读数，ViewModel 基于数量推断最新前 N 条的本地伪未读状态。
struct GalleryMessageUnreadCounts: Decodable, Equatable {
    var comment: Int
    var follow: Int
    var like: Int
    var system: Int

    init(comment: Int = 0, follow: Int = 0, like: Int = 0, system: Int = 0) {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comment = try container.decodeIfPresent(Int.self, forKey: .comment) ?? 0
        follow = try container.decodeIfPresent(Int.self, forKey: .follow) ?? 0
        like = try container.decodeIfPresent(Int.self, forKey: .like) ?? 0
        system = try container.decodeIfPresent(Int.self, forKey: .system) ?? 0
    }

    /// 返回消息类型对应的未读数。
    func unreadCount(for type: GalleryMessageType) -> Int {
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
/// 服务端沿用 Web 端的 `obj/link_obj` 字段命名。helper 从字段中解析目标帖子 ID。
struct GalleryMessage: Decodable, Identifiable, Hashable {
    let fromUser: GalleryMessageUser
    let id: Int
    let linkObj: String
    let obj: String
    let text: String
    let updateTime: String

    /// 解析消息指向的帖子 ID。
    var linkedPosterID: Int? {
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
struct GalleryMessageListState {
    /// 当前已经加载到客户端的消息列表。
    var items: [GalleryMessage] = []
    /// 列表当前所处的加载状态。
    var status: GalleryFeedStatus = .idle
    /// 是否正在请求下一页。
    var isLoadingMore = false
    /// 下一次分页请求要带的最后一条消息 ID。
    var nextCursor: Int?
    /// 服务端是否还有更多历史消息。
    var canLoadMore = true
}

extension GalleryMessageListState: CursorPagedItemsState {}

private extension GalleryImage {
    /// 返回占位 UI 使用的空图片模型。
    static var placeholder: GalleryImage {
        GalleryImage(mid: "", url: "", lowUrl: "")
    }
}

private extension GalleryIdentity {
    /// 返回占位用户使用的空身份模型。
    static var placeholder: GalleryIdentity {
        GalleryIdentity(id: 0, color: "#FF9500", text: "", createTime: "", updateTime: "", deleteTime: nil)
    }
}

extension GalleryUser {
    /// 构造消息页跳转帖子详情时使用的占位用户。
    static func placeholder(id: Int = 0, nickname: String = "加载中") -> GalleryUser {
        GalleryUser(
            id: id,
            createTime: "",
            nickname: nickname,
            avatar: .placeholder,
            motto: "",
            identity: .placeholder
        )
    }
}

extension GalleryClaim {
    /// 返回占位帖子使用的空 claim。
    static var placeholder: GalleryClaim {
        GalleryClaim(id: 0, text: "")
    }
}

extension GalleryPoster {
    /// 构造消息页详情请求完成前使用的占位帖子。
    static func placeholder(id: Int, title: String = "正在打开帖子") -> GalleryPoster {
        GalleryPoster(
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
