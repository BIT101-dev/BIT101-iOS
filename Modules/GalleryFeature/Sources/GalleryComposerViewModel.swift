import Combine
import CommunityCore
import CommunityTransport
import DesignSystemKit
import Foundation
import TransportCore

nonisolated struct GalleryCustomTagDraft: Identifiable, Sendable {
    let id = UUID()
    var text = ""
}

/// 发帖场景持有编辑、草稿与上传状态，异步结果核对账号和页面生命周期。
@MainActor
final class GalleryComposerViewModel: ObservableObject {
    static let maximumImageCount = ComposerDraftImagePolicy.maximumImageCount
    @Published var title: String
    @Published var text: String
    @Published var selectedTags: [String]
    @Published var customTagDrafts: [GalleryCustomTagDraft] = []
    @Published var anonymous: Bool
    @Published var isPublic: Bool
    @Published var selectedClaimID: Int
    @Published private(set) var imageDrafts: [ComposerImageDraft] = []
    @Published private(set) var existingImages: [CommunityImage]
    @Published private(set) var claims = [CommunityClaim(id: 0, text: "无声明")]
    @Published private(set) var isAddingImages = false
    @Published private(set) var isLoadingClaims = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var isSavingDraft = false
    @Published var alert: AppAlert?
    let editingPoster: GalleryPosterDetail?

    private let service: any GalleryComposerServicing
    private let images: any GalleryImageUploading
    private let drafts: any GalleryComposerDraftStoring
    private let currentIdentity: () -> CommunitySessionIdentity
    private let owner: CommunitySessionIdentity
    private let prepareImageData: (Data) async -> Data?
    private var generation = 0
    private var didCheckDraft = false
    private var didLoadClaims = false
    private var imageBatchTask: Task<Void, Never>?
    private var uploads: [UUID: Task<Void, Never>] = [:]
    private var submissionTask: Task<Bool, Never>?
    private var savingTask: Task<Bool, Never>?

    init(editingPoster: GalleryPosterDetail? = nil, service: any GalleryComposerServicing,
         images: any GalleryImageUploading, drafts: any GalleryComposerDraftStoring,
         currentIdentity: @escaping () -> CommunitySessionIdentity, prepareImageData: @escaping (Data) async -> Data?) {
        self.editingPoster = editingPoster
        self.service = service
        self.images = images
        self.drafts = drafts
        self.currentIdentity = currentIdentity
        self.owner = currentIdentity()
        self.prepareImageData = prepareImageData
        title = editingPoster?.title ?? ""
        text = editingPoster?.text ?? ""
        selectedTags = editingPoster?.tags ?? []
        anonymous = editingPoster?.anonymous ?? false
        isPublic = editingPoster?.public ?? true
        selectedClaimID = editingPoster?.claim.id ?? 0
        existingImages = editingPoster?.images ?? []
    }

    deinit {
        imageBatchTask?.cancel()
        for task in uploads.values { task.cancel() }
        submissionTask?.cancel()
        savingTask?.cancel()
    }

    func cancelPendingOperations() {
        generation &+= 1
        imageBatchTask?.cancel()
        imageBatchTask = nil
        for task in uploads.values { task.cancel() }
        uploads.removeAll()
        submissionTask?.cancel()
        submissionTask = nil
        savingTask?.cancel()
        savingTask = nil
        for index in imageDrafts.indices where imageDrafts[index].isUploading {
            imageDrafts[index].status = .failed("上传已暂停，请重试。")
        }
        isAddingImages = false
        isSubmitting = false
        isSavingDraft = false
        isLoadingClaims = false
    }

    private func isCurrent(_ operation: Int) -> Bool {
        generation == operation && owner == currentIdentity() && !Task.isCancelled
    }

    var hasDraftContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedTags.isEmpty || !customTagDrafts.isEmpty || !imageDrafts.isEmpty
            || anonymous || !isPublic || selectedClaimID != 0
    }

    var hasUploadingImages: Bool { imageDrafts.contains { $0.isUploading } }

    var draftSnapshot: GalleryComposerDraftSnapshot {
        GalleryComposerDraftSnapshot(title: title, text: text, selectedTags: selectedTags,
            customTags: customTagDrafts.map(\.text), anonymous: anonymous, isPublic: isPublic,
            selectedClaimID: selectedClaimID, images: imageDrafts.map {
                .init(filename: $0.filename, previewData: $0.previewData, uploadData: $0.uploadData)
            })
    }

    func checkDraftOnAppear() async -> Bool {
        let operation = generation
        guard editingPoster == nil, !didCheckDraft, isCurrent(operation) else { return false }
        let result = await drafts.loadGallery()
        guard isCurrent(operation) else { return false }
        didCheckDraft = true
        presentRecovery(result)
        return result.snapshot != nil
    }

    func restoreDraft() async {
        let operation = generation
        guard editingPoster == nil, isCurrent(operation) else { return }
        let result = await drafts.loadGallery()
        guard isCurrent(operation) else { return }
        presentRecovery(result)
        guard let draft = result.snapshot else { return }
        title = draft.title
        text = draft.text
        selectedTags = draft.selectedTags
        customTagDrafts = draft.customTags.map { GalleryCustomTagDraft(text: $0) }
        anonymous = draft.anonymous
        isPublic = draft.isPublic
        selectedClaimID = draft.selectedClaimID
        var restored: [ComposerImageDraft] = []
        for image in draft.images {
            let uploadData: Data?
            if let data = image.uploadData { uploadData = data }
            else { uploadData = await prepareImageData(image.previewData) }
            guard isCurrent(operation) else { return }
            restored.append(ComposerImageDraft(previewData: image.previewData, filename: image.filename,
                uploadData: uploadData, status: .failed("需要重新上传")))
        }
        imageDrafts = restored
    }

    private func presentRecovery(_ result: ComposerDraftLoadResult<GalleryComposerDraftSnapshot>) {
        if let message = result.recoveryMessage {
            alert = .informational(title: "发帖草稿恢复需要处理", message: message)
        }
    }

    func discardDraft() async -> Bool {
        let operation = generation
        guard isCurrent(operation) else { return false }
        await drafts.removeGallery()
        return isCurrent(operation)
    }

    func saveDraft() async -> Bool {
        let operation = generation
        guard editingPoster == nil, savingTask == nil, isCurrent(operation) else { return false }
        let snapshot = draftSnapshot
        isSavingDraft = true
        let task = Task { [self] in
            let result = await drafts.loadGallery()
            guard isCurrent(operation) else { return false }
            presentRecovery(result)
            guard result.allowsWrite else { return false }
            let saved = await drafts.saveGallery(snapshot)
            guard isCurrent(operation) else { return false }
            if !saved {
                alert = .informational(title: "草稿暂存遇到问题", message: "当前页面内容已保留，请稍后重试保存。")
            }
            return saved
        }
        savingTask = task
        defer { if generation == operation { savingTask = nil; isSavingDraft = false } }
        let saved = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return saved && isCurrent(operation)
    }

    func loadClaimsIfNeeded() async {
        let operation = generation
        guard !didLoadClaims, !isLoadingClaims, isCurrent(operation) else { return }
        isLoadingClaims = true
        defer { if generation == operation { isLoadingClaims = false } }
        do {
            let fetched = try await service.fetchClaims()
            guard isCurrent(operation) else { return }
            didLoadClaims = true
            if !fetched.isEmpty {
                claims = fetched.sorted { $0.id < $1.id }
                if !claims.contains(where: { $0.id == selectedClaimID }) { selectedClaimID = claims.first?.id ?? 0 }
            }
        } catch { return }
    }

    func combinedTags() -> [String] {
        var seen = Set<String>()
        return Array((selectedTags + customTagDrafts.map(\.text))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(10))
    }

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) { selectedTags.removeAll { $0 == tag } }
        else if selectedTags.count + customTagDrafts.count < 10 { selectedTags.append(tag) }
    }

    func addCustomTagDraft() {
        guard selectedTags.count + customTagDrafts.count < 10 else { return }
        customTagDrafts.append(GalleryCustomTagDraft())
    }

    func removeCustomTagDraft(id: GalleryCustomTagDraft.ID) { customTagDrafts.removeAll { $0.id == id } }
    func removeExistingImage(id: CommunityImage.ID) { existingImages.removeAll { $0.id == id } }

    func removeImageDraft(id: ComposerImageDraft.ID) {
        uploads.removeValue(forKey: id)?.cancel()
        imageDrafts.removeAll { $0.id == id }
    }

    func addImages(from sources: [@MainActor () async throws -> Data?]) async {
        let operation = generation
        guard imageBatchTask == nil, !isSubmitting, isCurrent(operation) else { return }
        isAddingImages = true
        let task = Task { [self] in
            let remaining = max(0, Self.maximumImageCount - existingImages.count - imageDrafts.count)
            for source in sources.prefix(remaining) {
                guard isCurrent(operation) else { return }
                do {
                    let sourceData = try await source()
                    guard isCurrent(operation) else { return }
                    guard let data = sourceData else { throw GalleryServiceError.uploadFailed }
                    let prepared = await prepareImageData(data)
                    guard isCurrent(operation) else { return }
                    guard let prepared else { throw GalleryServiceError.uploadFailed }
                    let draft = ComposerImageDraft(previewData: prepared, filename: "poster-\(UUID().uuidString).jpg", uploadData: prepared)
                    imageDrafts.append(draft)
                    await retryImageUpload(id: draft.id)
                } catch {
                    guard isCurrent(operation), !TaskCancellation.matches(error) else { return }
                    alert = AppAlert(title: "图片添加失败", message: error.localizedDescription)
                }
            }
        }
        imageBatchTask = task
        defer { if generation == operation { imageBatchTask = nil; isAddingImages = false } }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func retryImageUpload(id: ComposerImageDraft.ID) async {
        let operation = generation
        guard uploads[id] == nil, isCurrent(operation),
              let index = imageDrafts.firstIndex(where: { $0.id == id }) else { return }
        let draft = imageDrafts[index]
        imageDrafts[index].status = .uploading
        let task = Task { [self] in
            let status: ComposerImageDraft.Status
            do {
                status = .uploaded(try await images.uploadImage(data: draft.uploadData ?? draft.previewData, filename: draft.filename))
            } catch {
                guard !TaskCancellation.matches(error) else { return }
                status = .failed(error.localizedDescription)
            }
            guard isCurrent(operation), let index = imageDrafts.firstIndex(where: { $0.id == id }) else { return }
            imageDrafts[index].status = status
        }
        uploads[id] = task
        defer { if generation == operation { uploads[id] = nil } }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func submit() async -> Bool {
        let operation = generation
        guard submissionTask == nil, isCurrent(operation) else { return false }
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = combinedTags()
        let uploaded = imageDrafts.compactMap(\.uploadedImage)
        let issue: String?
        if title.isEmpty { issue = "请填写标题。" }
        else if text.isEmpty { issue = "请填写正文。" }
        else if tags.count < 2 { issue = "请至少添加 2 个标签。" }
        else if isAddingImages || hasUploadingImages { issue = "图片仍在上传，请稍候。" }
        else if uploaded.count != imageDrafts.count { issue = "请重试上传失败的图片，或移除图片后继续。" }
        else { issue = nil }
        if let issue { alert = .userInput(title: "发布失败", message: issue); return false }
        let mids = existingImages.map(\.mid) + uploaded.map(\.mid)
        let anonymous = self.anonymous
        let isPublic = self.isPublic
        let claimID = selectedClaimID
        isSubmitting = true
        let task = Task { [self] in
            let cleanup = editingPoster == nil ? await drafts.captureGalleryCleanup() : nil
            guard isCurrent(operation) else { return false }
            do {
                if let editingPoster {
                    try await service.updatePoster(id: editingPoster.id, title: title, text: text, imageMids: mids,
                        anonymous: anonymous, tags: tags, claimID: claimID, isPublic: isPublic)
                } else {
                    _ = try await service.createPoster(title: title, text: text, imageMids: mids,
                        anonymous: anonymous, tags: tags, claimID: claimID, isPublic: isPublic)
                }
                guard isCurrent(operation) else { return false }
                if let cleanup { await cleanup() }
                return isCurrent(operation)
            } catch {
                if isCurrent(operation), !TaskCancellation.matches(error) {
                    alert = AppAlert(title: "发布失败", message: error.localizedDescription)
                }
                return false
            }
        }
        submissionTask = task
        defer { if generation == operation { submissionTask = nil; isSubmitting = false } }
        let submitted = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return submitted && isCurrent(operation)
    }
}

private nonisolated extension ComposerImageDraft {
    var isUploading: Bool {
        if case .uploading = status { return true }
        return false
    }
}
