import CommunityTransport
import CommunityCore
//
//  CourseService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Foundation

/// 课程模块接口错误。
public enum CourseServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return CommunitySessionRestorationError.credentialsRejected.localizedDescription
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        }
    }
}

extension CourseServiceError: CommunityAPIServiceError {
    public static var communityNotLoggedIn: Self { .notLoggedIn }
    public static var communityInvalidResponse: Self { .invalidResponse }
}

/// 课程模块网络层。
///
/// 课程列表和详情走 `courses` 资源，评论和点赞共用社区 reaction 接口。
public struct CourseService {
    /// 课程列表固定按“最新”顺序请求。
    private static let defaultCourseOrder = "new"



    private let api: CommunityAPIClient<CourseServiceError>

    public init(session: CommunitySession) {
        api = session.client(errorDomain: "BIT101.Course")
    }

    /// 拉取课程列表。
    public func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
        var queryItems = [
            URLQueryItem(name: "order", value: Self.defaultCourseOrder),
            URLQueryItem(name: "page", value: String(page)),
        ]

        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            queryItems.insert(URLQueryItem(name: "search", value: keyword), at: 0)
        }

        return try await api.request(path: "courses", queryItems: queryItems, validate: { courses in
            for course in courses {
                try Self.validateCourseFields(id: course.id, likeNum: course.likeNum, commentNum: course.commentNum, rate: course.rate)
            }
        })
    }

    /// 拉取单门课程详情。
    public func fetchCourse(id: Int) async throws -> CourseDetail {
        try await api.request(path: "courses/\(id)", validate: { detail in
            guard id > 0, detail.id == id else { throw CourseServiceError.invalidResponse }
            try Self.validateCourseFields(id: detail.id, likeNum: detail.likeNum, commentNum: detail.commentNum, rate: detail.rate)
        })
    }

    private nonisolated static func validateCourseFields(id: Int, likeNum: Int, commentNum: Int, rate: Double) throws {
        guard id > 0, likeNum >= 0, commentNum >= 0, (0...10).contains(rate) else {
            throw CourseServiceError.invalidResponse
        }
    }

    /// 拉取单门课程按学期聚合的历史成绩统计。
    public func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] {
        try await api.request(path: "courses/histories", pathComponent: number, validate: { grades in
            guard grades.allSatisfy(\.hasValidStatistics), Set(grades.map(\.term)).count == grades.count else {
                throw CourseServiceError.invalidResponse
            }
        })
    }

    /// 拉取课程评论。
    ///
    /// 课程评论按“最新”顺序请求。
    public func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment] {
        var queryItems = [
            URLQueryItem(name: "obj", value: "course\(courseID)"),
            URLQueryItem(name: "order", value: CommunityCommentOrder.newest.rawValue),
        ]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        return try await api.request(path: "reaction/comments", queryItems: queryItems, validate: { comments in
            guard CommunityComment.validatesResponse(comments, for: "course\(courseID)") else { throw CourseServiceError.invalidResponse }
        })
    }

    /// 对课程评论执行点赞或取消点赞。
    public func like(objectID: String) async throws -> CommunityLikeResult {
        try await api.request(
            path: "reaction/like",
            method: "POST",
            body: try api.encode(CommunityLikeRequest(obj: objectID))
        )
    }

    /// 创建课程评论或回复。
    public func createComment(
        objectID: String,
        text: String,
        replyObjectID: String? = nil,
        replyUID: Int? = nil,
        anonymous: Bool = false,
        rate: Int? = nil
    ) async throws -> CommunityComment {
        try await api.request(
            path: "reaction/comments",
            method: "POST",
            body: try api.encode(
                CommunityCreateCommentRequest(
                    obj: objectID,
                    text: text,
                    replyObj: replyObjectID,
                    replyUid: replyUID,
                    anonymous: anonymous,
                    rate: rate,
                    imageMids: []
                )
            ),
            validate: { guard $0.id > 0 else { throw CourseServiceError.invalidResponse } }
        )
    }

}
