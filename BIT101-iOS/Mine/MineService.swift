//
//  MineService.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// “我的”页接口层错误。
///
/// 这里故意只保留少量、面向 UI 的错误分类；更底层的 HTTP 状态码会在必要时转成通用 NSError。
enum MineServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效，请重新登录后再查看个人主页。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        }
    }
}

extension MineServiceError: CommunityAPIServiceError {
    static var communityNotLoggedIn: Self { .notLoggedIn }
    static var communityInvalidResponse: Self { .invalidResponse }
}

/// “我的”页网络层。
///
/// 这层只负责“我的”和“他人主页”会共用到的资料卡、关注关系和帖子列表请求，
/// 不承载任何页面状态，也不做分页拼接。
struct MineService {
    /// 个人主页相关接口根地址。
    private let api: CommunityAPIClient<MineServiceError>

    /// 初始化带 fake-cookie 的会话。
    ///
    /// “我的”页和话题页共用同一份登录存储，因此这里沿用系统 cookie 容器。
    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        api = CommunityAPIClient(storage: storage, httpClient: httpClient, errorDomain: "BIT101.Mine")
    }

    /// 获取当前登录用户自己的资料卡信息。
    ///
    /// 服务端以 `0` 作为“当前用户”的占位 ID，所以“我的主页”和“他人主页”需要分别走不同接口路径。
    func fetchMyInfo() async throws -> MineUserInfo {
        try await api.request(path: "user/info/0")
    }

    /// 获取指定用户的公开资料卡信息。
    func fetchUserInfo(id: Int) async throws -> MineUserInfo {
        try await api.request(path: "user/info/\(id)")
    }

    /// 获取我关注的用户列表。
    ///
    /// 关注/粉丝接口都使用页码分页，第一页从 0 开始。
    func fetchFollowings(page: Int) async throws -> [GalleryUser] {
        try await api.request(path: "user/followings", queryItems: [URLQueryItem(name: "page", value: String(page))])
    }

    /// 获取我的粉丝列表。
    func fetchFollowers(page: Int) async throws -> [GalleryUser] {
        try await api.request(path: "user/followers", queryItems: [URLQueryItem(name: "page", value: String(page))])
    }

    /// 获取“我的帖子”列表；普通帖子页面按设置隐藏机器人帖子。
    ///
    /// 服务端通过 `uid=0` 约定当前登录用户。
    func fetchMyPosters(page: Int) async throws -> [GalleryPoster] {
        var queryItems = [
            URLQueryItem(name: "mode", value: "search"),
            URLQueryItem(name: "uid", value: "0"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        if await shouldHideBotPosters() {
            queryItems.append(URLQueryItem(name: "hide_bot", value: "true"))
        }
        return try await api.request(
            path: "posters",
            queryItems: queryItems
        )
    }

    /// 获取指定用户的帖子列表；普通帖子页面按设置隐藏机器人帖子。
    ///
    /// 这里沿用帖子搜索接口的 `uid` 语义，而不是单独的“用户帖子”接口。
    func fetchUserPosters(userID: Int, page: Int) async throws -> [GalleryPoster] {
        var queryItems = [
            URLQueryItem(name: "mode", value: "search"),
            URLQueryItem(name: "uid", value: String(userID)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        if await shouldHideBotPosters() {
            queryItems.append(URLQueryItem(name: "hide_bot", value: "true"))
        }
        return try await api.request(
            path: "posters",
            queryItems: queryItems
        )
    }

    private func shouldHideBotPosters() async -> Bool {
        await MainActor.run {
            AppSettingsStore.loadSnapshotFromDefaults()?.galleryHideBotPosterInSearch ?? false
        }
    }

}
