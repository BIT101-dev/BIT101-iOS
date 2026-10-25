import CommunityCore
import StorageCore
import Foundation
import OSLog

private nonisolated struct StoredComposerDraftImage: Codable {
    let filename: String
    let uploadedImage: CommunityImage?
}

private nonisolated protocol StoredComposerDraft: Codable {
    associatedtype Snapshot: ComposerDraftSnapshot
    var schemaVersion: Int { get }
    var assetRevision: String { get }
    var images: [StoredComposerDraftImage] { get }
    func snapshot(images: [ComposerImageDraftSnapshot]) -> Snapshot
}

private nonisolated struct DraftSchemaHeader: Decodable {
    let schemaVersion: Int?
    private enum CodingKeys: String, CodingKey { case schemaVersion }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = container.contains(.schemaVersion) ? try container.decode(Int.self, forKey: .schemaVersion) : nil
    }
}

private nonisolated struct DraftRead<Snapshot: Sendable> {
    let result: ComposerDraftLoadResult<Snapshot>
    var sourceURL: URL?
    var needsMigration = false
    var assetRevision: String?
}

private nonisolated struct StoredGalleryComposerDraft: Codable, StoredComposerDraft {
    let schemaVersion: Int
    let assetRevision: String
    let title: String
    let text: String
    let selectedTags: [String]
    let customTags: [String]
    let anonymous: Bool
    let isPublic: Bool
    let selectedClaimID: Int
    let images: [StoredComposerDraftImage]

    func snapshot(images: [ComposerImageDraftSnapshot]) -> GalleryComposerDraftSnapshot {
        GalleryComposerDraftSnapshot(title: title, text: text, selectedTags: selectedTags, customTags: customTags,
            anonymous: anonymous, isPublic: isPublic, selectedClaimID: selectedClaimID, images: images)
    }
}

private nonisolated struct StoredDeveloperSuggestionDraft: Codable, StoredComposerDraft {
    let schemaVersion: Int
    let assetRevision: String
    let text: String
    let contact: String
    let pendingSubmissionMetadata: Data?
    let images: [StoredComposerDraftImage]

    func snapshot(images: [ComposerImageDraftSnapshot]) -> DeveloperSuggestionDraftSnapshot {
        DeveloperSuggestionDraftSnapshot(text: text, images: images, contact: contact,
            pendingSubmissionMetadata: pendingSubmissionMetadata)
    }
}

private typealias StoredPaperDrafts = [String: Data]

public nonisolated final class ComposerDraftStore: GalleryComposerDraftStoring, DeveloperSuggestionDraftStoring, PaperComposerDraftStoring, ComposerPublicationStoring {
    private static let logger = Logger(subsystem: "BIT101", category: "ComposerDraft")
    private static let currentSchemaVersion = 1
    private static let publicationSchemaVersion = 1
    private static let storage = ComposerDraftStorage()
    private let files: any AppFileService
    private let applicationSupport: URL
    private let prepareImageData: @Sendable (Data) throws -> Data
    private let currentSession: @MainActor @Sendable () -> AppStorageSession
    private let currentPublicationOwner: @MainActor @Sendable () -> String
    private let storageOperations: StorageOperationTracker

    public init(files: any AppFileService, applicationSupport: URL, session: @escaping @MainActor @Sendable () -> AppStorageSession, prepareImageData: @escaping @Sendable (Data) throws -> Data, storageOperations: StorageOperationTracker = StorageOperationTracker(), publicationOwner: (@MainActor @Sendable () -> String)? = nil) {
        self.prepareImageData = prepareImageData
        self.files = files
        self.applicationSupport = applicationSupport
        self.currentSession = session
        self.currentPublicationOwner = publicationOwner ?? { session().accountIdentifier }
        self.storageOperations = storageOperations
    }

    @MainActor
    private func publicationSession(owner: String) throws -> AppStorageSession {
        let session = currentSession()
        guard currentPublicationOwner() == owner.trimmingCharacters(in: .whitespacesAndNewlines) else { throw CancellationError() }
        return session
    }

    @MainActor
    public func loadPublication(kind: ComposerPublicationKind, owner: String) async throws -> ComposerPublicationAttempt? {
        guard storageOperations.begin() else { throw CancellationError() }
        defer { storageOperations.finish() }
        return try await Self.storage.loadPublication(store: self, kind: kind, session: publicationSession(owner: owner))
    }

    @MainActor
    public func beginPublication(_ content: ComposerPublicationContent, owner: String) async throws -> ComposerPublicationStart {
        guard storageOperations.begin() else { throw CancellationError() }
        defer { storageOperations.finish() }
        return try await Self.storage.beginPublication(store: self, content: content, session: publicationSession(owner: owner))
    }

    @MainActor
    public func finishPublication(_ expected: ComposerPublicationAttempt) async throws -> Bool {
        guard storageOperations.begin() else { throw CancellationError() }
        defer { storageOperations.finish() }
        return try await Self.storage.finishPublication(store: self, expected: expected)
    }

    @MainActor
    public func resetPublicationsAfterReview(owner: String) async throws {
        guard storageOperations.begin() else { throw CancellationError() }
        defer { storageOperations.finish() }
        try await Self.storage.resetPublications(store: self, session: publicationSession(owner: owner))
    }

    private var publicationMaximumBytes: Int { ComposerDraftImagePolicy.maximumMetadataBytes * ComposerPublicationKind.allCases.count }

    private func publicationDocument(session: AppStorageSession) throws -> (fields: [String: Any], attempts: [String: Any]) {
        do {
            let data = try files.readData(at: currentFileURL(for: "publications.json", session: session), maximumBytes: publicationMaximumBytes)
            let header = try JSONDecoder().decode(DraftSchemaHeader.self, from: data)
            guard header.schemaVersion == Self.publicationSchemaVersion,
                  let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let attempts = document["attempts"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            return (document, attempts)
        } catch {
            if AppFileSystem.isMissingFile(error) { return (["schemaVersion": Self.publicationSchemaVersion], [:]) }
            throw error
        }
    }

    private func publication(in entries: [String: Any], kind: ComposerPublicationKind, session: AppStorageSession) throws -> ComposerPublicationAttempt? {
        guard let entry = entries[kind.rawValue] else { return nil }
        guard let value = entry as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let result = try JSONDecoder().decode(ComposerPublicationAttempt.self, from: JSONSerialization.data(withJSONObject: value))
        guard result.content.kind == kind, result.accountStorageIdentifier == session.accountStorageIdentifier else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }

    private func writePublications(_ fields: [String: Any], attempts: [String: Any], session: AppStorageSession) throws {
        var document = fields
        document["attempts"] = attempts
        let data = try JSONSerialization.data(withJSONObject: document)
        guard data.count <= publicationMaximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let url = currentFileURL(for: "publications.json", session: session)
        try files.createDirectory(at: url.deletingLastPathComponent())
        try files.writeData(data, to: url, options: AppFileSystem.protectedDataWritingOptions)
    }

    fileprivate func loadPublication(kind: ComposerPublicationKind, session: AppStorageSession) throws -> ComposerPublicationAttempt? {
        let document = try publicationDocument(session: session)
        return try publication(in: document.attempts, kind: kind, session: session)
    }

    fileprivate func beginPublication(_ content: ComposerPublicationContent, session: AppStorageSession) throws -> ComposerPublicationStart {
        let document = try publicationDocument(session: session)
        if let pending = try publication(in: document.attempts, kind: content.kind, session: session) { return .pending(pending) }
        let attempt = ComposerPublicationAttempt(accountStorageIdentifier: session.accountStorageIdentifier, content: content)
        var entries = document.attempts
        entries[content.kind.rawValue] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt))
        try writePublications(document.fields, attempts: entries, session: session)
        return .started(attempt)
    }

    fileprivate func removePublication(_ expected: ComposerPublicationAttempt) throws -> Bool {
        let session = AppStorageSession(accountIdentifier: expected.accountStorageIdentifier)
        let document = try publicationDocument(session: session)
        guard let current = try publication(in: document.attempts, kind: expected.content.kind, session: session) else { return true }
        guard current == expected else { return false }
        var entries = document.attempts
        entries.removeValue(forKey: expected.content.kind.rawValue)
        if entries.isEmpty && Set(document.fields.keys) == ["schemaVersion", "attempts"] {
            try files.removeItem(at: currentFileURL(for: "publications.json", session: session))
        } else { try writePublications(document.fields, attempts: entries, session: session) }
        return true
    }

    fileprivate func resetPublications(session: AppStorageSession) throws {
        do { try files.removeItem(at: currentFileURL(for: "publications.json", session: session)) }
        catch { if !AppFileSystem.isMissingFile(error) { throw error } }
    }

    @MainActor
    public func savePaper(_ snapshot: PaperComposerDraftSnapshot) async -> Bool {
        guard storageOperations.begin() else { return false }
        defer { storageOperations.finish() }
        return await Self.storage.savePaper(store: self, snapshot, session: currentSession())
    }

    @MainActor
    public func loadPaperDrafts() async -> ComposerDraftLoadResult<[PaperComposerDraftSnapshot]> {
        guard storageOperations.begin() else { return .missing }
        defer { storageOperations.finish() }
        return await Self.storage.loadPaperDrafts(store: self, session: currentSession())
    }

    @MainActor
    public func loadPaper(paperID: Int?) async -> ComposerDraftLoadResult<PaperComposerDraftSnapshot> {
        guard storageOperations.begin() else { return .missing }
        defer { storageOperations.finish() }
        return await Self.storage.loadPaper(store: self, paperID: paperID, session: currentSession())
    }

    @MainActor
    public func capturePaperRecovery() async -> ComposerDraftCleanup {
        let session = currentSession()
        return { @MainActor in
            guard self.currentSession() == session, self.storageOperations.begin() else { return false }
            defer { self.storageOperations.finish() }
            return await Self.storage.recoverPaperDrafts(store: self, session: session)
        }
    }

    @MainActor
    public func capturePaperCleanup(matching snapshot: PaperComposerDraftSnapshot?) async -> ComposerDraftCleanup {
        guard let snapshot else { return { true } }
        guard storageOperations.begin() else { return { false } }
        defer { storageOperations.finish() }
        let session = currentSession()
        return { @MainActor in
            guard self.storageOperations.begin() else { return false }
            defer { self.storageOperations.finish() }
            return await Self.storage.removePaper(store: self, paperID: snapshot.paperID, captured: snapshot, session: session)
        }
    }

    private static func paperKey(_ id: Int?) -> String { id.map { "paper:\($0)" } ?? "new" }

    private static func paperSnapshot(_ data: Data, key: String) -> PaperComposerDraftSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(PaperComposerDraftSnapshot.self, from: data),
              key == paperKey(snapshot.paperID) else { return nil }
        return snapshot
    }

    private func paperEntries(_ data: Data) throws -> StoredPaperDrafts {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        return try entries.mapValues { try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
    }

    private func writePaperDrafts(_ entries: StoredPaperDrafts, to url: URL) throws {
        let values = try entries.mapValues { try JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": Self.currentSchemaVersion, "entries": values])
        try writeData(data, to: url)
    }

    private func readPaperDrafts(session: AppStorageSession) -> ComposerDraftLoadResult<StoredPaperDrafts> {
        let url = currentFileURL(for: "paper.json", session: session)
        do {
            try files.setPrivateFileProtection(at: url)
            let data = try files.readData(at: url, maximumBytes: ComposerDraftImagePolicy.maximumMetadataBytes)
            let header = try JSONDecoder().decode(DraftSchemaHeader.self, from: data)
            guard let version = header.schemaVersion else { return .unreadable }
            guard version == Self.currentSchemaVersion else { return .unsupportedVersion(version) }
            return .loaded(try paperEntries(data))
        } catch { return AppFileSystem.isMissingFile(error) ? .missing : .unreadable }
    }

    fileprivate func persistPaper(_ snapshot: PaperComposerDraftSnapshot, session: AppStorageSession) -> Bool {
        let loaded = readPaperDrafts(session: session)
        guard loaded.allowsWrite else { return false }
        var archive = loaded.snapshot ?? [:]
        let key = Self.paperKey(snapshot.paperID)
        if let current = archive[key], Self.paperSnapshot(current, key: key) == nil { return false }
        do {
            archive[key] = try JSONEncoder().encode(snapshot)
            try writePaperDrafts(archive, to: currentFileURL(for: "paper.json", session: session))
            return true
        }
        catch { Self.logger.error("保存文章草稿失败：\(String(describing: error), privacy: .private)"); return false }
    }

    fileprivate func loadPaperDrafts(session: AppStorageSession) -> ComposerDraftLoadResult<[PaperComposerDraftSnapshot]> {
        switch readPaperDrafts(session: session) {
        case .missing: return .missing
        case .loaded(let entries), .recovered(let entries, _):
            return .loaded(entries.sorted { $0.key < $1.key }.compactMap { Self.paperSnapshot($0.value, key: $0.key) })
        case .unreadable: return .unreadable
        case .unsupportedVersion(let version): return .unsupportedVersion(version)
        }
    }

    fileprivate func loadPaper(paperID: Int?, session: AppStorageSession) -> ComposerDraftLoadResult<PaperComposerDraftSnapshot> {
        switch readPaperDrafts(session: session) {
        case .missing: return .missing
        case let .loaded(archive), let .recovered(archive, _):
            let key = Self.paperKey(paperID)
            guard let data = archive[key] else { return .missing }
            guard let snapshot = Self.paperSnapshot(data, key: key) else { return .unreadable }
            return .loaded(snapshot)
        case .unreadable: return .unreadable
        case let .unsupportedVersion(version): return .unsupportedVersion(version)
        }
    }

    fileprivate func recoverPaperDrafts(session: AppStorageSession) -> Bool {
        let url = currentFileURL(for: "paper.json", session: session)
        do {
            try files.setPrivateFileProtection(at: url)
            let data = try files.readData(at: url, maximumBytes: ComposerDraftImagePolicy.maximumMetadataBytes)
            let version = (try? JSONDecoder().decode(DraftSchemaHeader.self, from: data))?.schemaVersion
            if let version, version != Self.currentSchemaVersion { return false }
            let parsed = try? paperEntries(data)
            let readable = (parsed ?? [:]).filter { Self.paperSnapshot($0.value, key: $0.key) != nil }
            if let parsed, version == Self.currentSchemaVersion, readable.count == parsed.count { return true }
            try writePaperDrafts(readable, to: url)
            return true
        } catch {
            if AppFileSystem.isMissingFile(error) { return true }
            Self.logger.error("恢复文章草稿失败：\(String(describing: error), privacy: .private)")
            return false
        }
    }

    fileprivate func removePaper(paperID: Int?, captured: PaperComposerDraftSnapshot?, session: AppStorageSession) -> Bool {
        guard let captured else { return true }
        let loaded = readPaperDrafts(session: session)
        guard loaded.allowsWrite else { return false }
        let key = Self.paperKey(paperID)
        guard var archive = loaded.snapshot, let data = archive[key] else { return true }
        guard let current = Self.paperSnapshot(data, key: key) else { return false }
        guard current == captured else { return true }
        archive.removeValue(forKey: key)
        do {
            if archive.isEmpty { return removeFile(currentFileURL(for: "paper.json", session: session)) }
            try writePaperDrafts(archive, to: currentFileURL(for: "paper.json", session: session))
            return true
        } catch { Self.logger.error("清理文章草稿失败：\(String(describing: error), privacy: .private)"); return false }
    }

    @MainActor
    @discardableResult
    public func saveGallery(_ snapshot: GalleryComposerDraftSnapshot) async -> Bool {
        guard storageOperations.begin() else { return false }
        defer { storageOperations.finish() }
        return await Self.storage.saveGallery(store: self, snapshot, session: currentSession())
    }

    @MainActor
    public func loadGallery() async -> ComposerDraftLoadResult<GalleryComposerDraftSnapshot> {
        guard storageOperations.begin() else { return .missing }
        defer { storageOperations.finish() }
        return await Self.storage.loadGallery(store: self, session: currentSession())
    }

    @discardableResult
    fileprivate func persistGallery(_ snapshot: GalleryComposerDraftSnapshot, session: AppStorageSession) -> Bool {
        persist(snapshot, as: StoredGalleryComposerDraft.self, filename: "gallery.json", session: session) { revision, images in
            StoredGalleryComposerDraft(
                schemaVersion: Self.currentSchemaVersion,
                assetRevision: revision,
                title: snapshot.title,
                text: snapshot.text,
                selectedTags: snapshot.selectedTags,
                customTags: snapshot.customTags,
                anonymous: snapshot.anonymous,
                isPublic: snapshot.isPublic,
                selectedClaimID: snapshot.selectedClaimID,
                images: images
            )
        }
    }

    fileprivate func loadGallery(session: AppStorageSession) -> ComposerDraftLoadResult<GalleryComposerDraftSnapshot> {
        let read = readDraft(StoredGalleryComposerDraft.self, filename: "gallery.json", session: session)
        if read.needsMigration, let snapshot = read.result.snapshot { _ = persistGallery(snapshot, session: session) }
        return read.result
    }

    @discardableResult
    @MainActor
    public func saveSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot) async -> Bool {
        guard storageOperations.begin() else { return false }
        defer { storageOperations.finish() }
        return await Self.storage.saveSuggestion(store: self, snapshot, session: currentSession())
    }

    @MainActor
    public func loadSuggestion() async -> ComposerDraftLoadResult<DeveloperSuggestionDraftSnapshot> {
        guard storageOperations.begin() else { return .missing }
        defer { storageOperations.finish() }
        return await Self.storage.loadSuggestion(store: self, session: currentSession())
    }

    @discardableResult
    fileprivate func persistSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot, session: AppStorageSession) -> Bool {
        persist(snapshot, as: StoredDeveloperSuggestionDraft.self, filename: "suggestion.json", session: session) { revision, images in
            StoredDeveloperSuggestionDraft(
                schemaVersion: Self.currentSchemaVersion, assetRevision: revision, text: snapshot.text,
                contact: snapshot.contact, pendingSubmissionMetadata: snapshot.pendingSubmissionMetadata, images: images)
        }
    }

    private func persist<Stored: StoredComposerDraft>(
        _ snapshot: Stored.Snapshot, as type: Stored.Type, filename: String, session: AppStorageSession,
        makeStored: (String, [StoredComposerDraftImage]) -> Stored
    ) -> Bool {
        let fileURL = currentFileURL(for: filename, session: session)
        let previous = readDraft(type, filename: filename, session: session)
        guard previous.result.allowsWrite else { return false }
        let previousRevision = previous.sourceURL == fileURL ? previous.assetRevision : nil
        var newRevision: String?
        do {
            // 清理上次保存留下的版本后再创建新目录；清理失败时本轮写入停止，限制孤立版本数量。
            try removeObsoleteAssetRevisions(
                for: filename,
                keeping: previousRevision,
                session: session
            )
            let reuse = reusableAssetRevision(previous, at: fileURL, images: snapshot.images)
            let (revision, images) = if let reuse {
                (reuse, snapshot.images.map { StoredComposerDraftImage(filename: $0.filename, uploadedImage: $0.uploadedImage) })
            } else { try writeImages(snapshot.images, filename: filename, session: session) }
            newRevision = reuse == nil ? revision : nil
            try write(makeStored(revision, images), to: fileURL)
            removeMigratedSource(previous.sourceURL, filename: filename, session: session)
            do { try removeObsoleteAssetRevisions(for: filename, keeping: revision, session: session) }
            catch { Self.logger.error("清理草稿资产遇到错误：\(String(describing: error), privacy: .private)") }
            return true
        } catch {
            if let newRevision { removeAssets(for: filename, revision: newRevision, session: session) }
            Self.logger.error("保存草稿失败：\(String(describing: error), privacy: .public)")
            return false
        }
    }

    fileprivate func loadSuggestion(session: AppStorageSession) -> ComposerDraftLoadResult<DeveloperSuggestionDraftSnapshot> {
        let read = readDraft(StoredDeveloperSuggestionDraft.self, filename: "suggestion.json", session: session)
        if read.needsMigration, let snapshot = read.result.snapshot { _ = persistSuggestion(snapshot, session: session) }
        return read.result
    }

    private func readDraft<Stored: StoredComposerDraft>(
        _ type: Stored.Type, filename: String, session: AppStorageSession, includeImages: Bool = true
    ) -> DraftRead<Stored.Snapshot> {
        let currentURL = currentFileURL(for: filename, session: session)
        let sources = [currentURL, legacyAccountFileURL(for: filename, session: session)]
        for url in sources {
            do {
                try files.setPrivateFileProtection(at: url)
                let data = try files.readData(at: url, maximumBytes: ComposerDraftImagePolicy.maximumLegacyMetadataBytes)
                let decoder = JSONDecoder()
                let header = try decoder.decode(DraftSchemaHeader.self, from: data)
                let snapshot: Stored.Snapshot
                let unavailableImages: Int
                var assetRevision: String?
                if let version = header.schemaVersion {
                    guard version == Self.currentSchemaVersion else {
                        return DraftRead(result: .unsupportedVersion(version), sourceURL: url)
                    }
                    guard data.count <= ComposerDraftImagePolicy.maximumMetadataBytes else { throw CocoaError(.fileReadCorruptFile) }
                    let stored = try decoder.decode(type, from: data)
                    guard UUID(uuidString: stored.assetRevision) != nil else { throw CocoaError(.fileReadCorruptFile) }
                    let recovered = includeImages ? readImages(stored.images, revision: stored.assetRevision, sourceURL: url)
                        : (images: [], unavailable: 0)
                    snapshot = stored.snapshot(images: recovered.images)
                    unavailableImages = recovered.unavailable
                    assetRevision = stored.assetRevision
                } else {
                    var legacy = try decoder.decode(Stored.Snapshot.self, from: data)
                    let count = legacy.images.count
                    legacy.images = legacy.images.prefix(ComposerDraftImagePolicy.maximumImageCount).filter {
                        $0.previewData.count <= ComposerDraftImagePolicy.maximumBytes
                            && ($0.uploadData?.count ?? 0) <= ComposerDraftImagePolicy.maximumBytes
                    }
                    unavailableImages = count - legacy.images.count
                    snapshot = legacy
                }
                if unavailableImages > 0 {
                    return DraftRead(result: .recovered(snapshot, unavailableImages: unavailableImages), sourceURL: url,
                        assetRevision: assetRevision)
                }
                return DraftRead(result: .loaded(snapshot), sourceURL: url,
                    needsMigration: url != currentURL || header.schemaVersion == nil, assetRevision: assetRevision)
            } catch {
                if AppFileSystem.isMissingFile(error) { continue }
                Self.logger.error("草稿读取遇到问题，原文件与图片已保留：\(String(describing: error), privacy: .public)")
                return DraftRead(result: .unreadable, sourceURL: url)
            }
        }
        return DraftRead(result: .missing)
    }

    private func removeMigratedSource(_ sourceURL: URL?, filename: String, session: AppStorageSession) {
        guard let sourceURL, sourceURL != currentFileURL(for: filename, session: session) else { return }
        guard removeFile(sourceURL) else { return }
        removeFile(sourceURL.appendingPathExtension("assets"))
    }

    @discardableResult
    private func removeFile(_ url: URL) -> Bool {
        do { try files.removeItem(at: url); return true }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return true }
        catch {
            Self.logger.error("清理草稿文件遇到错误：\(String(describing: error), privacy: .private)")
            return false
        }
    }

    @MainActor
    @discardableResult
    public func removeGallery() async -> Bool {
        guard storageOperations.begin() else { return false }
        defer { storageOperations.finish() }
        return await Self.storage.removeGallery(store: self, session: currentSession())
    }

    /// Capture cleanup for the saved revision owned by a submission.
    @MainActor
    public func captureSuggestionCleanup() async -> ComposerDraftCleanup {
        await captureCleanup(filename: "suggestion.json")
    }

    @MainActor
    public func captureGalleryCleanup() async -> ComposerDraftCleanup {
        await captureCleanup(filename: "gallery.json")
    }

    @MainActor
    private func captureCleanup(filename: String) async -> ComposerDraftCleanup {
        guard storageOperations.begin() else { return { false } }
        defer { storageOperations.finish() }
        let session = currentSession()
        let metadata = await Self.storage.cleanupMetadata(store: self, filename: filename, session: session)
        return { @MainActor in
            guard self.storageOperations.begin() else { return false }
            defer { self.storageOperations.finish() }
            return await Self.storage.removeMatching(store: self, filename: filename, session: session, metadata: metadata)
        }
    }

    @MainActor
    @discardableResult
    public func removeSuggestion() async -> Bool {
        guard storageOperations.begin() else { return false }
        defer { storageOperations.finish() }
        return await Self.storage.removeSuggestion(store: self, session: currentSession())
    }

    private func write<T: Encodable>(_ value: T, to fileURL: URL) throws {
        try writeData(JSONEncoder().encode(value), to: fileURL)
    }

    private func writeData(_ data: Data, to fileURL: URL) throws {
        try files.createDirectory(at: fileURL.deletingLastPathComponent())
        guard data.count <= ComposerDraftImagePolicy.maximumMetadataBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try files.writeData(
            data,
            to: fileURL,
            options: AppFileSystem.protectedDataWritingOptions
        )
    }

    private func writeImages(
        _ images: [ComposerImageDraftSnapshot],
        filename: String,
        session: AppStorageSession
    ) throws -> (revision: String, references: [StoredComposerDraftImage]) {
        guard images.count <= ComposerDraftImagePolicy.maximumImageCount else { throw CocoaError(.fileWriteOutOfSpace) }
        let revision = UUID().uuidString.lowercased()
        let directory = assetDirectoryURL(for: filename, revision: revision, session: session)
        try files.createDirectory(at: directory)
        do {
            let references = try images.enumerated().map { index, image in
                let source = image.uploadData ?? image.previewData
                let data: Data
                if let uploadData = image.uploadData,
                   uploadData.count <= ComposerDraftImagePolicy.maximumBytes {
                    data = uploadData
                } else {
                    data = try prepareImageData(source)
                }
                guard data.count <= ComposerDraftImagePolicy.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                try files.writeData(
                    data,
                    to: directory.appending(path: "image-\(index).jpg"),
                    options: AppFileSystem.protectedDataWritingOptions
                )
                return StoredComposerDraftImage(filename: image.filename, uploadedImage: image.uploadedImage)
            }
            return (revision, references)
        } catch {
            removeFile(directory)
            throw error
        }
    }

    private func reusableAssetRevision<Snapshot: ComposerDraftSnapshot>(
        _ previous: DraftRead<Snapshot>, at url: URL, images: [ComposerImageDraftSnapshot]
    ) -> String? {
        guard previous.sourceURL == url, case .loaded(let snapshot) = previous.result,
              snapshot.images.count == images.count,
              zip(snapshot.images, images).allSatisfy({ old, new in
                  old.filename == new.filename && (old.uploadData ?? old.previewData) == (new.uploadData ?? new.previewData)
              }) else { return nil }
        return previous.assetRevision
    }

    private func readImages(
        _ references: [StoredComposerDraftImage], revision: String, sourceURL: URL
    ) -> (images: [ComposerImageDraftSnapshot], unavailable: Int) {
        let directory = sourceURL.appendingPathExtension("assets").appending(path: revision, directoryHint: .isDirectory)
        var images: [ComposerImageDraftSnapshot] = []
        for (index, reference) in references.prefix(ComposerDraftImagePolicy.maximumImageCount).enumerated() {
            do {
                let fileURL = directory.appending(path: "image-\(index).jpg")
                guard let size = files.regularFileSize(at: fileURL), size <= ComposerDraftImagePolicy.maximumBytes
                else { throw CocoaError(.fileReadCorruptFile) }
                try files.setPrivateFileProtection(at: fileURL)
                let data = try files.readData(at: fileURL, maximumBytes: ComposerDraftImagePolicy.maximumBytes)
                images.append(ComposerImageDraftSnapshot(filename: reference.filename, previewData: data,
                    uploadData: data, uploadedImage: reference.uploadedImage))
            } catch {
                Self.logger.error("草稿图片读取受阻：\(String(describing: error), privacy: .public)")
            }
        }
        return (images, references.count - images.count)
    }

    fileprivate func cleanupMetadata(filename: String, session: AppStorageSession) -> (data: Data?, readable: Bool) {
        if filename == "gallery.json" {
            return cleanupMetadata(StoredGalleryComposerDraft.self, filename: filename, session: session)
        }
        return cleanupMetadata(StoredDeveloperSuggestionDraft.self, filename: filename, session: session)
    }

    private func cleanupMetadata<Stored: StoredComposerDraft>(
        _ type: Stored.Type, filename: String, session: AppStorageSession
    ) -> (data: Data?, readable: Bool) {
        let read = readDraft(type, filename: filename, session: session, includeImages: false)
        guard read.result.allowsWrite else { return (nil, false) }
        guard let source = read.sourceURL else { return (nil, true) }
        do {
            return (try files.readData(at: source, maximumBytes: ComposerDraftImagePolicy.maximumLegacyMetadataBytes), true)
        } catch { return (nil, false) }
    }

    @discardableResult
    fileprivate func remove(filename: String, session: AppStorageSession) -> Bool {
        var removed = true
        for url in Set([currentFileURL(for: filename, session: session),
                        legacyAccountFileURL(for: filename, session: session)]) {
            guard removeFile(url) else { removed = false; continue }
            if !removeFile(url.appendingPathExtension("assets")) { removed = false }
        }
        return removed
    }

    private func currentFileURL(for filename: String, session: AppStorageSession) -> URL {
        applicationSupport
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: session.accountStorageIdentifier, directoryHint: .isDirectory)
            .appending(path: "composer-\(filename)")
    }

    private func legacyAccountFileURL(for filename: String, session: AppStorageSession) -> URL {
        applicationSupport
            .appending(path: "BIT101-iOS", directoryHint: .isDirectory)
            .appending(path: session.legacyAccountDirectoryNameForMigration, directoryHint: .isDirectory)
            .appending(path: "composer-\(filename)")
    }

    private func assetRootURL(for filename: String, session: AppStorageSession) -> URL {
        currentFileURL(for: filename, session: session).appendingPathExtension("assets")
    }

    private func assetDirectoryURL(for filename: String, revision: String, session: AppStorageSession) -> URL {
        assetRootURL(for: filename, session: session).appending(path: revision, directoryHint: .isDirectory)
    }

    private func removeAssets(for filename: String, revision: String, session: AppStorageSession) {
        removeFile(assetDirectoryURL(for: filename, revision: revision, session: session))
    }

    private func removeObsoleteAssetRevisions(
        for filename: String,
        keeping revision: String?,
        session: AppStorageSession
    ) throws {
        let root = assetRootURL(for: filename, session: session)
        guard files.fileExists(at: root) else { return }
        let revisions = try files.contentsOfDirectory(at: root, options: [])
        for oldRevision in revisions where oldRevision.lastPathComponent != revision {
            try files.removeItem(at: oldRevision)
        }
    }
}

private actor ComposerDraftStorage {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    func loadPublication(store: ComposerDraftStore, kind: ComposerPublicationKind, session: AppStorageSession) throws -> ComposerPublicationAttempt? {
        try store.loadPublication(kind: kind, session: session)
    }
    func beginPublication(store: ComposerDraftStore, content: ComposerPublicationContent, session: AppStorageSession) throws -> ComposerPublicationStart {
        try store.beginPublication(content, session: session)
    }
    func finishPublication(store: ComposerDraftStore, expected: ComposerPublicationAttempt) throws -> Bool {
        try store.removePublication(expected)
    }
    func resetPublications(store: ComposerDraftStore, session: AppStorageSession) throws {
        try store.resetPublications(session: session)
    }

    func savePaper(store: ComposerDraftStore, _ snapshot: PaperComposerDraftSnapshot, session: AppStorageSession) -> Bool {
        store.persistPaper(snapshot, session: session)
    }
    func loadPaper(store: ComposerDraftStore, paperID: Int?, session: AppStorageSession) -> ComposerDraftLoadResult<PaperComposerDraftSnapshot> {
        store.loadPaper(paperID: paperID, session: session)
    }
    func loadPaperDrafts(store: ComposerDraftStore, session: AppStorageSession) -> ComposerDraftLoadResult<[PaperComposerDraftSnapshot]> {
        store.loadPaperDrafts(session: session)
    }
    func recoverPaperDrafts(store: ComposerDraftStore, session: AppStorageSession) -> Bool {
        store.recoverPaperDrafts(session: session)
    }
    func removePaper(store: ComposerDraftStore, paperID: Int?, captured: PaperComposerDraftSnapshot?, session: AppStorageSession) -> Bool {
        store.removePaper(paperID: paperID, captured: captured, session: session)
    }

    func saveGallery(store: ComposerDraftStore, _ snapshot: GalleryComposerDraftSnapshot, session: AppStorageSession) -> Bool {
        store.persistGallery(snapshot, session: session)
    }

    func loadGallery(store: ComposerDraftStore, session: AppStorageSession) -> ComposerDraftLoadResult<GalleryComposerDraftSnapshot> {
        store.loadGallery(session: session)
    }

    func saveSuggestion(store: ComposerDraftStore, _ snapshot: DeveloperSuggestionDraftSnapshot, session: AppStorageSession) -> Bool {
        store.persistSuggestion(snapshot, session: session)
    }

    func loadSuggestion(store: ComposerDraftStore, session: AppStorageSession) -> ComposerDraftLoadResult<DeveloperSuggestionDraftSnapshot> {
        store.loadSuggestion(session: session)
    }

    func cleanupMetadata(store: ComposerDraftStore, filename: String, session: AppStorageSession) -> (data: Data?, readable: Bool) {
        store.cleanupMetadata(filename: filename, session: session)
    }

    func removeMatching(store: ComposerDraftStore, filename: String, session: AppStorageSession, metadata: (data: Data?, readable: Bool)) -> Bool {
        let current = store.cleanupMetadata(filename: filename, session: session)
        guard metadata.readable, current.readable else { return false }
        guard let captured = metadata.data, current.data == captured else { return true }
        return store.remove(filename: filename, session: session)
    }

    func removeGallery(store: ComposerDraftStore, session: AppStorageSession) -> Bool {
        store.remove(filename: "gallery.json", session: session)
    }

    func removeSuggestion(store: ComposerDraftStore, session: AppStorageSession) -> Bool {
        store.remove(filename: "suggestion.json", session: session)
    }
}
