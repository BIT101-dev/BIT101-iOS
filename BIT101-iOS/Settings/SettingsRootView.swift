import CommunityCore
import CommunityUI
import ScheduleFeature
import MediaKit
import TransportCore
import DesignSystemKit
//
//  SettingsRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import PhotosUI
import SwiftUI
import UIKit

let mitLicenseText = "MIT License Copyright (c) 2026 BIT101 Contributors Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."

/// 此枚举定义设置中心的一级菜单。
///
/// 设置首页卡片和其它页面的设置深链共用此枚举。
enum SettingsRoute: String, CaseIterable, Identifiable {
    case account
    case calendar
    case ddl
    case gallery
    case suggestion
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "账号设置"
        case .calendar: return "课程表设置"
        case .ddl: return "DDL设置"
        case .gallery: return "话廊设置"
        case .suggestion: return "向开发者提建议"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .calendar: return "calendar.badge.clock"
        case .ddl: return "list.bullet.clipboard"
        case .gallery: return "bubble.left.and.bubble.right"
        case .suggestion: return "lightbulb"
        case .about: return "info.circle"
        }
    }
}

/// 设置页面消费同一组装入口选择的媒体、账号与清理能力。
struct SettingsDependencies {
    let settings: AppSettingsStore
    let schedule: ScheduleViewModel
    let scheduleCloudSync: ScheduleCloudSyncPresentation
    let suggestion: DeveloperSuggestionDependencies
    let media: MediaEnvironment
    let localData: AppLocalDataService
    let updates: AppUpdatePromptCoordinator
    let prompts: AppPromptCoordinator
    let account: SettingsAccountDependencies
    let networkDiagnosis: NetworkDiagnosisDependencies
}

/// 此视图展示设置中心的一级入口。
///
/// “我的”页设置入口进入此视图。
struct SettingsRootView: View {
    let initialRoute: SettingsRoute?
    let studentID: String
    let onLogout: () -> Void
    let dependencies: SettingsDependencies
    var showsCloseButton = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let initialRoute {
                SettingsRoutePage(route: initialRoute, studentID: studentID, onLogout: onLogout, dependencies: dependencies)
            } else {
                SettingsIndexPage(studentID: studentID, onLogout: onLogout, dependencies: dependencies)
            }
        }
        .environmentObject(dependencies.settings)
        .environmentObject(dependencies.schedule)
        .environment(dependencies.media)
        .navigationTitle(initialRoute?.title ?? "设置")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { SettingsStorageNotice(settings: dependencies.settings) }
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                        .accessibilityIdentifier("ui.settings-root-view.cancel")
                }
            }
        }
    }
}

private struct SettingsStorageNotice: View {
    @ObservedObject var settings: AppSettingsStore
    @State private var showsRecoveryConfirmation = false
    var body: some View {
        if let issue = settings.storageIssue {
            VStack(spacing: AppDesignSystem.Spacing.regular) {
                Text(issue)
                    .font(AppDesignSystem.Typography.caption)
                    .foregroundStyle(AppDesignSystem.Palette.Status.danger)
                Button("恢复账号设置", role: .destructive) { showsRecoveryConfirmation = true }
                    .accessibilityIdentifier("settings.storage.recover")
            }
            .padding(AppDesignSystem.Spacing.regular)
            .frame(maxWidth: .infinity)
            .background(AppDesignSystem.Palette.Background.grouped)
            .alert("恢复当前账号的设置？", isPresented: $showsRecoveryConfirmation) {
                Button("恢复账号设置", role: .destructive) { settings.restoreAccountPreferences() }
                    .accessibilityIdentifier("settings.storage.confirm-recovery")
                Button("取消", role: .cancel) {}
            } message: {
                Text("话廊偏好与账号内的提示设置恢复为默认值。日程、成绩、登录状态与设备偏好继续保留。")
            }
        }
    }
}

/// 此页面列出全部设置一级菜单。
///
/// 此页面使用卡片式入口，与“我的”页保持风格区分。
private struct SettingsIndexPage: View {
    let studentID: String
    let onLogout: () -> Void
    let dependencies: SettingsDependencies
    @State private var isShowingSuggestion = false

    var body: some View {
        ScrollView {
            VStack(spacing: AppDesignSystem.Spacing.regular) {
                ForEach(SettingsRoute.allCases) { route in
                    if route == .suggestion {
                        Button {
                            isShowingSuggestion = true
                        } label: {
                            SettingsIndexCard(route: route)
                        }
                        .buttonStyle(.plain)
                            .accessibilityIdentifier("ui.settings-index-page.suggestion")
                    } else {
                        NavigationLink {
                            SettingsRoutePage(route: route, studentID: studentID, onLogout: onLogout, dependencies: dependencies)
                        } label: {
                            SettingsIndexCard(route: route)
                        }
                        .buttonStyle(.plain)
                            .accessibilityIdentifier("ui.settings-index-page.destination")
                    }
                }
            }
            .padding(AppDesignSystem.Spacing.section)
        }
        .accessibilityIdentifier("interaction.SettingsIndexPage.scroll")
        .background(AppDesignSystem.Palette.Background.grouped)
        .sheet(isPresented: $isShowingSuggestion) {
            NavigationStack {
                DeveloperSuggestionPage(dependencies: dependencies.suggestion)
            }
        }
    }
}

/// 此视图展示设置首页卡片。
private struct SettingsIndexCard: View {
    let route: SettingsRoute

    var body: some View {
        AppCard {
            AppNavigationRowLabel(title: route.title, systemImage: route.systemImage)
        }
    }
}

/// 此视图根据 `route` 展示对应的设置页面。
///
/// 其它模块通过 `route` 进入对应的设置页面。
private struct SettingsRoutePage: View {
    @EnvironmentObject private var scheduleViewModel: ScheduleViewModel
    let route: SettingsRoute
    let studentID: String
    let onLogout: () -> Void
    let dependencies: SettingsDependencies

    var body: some View {
        switch route {
        case .account:
            AccountSettingsPage(dependencies: dependencies.account, studentID: studentID, onLogout: onLogout)
        case .calendar:
            AppCalendarSettingsPage(viewModel: scheduleViewModel, scheduleCloudSync: dependencies.scheduleCloudSync)
        case .ddl:
            DDLSettingsPage(viewModel: scheduleViewModel.ddl)
        case .gallery:
            GallerySettingsPage(media: dependencies.media, diagnosis: dependencies.networkDiagnosis)
        case .suggestion:
            DeveloperSuggestionPage(dependencies: dependencies.suggestion)
        case .about:
            AboutSettingsPage(onLogout: onLogout, localData: dependencies.localData,
                updates: dependencies.updates, prompts: dependencies.prompts)
        }
    }
}

nonisolated struct DeveloperSuggestionAttachment: Codable, Equatable, Sendable {
    let filename: String
    let contentType: String
    let data: String
}

nonisolated struct DeveloperSuggestionPayload: FeedbackSubmissionPayload, Codable {
    var requestID = UUID()
    var mode = "suggestion"
    var isDevelopmentBuild = AppBuildEnvironment.isDevelopment
    let comment: String
    var errorTitle = "开发者建议"
    var errorMessage = "用户主动提交的功能建议。"
    let contact: String?
    let appVersion: String
    let build: String
    let systemVersion: String
    let deviceModel: String
    let networkStatus: String
    var diagnostics: [NetworkDiagnosticRecord] = []
    let submittedAt: Date
    let context: FeedbackDeviceContext
    var diagnosticSummary = FeedbackDiagnosticSummary.empty
    var attachments: [DeveloperSuggestionAttachment]

    func hasSameContent(as other: Self) -> Bool {
        comment == other.comment && contact == other.contact && attachments == other.attachments
    }

    func draftMetadata(matching draft: DeveloperSuggestionDraftSnapshot) throws -> Data? {
        guard comment == draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
              (contact ?? "") == draft.contact.trimmingCharacters(in: .whitespacesAndNewlines),
              attachments == Self.attachments(from: draft) else { return nil }
        var metadata = self
        metadata.attachments = attachments.map { .init(filename: $0.filename, contentType: $0.contentType, data: "") }
        return try JSONEncoder().encode(metadata)
    }

    static func restored(from draft: DeveloperSuggestionDraftSnapshot) throws -> Self? {
        guard let metadata = draft.pendingSubmissionMetadata else { return nil }
        var payload = try JSONDecoder().decode(Self.self, from: metadata)
        let images = attachments(from: draft)
        guard payload.comment == draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
              (payload.contact ?? "") == draft.contact.trimmingCharacters(in: .whitespacesAndNewlines),
              payload.attachments.count == images.count,
              zip(payload.attachments, images).allSatisfy({
                  $0.filename == $1.filename && $0.contentType == $1.contentType && $0.data.isEmpty
              }) else { throw CocoaError(.fileReadCorruptFile) }
        payload.attachments = images
        return payload
    }

    private static func attachments(from draft: DeveloperSuggestionDraftSnapshot) -> [DeveloperSuggestionAttachment] {
        draft.images.map { .init(filename: $0.filename, contentType: "image/jpeg",
            data: ($0.uploadData ?? $0.previewData).base64EncodedString()) }
    }
}

private enum DeveloperSuggestionConfirmation: String, Identifiable {
    case saveDraft
    case restoreDraft
    case missingContact
    case rebuildSubmission

    var id: String { rawValue }
}

/// 建议提交与所属草稿清理通过注入端口组装。
struct DeveloperSuggestionDependencies {
    let drafts: any DeveloperSuggestionDraftStoring
    private let send: (DeveloperSuggestionPayload) async throws -> Void
    private let captureSubmissionOwner: () -> () -> Bool

    init(drafts: any DeveloperSuggestionDraftStoring, submit: @escaping (DeveloperSuggestionPayload) async throws -> Void,
         captureSubmissionOwner: @escaping () -> () -> Bool = { { true } }) {
        self.drafts = drafts
        self.send = submit
        self.captureSubmissionOwner = captureSubmissionOwner
    }

    @discardableResult
    func submitAndClear(_ payload: DeveloperSuggestionPayload, persisting draft: DeveloperSuggestionDraftSnapshot? = nil) async throws -> Task<Bool, Never> {
        let ownerIsCurrent = captureSubmissionOwner()
        let persisted: Bool
        if let draft {
            persisted = await drafts.saveSuggestion(draft)
        } else { persisted = true }
        guard ownerIsCurrent() else { throw CancellationError() }
        let cleanup = persisted ? await drafts.captureSuggestionCleanup() : nil
        guard ownerIsCurrent() else { throw CancellationError() }
        try await send(payload)
        return Task {
            guard let cleanup else { return false }
            return await cleanup()
        }
    }
}

struct DeveloperSuggestionPage: View {
    @Environment(MediaEnvironment.self) private var media
    let dependencies: DeveloperSuggestionDependencies
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var contact = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var imageDrafts: [ComposerImageDraft] = []
    @State private var isLoadingImages = false
    @State private var imageTask: Task<Void, Never>?
    @State private var imagePreparer = ComposerImagePreparer()
    @State private var isSubmitting = false
    @State private var isUpdatingDraft = false
    @State private var alert: AppAlert?
    @State private var confirmation: DeveloperSuggestionConfirmation?
    @FocusState private var isContactFocused: Bool
    @State private var didCheckDraft = false
    @State private var submissionAttempt = FeedbackSubmissionAttempt<DeveloperSuggestionPayload>()
    @State private var submissionRecoveryFailed = false

    private var isBusy: Bool { isSubmitting || isUpdatingDraft }

    var body: some View {
        Form {
            if submissionRecoveryFailed {
                Section {
                    Text("已恢复的文字与图片已保留。请核对内容，并确认作为新建议继续编辑。")
                    Button("使用恢复内容继续编辑") { confirmation = .rebuildSubmission }
                        .appInteractiveListRow()
                        .accessibilityIdentifier("suggestion.recovery.continue")
                }
            }
            Section("建议内容") {
                TextField(
                    "",
                    text: $text,
                    prompt: AppInputPrompt.text("请输入你想告诉开发者的内容"),
                    axis: .vertical
                )
                .lineLimit(12, reservesSpace: true)
                .frame(minHeight: AppDesignSystem.Size.Editor.multilineMinimumHeight)
                .accessibilityLabel("建议内容")
                .accessibilityHint("输入想告诉开发者的内容")
            }

            Section("联系方式（可选）") {
                TextField("", text: $contact, prompt: AppInputPrompt.text("微信、QQ 或邮箱"), axis: .vertical)
                    .lineLimit(1 ... 3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isContactFocused)
                    .accessibilityLabel("联系方式")
                    .accessibilityHint("可填写微信、QQ、邮箱或其他联系方式")
                    .accessibilityIdentifier("ui.developer-suggestion-page.联系方式")
            }

            Section("图片（可选）") {
                PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 6, matching: .images) {
                    Text("插入图片")
                }
                .disabled(isSubmitting || isLoadingImages || imageDrafts.count >= 6)
                .appInteractiveListRow()
                    .accessibilityIdentifier("ui.developer-suggestion-page.插入图片")

                if !imageDrafts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppDesignSystem.Spacing.regular) {
                            ForEach(imageDrafts) { draft in
                                ComposerImageTile(
                                    draft: draft,
                                    onRetry: { retryImageDraft(id: draft.id) },
                                    onRemove: { removeImageDraft(id: draft.id) },
                                    showsPreparedSuccessIndicator: false
                                )
                            }
                        }
                        .padding(.vertical, AppDesignSystem.Spacing.tiny)
                    }
                    .accessibilityIdentifier("interaction.DeveloperSuggestionPage.scroll")
                }
            }
        }
        .disabled(isBusy)
        .interactiveDismissDisabled(hasDraftContent || isBusy || isLoadingImages)
        .appGroupedListStyle()
        .navigationTitle("向开发者提建议")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppComposerToolbar(
                isSubmitting: isBusy,
                submitTitle: "提交",
                submittingTitle: isUpdatingDraft ? "处理中" : "提交中",
                isSubmitDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onCancel: {
                    requestDismiss()
                },
                onSubmit: {
                    requestSubmission()
                }
            )
        }
        .onChange(of: selectedPhotoItems) { _, newValue in
            guard !isBusy, !newValue.isEmpty else { return }
            startImageTask { await addImages(from: newValue) }
        }
        .onDisappear { imageTask?.cancel() }
        .task { await checkDraftOnAppear() }
        .alert(item: $confirmation) { item in
            switch item {
            case .rebuildSubmission:
                Alert(
                    title: Text("将恢复内容作为新建议？"),
                    message: Text("上一份建议可能已经送达。确认后保留当前文字和图片，后续提交将建立另一份建议。"),
                    primaryButton: .default(Text("继续编辑"), action: {
                        submissionAttempt.restore(nil)
                        submissionRecoveryFailed = false
                    }),
                    secondaryButton: .cancel(Text("返回核对"))
                )
            case .saveDraft:
                Alert(
                    title: Text("保存草稿？"),
                    message: Text("保存后下次打开时可以加载草稿。"),
                    primaryButton: .default(Text("保存草稿"), action: {
                        Task {
                            if await saveDraft() {
                                dismiss()
                            } else {
                                alert = AppAlert.informational(
                                    title: "草稿暂存遇到问题",
                                    message: "当前页面内容已保留，请稍后重试保存。"
                                )
                            }
                        }
                    }),
                    secondaryButton: .cancel(Text("不保存"), action: {
                        Task {
                            if await discardDraft() { dismiss() }
                        }
                    })
                )
            case .restoreDraft:
                Alert(
                    title: Text("加载草稿？"),
                    message: Text("发现上次保存的建议草稿。"),
                    primaryButton: .default(Text("加载草稿"), action: {
                        startImageTask { await loadSavedDraft() }
                    }),
                    secondaryButton: .cancel(Text("不加载"), action: {
                        Task { _ = await discardDraft() }
                    })
                )
            case .missingContact:
                Alert(
                    title: Text("你没有填写联系方式"),
                    message: Text("开发者非常希望与你沟通，向你反馈。"),
                    primaryButton: .default(Text("继续提交"), action: {
                        Task { await submit() }
                    }),
                    secondaryButton: .cancel(Text("返回补充"), action: {
                        isContactFocused = true
                    })
                )
            }
        }
        .diagnosticAlert(item: $alert)
    }

    private func requestSubmission() {
        guard !isBusy else { return }
        if submissionRecoveryFailed { confirmation = .rebuildSubmission; return }
        if contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            confirmation = .missingContact
        } else {
            Task { await submit() }
        }
    }

    @MainActor
    private func submit() async {
        guard !isBusy else { return }
        let suggestion = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suggestion.isEmpty else { return }
        guard !submissionRecoveryFailed else {
            confirmation = .rebuildSubmission
            return
        }
        guard !hasProcessingImages else {
            alert = AppAlert.userInput(title: "提交失败", message: "图片仍在处理中，请稍候。")
            return
        }
        guard imageDrafts.allSatisfy({
            if case .prepared = $0.status { return true }
            return false
        }) else {
            alert = AppAlert.userInput(title: "提交失败", message: "有图片未处理完成，请删除后重新选择。")
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let context = FeedbackDeviceContext.current
            let payload = submissionAttempt.prepare(
                DeveloperSuggestionPayload(
                    comment: suggestion,
                    contact: contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : contact.trimmingCharacters(in: .whitespacesAndNewlines),
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                    systemVersion: UIDevice.current.systemVersion,
                    deviceModel: UIDevice.current.model,
                    networkStatus: context.networkStatus,
                    submittedAt: Date(),
                    context: context,
                    attachments: imageDrafts.map {
                        DeveloperSuggestionAttachment(
                            filename: $0.filename,
                            contentType: "image/jpeg",
                            data: ($0.uploadData ?? $0.previewData).base64EncodedString()
                        )
                    }
                )
            )
            try await dependencies.submitAndClear(payload, persisting: draftSnapshot())
            submissionAttempt.finish(payload)
            text = ""
            contact = ""
            alert = nil
            dismiss()
        } catch {
            alert = AppAlert(title: "提交失败", message: error.localizedDescription)
        }
    }

    private func requestDismiss() {
        guard !isBusy else { return }
        guard hasDraftContent else {
            dismiss()
            return
        }
        confirmation = .saveDraft
    }

    private func discardDraft() async -> Bool {
        guard !isBusy else { return false }
        isUpdatingDraft = true
        defer { isUpdatingDraft = false }
        let removed = await dependencies.drafts.removeSuggestion()
        if removed { submissionAttempt.restore(nil); submissionRecoveryFailed = false }
        if !removed {
            alert = AppAlert.informational(title: "草稿清理遇到问题", message: "当前页面内容已保留，请稍后重试清理。")
        }
        return removed
    }

    private func saveDraft() async -> Bool {
        guard !isBusy, !submissionRecoveryFailed else { return false }
        isUpdatingDraft = true
        defer { isUpdatingDraft = false }
        await imageTask?.value
        guard !Task.isCancelled, !submissionRecoveryFailed else { return false }
        do { return await dependencies.drafts.saveSuggestion(try draftSnapshot()) }
        catch { return false }
    }

    private func draftSnapshot() throws -> DeveloperSuggestionDraftSnapshot {
        let images = imageDrafts.map { ComposerImageDraftSnapshot(filename: $0.filename,
            previewData: $0.previewData, uploadData: $0.uploadData) }
        let draft = DeveloperSuggestionDraftSnapshot(text: text, images: images, contact: contact)
        return DeveloperSuggestionDraftSnapshot(text: text, images: images, contact: contact,
            pendingSubmissionMetadata: try submissionAttempt.pending?.draftMetadata(matching: draft))
    }

    private func checkDraftOnAppear() async {
        guard !didCheckDraft else { return }
        let result = await dependencies.drafts.loadSuggestion()
        guard !Task.isCancelled else { return }
        didCheckDraft = true
        if result.snapshot != nil { confirmation = .restoreDraft }
        else if let message = result.recoveryMessage {
            alert = AppAlert.informational(title: "建议草稿恢复需要处理", message: message)
        }
    }

    private func loadSavedDraft() async {
        let result = await dependencies.drafts.loadSuggestion()
        guard !Task.isCancelled else { return }
        guard let draft = result.snapshot else {
            if let message = result.recoveryMessage {
                alert = AppAlert.informational(title: "建议草稿恢复需要处理", message: message)
            }
            return
        }

        text = draft.text
        contact = draft.contact
        do {
            submissionAttempt.restore(try DeveloperSuggestionPayload.restored(from: draft))
            submissionRecoveryFailed = false
            if let message = result.recoveryMessage {
                alert = AppAlert.informational(title: "建议内容已部分恢复", message: message)
            }
        } catch {
            submissionRecoveryFailed = true
            alert = AppAlert.informational(title: "建议内容已部分恢复", message: "文字与可用图片已保留。请核对内容，并选择使用恢复内容继续编辑。")
        }
        imageDrafts = draft.images.map {
            ComposerImageDraft(
                previewData: $0.previewData,
                filename: $0.filename,
                uploadData: $0.uploadData,
                progress: $0.uploadData == nil ? 0 : 100,
                status: $0.uploadData == nil ? .compressing : .prepared
            )
        }
        if imageDrafts.contains(where: { $0.status.isCompressing }) {
            await compressRestoredImages()
        }
    }

    private func compressRestoredImages() async {
        let drafts = imageDrafts.filter { $0.status.isCompressing }
        guard !drafts.isEmpty else { return }

        let results = await compressImageDrafts(drafts)
        guard !Task.isCancelled else { return }
        applyCompressionResults(results, showsFailureAlert: false)
    }

    private func compressImageDrafts(
        _ drafts: [ComposerImageDraft]
    ) async -> [(ComposerImageDraft.ID, Data?)] {
        var results: [(ComposerImageDraft.ID, Data?)] = []
        var completedCount = 0
        for draft in drafts {
            let data = try? await imagePreparer.prepare(draft.previewData)
            guard !Task.isCancelled else { return results }
            results.append((draft.id, data))
            completedCount += 1
            let progress = Int((Double(completedCount) / Double(drafts.count) * 100).rounded())
            imageDrafts = imageDrafts.map { draft in
                guard draft.status.isCompressing else { return draft }
                var updated = draft
                updated.progress = progress
                return updated
            }
        }
        return results
    }

    private func applyCompressionResults(
        _ results: [(ComposerImageDraft.ID, Data?)],
        showsFailureAlert: Bool
    ) {
        var failed = false
        imageDrafts = imageDrafts.map { draft in
            guard let result = results.first(where: { $0.0 == draft.id }) else { return draft }
            guard let data = result.1 else {
                failed = true
                var failedDraft = draft
                failedDraft.status = .failed("图片无法处理")
                return failedDraft
            }
            var preparedDraft = draft
            preparedDraft.previewData = data
            preparedDraft.uploadData = data
            preparedDraft.status = .prepared
            return preparedDraft
        }

        if showsFailureAlert && failed {
            alert = AppAlert.userInput(title: "图片添加失败", message: "部分图片无法处理，请删除后重新选择。")
        }
    }

    private var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !imageDrafts.isEmpty
    }

    private var hasProcessingImages: Bool {
        isLoadingImages || imageDrafts.contains { $0.status.isCompressing }
    }

    private func startImageTask(_ operation: @escaping @MainActor () async -> Void) {
        guard !isLoadingImages, !isSubmitting else { return }
        isLoadingImages = true
        imageTask = Task { @MainActor in
            defer { isLoadingImages = false; imageTask = nil }
            await operation()
        }
    }

    private func addImages(from items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }
        let remaining = max(0, 6 - imageDrafts.count)
        let selectedItems = Array(items.prefix(remaining))
        guard !selectedItems.isEmpty else { return }

        for item in selectedItems {
            guard !Task.isCancelled, imageDrafts.count < 6 else { return }
            do {
                guard let source = try await media.loadBoundedImageData(from: item) else { throw SettingsServiceError.uploadFailed }
                let data = try await imagePreparer.prepare(source)
                guard !Task.isCancelled else { return }
                imageDrafts.append(ComposerImageDraft(previewData: data, filename: "suggestion-\(UUID().uuidString).jpg",
                    uploadData: data, status: .prepared))
            } catch {
                guard !TaskCancellation.matches(error) else { return }
                alert = AppAlert.userInput(title: "图片添加失败", message: error.localizedDescription)
            }
        }
    }

    private func removeImageDraft(id: ComposerImageDraft.ID) {
        guard !isBusy else { return }
        imageDrafts.removeAll { $0.id == id }
    }

    private func retryImageDraft(id: ComposerImageDraft.ID) {
        guard !isSubmitting, !isLoadingImages,
              let draft = imageDrafts.first(where: { $0.id == id }),
              case .failed = draft.status else { return }

        var retryingDraft = draft
        retryingDraft.progress = 0
        retryingDraft.uploadData = nil
        retryingDraft.status = .compressing
        imageDrafts = imageDrafts.map { $0.id == id ? retryingDraft : $0 }

        startImageTask {
            let results = await compressImageDrafts([retryingDraft])
            guard !Task.isCancelled else { return }
            applyCompressionResults(results, showsFailureAlert: true)
        }
    }
}

private extension ComposerImageDraft.Status {
    var isCompressing: Bool {
        if case .compressing = self { return true }
        return false
    }
}
