import CommunityCore
import CommunityUI
import ScheduleFeature
import MediaKit
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
    let suggestion: DeveloperSuggestionDependencies
    let media: MediaEnvironment
    let localData: AppLocalDataService
    let account: SettingsAccountDependencies
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
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
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
                    } else {
                        NavigationLink {
                            SettingsRoutePage(route: route, studentID: studentID, onLogout: onLogout, dependencies: dependencies)
                        } label: {
                            SettingsIndexCard(route: route)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(AppDesignSystem.Spacing.section)
        }
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
            AppCalendarSettingsPage(viewModel: scheduleViewModel)
        case .ddl:
            DDLSettingsPage(viewModel: scheduleViewModel.ddl)
        case .gallery:
            GallerySettingsPage(media: dependencies.media)
        case .suggestion:
            DeveloperSuggestionPage(dependencies: dependencies.suggestion)
        case .about:
            AboutSettingsPage(onLogout: onLogout, localData: dependencies.localData)
        }
    }
}

struct DeveloperSuggestionAttachment: Encodable {
    let filename: String
    let contentType: String
    let data: String
}

struct DeveloperSuggestionPayload: Encodable {
    let mode = "suggestion"
    let isDevelopmentBuild = AppBuildEnvironment.isDevelopment
    let comment: String
    let errorTitle = "开发者建议"
    let errorMessage = "用户主动提交的功能建议。"
    let contact: String?
    let appVersion: String
    let build: String
    let systemVersion: String
    let deviceModel: String
    let networkStatus: String
    let diagnostics: [NetworkDiagnosticRecord] = []
    let submittedAt: Date
    let context: FeedbackDeviceContext
    let diagnosticSummary = FeedbackDiagnosticSummary.empty
    let attachments: [DeveloperSuggestionAttachment]
}

private enum DeveloperSuggestionConfirmation: String, Identifiable {
    case saveDraft
    case restoreDraft
    case missingContact

    var id: String { rawValue }
}

/// 此页面向开发者提交功能建议，并复用错误反馈 Worker 与邮件通知链路。
struct DeveloperSuggestionDependencies {
    let drafts: any DeveloperSuggestionDraftStoring
    private let send: (DeveloperSuggestionPayload) async throws -> Void

    init(drafts: any DeveloperSuggestionDraftStoring, submit: @escaping (DeveloperSuggestionPayload) async throws -> Void) {
        self.drafts = drafts
        self.send = submit
    }

    func submitAndClear(_ payload: DeveloperSuggestionPayload) async throws {
        let cleanup = await drafts.captureSuggestionCleanup()
        try await send(payload)
        await cleanup()
    }
}

struct DeveloperSuggestionPage: View {
    let dependencies: DeveloperSuggestionDependencies
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var contact = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var imageDrafts: [ComposerImageDraft] = []
    @State private var isSubmitting = false
    @State private var alert: AppAlert?
    @State private var confirmation: DeveloperSuggestionConfirmation?
    @FocusState private var isContactFocused: Bool
    @State private var didCheckDraft = false

    var body: some View {
        Form {
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
            }

            Section("图片（可选）") {
                PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 6, matching: .images) {
                    Text("插入图片")
                }
                .disabled(isSubmitting || imageDrafts.count >= 6)
                .appInteractiveListRow()

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
                }
            }
        }
        .appGroupedListStyle()
        .navigationTitle("向开发者提建议")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppComposerToolbar(
                isSubmitting: isSubmitting,
                submitTitle: "提交",
                submittingTitle: "提交中",
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
            guard !newValue.isEmpty else { return }
            Task { await addImages(from: newValue) }
        }
        .task { await checkDraftOnAppear() }
        .alert(item: $confirmation) { item in
            switch item {
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
                            await dependencies.drafts.removeSuggestion()
                            dismiss()
                        }
                    })
                )
            case .restoreDraft:
                Alert(
                    title: Text("加载草稿？"),
                    message: Text("发现上次保存的建议草稿。"),
                    primaryButton: .default(Text("加载草稿"), action: {
                        Task { await loadSavedDraft() }
                    }),
                    secondaryButton: .cancel(Text("不加载"), action: {
                        Task { await dependencies.drafts.removeSuggestion() }
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
        guard !isSubmitting else { return }
        if contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            confirmation = .missingContact
        } else {
            Task { await submit() }
        }
    }

    @MainActor
    private func submit() async {
        guard !isSubmitting else { return }
        let suggestion = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suggestion.isEmpty else { return }
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
            try await dependencies.submitAndClear(
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
            text = ""
            contact = ""
            alert = nil
            dismiss()
        } catch {
            alert = AppAlert(title: "提交失败", message: error.localizedDescription)
        }
    }

    private func requestDismiss() {
        guard !isSubmitting else { return }
        guard hasDraftContent else {
            dismiss()
            return
        }
        confirmation = .saveDraft
    }

    private func saveDraft() async -> Bool {
        await dependencies.drafts.saveSuggestion(
            DeveloperSuggestionDraftSnapshot(
                text: text,
                images: imageDrafts.map {
                    ComposerImageDraftSnapshot(
                        filename: $0.filename,
                        previewData: $0.previewData,
                        uploadData: $0.uploadData
                    )
                },
                contact: contact
            )
        )
    }

    private func checkDraftOnAppear() async {
        guard !didCheckDraft else { return }
        let result = await dependencies.drafts.loadSuggestion()
        guard !Task.isCancelled else { return }
        didCheckDraft = true
        if result.snapshot != nil { confirmation = .restoreDraft }
        if let message = result.recoveryMessage {
            alert = AppAlert.informational(title: "建议草稿恢复需要处理", message: message)
        }
    }

    private func loadSavedDraft() async {
        let result = await dependencies.drafts.loadSuggestion()
        guard let draft = result.snapshot else {
            if let message = result.recoveryMessage {
                alert = AppAlert.informational(title: "建议草稿恢复需要处理", message: message)
            }
            return
        }

        text = draft.text
        contact = draft.contact
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
            Task { await compressRestoredImages() }
        }
    }

    private func compressRestoredImages() async {
        let drafts = imageDrafts.filter { $0.status.isCompressing }
        guard !drafts.isEmpty else { return }

        let results = await compressImageDrafts(drafts)
        applyCompressionResults(results, showsFailureAlert: false)
    }

    private func compressImageDrafts(
        _ drafts: [ComposerImageDraft]
    ) async -> [(ComposerImageDraft.ID, Data?)] {
        var results: [(ComposerImageDraft.ID, Data?)] = []
        var completedCount = 0
        await withTaskGroup(of: (ComposerImageDraft.ID, Data?).self) { group in
            for draft in drafts {
                group.addTask {
                    (draft.id, try? ComposerDraftImageCompressor.compress(draft.previewData))
                }
            }
            for await result in group {
                results.append(result)
                completedCount += 1
                let progress = Int((Double(completedCount) / Double(drafts.count) * 100).rounded())
                imageDrafts = imageDrafts.map { draft in
                    guard draft.status.isCompressing else { return draft }
                    var updated = draft
                    updated.progress = progress
                    return updated
                }
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
        imageDrafts.contains { $0.status.isCompressing }
    }

    private func addImages(from items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }
        let remaining = max(0, 6 - imageDrafts.count)
        let selectedItems = Array(items.prefix(remaining))
        guard !selectedItems.isEmpty else { return }

        var loaded: [(Int, Data)] = []
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, item) in selectedItems.enumerated() {
                group.addTask {
                    (index, try? await item.loadTransferable(type: Data.self))
                }
            }
            for await (index, data) in group {
                if let data {
                    loaded.append((index, data))
                }
            }
        }
        loaded.sort { $0.0 < $1.0 }

        let drafts = loaded.map { _, data in
            ComposerImageDraft(
                previewData: data,
                filename: "suggestion-\(UUID().uuidString).jpg",
                status: .compressing
            )
        }
        imageDrafts.append(contentsOf: drafts)

        let compressed = await compressImageDrafts(drafts)
        applyCompressionResults(compressed, showsFailureAlert: true)
    }

    private func removeImageDraft(id: ComposerImageDraft.ID) {
        imageDrafts.removeAll { $0.id == id }
    }

    private func retryImageDraft(id: ComposerImageDraft.ID) {
        guard !isSubmitting,
              let draft = imageDrafts.first(where: { $0.id == id }),
              case .failed = draft.status else { return }

        var retryingDraft = draft
        retryingDraft.progress = 0
        retryingDraft.uploadData = nil
        retryingDraft.status = .compressing
        imageDrafts = imageDrafts.map { $0.id == id ? retryingDraft : $0 }

        Task {
            let results = await compressImageDrafts([retryingDraft])
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
