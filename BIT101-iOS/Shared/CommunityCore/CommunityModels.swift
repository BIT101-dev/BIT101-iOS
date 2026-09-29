import Foundation

/// 图片资源。
///
/// 后端同时返回原图和低清图。列表优先使用低清图，大图浏览使用原图。
public nonisolated struct CommunityImage: Decodable, Identifiable, Hashable, Sendable {
    public init(mid: String, url: String, lowUrl: String) {
        self.mid = mid
        self.url = url
        self.lowUrl = lowUrl
    }

    public let mid: String
    public let url: String
    public let lowUrl: String

    /// 图片资源的稳定标识。
    public var id: String { mid }

    /// 识别服务端返回的 GIF 地址；查询参数中的扩展名也纳入判断。
    public var isGIF: Bool {
        [url, lowUrl].contains { value in
            let normalized = value.lowercased()
            guard let url = URL(string: value) else {
                return normalized.contains(".gif")
            }
            return url.pathExtension.lowercased() == "gif"
                || url.absoluteString.lowercased().contains(".gif")
        }
    }
}

/// 用户身份标签。
///
/// 模型保留服务端返回的完整字段，供昵称旁的 badge 和身份展示使用。
public nonisolated struct CommunityIdentity: Decodable, Hashable, Sendable {
    public init(id: Int, color: String, text: String, createTime: String, updateTime: String, deleteTime: String?) {
        self.id = id
        self.color = color
        self.text = text
        self.createTime = createTime
        self.updateTime = updateTime
        self.deleteTime = deleteTime
    }

    public let id: Int
    public let color: String
    public let text: String
    public let createTime: String
    public let updateTime: String
    public let deleteTime: String?
}

/// 社区用户摘要。
///
/// 帖子、课程、文章和主页共用基础用户字段。
public nonisolated struct CommunityUser: Decodable, Identifiable, Hashable, Sendable {
    public init(id: Int, createTime: String, nickname: String, avatar: CommunityImage, motto: String, identity: CommunityIdentity) {
        self.id = id
        self.createTime = createTime
        self.nickname = nickname
        self.avatar = avatar
        self.motto = motto
        self.identity = identity
    }

    public let id: Int
    public let createTime: String
    public let nickname: String
    public let avatar: CommunityImage
    public let motto: String
    public let identity: CommunityIdentity
}

/// 帖子所属 claim。
///
/// claim 用于发帖选择、帖子卡片和详情展示。
public nonisolated struct CommunityClaim: Codable, Hashable, Identifiable, Sendable {
    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }

    public let id: Int
    public let text: String
}

/// 信息流帖子卡片模型。
///
/// 模型包含列表渲染所需字段，详情状态由对应业务功能维护。
public nonisolated struct CommunityPoster: Decodable, Identifiable, Hashable, Sendable {
    public init(anonymous: Bool, claim: CommunityClaim, commentNum: Int, createTime: String, editTime: String, id: Int, images: [CommunityImage], likeNum: Int, `public`: Bool, tags: [String], text: String, title: String, updateTime: String, user: CommunityUser) {
        self.anonymous = anonymous
        self.claim = claim
        self.commentNum = commentNum
        self.createTime = createTime
        self.editTime = editTime
        self.id = id
        self.images = images
        self.likeNum = likeNum
        self.`public` = `public`
        self.tags = tags
        self.text = text
        self.title = title
        self.updateTime = updateTime
        self.user = user
    }

    public let anonymous: Bool
    public let claim: CommunityClaim
    public let commentNum: Int
    public let createTime: String
    public let editTime: String
    public let id: Int
    public let images: [CommunityImage]
    public let likeNum: Int
    public let `public`: Bool
    public let tags: [String]
    public let text: String
    public let title: String
    public let updateTime: String
    public let user: CommunityUser
}


/// 评论列表的排序方式。
public enum CommunityCommentOrder: String, CaseIterable, Identifiable {
    case newest = "new"
    case oldest = "old"
    case like

    /// 供评论排序菜单绑定的稳定标识。
    public var id: String { rawValue }

    /// 评论排序菜单展示的标题。
    public var title: String {
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

/// 社区评论模型。
///
/// 顶层评论和子评论使用同一结构，`sub` 保存子评论树。
public nonisolated struct CommunityComment: Decodable, Identifiable, Hashable, Sendable {
    public init(id: Int, obj: String, images: [CommunityImage], user: CommunityUser, anonymous: Bool, createTime: String, updateTime: String, like: Bool, likeNum: Int, commentNum: Int, own: Bool, rate: Int, replyUser: CommunityUser, replyObj: String, text: String, sub: [CommunityComment]) {
        self.id = id
        self.obj = obj
        self.images = images
        self.user = user
        self.anonymous = anonymous
        self.createTime = createTime
        self.updateTime = updateTime
        self.like = like
        self.likeNum = likeNum
        self.commentNum = commentNum
        self.own = own
        self.rate = rate
        self.replyUser = replyUser
        self.replyObj = replyObj
        self.text = text
        self.sub = sub
    }

    public let id: Int
    public let obj: String
    public let images: [CommunityImage]
    public let user: CommunityUser
    public let anonymous: Bool
    public let createTime: String
    public let updateTime: String
    public let like: Bool
    public let likeNum: Int
    public let commentNum: Int
    public let own: Bool
    public let rate: Int
    public let replyUser: CommunityUser
    public let replyObj: String
    public let text: String
    public let sub: [CommunityComment]

    /// 返回替换子评论列表的评论副本。
    public nonisolated func replacingSubComments(_ sub: [CommunityComment]) -> CommunityComment {
        CommunityComment(
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
    public func updatingLike(_ like: Bool, likeNum: Int) -> CommunityComment {
        CommunityComment(
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
public nonisolated struct CommunityLikeResult: Decodable, Sendable {
    public init(like: Bool, likeNum: Int) {
        self.like = like
        self.likeNum = likeNum
    }

    public let like: Bool
    public let likeNum: Int
}


public enum CommunityLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 单个 feed 的状态快照。
///
/// 列表、加载状态和分页信息按 feed 键统一存放。

private extension CommunityImage {
    /// 返回占位 UI 使用的空图片模型。
    static var placeholder: CommunityImage {
        CommunityImage(mid: "", url: "", lowUrl: "")
    }
}

private extension CommunityIdentity {
    /// 返回占位用户使用的空身份模型。
    static var placeholder: CommunityIdentity {
        CommunityIdentity(id: 0, color: "#FF9500", text: "", createTime: "", updateTime: "", deleteTime: nil)
    }
}

extension CommunityUser {
    /// 构造消息页跳转帖子详情时使用的占位用户。
    public static func placeholder(id: Int = 0, nickname: String = "加载中") -> CommunityUser {
        CommunityUser(
            id: id,
            createTime: "",
            nickname: nickname,
            avatar: .placeholder,
            motto: "",
            identity: .placeholder
        )
    }
}
