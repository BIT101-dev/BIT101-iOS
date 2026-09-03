//
//  SettingsRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import PhotosUI
import SwiftUI
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

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(SettingsRoute.allCases) { route in
                    NavigationLink {
                        SettingsRoutePage(route: route, studentID: studentID, onLogout: onLogout)
                    } label: {
                        SettingsIndexCard(route: route)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// 设置首页卡片样式。
private struct SettingsIndexCard: View {
    let route: SettingsRoute

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: route.systemImage)
                .frame(width: 24, height: 24)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 0) {
                Text(route.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    @State private var text = ""
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var imageDrafts: [GalleryComposerImageDraft] = []
    @State private var isSubmitting = false
    @State private var alert: AppAlert?

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
                    Label("插入图片", systemImage: "photo.badge.plus")
                }
                .disabled(isSubmitting || imageDrafts.count >= 6)

                if !imageDrafts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(imageDrafts) { draft in
                                GalleryComposerImageTile(
                                    draft: draft,
                                    onRetry: {},
                                    onRemove: { removeImageDraft(id: draft.id) }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if hasUploadingImages {
                    Text("图片上传中，上传完成后即可提交。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("图片会自动压缩后上传。最多 6 张。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Text(isSubmitting ? "提交中" : "提交建议")
                        Spacer()
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isSubmitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
            .navigationTitle("我想和开发者提建议")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedPhotoItems) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task { await addImages(from: newValue) }
            }
            .diagnosticAlert(item: $alert)
    }

    @MainActor
    private func submit() async {
        guard !isSubmitting else { return }
        let suggestion = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suggestion.isEmpty else { return }
        guard !hasUploadingImages else {
            alert = AppAlert(title: "提交失败", message: "图片仍在上传，请稍候。")
            return
        }
        guard imageDrafts.allSatisfy({
            if case .prepared = $0.status { return true }
            return false
        }) else {
            alert = AppAlert(title: "提交失败", message: "有图片上传失败，请删除后重试，或点“重试”重新上传。")
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
                            data: $0.previewData.base64EncodedString()
                        )
                    }
                )
            )
            text = ""
            alert = AppAlert(title: "提交成功", message: "感谢你的建议。")
        } catch {
            alert = AppAlert(title: "提交失败", message: error.localizedDescription)
        }
    }

    private var hasUploadingImages: Bool {
        imageDrafts.contains {
            if case .uploading = $0.status { return true }
            return false
        }
    }

    private func addImages(from items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }
        for item in items {
            await addImage(from: item)
        }
    }

    private func addImage(from item: PhotosPickerItem) async {
        do {
            guard imageDrafts.count < 6 else { return }
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw GalleryServiceError.uploadFailed
            }

            let compressed = try compressImage(data)
            let draft = GalleryComposerImageDraft(
                previewData: compressed,
                filename: "suggestion-\(UUID().uuidString).jpg",
                status: .prepared
            )
            imageDrafts.append(draft)
        } catch {
            alert = AppAlert(title: "图片添加失败", message: error.localizedDescription)
        }
    }

    private func removeImageDraft(id: GalleryComposerImageDraft.ID) {
        imageDrafts.removeAll { $0.id == id }
    }

    private func compressImage(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw GalleryServiceError.uploadFailed
        }

        let maxBytes = 100 * 1024
        var dimension: CGFloat = 1600
        var best = data
        while dimension >= 320 {
            let scale = min(1, dimension / max(image.size.width, image.size.height))
            let size = CGSize(
                width: max(1, image.size.width * scale),
                height: max(1, image.size.height * scale)
            )
            let renderer = UIGraphicsImageRenderer(size: size)
            for quality in [0.72, 0.58, 0.42, 0.28] {
                let candidate = renderer.jpegData(withCompressionQuality: quality) {
                    _ in image.draw(in: CGRect(origin: .zero, size: size))
                }
                best = candidate
                if candidate.count <= maxBytes {
                    return candidate
                }
            }
            dimension *= 0.8
        }
        return best
    }
}

/// 账号设置页。
///
/// 包含个人资料编辑、头像上传、登录状态检查和退出登录。
