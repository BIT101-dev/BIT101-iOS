import MineFeature
import CommunityUI
import TransportCore
import MediaKit
import CommunityCore
import CommunityTransport
import DesignSystemKit
//
//  SettingsAccountViews.swift
//  BIT101-iOS
//
//

import PhotosUI
import SwiftUI

struct AccountSettingsPage: View {
    @Environment(MediaEnvironment.self) private var media
    let dependencies: SettingsAccountDependencies
    let studentID: String
    let onLogout: () -> Void

    @StateObject private var model: AccountSettingsModel
    private var profile: MineUserInfo? { model.profile }
    private var isCheckingLogin: Bool { model.isCheckingLogin }
    private var isLoggedIn: Bool { model.isLoggedIn }
    @StateObject private var profileMutation: AccountProfileMutation
    private var isBusy: Bool { profileMutation.isBusy }
    @State private var showNicknameEditor = false
    @State private var showMottoEditor = false
    @State private var nicknameText = ""
    @State private var mottoText = ""
    @State private var isShowingStudentID = false
    @State private var isShowingUID = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imagePreparer = ComposerImagePreparer()
    @State private var isShowingPhotoPicker = false

    init(dependencies: SettingsAccountDependencies, studentID: String, onLogout: @escaping () -> Void) {
        self.dependencies = dependencies
        self.studentID = studentID
        self.onLogout = onLogout
        _model = StateObject(wrappedValue: AccountSettingsModel(dependencies: dependencies))
        _profileMutation = StateObject(wrappedValue: dependencies.profileMutation)
    }

    var body: some View {
        List {
            if let profile {
                Section("个人信息") {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text("头像")
                        Spacer()
                        Button {
                            isShowingPhotoPicker = true
                        } label: {
                            AppAvatarView(
                                imageURL: profile.user.avatar.thumbnailURL,
                                fallbackImageURL: profile.user.avatar.originalURL,
                                size: AppDesignSystem.Size.Avatar.standard,
                                tint: AppDesignSystem.Palette.Accent.primary
                            )
                        }
                        .accessibilityLabel("头像")
                        .accessibilityHint("选择新头像")
                        .disabled(isBusy)
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
                    .disabled(isBusy)
                    .appInteractiveListRow()

                    Button {
                        mottoText = profile.user.motto
                        showMottoEditor = true
                    } label: {
                        LabeledContent("个性签名", value: profile.user.motto.isEmpty ? "空" : profile.user.motto)
                    }
                    .disabled(isBusy)
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

            if profile == nil, model.isLoadingProfile || model.profileLoadError != nil {
                Section("个人信息") {
                    if model.isLoadingProfile {
                        AppInlineLoadingState("正在加载个人信息")
                    } else if let error = model.profileLoadError {
                        AppFailureState(title: "个人信息加载失败", systemImage: "person.crop.circle.badge.exclamationmark",
                            message: error.localizedDescription,
                            onRetry: { profileMutation.start { await model.loadProfile() } })
                    }
                }
            }

            Section("登录状态") {
                Button {
                    profileMutation.start { await model.checkLogin() }
                } label: {
                    HStack(spacing: AppDesignSystem.Spacing.regular) {
                        Text("登录状态检查")
                        Spacer()
                        if isCheckingLogin {
                            ProgressView()
                                .accessibilityLabel("正在检查登录状态")
                        } else {
                            Text(isLoggedIn ? "已登录" : "未登录")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(isBusy)
                .appInteractiveListRow()

                Button("退出登录", role: .destructive, action: onLogout)
                    .accessibilityIdentifier("settings.account.logout")
                    .disabled(isBusy)
                .appInteractiveListRow(isDestructive: true)
            }
        }
        .accessibilityIdentifier("interaction.AccountSettingsPage.list")
        .appGroupedListStyle()
        .task { await model.loadProfile() }
        .communityReadRecovery(networkPath: AppNetworkPath.state) {
            guard model.profileLoadError != nil, !profileMutation.isBusy else { return }
            await model.loadProfile()
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            if !profileMutation.start({ await updateAvatar(with: newValue) }) { selectedPhoto = nil }
        }
        .sheet(isPresented: $showNicknameEditor) {
            SettingsTextEditSheet(
                title: "修改昵称",
                text: $nicknameText,
                isSubmitting: isBusy,
                onSubmit: {
                    profileMutation.start { await updateProfile(nickname: nicknameText, motto: nil) }
                }
            )
        }
        .sheet(isPresented: $showMottoEditor) {
            SettingsTextEditSheet(
                title: "修改个性签名",
                text: $mottoText,
                axis: .vertical,
                isSubmitting: isBusy,
                onSubmit: {
                    profileMutation.start { await updateProfile(nickname: nil, motto: mottoText) }
                }
            )
        }
        .diagnosticAlert(item: $model.alert)
        .onDisappear { profileMutation.cancel() }
    }

    private func updateProfile(nickname: String?, motto: String?) async {
        if await model.updateProfile(nickname: nickname, motto: motto) {
            showNicknameEditor = false
            showMottoEditor = false
        }
    }

    private func updateAvatar(with item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        await model.updateAvatar {
            guard let data = try await media.loadBoundedImageData(from: item) else {
                throw SettingsServiceError.uploadFailed
            }
            return try await imagePreparer.prepare(data)
        }
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
                        .foregroundStyle(.tint)
                } else {
                    Text(value)
                        .foregroundStyle(.tint)
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
