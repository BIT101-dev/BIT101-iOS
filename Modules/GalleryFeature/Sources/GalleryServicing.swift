import CommunityCore
import Foundation

/// 话廊首页与搜索页所需的最小网络能力。
public protocol GalleryFeedServicing {
    func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster>
    func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster>
    func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster>
    func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster>
}

/// 消息中心所需的网络能力。
public protocol GalleryMessageServicing {
    func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts
    func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage]
}

/// 帖子详情及评论区所需的网络能力。
public protocol GalleryPosterDetailServicing {
    func fetchPoster(id: Int) async throws -> GalleryPosterDetail
    func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment>
    func like(objectID: String) async throws -> CommunityLikeResult
    func createComment(
        objectID: String,
        text: String,
        replyObjectID: String?,
        replyUID: Int?,
        anonymous: Bool,
        imageMids: [String]
    ) async throws -> CommunityComment
    func deleteComment(id: Int) async throws
    func deletePoster(id: Int) async throws
}

public protocol GalleryReportServicing {
    func fetchReportTypes() async throws -> [GalleryReportType]
    func report(objectID: String, typeID: Int, text: String) async throws
}

public protocol GalleryImageUploading {
    func uploadImage(data: Data, filename: String) async throws -> CommunityImage
}

public protocol GalleryComposerServicing: GalleryImageUploading {
    func fetchClaims() async throws -> [CommunityClaim]
    func createPoster(title: String, text: String, imageMids: [String], anonymous: Bool, tags: [String], claimID: Int, isPublic: Bool) async throws -> Int
    func updatePoster(id: Int, title: String, text: String, imageMids: [String], anonymous: Bool, tags: [String], claimID: Int, isPublic: Bool) async throws
}

extension GalleryService: GalleryFeedServicing, GalleryMessageServicing, GalleryPosterDetailServicing, GalleryReportServicing, GalleryComposerServicing {}
