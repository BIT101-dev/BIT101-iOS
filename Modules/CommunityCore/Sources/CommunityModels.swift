import Foundation

/// 图片资源。
///
/// 后端同时返回原图和低清图。列表优先使用低清图，大图浏览使用原图。
public nonisolated struct CommunityImage: Codable, Identifiable, Hashable, Sendable {
    public init(mid: String, url: String, lowUrl: String) {
        self.mid = mid
        self.url = url
        self.lowUrl = lowUrl
    }

    public let mid: String
    public let url: String
    public let lowUrl: String

    private enum CodingKeys: String, CodingKey { case mid, url, lowUrl }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        mid = try fields.decode(String.self, forKey: .mid)
        url = (try? fields.decode(String.self, forKey: .url)) ?? ""
        lowUrl = (try? fields.decode(String.self, forKey: .lowUrl)) ?? ""
    }

    /// 图片资源的稳定标识。
    public var id: String { mid }
    public var hasResourceIdentity: Bool { !mid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var thumbnailURL: URL? { Self.remoteURL(lowUrl) ?? Self.remoteURL(url) }
    public var originalURL: URL? { Self.remoteURL(url) ?? Self.remoteURL(lowUrl) }

    public static func remoteURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = URL(string: trimmed), let scheme = result.scheme?.lowercased(),
              ["http", "https"].contains(scheme), result.host?.isEmpty == false else { return nil }
        return result
    }

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

    private enum CodingKeys: String, CodingKey { case id, color, text, createTime, updateTime, deleteTime }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(Int.self, forKey: .id)
        color = (try? fields.decode(String.self, forKey: .color)) ?? ""
        text = (try? fields.decode(String.self, forKey: .text)) ?? ""
        createTime = (try? fields.decode(String.self, forKey: .createTime)) ?? ""
        updateTime = (try? fields.decode(String.self, forKey: .updateTime)) ?? ""
        deleteTime = try? fields.decode(String.self, forKey: .deleteTime)
    }
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

    private enum CodingKeys: String, CodingKey { case id, createTime, nickname, avatar, motto, identity }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(Int.self, forKey: .id)
        createTime = (try? fields.decode(String.self, forKey: .createTime)) ?? ""
        nickname = (try? fields.decode(String.self, forKey: .nickname)) ?? "未命名用户"
        avatar = (try? fields.decode(CommunityImage.self, forKey: .avatar)) ?? .placeholder
        motto = (try? fields.decode(String.self, forKey: .motto)) ?? ""
        identity = (try? fields.decode(CommunityIdentity.self, forKey: .identity)) ?? .placeholder
    }
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
/// 模型按列表预览预算保留正文，完整正文由详情请求承接。
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
        self.text = CommunityTextLimits.displayText(text, preview: true)
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

    private enum CodingKeys: String, CodingKey {
        case anonymous, claim, commentNum, createTime, editTime, id, images, likeNum, `public`, tags, text, title, updateTime, user
    }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(Int.self, forKey: .id)
        guard id > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: fields, debugDescription: "帖子需要有效的资源编号。")
        }
        anonymous = try fields.decode(Bool.self, forKey: .anonymous)
        claim = (try? fields.decode(CommunityClaim.self, forKey: .claim)) ?? .init(id: 0, text: "")
        commentNum = (try? fields.decode(Int.self, forKey: .commentNum)) ?? 0
        createTime = (try? fields.decode(String.self, forKey: .createTime)) ?? ""
        editTime = (try? fields.decode(String.self, forKey: .editTime)) ?? ""
        images = (try? fields.decode([CommunityImage].self, forKey: .images)) ?? []
        likeNum = (try? fields.decode(Int.self, forKey: .likeNum)) ?? 0
        self.public = (try? fields.decode(Bool.self, forKey: .public)) ?? false
        tags = (try? fields.decode([String].self, forKey: .tags)) ?? []
        text = CommunityTextLimits.displayText((try? fields.decode(String.self, forKey: .text)) ?? "", preview: true)
        title = (try? fields.decode(String.self, forKey: .title)) ?? ""
        updateTime = (try? fields.decode(String.self, forKey: .updateTime)) ?? ""
        if anonymous {
            user = (try? fields.decode(CommunityUser.self, forKey: .user)) ?? .placeholder(nickname: "匿名用户")
        } else {
            user = try fields.decode(CommunityUser.self, forKey: .user)
            guard user.id > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .user, in: fields, debugDescription: "公开作者需要有效的用户编号。")
            }
        }
    }
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
    public init(id: Int, obj: String, images: [CommunityImage], user: CommunityUser, anonymous: Bool, createTime: String, updateTime: String, like: Bool, likeNum: Int, commentNum: Int, own: Bool, rate: Int, replyUser: CommunityUser, replyObj: String, text: String, sub: [CommunityComment], isViewerAuthenticated: Bool = true) {
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
        self.isViewerAuthenticated = isViewerAuthenticated
    }

    public var isViewerAuthenticated = true
    private enum CodingKeys: String, CodingKey {
        case id, obj, images, user, anonymous, createTime, updateTime, like, likeNum, commentNum
        case own, rate, replyUser, replyObj, text, sub
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

    public func settingViewerAuthentication(_ isAuthenticated: Bool) -> CommunityComment {
        var result = replacingSubComments(sub.map { $0.settingViewerAuthentication(isAuthenticated) })
        result.isViewerAuthenticated = isAuthenticated
        return result
    }

    public static func validatesResponse(_ comments: [CommunityComment], for objectID: String) -> Bool {
        guard comments.allSatisfy({ $0.obj == objectID }) else { return false }
        var identities = Set<Int>()
        var pending = comments
        while let comment = pending.popLast() {
            guard comment.id > 0, identities.insert(comment.id).inserted else { return false }
            pending.append(contentsOf: comment.sub)
        }
        return true
    }

    /// 按回复树的先序顺序展示全部后代。
    public var flattenedReplies: [CommunityComment] {
        var replies: [CommunityComment] = []
        var pending = Array(sub.reversed())
        while let reply = pending.popLast() {
            replies.append(reply)
            pending.append(contentsOf: reply.sub.reversed())
        }
        return replies
    }

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
            sub: sub,
            isViewerAuthenticated: isViewerAuthenticated
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
            sub: sub,
            isViewerAuthenticated: isViewerAuthenticated
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

private extension CommunityImage {
    /// 返回占位 UI 使用的空图片模型。
    nonisolated static var placeholder: CommunityImage {
        CommunityImage(mid: "", url: "", lowUrl: "")
    }
}

private extension CommunityIdentity {
    /// 返回占位用户使用的空身份模型。
    nonisolated static var placeholder: CommunityIdentity {
        CommunityIdentity(id: 0, color: "#FF9500", text: "", createTime: "", updateTime: "", deleteTime: nil)
    }
}

extension CommunityUser {
    /// 构造消息页跳转帖子详情时使用的占位用户。
    public nonisolated static func placeholder(id: Int = 0, nickname: String = "加载中") -> CommunityUser {
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
