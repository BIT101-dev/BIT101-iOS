#if os(iOS)
import CommunityUI
import CommunityCore
import DesignSystemKit
import PhotosUI
import SwiftUI
import UIKit

/// 一条自定义标签输入行草稿。
///
/// 发帖页允许用户临时追加多条输入框，每行使用稳定 `id` 区分。
private struct GalleryCustomTagDraft: Identifiable {
    let id = UUID()
    var text = ""
}


/// 原生发帖页。
///
/// 负责标题、正文、标签、声明和可见性设置。
struct GalleryComposerView: View {
    @Environment(GalleryDependencies.self) private var dependencies
    private static let maximumImageCount = 9

    /// 发帖成功后的回调。
    ///
    /// 调用方通常会在这里刷新当前 feed，并在必要时切回用户刚发帖的分栏。
    let onCreated: () -> Void
    let editingPoster: GalleryPosterDetail?

    @Environment(\.dismiss) private var dismiss
    /// 帖子标题。
    @State private var title = ""
    /// 帖子正文。
    @State private var text = ""
    /// 已选中的预置标签。
    @State private var selectedTags: [String] = []
    /// 用户手动新增的自定义标签输入行。
    @State private var customTagDrafts: [GalleryCustomTagDraft] = []
    /// 当前通过图片选择器选中的图片集合。
    ///
    /// 系统 `PhotosPicker` 支持一次选择多张图，页面保留整批结果并逐张加入上传队列。
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    /// 已经加入发帖草稿的图片列表。
    @State private var imageDrafts: [ComposerImageDraft] = []
    /// 编辑帖子时保留的原有图片列表。
    @State private var existingImages: [CommunityImage] = []
    /// 当前批量读取图片并加入上传队列。
    @State private var isAddingImages = false
    /// 是否匿名发布。
    @State private var anonymous = false
    /// 是否公开出现在信息流中。
    @State private var isPublic = true
    /// 服务端返回的声明列表。
    @State private var claims: [CommunityClaim] = [CommunityClaim(id: 0, text: "无声明")]
    /// 当前选中的声明 ID。
    @State private var selectedClaimID = 0
    /// 是否正在加载声明列表。
    @State private var isLoadingClaims = false
    /// 是否正在提交帖子。
    @State private var isSubmitting = false
    /// 页面级错误提示。
    @State private var alert: AppAlert?
    @State private var isShowingDraftAlert = false
    @State private var isShowingDraftRestoreAlert = false
    @State private var didCheckDraft = false

    /// 发帖接口服务。
    private var service: any GalleryComposerServicing { dependencies.composer }

    init(editingPoster: GalleryPosterDetail? = nil, onCreated: @escaping () -> Void) {
        self.editingPoster = editingPoster
        self.onCreated = onCreated
        _title = State(initialValue: editingPoster?.title ?? "")
        _text = State(initialValue: editingPoster?.text ?? "")
        _selectedTags = State(initialValue: editingPoster?.tags ?? [])
        _anonymous = State(initialValue: editingPoster?.anonymous ?? false)
        _isPublic = State(initialValue: editingPoster?.public ?? true)
        _selectedClaimID = State(initialValue: editingPoster?.claim.id ?? 0)
        _existingImages = State(initialValue: editingPoster?.images ?? [])
    }

    /// 内置的推荐标签。
    ///
    /// 这些常用场景标签帮助用户快速编辑帖子。
    private static let suggestedTags = [
        "水",
        "活动",
        "表白",
        "树洞",
        "求助",
        "聊天",
        "抽象"
    ]

    /// 发帖表单主体。
    ///
    /// 表单结构参考网页端，交互采用原生 `Form`。
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("", text: $title, prompt: AppInputPrompt.text("标题"))
                    TextField("", text: $text, prompt: AppInputPrompt.text("正文"), axis: .vertical)
                        .lineLimit(6, reservesSpace: true)
                }

                Section("标签") {
                    // 标签入口分开呈现预置标签按钮和自定义输入行，常用标签保持快捷选择。
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 64), spacing: AppDesignSystem.Spacing.regular)],
                        alignment: .leading,
                        spacing: AppDesignSystem.Spacing.regular
                    ) {
                        ForEach(Self.suggestedTags, id: \.self) { tag in
                            Button {
                                toggleTag(tag)
                            } label: {
                                AppTagChip(
                                    title: tag,
                                    variant: .selection(isSelected: selectedTags.contains(tag))
                                )
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .appInteractiveListRow()
                        }

                        Button {
                            addCustomTagDraft()
                        } label: {
                            AppTagChip(title: "自定义", variant: .selection(isSelected: false))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .appInteractiveListRow()
                    }
                    .appSelectionFeedback(trigger: selectedTags)

                    if !customTagDrafts.isEmpty {
                        // 每条自定义标签使用独立输入行，输入和删除操作分开呈现。
                        ForEach($customTagDrafts) { $draft in
                            HStack(spacing: AppDesignSystem.Spacing.regular) {
                                TextField("", text: $draft.text, prompt: AppInputPrompt.text("自定义标签"))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                Button {
                                    removeCustomTagDraft(id: draft.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                                        .font(AppDesignSystem.Typography.title)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除标签")
                                .appInteractiveListRow()
                            }
                        }
                    }
                }

                Section("发布设置") {
                    // 声明列表由服务端返回，页面与网页端保持一致。
                    Picker("声明", selection: $selectedClaimID) {
                        ForEach(claims) { claim in
                            Text(claim.text).tag(claim.id)
                        }
                    }
                    .appSelectionFeedback(trigger: selectedClaimID)
                    .appInteractiveListRow()

                    Toggle("匿名发布", isOn: $anonymous)
                        .appSelectionFeedback(trigger: anonymous)
                    .appInteractiveListRow()
                    Toggle("公开显示", isOn: $isPublic)
                        .appSelectionFeedback(trigger: isPublic)
                    .appInteractiveListRow()
                }

                Section("图片") {
                    PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: Self.maximumImageCount, matching: .images) {
                        Text("插入图片")
                    }
                    .disabled(
                        isSubmitting
                            || isAddingImages
                            || existingImages.count + imageDrafts.count >= Self.maximumImageCount
                    )
                    .appInteractiveListRow()

                    if !existingImages.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: AppDesignSystem.Size.Media.draft), spacing: AppDesignSystem.Spacing.regular)],
                            spacing: AppDesignSystem.Spacing.regular
                        ) {
                            ForEach(existingImages) { image in
                                ZStack(alignment: .topTrailing) {
                                    CommunityImageThumbnail(image: image, contentMode: .fill)
                                        .frame(
                                            width: AppDesignSystem.Size.Media.draft,
                                            height: AppDesignSystem.Size.Media.draft
                                        )
                                        .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))

                                    Button {
                                        removeExistingImage(id: image.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(AppDesignSystem.Typography.title)
                                            .foregroundStyle(AppDesignSystem.Palette.Media.foreground, AppDesignSystem.Palette.Media.controlOverlay)
                                    }
                                    .padding(AppDesignSystem.Spacing.tiny)
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("移除原有图片")
                                    .appInteractiveListRow()
                                }
                                .frame(
                                    width: AppDesignSystem.Size.Media.draft,
                                    height: AppDesignSystem.Size.Media.draft
                                )
                            }
                        }
                    }

                    if !imageDrafts.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: AppDesignSystem.Size.Media.draft), spacing: AppDesignSystem.Spacing.regular)],
                            spacing: AppDesignSystem.Spacing.regular
                        ) {
                            ForEach(imageDrafts) { draft in
                                ComposerImageTile(
                                    draft: draft,
                                    onRetry: {
                                        Task { await retryImageUpload(id: draft.id) }
                                    },
                                    onRemove: {
                                        removeImageDraft(id: draft.id)
                                    }
                                )
                            }
                        }
                    }

                    if hasUploadingImages {
                        Text("图片上传中，上传完成后即可一并发布。")
                            .font(AppDesignSystem.Typography.footnote)
                            .foregroundStyle(AppDesignSystem.Foreground.secondary)
                    }
                }
            }
            .navigationTitle(editingPoster == nil ? "发布帖子" : "编辑帖子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { requestDismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSubmitting ? "保存中" : editingPoster == nil ? "发布" : "保存") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting)
                }
            }
            .task { await loadClaimsIfNeeded() }
            .onChange(of: selectedPhotoItems) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task { await addImages(from: newValue) }
            }
            .task { await checkDraftOnAppear() }
            .alert("保存草稿？", isPresented: $isShowingDraftAlert) {
                Button("保存草稿") {
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
                }
                Button("不保存") {
                    Task {
                        await dependencies.drafts.removeGallery()
                        dismiss()
                    }
                }
            } message: {
                Text("保存后下次打开时可以加载草稿。")
            }
            .alert("加载草稿？", isPresented: $isShowingDraftRestoreAlert) {
                Button("加载草稿") {
                    Task { await loadSavedDraft() }
                }
                Button("不加载") {
                    Task { await dependencies.drafts.removeGallery() }
                }
            } message: {
                Text("发现上次保存的发帖草稿。")
            }
            .diagnosticAlert(item: $alert)
        }
    }

    private func requestDismiss() {
        guard !isSubmitting else { return }
        if editingPoster != nil {
            dismiss()
            return
        }
        guard hasDraftContent else {
            dismiss()
            return
        }
        isShowingDraftAlert = true
    }

    private func saveDraft() async -> Bool {
        await dependencies.drafts.saveGallery(
            GalleryComposerDraftSnapshot(
                title: title,
                text: text,
                selectedTags: selectedTags,
                customTags: customTagDrafts.map(\.text),
                anonymous: anonymous,
                isPublic: isPublic,
                selectedClaimID: selectedClaimID,
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

    private func checkDraftOnAppear() async {
        guard editingPoster == nil, !didCheckDraft else { return }
        let hasDraft = await dependencies.drafts.loadGallery() != nil
        guard !Task.isCancelled else { return }
        didCheckDraft = true
        isShowingDraftRestoreAlert = hasDraft
    }

    private func loadSavedDraft() async {
        guard let draft = await dependencies.drafts.loadGallery() else { return }

        title = draft.title
        text = draft.text
        selectedTags = draft.selectedTags
        customTagDrafts = draft.customTags.map { tag in
            var tagDraft = GalleryCustomTagDraft()
            tagDraft.text = tag
            return tagDraft
        }
        anonymous = draft.anonymous
        isPublic = draft.isPublic
        selectedClaimID = draft.selectedClaimID
        imageDrafts = draft.images.map {
            let uploadData = $0.uploadData ?? jpegUploadData(from: $0.previewData)
            return ComposerImageDraft(
                previewData: $0.previewData,
                filename: $0.filename,
                uploadData: uploadData,
                status: .failed("需要重新上传")
            )
        }
    }

    private var hasDraftContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedTags.isEmpty
            || !customTagDrafts.isEmpty
            || !imageDrafts.isEmpty
            || anonymous
            || !isPublic
            || selectedClaimID != 0
    }

    /// 当前是否仍有图片在上传中。
    ///
    /// 图片上传完成后，发帖操作即可提交完整的资源列表。
    private var hasUploadingImages: Bool {
        imageDrafts.contains {
            if case .uploading = $0.status {
                return true
            }
            return false
        }
    }

    /// 首次进入时拉取可选 claim 列表。
    ///
    /// 声明列表加载失败时继续发帖，页面保留默认的“无声明”占位。
    private func loadClaimsIfNeeded() async {
        guard !isLoadingClaims else { return }
        isLoadingClaims = true
        defer { isLoadingClaims = false }

        do {
            let fetchedClaims = try await service.fetchClaims()
            if !fetchedClaims.isEmpty {
                claims = fetchedClaims.sorted { $0.id < $1.id }
                if !claims.contains(where: { $0.id == selectedClaimID }) {
                    selectedClaimID = claims.first?.id ?? 0
                }
            }
        } catch {
            return
        }
    }

    /// 完成必要字段校验后提交帖子。
    ///
    /// 提交按以下顺序执行：
    /// 1. 校验必要字段。
    /// 2. 设置提交状态，阻止重复点击。
    /// 3. 服务端成功后通知调用方刷新，再关闭当前页面。
    private func submit() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = combinedTags()

        guard !trimmedTitle.isEmpty else {
            alert = AppAlert.userInput(title: "发布失败", message: "标题不能为空。")
            return
        }
        guard !trimmedText.isEmpty else {
            alert = AppAlert.userInput(title: "发布失败", message: "正文不能为空。")
            return
        }
        guard tags.count >= 2 else {
            alert = AppAlert.userInput(title: "发布失败", message: "请至少添加 2 个标签。")
            return
        }
        guard !hasUploadingImages else {
            alert = AppAlert.userInput(title: "发布失败", message: "图片仍在上传，请稍候。")
            return
        }

        let uploadedImages = imageDrafts.compactMap(\.uploadedImage)
        guard uploadedImages.count == imageDrafts.count else {
            alert = AppAlert(title: "发布失败", message: "有图片上传失败，请删除后重试，或点“重试”重新上传。")
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }
        let cleanup = await dependencies.drafts.captureGalleryCleanup()

        do {
            let imageMids = existingImages.map(\.mid) + uploadedImages.map(\.mid)
            if let editingPoster {
                try await service.updatePoster(
                    id: editingPoster.id,
                    title: trimmedTitle,
                    text: trimmedText,
                    imageMids: imageMids,
                    anonymous: anonymous,
                    tags: tags,
                    claimID: selectedClaimID,
                    isPublic: isPublic
                )
            } else {
                _ = try await service.createPoster(
                    title: trimmedTitle,
                    text: trimmedText,
                    imageMids: imageMids,
                    anonymous: anonymous,
                    tags: tags,
                    claimID: selectedClaimID,
                    isPublic: isPublic
                )
            }
            await cleanup()
            onCreated()
            dismiss()
        } catch {
            alert = AppAlert(title: "发布失败", message: error.localizedDescription)
        }
    }

    /// 切换预置标签的选中状态。
    ///
    /// 预置标签和自定义标签来源独立，这里操作预置标签集合。
    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.removeAll { $0 == tag }
        } else {
            addTag(tag)
        }
    }

    /// 添加一个新的预置标签，同时负责去重和数量上限。
    ///
    /// 数量上限与最终提交限制一致，编辑阶段直接应用上限。
    private func addTag(_ tag: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !selectedTags.contains(normalized) else { return }
        guard selectedTags.count < 10 else { return }
        selectedTags.append(normalized)
    }

    /// 追加一条新的自定义标签输入行。
    ///
    /// “预置标签数 + 输入行数”共同限制上限，连续添加“自定义”时立即应用上限。
    private func addCustomTagDraft() {
        guard selectedTags.count + customTagDrafts.count < 10 else { return }
        customTagDrafts.append(GalleryCustomTagDraft())
    }

    /// 删除指定的自定义标签输入行。
    private func removeCustomTagDraft(id: GalleryCustomTagDraft.ID) {
        customTagDrafts.removeAll { $0.id == id }
    }

    /// 从图片选择器批量追加图片并逐张开始上传。
    ///
    /// 图片按选择顺序逐张加入队列并上传，缩略图排列保持选择顺序。
    private func addImages(from items: [PhotosPickerItem]) async {
        guard !isAddingImages else { return }
        isAddingImages = true
        defer { isAddingImages = false }
        defer { selectedPhotoItems = [] }
        let remaining = max(0, Self.maximumImageCount - existingImages.count - imageDrafts.count)
        guard remaining > 0 else { return }

        for item in items.prefix(remaining) {
            await addImage(from: item)
        }
    }

    /// 从图片选择器追加一张新图并立即开始上传。
    private func addImage(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw GalleryServiceError.uploadFailed
            }

            let filename = "poster-\(UUID().uuidString).jpg"
            guard let uploadData = jpegUploadData(from: data) else {
                throw GalleryServiceError.uploadFailed
            }
            var draft = ComposerImageDraft(
                previewData: data,
                filename: filename,
                uploadData: uploadData
            )
            imageDrafts.append(draft)

            do {
                let image = try await service.uploadImage(
                    data: draft.uploadData ?? draft.previewData,
                    filename: filename
                )
                draft.status = .uploaded(image)
            } catch {
                draft.status = .failed(error.localizedDescription)
            }

            replaceImageDraft(draft)
        } catch {
            alert = AppAlert(title: "图片添加失败", message: error.localizedDescription)
        }
    }

    /// 按 `id` 回写图片草稿。
    private func replaceImageDraft(_ draft: ComposerImageDraft) {
        guard let index = imageDrafts.firstIndex(where: { $0.id == draft.id }) else { return }
        imageDrafts[index] = draft
    }

    /// 将照片选择器返回的图片统一编码为上传接口声明的 JPEG。
    private func jpegUploadData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 1)
    }

    /// 重试失败图片的上传。
    private func retryImageUpload(id: ComposerImageDraft.ID) async {
        guard var draft = imageDrafts.first(where: { $0.id == id }) else { return }
        draft.status = .uploading
        replaceImageDraft(draft)

        do {
            let image = try await service.uploadImage(
                data: draft.uploadData ?? draft.previewData,
                filename: draft.filename
            )
            draft.status = .uploaded(image)
        } catch {
            draft.status = .failed(error.localizedDescription)
        }
        replaceImageDraft(draft)
    }

    /// 移除新加入的图片草稿。
    private func removeImageDraft(id: ComposerImageDraft.ID) {
        imageDrafts.removeAll { $0.id == id }
    }

    /// 移除编辑帖子时保留的原有图片。
    private func removeExistingImage(id: CommunityImage.ID) {
        existingImages.removeAll { $0.id == id }
    }

    /// 把预置标签和自定义标签合并成最终提交数组。
    ///
    /// 这里会统一裁剪空白、去重并限制最多 10 个标签。
    private func combinedTags() -> [String] {
        let customTags = customTagDrafts
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [String] = []

        for tag in selectedTags + customTags {
            guard !seen.contains(tag) else { continue }
            seen.insert(tag)
            result.append(tag)
        }

        return Array(result.prefix(10))
    }
}

#endif
