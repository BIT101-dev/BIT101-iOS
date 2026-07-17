import Foundation

protocol PaperListServicing {
    func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary]
    func fetchPaper(id: Int) async throws -> PaperDetail
}

protocol PaperDetailServicing {
    func fetchPaper(id: Int) async throws -> PaperDetail
    func fetchComments(paperID: Int, order: GalleryCommentOrder, page: Int?) async throws -> [GalleryComment]
    func likePaper(id: Int) async throws -> GalleryLikeResult
    func sendLike(objectID: String) async throws -> GalleryLikeResult
    func createComment(
        objectID: String,
        text: String,
        replyObjectID: String?,
        replyUID: Int?,
        anonymous: Bool
    ) async throws -> GalleryComment
}

extension PaperService: PaperListServicing, PaperDetailServicing {}
