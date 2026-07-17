//
//  PaperService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-01.
//

import Foundation

/// 文章模块网络层错误。
enum PaperServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再查看文章。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        }
    }
}

extension PaperServiceError: CommunityAPIServiceError {
    static var communityNotLoggedIn: Self { .notLoggedIn }
    static var communityInvalidResponse: Self { .invalidResponse }
}

/// 文章模块网络层。
///
/// 文章列表和详情接口独立于话廊，但点赞、评论仍然沿用同一套 reaction 接口。
struct PaperService {
    private let api: CommunityAPIClient<PaperServiceError>

    private struct LikeRequest: Encodable {
        let obj: String
    }

    private struct CreateCommentRequest: Encodable {
        let obj: String
        let text: String
        let replyObj: String?
        let replyUid: Int?
        let anonymous: Bool?
        let imageMids: [String]

        enum CodingKeys: String, CodingKey {
            case obj
            case text
            case replyObj = "reply_obj"
            case replyUid = "reply_uid"
            case anonymous
            case imageMids = "image_mids"
        }
    }

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

    private struct CreatePaperResponse: Decodable {
        let id: Int
    }

    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        api = CommunityAPIClient(storage: storage, httpClient: httpClient, errorDomain: "BIT101.Paper")
    }

    /// 拉取文章列表。
    func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
        var queryItems = [URLQueryItem(name: "page", value: String(page))]
        if let search, !search.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }
        if let orderValue = order.requestValue {
            queryItems.append(URLQueryItem(name: "order", value: orderValue))
        }
        return try await api.request(path: "papers", queryItems: queryItems, authentication: .optional)
    }

    /// 拉取单篇文章详情。
    func fetchPaper(id: Int) async throws -> PaperDetail {
        try await api.request(path: "papers/\(id)", authentication: .optional)
    }

    /// 拉取文章评论。
    func fetchComments(paperID: Int, order: GalleryCommentOrder, page: Int?) async throws -> [GalleryComment] {
        var queryItems = [
            URLQueryItem(name: "obj", value: "paper\(paperID)"),
            URLQueryItem(name: "order", value: order.rawValue),
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        return try await api.request(path: "reaction/comments", queryItems: queryItems, authentication: .optional)
    }

    /// 点赞或取消点赞文章。
    func likePaper(id: Int) async throws -> GalleryLikeResult {
        try await sendLike(objectID: "paper\(id)")
    }

    /// 点赞或取消点赞评论。
    ///
    /// 文章详情里的评论同样通过 reaction 接口处理，所以这里开放一个最小通用入口。
    func sendLike(objectID: String) async throws -> GalleryLikeResult {
        try await api.request(
            path: "reaction/like",
            method: "POST",
            body: try api.encode(LikeRequest(obj: objectID))
        )
    }

    /// 发送文章评论或回复。
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

    /// 新建文章。
    func createPaper(
        title: String,
        intro: String,
        content: String,
        anonymous: Bool,
        publicEdit: Bool = true
    ) async throws -> Int {
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
            )
        )
        return response.id
    }

}
