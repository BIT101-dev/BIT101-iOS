import CommunityCore
protocol PaperListServicing {
    func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary]
    func fetchPaper(id: Int) async throws -> PaperDetail
}

protocol PaperDetailServicing {
    func fetchPaper(id: Int) async throws -> PaperDetail
    func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment]
    func likePaper(id: Int) async throws -> CommunityLikeResult
    func sendLike(objectID: String) async throws -> CommunityLikeResult
    func createComment(
        objectID: String,
        text: String,
        replyObjectID: String?,
        replyUID: Int?,
        anonymous: Bool
    ) async throws -> CommunityComment
    func updatePaper(
        id: Int,
        title: String,
        intro: String,
        content: String,
        anonymous: Bool,
        publicEdit: Bool
    ) async throws
    func deletePaper(id: Int) async throws
}

extension PaperService: PaperListServicing, PaperDetailServicing {}
