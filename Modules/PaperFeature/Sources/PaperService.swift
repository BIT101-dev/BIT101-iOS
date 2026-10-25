import CommunityTransport
import CommunityCore
//
//  PaperService.swift
//  BIT101-iOS
import Foundation

/// 文章模块网络层错误。
public enum PaperServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case missingPaper

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return CommunitySessionRestorationError.credentialsRejected.localizedDescription
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .missingPaper:
            return "文章已删除或暂时无法访问。"
        }
    }
}

extension PaperServiceError: CommunityAPIServiceError {
    public static var communityNotLoggedIn: Self { .notLoggedIn }
    public static var communityInvalidResponse: Self { .invalidResponse }
    public static func communityResourceFailure(path: String, message: String?) -> Self? {
        let parts = path.split(separator: "/")
        return parts.count == 2 && parts[0] == "papers" && Int(parts[1]) != nil && message == "文章不存在Orz" ? .missingPaper : nil
    }
}

/// 文章模块网络层。
///
/// 文章列表和详情接口独立于话廊。文章点赞和评论沿用 reaction 接口。
public struct PaperService {
    private let api: CommunityAPIClient<PaperServiceError>
    private let session: CommunitySession
    private let details = PaperDetailRequestStore()



    private struct CreatePaperRequest: Encodable {
        let title: String
        let intro: String
        let content: String
        let anonymous: Bool
        let publicEdit: Bool

        enum CodingKeys: String, CodingKey {
            case title
            case intro
            case content
            case anonymous
            case publicEdit = "public_edit"
        }
    }

    private nonisolated struct CreatePaperResponse: Decodable, Sendable {
        let id: Int
    }

    private struct UpdatePaperRequest: Encodable {
        let title: String
        let intro: String
        let content: String
        let anonymous: Bool
        let publicEdit: Bool
        let lastTime: TimeInterval

        enum CodingKeys: String, CodingKey {
            case title, intro, content, anonymous
            case publicEdit = "public_edit"
            case lastTime = "last_time"
        }
    }

    public init(session: CommunitySession) {
        self.session = session
        api = session.client(errorDomain: "BIT101.Paper")
    }

    /// 拉取文章列表。
    public func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
        var queryItems = [URLQueryItem(name: "page", value: String(page))]
        if let search, !search.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }
        if let orderValue = order.requestValue {
            queryItems.append(URLQueryItem(name: "order", value: orderValue))
        }
        let papers: [PaperSummary] = try await api.request(path: "papers", queryItems: queryItems, authentication: .optional)
        if page == 0 { details.invalidate(ids: Set(papers.map(\.id))) }
        return papers
    }

    /// 读取作者预览交接的文章内容。
    public func cachedPaper(id: Int) async -> PaperDetail? {
        guard !Task.isCancelled else { return nil }
        return details.cachedDetail(id: id, credentials: session.currentCredentials)
    }

    /// 重新确认文章正文及当前账号的交互状态。
    public func fetchPaper(id: Int) async throws -> PaperDetail {
        let credentials = session.currentCredentials
        return try await details.detail(id: id, credentials: credentials) {
            try await self.loadPaper(id: id, credentials: credentials)
        }
    }

    public func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata {
        let credentials = session.currentCredentials
        return try await details.preview(id: id, credentials: credentials) {
            try await self.loadPaper(id: id, credentials: credentials)
        }
    }

    private func loadPaper(id: Int, credentials: CommunityCredentials) async throws -> PaperDetail {
        guard session.currentCredentials.identity == credentials.identity else { throw CancellationError() }
        let response: CommunityAPIResponse<PaperDetail> = try await api.response(path: "papers/\(id)", authentication: .optional,
            validate: { detail in guard id > 0, detail.id == id else { throw PaperServiceError.invalidResponse } })
        var detail = response.value
        detail.isViewerAuthenticated = response.isAuthenticated
        return detail
    }

    /// 拉取文章评论。
    public func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment] {
        var queryItems = [
            URLQueryItem(name: "obj", value: "paper\(paperID)"),
            URLQueryItem(name: "order", value: order.rawValue),
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        let response: CommunityAPIResponse<[CommunityComment]> = try await api.response(path: "reaction/comments",
            queryItems: queryItems, authentication: .optional, validate: { comments in
                guard CommunityComment.validatesResponse(comments, for: "paper\(paperID)") else { throw PaperServiceError.invalidResponse }
            })
        return response.value.map { $0.settingViewerAuthentication(response.isAuthenticated) }
    }

    /// 点赞或取消点赞文章。
    public func likePaper(id: Int) async throws -> CommunityLikeResult {
        try await sendLike(objectID: "paper\(id)")
    }

    /// 点赞或取消点赞评论。
    ///
    /// 文章详情评论通过 reaction 接口处理。这个方法为评论点赞提供通用入口。
    public func sendLike(objectID: String) async throws -> CommunityLikeResult {
        defer { details.invalidate() }
        return try await api.request(
            path: "reaction/like",
            method: "POST",
            body: try api.encode(CommunityLikeRequest(obj: objectID))
        )
    }

    /// 发送文章评论或回复。
    public func createComment(
        objectID: String,
        text: String,
        replyObjectID: String? = nil,
        replyUID: Int? = nil,
        anonymous: Bool = false
    ) async throws -> CommunityComment {
        defer { details.invalidate() }
        return try await api.request(
            path: "reaction/comments",
            method: "POST",
            body: try api.encode(
                CommunityCreateCommentRequest(
                    obj: objectID,
                    text: text,
                    replyObj: replyObjectID,
                    replyUid: replyUID,
                    anonymous: anonymous,
                    imageMids: []
                )
            ),
            validate: { guard $0.id > 0 else { throw PaperServiceError.invalidResponse } }
        )
    }

    /// 新建文章。
    public func createPaper(
        title: String,
        intro: String,
        content: String,
        anonymous: Bool,
        publicEdit: Bool = true
    ) async throws -> Int {
        defer { details.invalidate() }
        let response: CreatePaperResponse = try await api.request(
            path: "papers",
            method: "POST",
            body: try api.encode(
                CreatePaperRequest(
                    title: title,
                    intro: intro,
                    content: content,
                    anonymous: anonymous,
                    publicEdit: publicEdit
                )
            ),
            validate: { guard $0.id > 0 else { throw PaperServiceError.invalidResponse } }
        )
        return response.id
    }

    public func updatePaper(
        id: Int,
        title: String,
        intro: String,
        content: String,
        anonymous: Bool,
        publicEdit: Bool = true,
        lastUpdatedAt: String
    ) async throws {
        defer { details.invalidate() }
        guard let version = AppDateText.date(from: lastUpdatedAt) else { throw PaperServiceError.invalidResponse }
        try await api.requestVoid(
            path: "papers/\(id)",
            method: "PUT",
            body: try api.encode(
                UpdatePaperRequest(
                    title: title,
                    intro: intro,
                    content: content,
                    anonymous: anonymous,
                    publicEdit: publicEdit,
                    lastTime: version.timeIntervalSince1970
                )
            )
        )
    }

    public func deletePaper(id: Int) async throws {
        defer { details.invalidate() }
        try await api.requestVoid(path: "papers/\(id)", method: "DELETE")
    }

}
