import Foundation

/// 话廊首页与搜索页所需的最小网络能力。
protocol GalleryFeedServicing {
    func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> [GalleryPoster]
    func fetchRecommendPage(sourcePage: Int) async throws -> GalleryRecommendFeedBatch
    func fetchBotFeed(startPage: Int) async throws -> GalleryBotFeedBatch
    func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> [GalleryPoster]
}

/// 消息中心所需的网络能力。
protocol GalleryMessageServicing {
    func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts
    func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage]
}

/// 帖子详情及评论区所需的网络能力。
protocol GalleryPosterDetailServicing {
    func fetchPoster(id: Int) async throws -> GalleryPosterDetail
    func fetchComments(objectID: String, order: GalleryCommentOrder, page: Int?) async throws -> [GalleryComment]
    func like(objectID: String) async throws -> GalleryLikeResult
    func createComment(
        objectID: String,
        text: String,
        replyObjectID: String?,
        replyUID: Int?,
        anonymous: Bool
    ) async throws -> GalleryComment
    func deletePoster(id: Int) async throws
}

extension GalleryService: GalleryFeedServicing, GalleryMessageServicing, GalleryPosterDetailServicing {}
