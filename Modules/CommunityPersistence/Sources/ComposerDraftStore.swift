import CommunityCore
import StorageCore
import Foundation
import OSLog

private nonisolated struct StoredComposerDraftImage: Codable {
    let filename: String
}

private nonisolated protocol StoredComposerDraft: Decodable {
    associatedtype Snapshot: Decodable & Sendable
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
    let images: [StoredComposerDraftImage]

    func snapshot(images: [ComposerImageDraftSnapshot]) -> DeveloperSuggestionDraftSnapshot {
        DeveloperSuggestionDraftSnapshot(text: text, images: images, contact: contact)
    }
}

public nonisolated final class ComposerDraftStore: GalleryComposerDraftStoring, DeveloperSuggestionDraftStoring {
    private static let directoryName = "ComposerDrafts"
    private static let logger = Logger(subsystem: "BIT101", category: "ComposerDraft")
    private static let currentSchemaVersion = 1
    private let storage = ComposerDraftStorage()
    private let files: any AppFileService
    private let applicationSupport: URL
    private let prepareImageData: @Sendable (Data) throws -> Data
    private let currentSession: @MainActor @Sendable () -> AppStorageSession

    public init(files: any AppFileService, applicationSupport: URL, session: @escaping @MainActor @Sendable () -> AppStorageSession, prepareImageData: @escaping @Sendable (Data) throws -> Data) {
        self.prepareImageData = prepareImageData
        self.files = files
        self.applicationSupport = applicationSupport
        self.currentSession = session
    }

    @MainActor
    @discardableResult
    public func saveGallery(_ snapshot: GalleryComposerDraftSnapshot) async -> Bool {
        await storage.saveGallery(store: self, snapshot, session: currentSession())
    }

    @MainActor
    public func loadGallery() async -> ComposerDraftLoadResult<GalleryComposerDraftSnapshot> {
        await storage.loadGallery(store: self, session: currentSession())
    }

    @discardableResult
    fileprivate func persistGallery(_ snapshot: GalleryComposerDraftSnapshot, session: AppStorageSession) -> Bool {
        let fileURL = currentFileURL(for: "gallery.json", session: session)
        guard readDraft(StoredGalleryComposerDraft.self, filename: "gallery.json", session: session).result.allowsWrite else { return false }
        let previousRevision = storedGalleryRevision(at: fileURL)
        var newRevision: String?
        do {
            // 清理上次保存留下的版本后再创建新目录；清理失败时本轮写入停止，限制孤立版本数量。
            try removeObsoleteAssetRevisions(
                for: "gallery.json",
                keeping: previousRevision,
                session: session
            )
            let (revision, images) = try writeImages(snapshot.images, filename: "gallery.json", session: session)
            newRevision = revision
            let stored = StoredGalleryComposerDraft(
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
            try write(stored, to: fileURL)
            try? removeObsoleteAssetRevisions(for: "gallery.json", keeping: revision, session: session)
            return true
        } catch {
            if let newRevision { removeAssets(for: "gallery.json", revision: newRevision, session: session) }
            Self.logger.error("保存发帖草稿失败：\(String(describing: error), privacy: .public)")
            return false
        }
    }

    fileprivate func loadGallery(session: AppStorageSession) -> ComposerDraftLoadResult<GalleryComposerDraftSnapshot> {
        let read = readDraft(StoredGalleryComposerDraft.self, filename: "gallery.json", session: session)
        if read.needsMigration, let snapshot = read.result.snapshot,
           persistGallery(snapshot, session: session) {
            removeMigratedSource(read.sourceURL, filename: "gallery.json", session: session)
        }
        return read.result
    }

    @discardableResult
    @MainActor
    public func saveSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot) async -> Bool {
        await storage.saveSuggestion(store: self, snapshot, session: currentSession())
    }

    @MainActor
    public func loadSuggestion() async -> ComposerDraftLoadResult<DeveloperSuggestionDraftSnapshot> {
        await storage.loadSuggestion(store: self, session: currentSession())
    }

    @discardableResult
    fileprivate func persistSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot, session: AppStorageSession) -> Bool {
        let fileURL = currentFileURL(for: "suggestion.json", session: session)
        guard readDraft(StoredDeveloperSuggestionDraft.self, filename: "suggestion.json", session: session).result.allowsWrite else { return false }
        let previousRevision = storedSuggestionRevision(at: fileURL)
        var newRevision: String?
        do {
            // 清理上次保存留下的版本后再创建新目录；清理失败时本轮写入停止，限制孤立版本数量。
            try removeObsoleteAssetRevisions(
                for: "suggestion.json",
                keeping: previousRevision,
                session: session
            )
            let (revision, images) = try writeImages(snapshot.images, filename: "suggestion.json", session: session)
            newRevision = revision
            let stored = StoredDeveloperSuggestionDraft(
                schemaVersion: Self.currentSchemaVersion,
                assetRevision: revision,
                text: snapshot.text,
                contact: snapshot.contact,
                images: images
            )
            try write(stored, to: fileURL)
            try? removeObsoleteAssetRevisions(for: "suggestion.json", keeping: revision, session: session)
            return true
        } catch {
            if let newRevision { removeAssets(for: "suggestion.json", revision: newRevision, session: session) }
            Self.logger.error("保存建议草稿失败：\(String(describing: error), privacy: .public)")
            return false
        }
    }

    fileprivate func loadSuggestion(session: AppStorageSession) -> ComposerDraftLoadResult<DeveloperSuggestionDraftSnapshot> {
        let read = readDraft(StoredDeveloperSuggestionDraft.self, filename: "suggestion.json", session: session)
        if read.needsMigration, let snapshot = read.result.snapshot,
           persistSuggestion(snapshot, session: session) {
            removeMigratedSource(read.sourceURL, filename: "suggestion.json", session: session)
        }
        return read.result
    }

    private func readDraft<Stored: StoredComposerDraft>(
        _ type: Stored.Type, filename: String, session: AppStorageSession
    ) -> DraftRead<Stored.Snapshot> {
        let currentURL = currentFileURL(for: filename, session: session)
        let sources = [currentURL, legacyAccountFileURL(for: filename, session: session), directoryURL.appendingPathComponent(filename)]
        for url in sources where files.fileExists(at: url) {
            do {
                try? files.setPrivateFileProtection(at: url)
                let data = try files.readData(at: url)
                let decoder = JSONDecoder()
                let header = try decoder.decode(DraftSchemaHeader.self, from: data)
                let snapshot: Stored.Snapshot
                if let version = header.schemaVersion {
                    guard version == Self.currentSchemaVersion else {
                        return DraftRead(result: .unsupportedVersion(version), sourceURL: url)
                    }
                    let stored = try decoder.decode(type, from: data)
                    guard UUID(uuidString: stored.assetRevision) != nil else { throw CocoaError(.fileReadCorruptFile) }
                    let images = try readImages(stored.images, revision: stored.assetRevision, sourceURL: url)
                    snapshot = stored.snapshot(images: images)
                } else {
                    snapshot = try decoder.decode(Stored.Snapshot.self, from: data)
                }
                return DraftRead(result: .loaded(snapshot), sourceURL: url,
                    needsMigration: url != currentURL || header.schemaVersion == nil)
            } catch {
                Self.logger.error("草稿读取遇到问题，原文件与图片已保留：\(String(describing: error), privacy: .public)")
                return DraftRead(result: .unreadable, sourceURL: url)
            }
        }
        return DraftRead(result: .missing)
    }

    private func removeMigratedSource(_ sourceURL: URL?, filename: String, session: AppStorageSession) {
        guard let sourceURL, sourceURL != currentFileURL(for: filename, session: session) else { return }
        try? files.removeItem(at: sourceURL)
        try? files.removeItem(at: sourceURL.appendingPathExtension("assets"))
    }

    @MainActor
    public func removeGallery() async {
        await storage.removeGallery(store: self, session: currentSession())
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
        let session = currentSession()
        let metadata = await storage.cleanupMetadata(store: self, filename: filename, session: session)
        return {
            await self.storage.removeMatching(store: self, filename: filename, session: session, metadata: metadata)
        }
    }

    fileprivate func metadata(filename: String, session: AppStorageSession) -> Data? {
        readData(at: currentFileURL(for: filename, session: session))
    }

    @MainActor
    public func removeSuggestion() async {
        await storage.removeSuggestion(store: self, session: currentSession())
    }

    private var directoryURL: URL {
        applicationSupport.appending(path: Self.directoryName, directoryHint: .isDirectory)
    }

    private func readData(at url: URL) -> Data? {
        try? files.setPrivateFileProtection(at: url)
        return try? files.readData(at: url)
    }

    private func write<T: Encodable>(_ value: T, to fileURL: URL) throws {
        try files.createDirectory(at: fileURL.deletingLastPathComponent())
        let data = try JSONEncoder().encode(value)
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
                return StoredComposerDraftImage(filename: image.filename)
            }
            return (revision, references)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    private func readImages(
        _ references: [StoredComposerDraftImage], revision: String, sourceURL: URL
    ) throws -> [ComposerImageDraftSnapshot] {
        let directory = sourceURL.appendingPathExtension("assets").appending(path: revision, directoryHint: .isDirectory)
        return try references.enumerated().map { index, reference in
            let fileURL = directory.appending(path: "image-\(index).jpg")
            try? files.setPrivateFileProtection(at: fileURL)
            let data = try files.readData(at: fileURL)
            return ComposerImageDraftSnapshot(filename: reference.filename, previewData: data, uploadData: data)
        }
    }

    fileprivate func cleanupMetadata(filename: String, session: AppStorageSession) -> Data? {
        let allowsWrite = filename == "gallery.json"
            ? readDraft(StoredGalleryComposerDraft.self, filename: filename, session: session).result.allowsWrite
            : readDraft(StoredDeveloperSuggestionDraft.self, filename: filename, session: session).result.allowsWrite
        return allowsWrite ? metadata(filename: filename, session: session) : nil
    }

    fileprivate func remove(filename: String, session: AppStorageSession) {
        for url in Set([currentFileURL(for: filename, session: session),
                        legacyAccountFileURL(for: filename, session: session), directoryURL.appendingPathComponent(filename)]) {
            try? files.removeItem(at: url)
            try? files.removeItem(at: url.appendingPathExtension("assets"))
        }
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

    fileprivate func storedGalleryRevision(at url: URL) -> String? {
        guard let data = readData(at: url) else { return nil }
        return try? JSONDecoder().decode(StoredGalleryComposerDraft.self, from: data).assetRevision
    }

    fileprivate func storedSuggestionRevision(at url: URL) -> String? {
        guard let data = readData(at: url) else { return nil }
        return try? JSONDecoder().decode(StoredDeveloperSuggestionDraft.self, from: data).assetRevision
    }

    private func removeAssets(for filename: String, revision: String, session: AppStorageSession) {
        try? files.removeItem(at: assetDirectoryURL(for: filename, revision: revision, session: session))
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

    func cleanupMetadata(store: ComposerDraftStore, filename: String, session: AppStorageSession) -> Data? {
        store.cleanupMetadata(filename: filename, session: session)
    }

    func removeMatching(store: ComposerDraftStore, filename: String, session: AppStorageSession, metadata: Data?) {
        guard let metadata, store.cleanupMetadata(filename: filename, session: session) == metadata else { return }
        store.remove(filename: filename, session: session)
    }

    func removeGallery(store: ComposerDraftStore, session: AppStorageSession) {
        store.remove(filename: "gallery.json", session: session)
    }

    func removeSuggestion(store: ComposerDraftStore, session: AppStorageSession) {
        store.remove(filename: "suggestion.json", session: session)
    }
}
