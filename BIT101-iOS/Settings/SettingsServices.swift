import MineFeature
import TransportCore
import CommunityTransport
import CommunityCore
import DesignSystemKit
//
//  SettingsServices.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Foundation
import Combine

/// 设置中心网络层使用的错误类型。
enum SettingsServiceError: LocalizedError {
    case notLoggedIn
    case invalidResponse
    case uploadFailed

    /// 设置页直接展示此错误文案。
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return CommunitySessionRestorationError.credentialsRejected.localizedDescription
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

@MainActor
protocol AccountSettingsServicing {
    func fetchMyInfo() async throws -> MineUserInfo
    func updateUser(nickname: String?, motto: String?, avatarMid: String?) async throws
    func uploadAvatar(data: Data, filename: String) async throws -> CommunityImage
    func checkLogin() async throws -> Bool
}

struct SettingsAccountDependencies {
    let service: any AccountSettingsServicing
    let credentials: () -> CommunityCredentials
    let profileMutation = AccountProfileMutation()

    func acceptsLoginCheck(_ isLoggedIn: Bool, for owner: CommunityCredentials) -> Bool {
        let current = credentials()
        return current.identity == owner.identity && !current.cookie.isEmpty
            || (!isLoggedIn && current.cookie.isEmpty && current.identity.accountIdentifier == owner.identity.accountIdentifier)
    }
}

@MainActor
final class AccountProfileMutation: ObservableObject {
    @Published private(set) var isUpdating = false
    @Published private(set) var isRunning = false
    var isBusy: Bool { isRunning || isUpdating }
    private var task: Task<Void, Never>?
    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        guard !isBusy else { return false }
        isRunning = true
        task = Task {
            defer { task = nil; isRunning = false }
            guard !Task.isCancelled else { return }
            await operation()
        }
        return true
    }
    func cancel() { task?.cancel() }
    func perform(_ operation: () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        try await operation()
    }
}

@MainActor
final class AccountSettingsModel: ObservableObject {
    @Published private(set) var profile: MineUserInfo?
    @Published private(set) var isLoadingProfile = false
    @Published private(set) var profileLoadError: (any Error)?
    @Published private(set) var isCheckingLogin = false
    @Published private(set) var isLoggedIn: Bool
    @Published var alert: AppAlert?
    private let dependencies: SettingsAccountDependencies
    private var profileOwner: CommunitySessionIdentity?
    private var readRevision = 0

    init(dependencies: SettingsAccountDependencies) {
        self.dependencies = dependencies
        isLoggedIn = !dependencies.credentials().cookie.isEmpty
    }

    func loadProfile(for expected: CommunityCredentials? = nil) async {
        let owner = expected ?? dependencies.credentials()
        guard !owner.cookie.isEmpty else { isLoggedIn = false; profile = nil; profileOwner = nil; return }
        readRevision &+= 1
        let revision = readRevision
        isLoadingProfile = true
        profileLoadError = nil
        defer { if readRevision == revision { isLoadingProfile = false } }
        do {
            let loaded = try await dependencies.service.fetchMyInfo()
            guard isCurrent(owner), readRevision == revision else { return }
            profile = loaded
            profileOwner = owner.identity
            isLoggedIn = true
        } catch {
            guard presents(error, for: owner), readRevision == revision else { return }
            if let settingsError = error as? SettingsServiceError, case .notLoggedIn = settingsError {
                isLoggedIn = false; profile = nil; profileOwner = nil
            }
            profileLoadError = error
            alert = AppAlert(title: "加载资料失败", error: error)
        }
    }

    func checkLogin() async {
        let owner = dependencies.credentials()
        isCheckingLogin = true
        defer { isCheckingLogin = false }
        do {
            let loggedIn = try await dependencies.service.checkLogin()
            guard dependencies.acceptsLoginCheck(loggedIn, for: owner), !Task.isCancelled else { return }
            isLoggedIn = loggedIn
            if loggedIn { await loadProfile(for: owner) }
            else { profile = nil; profileOwner = nil }
        } catch {
            guard presents(error, for: owner) else { return }
            if dependencies.credentials().cookie.isEmpty { isLoggedIn = false; profile = nil }
            alert = AppAlert(title: "检查失败", error: error)
        }
    }

    func updateProfile(nickname: String?, motto: String?) async -> Bool {
        guard let profile, profileOwner == dependencies.credentials().identity else { return false }
        return await updateProfile(profile.updatingUser(nickname: nickname, motto: motto))
    }

    func updateAvatar(preparedData: () async throws -> Data) async {
        let owner = dependencies.credentials()
        guard profileOwner == owner.identity else { return }
        do {
            try await dependencies.profileMutation.perform {
                let data = try await preparedData()
                guard isCurrent(owner), let profile else { return }
                let image = try await dependencies.service.uploadAvatar(data: data, filename: "avatar.jpg")
                guard isCurrent(owner) else { return }
                _ = try await commit(profile.updatingUser(avatar: image), for: owner)
            }
        } catch {
            guard presents(error, for: owner) else { return }
            alert = AppAlert(title: "头像更新失败", error: error)
        }
    }

    private func updateProfile(_ updated: MineUserInfo) async -> Bool {
        let owner = dependencies.credentials()
        var saved = false
        do {
            try await dependencies.profileMutation.perform {
                saved = try await commit(updated, for: owner)
            }
        } catch {
            guard presents(error, for: owner) else { return false }
            alert = AppAlert(title: "更新失败", error: error)
        }
        return saved
    }

    private func commit(_ updated: MineUserInfo, for owner: CommunityCredentials) async throws -> Bool {
        guard isCurrent(owner) else { return false }
        try await dependencies.service.updateUser(nickname: updated.user.nickname,
            motto: updated.user.motto, avatarMid: updated.user.avatar.mid)
        guard isCurrent(owner) else { return false }
        readRevision &+= 1
        profile = updated
        profileOwner = owner.identity
        await loadProfile(for: owner)
        return true
    }

    private func presents(_ error: any Error, for owner: CommunityCredentials) -> Bool {
        !TaskCancellation.matches(error) && dependencies.credentials().identity == owner.identity
    }

    private func isCurrent(_ owner: CommunityCredentials) -> Bool {
        let current = dependencies.credentials()
        return !Task.isCancelled && current.identity == owner.identity && !current.cookie.isEmpty
    }
}

/// 设置中心复用的网络服务。
///
/// 此服务处理账号资料、头像上传和登录状态检查，设置页面通过此服务发起请求。
struct SettingsNetworkService: AccountSettingsServicing {
    private let api: CommunityAPIClient<SettingsServiceError>
    private let validateLogin: () async throws -> Bool

    /// 初始化设置中心网络层。
    ///
    /// 头像上传、资料修改和登录检查消费构造时选择的社区会话与验证能力。
    init(session: CommunitySession, checkLogin: @escaping () async throws -> Bool) {
        api = session.client(errorDomain: "BIT101.Settings")
        validateLogin = checkLogin
    }

    /// 拉取当前登录用户资料。
    ///
    /// 账号设置页复用这条接口。
    func fetchMyInfo() async throws -> MineUserInfo {
        try await api.request(path: "user/info/0")
    }

    /// 更新昵称、签名和头像。
    ///
    /// 接口要求整份资料一起提交；调用方传入未编辑字段的当前值。
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
    func uploadAvatar(data: Data, filename: String = "avatar.jpg") async throws -> CommunityImage {
        let multipart = MultipartFormData.jpegFile(data: data, filename: filename)
        return try await api.request(path: "upload/image", method: "POST", body: multipart.body,
            contentType: multipart.contentType, validate: { image in
                guard image.hasResourceIdentity else { throw SettingsServiceError.invalidResponse }
            })
    }

    /// 检查当前登录状态是否仍然有效。
    ///
    /// 此方法复用登录模块的后台校验逻辑，`LoginService` 统一维护登录判断链路。
    func checkLogin() async throws -> Bool {
        try await validateLogin()
    }
}
