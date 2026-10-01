import CommunityCore
import StorageCore
import Foundation
import OSLog

private nonisolated struct StoredComposerDraftImage: Codable {
    let filename: String
}

private nonisolated struct StoredGalleryComposerDraft: Codable {
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
}

private nonisolated struct StoredDeveloperSuggestionDraft: Codable {
    let schemaVersion: Int
    let assetRevision: String
    let text: String
    let contact: String
    let images: [StoredComposerDraftImage]
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
    public func loadGallery() async -> GalleryComposerDraftSnapshot? {
        await storage.loadGallery(store: self, session: currentSession())
    }

    @discardableResult
    fileprivate func persistGallery(_ snapshot: GalleryComposerDraftSnapshot, session: AppStorageSession) -> Bool {
        let fileURL = currentFileURL(for: "gallery.json", session: session)
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

    fileprivate func loadGallery(session: AppStorageSession) -> GalleryComposerDraftSnapshot? {
        let currentURL = currentFileURL(for: "gallery.json", session: session)
        if let data = readData(at: currentURL) {
            if let stored = try? JSONDecoder().decode(StoredGalleryComposerDraft.self, from: data),
               stored.schemaVersion == Self.currentSchemaVersion,
               let images = readImages(stored.images, filename: "gallery.json", revision: stored.assetRevision, session: session) {
                return GalleryComposerDraftSnapshot(
                    title: stored.title,
                    text: stored.text,
                    selectedTags: stored.selectedTags,
                    customTags: stored.customTags,
                    anonymous: stored.anonymous,
                    isPublic: stored.isPublic,
                    selectedClaimID: stored.selectedClaimID,
                    images: images
                )
            }
            if let legacy = try? JSONDecoder().decode(GalleryComposerDraftSnapshot.self, from: data) {
                _ = persistGallery(legacy, session: session)
                return legacy
            }
        }

        let previousAccountURL = legacyAccountFileURL(for: "gallery.json", session: session)
        if previousAccountURL != currentURL, let data = readData(at: previousAccountURL) {
            if let stored = try? JSONDecoder().decode(StoredGalleryComposerDraft.self, from: data),
               stored.schemaVersion == Self.currentSchemaVersion,
               let images = readImages(
                   stored.images,
                   filename: "gallery.json",
                   revision: stored.assetRevision,
                   session: session,
                   assetDirectory: legacyAssetDirectoryURL(
                       for: "gallery.json",
                       revision: stored.assetRevision,
                       session: session
                   )
               ) {
                let migrated = GalleryComposerDraftSnapshot(
                    title: stored.title,
                    text: stored.text,
                    selectedTags: stored.selectedTags,
                    customTags: stored.customTags,
                    anonymous: stored.anonymous,
                    isPublic: stored.isPublic,
                    selectedClaimID: stored.selectedClaimID,
                    images: images
                )
                if persistGallery(migrated, session: session) {
                    try? files.removeItem(at: previousAccountURL)
                    try? files.removeItem(at: previousAccountURL.appendingPathExtension("assets"))
                }
                return migrated
            }
            if let legacy = try? JSONDecoder().decode(GalleryComposerDraftSnapshot.self, from: data) {
                if persistGallery(legacy, session: session) { try? files.removeItem(at: previousAccountURL) }
                return legacy
            }
        }

        let legacyURL = directoryURL.appendingPathComponent("gallery.json")
        guard let data = readData(at: legacyURL),
              let legacy = try? JSONDecoder().decode(GalleryComposerDraftSnapshot.self, from: data)
        else { return nil }
        if persistGallery(legacy, session: session) {
            try? files.removeItem(at: legacyURL)
        }
        return legacy
    }

    @discardableResult
    @MainActor
    public func saveSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot) async -> Bool {
        await storage.saveSuggestion(store: self, snapshot, session: currentSession())
    }

    @MainActor
    public func loadSuggestion() async -> DeveloperSuggestionDraftSnapshot? {
        await storage.loadSuggestion(store: self, session: currentSession())
    }

    @discardableResult
    fileprivate func persistSuggestion(_ snapshot: DeveloperSuggestionDraftSnapshot, session: AppStorageSession) -> Bool {
        let fileURL = currentFileURL(for: "suggestion.json", session: session)
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

    fileprivate func loadSuggestion(session: AppStorageSession) -> DeveloperSuggestionDraftSnapshot? {
        let currentURL = currentFileURL(for: "suggestion.json", session: session)
        if let data = readData(at: currentURL) {
            if let stored = try? JSONDecoder().decode(StoredDeveloperSuggestionDraft.self, from: data),
               stored.schemaVersion == Self.currentSchemaVersion,
               let images = readImages(stored.images, filename: "suggestion.json", revision: stored.assetRevision, session: session) {
                return DeveloperSuggestionDraftSnapshot(
                    text: stored.text,
                    images: images,
                    contact: stored.contact
                )
            }
            if let legacy = try? JSONDecoder().decode(DeveloperSuggestionDraftSnapshot.self, from: data) {
                _ = persistSuggestion(legacy, session: session)
                return legacy
            }
        }

        let previousAccountURL = legacyAccountFileURL(for: "suggestion.json", session: session)
        if previousAccountURL != currentURL, let data = readData(at: previousAccountURL) {
            if let stored = try? JSONDecoder().decode(StoredDeveloperSuggestionDraft.self, from: data),
               stored.schemaVersion == Self.currentSchemaVersion,
               let images = readImages(
                   stored.images,
                   filename: "suggestion.json",
                   revision: stored.assetRevision,
                   session: session,
                   assetDirectory: legacyAssetDirectoryURL(
                       for: "suggestion.json",
                       revision: stored.assetRevision,
                       session: session
                   )
               ) {
                let migrated = DeveloperSuggestionDraftSnapshot(
                    text: stored.text,
                    images: images,
                    contact: stored.contact
                )
                if persistSuggestion(migrated, session: session) {
                    try? files.removeItem(at: previousAccountURL)
                    try? files.removeItem(at: previousAccountURL.appendingPathExtension("assets"))
                }
                return migrated
            }
            if let legacy = try? JSONDecoder().decode(DeveloperSuggestionDraftSnapshot.self, from: data) {
                if persistSuggestion(legacy, session: session) { try? files.removeItem(at: previousAccountURL) }
                return legacy
            }
        }

        let legacyURL = directoryURL.appendingPathComponent("suggestion.json")
        guard let data = readData(at: legacyURL),
              let legacy = try? JSONDecoder().decode(DeveloperSuggestionDraftSnapshot.self, from: data)
        else { return nil }
        if persistSuggestion(legacy, session: session) {
            try? files.removeItem(at: legacyURL)
        }
        return legacy
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
        let metadata = await storage.metadata(store: self, filename: filename, session: session)
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
        _ references: [StoredComposerDraftImage],
        filename: String,
        revision: String,
        session: AppStorageSession,
        assetDirectory: URL? = nil
    ) -> [ComposerImageDraftSnapshot]? {
        let directory = assetDirectory ?? assetDirectoryURL(for: filename, revision: revision, session: session)
        var images: [ComposerImageDraftSnapshot] = []
        for (index, reference) in references.enumerated() {
            let fileURL = directory.appending(path: "image-\(index).jpg")
            guard let data = readData(at: fileURL) else { return nil }
            images.append(ComposerImageDraftSnapshot(
                filename: reference.filename,
                previewData: data,
                uploadData: data
            ))
        }
        return images
    }

    fileprivate func remove(filename: String, session: AppStorageSession) {
        try? files.removeItem(at: currentFileURL(for: filename, session: session))
        try? files.removeItem(at: directoryURL.appendingPathComponent(filename))
        try? files.removeItem(at: assetRootURL(for: filename, session: session))
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

    private func legacyAssetDirectoryURL(
        for filename: String,
        revision: String,
        session: AppStorageSession
    ) -> URL {
        legacyAccountFileURL(for: filename, session: session)
            .appendingPathExtension("assets")
            .appending(path: revision, directoryHint: .isDirectory)
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

    func loadGallery(store: ComposerDraftStore, session: AppStorageSession) -> GalleryComposerDraftSnapshot? {
        store.loadGallery(session: session)
    }

    func saveSuggestion(store: ComposerDraftStore, _ snapshot: DeveloperSuggestionDraftSnapshot, session: AppStorageSession) -> Bool {
        store.persistSuggestion(snapshot, session: session)
    }

    func loadSuggestion(store: ComposerDraftStore, session: AppStorageSession) -> DeveloperSuggestionDraftSnapshot? {
        store.loadSuggestion(session: session)
    }

    func metadata(store: ComposerDraftStore, filename: String, session: AppStorageSession) -> Data? {
        store.metadata(filename: filename, session: session)
    }

    func removeMatching(store: ComposerDraftStore, filename: String, session: AppStorageSession, metadata: Data?) {
        guard let metadata, store.metadata(filename: filename, session: session) == metadata else { return }
        store.remove(filename: filename, session: session)
    }

    func removeGallery(store: ComposerDraftStore, session: AppStorageSession) {
        store.remove(filename: "gallery.json", session: session)
    }

    func removeSuggestion(store: ComposerDraftStore, session: AppStorageSession) {
        store.remove(filename: "suggestion.json", session: session)
    }
}
