//
//  SettingsRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import PhotosUI
import SwiftUI
import ImageIO
import WebKit

let mitLicenseText = "MIT License Copyright (c) 2026 BIT101 Contributors Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."

/// 设置中心支持的一级菜单。
///
/// “设置首页卡片”与“从其它页面直达某一设置子页”都依赖这个枚举作为统一路由源。
enum SettingsRoute: String, CaseIterable, Identifiable {
    case account
    case pages
    case theme
    case calendar
    case ddl
    case gallery
    case suggestion
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "账号设置"
        case .pages: return "页面设置"
        case .theme: return "外观设置"
        case .calendar: return "课程表设置"
        case .ddl: return "DDL设置"
        case .gallery: return "话廊设置"
        case .suggestion: return "我想和开发者提建议"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .pages: return "square.grid.2x2"
        case .theme: return "paintpalette"
        case .calendar: return "calendar.badge.clock"
        case .ddl: return "list.bullet.clipboard"
        case .gallery: return "bubble.left.and.bubble.right"
        case .suggestion: return "lightbulb"
        case .about: return "info.circle"
        }
    }
}

/// 全局设置中心入口。
///
/// “我的”页右上角设置、课程表页齿轮、DDL 页齿轮都应当汇入这里。
struct SettingsRootView: View {
    let initialRoute: SettingsRoute?
    let studentID: String
    let onLogout: () -> Void
    var showsCloseButton = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let initialRoute {
                SettingsRoutePage(route: initialRoute, studentID: studentID, onLogout: onLogout)
            } else {
                SettingsIndexPage(studentID: studentID, onLogout: onLogout)
            }
        }
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

/// 设置首页，负责列出全部一级菜单。
///
/// 这里仍然保留卡片式入口，而不是直接用 `List`，是为了和“我的”页的入口风格区分开。
private struct SettingsIndexPage: View {
    let studentID: String
    let onLogout: () -> Void
    @State private var isShowingSuggestion = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
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
                            SettingsRoutePage(route: route, studentID: studentID, onLogout: onLogout)
                        } label: {
                            SettingsIndexCard(route: route)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(AppDesignSystem.Palette.groupedBackground)
        .sheet(isPresented: $isShowingSuggestion) {
            NavigationStack {
                DeveloperSuggestionPage()
            }
        }
    }
}

/// 设置首页卡片样式。
private struct SettingsIndexCard: View {
    let route: SettingsRoute

    var body: some View {
        AppCard {
            HStack(spacing: AppDesignSystem.Spacing.control) {
                Image(systemName: route.systemImage)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.primary)

                Text(route.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()
            }
        }
    }
}

/// 根据 route 分发到具体设置页面。
///
/// 这一层的意义是把“路由选择”和“具体页面实现”解耦，便于其它模块直接按 route 深链进来。
private struct SettingsRoutePage: View {
    let route: SettingsRoute
    let studentID: String
    let onLogout: () -> Void

    var body: some View {
        switch route {
        case .account:
            AccountSettingsPage(studentID: studentID, onLogout: onLogout)
        case .pages:
            PagesSettingsPage()
        case .theme:
            ThemeSettingsPage()
        case .calendar:
            CalendarSettingsPage()
        case .ddl:
            DDLSettingsPage()
        case .gallery:
            GallerySettingsPage()
        case .suggestion:
            DeveloperSuggestionPage()
        case .about:
            AboutSettingsPage(onLogout: onLogout)
        }
    }
}

private struct DeveloperSuggestionAttachment: Encodable {
    let filename: String
    let contentType: String
    let data: String
}

private struct DeveloperSuggestionPayload: Encodable {
    let mode = "suggestion"
    let comment: String
    let errorTitle = "开发者建议"
    let errorMessage = "用户主动提交的功能建议。"
    let appVersion: String
    let build: String
    let systemVersion: String
    let deviceModel: String
    let networkStatus = ""
    let diagnostics: [NetworkDiagnosticRecord] = []
    let attachments: [DeveloperSuggestionAttachment]
}

/// 向开发者提交功能建议，复用错误反馈 Worker 与邮件通知链路。
struct DeveloperSuggestionPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var imageDrafts: [GalleryComposerImageDraft] = []
    @State private var isSubmitting = false
    @State private var alert: AppAlert?
    @State private var isShowingDraftAlert = false
    @State private var isShowingDraftRestoreAlert = false
    @State private var didCheckDraft = false

    var body: some View {
        Form {
            Section("建议内容") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                    if text.isEmpty {
                        Text("请输入你想告诉开发者的内容")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            }

            Section("图片（可选）") {
                PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 6, matching: .images) {
                    Text("插入图片")
                }
                .disabled(isSubmitting || imageDrafts.count >= 6)

                if !imageDrafts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(imageDrafts) { draft in
                                GalleryComposerImageTile(
                                    draft: draft,
                                    onRetry: {},
                                    onRemove: { removeImageDraft(id: draft.id) },
                                    showsPreparedSuccessIndicator: false
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

            }

        }
            .navigationTitle("我想和开发者提建议")
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
                        Task { await submit() }
                    }
                )
            }
            .onChange(of: selectedPhotoItems) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task { await addImages(from: newValue) }
            }
            .onAppear { checkDraftOnAppear() }
            .alert("保存草稿？", isPresented: $isShowingDraftAlert) {
                Button("保存草稿") {
                    saveDraft()
                    dismiss()
                }
                Button("不保存") {
                    ComposerDraftStore.removeSuggestion()
                    dismiss()
                }
            } message: {
                Text("保存后下次打开时可以加载草稿。")
            }
            .alert("加载草稿？", isPresented: $isShowingDraftRestoreAlert) {
                Button("加载草稿") {
                    loadSavedDraft()
                }
                Button("不加载") {
                    ComposerDraftStore.removeSuggestion()
                }
            } message: {
                Text("发现上次保存的建议草稿。")
            }
            .diagnosticAlert(item: $alert)
    }

    @MainActor
    private func submit() async {
        guard !isSubmitting else { return }
        let suggestion = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suggestion.isEmpty else { return }
        guard !hasUploadingImages else {
            alert = AppAlert(title: "提交失败", message: "图片仍在处理中，请稍候。")
            return
        }
        guard imageDrafts.allSatisfy({
            if case .prepared = $0.status { return true }
            return false
        }) else {
            alert = AppAlert(title: "提交失败", message: "有图片未处理完成，请删除后重新选择。")
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await FeedbackSubmissionClient.submit(
                DeveloperSuggestionPayload(
                    comment: suggestion,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                    systemVersion: UIDevice.current.systemVersion,
                    deviceModel: UIDevice.current.model,
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
            ComposerDraftStore.removeSuggestion()
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
        isShowingDraftAlert = true
    }

    private func saveDraft() {
        ComposerDraftStore.saveSuggestion(
            DeveloperSuggestionDraftSnapshot(
                text: text,
                images: imageDrafts.map {
                    ComposerImageDraftSnapshot(
                        filename: $0.filename,
                        previewData: $0.previewData,
                        uploadData: $0.uploadData
                    )
                }
            )
        )
    }

    private func checkDraftOnAppear() {
        guard !didCheckDraft else { return }
        didCheckDraft = true
        isShowingDraftRestoreAlert = ComposerDraftStore.loadSuggestion() != nil
    }

    private func loadSavedDraft() {
        guard let draft = ComposerDraftStore.loadSuggestion() else { return }

        text = draft.text
        imageDrafts = draft.images.map {
            GalleryComposerImageDraft(
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

        var results: [(GalleryComposerImageDraft.ID, Data?)] = []
        var completedCount = 0
        await withTaskGroup(of: (GalleryComposerImageDraft.ID, Data?).self) { group in
            for draft in drafts {
                group.addTask {
                    (draft.id, try? SuggestionImageCompressor.compress(draft.previewData))
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

        imageDrafts = imageDrafts.map { draft in
            guard let result = results.first(where: { $0.0 == draft.id }) else { return draft }
            guard let data = result.1 else {
                var failed = draft
                failed.status = .failed("图片无法处理")
                return failed
            }
            var prepared = draft
            prepared.uploadData = data
            prepared.status = .prepared
            return prepared
        }
    }

    private var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageDrafts.isEmpty
    }

    private var hasUploadingImages: Bool {
        imageDrafts.contains {
            if case .uploading = $0.status { return true }
            if case .compressing = $0.status { return true }
            return false
        }
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
            GalleryComposerImageDraft(
                previewData: data,
                filename: "suggestion-\(UUID().uuidString).jpg",
                status: .compressing
            )
        }
        imageDrafts.append(contentsOf: drafts)

        var compressed: [(GalleryComposerImageDraft.ID, Data?)] = []
        var completedCount = 0
        await withTaskGroup(of: (GalleryComposerImageDraft.ID, Data?).self) { group in
            for draft in drafts {
                group.addTask {
                    (draft.id, try? SuggestionImageCompressor.compress(draft.previewData))
                }
            }
            for await result in group {
                compressed.append(result)
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

        var failed = false
        imageDrafts = imageDrafts.map { draft in
            guard let result = compressed.first(where: { $0.0 == draft.id }) else { return draft }
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

        if failed {
            alert = AppAlert(title: "图片添加失败", message: "部分图片无法处理，请删除后重新选择。")
        }
    }

    private func removeImageDraft(id: GalleryComposerImageDraft.ID) {
        imageDrafts.removeAll { $0.id == id }
    }

}

private extension GalleryComposerImageDraft.Status {
    var isCompressing: Bool {
        if case .compressing = self { return true }
        return false
    }
}

private enum SuggestionImageCompressor {
    nonisolated static func compress(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1600
                  ] as CFDictionary
              ) else {
            throw GalleryServiceError.uploadFailed
        }

        let maxBytes = 1 * 1024 * 1024
        var best = render(image: image, maxDimension: 1600, quality: 0.68)
        if best.count <= maxBytes { return best }

        for quality in [0.48, 0.32, 0.2] {
            best = render(image: image, maxDimension: 1600, quality: quality)
            if best.count <= maxBytes { return best }
        }

        for dimension in [1200, 900, 700] {
            best = render(image: image, maxDimension: CGFloat(dimension), quality: 0.5)
            if best.count <= maxBytes { return best }
        }
        return best
    }

    private nonisolated static func render(
        image: CGImage,
        maxDimension: CGFloat,
        quality: CGFloat
    ) -> Data {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let size = CGSize(
            width: max(1, width * scale),
            height: max(1, height * scale)
        )
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: quality) { context in
            context.cgContext.interpolationQuality = .medium
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// 账号设置页。
///
/// 包含个人资料编辑、头像上传、登录状态检查和退出登录。
