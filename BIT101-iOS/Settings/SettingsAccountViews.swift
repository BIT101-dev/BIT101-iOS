//
//  SettingsAccountViews.swift
//  BIT101-iOS
//
//  Split from SettingsRootView.swift.
//

import PhotosUI
import SwiftUI

struct AccountSettingsPage: View {
    let studentID: String
    let onLogout: () -> Void

    @State private var profile: MineUserInfo?
    @State private var isCheckingLogin = false
    @State private var isLoggedIn = !LoginStorage.shared.fakeCookie.isEmpty
    @State private var isUpdating = false
    @State private var showNicknameEditor = false
    @State private var showMottoEditor = false
    @State private var nicknameText = ""
    @State private var mottoText = ""
    @State private var isShowingStudentID = false
    @State private var isShowingUID = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var alert: AppAlert?

    private let service = SettingsNetworkService()

    var body: some View {
        List {
            if let profile {
                Section("个人信息") {
                    HStack(spacing: AppDesignSystem.Spacing.control) {
                        Text("头像")
                        Spacer()
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            AppAvatarView(
                                imageURL: URL(string: profile.user.avatar.url),
                                size: AppDesignSystem.Size.avatar.account,
                                tint: AppDesignSystem.Palette.info
                            )
                        }
                        .disabled(isUpdating)
                    }

                    Button {
                        nicknameText = profile.user.nickname
                        showNicknameEditor = true
                    } label: {
                        LabeledContent("昵称", value: profile.user.nickname)
                    }
                    .disabled(isUpdating)

                    Button {
                        mottoText = profile.user.motto
                        showMottoEditor = true
                    } label: {
                        LabeledContent("个性签名", value: profile.user.motto.isEmpty ? "空" : profile.user.motto)
                    }
                    .disabled(isUpdating)

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
                    HStack(spacing: AppDesignSystem.Spacing.control) {
                        Text("登录状态检查")
                        Spacer()
                        if isCheckingLogin {
                            ProgressView()
                        } else {
                            Text(isLoggedIn ? "已登录" : "未登录")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isCheckingLogin)

                Button("退出登录", role: .destructive, action: onLogout)
            }
        }
        .appGroupedListStyle()
        .task {
            guard !LoginStorage.shared.fakeCookie.isEmpty else {
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
                onSubmit: {
                    Task { await updateProfile(nickname: nil, motto: mottoText) }
                }
            )
        }
        .diagnosticAlert(item: $alert)
    }

    /// 页面加载当前登录用户资料卡。
    private func loadProfile(for expectedSessionCookie: String? = nil) async {
        let sessionCookie = expectedSessionCookie ?? LoginStorage.shared.fakeCookie
        guard !sessionCookie.isEmpty else {
            isLoggedIn = false
            return
        }
        do {
            let loadedProfile = try await service.fetchMyInfo()
            guard isCurrentSession(sessionCookie) else { return }
            profile = loadedProfile
            isLoggedIn = true
        } catch {
            guard shouldPresentError(error, for: sessionCookie) else { return }
            alert = AppAlert(title: "加载失败", message: error.localizedDescription)
        }
    }

    /// 用户操作触发一次显式登录状态检查。
    private func checkLogin() async {
        let sessionCookie = LoginStorage.shared.fakeCookie
        isCheckingLogin = true
        defer { isCheckingLogin = false }
        do {
            let loginState = try await service.checkLogin()
            guard isCurrentSession(sessionCookie)
                || (!loginState && LoginStorage.shared.fakeCookie.isEmpty)
            else { return }
            isLoggedIn = loginState
        } catch {
            guard shouldPresentError(error, for: sessionCookie) else { return }
            alert = AppAlert(title: "检查失败", message: error.localizedDescription)
        }
    }

    /// 服务提交昵称或签名。
    ///
    /// 接口要求整份资料一起提交，页面沿用当前资料中的未修改字段。
    private func updateProfile(nickname: String?, motto: String?) async {
        guard let profile else { return }
        let sessionCookie = LoginStorage.shared.fakeCookie
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await service.updateUser(
                nickname: nickname ?? profile.user.nickname,
                motto: motto ?? profile.user.motto,
                avatarMid: profile.user.avatar.mid
            )
            guard isCurrentSession(sessionCookie) else { return }
            await loadProfile(for: sessionCookie)
            guard isCurrentSession(sessionCookie) else { return }
            showNicknameEditor = false
            showMottoEditor = false
        } catch {
            guard shouldPresentError(error, for: sessionCookie) else { return }
            alert = AppAlert(title: "更新失败", message: error.localizedDescription)
        }
    }

    /// 服务上传并绑定新头像。
    private func updateAvatar(with item: PhotosPickerItem) async {
        guard let profile else { return }
        defer { selectedPhoto = nil }
        let sessionCookie = LoginStorage.shared.fakeCookie
        isUpdating = true
        defer { isUpdating = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw SettingsServiceError.uploadFailed
            }
            guard isCurrentSession(sessionCookie) else { return }
            let image = try await service.uploadAvatar(data: data)
            guard isCurrentSession(sessionCookie) else { return }
            try await service.updateUser(
                nickname: profile.user.nickname,
                motto: profile.user.motto,
                avatarMid: image.mid
            )
            guard isCurrentSession(sessionCookie) else { return }
            await loadProfile(for: sessionCookie)
        } catch {
            guard shouldPresentError(error, for: sessionCookie) else { return }
            alert = AppAlert(title: "头像更新失败", message: error.localizedDescription)
        }
    }

    /// 页面在当前账号且请求未取消时展示请求错误。
    private func shouldPresentError(_ error: Error, for sessionCookie: String) -> Bool {
        !TaskCancellation.matches(error) && isCurrentSession(sessionCookie)
    }

    private func isCurrentSession(_ sessionCookie: String) -> Bool {
        !sessionCookie.isEmpty && LoginStorage.shared.fakeCookie == sessionCookie
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
            HStack(spacing: AppDesignSystem.Spacing.control) {
                Text(title)
                Spacer()
                if isRevealed {
                    Text(value)
                        .foregroundStyle(.secondary)
                } else {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .blur(radius: 7)
                        .padding(.horizontal, AppDesignSystem.Spacing.tight)
                        .padding(.vertical, AppDesignSystem.Spacing.micro)
                        .background(.ultraThinMaterial, in: AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.small))
                }
            }
        }
        .buttonStyle(.plain)
    }
}
