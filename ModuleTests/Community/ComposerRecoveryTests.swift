import BIT101TestSupport
import Combine
import CommunityCore
import CommunityPersistence
import CommunityUI
import Foundation
import StorageCore
import Testing
import os

@MainActor
struct ComposerRecoveryTests {
    private let session = AppStorageSession(accountIdentifier: "composer-recovery")
    private let root = URL(fileURLWithPath: "/composer-recovery")

    private func store(_ files: ModuleScoreFiles) -> ComposerDraftStore {
        ComposerDraftStore(
            files: files, applicationSupport: root, session: { session }, prepareImageData: { $0 })
    }

    private func file(_ name: String, legacyAccount: Bool = false) -> URL {
        root.appending(path: "BIT101-iOS")
            .appending(
                path: legacyAccount
                    ? session.legacyAccountDirectoryNameForMigration
                    : session.accountStorageIdentifier
            )
            .appending(path: "composer-\(name).json")
    }

    private func legacyData(
        _ name: String, text: String = "原草稿",
        images: [ComposerImageDraftSnapshot] = [
            .init(filename: "image.jpg", previewData: Data([1, 2]), uploadData: nil)
        ]
    ) throws -> Data {
        return name == "gallery"
            ? try JSONEncoder().encode(
                GalleryComposerDraftSnapshot(
                    title: "标题", text: text, selectedTags: ["校园", "生活"],
                    customTags: [], anonymous: false, isPublic: true, selectedClaimID: 0,
                    images: images))
            : try JSONEncoder().encode(
                DeveloperSuggestionDraftSnapshot(text: text, images: images, contact: "联系信息"))
    }

    private func save(
        _ store: ComposerDraftStore, _ name: String, text: String = "新草稿",
        images: [ComposerImageDraftSnapshot] = []
    ) async -> Bool {
        if name == "gallery" {
            return await store.saveGallery(
                .init(
                    title: "标题", text: text, selectedTags: ["校园", "生活"], customTags: [],
                    anonymous: false, isPublic: true, selectedClaimID: 0, images: images))
        }
        return await store.saveSuggestion(.init(text: text, images: images, contact: "联系信息"))
    }

    private func state<T>(_ result: ComposerDraftLoadResult<T>) -> String {
        switch result {
        case .missing: "missing"
        case .loaded(let value):
            if let gallery = value as? GalleryComposerDraftSnapshot {
                gallery.text
            } else if let suggestion = value as? DeveloperSuggestionDraftSnapshot {
                suggestion.text
            } else {
                "loaded"
            }
        case .recovered(_, let count): "recovered-\(count)"
        case .unreadable: "unreadable"
        case .unsupportedVersion(let version): "version-\(version)"
        }
    }

    private func read(_ store: ComposerDraftStore, _ name: String) async -> String {
        name == "gallery" ? state(await store.loadGallery()) : state(await store.loadSuggestion())
    }

    private func cleanup(_ store: ComposerDraftStore, _ name: String) async -> ComposerDraftCleanup
    {
        name == "gallery"
            ? await store.captureGalleryCleanup() : await store.captureSuggestionCleanup()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func imageGrowthKeepsText(_ name: String) async throws {
        let readState = OSAllocatedUnfairLock(
            initialState: (
                reads: 0, files: Optional<ModuleScoreFiles>.none, image: Optional<URL>.none
            ))
        let oversized = Data(count: ComposerDraftImagePolicy.maximumBytes + 1)
        let files = ModuleScoreFiles(beforeReading: {
            let replacement = readState.withLock { state -> (ModuleScoreFiles, URL)? in
                guard let files = state.files, let image = state.image else { return nil }
                state.reads += 1
                return state.reads == 2 ? (files, image) : nil
            }
            if let (files, image) = replacement {
                do { try files.writeData(oversized, to: image, options: [.atomic]) } catch {
                    Issue.record(error)
                }
            }
        })
        let drafts = store(files)
        let image = ComposerImageDraftSnapshot(
            filename: "image.jpg", previewData: Data([7]), uploadData: nil)
        #expect(await save(drafts, name, images: [image]))
        let original = files.storedData
        let asset = try #require(original.keys.first { $0.pathExtension == "jpg" })
        readState.withLock {
            $0.files = files
            $0.image = asset
        }
        #expect(await read(drafts, name) == "recovered-1")
        #expect(files.storedData[file(name)] == original[file(name)])
        #expect(files.storedData[asset] == oversized)
        readState.withLock { $0.files = nil }
        #expect(await save(drafts, name))
        #expect(await read(drafts, name) == "新草稿")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func textEditsReuseImageAssets(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        let image = ComposerImageDraftSnapshot(
            filename: "image.jpg", previewData: Data([7]), uploadData: nil)
        #expect(await save(drafts, name, images: [image]))
        let metadata = file(name)
        let first = try #require(
            JSONSerialization.jsonObject(with: files.readData(at: metadata)) as? [String: Any])
        let old = try #require(first["assetRevision"] as? String)
        let assets = metadata.appendingPathExtension("assets")
        let oldImage = assets.appending(path: old).appending(path: "image-0.jpg")
        let identity = files.atomicFileIdentity(at: oldImage)
        let reads = files.readCount(at: oldImage)
        let interrupted = assets.appending(path: "interrupted", directoryHint: .isDirectory)
        try files.createDirectory(at: interrupted)
        let interruptedImage = interrupted.appending(path: "image-0.jpg")
        try files.writeData(Data([1]), to: interruptedImage, options: [.atomic])
        #expect(files.fileExists(at: assets))
        #expect(await save(drafts, name, text: "更新文字", images: [image]))
        #expect(
            files.atomicFileIdentity(at: oldImage) == identity
                && !files.fileExists(at: interruptedImage))
        #expect(files.readCount(at: oldImage) == reads + 1)
        #expect(await read(drafts, name) == "更新文字")
        #expect(files.storedData.filter { $0.key.path.hasPrefix(assets.path) }.count == 1)
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"],
        ["sidecar", "references", "legacyBytes", "legacyCount", "metadata"])
    func excessiveDraftResourcesSave(_ name: String, damage: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        let metadata = file(name)
        let image = ComposerImageDraftSnapshot(
            filename: "image.jpg", previewData: Data([7]), uploadData: nil)
        #expect(await save(drafts, name, images: [image]))
        var payload = try #require(
            JSONSerialization.jsonObject(with: files.readData(at: metadata)) as? [String: Any])
        let revision = try #require(payload["assetRevision"] as? String)
        let asset = metadata.appendingPathExtension("assets").appending(path: revision).appending(
            path: "image-0.jpg")
        if damage == "sidecar" {
            try files.writeData(
                Data(count: ComposerDraftImagePolicy.maximumBytes + 1), to: asset,
                options: [.atomic])
        } else if damage == "references" {
            payload["images"] = Array(
                repeating: ["filename": "image.jpg"],
                count: ComposerDraftImagePolicy.maximumImageCount + 1)
            try files.writeData(
                try JSONSerialization.data(withJSONObject: payload), to: metadata,
                options: [.atomic])
        } else if damage == "metadata" {
            let text = String(
                repeating: "x", count: ComposerDraftImagePolicy.maximumLegacyMetadataBytes + 1)
            try files.writeData(try legacyData(name, text: text), to: metadata, options: [.atomic])
        } else {
            let images =
                damage == "legacyCount"
                ? Array(repeating: image, count: ComposerDraftImagePolicy.maximumImageCount + 1)
                : [
                    .init(
                        filename: "image.jpg",
                        previewData: Data(count: ComposerDraftImagePolicy.maximumBytes + 1),
                        uploadData: nil)
                ]
            try files.writeData(
                try legacyData(name, images: images), to: metadata, options: [.atomic])
        }
        let original = files.storedData
        let reads = files.readCount(at: damage == "metadata" ? metadata : asset)
        #expect(
            await read(drafts, name)
                == (damage == "metadata"
                    ? "unreadable" : damage == "references" ? "recovered-9" : "recovered-1"))
        if ["metadata", "sidecar"].contains(damage) {
            #expect(files.readCount(at: damage == "metadata" ? metadata : asset) == reads)
        }
        #expect(files.storedData == original)
        if damage == "metadata" {
            #expect(await save(drafts, name) == false)
            #expect(await cleanup(drafts, name)() == false)
            #expect(files.storedData == original)
        } else {
            #expect(await save(drafts, name))
            #expect(await read(drafts, name) == "新草稿")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func attachmentCountAdmissionPreservesDraft(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await save(drafts, name))
        let original = files.storedData
        let image = ComposerImageDraftSnapshot(
            filename: "image.jpg", previewData: Data([7]), uploadData: nil)
        #expect(
            await save(
                drafts, name,
                images: Array(
                    repeating: image, count: ComposerDraftImagePolicy.maximumImageCount + 1))
                == false)
        #expect(files.storedData == original)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func missingDraftAllowsFirstSave(_ name: String) async {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await read(drafts, name) == "missing")
        #expect(await save(drafts, name))
        #expect(await read(drafts, name) == "新草稿")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func malformedMetadataBlocksSaving(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(
            await save(
                drafts, name,
                images: [.init(filename: "image.jpg", previewData: Data([7]), uploadData: nil)]))
        try files.writeData(Data("damaged".utf8), to: file(name), options: [.atomic])
        let original = files.storedData
        #expect(await read(drafts, name) == "unreadable")
        #expect(await save(drafts, name) == false)
        #expect(await cleanup(drafts, name)() == false)
        #expect(files.storedData == original)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func futureFormatsKeepMetadata(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await save(drafts, name))
        var payload = try #require(
            JSONSerialization.jsonObject(with: files.readData(at: file(name))) as? [String: Any])
        payload["schemaVersion"] = 2
        payload["futureField"] = "保留此字段"
        try files.writeData(
            try JSONSerialization.data(withJSONObject: payload), to: file(name), options: [.atomic])
        let original = files.storedData
        #expect(await read(drafts, name) == "version-2")
        #expect(await save(drafts, name) == false)
        #expect(await cleanup(drafts, name)() == false)
        #expect(files.storedData == original)
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"],
        ["nullVersion", "textVersion", "assetPath"])
    func malformedFormatHeadersKeepCompleteSource(_ name: String, _ defect: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(await save(drafts, name))
        var payload = try #require(
            JSONSerialization.jsonObject(with: files.readData(at: file(name))) as? [String: Any])
        if defect == "nullVersion" { payload["schemaVersion"] = NSNull() }
        if defect == "textVersion" { payload["schemaVersion"] = "1" }
        if defect == "assetPath" { payload["assetRevision"] = "../other-assets" }
        try files.writeData(
            try JSONSerialization.data(withJSONObject: payload), to: file(name), options: [.atomic])
        let original = files.storedData
        #expect(await read(drafts, name) == "unreadable")
        #expect(await save(drafts, name) == false)
        #expect(files.storedData == original)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func missingImageKeepsText(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        let images = [1, 2].map {
            ComposerImageDraftSnapshot(
                filename: "\($0).jpg", previewData: Data([UInt8($0)]), uploadData: nil)
        }
        #expect(await save(drafts, name, images: images))
        let submittedCleanup = await cleanup(drafts, name)
        let imageURL = try #require(
            files.storedData.keys.first { $0.lastPathComponent == "image-0.jpg" })
        try files.removeItem(at: imageURL)
        let original = files.storedData
        #expect(await read(drafts, name) == "recovered-1")
        #expect(files.storedData == original)
        let restoredImages: [ComposerImageDraftSnapshot]
        if name == "gallery" {
            let recovered = await drafts.loadGallery()
            #expect(recovered.snapshot?.text == "新草稿" && recovered.recoveryMessage != nil)
            restoredImages = try #require(recovered.snapshot?.images)
        } else {
            let recovered = await drafts.loadSuggestion()
            #expect(recovered.snapshot?.text == "新草稿" && recovered.recoveryMessage != nil)
            restoredImages = try #require(recovered.snapshot?.images)
        }
        #expect(restoredImages.map(\.filename) == ["2.jpg"])
        #expect(await save(drafts, name, text: "继续编辑", images: restoredImages))
        #expect(await submittedCleanup())
        #expect(await read(drafts, name) == "继续编辑")
        #expect(
            files.storedData.first { $0.key.lastPathComponent == "image-0.jpg" }?.value == Data([2])
        )
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func existenceFailureUsesActualDraftRead(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        let unowned = root.appending(path: "ComposerDrafts/\(name).json")
        let data = try legacyData(name)
        try files.writeData(data, to: unowned, options: [.atomic])
        #expect(await read(drafts, name) == "missing")
        #expect(await save(drafts, name))
        files.setFailures(existence: true)
        #expect(await read(drafts, name) == "新草稿")
        files.setFailures(reading: true, existence: true)
        #expect(await read(drafts, name) == "unreadable")
        #expect(await save(drafts, name) == false)
        files.setFailures()
        let completedCleanup = await cleanup(drafts, name)
        #expect(await completedCleanup())
        #expect(try files.readData(at: unowned) == data)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
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

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func recoveryStateTakesSources(_ name: String) async throws {
        let files = ModuleScoreFiles()
        try files.writeData(Data("damaged".utf8), to: file(name), options: [.atomic])
        try files.writeData(
            try legacyData(name), to: file(name, legacyAccount: true), options: [.atomic])
        try files.writeData(
            try legacyData(name), to: root.appending(path: "ComposerDrafts/\(name).json"),
            options: [.atomic])
        let original = files.storedData
        let drafts = store(files)
        #expect(await read(drafts, name) == "unreadable")
        #expect(await save(drafts, name) == false)
        #expect(files.storedData == original)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"], ["current", "account"])
    func legacySnapshotsMigrateAtTheirOwningSource(_ name: String, _ location: String) async throws
    {
        let files = ModuleScoreFiles()
        let source = file(name, legacyAccount: location == "account")
        try files.writeData(try legacyData(name), to: source, options: [.atomic])
        let drafts = store(files)
        #expect(await read(drafts, name) == "原草稿")
        #expect(await read(drafts, name) == "原草稿")
        let metadata = try #require(
            JSONSerialization.jsonObject(with: files.readData(at: file(name))) as? [String: Any])
        #expect(metadata["schemaVersion"] as? Int == 1)
        if source != file(name) { #expect(files.fileExists(at: source) == false) }
        #expect(files.storedData.values.contains(Data([1, 2])))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func accountDirectoryMigrationMovesAtomically(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let drafts = store(files)
        #expect(
            await save(
                drafts, name, text: "原草稿",
                images: [.init(filename: "image.jpg", previewData: Data([8]), uploadData: nil)]))
        let previousURL = file(name, legacyAccount: true)
        for (url, data) in files.storedData {
            let destination = URL(
                fileURLWithPath: url.path.replacingOccurrences(
                    of: file(name).path, with: previousURL.path))
            try files.writeData(data, to: destination, options: [.atomic])
        }
        try files.removeItem(at: file(name))
        try files.removeItem(at: file(name).appendingPathExtension("assets"))
        #expect(await read(drafts, name) == "原草稿")
        #expect(files.fileExists(at: previousURL) == false)
        #expect(files.storedData.keys.contains { $0.path.hasPrefix(previousURL.path) } == false)
        #expect(files.storedData.values.contains(Data([8])))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func migrationWriteFailureRetainsReadableSource(_ name: String) async throws {
        let files = ModuleScoreFiles()
        let source = file(name, legacyAccount: true)
        try files.writeData(try legacyData(name), to: source, options: [.atomic])
        let original = files.storedData
        files.setFailures(writing: true)
        #expect(await read(store(files), name) == "原草稿")
        #expect(files.storedData == original)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func failedMetadataDeletionRetainsImages(_ name: String) async {
        let metadata = file(name)
        let fail = OSAllocatedUnfairLock(initialState: true)
        let files = ModuleScoreFiles(beforeRemovingItem: { url in
            if url == metadata && fail.withLock({ $0 }) { throw CocoaError(.fileWriteNoPermission) }
        })
        let drafts = store(files)
        #expect(
            await save(
                drafts, name,
                images: [.init(filename: "image.jpg", previewData: Data([8]), uploadData: nil)]))
        let original = files.storedData
        let removed =
            name == "gallery" ? await drafts.removeGallery() : await drafts.removeSuggestion()
        #expect(removed == false && files.storedData == original)
        #expect(await read(drafts, name) == "新草稿")
        fail.withLock { $0 = false }
        let retried =
            name == "gallery" ? await drafts.removeGallery() : await drafts.removeSuggestion()
        #expect(retried && files.storedData.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["gallery", "suggestion"])
    func explicitDiscardReleasesTheRecoveryGate(_ name: String) async throws {
        let files = ModuleScoreFiles()
        try files.writeData(Data("damaged".utf8), to: file(name), options: [.atomic])
        let drafts = store(files)
        if name == "gallery" {
            #expect(await drafts.removeGallery())
        } else {
            #expect(await drafts.removeSuggestion())
        }
        #expect(await read(drafts, name) == "missing")
        #expect(await save(drafts, name))
    }
}

@MainActor
struct AccountStorageContractTests {
    private enum Payload: Codable {
        case value(String)
        case rejected
        init(from decoder: Decoder) throws {
            self = .value(try decoder.singleValueContainer().decode(String.self))
        }
        func encode(to encoder: Encoder) async throws {
            guard case .value(let text) = self else {
                throw EncodingError.invalidValue(
                    self,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "injected encoding failure"))
            }
            var container = encoder.singleValueContainer()
            try container.encode(text)
        }
    }

    @Test func accountTokensAreNormalizedOpaque() {
        let token = AccountStorageIdentity.stableToken(for: " student-A ")
        #expect(token == AccountStorageIdentity.stableToken(for: "student-A"))
        #expect(token.count == "account-".count + 64)
        #expect(token != AccountStorageIdentity.stableToken(for: "student-B"))
        #expect(AccountStorageIdentity.stableToken(for: token) == token)
        #expect(AccountStorageIdentity.stableToken(for: " ") == "__default__")
        #expect(AccountStorageIdentity.stableToken(for: "account-invalid") != "account-invalid")
        #expect(
            AccountStorageIdentity.stableToken(for: "account-" + String(repeating: "z", count: 64))
                .hasSuffix(String(repeating: "z", count: 64)) == false)
    }

    @Test func directory() {
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
        #expect(
            first.legacyAccountDirectoryNameForMigration
                != second.legacyAccountDirectoryNameForMigration)
        #expect(first.key("cache") != second.key("cache"))
        #expect(first.legacyKey("cache") == "cache.A/B")
    }

    @Test func prefEncodingFailure() throws {
        let domain = "BIT101ModulesTests.preference-failures"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var session = AppStorageSession(accountIdentifier: "A")
        let store = AccountScopedCodableStore<Payload>(
            keyPrefix: "payload", defaults: defaults, sessionProvider: { session })
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
}
