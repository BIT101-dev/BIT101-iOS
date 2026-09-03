import PhotosUI
import SwiftUI
import UIKit

/// 一条尚未提交的自定义标签输入行。
///
/// 发帖页允许用户临时追加多条输入框，因此需要一个稳定 `id` 区分每一行。
private struct GalleryCustomTagDraft: Identifiable, Equatable {
    let id = UUID()
    var text = ""
}

/// 发帖页里一张待上传或已上传完成的图片草稿。
///
/// Android 端的实现是“先上传得到服务端图片对象，再带 `mid` 发帖”。iOS 这里沿用同样的链路，
/// 因此页面需要显式维护上传状态，而不是只记录一个本地 `UIImage`。
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

    /// 只有上传成功后，图片才会拿到可提交给发帖接口的 `mid`。
    var uploadedImage: GalleryImage? {
        guard case .uploaded(let image) = status else { return nil }
        return image
    }
}

/// 发帖页图片缩略图条目。
///
/// 这里保留 Android 类似的交互语义：
/// - 上传中显示进度
/// - 失败时允许重试
/// - 任意状态都允许删除
struct GalleryComposerImageTile: View {
    let draft: GalleryComposerImageDraft
    let onRetry: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemGroupedBackground))

                if let image = UIImage(data: draft.previewData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottom) {
                overlayContent
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, Color.black.opacity(0.55))
            }
            .padding(6)
            .buttonStyle(.plain)
        }
        .frame(width: 96, height: 96)
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch draft.status {
        case .uploading:
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.45))
                ProgressView()
                    .tint(.white)
            }
            .frame(height: 28)
        case .compressing:
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.45))
                Text("\(draft.progress)%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(height: 28)
        case .prepared:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.35), in: Circle())
        case .uploaded:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("已上传")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.black.opacity(0.35))
        case .failed:
            Button(action: onRetry) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("重试")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.red.opacity(0.82))
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
}

enum ComposerDraftStore {
    private static let directoryName = "ComposerDrafts"

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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func save<T: Encodable>(_ value: T, filename: String) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: directoryURL.appendingPathComponent(filename), options: .atomic)
        } catch {
            // 草稿保存失败不应阻止用户退出。
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
/// 负责标题、正文、标签、声明和可见性设置，并在提交前执行本地敏感词检查。
struct GalleryComposerView: View {
    /// 发帖成功后的回调。
    ///
    /// 调用方通常会在这里刷新当前 feed，并在必要时切回用户刚发帖的分栏。
    let onCreated: () -> Void

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
    /// 系统 `PhotosPicker` 支持一次选择多张图，这里直接保留整批结果，再逐张加入上传队列。
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    /// 已经加入发帖草稿的图片列表。
    @State private var imageDrafts: [GalleryComposerImageDraft] = []
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
    @State private var didRestoreDraft = false

    /// 发帖接口服务。
    private let service = GalleryService()

    /// 内置的推荐标签。
    ///
    /// 这里沿用 Android/Web 的高频场景标签，目的是让首次发帖时不必完全依赖用户自己输入。
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
    /// 结构尽量贴近网页端，但改成更适合 iOS 的原生 `Form` 交互。
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $title)
                    TextField("正文", text: $text, axis: .vertical)
                        .lineLimit(6, reservesSpace: true)
                }

                Section("标签") {
                    // 标签入口保留“两排按钮 + 自定义单独追加输入框”的结构，
                    // 这样既能快速选常用标签，也不会把自定义输入塞进同一行里挤压布局。
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Self.suggestedTags, id: \.self) { tag in
                            Button {
                                toggleTag(tag)
                            } label: {
                                Text(tag)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(selectedTags.contains(tag) ? Color.white : Color.accentColor)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        selectedTags.contains(tag) ? Color.accentColor : Color.accentColor.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            addCustomTagDraft()
                        } label: {
                            Text("自定义")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Color.accentColor.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if !customTagDrafts.isEmpty {
                        // 每条自定义标签都用单独输入行，避免旧版“统一输入框 + 行内删除”
                        // 在移动端上编辑体验混乱。
                        ForEach($customTagDrafts) { $draft in
                            HStack {
                                TextField("自定义标签", text: $draft.text)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                Button {
                                    removeCustomTagDraft(id: draft.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("发布设置") {
                    // 声明列表由服务端控制，便于后续和网页端保持一致。
                    Picker("声明", selection: $selectedClaimID) {
                        ForEach(claims) { claim in
                            Text(claim.text).tag(claim.id)
                        }
                    }

                    Toggle("匿名发布", isOn: $anonymous)
                    Toggle("公开显示", isOn: $isPublic)
                }

                Section("图片") {
                    PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 9, matching: .images) {
                        Label("插入图片", systemImage: "photo.badge.plus")
                    }
                    .disabled(isSubmitting)

                    if hasUploadingImages {
                        Text("图片上传中，上传完成后即可一并发布。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("发布帖子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { requestDismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSubmitting ? "发布中" : "发布") {
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
            .onAppear { restoreDraftIfNeeded() }
            .alert("保存草稿？", isPresented: $isShowingDraftAlert) {
                Button("保存草稿") {
                    saveDraft()
                    dismiss()
                }
                Button("不保存", role: .destructive) {
                    ComposerDraftStore.removeGallery()
                    dismiss()
                }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("退出后下次可以继续编辑。")
            }
            .diagnosticAlert(item: $alert)
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

    private func restoreDraftIfNeeded() {
        guard !didRestoreDraft else { return }
        didRestoreDraft = true
        guard let draft = ComposerDraftStore.loadGallery() else { return }

        title = draft.title
        text = draft.text
        selectedTags = draft.selectedTags
        customTagDrafts = draft.customTags.map { tag in
            var draft = GalleryCustomTagDraft()
            draft.text = tag
            return draft
        }
        anonymous = draft.anonymous
        isPublic = draft.isPublic
        selectedClaimID = draft.selectedClaimID
        imageDrafts = draft.images.map {
            GalleryComposerImageDraft(
                previewData: $0.previewData,
                filename: $0.filename,
                uploadData: $0.uploadData,
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
    /// 上传中的图片不能提交，否则会出现 Android 端同样会拦掉的 “upload image error” 场景。
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
    /// 这里故意吞掉接口失败：声明列表加载失败不应该阻止用户发帖，
    /// 页面会继续使用默认的“无声明”占位。
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
            if selectedClaimID == 0 {
                selectedClaimID = claims.first?.id ?? 0
            }
        }
    }

    /// 在本地校验通过后提交帖子。
    ///
    /// 提交顺序刻意设计为：
    /// 1. 先做纯本地校验，尽量在发请求前拦掉明显错误。
    /// 2. 再进入提交态，防止重复点击。
    /// 3. 服务端成功后先通知调用方刷新，再关闭当前页面。
    private func submit() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = combinedTags()

        guard !trimmedTitle.isEmpty else {
            alert = AppAlert(title: "发布失败", message: "标题不能为空。")
            return
        }
        guard !trimmedText.isEmpty else {
            alert = AppAlert(title: "发布失败", message: "正文不能为空。")
            return
        }
        guard tags.count >= 2 else {
            alert = AppAlert(title: "发布失败", message: "请至少添加 2 个标签。")
            return
        }
        if let message = CommunityModeration.validateDraft(title: trimmedTitle, text: trimmedText, tags: tags) {
            alert = AppAlert(title: "内容不合规", message: message)
            return
        }
        guard !hasUploadingImages else {
            alert = AppAlert(title: "发布失败", message: "图片仍在上传，请稍候。")
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
            _ = try await service.createPoster(
                title: trimmedTitle,
                text: trimmedText,
                imageMids: uploadedImages.map(\.mid),
                anonymous: anonymous,
                tags: tags,
                claimID: selectedClaimID,
                isPublic: isPublic
            )
            ComposerDraftStore.removeGallery()
            onCreated()
            dismiss()
        } catch {
            alert = AppAlert(title: "发布失败", message: error.localizedDescription)
        }
    }

    /// 切换预置标签的选中状态。
    ///
    /// 预置标签和自定义标签是两套来源，因此这里只处理预置集合本身，不直接碰自定义输入行。
    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.removeAll { $0 == tag }
        } else {
            addTag(tag)
        }
    }

    /// 添加一个新的预置标签，同时负责去重和数量上限。
    ///
    /// 数量上限与最终提交限制保持一致，这样用户在编辑阶段就能感知规则，
    /// 不必等到点击“发布”时才发现标签超限。
    private func addTag(_ tag: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !selectedTags.contains(normalized) else { return }
        guard selectedTags.count < 10 else { return }
        selectedTags.append(normalized)
    }

    /// 追加一条新的自定义标签输入行。
    ///
    /// 这里用“预置标签数 + 输入行数”共同限制上限，是为了避免用户先连点十几次
    /// “自定义”，最后再发现无法提交。
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
    /// 这里故意按顺序处理：图片最终仍然会很快并发上传完，但顺序更稳定，
    /// 发帖页里的缩略图排列也更接近用户在系统相册里点选的顺序。
    private func addImages(from items: [PhotosPickerItem]) async {
        defer { selectedPhotoItems = [] }

        for item in items {
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
            var draft = GalleryComposerImageDraft(previewData: data, filename: filename)
            imageDrafts.append(draft)

            do {
                let image = try await service.uploadImage(data: data, filename: filename)
                draft.status = .uploaded(image)
            } catch {
                draft.status = .failed(error.localizedDescription)
            }

            replaceImageDraft(draft)
        } catch {
            alert = AppAlert(title: "图片添加失败", message: error.localizedDescription)
        }
    }

    /// 失败图片的重试上传。
    private func retryImageUpload(id: GalleryComposerImageDraft.ID) async {
        guard var draft = imageDrafts.first(where: { $0.id == id }) else { return }
        draft.status = .uploading
        replaceImageDraft(draft)

        do {
            let image = try await service.uploadImage(data: draft.previewData, filename: draft.filename)
            draft.status = .uploaded(image)
        } catch {
            draft.status = .failed(error.localizedDescription)
        }

        replaceImageDraft(draft)
    }

    /// 删除一张草稿图片。
    private func removeImageDraft(id: GalleryComposerImageDraft.ID) {
        imageDrafts.removeAll { $0.id == id }
    }

    /// 按 `id` 回写图片草稿。
    private func replaceImageDraft(_ draft: GalleryComposerImageDraft) {
        guard let index = imageDrafts.firstIndex(where: { $0.id == draft.id }) else { return }
        imageDrafts[index] = draft
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
