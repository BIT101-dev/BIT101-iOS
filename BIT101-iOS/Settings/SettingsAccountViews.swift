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
    @State private var isLoggedIn = true
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
                    HStack {
                        Text("头像")
                        Spacer()
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            CachedRemoteImage(url: URL(string: profile.user.avatar.url)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(Color.blue.opacity(0.15))
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
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
                    HStack {
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
        .task {
            guard !LoginStorage.shared.fakeCookie.isEmpty else { return }
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

    /// 拉取当前登录用户资料卡。
    private func loadProfile() async {
        let sessionCookie = LoginStorage.shared.fakeCookie
        do {
            profile = try await service.fetchMyInfo()
            isLoggedIn = true
        } catch {
            guard !shouldIgnore(error: error, sessionCookie: sessionCookie) else { return }
            alert = AppAlert(title: "加载失败", message: error.localizedDescription)
        }
    }

    /// 触发一次显式登录状态检查。
    private func checkLogin() async {
        let sessionCookie = LoginStorage.shared.fakeCookie
        isCheckingLogin = true
        defer { isCheckingLogin = false }
        do {
            isLoggedIn = try await service.checkLogin()
        } catch {
            guard !shouldIgnore(error: error, sessionCookie: sessionCookie) else { return }
            alert = AppAlert(title: "检查失败", message: error.localizedDescription)
        }
    }

    /// 更新昵称或签名。
    ///
    /// 接口要求整份资料一起提交，所以未改动字段也要回填旧值。
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
            await loadProfile()
            showNicknameEditor = false
            showMottoEditor = false
        } catch {
            guard !shouldIgnore(error: error, sessionCookie: sessionCookie) else { return }
            alert = AppAlert(title: "更新失败", message: error.localizedDescription)
        }
    }

    /// 上传并绑定新头像。
    private func updateAvatar(with item: PhotosPickerItem) async {
        guard let profile else { return }
        let sessionCookie = LoginStorage.shared.fakeCookie
        isUpdating = true
        defer { isUpdating = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw SettingsServiceError.uploadFailed
            }
            let image = try await service.uploadAvatar(data: data)
            try await service.updateUser(
                nickname: profile.user.nickname,
                motto: profile.user.motto,
                avatarMid: image.mid
            )
            await loadProfile()
        } catch {
            guard !shouldIgnore(error: error, sessionCookie: sessionCookie) else { return }
            alert = AppAlert(title: "头像更新失败", message: error.localizedDescription)
        }
    }

    /// 退出或切换账号后，旧请求的失败不能再回写到新账号界面。
    private func shouldIgnore(error: Error, sessionCookie: String) -> Bool {
        TaskCancellation.matches(error)
            || sessionCookie.isEmpty
            || LoginStorage.shared.fakeCookie != sessionCookie
    }
}

/// 设置页里用于按需显示学号、UID 这类敏感标识。
///
/// 默认做轻度模糊，点击后再完全展开，避免在公共场合一眼暴露账号信息。
private struct SettingsSensitiveValueRow: View {
    let title: String
    let value: String
    @Binding var isRevealed: Bool

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                Spacer()
                if isRevealed {
                    Text(value)
                        .foregroundStyle(.secondary)
                } else {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .blur(radius: 7)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 页面设置页。
///
/// 负责底部 tab 的显示顺序、默认页和可见性配置。
