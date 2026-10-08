import MineFeature
import TransportCore
import MediaKit
import CommunityCore
import CommunityTransport
import DesignSystemKit
//
//  SettingsAccountViews.swift
//  BIT101-iOS
//
//  Split from SettingsRootView.swift.
//

import PhotosUI
import SwiftUI

struct AccountSettingsPage: View {
    let dependencies: SettingsAccountDependencies
    let studentID: String
    let onLogout: () -> Void

    @State private var profile: MineUserInfo?
    @State private var isCheckingLogin = false
    @State private var isLoggedIn: Bool
    @StateObject private var profileMutation = AccountProfileMutation()
    private var isUpdating: Bool { profileMutation.isUpdating }
    @State private var showNicknameEditor = false
    @State private var showMottoEditor = false
    @State private var nicknameText = ""
    @State private var mottoText = ""
    @State private var isShowingStudentID = false
    @State private var isShowingUID = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isShowingPhotoPicker = false
    @State private var alert: AppAlert?

    private var service: any AccountSettingsServicing { dependencies.service }

    init(dependencies: SettingsAccountDependencies, studentID: String, onLogout: @escaping () -> Void) {
        self.dependencies = dependencies
        self.studentID = studentID
        self.onLogout = onLogout
        _isLoggedIn = State(initialValue: !dependencies.credentials().cookie.isEmpty)
    }

    var body: some View {
        List {
            if let profile {
                Section("个人信息") {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text("头像")
                            .foregroundStyle(.tint)
                        Spacer()
                        Button {
                            isShowingPhotoPicker = true
                        } label: {
                            AppAvatarView(
                                imageURL: URL(string: profile.user.avatar.url),
                                size: AppDesignSystem.Size.Avatar.standard,
                                tint: AppDesignSystem.Palette.Accent.primary
                            )
                        }
                        .accessibilityLabel("头像")
                        .accessibilityHint("选择新头像")
                        .disabled(isUpdating)
                        .photosPicker(
                            isPresented: $isShowingPhotoPicker,
                            selection: $selectedPhoto,
                            matching: .images
                        )
                        .appInteractiveListRow()
                    }

                    Button {
                        nicknameText = profile.user.nickname
                        showNicknameEditor = true
                    } label: {
                        LabeledContent("昵称", value: profile.user.nickname)
                    }
                    .disabled(isUpdating)
                    .appInteractiveListRow()

                    Button {
                        mottoText = profile.user.motto
                        showMottoEditor = true
                    } label: {
                        LabeledContent("个性签名", value: profile.user.motto.isEmpty ? "空" : profile.user.motto)
                    }
                    .disabled(isUpdating)
                    .appInteractiveListRow()

                    SettingsSensitiveValueRow(
                        title: "学号",
                        value: studentID,
                        isRevealed: $isShowingStudentID
                    )

                    SettingsSensitiveValueRow(
                        title: "UID",
                        value: String(profile.user.id),
                        isRevealed: $isShowingUID
                    )
                }
            }

            Section("登录状态") {
                Button {
                    Task { await checkLogin() }
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text("登录状态检查")
                        Spacer()
                        if isCheckingLogin {
                            ProgressView()
                                .accessibilityLabel("正在检查登录状态")
                        } else {
                            Text(isLoggedIn ? "已登录" : "未登录")
                                .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        }
                    }
                }
                .disabled(isCheckingLogin)
                .appInteractiveListRow()

                Button("退出登录", role: .destructive, action: onLogout)
                    .accessibilityIdentifier("settings.account.logout")
                    .disabled(isUpdating)
                .appInteractiveListRow(isDestructive: true)
            }
        }
        .appGroupedListStyle()
        .task {
            guard !dependencies.credentials().cookie.isEmpty else {
                isLoggedIn = false
                return
            }
            await loadProfile()
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task { await updateAvatar(with: newValue) }
        }
        .sheet(isPresented: $showNicknameEditor) {
            SettingsTextEditSheet(
                title: "修改昵称",
                text: $nicknameText,
                isSubmitting: isUpdating,
                onSubmit: {
                    Task { await updateProfile(nickname: nicknameText, motto: nil) }
                }
            )
        }
        .sheet(isPresented: $showMottoEditor) {
            SettingsTextEditSheet(
                title: "修改个性签名",
                text: $mottoText,
                axis: .vertical,
                isSubmitting: isUpdating,
                onSubmit: {
                    Task { await updateProfile(nickname: nil, motto: mottoText) }
                }
            )
        }
        .diagnosticAlert(item: $alert)
    }

    /// 页面加载当前登录用户资料卡。
    private func loadProfile(for expectedCredentials: CommunityCredentials? = nil) async {
        let credentials = expectedCredentials ?? dependencies.credentials()
        guard !credentials.cookie.isEmpty else {
            isLoggedIn = false
            profile = nil
            return
        }
        do {
            let loadedProfile = try await service.fetchMyInfo()
            guard isCurrentSession(credentials) else { return }
            profile = loadedProfile
            isLoggedIn = true
        } catch {
            guard shouldPresentError(error, for: credentials) else { return }
            if let settingsError = error as? SettingsServiceError,
               case .notLoggedIn = settingsError {
                isLoggedIn = false
                profile = nil
            }
            alert = AppAlert(title: "加载失败", message: error.localizedDescription)
        }
    }

    /// 用户操作触发一次显式登录状态检查。
    private func checkLogin() async {
        let credentials = dependencies.credentials()
        isCheckingLogin = true
        defer { isCheckingLogin = false }
        do {
            let loginState = try await service.checkLogin()
            guard dependencies.acceptsLoginCheck(loginState, for: credentials) else { return }
            isLoggedIn = loginState
            if !loginState {
                profile = nil
            }
        } catch {
            guard shouldPresentError(error, for: credentials) else { return }
            alert = AppAlert(title: "检查失败", message: error.localizedDescription)
        }
    }

    /// 服务提交昵称或签名。
    ///
    /// 接口要求整份资料一起提交，页面沿用当前资料中的未修改字段。
    private func updateProfile(nickname: String?, motto: String?) async {
        guard let profile else { return }
        let credentials = dependencies.credentials()
        guard !credentials.cookie.isEmpty else {
            isLoggedIn = false
            self.profile = nil
            return
        }
        do {
            try await profileMutation.perform {
                try await service.updateUser(
                    nickname: nickname ?? profile.user.nickname,
                    motto: motto ?? profile.user.motto,
                    avatarMid: profile.user.avatar.mid
                )
                guard isCurrentSession(credentials) else { return }
                await loadProfile(for: credentials)
                guard isCurrentSession(credentials) else { return }
                showNicknameEditor = false
                showMottoEditor = false
            }
        } catch {
            guard shouldPresentError(error, for: credentials) else { return }
            alert = AppAlert(title: "更新失败", message: error.localizedDescription)
        }
    }

    /// 服务上传并绑定新头像。
    private func updateAvatar(with item: PhotosPickerItem) async {
        guard let profile else { return }
        defer { selectedPhoto = nil }
        let credentials = dependencies.credentials()
        guard !credentials.cookie.isEmpty else {
            isLoggedIn = false
            self.profile = nil
            return
        }
        do {
            try await profileMutation.perform {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw SettingsServiceError.uploadFailed
                }
                guard isCurrentSession(credentials) else { return }
                let image = try await service.uploadAvatar(data: data, filename: "avatar.jpg")
                guard isCurrentSession(credentials) else { return }
                try await service.updateUser(
                    nickname: profile.user.nickname,
                    motto: profile.user.motto,
                    avatarMid: image.mid
                )
                guard isCurrentSession(credentials) else { return }
                await loadProfile(for: credentials)
            }
        } catch {
            guard shouldPresentError(error, for: credentials) else { return }
            alert = AppAlert(title: "头像更新失败", message: error.localizedDescription)
        }
    }

    /// 页面在当前账号且请求未取消时展示请求错误。
    private func shouldPresentError(_ error: Error, for credentials: CommunityCredentials) -> Bool {
        !TaskCancellation.matches(error) && isCurrentSession(credentials)
    }

    private func isCurrentSession(_ credentials: CommunityCredentials) -> Bool {
        let current = dependencies.credentials()
        return current.identity == credentials.identity && !current.cookie.isEmpty
    }
}

/// 设置页按需显示学号、UID 等敏感标识。
///
/// 页面默认模糊账号标识，用户点击后显示完整值；公共场合查看设置时，账号标识保持模糊状态。
private struct SettingsSensitiveValueRow: View {
    let title: String
    let value: String
    @Binding var isRevealed: Bool

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            HStack(spacing: AppDesignSystem.Spacing.regular) {
                Text(title)
                Spacer()
                if isRevealed {
                    Text(value)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                } else {
                    Text(value)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                        .blur(radius: AppDesignSystem.Size.Effect.blurRadius)
                        .padding(.horizontal, AppDesignSystem.Spacing.tiny)
                        .padding(.vertical, AppDesignSystem.Spacing.micro)
                        .background(.ultraThinMaterial, in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.small))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isRevealed ? value : "已隐藏")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isRevealed ? "轻点隐藏\(title)" : "轻点显示\(title)")
        .appInteractiveListRow()
            .accessibilityIdentifier("ui.settings-sensitive-value-row.reveal")
    }
}
