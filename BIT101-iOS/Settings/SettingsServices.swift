//
//  SettingsServices.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation

/// 设置中心网络层使用的错误类型。
enum SettingsServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case uploadFailed

    /// 设置页直接展示此错误文案。
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

/// 设置中心复用的网络服务。
///
/// 此服务处理账号资料、头像上传和登录状态检查，设置页面通过此服务发起请求。
struct SettingsNetworkService {
    private let api: CommunityAPIClient<SettingsServiceError>

    /// 初始化设置中心网络层。
    ///
    /// 头像上传和资料修改依赖 fake-cookie；此服务与主 App 共用登录态存储。
    init(storage: LoginStorage = .shared, httpClient: HTTPClient = .community) {
        api = CommunityAPIClient(storage: storage, httpClient: httpClient, errorDomain: "BIT101.Settings")
    }

    /// 拉取当前登录用户资料。
    ///
    /// 账号设置页复用这条接口。
    func fetchMyInfo() async throws -> MineUserInfo {
        try await api.request(path: "user/info/0")
    }

    /// 更新昵称、签名和头像。
    ///
    /// 接口要求整份资料一起提交；调用方传入“未改动但仍需保留”的旧值。
    func updateUser(nickname: String?, motto: String?, avatarMid: String?) async throws {
        let body = try api.encode([
            "nickname": nickname,
            "motto": motto,
            "avatar_mid": avatarMid,
        ])
        try await api.requestVoid(path: "user/info", method: "PUT", body: body)
    }

    /// 上传头像并返回服务端生成的图片资源对象。
    ///
    /// 上传成功后，调用方再次调用 `updateUser`，将返回的 `mid` 绑定到用户资料。
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
    /// 此方法复用登录模块的后台校验逻辑，`LoginService` 统一维护登录判断链路。
    func checkLogin() async throws -> Bool {
        try await LoginService().checkLogin() != nil
    }
}
