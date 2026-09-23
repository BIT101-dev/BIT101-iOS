import PhotosUI
import OSLog
import SwiftUI
import UIKit

/// 一条自定义标签输入行草稿。
///
/// 发帖页允许用户临时追加多条输入框，每行使用稳定 `id` 区分。
private struct GalleryCustomTagDraft: Identifiable {
    let id = UUID()
    var text = ""
}

/// 发帖页的一张图片草稿，记录预览和上传状态。
///
/// 图片上传成功后，草稿保存服务端图片对象，发帖请求通过 `mid` 引用资源。
struct GalleryComposerImageDraft: Identifiable {
    enum Status {
        case uploading
        case compressing
        case prepared
        case uploaded(GalleryImage)
        case failed(String)
    }

    let id = UUID()
    let previewData: Data
    let filename: String
    var uploadData: Data?
    var progress: Int = 0
    var status: Status = .uploading

    init(
        previewData: Data,
        filename: String,
        uploadData: Data? = nil,
        progress: Int = 0,
        status: Status = .uploading
    ) {
        self.previewData = previewData
        self.filename = filename
        self.uploadData = uploadData
        self.progress = progress
        self.status = status
    }

    /// 上传成功的图片会拿到可提交给发帖接口的 `mid`。
    var uploadedImage: GalleryImage? {
        guard case .uploaded(let image) = status else { return nil }
        return image
    }
}

/// 发帖页图片缩略图条目。
///
/// 图片状态对应以下交互：
/// - 上传中显示进度
/// - 失败时允许重试
/// - 每种状态都提供删除操作
struct GalleryComposerImageTile: View {
    let draft: GalleryComposerImageDraft
    let onRetry: () -> Void
    let onRemove: () -> Void
    let showsPreparedSuccessIndicator: Bool

    init(
        draft: GalleryComposerImageDraft,
        onRetry: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        showsPreparedSuccessIndicator: Bool = true
    ) {
        self.draft = draft
        self.onRetry = onRetry
        self.onRemove = onRemove
        self.showsPreparedSuccessIndicator = showsPreparedSuccessIndicator
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card)
                    .fill(AppDesignSystem.Palette.secondaryGroupedBackground)

                if let image = UIImage(data: draft.previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(AppDesignSystem.Typography.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: AppDesignSystem.Size.Content.imageDraft, height: AppDesignSystem.Size.Content.imageDraft)
            .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))
            .overlay(alignment: .bottom) {
                overlayContent
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(AppDesignSystem.Typography.title3)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .padding(AppDesignSystem.Spacing.tiny)
            .buttonStyle(.plain)
            .accessibilityLabel("移除图片")
        }
        .frame(width: AppDesignSystem.Size.Content.imageDraft, height: AppDesignSystem.Size.Content.imageDraft)
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch draft.status {
        case .uploading:
            ZStack {
                Rectangle()
                    .fill(AppDesignSystem.Palette.mediaOverlay)
                ProgressView()
                    .tint(.white)
            }
            .frame(height: AppDesignSystem.Size.Control.compact)
        case .compressing:
            ZStack {
                Rectangle()
                    .fill(AppDesignSystem.Palette.mediaOverlay)
                Text("\(draft.progress)%")
                    .font(AppDesignSystem.Typography.caption2Emphasis)
                    .foregroundStyle(.white)
            }
            .frame(height: AppDesignSystem.Size.Control.compact)
        case .prepared:
            if showsPreparedSuccessIndicator {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppDesignSystem.Typography.title3)
                    .foregroundStyle(.white)
                    .padding(AppDesignSystem.Spacing.tiny)
                    .background(AppDesignSystem.Palette.mediaOverlayStrong, in: Circle())
            }
        case .uploaded:
            HStack(spacing: AppDesignSystem.Spacing.tiny) {
                Image(systemName: "checkmark.circle.fill")
                Text("已上传")
            }
            .font(AppDesignSystem.Typography.caption2Emphasis)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppDesignSystem.Spacing.tiny)
            .background(AppDesignSystem.Palette.mediaOverlayStrong)
        case .failed:
            Button(action: onRetry) {
                HStack(spacing: AppDesignSystem.Spacing.tiny) {
                    Image(systemName: "arrow.clockwise")
                    Text("重试")
                }
                .font(AppDesignSystem.Typography.caption2Emphasis)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppDesignSystem.Spacing.tiny)
                .background(AppDesignSystem.Palette.danger.opacity(0.82))
            }
            .buttonStyle(.plain)
        }
    }
}

struct ComposerImageDraftSnapshot: Codable {
    let filename: String
    let previewData: Data
    let uploadData: Data?
}

struct GalleryComposerDraftSnapshot: Codable {
    let title: String
    let text: String
    let selectedTags: [String]
    let customTags: [String]
    let anonymous: Bool
    let isPublic: Bool
    let selectedClaimID: Int
    let images: [ComposerImageDraftSnapshot]
}

struct DeveloperSuggestionDraftSnapshot: Codable {
    let text: String
    let images: [ComposerImageDraftSnapshot]
    let contact: String

    init(
        text: String,
        images: [ComposerImageDraftSnapshot],
        contact: String = ""
    ) {
        self.text = text
        self.images = images
        self.contact = contact
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case images
        case contact
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        images = try container.decode([ComposerImageDraftSnapshot].self, forKey: .images)
        contact = try container.decodeIfPresent(String.self, forKey: .contact) ?? ""
    }
}

enum ComposerDraftStore {
    private static let directoryName = "ComposerDrafts"
    private static let logger = Logger(subsystem: "BIT101", category: "ComposerDraft")

    static func saveGallery(_ snapshot: GalleryComposerDraftSnapshot) {
        save(snapshot, filename: "gallery.json")
    }

    static func loadGallery() -> GalleryComposerDraftSnapshot? {
        load(filename: "gallery.json")
    }

    static func saveSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot) {
        save(snapshot, filename: "suggestion.json")
    }

    static func loadSuggestion() -> DeveloperSuggestionDraftSnapshot? {
        load(filename: "suggestion.json")
    }

    static func removeGallery() {
        remove(filename: "gallery.json")
    }

    static func removeSuggestion() {
        remove(filename: "suggestion.json")
    }

    private static var directoryURL: URL {
        AppFileDirectories.applicationSupport
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func save<T: Encodable>(_ value: T, filename: String) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: directoryURL.appendingPathComponent(filename), options: .atomic)
        } catch {
            // 草稿保存失败允许用户退出，日志保留诊断信息。
            logger.error("保存草稿失败：\(String(describing: error), privacy: .public)")
        }
    }

    private static func load<T: Decodable>(filename: String) -> T? {
        guard let data = try? Data(contentsOf: directoryURL.appendingPathComponent(filename)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func remove(filename: String) {
        try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(filename))
    }
}

/// 原生发帖页。
///
/// 负责标题、正文、标签、声明和可见性设置。
struct GalleryComposerView: View {
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
    @State private var imageDrafts: [GalleryComposerImageDraft] = []
    /// 编辑帖子时保留的原有图片列表。
    @State private var existingImages: [GalleryImage] = []
    /// 当前批量读取图片并加入上传队列。
    @State private var isAddingImages = false
    /// 是否匿名发布。
    @State private var anonymous = false
    /// 是否公开出现在信息流中。
    @State private var isPublic = true
    /// 服务端返回的声明列表。
    @State private var claims: [GalleryClaim] = [GalleryClaim(id: 0, text: "无声明")]
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
    private let service = GalleryService()

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
                        }

                        Button {
                            addCustomTagDraft()
                        } label: {
                            AppTagChip(title: "自定义", variant: .selection(isSelected: false))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
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
                                        .foregroundStyle(.secondary)
                                        .font(AppDesignSystem.Typography.title3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除标签")
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

                    Toggle("匿名发布", isOn: $anonymous)
                        .appSelectionFeedback(trigger: anonymous)
                    Toggle("公开显示", isOn: $isPublic)
                        .appSelectionFeedback(trigger: isPublic)
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

                    if !existingImages.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: AppDesignSystem.Size.Content.imageDraft), spacing: AppDesignSystem.Spacing.regular)],
                            spacing: AppDesignSystem.Spacing.regular
                        ) {
                            ForEach(existingImages) { image in
                                ZStack(alignment: .topTrailing) {
                                    GalleryPosterThumbnail(image: image, contentMode: .fill)
                                        .frame(
                                            width: AppDesignSystem.Size.Content.imageDraft,
                                            height: AppDesignSystem.Size.Content.imageDraft
                                        )
                                        .clipShape(AppDesignSystem.roundedRectangle(AppDesignSystem.Radius.card))

                                    Button {
                                        removeExistingImage(id: image.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(AppDesignSystem.Typography.title3)
                                            .foregroundStyle(.white, Color.black.opacity(0.55))
                                    }
                                    .padding(AppDesignSystem.Spacing.tiny)
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("移除原有图片")
                                }
                                .frame(
                                    width: AppDesignSystem.Size.Content.imageDraft,
                                    height: AppDesignSystem.Size.Content.imageDraft
                                )
                            }
                        }
                    }

                    if !imageDrafts.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: AppDesignSystem.Size.Content.imageDraft), spacing: AppDesignSystem.Spacing.regular)],
                            spacing: AppDesignSystem.Spacing.regular
                        ) {
                            ForEach(imageDrafts) { draft in
                                GalleryComposerImageTile(
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
                            .foregroundStyle(.secondary)
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
            .onAppear { checkDraftOnAppear() }
            .alert("保存草稿？", isPresented: $isShowingDraftAlert) {
                Button("保存草稿") {
                    saveDraft()
                    dismiss()
                }
                Button("不保存") {
                    ComposerDraftStore.removeGallery()
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
                    ComposerDraftStore.removeGallery()
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

    private func saveDraft() {
        ComposerDraftStore.saveGallery(
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

    private func checkDraftOnAppear() {
        guard editingPoster == nil, !didCheckDraft else { return }
        didCheckDraft = true
        isShowingDraftRestoreAlert = ComposerDraftStore.loadGallery() != nil
    }

    private func loadSavedDraft() {
        guard let draft = ComposerDraftStore.loadGallery() else { return }

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
            return GalleryComposerImageDraft(
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
            ComposerDraftStore.removeGallery()
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
            var draft = GalleryComposerImageDraft(
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
    private func replaceImageDraft(_ draft: GalleryComposerImageDraft) {
        guard let index = imageDrafts.firstIndex(where: { $0.id == draft.id }) else { return }
        imageDrafts[index] = draft
    }

    /// 将照片选择器返回的图片统一编码为上传接口声明的 JPEG。
    private func jpegUploadData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 1)
    }

    /// 重试失败图片的上传。
    private func retryImageUpload(id: GalleryComposerImageDraft.ID) async {
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
    private func removeImageDraft(id: GalleryComposerImageDraft.ID) {
        imageDrafts.removeAll { $0.id == id }
    }

    /// 移除编辑帖子时保留的原有图片。
    private func removeExistingImage(id: GalleryImage.ID) {
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
