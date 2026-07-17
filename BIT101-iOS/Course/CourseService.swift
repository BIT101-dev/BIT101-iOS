//
//  CourseService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Foundation

/// 课程模块接口错误。
enum CourseServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再查看课程。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        }
    }
}

extension CourseServiceError: CommunityAPIServiceError {
    static var communityNotLoggedIn: Self { .notLoggedIn }
    static var communityInvalidResponse: Self { .invalidResponse }
}

/// 课程模块网络层。
///
/// 课程列表和详情走 `courses` 资源，评论和点赞仍然复用社区 reaction 接口。
struct CourseService {
    /// 课程页当前不再暴露排序切换，列表固定按“最新”请求。
    private static let defaultCourseOrder = "new"

    private struct CreateCommentRequest: Encodable {
        let obj: String
        let text: String
        let replyObj: String?
        let replyUid: Int?
        let anonymous: Bool?
        let rate: Int?
        let imageMids: [String]

        enum CodingKeys: String, CodingKey {
            case obj
            case text
            case replyObj = "reply_obj"
            case replyUid = "reply_uid"
            case anonymous
            case rate
            case imageMids = "image_mids"
        }
    }

    private struct LikeRequest: Encodable {
        let obj: String
    }

    private let api: CommunityAPIClient<CourseServiceError>

    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        api = CommunityAPIClient(storage: storage, httpClient: httpClient, errorDomain: "BIT101.Course")
    }

    /// 拉取课程列表。
    func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
        var queryItems = [
            URLQueryItem(name: "order", value: Self.defaultCourseOrder),
            URLQueryItem(name: "page", value: String(page)),
        ]

        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            queryItems.insert(URLQueryItem(name: "search", value: keyword), at: 0)
        }

        return try await api.request(path: "courses", queryItems: queryItems)
    }

    /// 拉取单门课程详情。
    func fetchCourse(id: Int) async throws -> CourseDetail {
        try await api.request(path: "courses/\(id)")
    }

    /// 拉取单门课程按学期聚合的历史成绩统计。
    func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] {
        try await api.request(path: "courses/histories/\(number)")
    }

    /// 拉取课程评论。
    ///
    /// 课程页当前评论量较小，不再提供排序切换，因此固定拉取“最新”顺序。
    func fetchComments(courseID: Int, page: Int?) async throws -> [GalleryComment] {
        var queryItems = [
            URLQueryItem(name: "obj", value: "course\(courseID)"),
            URLQueryItem(name: "order", value: GalleryCommentOrder.newest.rawValue),
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        return try await api.request(path: "reaction/comments", queryItems: queryItems)
    }

    /// 对课程评论执行点赞或取消点赞。
    func like(objectID: String) async throws -> GalleryLikeResult {
        try await api.request(
            path: "reaction/like",
            method: "POST",
            body: try api.encode(LikeRequest(obj: objectID))
        )
    }

    /// 创建课程评论或回复。
    func createComment(
        objectID: String,
        text: String,
        replyObjectID: String? = nil,
        replyUID: Int? = nil,
        anonymous: Bool = false,
        rate: Int? = nil
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
                    rate: rate,
                    imageMids: []
                )
            )
        )
    }

}
