import Combine
import CommunityTransport
import CommunityCore
//
//  GalleryService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation
import TransportCore

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
    case missingPoster
    case uploadFailed

    /// 给 UI 直接展示的错误文案。
    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return CommunitySessionRestorationError.credentialsRejected.localizedDescription
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .missingPoster:
            return "帖子已删除或暂时无法访问。"
        case .uploadFailed:
            return "图片上传失败。"
        }
    }
}

extension GalleryServiceError: CommunityAPIServiceError {
    public static var communityNotLoggedIn: Self { .notLoggedIn }
    public static var communityInvalidResponse: Self { .invalidResponse }
    public static func communityResourceFailure(path: String, message: String?) -> Self? {
        let parts = path.split(separator: "/")
        return parts.count == 2 && parts[0] == "posters" && Int(parts[1]) != nil && message == "帖子不存在Orz" ? .missingPoster : nil
    }
}

nonisolated enum GalleryContentFilter {
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

nonisolated struct GalleryCommentFilter: Equatable, Sendable {
    let hiddenUserIDs: Set<Int>
    let hideAnonymous: Bool

    @MainActor init(preferences: CommunityPreferenceSnapshot) {
        hiddenUserIDs = Set(preferences.galleryHiddenUserIDs)
        hideAnonymous = preferences.galleryHideAnonymousContent
    }

    func apply(_ comments: [CommunityComment]) -> [CommunityComment] {
        comments.compactMap { comment in
            guard !GalleryContentFilter.shouldHideComment(authorID: comment.user.id, replyTargetID: comment.replyUser.id,
                isAnonymous: comment.anonymous, hiddenUserIDs: hiddenUserIDs, hideAnonymousContent: hideAnonymous) else { return nil }
            return comment.replacingSubComments(apply(comment.sub))
        }
    }
}

/// 话廊列表与搜索共享原始分页游标和可见帖子。
public nonisolated enum GalleryPaging {
    public static let maximumSourcePages = 5
}

public nonisolated struct GalleryPageBatch<Element: Identifiable & Sendable>: Sendable where Element.ID == Int {
    public init(items: [Element], nextSourcePage: Int, canLoadMore: Bool, sourceIDs: [Int]? = nil) {
        self.items = items
        self.nextSourcePage = nextSourcePage
        self.canLoadMore = canLoadMore
        self.sourceIDs = sourceIDs ?? items.map(\.id)
    }

    public let items: [Element]
    public let nextSourcePage: Int
    public let canLoadMore: Bool
    public let sourceIDs: [Int]
}

public enum GalleryBotClassifier {
    private static let keywords = ["bot", "机器人", "通知", "新闻"]

    public static func matches(tags: [String]) -> Bool {
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
    private let session: CommunitySession
    private let resourceUpdates: CommunityResourceUpdates<CommunitySessionIdentity>
    public var resourceChanges: AnyPublisher<[CommunityResourceMetrics], Never> { resourceUpdates.changes }

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

    private struct ReportRequest: Encodable {
        let obj: String
        let text: String
        let typeID: Int

        enum CodingKeys: String, CodingKey {
            case obj, text
            case typeID = "type_id"
        }
    }

    /// 构造沿社区会话快照认证的服务实例。
    ///
    /// 话廊请求沿 CommunitySession 的凭据快照提供 fake-cookie，
    /// CommunityAPIClient 在请求层显式关闭自动 Cookie 处理。
    public init(session: CommunitySession, preferences: @escaping () -> CommunityPreferenceSnapshot,
        resourceUpdates: CommunityResourceUpdates<CommunitySessionIdentity>? = nil) {
        self.session = session
        self.resourceUpdates = resourceUpdates ?? .init(currentOwner: { session.currentCredentials.identity })
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
            canLoadMore: !rawPosters.isEmpty,
            sourceIDs: rawPosters.map(\.id)
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
    /// 每批最多扫描五页，后续查询沿源游标继续。
    public func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
        var sourcePage = startPage
        var collected: [CommunityPoster] = []
        var collectedIDs = Set<Int>()
        var canLoadMore = true
        let maxScanCount = GalleryPaging.maximumSourcePages
        var scanned = 0
        var sourceIDs: [Int] = []
        var progress = CommunityPageProgress<Int>()

        while canLoadMore && collected.count < 12 && scanned < maxScanCount {
            try Task.checkCancellation()
            let rawPosters: [CommunityPoster]
            do {
                rawPosters = try await fetchRawPosters(
                    mode: "search", order: "new", search: nil, uid: -1,
                    page: sourcePage == 0 ? nil : sourcePage, hideBot: false
                )
            } catch {
                guard !Task.isCancelled, !TaskCancellation.matches(error), !collected.isEmpty else { throw error }
                break
            }
            let visible = await applyGalleryFilters(rawPosters)
            try progress.record(rawPosters.map(\.id))
            sourceIDs.append(contentsOf: rawPosters.map(\.id))
            collected.append(contentsOf: visible.filter { GalleryBotClassifier.matches(tags: $0.tags) && collectedIDs.insert($0.id).inserted })
            canLoadMore = !rawPosters.isEmpty
            sourcePage += 1
            scanned += 1
        }

        return GalleryPageBatch<CommunityPoster>(
            items: await applyGalleryFilters(collected),
            nextSourcePage: sourcePage,
            canLoadMore: canLoadMore,
            sourceIDs: sourceIDs
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
        let filter = await MainActor.run { GalleryCommentFilter(preferences: preferences()) }
        return filter.apply(comments)
    }

    private func shouldHideBotPosters() async -> Bool {
        await MainActor.run {
            preferences().galleryHideBotPosterInSearch
        }
    }

    /// 获取可选的帖子 claim 列表。
    ///
    /// claim 驱动发帖页的声明选项；编辑器保留默认声明并提供加载重试。
    public func fetchClaims() async throws -> [CommunityClaim] {
        try await api.request(path: "posters/claims", authentication: .none)
    }

    public func fetchSubscriptions(page: Int) async throws -> [GallerySubscription] {
        try await api.request(path: "subscriptions", queryItems: [URLQueryItem(name: "page", value: String(page))])
    }

    public func setSubscription(objectID: String, level: GallerySubscriptionLevel) async throws {
        struct Request: Encodable { let obj: String; let level: GallerySubscriptionLevel }
        try await api.requestVoid(path: "subscriptions", method: "POST", body: api.encode(Request(obj: objectID, level: level)))
    }

    /// 上传一张发帖图片，返回服务端生成的图片资源对象。
    ///
    /// 图片上传返回服务端资源对象；发帖请求通过 `image_mids` 引用该资源。
    public func uploadImage(data: Data, filename: String = "poster.jpg") async throws -> CommunityImage {
        let multipart = MultipartFormData.jpegFile(data: data, filename: filename)
        return try await api.request(
            path: "upload/image",
            method: "POST",
            body: multipart.body,
            contentType: multipart.contentType,
            validate: { image in
                guard image.hasResourceIdentity else {
                    throw GalleryServiceError.invalidResponse
                }
            }
        )
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
            ),
            mutation: .creation,
            validate: { guard $0.id > 0 else { throw GalleryServiceError.invalidResponse } }
        )
        return response.id
    }

    /// 拉取单个帖子的详情。
    ///
    /// 帖子详情会额外包含 `like / own / plugins` 等当前用户态字段，因此不能完全用列表卡片代替。
    public func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
        let revision = resourceUpdates.beginRead()
        defer { resourceUpdates.finishRead(revision) }
        let result: GalleryPosterDetail = try await api.request(path: "posters/\(id)", validate: { detail in
            guard id > 0, detail.id == id else { throw GalleryServiceError.invalidResponse }
        })
        return resourceUpdates.resolve(result, since: revision)
    }

    /// 删除一条帖子。
    ///
    /// 服务端确认删除或目标已消失时完成操作。
    public func deletePoster(id: Int) async throws {
        try await api.requestVoid(path: "posters/\(id)", method: "DELETE")
    }

    public func updatePoster(
        id: Int,
        title: String,
        text: String,
        imageMids: [String],
        plugins: String,
        anonymous: Bool,
        tags: [String],
        claimID: Int,
        isPublic: Bool
    ) async throws {
        let identity = session.currentCredentials.identity
        do { try await api.requestVoid(
            path: "posters/\(id)",
            method: "PUT",
            body: try api.encode(
                UpdatePosterRequest(
                    title: title,
                    text: text,
                    imageMids: imageMids,
                    plugins: plugins,
                    anonymous: anonymous,
                    tags: tags,
                    claimID: claimID,
                    public: isPublic
                )
            ), mutation: .update
        ) } catch let failure as CommunityUpdateOutcomeUnknown {
            guard session.currentCredentials.identity == identity else { throw CancellationError() }
            let latest: GalleryPosterDetail
            do { latest = try await fetchPoster(id: id) }
            catch {
                if TaskCancellation.matches(error) { throw error }
                throw failure
            }
            try Task.checkCancellation()
            guard session.currentCredentials.identity == identity else { throw CancellationError() }
            guard latest.title == title, latest.text == text, latest.images.map(\.mid) == imageMids,
                  latest.plugins == plugins, latest.anonymous == anonymous, latest.tags == tags,
                  latest.claim.id == claimID, latest.public == isPublic else { throw failure }
        }
    }

    /// 获取社区内容举报类型。
    public func fetchReportTypes() async throws -> [GalleryReportType] {
        let types: [GalleryReportType] = try await api.request(path: "manage/report_types", authentication: .none)
        return GalleryReportType.usableOptions(types)
    }

    /// 提交帖子或评论举报。
    public func report(objectID: String, typeID: Int, text: String) async throws {
        try await api.requestVoid(
            path: "manage/reports",
            method: "POST",
            body: try api.encode(ReportRequest(obj: objectID, text: text, typeID: typeID)), mutation: .creation
        )
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
        var progress = CommunityPageProgress<Int>()
        var sourceIDs: [Int] = []
        while true {
            try Task.checkCancellation()
            let raw = try await fetchRawComments(objectID: objectID, order: order, page: sourcePage == 0 ? nil : sourcePage)
            try progress.record(raw.map(\.id))
            sourceIDs.append(contentsOf: raw.map(\.id))
            let visible = await applyGalleryFilters(raw)
            sourcePage += 1
            if !visible.isEmpty || raw.isEmpty || sourcePage - (page ?? 0) >= GalleryPaging.maximumSourcePages {
                return GalleryPageBatch(items: visible, nextSourcePage: sourcePage, canLoadMore: !raw.isEmpty, sourceIDs: sourceIDs)
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
        return try await api.request(path: "reaction/comments", queryItems: queryItems, validate: { comments in
            guard CommunityComment.validatesResponse(comments, for: objectID) else { throw GalleryServiceError.invalidResponse }
        })
    }

    /// 对帖子或评论执行点赞操作。
    ///
    /// 后端使用同一个接口处理帖子和评论的点赞，因此这里只传对象 ID。
    public func like(objectID: String) async throws -> CommunityLikeResult {
        let result: CommunityLikeResult = try await api.request(
            path: "reaction/like",
            method: "POST",
            body: try api.encode(CommunityLikeRequest(obj: objectID)), mutation: .toggle
        )
        resourceUpdates.confirmLike(objectID: objectID, count: result.likeNum)
        return result
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
        let result: CommunityComment = try await api.request(
            path: "reaction/comments",
            method: "POST",
            body: try api.encode(
                CommunityCreateCommentRequest(
                    obj: objectID,
                    text: text,
                    replyObj: replyObjectID,
                    replyUid: replyUID,
                    anonymous: anonymous,
                    imageMids: imageMids
                )
            ),
            mutation: .creation,
            validate: { guard $0.id > 0 else { throw GalleryServiceError.invalidResponse } }
        )
        resourceUpdates.invalidateComments(objectID: objectID)
        return result
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
    /// `last_id` 为 0 时读取最新记录并清零该分类未读数；正值用于历史分页。
    public func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
        var queryItems = [URLQueryItem(name: "type", value: type.rawValue)]
        if let lastID {
            queryItems.append(URLQueryItem(name: "last_id", value: String(lastID)))
        }
        let cursor = lastID.flatMap { $0 > 0 ? $0 : nil }
        return try await api.request(path: "messages", queryItems: queryItems, validate: { messages in
            guard messages.allSatisfy({ message in message.id > 0 && (cursor.map { message.id < $0 } ?? true) }),
                  zip(messages, messages.dropFirst()).allSatisfy({ $0.id > $1.id }) else {
                throw GalleryServiceError.invalidResponse
            }
        })
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
        var progress = CommunityPageProgress<Int>()
        var sourceIDs: [Int] = []
        while true {
            try Task.checkCancellation()
            let rawPosters = try await fetchRawPosters(mode: mode, order: order, search: search, uid: uid,
                page: sourcePage == 0 ? nil : sourcePage, hideBot: hideBot)
            try progress.record(rawPosters.map(\.id))
            sourceIDs.append(contentsOf: rawPosters.map(\.id))
            let visible = await applyGalleryFilters(applyBotFilterIfNeeded(rawPosters, hideBot: hideBot))
            sourcePage += 1
            if !visible.isEmpty || rawPosters.isEmpty || sourcePage - (page ?? 0) >= GalleryPaging.maximumSourcePages {
                return GalleryPageBatch<CommunityPoster>(items: visible, nextSourcePage: sourcePage, canLoadMore: !rawPosters.isEmpty, sourceIDs: sourceIDs)
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
        let revision = resourceUpdates.beginRead()
        defer { resourceUpdates.finishRead(revision) }
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

        let result: [CommunityPoster] = try await api.request(path: "posters", queryItems: queryItems, validate: { posters in
            guard posters.allSatisfy({ $0.id > 0 && $0.likeNum >= 0 && $0.commentNum >= 0 }) else {
                throw GalleryServiceError.invalidResponse
            }
        })
        return resourceUpdates.resolve(result, since: revision)
    }
}
