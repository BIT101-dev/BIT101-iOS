import CommunityTransport
import CommunityCore
//
//  GalleryService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

nonisolated enum GalleryWebRequestFactory {
    static func isTrustedPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "bit101.cn"
            && (url.port == nil || url.port == 443)
    }

    static func request(for url: URL) -> URLRequest {
        URLRequest(url: url)
    }
}

/// 话廊接口层错误。
public enum GalleryServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case uploadFailed
    case reportFailed

    /// 给 UI 直接展示的错误文案。
    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再查看话廊。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .uploadFailed:
            return "图片上传失败。"
        case .reportFailed:
            return "举报提交失败。"
        }
    }
}

extension GalleryServiceError: CommunityAPIServiceError {
    public static var communityNotLoggedIn: Self { .notLoggedIn }
    public static var communityInvalidResponse: Self { .invalidResponse }
}

enum GalleryContentFilter {
    static func shouldHideComment(
        authorID: Int,
        replyTargetID: Int,
        isAnonymous: Bool,
        hiddenUserIDs: Set<Int>,
        hideAnonymousContent: Bool
    ) -> Bool {
        hiddenUserIDs.contains(authorID)
            || hiddenUserIDs.contains(replyTargetID)
            || (hideAnonymousContent && isAnonymous)
    }
}

/// 话廊列表与搜索共享原始分页游标和可见帖子。
public nonisolated struct GalleryPageBatch<Element: Sendable>: Sendable {
    public init(items: [Element], nextSourcePage: Int, canLoadMore: Bool) {
        self.items = items
        self.nextSourcePage = nextSourcePage
        self.canLoadMore = canLoadMore
    }

    public let items: [Element]
    public let nextSourcePage: Int
    public let canLoadMore: Bool
}

private enum GalleryBotClassifier {
    private static let keywords = ["bot", "机器人", "通知", "新闻"]

    static func matches(tags: [String]) -> Bool {
        let normalizedTags = tags.map { $0.lowercased() }
        return normalizedTags.contains { tag in
            keywords.contains { tag.contains($0) }
        }
    }
}

/// 话廊模块网络层。
///
/// 负责帖子流、搜索和消息请求；机器人分栏使用服务端标签分类，正文筛选保持关闭。
public struct GalleryService {
    private let api: CommunityAPIClient<GalleryServiceError>
    private let preferences: () -> CommunityPreferenceSnapshot

    /// 发帖接口请求体。
    private struct CreatePosterRequest: Encodable {
        let title: String
        let text: String
        let imageMids: [String]
        let plugins: String
        let anonymous: Bool
        let tags: [String]
        let claimID: Int
        let `public`: Bool

        /// 对齐后端 snake_case 字段名。
        enum CodingKeys: String, CodingKey {
            case title
            case text
            case imageMids = "image_mids"
            case plugins
            case anonymous
            case tags
            case claimID = "claim_id"
            case `public`
        }
    }

    private struct UpdatePosterRequest: Encodable {
        let title: String
        let text: String
        let imageMids: [String]
        let plugins: String
        let anonymous: Bool
        let tags: [String]
        let claimID: Int
        let `public`: Bool

        enum CodingKeys: String, CodingKey {
            case title, text, plugins, anonymous, tags
            case imageMids = "image_mids"
            case claimID = "claim_id"
            case `public`
        }
    }

    /// 发帖接口返回的帖子 ID。
    private nonisolated struct CreatePosterResponse: Decodable, Sendable {
        let id: Int
    }

    /// 发评论接口请求体。
    private struct CreateCommentRequest: Encodable {
        let obj: String
        let text: String
        let replyObj: String?
        let replyUid: Int?
        let anonymous: Bool
        let imageMids: [String]

        /// 对齐后端 snake_case 字段名。
        enum CodingKeys: String, CodingKey {
            case obj
            case text
            case replyObj = "reply_obj"
            case replyUid = "reply_uid"
            case anonymous
            case imageMids = "image_mids"
        }
    }

    /// 点赞接口请求体。
    private struct LikeRequest: Encodable {
        let obj: String
    }

    private struct ReportRequest: Encodable {
        let obj: String
        let text: String
        let typeID: Int

        enum CodingKeys: String, CodingKey {
            case obj, text
            case typeID = "type_id"
        }
    }

    /// 构造带共享 cookie 策略的服务实例。
    ///
    /// 话廊接口普遍依赖 fake-cookie，同时又需要继承现有登录 session，
    /// 因此这里沿用共享 `HTTPCookieStorage`，避免每个服务实例各自维护认证状态。
    public init(session: CommunitySession, preferences: @escaping () -> CommunityPreferenceSnapshot) {
        api = session.client(errorDomain: "BIT101.Gallery")
        self.preferences = preferences
    }

    /// 拉取某个 feed 的帖子列表。
    ///
    /// 普通 feed 直接映射到后端帖子接口；机器人 feed 走本地标签分页逻辑。
    public func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
        if kind.isBotFeed {
            return try await fetchBotFeed(startPage: page ?? 0)
        }

        let hideBot = await shouldHideBotPosters()

        return try await fetchPosters(
            mode: kind.requestMode,
            order: kind.requestOrder,
            search: nil,
            uid: kind.requestUID,
            page: page,
            hideBot: hideBot
        )
    }

    /// 拉取推荐流的单个源页。
    ///
    /// 服务保留原始源游标，首屏过滤空页由 ViewModel 继续读取，后续页面沿后台预取准备。
    public func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
        let hideBot = await shouldHideBotPosters()
        let rawPosters = try await fetchRawPosters(
            mode: nil,
            order: nil,
            search: nil,
            uid: nil,
            page: sourcePage == 0 ? nil : sourcePage,
            hideBot: hideBot
        )

        return GalleryPageBatch<CommunityPoster>(
            items: await applyGalleryFilters(
                applyBotFilterIfNeeded(rawPosters, hideBot: hideBot)
            ),
            nextSourcePage: sourcePage + 1,
            canLoadMore: !rawPosters.isEmpty
        )
    }

    /// 根据搜索关键词和排序条件查询帖子。
    ///
    /// 搜索页与其它普通帖子页面共用机器人隐藏设置。
    public func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
        let hideBot = await shouldHideBotPosters()
        return try await fetchPosters(
            mode: "search",
            order: query.order.rawValue,
            search: query.text.trimmingCharacters(in: .whitespacesAndNewlines),
            uid: -1,
            page: page,
            hideBot: hideBot
        )
    }

    /// 机器人分栏使用最新帖子流作为源页，向后读取多页并筛出机器人帖子；
    /// 该分栏沿用独立的隐藏设置语义。
    ///
    /// 机器人帖子在整体帖子流里占比并不高，所以这里采用“多抓几页 + 本地筛”的做法。
    /// 已取得可见内容的批次按扫描阈值结束；连续过滤页继续读取至可见内容或源流末尾。
    public func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
        var sourcePage = startPage
        var collected: [CommunityPoster] = []
        var canLoadMore = true
        let maxScanCount = 5
        var scanned = 0

        while canLoadMore && collected.count < 12 && (scanned < maxScanCount || collected.isEmpty) {
            try Task.checkCancellation()
            let rawPosters = try await fetchRawPosters(
                mode: "search",
                order: "new",
                search: nil,
                uid: -1,
                page: sourcePage == 0 ? nil : sourcePage,
                hideBot: false
            )
            let visible = await applyGalleryFilters(rawPosters)
            collected.append(contentsOf: visible.filter { GalleryBotClassifier.matches(tags: $0.tags) })
            canLoadMore = !rawPosters.isEmpty
            sourcePage += 1
            scanned += 1
        }

        return GalleryPageBatch<CommunityPoster>(
            items: await applyGalleryFilters(collected),
            nextSourcePage: sourcePage,
            canLoadMore: canLoadMore
        )
    }

    private func applyBotFilterIfNeeded(_ posters: [CommunityPoster], hideBot: Bool) -> [CommunityPoster] {
        guard hideBot else { return posters }
        return posters.filter { !GalleryBotClassifier.matches(tags: $0.tags) }
    }

    private func applyGalleryFilters(_ posters: [CommunityPoster]) async -> [CommunityPoster] {
        let settings = await MainActor.run {
            preferences()
        }
        let hiddenIDs = Set(settings.galleryHiddenUserIDs)
        let hideAnonymousContent = settings.galleryHideAnonymousContent
        return posters.filter { poster in
            !hiddenIDs.contains(poster.user.id) && !(hideAnonymousContent && poster.anonymous)
        }
    }

    private func applyGalleryFilters(_ comments: [CommunityComment]) async -> [CommunityComment] {
        let settings = await MainActor.run {
            preferences()
        }
        let hiddenIDs = Set(settings.galleryHiddenUserIDs)
        let hideAnonymousContent = settings.galleryHideAnonymousContent

        func filter(_ comment: CommunityComment) -> CommunityComment? {
            guard !GalleryContentFilter.shouldHideComment(
                authorID: comment.user.id,
                replyTargetID: comment.replyUser.id,
                isAnonymous: comment.anonymous,
                hiddenUserIDs: hiddenIDs,
                hideAnonymousContent: hideAnonymousContent
            ) else { return nil }
            return comment.replacingSubComments(comment.sub.compactMap(filter))
        }

        return comments.compactMap(filter)
    }

    private func shouldHideBotPosters() async -> Bool {
        await MainActor.run {
            preferences().galleryHideBotPosterInSearch
        }
    }

    /// 获取可选的帖子 claim 列表。
    ///
    /// claim 会驱动发帖页里的“声明”选择器，因此它属于一个低频但必须成功的基础数据。
    public func fetchClaims() async throws -> [CommunityClaim] {
        try await api.request(path: "posters/claims")
    }

    /// 上传一张发帖图片，返回服务端生成的图片资源对象。
    ///
    /// 图片上传返回服务端资源对象；发帖请求通过 `image_mids` 引用该资源。
    public func uploadImage(data: Data, filename: String = "poster.jpg") async throws -> CommunityImage {
        let multipart = MultipartFormData.jpegFile(data: data, filename: filename)
        do {
            return try await api.request(
                path: "upload/image",
                method: "POST",
                body: multipart.body,
                contentType: multipart.contentType
            )
        } catch let error as NSError where error.domain == "BIT101.Gallery" && error.code >= 400 {
            throw GalleryServiceError.uploadFailed
        }
    }

    /// 发送帖子创建请求。
    ///
    /// 图片会在发帖前单独上传；这里仅提交已经拿到的 `image_mids`。
    public func createPoster(
        title: String,
        text: String,
        imageMids: [String],
        anonymous: Bool,
        tags: [String],
        claimID: Int,
        isPublic: Bool
    ) async throws -> Int {
        let response: CreatePosterResponse = try await api.request(
            path: "posters",
            method: "POST",
            body: try api.encode(
                CreatePosterRequest(
                    title: title,
                    text: text,
                    imageMids: imageMids,
                    plugins: "[]",
                    anonymous: anonymous,
                    tags: tags,
                    claimID: claimID,
                    public: isPublic
                )
            )
        )
        return response.id
    }

    /// 拉取单个帖子的详情。
    ///
    /// 帖子详情会额外包含 `like / own / plugins` 等当前用户态字段，因此不能完全用列表卡片代替。
    public func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
        try await api.request(path: "posters/\(id)")
    }

    /// 删除一条帖子。
    ///
    /// 删除接口没有复杂返回体，只以 HTTP 成功与否为准。
    public func deletePoster(id: Int) async throws {
        try await api.requestVoid(path: "posters/\(id)", method: "DELETE")
    }

    public func updatePoster(
        id: Int,
        title: String,
        text: String,
        imageMids: [String],
        anonymous: Bool,
        tags: [String],
        claimID: Int,
        isPublic: Bool
    ) async throws {
        try await api.requestVoid(
            path: "posters/\(id)",
            method: "PUT",
            body: try api.encode(
                UpdatePosterRequest(
                    title: title,
                    text: text,
                    imageMids: imageMids,
                    plugins: "[]",
                    anonymous: anonymous,
                    tags: tags,
                    claimID: claimID,
                    public: isPublic
                )
            )
        )
    }

    /// 获取社区内容举报类型。
    public func fetchReportTypes() async throws -> [GalleryReportType] {
        try await api.request(path: "manage/report_types")
    }

    /// 提交帖子或评论举报。
    public func report(objectID: String, typeID: Int, text: String) async throws {
        do {
            try await api.requestVoid(
                path: "manage/reports",
                method: "POST",
                body: try api.encode(ReportRequest(obj: objectID, text: text, typeID: typeID))
            )
        } catch let error as GalleryServiceError {
            throw error
        } catch {
            throw GalleryServiceError.reportFailed
        }
    }

    /// 拉取帖子或评论对象下的评论列表。
    ///
    /// 评论列表接口同时服务帖子评论和评论回复，因此通过 `obj` 参数区分目标对象。
    public func fetchComments(
        objectID: String,
        order: CommunityCommentOrder,
        page: Int?
    ) async throws -> GalleryPageBatch<CommunityComment> {
        var sourcePage = page ?? 0
        while true {
            try Task.checkCancellation()
            let raw = try await fetchRawComments(objectID: objectID, order: order, page: sourcePage == 0 ? nil : sourcePage)
            let visible = await applyGalleryFilters(raw)
            sourcePage += 1
            if !visible.isEmpty || raw.isEmpty {
                return GalleryPageBatch(items: visible, nextSourcePage: sourcePage, canLoadMore: !raw.isEmpty)
            }
        }
    }

    /// 清理验收内容时按服务端原始评论列表恢复创建标识。
    public func fetchRawComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment] {
        var queryItems = [
            URLQueryItem(name: "obj", value: objectID),
            URLQueryItem(name: "order", value: order.rawValue),
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        return try await api.request(path: "reaction/comments", queryItems: queryItems)
    }

    /// 对帖子或评论执行点赞操作。
    ///
    /// 后端使用同一个接口处理帖子和评论的点赞，因此这里只传对象 ID。
    public func like(objectID: String) async throws -> CommunityLikeResult {
        try await api.request(
            path: "reaction/like",
            method: "POST",
            body: try api.encode(LikeRequest(obj: objectID))
        )
    }

    /// 创建一条评论或回复。
    ///
    /// 如果 `replyObjectID` 和 `replyUID` 为空，则表示直接评论帖子或主评论；
    /// 否则表示对某条具体评论的回复。
    public func createComment(
        objectID: String,
        text: String,
        replyObjectID: String? = nil,
        replyUID: Int? = nil,
        anonymous: Bool = false,
        imageMids: [String] = []
    ) async throws -> CommunityComment {
        try await api.request(
            path: "reaction/comments",
            method: "POST",
            body: try api.encode(
                CreateCommentRequest(
                    obj: objectID,
                    text: text,
                    replyObj: replyObjectID,
                    replyUid: replyUID,
                    anonymous: anonymous,
                    imageMids: imageMids
                )
            )
        )
    }

    public func uploadCommentImage(data: Data, filename: String) async throws -> CommunityImage {
        try await uploadImage(data: data, filename: filename)
    }

    public func deleteComment(id: Int) async throws {
        try await api.requestVoid(path: "reaction/comments/\(id)", method: "DELETE")
    }

    /// 获取消息中心各分类的未读数。
    ///
    /// 服务端目前提供分类未读数，逐条 read 状态由消息页本地伪新消息机制补充；
    /// 消息页先读取这里的结果。
    public func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
        try await api.request(path: "messages/unread_nums")
    }

    /// 拉取某个消息分类的列表。
    ///
    /// 后端使用 `last_id` 做历史分页；首次传空会顺手把该分类未读数清零。
    public func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
        var queryItems = [URLQueryItem(name: "type", value: type.rawValue)]
        if let lastID {
            queryItems.append(URLQueryItem(name: "last_id", value: String(lastID)))
        }
        return try await api.request(path: "messages", queryItems: queryItems)
    }

    /// 统一拼装帖子流接口参数。
    ///
    /// 这是普通帖子 feed 的公共入口。
    private func fetchPosters(
        mode: String?,
        order: String?,
        search: String?,
        uid: Int?,
        page: Int?,
        hideBot: Bool
    ) async throws -> GalleryPageBatch<CommunityPoster> {
        var sourcePage = page ?? 0
        while true {
            try Task.checkCancellation()
            let rawPosters = try await fetchRawPosters(mode: mode, order: order, search: search, uid: uid,
                page: sourcePage == 0 ? nil : sourcePage, hideBot: hideBot)
            let visible = await applyGalleryFilters(applyBotFilterIfNeeded(rawPosters, hideBot: hideBot))
            sourcePage += 1
            if !visible.isEmpty || rawPosters.isEmpty {
                return GalleryPageBatch<CommunityPoster>(items: visible, nextSourcePage: sourcePage, canLoadMore: !rawPosters.isEmpty)
            }
        }
    }

    /// 发起原始帖子流请求，供推荐流和机器人分栏复用。
    private func fetchRawPosters(
        mode: String?,
        order: String?,
        search: String?,
        uid: Int?,
        page: Int?,
        hideBot: Bool
    ) async throws -> [CommunityPoster] {
        var queryItems: [URLQueryItem] = []

        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }

        if let mode, !mode.isEmpty {
            queryItems.append(URLQueryItem(name: "mode", value: mode))
        }

        if let order, !order.isEmpty {
            queryItems.append(URLQueryItem(name: "order", value: order))
        }

        if let search, !search.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }

        if let uid {
            queryItems.append(URLQueryItem(name: "uid", value: String(uid)))
        }

        if hideBot {
            queryItems.append(URLQueryItem(name: "hide_bot", value: "true"))
        }

        return try await api.request(path: "posters", queryItems: queryItems)
    }
}
