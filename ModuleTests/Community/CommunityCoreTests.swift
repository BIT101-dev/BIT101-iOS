import CommunityPersistence
import Combine
import BIT101TestSupport
import CommunityUI
import StorageCore
import CommunityCore
import Foundation
import Testing

@MainActor
struct CommunityCoreTests {
    @Test func unreadCandidatesSurviveNewNotificationsManualReadsAndReload() throws {
        let domain = "BIT101ModulesTests.unread-candidates"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "unread-candidates")
        let store = GalleryMessageReadStore(defaults: defaults, session: { session })
        store.replaceLatestIDs([5, 4, 3], unreadCount: 3, for: .comment)
        store.markSeen(ids: [4], for: .comment)
        store.replaceLatestIDs([6, 5], unreadCount: 1, for: .comment)
        let reopened = GalleryMessageReadStore(defaults: defaults, session: { session })
        #expect(reopened.unreadCount(for: .comment) == 3)
        #expect(reopened.isUnread(id: 3, for: .comment))
        #expect(!reopened.isUnread(id: 4, for: .comment))
        reopened.replaceLatestIDs([], unreadCount: 0, for: .comment)
        #expect(reopened.unreadCount(for: .comment) == 3)
        reopened.replaceLatestIDs(Array(1...2_000), unreadCount: 2_000, for: .like)
        #expect(reopened.unreadCount(for: .like) == GalleryMessageReadSnapshot.maximumHistoryIDsPerType)
    }

    @Test func damagedMessageReadStatePreservesBytesAndSuppressesSaveEvents() throws {
        let domain = "BIT101ModulesTests.message-corruption"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "message-corruption")
        let store = GalleryMessageReadStore(defaults: defaults, session: { session })
        let key = session.key("gallery.message.read.snapshot")
        let damaged = Data("damaged".utf8)
        defaults.set(damaged, forKey: key)
        #expect(store.hasUnreadableSnapshot)
        var saves = 0
        let subscription = store.localSaves.sink { _ in saves += 1 }
        store.markSeen(ids: [1], for: .comment)
        store.replaceLatestIDs([1, 2], unreadCount: 2, for: .comment)
        var remote = GalleryMessageReadSnapshot()
        remote.seenIDsByType = ["comment": [3]]
        store.applySyncedSnapshot(remote)
        #expect(defaults.data(forKey: key) == damaged)
        #expect(saves == 0)
        #expect(store.unreadCount(for: .comment) == 0)
        subscription.cancel()
    }

    @Test func messageReadHistoryStaysBoundedAndItsRetirementBoundaryConverges() throws {
        let domain = "BIT101ModulesTests.message-history"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = AppStorageSession(accountIdentifier: "history")
        let store = GalleryMessageReadStore(defaults: defaults, session: { account })
        store.replaceLatestIDs([1, 10_000, 10_001], unreadCount: 3, for: .comment)
        store.markSeen(ids: Array(1...10_000), for: .comment)
        let snapshot = store.syncSnapshot()
        #expect(snapshot.seenIDsByType["comment"]?.count == GalleryMessageReadSnapshot.maximumHistoryIDsPerType)
        #expect(snapshot.retainedFromIDByType["comment"] == 8_977)
        #expect(store.unreadCount(for: .comment) == 1)
        #expect(!store.isUnread(id: 1, for: .comment))
        #expect(store.isUnread(id: 10_001, for: .comment))
        let reopened = GalleryMessageReadStore(defaults: defaults, session: { account })
        #expect(reopened.syncSnapshot() == snapshot)
        reopened.markSeen(ids: [10_001], for: .comment)
        #expect(store.unreadCount(for: .comment) == 0)
        var older = GalleryMessageReadSnapshot()
        older.seenIDsByType = ["comment": [1, 2, 10_002]]
        let forward = snapshot.mergingReadState(older)
        let backward = older.mergingReadState(snapshot)
        #expect(forward.seenIDsByType == backward.seenIDsByType)
        #expect(forward.retainedFromIDByType == backward.retainedFromIDByType)
        #expect(forward.seenIDsByType["comment"]?.count == GalleryMessageReadSnapshot.maximumHistoryIDsPerType)
        #expect(forward.retainedFromIDByType["comment"] == 8_978)
        let legacy = try JSONDecoder().decode(GalleryMessageReadSnapshot.self,
            from: Data(#"{"latestIDsByType":{"comment":[1]},"seenIDsByType":{"comment":[1]}}"#.utf8))
        #expect(legacy.retainedFromIDByType.isEmpty)
        #expect(legacy.seenIDsByType["comment"] == [1])
    }

    @Test func messageStorageSeparatesAccountChangesFromLocalUploads() throws {
        let domain = "BIT101ModulesTests.message-storage"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "messages")
        let store = GalleryMessageReadStore(defaults: defaults, session: { session })
        let other = GalleryMessageReadStore(defaults: defaults, session: { session })
        var changes: [AppStorageSession] = []
        var uploads: [AppStorageSession] = []
        var otherChanges: [AppStorageSession] = []
        let subscriptions = [
            store.changes.sink { changes.append($0) },
            store.localSaves.sink { uploads.append($0) },
            other.changes.sink { otherChanges.append($0) }
        ]
        store.replaceLatestIDs([42], unreadCount: 1, for: .comment)
        #expect(uploads == [session])
        #expect(changes == [session])
        var remote = GalleryMessageReadSnapshot()
        remote.latestIDsByType = ["comment": [42]]
        remote.seenIDsByType = ["comment": [42]]
        store.applySyncedSnapshot(remote)
        #expect(store.unreadCount(for: .comment) == 0)
        #expect(changes == [session, session])
        #expect(uploads == [session])
        #expect(otherChanges.isEmpty)
        withExtendedLifetime(subscriptions) {}
    }

    @Test func communityImageDecodesExistingWireKeys() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let image = try decoder.decode(CommunityImage.self, from: Data(#"{"mid":"image","url":"https://example.invalid/image.gif","low_url":"https://example.invalid/thumbnail.jpg"}"#.utf8))
        #expect(image.id == "image")
        #expect(image.lowUrl.hasSuffix("thumbnail.jpg"))
        #expect(image.isGIF)
    }

    @Test func commentCopiesPreserveIdentityAndReplyTree() {
        let user = CommunityUser.placeholder(id: 42, nickname: "用户")
        let comment = CommunityComment(
            id: 17, obj: "course17", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 2, commentNum: 0,
            own: true, rate: 5, replyUser: user, replyObj: "", text: "评论", sub: []
        )
        let liked = comment.updatingLike(true, likeNum: 3)
        #expect(liked.id == comment.id)
        #expect(liked.obj == comment.obj)
        #expect(liked.text == comment.text)
        #expect(liked.user == user)
        #expect(liked.like && liked.likeNum == 3)
        let thread = comment.replacingSubComments([liked])
        #expect(thread.sub == [liked])
        #expect(thread.like == comment.like)
        var state = CommunityCommentState()
        state.applyFirstPage([thread, thread])
        #expect(state.items == [thread])
        #expect(state.nextPage == 1)
        state.appendPage([thread, liked, liked])
        #expect(state.items == [thread])
        #expect(state.nextPage == 2 && state.canLoadMore)
        state.appendPage([])
        #expect(state.canLoadMore == false)
    }

    @Test func accountStorePreservesLegacyKeysAndSeparatesAccounts() throws {
        let suite = "BIT101ModulesTests.storage"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var session = AppStorageSession(accountIdentifier: "module-a")
        defaults.set(try JSONEncoder().encode(["old-value"]), forKey: session.legacyKey("module-test"))
        let store = AccountScopedCodableStore<[String]>(keyPrefix: "module-test", defaults: defaults, sessionProvider: { session })
        #expect(store.load() == ["old-value"])
        #expect(defaults.data(forKey: session.legacyKey("module-test")) == nil)
        #expect(defaults.data(forKey: store.storageKey) != nil)
        session = AppStorageSession(accountIdentifier: "module-b")
        #expect(store.load() == nil)
        store.save(["account-b"])
        session = AppStorageSession(accountIdentifier: "module-a")
        #expect(store.load() == ["old-value"])
        let guestStore = AccountScopedCodableStore<[String]>(
            keyPrefix: "module-test", defaults: defaults, sessionProvider: { session }, guestIdentifier: "__default__"
        )
        session = AppStorageSession(accountIdentifier: "")
        guestStore.save(["guest-value"])
        #expect(guestStore.storageKey == "module-test.__default__")
        #expect(guestStore.load() == ["guest-value"])
        #expect(store.load() == nil)
        session = AppStorageSession(accountIdentifier: "module-a")
        #expect(guestStore.load() == ["old-value"])
    }
}

@MainActor
struct ComposerPublicContractTests {
    private final class Account {
        var session = AppStorageSession(accountIdentifier: "composer-A")
    }
    @Test func imagePreparationAndStoredBytesFollowTheSelectedBackend() async throws {
        let files = ModuleScoreFiles()
        let session = AppStorageSession(accountIdentifier: "composer-A")
        let store = ComposerDraftStore(files: files, applicationSupport: URL(fileURLWithPath: "/module-composer"),
            session: { session }, prepareImageData: { Data([42]) + $0 })
        let snapshot = DeveloperSuggestionDraftSnapshot(text: "draft", images: [
            ComposerImageDraftSnapshot(filename: "image.jpg", previewData: Data([7]), uploadData: nil)
        ], contact: "contact")
        #expect(await store.saveSuggestion(snapshot))
        let restored = try #require(await store.loadSuggestion().snapshot)
        #expect(restored.text == snapshot.text)
        #expect(restored.contact == snapshot.contact)
        #expect(restored.images.first?.uploadData == Data([42, 7]))
        #expect(restored.images.first?.previewData == Data([42, 7]))
        let url = URL(fileURLWithPath: "/module-composer/BIT101-iOS")
            .appending(path: session.accountStorageIdentifier).appending(path: "composer-suggestion.json")
        #expect(files.writingOptions(at: url)?.contains(.atomic) == true)
        files.setFailures(writing: true)
        #expect(await store.saveSuggestion(.init(text: "next", images: [])) == false)
        #expect(await store.loadSuggestion().snapshot?.text == "draft")
    }

    @Test func capturedCleanupMatchesTheAccountAndSavedRevision() async {
        let account = Account()
        let store = ComposerDraftStore(files: ModuleScoreFiles(), applicationSupport: URL(fileURLWithPath: "/module-composer"),
            session: { account.session }, prepareImageData: { $0 })
        #expect(await store.saveSuggestion(.init(text: "A", images: [])))
        let cleanup = await store.captureSuggestionCleanup()
        account.session = AppStorageSession(accountIdentifier: "composer-B")
        #expect(await store.saveSuggestion(.init(text: "B", images: [])))
        await cleanup()
        #expect(await store.loadSuggestion().snapshot?.text == "B")
        account.session = AppStorageSession(accountIdentifier: "composer-A")
        #expect(await store.loadSuggestion().snapshot == nil)
        #expect(await store.saveSuggestion(.init(text: "submitted", images: [])))
        let oldCleanup = await store.captureSuggestionCleanup()
        #expect(await store.saveSuggestion(.init(text: "continued", images: [])))
        await oldCleanup()
        #expect(await store.loadSuggestion().snapshot?.text == "continued")
    }

    @Test func preparedImageSizeIsEnforcedAtTheStorageBoundary() async {
        let store = ComposerDraftStore(files: ModuleScoreFiles(), applicationSupport: URL(fileURLWithPath: "/module-composer"),
            session: { AppStorageSession(accountIdentifier: "composer-A") },
            prepareImageData: { _ in Data(count: ComposerDraftImagePolicy.maximumBytes + 1) })
        #expect(await store.saveSuggestion(.init(text: "saved", images: [])))
        #expect(await store.saveSuggestion(.init(text: "oversized", images: [
            .init(filename: "image.jpg", previewData: Data([1]), uploadData: nil)
        ])) == false)
        #expect(await store.loadSuggestion().snapshot?.text == "saved")
    }
}

@MainActor
struct ComposerRecoveryTests {
    private let session = AppStorageSession(accountIdentifier: "composer-recovery")
    private let root = URL(fileURLWithPath: "/composer-recovery")

    private func store(_ files: ModuleScoreFiles) -> ComposerDraftStore {
        ComposerDraftStore(files: files, applicationSupport: root, session: { session }, prepareImageData: { $0 })
    }

    private func file(_ name: String, legacyAccount: Bool = false) -> URL {
        root.appending(path: "BIT101-iOS")
            .appending(path: legacyAccount ? session.legacyAccountDirectoryNameForMigration : session.accountStorageIdentifier)
            .appending(path: "composer-\(name).json")
    }

    private func legacyData(_ name: String, text: String = "原草稿", images: [ComposerImageDraftSnapshot] = [
        .init(filename: "image.jpg", previewData: Data([1, 2]), uploadData: nil)]) throws -> Data {
        return name == "gallery"
            ? try JSONEncoder().encode(GalleryComposerDraftSnapshot(title: "标题", text: text, selectedTags: ["校园", "生活"],
                customTags: [], anonymous: false, isPublic: true, selectedClaimID: 0, images: images))
            : try JSONEncoder().encode(DeveloperSuggestionDraftSnapshot(text: text, images: images, contact: "联系信息"))
    }

    private func save(_ store: ComposerDraftStore, _ name: String, text: String = "新草稿", images: [ComposerImageDraftSnapshot] = []) async -> Bool {
        if name == "gallery" {
            return await store.saveGallery(.init(title: "标题", text: text, selectedTags: ["校园", "生活"], customTags: [],
                anonymous: false, isPublic: true, selectedClaimID: 0, images: images))
        }
        return await store.saveSuggestion(.init(text: text, images: images, contact: "联系信息"))
    }

    private func state<T>(_ result: ComposerDraftLoadResult<T>) -> String {
        switch result {
        case .missing: "missing"
        case .loaded(let value):
            if let gallery = value as? GalleryComposerDraftSnapshot { gallery.text }
            else if let suggestion = value as? DeveloperSuggestionDraftSnapshot { suggestion.text }
            else { "loaded" }
        case .unreadable: "unreadable"
        case .unsupportedVersion(let version): "version-\(version)"
        }
    }

    private func read(_ store: ComposerDraftStore, _ name: String) async -> String {
        name == "gallery" ? state(await store.loadGallery()) : state(await store.loadSuggestion())
    }

    private func cleanup(_ store: ComposerDraftStore, _ name: String) async -> ComposerDraftCleanup {
        name == "gallery" ? await store.captureGalleryCleanup() : await store.captureSuggestionCleanup()
    }

    @Test(arguments: ["gallery", "suggestion"], ["sidecar", "references", "legacyBytes", "legacyCount", "metadata"])
    func excessiveDraftResourcesPreserveFilesAndBlockFurtherWrites(_ name: String, damage: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        let metadata = file(name)
        let image = ComposerImageDraftSnapshot(filename: "image.jpg", previewData: Data([7]), uploadData: nil)
        #expect(await save(drafts, name, images: [image]))
        var payload = try #require(JSONSerialization.jsonObject(with: files.readData(at: metadata)) as? [String: Any])
        let revision = try #require(payload["assetRevision"] as? String)
        let asset = metadata.appendingPathExtension("assets").appending(path: revision).appending(path: "image-0.jpg")
        if damage == "sidecar" {
            try files.writeData(Data(count: ComposerDraftImagePolicy.maximumBytes + 1), to: asset, options: [.atomic])
        } else if damage == "references" {
            payload["images"] = Array(repeating: ["filename": "image.jpg"], count: ComposerDraftImagePolicy.maximumImageCount + 1)
            try files.writeData(try JSONSerialization.data(withJSONObject: payload), to: metadata, options: [.atomic])
        } else if damage == "metadata" {
            let text = String(repeating: "x", count: ComposerDraftImagePolicy.maximumLegacyMetadataBytes + 1)
            try files.writeData(try legacyData(name, text: text), to: metadata, options: [.atomic])
        } else {
            let images = damage == "legacyCount" ? Array(repeating: image, count: ComposerDraftImagePolicy.maximumImageCount + 1)
                : [.init(filename: "image.jpg", previewData: Data(count: ComposerDraftImagePolicy.maximumBytes + 1), uploadData: nil)]
            try files.writeData(try legacyData(name, images: images), to: metadata, options: [.atomic])
        }
        let original = files.storedData
        let reads = files.readCount(at: damage == "metadata" ? metadata : asset)
        #expect(await read(drafts, name) == "unreadable")
        if ["metadata", "references", "sidecar"].contains(damage) { #expect(files.readCount(at: damage == "metadata" ? metadata : asset) == reads) }
        #expect(await save(drafts, name) == false)
        await cleanup(drafts, name)()
        #expect(files.storedData == original)
    }

    @Test(arguments: ["gallery", "suggestion"])
    func attachmentCountAdmissionPreservesThePreviousDraft(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await save(drafts, name))
        let original = files.storedData
        let image = ComposerImageDraftSnapshot(filename: "image.jpg", previewData: Data([7]), uploadData: nil)
        #expect(await save(drafts, name, images: Array(repeating: image, count: ComposerDraftImagePolicy.maximumImageCount + 1)) == false)
        #expect(files.storedData == original)
    }

    @Test(arguments: ["gallery", "suggestion"])
    func missingDraftAllowsFirstSave(_ name: String) async {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await read(drafts, name) == "missing")
        #expect(await save(drafts, name))
        #expect(await read(drafts, name) == "新草稿")
    }

    @Test(arguments: ["gallery", "suggestion"])
    func malformedMetadataBlocksSavingAndSubmissionCleanup(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await save(drafts, name, images: [.init(filename: "image.jpg", previewData: Data([7]), uploadData: nil)]))
        try files.writeData(Data("damaged".utf8), to: file(name), options: [.atomic])
        let original = files.storedData
        #expect(await read(drafts, name) == "unreadable")
        #expect(await save(drafts, name) == false)
        await cleanup(drafts, name)()
        #expect(files.storedData == original)
    }

    @Test(arguments: ["gallery", "suggestion"])
    func futureFormatsKeepMetadataAndImagesThroughEveryOperation(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await save(drafts, name))
        var payload = try #require(JSONSerialization.jsonObject(with: files.readData(at: file(name))) as? [String: Any])
        payload["schemaVersion"] = 2
        payload["futureField"] = "保留此字段"
        try files.writeData(try JSONSerialization.data(withJSONObject: payload), to: file(name), options: [.atomic])
        let original = files.storedData
        #expect(await read(drafts, name) == "version-2")
        #expect(await save(drafts, name) == false)
        await cleanup(drafts, name)()
        #expect(files.storedData == original)
    }

    @Test(arguments: ["gallery", "suggestion"], ["nullVersion", "textVersion", "assetPath"])
    func malformedFormatHeadersKeepTheCompleteSource(_ name: String, _ defect: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await save(drafts, name))
        var payload = try #require(JSONSerialization.jsonObject(with: files.readData(at: file(name))) as? [String: Any])
        if defect == "nullVersion" { payload["schemaVersion"] = NSNull() }
        if defect == "textVersion" { payload["schemaVersion"] = "1" }
        if defect == "assetPath" { payload["assetRevision"] = "../other-assets" }
        try files.writeData(try JSONSerialization.data(withJSONObject: payload), to: file(name), options: [.atomic])
        let original = files.storedData
        #expect(await read(drafts, name) == "unreadable")
        #expect(await save(drafts, name) == false)
        #expect(files.storedData == original)
    }

    @Test(arguments: ["gallery", "suggestion"])
    func missingImageProtectsTheWholeDraft(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        let images = [1, 2].map { ComposerImageDraftSnapshot(filename: "\($0).jpg", previewData: Data([UInt8($0)]), uploadData: nil) }
        #expect(await save(drafts, name, images: images))
        let submittedCleanup = await cleanup(drafts, name)
        let imageURL = try #require(files.storedData.keys.first { $0.lastPathComponent == "image-0.jpg" })
        try files.removeItem(at: imageURL)
        let original = files.storedData
        #expect(await read(drafts, name) == "unreadable")
        #expect(await save(drafts, name) == false)
        await submittedCleanup()
        #expect(files.storedData == original)
    }

    @Test(arguments: ["gallery", "suggestion"])
    func readFailureKeepsTheSourceAndWriteGate(_ name: String) async {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await save(drafts, name))
        let original = files.storedData
        files.setFailures(reading: true)
        #expect(await read(drafts, name) == "unreadable")
        #expect(await save(drafts, name) == false)
        #expect(files.storedData == original)
        files.setFailures()
        #expect(await read(drafts, name) == "新草稿")
    }

    @Test(arguments: ["gallery", "suggestion"])
    func currentRecoveryStateTakesPrecedenceOverLegacySources(_ name: String) async throws {
        let files = ModuleScoreFiles()
        try files.writeData(Data("damaged".utf8), to: file(name), options: [.atomic])
        try files.writeData(try legacyData(name), to: file(name, legacyAccount: true), options: [.atomic])
        try files.writeData(try legacyData(name), to: root.appending(path: "ComposerDrafts/\(name).json"), options: [.atomic])
        let original = files.storedData
        let drafts = store(files)
        #expect(await read(drafts, name) == "unreadable")
        #expect(await save(drafts, name) == false)
        #expect(files.storedData == original)
    }

    @Test(arguments: ["gallery", "suggestion"], ["current", "account", "shared"])
    func legacySnapshotsMigrateAtTheirOwningSource(_ name: String, _ location: String) async throws {
        let files = ModuleScoreFiles()
        let source = location == "shared" ? root.appending(path: "ComposerDrafts/\(name).json")
            : file(name, legacyAccount: location == "account")
        try files.writeData(try legacyData(name), to: source, options: [.atomic])
        let drafts = store(files)
        #expect(await read(drafts, name) == "原草稿")
        #expect(await read(drafts, name) == "原草稿")
        let metadata = try #require(JSONSerialization.jsonObject(with: files.readData(at: file(name))) as? [String: Any])
        #expect(metadata["schemaVersion"] as? Int == 1)
        if source != file(name) { #expect(files.fileExists(at: source) == false) }
        #expect(files.storedData.values.contains(Data([1, 2])))
    }

    @Test(arguments: ["gallery", "suggestion"])
    func accountDirectoryMigrationMovesVersionedImagesAtomically(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await save(drafts, name, text: "原草稿", images: [.init(filename: "image.jpg", previewData: Data([8]), uploadData: nil)]))
        let previousURL = file(name, legacyAccount: true)
        for (url, data) in files.storedData {
            let destination = URL(fileURLWithPath: url.path.replacingOccurrences(of: file(name).path, with: previousURL.path))
            try files.writeData(data, to: destination, options: [.atomic])
        }
        try files.removeItem(at: file(name))
        try files.removeItem(at: file(name).appendingPathExtension("assets"))
        #expect(await read(drafts, name) == "原草稿")
        #expect(files.fileExists(at: previousURL) == false)
        #expect(files.storedData.keys.contains { $0.path.hasPrefix(previousURL.path) } == false)
        #expect(files.storedData.values.contains(Data([8])))
    }

    @Test(arguments: ["gallery", "suggestion"])
    func migrationWriteFailureRetainsItsReadableSource(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let source = file(name, legacyAccount: true)
        try files.writeData(try legacyData(name), to: source, options: [.atomic])
        let original = files.storedData
        files.setFailures(writing: true)
        #expect(await read(store(files), name) == "原草稿")
        #expect(files.storedData == original)
    }

    @Test(arguments: ["gallery", "suggestion"])
    func explicitDiscardReleasesTheRecoveryGate(_ name: String) async throws {
        let files = ModuleScoreFiles()
        try files.writeData(Data("damaged".utf8), to: file(name), options: [.atomic])
        let drafts = store(files)
        if name == "gallery" { await drafts.removeGallery() } else { await drafts.removeSuggestion() }
        #expect(await read(drafts, name) == "missing")
        #expect(await save(drafts, name))
    }
}

@MainActor
struct AccountStorageContractTests {
    private enum Payload: Codable {
        case value(String)
        case rejected
        init(from decoder: Decoder) throws { self = .value(try decoder.singleValueContainer().decode(String.self)) }
        func encode(to encoder: Encoder) throws {
            guard case .value(let text) = self else {
                throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "injected encoding failure"))
            }
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }
    }

    @Test func accountTokensAreNormalizedOpaqueAndIdempotent() {
        let token = AccountStorageIdentity.stableToken(for: " student-A ")
        #expect(token == AccountStorageIdentity.stableToken(for: "student-A"))
        #expect(token.count == "account-".count + 64)
        #expect(token != AccountStorageIdentity.stableToken(for: "student-B"))
        #expect(AccountStorageIdentity.stableToken(for: token) == token)
        #expect(AccountStorageIdentity.stableToken(for: " ") == "__default__")
        #expect(AccountStorageIdentity.stableToken(for: "account-invalid") != "account-invalid")
        #expect(AccountStorageIdentity.stableToken(for: "account-" + String(repeating: "z", count: 64)).hasSuffix(String(repeating: "z", count: 64)) == false)
    }

    @Test func directoryAndPreferenceMappingsSeparateGuestAndSpecialCharacters() {
        let guest = AppStorageSession(accountIdentifier: " ")
        #expect(guest.isGuest)
        #expect(guest.accountDirectoryName == "__default__")
        #expect(guest.legacyAccountDirectoryName == "__default__")
        #expect(guest.key("settings", guestIdentifier: "__default__") == "settings.__default__")
        #expect(guest.legacyKey("messages") == "messages.guest")
        let first = AppStorageSession(accountIdentifier: " A/B ")
        let second = AppStorageSession(accountIdentifier: "A?B")
        #expect(first.accountIdentifier == "A/B")
        #expect(first.accountDirectoryName == "__encoded__412F42")
        #expect(first.legacyAccountDirectoryName == "A_B")
        #expect(first.legacyAccountDirectoryName == second.legacyAccountDirectoryName)
        #expect(first.legacyAccountDirectoryNameForMigration != second.legacyAccountDirectoryNameForMigration)
        #expect(first.key("cache") != second.key("cache"))
        #expect(first.legacyKey("cache") == "cache.A/B")
    }

    @Test func preferenceEncodingFailureAndRemovalKeepAccountOwnership() throws {
        let domain = "BIT101ModulesTests.preference-failures"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var session = AppStorageSession(accountIdentifier: "A")
        let store = AccountScopedCodableStore<Payload>(keyPrefix: "payload", defaults: defaults, sessionProvider: { session })
        store.save(.value("original"))
        let original = defaults.data(forKey: store.storageKey)
        store.save(.rejected)
        #expect(defaults.data(forKey: store.storageKey) == original)
        session = AppStorageSession(accountIdentifier: "B")
        store.save(.value("second"))
        store.remove()
        #expect(store.load() == nil)
        session = AppStorageSession(accountIdentifier: "A")
        #expect(defaults.data(forKey: store.storageKey) == original)
        defaults.set(Data("damaged".utf8), forKey: store.storageKey)
        #expect(store.load() == nil)
        #expect(!store.save(.value("replacement")))
        #expect(defaults.data(forKey: store.storageKey) == Data("damaged".utf8))
        defaults.set(true, forKey: store.storageKey)
        #expect(!store.save(.value("replacement")))
        #expect(defaults.object(forKey: store.storageKey) as? Bool == true)
        store.remove()
        #expect(defaults.data(forKey: store.storageKey) == nil)
    }

    @Test func fileStoresMigrateAtomicallyAndFollowCapturedAccountPaths() throws {
        let files = ModuleScoreFiles()
        var session = AppStorageSession(accountIdentifier: "A/B")
        let root = URL(fileURLWithPath: "/storage-contract")
        let old = root.appending(path: "BIT101-iOS").appending(path: session.legacyAccountDirectoryNameForMigration).appending(path: "values.json")
        try files.writeData(try JSONEncoder().encode(["legacy"]), to: old, options: [.atomic])
        let store = AccountScopedFileCodableStore<[String]>(filename: "values.json", files: files, session: { session }, directory: root)
        #expect(store.load() == ["legacy"])
        let firstURL = store.fileURL
        #expect(firstURL.path.contains(session.accountStorageIdentifier))
        #expect(files.fileExists(at: old) == false)
        #expect(files.writingOptions(at: firstURL)?.contains(.atomic) == true)
        session = AppStorageSession(accountIdentifier: "B")
        #expect(store.load() == nil)
        #expect(store.save(["second"]))
        let secondURL = store.fileURL
        store.remove()
        #expect(files.fileExists(at: secondURL) == false)
        session = AppStorageSession(accountIdentifier: "A/B")
        #expect(store.load() == ["legacy"])
        store.remove()
        #expect(files.fileExists(at: firstURL) == false)
    }

    @Test func fileReadAndWriteFailuresPreserveTheCompleteSnapshot() throws {
        let files = ModuleScoreFiles()
        let store = AccountScopedFileCodableStore<[String]>(filename: "values.json", files: files,
            session: { AppStorageSession(accountIdentifier: "A") }, directory: URL(fileURLWithPath: "/storage-contract"))
        #expect(store.save(["original"]))
        let original = files.storedData
        files.setFailures(reading: true)
        #expect(store.load() == nil)
        #expect(store.save(["next"]) == false)
        #expect(files.storedData == original)
        files.setFailures(writing: true)
        #expect(store.save(["next"]) == false)
        #expect(files.storedData == original)
        files.setFailures(removal: true)
        store.remove()
        #expect(files.storedData == original)
        files.setFailures()
        try files.writeData(Data("damaged".utf8), to: store.fileURL, options: [.atomic])
        #expect(store.load() == nil)
        #expect(store.save(["next"]) == false)
        #expect(try files.readData(at: store.fileURL) == Data("damaged".utf8))
    }

    @Test(arguments: [false, true])
    func unreadableLegacyFilePreservesItsBytesAndKeepsTheCurrentPathAvailableForRecovery(damaged: Bool) throws {
        let files = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/storage-contract")
        let old = root.appending(path: "BIT101-iOS/A/values.json")
        let data = damaged ? Data("damaged".utf8) : try JSONEncoder().encode(["legacy"])
        try files.writeData(data, to: old, options: [.atomic])
        files.setFailures(reading: !damaged)
        let store = AccountScopedFileCodableStore<[String]>(filename: "values.json", files: files,
            session: { AppStorageSession(accountIdentifier: "A") }, directory: root)
        #expect(store.load() == nil)
        #expect(store.save(["next"]) == false)
        #expect(files.fileExists(at: store.fileURL) == false)
        files.setFailures()
        #expect(try files.readData(at: old) == data)
    }

    @Test func legacyMigrationWriteFailuresRetainTheirOriginalBytes() throws {
        let files = ModuleScoreFiles()
        let session = AppStorageSession(accountIdentifier: "A")
        let root = URL(fileURLWithPath: "/storage-contract")
        let old = root.appending(path: "BIT101-iOS/A/values.json")
        let data = try JSONEncoder().encode(["legacy"])
        try files.writeData(data, to: old, options: [.atomic])
        files.setFailures(writing: true)
        let store = AccountScopedFileCodableStore<[String]>(filename: "values.json", files: files, session: { session }, directory: root)
        #expect(store.load() == ["legacy"])
        #expect(try files.readData(at: old) == data)
        #expect(files.fileExists(at: store.fileURL) == false)
        files.setFailures()
        #expect(store.load() == ["legacy"])
        #expect(files.fileExists(at: old) == false)
    }
}
