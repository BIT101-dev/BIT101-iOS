//
//  GalleryService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 话题接口层错误。
enum GalleryServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case uploadFailed

    /// 给 UI 直接展示的错误文案。
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再查看话廊。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .uploadFailed:
            return "图片上传失败。"
        }
    }
}

extension GalleryServiceError: CommunityAPIServiceError {
    static var communityNotLoggedIn: Self { .notLoggedIn }
    static var communityInvalidResponse: Self { .invalidResponse }
}

/// 机器人分栏的分页结果。
///
/// 机器人流并不是后端原生 feed，而是 iOS 侧“从最新流抓几页再本地筛”得到的结果，
/// 因此需要额外记录“源分页已经推进到哪一页”。
struct GalleryBotFeedBatch {
    let posters: [GalleryPoster]
    let nextSourcePage: Int
    let canLoadMore: Bool
}

/// 推荐分栏的分页结果。
///
/// 推荐流会额外跳过那些“服务端返回了内容，但本地过滤后为空”的页，避免列表错误地停在半路。
struct GalleryRecommendFeedBatch {
    let posters: [GalleryPoster]
    let nextSourcePage: Int
    let canLoadMore: Bool
}

/// 话题模块网络层。
///
/// 负责帖子流、搜索和与设置中心相关的过滤参数拼接。
struct GalleryService {
    private let api: CommunityAPIClient<GalleryServiceError>

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

    /// 发帖接口返回的最小结果。
    private struct CreatePosterResponse: Decodable {
        let id: Int
        let msg: String
    }

    /// 发评论接口请求体。
    private struct CreateCommentRequest: Encodable {
        let obj: String
        let text: String
        let replyObj: String?
        let replyUid: Int?
        let anonymous: Bool?
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

    /// 构造带共享 cookie 策略的服务实例。
    ///
    /// 话廊接口普遍依赖 fake-cookie，同时又需要继承现有登录 session，
    /// 因此这里沿用共享 `HTTPCookieStorage`，避免每个服务实例各自维护认证状态。
    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        api = CommunityAPIClient(storage: storage, httpClient: httpClient, errorDomain: "BIT101.Gallery")
    }

    /// 拉取某个 feed 的帖子列表。
    ///
    /// 普通 feed 直接映射到后端帖子接口；机器人 feed 则走本地特殊分页逻辑。
    func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> [GalleryPoster] {
        if kind.isBotFeed {
            let batch = try await fetchBotFeed(startPage: page ?? 0)
            return batch.posters
        }

        return try await fetchPosters(
            mode: kind.requestMode,
            order: kind.requestOrder,
            search: nil,
            uid: kind.requestUID,
            page: page,
            hideBot: true
        )
    }

    /// 拉取推荐流的单个源页。
    ///
    /// 首屏只请求一页，保证话题页能尽快显示；后续由 ViewModel 在后台预取更多页。
    func fetchRecommendPage(sourcePage: Int) async throws -> GalleryRecommendFeedBatch {
        let rawPosters = try await fetchRawPosters(
            mode: nil,
            order: nil,
            search: nil,
            uid: nil,
            page: sourcePage == 0 ? nil : sourcePage,
            hideBot: true
        )

        return GalleryRecommendFeedBatch(
            posters: applyBotFilterIfNeeded(rawPosters, hideBot: true),
            nextSourcePage: sourcePage + 1,
            canLoadMore: !rawPosters.isEmpty
        )
    }

    /// 根据搜索关键词和排序条件查询帖子。
    ///
    /// 搜索页会读取设置中的“搜索结果隐藏机器人帖子”开关，因此这里需要回主线程
    /// 拿一份当前设置快照，再决定是否带 `hide_bot`。
    func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> [GalleryPoster] {
        let settings = await MainActor.run {
            AppSettingsStore.loadSnapshotFromDefaults() ?? AppSettingsSnapshot()
        }
        return try await fetchPosters(
            mode: "search",
            order: query.order.rawValue,
            search: query.text.trimmingCharacters(in: .whitespacesAndNewlines),
            uid: -1,
            page: page,
            hideBot: settings.galleryHideBotPosterInSearch
        )
    }

    /// 机器人分栏不是服务端原生 feed，这里从“最新”帖子流里向后多抓几页，再筛出机器人帖子。
    ///
    /// 机器人帖子在整体帖子流里占比并不高，所以这里采用“多抓几页 + 本地筛”的做法。
    /// 扫描上限主要是为了避免一次请求链拉得过深，影响滚动体验。
    func fetchBotFeed(startPage: Int) async throws -> GalleryBotFeedBatch {
        var sourcePage = startPage
        var collected: [GalleryPoster] = []
        var canLoadMore = true
        let maxScanCount = 5

        for _ in 0 ..< maxScanCount where canLoadMore && collected.count < 12 {
            let posters = try await fetchPosters(
                mode: "search",
                order: "new",
                search: nil,
                uid: -1,
                page: sourcePage == 0 ? nil : sourcePage,
                hideBot: false
            )
            collected.append(contentsOf: posters.filter { CommunityModeration.isBotPoster(tags: $0.tags) })
            canLoadMore = !posters.isEmpty
            sourcePage += 1
        }

        return GalleryBotFeedBatch(
            posters: collected,
            nextSourcePage: sourcePage,
            canLoadMore: canLoadMore
        )
    }

    /// 后端虽然支持 `hide_bot` 参数，但当前服务端过滤实现会漏掉机器人帖子。
    ///
    /// iOS 侧在保留服务端参数的同时，再补一层本地兜底，确保普通分栏不会混入机器人帖子。
    private func applyBotFilterIfNeeded(_ posters: [GalleryPoster], hideBot: Bool) -> [GalleryPoster] {
        guard hideBot else {
            return posters
        }

        return posters.filter { !CommunityModeration.isBotPoster(tags: $0.tags) }
    }

    /// 获取可选的帖子 claim 列表。
    ///
    /// claim 会驱动发帖页里的“声明”选择器，因此它属于一个低频但必须成功的基础数据。
    func fetchClaims() async throws -> [GalleryClaim] {
        try await api.request(path: "posters/claims")
    }

    /// 上传一张发帖图片，返回服务端生成的图片资源对象。
    ///
    /// 话廊发帖沿用 Android 端的老接口：先上传拿到 `mid`，再把 `image_mids`
    /// 放进真正的发帖请求里。
    func uploadImage(data: Data, filename: String = "poster.jpg") async throws -> GalleryImage {
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
    func createPoster(
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
    func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
        try await api.request(path: "posters/\(id)")
    }

    /// 删除一条帖子。
    ///
    /// 删除接口没有复杂返回体，只以 HTTP 成功与否为准。
    func deletePoster(id: Int) async throws {
        try await api.requestVoid(path: "posters/\(id)", method: "DELETE")
    }

    /// 拉取帖子或评论对象下的评论列表。
    ///
    /// 评论列表接口同时服务帖子评论和评论回复，因此通过 `obj` 参数区分目标对象。
    func fetchComments(
        objectID: String,
        order: GalleryCommentOrder,
        page: Int?
    ) async throws -> [GalleryComment] {
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
    /// 后端统一把帖子点赞和评论点赞收口到同一个接口，因此这里只需要传对象 ID。
    func like(objectID: String) async throws -> GalleryLikeResult {
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
    func createComment(
        objectID: String,
        text: String,
        replyObjectID: String? = nil,
        replyUID: Int? = nil,
        anonymous: Bool = false
    ) async throws -> GalleryComment {
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
                    imageMids: []
                )
            )
        )
    }

    /// 获取消息中心各分类的未读数。
    ///
    /// 服务端目前只提供分类未读数，不提供逐条 read 状态，因此消息页的“伪新消息”
    /// 需要先依赖这里的结果。
    func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts {
        try await api.request(path: "messages/unread_nums")
    }

    /// 拉取某个消息分类的列表。
    ///
    /// 后端使用 `last_id` 做历史分页；首次传空会顺手把该分类未读数清零。
    func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
        var queryItems = [URLQueryItem(name: "type", value: type.rawValue)]
        if let lastID {
            queryItems.append(URLQueryItem(name: "last_id", value: String(lastID)))
        }
        return try await api.request(path: "messages", queryItems: queryItems)
    }

    /// 统一拼装帖子流接口参数。
    ///
    /// 这是普通帖子 feed 的公共入口，会在拿到服务端结果后再按设置补一层本地机器人过滤。
    private func fetchPosters(
        mode: String?,
        order: String?,
        search: String?,
        uid: Int?,
        page: Int?,
        hideBot: Bool
    ) async throws -> [GalleryPoster] {
        let posters = try await fetchRawPosters(
            mode: mode,
            order: order,
            search: search,
            uid: uid,
            page: page,
            hideBot: hideBot
        )
        return applyBotFilterIfNeeded(posters, hideBot: hideBot)
    }

    /// 发起原始帖子流请求，不做客户端过滤，供更高层组合推荐/机器人等特殊分页语义。
    ///
    /// 把“原始请求”和“本地过滤”拆开，是因为推荐流和机器人流都需要基于服务端原始分页
    /// 自己决定如何跳页、如何兜底，而不能简单复用一层已经过滤后的数组。
    private func fetchRawPosters(
        mode: String?,
        order: String?,
        search: String?,
        uid: Int?,
        page: Int?,
        hideBot: Bool
    ) async throws -> [GalleryPoster] {
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
