import BIT101TestSupport
import CommunityCore
import CommunityTransport
import Foundation
@testable import GalleryFeature
import Testing

@MainActor
struct ComposerLifecycleTests {
    private final class Gate {
        private var pending: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { pending = $0 }
        }
        func waitUntilPaused() async throws {
            try await waitForTestEvent { pending != nil }
        }
        func resume() { pending?.resume(); pending = nil }
    }

    private final class Identity {
        var current = CommunitySessionIdentity(accountIdentifier: "composer-A", generation: 1)
    }

    private final class Drafts: GalleryComposerDraftStoring {
        var result: ComposerDraftLoadResult<GalleryComposerDraftSnapshot> = .missing
        var loadCount = 0
        var saveCount = 0
        var cleanupCount = 0
        var cleanupAttempts = 0
        var removalCount = 0
        var revision = 0
        var failsSaving = false
        var failsRemoval = false
        var readGate: Gate?
        var saveGate: Gate?
        var removalGate: Gate?
        func loadGallery() async -> ComposerDraftLoadResult<GalleryComposerDraftSnapshot> {
            loadCount += 1
            let result = result
            let gate = readGate
            readGate = nil
            await gate?.pause()
            return result
        }
        func saveGallery(_ snapshot: GalleryComposerDraftSnapshot) async -> Bool {
            saveCount += 1
            let gate = saveGate
            saveGate = nil
            await gate?.pause()
            guard !failsSaving, result.allowsWrite else { return false }
            revision += 1
            result = .loaded(snapshot)
            return true
        }
        func removeGallery() async -> Bool {
            removalCount += 1
            let gate = removalGate
            removalGate = nil
            await gate?.pause()
            guard !failsRemoval else { return false }
            revision += 1; result = .missing
            return true
        }
        func captureGalleryCleanup() async -> ComposerDraftCleanup {
            let captured = revision
            return { await self.removeSubmittedRevision(captured) }
        }
        private func removeSubmittedRevision(_ captured: Int) -> Bool {
            cleanupAttempts += 1
            guard revision == captured else { return true }
            guard !failsRemoval else { return false }
            cleanupCount += 1; revision += 1; result = .missing
            return true
        }
    }

    private final class Service: GalleryComposerServicing {
        struct Payload {
            let id: Int?
            let title: String
            let text: String
            let mids: [String]
            let tags: [String]
            let anonymous: Bool
            let claimID: Int
            let isPublic: Bool
            let plugins: String
        }
        var claims = [CommunityClaim(id: 3, text: "声明"), CommunityClaim(id: 0, text: "无声明")]
        var failsClaims = false
        var failsSubmission = false
        var unknownSubmission = false
        var uploadFailures = 0
        var claimsCount = 0
        var uploads: [Data] = []
        var submissions: [Payload] = []
        var uploadGate: Gate?
        var submissionGate: Gate?
        var claimsGate: Gate?
        func fetchClaims() async throws -> [CommunityClaim] {
            claimsCount += 1
            let gate = claimsGate
            claimsGate = nil
            await gate?.pause()
            if failsClaims { throw URLError(.notConnectedToInternet) }
            return claims
        }
        func uploadImage(data: Data, filename: String) async throws -> CommunityImage {
            uploads.append(data)
            let gate = uploadGate
            uploadGate = nil
            await gate?.pause()
            if uploadFailures > 0 { uploadFailures -= 1; throw URLError(.networkConnectionLost) }
            return CommunityImage(mid: "image-\(uploads.count)", url: "https://example.invalid/image.jpg", lowUrl: "")
        }
        func createPoster(title: String, text: String, imageMids: [String], anonymous: Bool, tags: [String], claimID: Int, isPublic: Bool) async throws -> Int {
            try await send(.init(id: nil, title: title, text: text, mids: imageMids, tags: tags, anonymous: anonymous, claimID: claimID, isPublic: isPublic, plugins: "[]"))
            return 42
        }
        func updatePoster(id: Int, title: String, text: String, imageMids: [String], plugins: String, anonymous: Bool, tags: [String], claimID: Int, isPublic: Bool) async throws {
            try await send(.init(id: id, title: title, text: text, mids: imageMids, tags: tags, anonymous: anonymous, claimID: claimID, isPublic: isPublic, plugins: plugins))
        }
        private func send(_ payload: Payload) async throws {
            submissions.append(payload)
            let gate = submissionGate
            submissionGate = nil
            await gate?.pause()
            if failsSubmission { throw URLError(.notConnectedToInternet) }
            if unknownSubmission { throw CommunityCreateOutcomeUnknown(underlying: URLError(.networkConnectionLost)) }
        }
    }

    private func model(_ service: Service = Service(), drafts: Drafts = Drafts(), identity: Identity = Identity(),
                       editing: GalleryPosterDetail? = nil, uploader: Service? = nil,
                       prepare: @escaping (Data) async -> Data? = { $0 }) -> GalleryComposerViewModel {
        GalleryComposerViewModel(editingPoster: editing, service: service, images: uploader ?? service, drafts: drafts,
            currentIdentity: { identity.current }, prepareImageData: prepare)
    }
    private func valid(_ model: GalleryComposerViewModel) {
        model.title = " 标题 "
        model.text = " 正文 "
        model.selectedTags = ["校园", "生活"]
    }
    private func snapshot() -> GalleryComposerDraftSnapshot {
        .init(title: "草稿标题", text: "草稿正文", selectedTags: ["校园"], customTags: ["自定义"], anonymous: true,
            isPublic: false, selectedClaimID: 3, images: [.init(filename: "saved.jpg", previewData: Data([7]), uploadData: nil)])
    }
    private func poster(images: [CommunityImage] = [], plugins: String = "[]") -> GalleryPosterDetail {
        .init(anonymous: true, claim: .init(id: 3, text: "声明"), commentNum: 0, createTime: "", editTime: "", id: 42,
            images: images, like: false, likeNum: 0, own: true, plugins: plugins, public: false,
            tags: ["校园", "生活"], text: "帖子正文", title: "帖子标题", updateTime: "", user: .placeholder(id: 1, nickname: "作者"))
    }

    @Test func tagEditingNormalizesDeduplicatesAndSharesTheLimit() {
        let viewModel = model()
        #expect(viewModel.hasDraftContent == false)
        viewModel.selectedTags = [" 校园 ", "生活"]
        viewModel.customTagDrafts = [.init(text: "校园"), .init(text: " "), .init(text: " 自定义 ")]
        #expect(viewModel.combinedTags() == ["校园", "生活", "自定义"])
        viewModel.customTagDrafts = []
        viewModel.selectedTags = (0..<10).map(String.init)
        viewModel.toggleTag("额外")
        viewModel.addCustomTagDraft()
        #expect(viewModel.selectedTags.count == 10)
        #expect(viewModel.customTagDrafts.isEmpty)
        viewModel.toggleTag("0")
        viewModel.addCustomTagDraft()
        let id = viewModel.customTagDrafts[0].id
        viewModel.removeCustomTagDraft(id: id)
        #expect(viewModel.customTagDrafts.isEmpty)
        #expect(viewModel.hasDraftContent)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["title", "text", "tags"])
    func requiredInputsStayInTheEditor(_ field: String) async {
        let service = Service()
        let viewModel = model(service)
        valid(viewModel)
        if field == "title" { viewModel.title = " " }
        if field == "text" { viewModel.text = " " }
        if field == "tags" { viewModel.selectedTags = ["校园"] }
        #expect(await viewModel.submit() == false)
        #expect(viewModel.alert?.allowsDiagnostics == false)
        #expect(service.submissions.isEmpty)
        #expect(viewModel.isSubmitting == false)
    }

    @Test(.timeLimit(.minutes(1))) func claimsAreSortedSelectedAndLoadedOnce() async {
        let service = Service()
        let viewModel = model(service)
        viewModel.selectedClaimID = 99
        await viewModel.loadClaimsIfNeeded()
        await viewModel.loadClaimsIfNeeded()
        #expect(viewModel.claims.map(\.id) == [0, 3])
        #expect(viewModel.selectedClaimID == 0)
        #expect(service.claimsCount == 1)
        #expect(viewModel.isLoadingClaims == false)
    }

    @Test(.timeLimit(.minutes(1))) func claimFailuresAllowAnotherAttemptAndKeepDefaults() async {
        let service = Service()
        service.failsClaims = true
        let viewModel = model(service)
        await viewModel.loadClaimsIfNeeded()
        #expect(viewModel.claims.map(\.id) == [0])
        #expect(viewModel.alert == nil && viewModel.claimsLoadError != nil)
        service.failsClaims = false
        service.claims = []
        await viewModel.loadClaimsIfNeeded()
        #expect(service.claimsCount == 2 && viewModel.claimsLoadError == nil)
        #expect(viewModel.claims.map(\.id) == [0])
    }

    @Test(.timeLimit(.minutes(1))) func draftRestoreOwnsFieldsImagesAndTheOneTimePrompt() async {
        let drafts = Drafts()
        drafts.result = .loaded(snapshot())
        let viewModel = model(drafts: drafts, prepare: { Data([42]) + $0 })
        #expect(await viewModel.checkDraftOnAppear())
        #expect(await viewModel.checkDraftOnAppear() == false)
        #expect(drafts.loadCount == 1)
        await viewModel.restoreDraft()
        #expect(viewModel.title == "草稿标题")
        #expect(viewModel.combinedTags() == ["校园", "自定义"])
        #expect(viewModel.anonymous && viewModel.isPublic == false)
        #expect(viewModel.selectedClaimID == 3)
        #expect(viewModel.imageDrafts.first?.uploadData == Data([42, 7]))
        #expect(viewModel.imageDrafts.first?.uploadedImage == nil)
        #expect(viewModel.draftSnapshot.customTags == ["自定义"])
        #expect(await viewModel.saveDraft())
        #expect(drafts.result.snapshot?.images.first?.uploadData == Data([42, 7]))
    }

    @Test(.timeLimit(.minutes(1))) func recoveryPausesSavingAndPreservesLiveEditing() async {
        for result: ComposerDraftLoadResult<GalleryComposerDraftSnapshot> in [.unreadable, .unsupportedVersion(2)] {
            let drafts = Drafts()
            drafts.result = result
            let viewModel = model(drafts: drafts)
            valid(viewModel)
            #expect(await viewModel.checkDraftOnAppear() == false)
            await viewModel.restoreDraft()
            #expect(await viewModel.saveDraft() == false)
            #expect(viewModel.alert?.title == "发帖草稿恢复需要处理")
            #expect(viewModel.title == " 标题 ")
            #expect(drafts.saveCount == 1)
            #expect(await viewModel.discardDraft())
            #expect(await viewModel.saveDraft())
        }
    }

    @Test(.timeLimit(.minutes(1))) func failedDiscardPreservesDraftAndKeepsTheEditorOpen() async {
        let drafts = Drafts()
        drafts.result = .loaded(snapshot())
        drafts.failsRemoval = true
        let viewModel = model(drafts: drafts)
        valid(viewModel)
        #expect(await viewModel.discardDraft() == false)
        #expect(drafts.result.snapshot != nil && viewModel.title == " 标题 ")
        #expect(viewModel.alert?.title == "草稿清理遇到问题")
        drafts.failsRemoval = false
        #expect(await viewModel.discardDraft())
        #expect(drafts.result.snapshot == nil && drafts.result.allowsWrite)
    }

    @Test(.timeLimit(.minutes(1))) func failedSavesKeepTheCurrentEditorState() async {
        let drafts = Drafts()
        drafts.failsSaving = true
        let viewModel = model(drafts: drafts)
        valid(viewModel)
        #expect(await viewModel.saveDraft() == false)
        #expect(viewModel.alert?.title == "草稿暂存遇到问题")
        #expect(viewModel.text == " 正文 ")
        #expect(viewModel.isSavingDraft == false)
    }

    @Test(.timeLimit(.minutes(1))) func successfulCreationUsesTheSelectedUploaderAndClearsItsDraft() async throws {
        let service = Service()
        let uploader = Service()
        let drafts = Drafts()
        let viewModel = model(service, drafts: drafts, uploader: uploader, prepare: { Data([42]) + $0 })
        valid(viewModel)
        await viewModel.addImages(from: [{ Data([7]) }])
        #expect(uploader.uploads == [Data([42, 7])])
        #expect(service.uploads.isEmpty)
        #expect(await viewModel.submit())
        #expect(service.submissions.first?.title == "标题")
        #expect(service.submissions.first?.text == "正文")
        #expect(service.submissions.first?.mids == ["image-1"])
        try await waitForTestEvent { drafts.cleanupCount == 1 }
        #expect(drafts.cleanupCount == 1)
        #expect(viewModel.isSubmitting == false)
    }

    @Test(.timeLimit(.minutes(1))) func confirmedPublicationCompletesWhileCleanupFails() async throws {
        let service = Service(), drafts = Drafts()
        drafts.failsRemoval = true
        let viewModel = model(service, drafts: drafts)
        valid(viewModel)
        #expect(await viewModel.submit())
        try await waitForTestEvent { drafts.cleanupAttempts == 1 }
        #expect(service.submissions.count == 1 && viewModel.submitTitle == "已发布")
        #expect(viewModel.hasPublishedContent && !viewModel.isBusy)
        #expect(await viewModel.saveDraft() == false)
        #expect(await viewModel.discardDraft() == false)
        #expect(await viewModel.submit())
        #expect(service.submissions.count == 1 && drafts.cleanupCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func editingPostsPreservesNewPostDraftsAndExistingImages() async {
        let drafts = Drafts()
        drafts.result = .loaded(snapshot())
        let service = Service()
        let image = CommunityImage(mid: "existing", url: "https://example.invalid/image.jpg", lowUrl: "")
        let viewModel = model(service, drafts: drafts, editing: poster(images: [image], plugins: #"[{"type":"future","data":{"value":"preserved"}}]"#))
        #expect(viewModel.title == "帖子标题")
        #expect(viewModel.hasUnsavedEdits == false)
        viewModel.title = "修改标题"
        #expect(viewModel.hasUnsavedEdits)
        viewModel.title = "帖子标题"
        #expect(viewModel.hasUnsavedEdits == false)
        #expect(viewModel.anonymous && viewModel.isPublic == false)
        #expect(await viewModel.checkDraftOnAppear() == false)
        await viewModel.restoreDraft()
        #expect(viewModel.title == "帖子标题")
        #expect(await viewModel.saveDraft() == false)
        #expect(await viewModel.submit())
        #expect(service.submissions.first?.id == 42)
        #expect(service.submissions.first?.mids == ["existing"])
        #expect(service.submissions.first?.plugins == #"[{"type":"future","data":{"value":"preserved"}}]"#)
        #expect(drafts.cleanupCount == 0)
        #expect(drafts.result.snapshot?.title == "草稿标题")
        viewModel.removeExistingImage(id: image.id)
        #expect(viewModel.existingImages.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func failedSubmissionsPreserveDraftsAndAllowRetry() async {
        let service = Service()
        service.failsSubmission = true
        let drafts = Drafts()
        let viewModel = model(service, drafts: drafts)
        valid(viewModel)
        #expect(await viewModel.submit() == false)
        #expect(drafts.cleanupCount == 0)
        #expect(viewModel.alert?.title == "发布失败")
        #expect(viewModel.isSubmitting == false)
        service.failsSubmission = false
        #expect(await viewModel.submit())
        #expect(service.submissions.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func uncertainCreationPreservesItsDraftAndStopsAnotherSubmission() async {
        let service = Service()
        service.unknownSubmission = true
        let drafts = Drafts()
        let viewModel = model(service, drafts: drafts)
        valid(viewModel)
        #expect(await viewModel.submit() == false)
        service.unknownSubmission = false
        #expect(await viewModel.submit() == false)
        #expect(service.submissions.count == 1 && drafts.cleanupCount == 0)
        #expect(viewModel.alert?.title == "发布结果待确认" && !viewModel.isSubmitting)
    }

    @Test(.timeLimit(.minutes(1))) func imageFailuresAreRetryableAndTheLimitIncludesExistingImages() async {
        let service = Service()
        service.uploadFailures = 1
        let viewModel = model(service)
        valid(viewModel)
        await viewModel.addImages(from: [{ Data([7]) }])
        #expect(await viewModel.submit() == false)
        let id = viewModel.imageDrafts[0].id
        await viewModel.retryImageUpload(id: id)
        #expect(viewModel.imageDrafts[0].uploadedImage?.mid == "image-2")
        await viewModel.addImages(from: (0..<12).map { value in { Data([UInt8(value)]) } })
        #expect(viewModel.imageDrafts.count == 9)
        viewModel.removeImageDraft(id: id)
        #expect(viewModel.imageDrafts.count == 8)
        await viewModel.retryImageUpload(id: id)
        let full = model(editing: poster(images: (0..<9).map { .init(mid: String($0), url: "", lowUrl: "") }))
        await full.addImages(from: [{ Data([7]) }])
        #expect(full.imageDrafts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func suspendedImagePreparationKeepsTheEditorResponsiveAndHonorsCancellation() async throws {
        let gate = Gate()
        let service = Service()
        let viewModel = model(service, prepare: { data in await gate.pause(); return Data([42]) + data })
        let adding = Task { await viewModel.addImages(from: [{ Data([7]) }]) }
        defer { adding.cancel(); gate.resume() }
        try await gate.waitUntilPaused()
        viewModel.title = "继续编辑"
        #expect(viewModel.isAddingImages)
        adding.cancel()
        gate.resume()
        await adding.value
        #expect(viewModel.title == "继续编辑")
        #expect(viewModel.imageDrafts.isEmpty)
        #expect(viewModel.isAddingImages == false)
        #expect(service.uploads.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func imagePreparationFailuresAndEmptyDataKeepTheEditorReady() async {
        let viewModel = model(prepare: { _ in nil })
        await viewModel.addImages(from: [{ Data([7]) }, { nil }, { throw URLError(.cancelled) }])
        #expect(viewModel.imageDrafts.isEmpty)
        #expect(viewModel.isAddingImages == false)
        #expect(viewModel.alert?.title == "图片添加失败")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["read", "prepare"], [false, true])
    func draftRestorationOwnsTheEditorAcrossSuspensionAndCancellation(stage: String, cancelled: Bool) async throws {
        let gate = Gate(), drafts = Drafts(), service = Service()
        drafts.result = .loaded(snapshot())
        if stage == "read" { drafts.readGate = gate }
        let viewModel = model(service, drafts: drafts, prepare: { data in
            if stage == "prepare" { await gate.pause() }
            return data
        })
        valid(viewModel)
        let previousTitle = viewModel.title
        let restoring = Task { await viewModel.restoreDraft() }
        defer { restoring.cancel(); gate.resume() }
        try await gate.waitUntilPaused()
        #expect(viewModel.isRestoringDraft && viewModel.isBusy)
        #expect(viewModel.title == previousTitle && viewModel.imageDrafts.isEmpty)
        await viewModel.restoreDraft()
        await viewModel.addImages(from: [{ Issue.record("Images entered during draft restoration"); return Data([9]) }])
        #expect(await viewModel.saveDraft() == false)
        #expect(await viewModel.discardDraft() == false)
        #expect(await viewModel.submit() == false)
        #expect(drafts.loadCount == 1 && drafts.saveCount == 0 && drafts.removalCount == 0)
        #expect(service.uploads.isEmpty && service.submissions.isEmpty)
        if cancelled { viewModel.cancelPendingOperations() }
        gate.resume()
        await restoring.value
        #expect(!viewModel.isRestoringDraft && !viewModel.isBusy)
        if cancelled {
            #expect(viewModel.title == previousTitle && viewModel.imageDrafts.isEmpty)
        } else {
            #expect(viewModel.title == snapshot().title && viewModel.imageDrafts.count == 1)
            await viewModel.retryImageUpload(id: viewModel.imageDrafts[0].id)
            #expect(service.uploads.count == 1 && viewModel.imageDrafts[0].uploadedImage != nil)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["save", "publish", "discard"])
    func savingPublishingAndDiscardingExcludeEachOther(first: String) async throws {
        let gate = Gate(), drafts = Drafts(), service = Service()
        if first == "save" { drafts.saveGate = gate }
        else if first == "publish" { service.submissionGate = gate }
        else { drafts.removalGate = gate }
        let viewModel = model(service, drafts: drafts)
        valid(viewModel)
        let pending = Task {
            if first == "save" { return await viewModel.saveDraft() }
            if first == "publish" { return await viewModel.submit() }
            return await viewModel.discardDraft()
        }
        defer { pending.cancel(); gate.resume() }
        try await gate.waitUntilPaused()
        #expect(viewModel.isBusy)
        #expect(await viewModel.discardDraft() == false)
        #expect(await viewModel.submit() == false)
        #expect(await viewModel.saveDraft() == false)
        #expect(service.submissions.count == (first == "publish" ? 1 : 0))
        #expect(drafts.saveCount == (first == "save" ? 1 : 0))
        #expect(drafts.removalCount == (first == "discard" ? 1 : 0))
        gate.resume()
        #expect(await pending.value)
        #expect(viewModel.isBusy == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateSubmissionUsesOneCapturedPayloadAndPreservesNewDraftRevisions() async throws {
        let gate = Gate()
        let service = Service()
        service.submissionGate = gate
        let drafts = Drafts()
        let viewModel = model(service, drafts: drafts)
        valid(viewModel)
        let pending = Task { await viewModel.submit() }
        defer { pending.cancel(); gate.resume() }
        try await gate.waitUntilPaused()
        #expect(await viewModel.submit() == false)
        viewModel.title = "后续编辑"
        #expect(await drafts.saveGallery(snapshot()))
        gate.resume()
        #expect(await pending.value)
        #expect(service.submissions.count == 1)
        #expect(service.submissions[0].title == "标题")
        #expect(drafts.result.snapshot?.title == "草稿标题")
    }

    @Test(.timeLimit(.minutes(1)))
    func removedImagesAndDuplicateRetriesHonorTheActiveUpload() async throws {
        let gate = Gate()
        let service = Service()
        service.uploadGate = gate
        let viewModel = model(service)
        let pending = Task { await viewModel.addImages(from: [{ Data([7]) }]) }
        defer { pending.cancel(); gate.resume() }
        try await gate.waitUntilPaused()
        let id = viewModel.imageDrafts[0].id
        await viewModel.retryImageUpload(id: id)
        #expect(service.uploads.count == 1)
        viewModel.removeImageDraft(id: id)
        gate.resume()
        await pending.value
        #expect(viewModel.imageDrafts.isEmpty)
        #expect(viewModel.isAddingImages == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func pageCancellationStopsPublicationAndAllowsFreshWork() async throws {
        let gate = Gate()
        let service = Service()
        service.uploadGate = gate
        let viewModel = model(service)
        let pending = Task { await viewModel.addImages(from: [{ Data([7]) }]) }
        defer { pending.cancel(); gate.resume() }
        try await gate.waitUntilPaused()
        viewModel.cancelPendingOperations()
        gate.resume()
        await pending.value
        #expect(viewModel.imageDrafts[0].uploadedImage == nil)
        #expect(viewModel.hasUploadingImages == false)
        await viewModel.retryImageUpload(id: viewModel.imageDrafts[0].id)
        #expect(viewModel.imageDrafts[0].uploadedImage != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func accountRoundTripsDiscardLateSubmissionAndDraftRestoration() async throws {
        let identity = Identity()
        let drafts = Drafts()
        drafts.result = .loaded(snapshot())
        let readGate = Gate()
        drafts.readGate = readGate
        let viewModel = model(drafts: drafts, identity: identity)
        let pending = Task { await viewModel.restoreDraft() }
        defer { pending.cancel(); readGate.resume() }
        try await readGate.waitUntilPaused()
        identity.current = .init(accountIdentifier: "composer-B", generation: 2)
        identity.current = .init(accountIdentifier: "composer-A", generation: 3)
        readGate.resume()
        await pending.value
        #expect(viewModel.title.isEmpty)
        #expect(await viewModel.saveDraft() == false)
        #expect(await viewModel.discardDraft() == false)
        #expect(await viewModel.submit() == false)
        #expect(drafts.removalCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledSubmissionRetainsTheDraftAndReturnsCancellation() async throws {
        let gate = Gate()
        let service = Service()
        service.submissionGate = gate
        let drafts = Drafts()
        let viewModel = model(service, drafts: drafts)
        valid(viewModel)
        let pending = Task { await viewModel.submit() }
        defer { pending.cancel(); gate.resume() }
        try await gate.waitUntilPaused()
        pending.cancel()
        gate.resume()
        #expect(await pending.value == false)
        #expect(drafts.cleanupCount == 0)
        #expect(viewModel.alert == nil)
        #expect(viewModel.isSubmitting == false)
    }
}
