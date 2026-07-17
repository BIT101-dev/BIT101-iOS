//
//  SettingsServices.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 设置中心网络层的统一错误。
enum SettingsServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case uploadFailed

    /// 给设置页直接展示的错误文案。
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "当前登录状态无效。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .uploadFailed:
            return "图片上传失败。"
        }
    }
}

extension SettingsServiceError: CommunityAPIServiceError {
    static var communityNotLoggedIn: Self { .notLoggedIn }
    static var communityInvalidResponse: Self { .invalidResponse }
}

/// 设置中心会复用到的网络请求集合。
///
/// 账号信息、头像上传、登录状态检查和版本检查都集中在这里，避免页面层直接拼请求。
struct SettingsNetworkService {
    private let api: CommunityAPIClient<SettingsServiceError>

    /// 初始化设置中心网络层。
    ///
    /// 头像上传和资料修改都依赖 fake-cookie，因此这里与主 app 共用登录态存储。
    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        api = CommunityAPIClient(storage: storage, httpClient: httpClient, errorDomain: "BIT101.Settings")
    }

    /// 拉取当前登录用户自己的资料。
    ///
    /// 账号设置页、隐藏用户列表恢复展示等场景都会复用这条接口。
    func fetchMyInfo() async throws -> MineUserInfo {
        try await api.request(path: "user/info/0")
    }

    /// 拉取指定用户的公开资料。
    func fetchUserInfo(id: Int) async throws -> MineUserInfo {
        try await api.request(path: "user/info/\(id)")
    }

    /// 更新昵称、签名和头像。
    ///
    /// 接口要求整份资料一起提交，因此调用方需要自行传入“未改动但仍需保留”的旧值。
    func updateUser(nickname: String?, motto: String?, avatarMid: String?) async throws {
        let body = try api.encode([
            "nickname": nickname,
            "motto": motto,
            "avatar_mid": avatarMid,
        ])
        try await api.requestVoid(path: "user/info", method: "PUT", body: body)
    }

    /// 上传头像图片，返回服务端生成的图片资源对象。
    ///
    /// 上传成功后还需要再调用一次 `updateUser`，把返回的 `mid` 绑定到用户资料里。
    func uploadAvatar(data: Data, filename: String = "avatar.jpg") async throws -> GalleryImage {
        let multipart = MultipartFormData.jpegFile(data: data, filename: filename)
        do {
            return try await api.request(
                path: "upload/image",
                method: "POST",
                body: multipart.body,
                contentType: multipart.contentType
            )
        } catch let error as NSError where error.code >= 400 {
            throw SettingsServiceError.uploadFailed
        }
    }

    /// 检查当前登录状态是否仍然有效。
    ///
    /// 这里直接复用登录模块的后台校验逻辑，不额外复制一套登录判断链路。
    func checkLogin() async throws -> Bool {
        try await LoginService().checkLogin() != nil
    }

}
