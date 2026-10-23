import Combine
import CommunityCore
import Foundation
import TransportCore

/// 图片先进入本地草稿，上传任务沿图片身份独立持有。
@MainActor
public final class ComposerImageUploads: ObservableObject {
    @Published public private(set) var drafts: [ComposerImageDraft] = []
    @Published public private(set) var isAddingImages = false
    @Published public private(set) var errorMessage: String?
    private let upload: @MainActor (Data, String) async throws -> CommunityImage
    private let prepare: @MainActor (Data) async throws -> Data
    private let isCurrentSession: () -> Bool
    private var generation = 0
    private var importTask: Task<Void, Never>?
    private var uploads: [UUID: Task<Void, Never>] = [:]

    public init(upload: @escaping @MainActor (Data, String) async throws -> CommunityImage,
        prepare: @escaping @MainActor (Data) async throws -> Data,
        isCurrentSession: @escaping () -> Bool) {
        self.upload = upload; self.prepare = prepare; self.isCurrentSession = isCurrentSession
    }

    deinit {
        importTask?.cancel()
        for task in uploads.values { task.cancel() }
    }

    public var hasUploadingImages: Bool { drafts.contains { $0.isUploading } }
    public var uploadedImages: [CommunityImage] { drafts.compactMap(\.uploadedImage) }
    public var isReadyToSubmit: Bool { !isAddingImages && uploadedImages.count == drafts.count }

    public func cancel() {
        generation &+= 1
        importTask?.cancel(); importTask = nil
        for task in uploads.values { task.cancel() }
        uploads.removeAll()
        for index in drafts.indices where drafts[index].isUploading {
            drafts[index].status = .failed("上传已暂停，请重试。")
        }
        isAddingImages = false
    }

    public func restore(_ values: [ComposerImageDraft]) {
        guard isCurrentSession() else { return }
        cancel()
        drafts = values
    }

    public func remove(id: UUID) {
        uploads.removeValue(forKey: id)?.cancel()
        drafts.removeAll { $0.id == id }
    }

    public func waitForImport() async { await importTask?.value }

    public func addImages(from sources: [@MainActor () async throws -> Data?], existingImageCount: Int = 0) async {
        let operation = generation
        guard importTask == nil, isCurrent(operation) else { return }
        isAddingImages = true
        errorMessage = nil
        let remaining = max(0, ComposerDraftImagePolicy.maximumImageCount - existingImageCount - drafts.count)
        let task = Task { [weak self, prepare] in
            for source in sources.prefix(remaining) {
                guard self?.isCurrent(operation) == true else { return }
                do {
                    guard let data = try await source() else { throw URLError(.cannotDecodeContentData) }
                    try Task.checkCancellation()
                    let prepared = try await prepare(data)
                    guard let self, self.isCurrent(operation) else { return }
                    let draft = ComposerImageDraft(previewData: prepared, filename: "image-\(UUID().uuidString).jpg", uploadData: prepared)
                    self.drafts.append(draft)
                    self.startUpload(id: draft.id)
                } catch {
                    guard let self, self.isCurrent(operation), !TaskCancellation.matches(error) else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        importTask = task
        defer { if generation == operation { importTask = nil; isAddingImages = false } }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        let pending = Array(uploads.values)
        await withTaskCancellationHandler {
            for task in pending { await task.value }
        } onCancel: {
            for task in pending { task.cancel() }
        }
    }

    public func retry(id: UUID) async {
        guard let task = startUpload(id: id) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    @discardableResult
    private func startUpload(id: UUID) -> Task<Void, Never>? {
        let operation = generation
        guard isCurrent(operation), uploads[id] == nil,
              let index = drafts.firstIndex(where: { $0.id == id }), drafts[index].uploadedImage == nil else { return nil }
        let draft = drafts[index]
        drafts[index].status = .uploading
        let task = Task { [weak self, upload] in
            defer { if let self, self.generation == operation { self.uploads[id] = nil } }
            let status: ComposerImageDraft.Status
            do {
                try Task.checkCancellation()
                status = .uploaded(try await upload(draft.uploadData ?? draft.previewData, draft.filename))
            } catch {
                status = .failed(TaskCancellation.matches(error) ? "上传已暂停，请重试。" : error.localizedDescription)
            }
            guard let self, self.generation == operation, self.isCurrentSession(),
                  let index = self.drafts.firstIndex(where: { $0.id == id }) else { return }
            self.drafts[index].status = status
        }
        uploads[id] = task
        return task
    }

    private func isCurrent(_ operation: Int) -> Bool {
        operation == generation && isCurrentSession() && !Task.isCancelled
    }
}
