import Combine
import CommunityCore
import CommunityTransport
import CommunityUI
import DesignSystemKit
import Foundation
import OSLog
import TransportCore

nonisolated struct GalleryCustomTagDraft: Identifiable, Sendable {
    let id = UUID()
    var text = ""
}

/// 发帖场景持有编辑、草稿与上传状态，异步结果核对账号和页面生命周期。
@MainActor
final class GalleryComposerViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "BIT101", category: "GalleryComposer")
    static let maximumImageCount = ComposerDraftImagePolicy.maximumImageCount
    @Published var title: String
    @Published var text: String
    @Published var selectedTags: [String]
    @Published var customTagDrafts: [GalleryCustomTagDraft] = []
    @Published var anonymous: Bool
    @Published var isPublic: Bool
    @Published var selectedClaimID: Int
    let imageUploads: ComposerImageUploads
    var imageDrafts: [ComposerImageDraft] { imageUploads.drafts }
    @Published private(set) var existingImages: [CommunityImage]
    @Published private(set) var claims = [CommunityClaim(id: 0, text: "无声明")]
    var isAddingImages: Bool { imageUploads.isAddingImages }
    @Published private(set) var isLoadingClaims = false
    @Published private(set) var claimsLoadError: String?
    @Published private(set) var isSubmitting = false
    @Published private(set) var isSavingDraft = false
    @Published private(set) var isDiscardingDraft = false
    @Published private(set) var isRestoringDraft = false
    @Published var alert: AppAlert?
    let editingPoster: GalleryPosterDetail?

    private let service: any GalleryComposerServicing
    private let drafts: any GalleryComposerDraftStoring
    private let currentIdentity: () -> CommunitySessionIdentity
    private let owner: CommunitySessionIdentity
    private let prepareImageData: (Data) async -> Data?
    private var generation = 0
    private var didCheckDraft = false
    private var didLoadClaims = false
    private var retainedClaim: CommunityClaim?
    private var imageObservation: AnyCancellable?
    private var imageErrorObservation: AnyCancellable?
    private var submissionTask: Task<Bool, Never>?
    private var createResultNeedsReview = false
    private var didPublish = false
    private var savingTask: Task<Bool, Never>?

    init(editingPoster: GalleryPosterDetail? = nil, service: any GalleryComposerServicing,
         images: any GalleryImageUploading, drafts: any GalleryComposerDraftStoring,
         currentIdentity: @escaping () -> CommunitySessionIdentity, prepareImageData: @escaping (Data) async -> Data?) {
        self.editingPoster = editingPoster
        retainedClaim = editingPoster?.claim
        self.service = service
        let imageOwner = currentIdentity()
        imageUploads = ComposerImageUploads(upload: { try await images.uploadImage(data: $0, filename: $1) },
            prepare: { data in
                guard let prepared = await prepareImageData(data) else { throw GalleryServiceError.uploadFailed }
                return prepared
            }, isCurrentSession: { currentIdentity() == imageOwner })
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
        imageObservation = imageUploads.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        imageErrorObservation = imageUploads.$errorMessage.compactMap { $0 }.sink { [weak self] message in
            self?.alert = AppAlert(title: "图片添加失败", message: message)
        }
    }

    deinit {
        submissionTask?.cancel()
        savingTask?.cancel()
    }

    func cancelPendingOperations() {
        generation &+= 1
        imageUploads.cancel()
        submissionTask?.cancel()
        submissionTask = nil
        savingTask?.cancel()
        savingTask = nil
        isSubmitting = false
        isSavingDraft = false
        isDiscardingDraft = false
        isRestoringDraft = false
        isLoadingClaims = false
    }

    private func isCurrent(_ operation: Int) -> Bool {
        generation == operation && owner == currentIdentity() && !Task.isCancelled
    }

    var hasDraftContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedTags.isEmpty || !customTagDrafts.isEmpty || !imageDrafts.isEmpty
            || anonymous || !isPublic || selectedClaimID != 0 || isAddingImages
    }

    var hasUnsavedEdits: Bool {
        guard let original = editingPoster else { return false }
        return title != original.title || text != original.text || selectedTags != original.tags ||
            customTagDrafts.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ||
            anonymous != original.anonymous || isPublic != original.public || selectedClaimID != original.claim.id ||
            existingImages != original.images || !imageDrafts.isEmpty || isAddingImages
    }

    var hasUploadingImages: Bool { imageDrafts.contains { $0.isUploading } }
    var hasPublishedContent: Bool { didPublish }

    var isBusy: Bool { isSubmitting || isSavingDraft || isDiscardingDraft || isRestoringDraft }

    var draftSnapshot: GalleryComposerDraftSnapshot {
        GalleryComposerDraftSnapshot(title: title, text: text, selectedTags: selectedTags,
            customTags: customTagDrafts.map(\.text), anonymous: anonymous, isPublic: isPublic,
            selectedClaimID: selectedClaimID, images: imageDrafts.map {
                .init(filename: $0.filename, previewData: $0.previewData, uploadData: $0.uploadData, uploadedImage: $0.uploadedImage)
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
        guard editingPoster == nil, !isBusy, !isAddingImages, !hasUploadingImages,
              !didPublish, isCurrent(operation) else { return }
        isRestoringDraft = true
        defer { if generation == operation { isRestoringDraft = false } }
        let result = await drafts.loadGallery()
        guard isCurrent(operation) else { return }
        presentRecovery(result)
        guard let draft = result.snapshot else { return }
        var restored: [ComposerImageDraft] = []
        for image in draft.images {
            let uploadData: Data?
            if let data = image.uploadData { uploadData = data }
            else if image.uploadedImage == nil { uploadData = await prepareImageData(image.previewData) }
            else { uploadData = nil }
            guard isCurrent(operation) else { return }
            restored.append(ComposerImageDraft(previewData: image.previewData, filename: image.filename,
                uploadData: uploadData, status: image.uploadedImage.map(ComposerImageDraft.Status.uploaded) ?? .failed("需要重新上传")))
        }
        title = draft.title
        text = draft.text
        selectedTags = draft.selectedTags
        customTagDrafts = draft.customTags.map { GalleryCustomTagDraft(text: $0) }
        anonymous = draft.anonymous
        isPublic = draft.isPublic
        selectedClaimID = draft.selectedClaimID
        let savedClaim = claims.first { $0.id == draft.selectedClaimID }
            ?? CommunityClaim(id: draft.selectedClaimID, text: "已保存的声明")
        retainedClaim = savedClaim
        if !claims.contains(where: { $0.id == savedClaim.id }) { claims.append(savedClaim) }
        imageUploads.restore(restored)
    }

    private func presentRecovery(_ result: ComposerDraftLoadResult<GalleryComposerDraftSnapshot>) {
        if let message = result.recoveryMessage {
            alert = .informational(title: "发帖草稿恢复需要处理", message: message)
        }
    }

    func discardDraft() async -> Bool {
        let operation = generation
        guard !isBusy, !didPublish, isCurrent(operation) else { return false }
        isDiscardingDraft = true
        defer { if generation == operation { isDiscardingDraft = false } }
        let removed = await drafts.removeGallery()
        guard isCurrent(operation) else { return false }
        if !removed {
            alert = .informational(title: "草稿清理遇到问题", message: "当前页面内容已保留，请稍后重试清理。")
        }
        return removed
    }

    func saveDraft() async -> Bool {
        let operation = generation
        guard editingPoster == nil, !isBusy, !didPublish, isCurrent(operation) else { return false }
        isSavingDraft = true
        let task = Task { [self] in
            await imageUploads.waitForImport()
            guard isCurrent(operation) else { return false }
            let snapshot = draftSnapshot
            let saved = await drafts.saveGallery(snapshot)
            guard isCurrent(operation) else { return false }
            if !saved {
                let recovery = await drafts.loadGallery()
                guard isCurrent(operation) else { return false }
                presentRecovery(recovery)
                if recovery.recoveryMessage == nil {
                    alert = .informational(title: "草稿暂存遇到问题", message: "当前页面内容已保留，请稍后重试保存。")
                }
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
            claimsLoadError = nil
            if !fetched.isEmpty {
                claims = fetched.sorted { $0.id < $1.id }
                if let retainedClaim, !claims.contains(where: { $0.id == retainedClaim.id }) {
                    claims.append(retainedClaim)
                }
                if !claims.contains(where: { $0.id == selectedClaimID }) { selectedClaimID = claims.first?.id ?? 0 }
            }
        } catch {
            guard isCurrent(operation), !TaskCancellation.matches(error) else { return }
            claimsLoadError = error.localizedDescription
        }
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

    func removeImageDraft(id: ComposerImageDraft.ID) { imageUploads.remove(id: id) }

    func addImages(from sources: [@MainActor () async throws -> Data?]) async {
        guard !isBusy, isCurrent(generation) else { return }
        await imageUploads.addImages(from: sources, existingImageCount: existingImages.count)
    }

    func retryImageUpload(id: ComposerImageDraft.ID) async {
        guard !isBusy, isCurrent(generation) else { return }
        await imageUploads.retry(id: id)
    }

    var submitTitle: String {
        if isSubmitting { return "保存中" }
        if didPublish { return "已发布" }
        return editingPoster == nil ? "发布" : "保存"
    }

    func submit() async -> Bool {
        let operation = generation
        guard !isBusy, isCurrent(operation) else { return false }
        if didPublish { return true }
        guard !createResultNeedsReview else {
            alert = AppAlert(title: "发布结果待确认", message: CommunityCreateOutcomeUnknown.reviewMessage)
            return false
        }
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
                        plugins: editingPoster.plugins, anonymous: anonymous, tags: tags, claimID: claimID, isPublic: isPublic)
                } else {
                    _ = try await service.createPoster(title: title, text: text, imageMids: mids,
                        anonymous: anonymous, tags: tags, claimID: claimID, isPublic: isPublic)
                    createResultNeedsReview = true
                }
                guard isCurrent(operation) else { return false }
                if let cleanup {
                    didPublish = true
                    Task {
                        if await cleanup() == false { Self.logger.error("已发布内容的草稿清理受阻，保留原草稿供后续处理。") }
                    }
                }
                return isCurrent(operation)
            } catch {
                if isCurrent(operation), error is CommunityCreateOutcomeUnknown {
                    createResultNeedsReview = true
                    alert = AppAlert(title: "发布结果待确认", error: error)
                    return false
                }
                if isCurrent(operation), !TaskCancellation.matches(error) {
                    alert = AppAlert(title: "发布失败", error: error)
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
