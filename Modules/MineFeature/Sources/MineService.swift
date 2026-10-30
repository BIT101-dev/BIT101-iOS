import Combine
import CommunityTransport
import CommunityCore
//
//  MineService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// “我的”页接口层错误。
///
/// 错误枚举保留面向 UI 的少量分类；底层 HTTP 状态码在必要时转换为通用 NSError。
public enum MineServiceError: LocalizedError {
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

extension MineServiceError: CommunityAPIServiceError {
    public static var communityNotLoggedIn: Self { .notLoggedIn }
    public static var communityInvalidResponse: Self { .invalidResponse }
}

/// “我的”页网络层。
///
/// 这层只负责“我的”和“他人主页”会共用到的资料卡、关注关系和帖子列表请求，
/// 不承载任何页面状态，也不做分页拼接。
public struct MineService {
    /// “我的”页请求使用的社区 API 客户端。
    private let api: CommunityAPIClient<MineServiceError>
    private let session: CommunitySession
    private let resourceUpdates: CommunityResourceUpdates<CommunitySessionIdentity>
    public var resourceChanges: AnyPublisher<[CommunityResourceMetrics], Never> { resourceUpdates.changes }

    private let preferences: () -> CommunityPreferenceSnapshot

    /// 初始化社区 API 客户端。
    ///
    /// 资料请求通过注入会话取得当前账号凭据，并复用社区连接池。
    public init(session: CommunitySession, preferences: @escaping () -> CommunityPreferenceSnapshot,
        resourceUpdates: CommunityResourceUpdates<CommunitySessionIdentity>? = nil) {
        self.session = session
        self.resourceUpdates = resourceUpdates ?? .init(currentOwner: { session.currentCredentials.identity })
        api = session.client(errorDomain: "BIT101.Mine")
        self.preferences = preferences
    }

    /// 获取当前登录用户自己的资料卡信息。
    ///
    /// 服务端以 `0` 表示当前用户；指定用户通过实际 ID 查询。
    public func fetchMyInfo() async throws -> MineUserInfo {
        try await api.request(path: "user/info/0")
    }

    /// 获取指定用户的公开资料卡信息。
    public func fetchUserInfo(id: Int) async throws -> MineUserInfo {
        let response: CommunityAPIResponse<MineUserInfo> = try await api.response(path: "user/info/\(id)", authentication: .optional, validate: { info in
            guard id > 0, info.user.id == id else { throw MineServiceError.invalidResponse }
        })
        var info = response.value
        info.isViewerAuthenticated = response.isAuthenticated
        return info
    }

    public func followUser(id: Int) async throws -> MineFollowResult {
        try await api.request(path: "user/follow/\(id)", method: "POST", mutation: .toggle)
    }

    /// 获取我关注的用户列表。
    ///
    /// 关注/粉丝接口都使用页码分页，第一页从 0 开始。
    public func fetchFollowings(page: Int) async throws -> [CommunityUser] {
        try await api.request(path: "user/followings", queryItems: [URLQueryItem(name: "page", value: String(page))])
    }

    /// 获取我的粉丝列表。
    public func fetchFollowers(page: Int) async throws -> [CommunityUser] {
        try await api.request(path: "user/followers", queryItems: [URLQueryItem(name: "page", value: String(page))])
    }

    /// 获取“我的帖子”列表；普通帖子页面按设置隐藏机器人帖子。
    ///
    /// 服务端通过 `uid=0` 约定当前登录用户。
    public func fetchMyPosters(page: Int) async throws -> [CommunityPoster] {
        try await fetchPosters(userID: 0, page: page)
    }

    /// 获取指定用户的帖子列表；普通帖子页面按设置隐藏机器人帖子。
    ///
    /// 这里复用帖子搜索接口的 `uid` 语义，用户帖子接口保持独立路径。
    public func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster] {
        try await fetchPosters(userID: userID, page: page)
    }

    private func fetchPosters(userID: Int, page: Int) async throws -> [CommunityPoster] {
        let identity = session.currentCredentials.identity
        let revision = resourceUpdates.beginRead()
        defer { resourceUpdates.finishRead(revision) }
        var queryItems = [
            URLQueryItem(name: "mode", value: "search"),
            URLQueryItem(name: "uid", value: String(userID)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        if preferences().galleryHideBotPosterInSearch {
            queryItems.append(URLQueryItem(name: "hide_bot", value: "true"))
        }
        let response: CommunityAPIResponse<[CommunityPoster]> = try await api.response(
            path: "posters",
            queryItems: queryItems,
            validate: { posters in
                guard userID == 0 || posters.allSatisfy({ $0.user.id == userID }) else { throw MineServiceError.invalidResponse }
            }
        )
        if let issue = response.value.compactMap(\.imageRecoveryIssue).first { await response.reportValidationFailure(issue) }
        try Task.checkCancellation()
        guard session.currentCredentials.identity == identity else { throw CancellationError() }
        return resourceUpdates.resolve(response.value, since: revision)
    }

}

