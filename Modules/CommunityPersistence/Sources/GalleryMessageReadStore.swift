import CommunityCore
import StorageCore
import Combine
import Foundation

private nonisolated struct MessageSnapshotState: Sendable {
    let snapshot: GalleryMessageReadSnapshot
    let unread: [String: Set<Int>]
    let seen: [String: Set<Int>]
    init(_ snapshot: GalleryMessageReadSnapshot) {
        self.snapshot = snapshot.compacted()
        unread = self.snapshot.latestIDsByType.mapValues { Set($0) }
        seen = self.snapshot.seenIDsByType.mapValues { Set($0) }
    }
}

/// 文件操作和快照计算在存储执行器中串行完成。
private actor MessageSnapshotFiles {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    func read(files: any AppFileService, url: URL, legacy: Data?, invalidLegacy: Bool) -> MessageSnapshotState? {
        do {
            let data: Data
            do {
                try files.setPrivateFileProtection(at: url)
                data = try files.readData(at: url, maximumBytes: GalleryMessageReadSnapshot.maximumSnapshotBytes)
            } catch {
                guard AppFileSystem.isMissingFile(error) else { return nil }
                guard !invalidLegacy else { return nil }
                guard let legacy else { return MessageSnapshotState(GalleryMessageReadSnapshot()) }
                data = legacy
            }
            guard data.count <= GalleryMessageReadSnapshot.maximumSnapshotBytes else { return nil }
            return MessageSnapshotState(try JSONDecoder().decode(GalleryMessageReadSnapshot.self, from: data))
        } catch { return nil }
    }

    func write(_ original: GalleryMessageReadSnapshot, files: any AppFileService, url: URL,
               edit: @Sendable (GalleryMessageReadSnapshot) -> GalleryMessageReadSnapshot?) throws -> MessageSnapshotState? {
        let source: GalleryMessageReadSnapshot
        do {
            try files.setPrivateFileProtection(at: url)
            source = try JSONDecoder().decode(GalleryMessageReadSnapshot.self,
                from: files.readData(at: url, maximumBytes: GalleryMessageReadSnapshot.maximumSnapshotBytes))
        } catch {
            guard AppFileSystem.isMissingFile(error) else { throw error }
            source = original
        }
        guard let edited = edit(source) else { return nil }
        let state = MessageSnapshotState(edited)
        let data = try JSONEncoder().encode(state.snapshot)
        guard data.count <= GalleryMessageReadSnapshot.maximumSnapshotBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try files.createDirectory(at: url.deletingLastPathComponent())
        try files.writeData(data, to: url, options: AppFileSystem.protectedDataWritingOptions)
        return state
    }
}

/// 界面读取内存索引；异步保存完成后发布所属账号的状态。
public final class GalleryMessageReadStore: GalleryMessageReadStoring {
    private let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    public var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    public var currentSession: AppStorageSession { session() }
    private let saveSubject = PassthroughSubject<AppStorageSession, Never>()
    public var localSaves: AnyPublisher<AppStorageSession, Never> { saveSubject.eraseToAnyPublisher() }
    private let session: () -> AppStorageSession
    private let defaults: UserDefaults
    private let files: any AppFileService
    private let storageOperations: StorageOperationTracker
    private let storageRoot: URL
    private let worker = MessageSnapshotFiles()
    private var cacheGeneration = 0
    private var cached: (session: AppStorageSession, revisionKey: String, revision: Int, state: MessageSnapshotState?)?
    private var loadTask: (session: AppStorageSession, revision: Int, generation: Int, task: Task<Bool, Never>)?
    private nonisolated struct WriteKey: Hashable {
        let url: URL
        let fileObject: ObjectIdentifier?
    }
    private static var writeTasks: [WriteKey: (id: Int, task: Task<Bool, Never>)] = [:]
    private static var writeID = 0
    public nonisolated static let maximumSnapshotBytes = GalleryMessageReadSnapshot.maximumSnapshotBytes
    private let snapshotStore: AccountScopedCodableStore<GalleryMessageReadSnapshot>

    public init(files: any AppFileService, storageRoot: URL, defaults: UserDefaults, session: @escaping () -> AppStorageSession, storageOperations: StorageOperationTracker = StorageOperationTracker()) {
        self.files = files
        self.storageOperations = storageOperations
        self.storageRoot = storageRoot
        self.session = session
        self.defaults = defaults
        snapshotStore = AccountScopedCodableStore(keyPrefix: "gallery.message.read.snapshot", defaults: defaults, sessionProvider: session)
        Task { [weak self] in await self?.prepareSnapshot() }
    }

    public func invalidateSnapshot() {
        cacheGeneration &+= 1
        cached = nil
        loadTask = nil
    }

    private var revisionKey: String { snapshotStore.storageKey + ".revision" }
    private var fileURL: URL {
        storageRoot.appending(path: session().accountStorageIdentifier, directoryHint: .isDirectory)
            .appending(path: "message-read-snapshot.json")
    }

    private var currentState: MessageSnapshotState? {
        let account = session()
        guard let cached, cached.session == account, cached.revision == defaults.integer(forKey: cached.revisionKey) else {
            Task { [weak self] in await self?.prepareSnapshot() }
            return nil
        }
        return cached.state
    }

    public var hasUnreadableSnapshot: Bool {
        cached?.session == session() && cached?.state == nil
    }

    @discardableResult public func prepareSnapshot() async -> Bool {
        guard storageOperations.begin() else { return false }
        defer { storageOperations.finish() }
        let account = session(), revision = defaults.integer(forKey: revisionKey), generation = cacheGeneration
        if let cached, cached.session == account, cached.revision == revision, cached.state != nil { return true }
        if let loadTask, loadTask.session == account, loadTask.revision == revision, loadTask.generation == generation { return await loadTask.task.value }
        let url = fileURL, key = snapshotStore.storageKey, revisionKey = self.revisionKey
        let legacyKey = account.legacyKey("gallery.message.read.snapshot")
        let legacyValue = defaults.object(forKey: key) ?? defaults.object(forKey: legacyKey)
        let legacy = legacyValue as? Data
        let invalidLegacy = legacyValue != nil && legacy == nil
        let task = Task { [weak self, worker, files] in
            let state = await worker.read(files: files, url: url, legacy: legacy, invalidLegacy: invalidLegacy)
            guard let self else { return false }
            if self.loadTask?.session == account && self.loadTask?.revision == revision && self.loadTask?.generation == generation { self.loadTask = nil }
            guard generation == self.cacheGeneration, account == self.session(), revision == self.defaults.integer(forKey: revisionKey) else { return false }
            let previous = self.cached?.session == account ? self.cached?.state?.unread : nil
            self.cached = (account, revisionKey, revision, state)
            self.loadTask = nil
            if state != nil, let legacy, self.defaults.object(forKey: key) == nil {
                self.defaults.set(legacy, forKey: key)
                self.defaults.removeObject(forKey: legacyKey)
            }
            if previous != state?.unread, previous != nil || state?.unread.isEmpty == false { self.changeSubject.send(account) }
            return state != nil
        }
        loadTask = (account, revision, generation, task)
        return await task.value
    }

    private func save(shouldSync: Bool = true,
                      edit: @escaping @Sendable (GalleryMessageReadSnapshot) -> GalleryMessageReadSnapshot?) async -> Bool {
        guard storageOperations.begin() else { return false }
        defer { storageOperations.finish() }
        let account = session(), generation = cacheGeneration
        let fileObject = (files as? any AppFileService & AnyObject).map(ObjectIdentifier.init)
        let writeKey = WriteKey(url: fileURL.standardizedFileURL, fileObject: fileObject)
        let previous = Self.writeTasks[writeKey]?.task
        Self.writeID &+= 1
        let writeID = Self.writeID
        let task = Task { [weak self] in
            defer {
                if Self.writeTasks[writeKey]?.id == writeID { Self.writeTasks.removeValue(forKey: writeKey) }
            }
            _ = await previous?.value
            guard let self, generation == self.cacheGeneration, account == self.session(), await self.prepareSnapshot(),
                  generation == self.cacheGeneration, account == self.session(), let state = self.currentState else { return false }
            let url = self.fileURL, key = self.snapshotStore.storageKey, revisionKey = self.revisionKey
            do {
                guard let saved = try await self.worker.write(state.snapshot, files: self.files, url: url, edit: edit) else { return true }
                self.defaults.removeObject(forKey: account.legacyKey("gallery.message.read.snapshot"))
                let revision = self.defaults.integer(forKey: revisionKey) &+ 1
                self.defaults.set(revision, forKey: revisionKey)
                self.defaults.removeObject(forKey: key)
                let isCurrent = generation == self.cacheGeneration && account == self.session()
                if isCurrent { self.cached = (account, revisionKey, revision, saved) }
                if shouldSync { self.saveSubject.send(account) }
                self.changeSubject.send(account)
                return isCurrent
            } catch { self.cached = nil; return false }
        }
        Self.writeTasks[writeKey] = (writeID, task)
        return await task.value
    }

    public func syncSnapshot() -> GalleryMessageReadSnapshot {
        guard var snapshot = currentState?.snapshot else { return GalleryMessageReadSnapshot() }
        snapshot.latestIDsByType = [:]
        snapshot.pendingUnreadAfterIDByType = [:]
        return snapshot
    }

    @discardableResult public func applySyncedSnapshot(_ snapshot: GalleryMessageReadSnapshot) async -> Bool {
        await save(shouldSync: false) { $0.mergingReadState(snapshot) }
    }

    @discardableResult public func replaceLatestIDs(_ ids: [Int], unreadCount: Int, for type: GalleryMessageType) async -> Bool {
        await save { snapshot in
            guard unreadCount > 0 else { return nil }
            var result = snapshot
            let seen = Set(snapshot.seenIDsByType[type.rawValue] ?? [])
            result.latestIDsByType[type.rawValue] = Array(Set(snapshot.latestIDsByType[type.rawValue] ?? []).union(ids.prefix(unreadCount)).subtracting(seen))
            return result
        }
    }

    @discardableResult public func markSeen(ids: [Int], for type: GalleryMessageType) async -> Bool {
        await save { snapshot in
            let seen = Set(snapshot.seenIDsByType[type.rawValue] ?? [])
            let floor = snapshot.retainedFromIDByType[type.rawValue] ?? Int.min
            guard ids.contains(where: { $0 >= floor && !seen.contains($0) }) else { return nil }
            var result = snapshot
            result.seenIDsByType[type.rawValue] = Array(seen.union(ids))
            return result
        }
    }

    public func unreadCount(for type: GalleryMessageType) -> Int { currentState?.unread[type.rawValue]?.count ?? 0 }
    public func pendingUnreadAfterID(for type: GalleryMessageType) -> Int? { currentState?.snapshot.pendingUnreadAfterIDByType[type.rawValue] }
    @discardableResult public func setPendingUnreadAfterID(_ id: Int?, for type: GalleryMessageType) async -> Bool {
        await save { snapshot in
            var result = snapshot
            result.pendingUnreadAfterIDByType[type.rawValue] = id
            return result
        }
    }
    public func isUnread(id: Int, for type: GalleryMessageType) -> Bool {
        guard let state = currentState else { return false }
        if state.unread[type.rawValue]?.contains(id) == true { return true }
        return state.snapshot.pendingUnreadAfterIDByType[type.rawValue].map { id > $0
            && state.seen[type.rawValue]?.contains(id) != true
            && id >= (state.snapshot.retainedFromIDByType[type.rawValue] ?? Int.min) } ?? false
    }
}
