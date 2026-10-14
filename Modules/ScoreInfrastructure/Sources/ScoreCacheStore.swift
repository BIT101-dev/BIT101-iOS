import ScoreDomain
import ScorePorts
import StorageCore
import Combine
import Foundation
import OSLog

nonisolated struct ScoreCacheLegacyData: Sendable {
    let rows: Data?
    let updatedAt: Data?
    let detailedUpdatedAt: Data?
    var isUnreadable = false

    static let empty = ScoreCacheLegacyData(rows: nil, updatedAt: nil, detailedUpdatedAt: nil)
}

nonisolated enum ScoreCacheDiskReadResult: Sendable {
    case loaded(ScoreCacheSnapshot, migratedLegacy: Bool)
    case missing
    case unreadable

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

nonisolated enum ScoreCacheMutation: Sendable {
    case rows([ScoreRow])
    case detailedRows([ScoreRow])
    case synced(ScoreCacheSyncPayload, replacing: ScoreCacheSyncPayload?)
}

nonisolated enum ScoreCacheDiskWriteResult: Sendable {
    case saved(ScoreCacheSnapshot)
    case superseded
    case unreadable
    case failed

    var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

/// 成绩缓存仓库。
///
/// 按学号隔离；文件读写、JSON 编解码和变更串行化均在专用 actor 执行。
public final class ScoreCacheStore: ScoreCacheSynchronizing {
    public nonisolated static let maximumCacheBytes = 16 * 1_024 * 1_024
    private let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    public var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    private let saveSubject = PassthroughSubject<AppStorageSession, Never>()
    public var localSaves: AnyPublisher<AppStorageSession, Never> { saveSubject.eraseToAnyPublisher() }
    private nonisolated static let logger = Logger(subsystem: "BIT101", category: "ScoreCache")
    private let repository: ScoreCacheDiskRepository
    private let defaults: UserDefaults
    private let currentSession: () -> AppStorageSession
    private let storageOperations: StorageOperationTracker
    private struct RepositoryKey: Hashable {
        let root: URL
        let fileObject: ObjectIdentifier?
    }
    private final class RepositoryReference {
        weak var value: ScoreCacheDiskRepository?
        init(_ value: ScoreCacheDiskRepository) { self.value = value }
    }
    private static var repositories: [RepositoryKey: RepositoryReference] = [:]

    public init(files: any AppFileService, storageRoot: URL, defaults: UserDefaults, session: @escaping () -> AppStorageSession, storageOperations: StorageOperationTracker = StorageOperationTracker()) {
        Self.repositories = Self.repositories.filter { $0.value.value != nil }
        let key: RepositoryKey?
        if files is LocalAppFileService {
            key = RepositoryKey(root: files.canonicalFileURL(storageRoot), fileObject: nil)
        } else if let object = files as? any AppFileService & AnyObject {
            key = RepositoryKey(root: files.canonicalFileURL(storageRoot), fileObject: ObjectIdentifier(object))
        } else {
            key = nil
        }
        if let key, let repository = Self.repositories[key]?.value {
            self.repository = repository
        } else {
            let repository = ScoreCacheDiskRepository(files: files, storageRoot: storageRoot)
            if let key { Self.repositories[key] = RepositoryReference(repository) }
            self.repository = repository
        }
        self.defaults = defaults
        self.currentSession = session
        self.storageOperations = storageOperations
    }

    public func loadSnapshot(for session: AppStorageSession? = nil) async throws -> ScoreCacheSnapshot? {
        guard storageOperations.begin() else { throw ScoreCacheReadError.unavailable }
        defer { storageOperations.finish() }
        let session = session ?? currentSession()
        let result = await repository.load(for: session, legacyData: legacyData(for: session))
        switch result {
        case .loaded(let snapshot, let migratedLegacy):
            if migratedLegacy { clearLegacyDefaults(for: session) }
            return snapshot
        case .missing: return nil
        case .unreadable: throw ScoreCacheReadError.unreadable
        }
    }

    public func loadRows(for session: AppStorageSession? = nil) async -> [ScoreRow]? {
        try? await loadSnapshot(for: session)?.rows
    }

    @discardableResult
    public func save(rows: [ScoreRow], for session: AppStorageSession? = nil) async -> Date? {
        guard !Task.isCancelled else { return nil }
        guard storageOperations.begin() else { return nil }
        defer { storageOperations.finish() }
        let session = session ?? currentSession()
        let result = await repository.mutate(
            .rows(rows),
            for: session,
            legacyData: legacyData(for: session)
        )
        let updatedAt = finishWrite(result, for: session, syncPreference: true)
        return Task.isCancelled ? nil : updatedAt
    }

    @discardableResult
    public func saveDetailed(rows: [ScoreRow], for session: AppStorageSession? = nil) async -> Date? {
        guard !Task.isCancelled else { return nil }
        guard storageOperations.begin() else { return nil }
        defer { storageOperations.finish() }
        let session = session ?? currentSession()
        let result = await repository.mutate(
            .detailedRows(rows),
            for: session,
            legacyData: legacyData(for: session)
        )
        let updatedAt = finishWrite(result, for: session, syncPreference: true)
        return Task.isCancelled ? nil : updatedAt
    }

    /// 文件读取错误沿同步端口传递，协调器保留本机与云端载荷并提示恢复原因。
    public func syncPayload(for session: AppStorageSession? = nil) async throws -> ScoreCacheSyncPayload? {
        guard storageOperations.begin() else { throw ScoreCacheReadError.unavailable }
        defer { storageOperations.finish() }
        let session = session ?? currentSession()
        let result = await repository.load(for: session, legacyData: legacyData(for: session))
        switch result {
        case .loaded(let snapshot, let migratedLegacy):
            if migratedLegacy { clearLegacyDefaults(for: session) }
            return ScoreCacheSyncPayload(
                rows: snapshot.rows ?? [],
                updatedAt: snapshot.updatedAt,
                detailedUpdatedAt: snapshot.detailedUpdatedAt
            )
        case .missing:
            return ScoreCacheSyncPayload(rows: [], updatedAt: nil, detailedUpdatedAt: nil)
        case .unreadable:
            throw ScoreCacheReadError.unreadable
        }
    }

    /// 写入来自 iCloud 的成绩缓存；损坏的本地文件保留原样，等待明确恢复。
    @discardableResult
    public func applySynced(
        _ payload: ScoreCacheSyncPayload,
        for session: AppStorageSession? = nil,
        replacing expected: ScoreCacheSyncPayload? = nil
    ) async throws -> Bool {
        guard storageOperations.begin() else { throw ScoreCacheReadError.unavailable }
        defer { storageOperations.finish() }
        guard !payload.rows.isEmpty || payload.updatedAt != nil || payload.detailedUpdatedAt != nil else { return false }
        let session = session ?? currentSession()
        let result = await repository.mutate(
            .synced(payload, replacing: expected),
            for: session,
            legacyData: legacyData(for: session)
        )
        if case .superseded = result { return false }
        guard result.isSaved else {
            _ = finishWrite(result, for: session, syncPreference: false)
            if result.isUnreadable { throw ScoreCacheReadError.unreadable }
            throw ScoreCacheWriteError.failed
        }
        _ = finishWrite(result, for: session, syncPreference: false)
        return true
    }

    private func finishWrite(
        _ result: ScoreCacheDiskWriteResult,
        for session: AppStorageSession,
        syncPreference: Bool
    ) -> Date? {
        if case .superseded = result { return nil }
        guard case .saved(let snapshot) = result else {
            if result.isUnreadable {
                Self.logger.error("保留无法读取的成绩缓存，跳过保存")
            } else {
                Self.logger.error("成绩缓存写入失败，本次结果待重试保存")
            }
            return nil
        }

        clearLegacyDefaults(for: session)
        if syncPreference {
            saveSubject.send(session)
        }
        changeSubject.send(session)
        return snapshot.updatedAt
    }

    private func legacyData(for session: AppStorageSession) -> ScoreCacheLegacyData {
        var isUnreadable = false
        func value(_ prefix: String) -> Data? {
            guard let object = defaults.object(forKey: session.key(prefix))
                ?? defaults.object(forKey: session.legacyKey(prefix)) else { return nil }
            guard let data = object as? Data else { isUnreadable = true; return nil }
            return data
        }
        var result = ScoreCacheLegacyData(
            rows: value("score.detail.cache"),
            updatedAt: value("score.detail.cache.updated-at"),
            detailedUpdatedAt: value("score.detail.cache.full-updated-at")
        )
        result.isUnreadable = isUnreadable
        return result
    }

    private func clearLegacyDefaults(for session: AppStorageSession) {
        for prefix in ["score.detail.cache", "score.detail.cache.updated-at", "score.detail.cache.full-updated-at"] {
            defaults.removeObject(forKey: session.key(prefix))
            defaults.removeObject(forKey: session.legacyKey(prefix))
        }
    }
}

/// 对账号成绩文件的全部操作都在 actor 内同步执行，避免主线程 I/O 与并发读改写丢失。
actor ScoreCacheDiskRepository {
    private nonisolated let executor = StorageFileExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    nonisolated private static let logger = Logger(subsystem: "BIT101", category: "ScoreCache")

    private let files: any AppFileService
    private let storageRoot: URL

    init(files: any AppFileService, storageRoot: URL) {
        self.files = files
        self.storageRoot = storageRoot
    }

    func load(for session: AppStorageSession, legacyData: ScoreCacheLegacyData) -> ScoreCacheDiskReadResult {
        switch readFile(for: session) {
        case .loaded(let stored):
            return .loaded(stored.snapshot, migratedLegacy: false)
        case .unreadable:
            return .unreadable
        case .missing:
            let snapshot: ScoreCacheSnapshot
            do { snapshot = try decodeLegacy(legacyData) }
            catch { return .unreadable }
            guard snapshot.containsData else { return .missing }
            do {
                try write(DiskSnapshot(snapshot: snapshot), for: session)
                return .loaded(snapshot, migratedLegacy: true)
            } catch {
                Self.logger.error("成绩缓存迁移写入失败：\(String(describing: error), privacy: .public)")
                return .loaded(snapshot, migratedLegacy: false)
            }
        }
    }

    func mutate(
        _ mutation: ScoreCacheMutation,
        for session: AppStorageSession,
        legacyData: ScoreCacheLegacyData
    ) -> ScoreCacheDiskWriteResult {
        guard !Task.isCancelled else { return .superseded }
        var stored: DiskSnapshot
        switch readFile(for: session) {
        case .loaded(let existing):
            stored = existing
        case .missing:
            do { stored = DiskSnapshot(snapshot: try decodeLegacy(legacyData)) }
            catch { return .unreadable }
        case .unreadable:
            return .unreadable
        }

        var snapshot = stored.snapshot
        switch mutation {
        case .rows(let rows):
            snapshot.rows = rows
            snapshot.updatedAt = Date()
            snapshot.detailedUpdatedAt = nil
        case .detailedRows(let rows):
            let now = Date()
            snapshot.rows = rows
            snapshot.updatedAt = now
            snapshot.detailedUpdatedAt = now
        case .synced(let payload, let expected):
            let current = ScoreCacheSyncPayload(rows: snapshot.rows ?? [], updatedAt: snapshot.updatedAt,
                detailedUpdatedAt: snapshot.detailedUpdatedAt)
            guard expected == nil || expected == current else { return .superseded }
            snapshot = ScoreCacheSnapshot(
                rows: payload.rows,
                updatedAt: payload.updatedAt,
                detailedUpdatedAt: payload.detailedUpdatedAt
            )
        }

        do {
            guard !Task.isCancelled else { return .superseded }
            stored.snapshot = snapshot
            try write(stored, for: session)
            removeLegacyFile(for: session)
            return .saved(snapshot)
        } catch {
            Self.logger.error("保存成绩缓存失败：\(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    private struct DiskSnapshot {
        var snapshot: ScoreCacheSnapshot
        var fields: [String: Any] = [:]
    }

    private struct DiskVersion: Decodable { let schemaVersion: Int? }
    private static let snapshotKeys: Set<String> = ["rows", "updatedAt", "detailedUpdatedAt"]

    private enum ExistingFileResult {
        case loaded(DiskSnapshot)
        case missing
        case unreadable
    }

    private func readFile(for session: AppStorageSession) -> ExistingFileResult {
        let url = fileURL(for: session)
        let result = readFile(at: url)
        switch result {
        case .loaded, .unreadable: return result
        case .missing:
            let legacyURL = legacyFileURL(for: session)
            guard legacyURL != url else { return .missing }
            let legacyResult = readFile(at: legacyURL)
            guard case .loaded(let stored) = legacyResult else { return legacyResult }
            do {
                try write(stored, for: session)
                removeLegacyFile(for: session)
            } catch {
                Self.logger.error("成绩缓存迁移写入失败：\(String(describing: error), privacy: .public)")
            }
            return .loaded(stored)
        }
    }

    private func readFile(at url: URL) -> ExistingFileResult {
        do {
            try files.setPrivateFileProtection(at: url)
            let data = try files.readData(at: url, maximumBytes: ScoreCacheStore.maximumCacheBytes)
            return .loaded(try decodeStoredData(data))
        } catch {
            if AppFileSystem.isMissingFile(error) { return .missing }
            Self.logger.error("成绩缓存无法读取，保留原文件：\(url.lastPathComponent, privacy: .public)")
            return .unreadable
        }
    }

    private func decodeStoredData(_ data: Data) throws -> DiskSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              !Self.snapshotKeys.isDisjoint(with: object.keys)
        else { throw CocoaError(.coderReadCorrupt) }
        let version = object["schemaVersion"] == nil ? 1 : try JSONDecoder().decode(DiskVersion.self, from: data).schemaVersion
        guard version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return DiskSnapshot(snapshot: try JSONDecoder().decode(ScoreCacheSnapshot.self, from: data),
            fields: object.filter { !Self.snapshotKeys.contains($0.key) && $0.key != "schemaVersion" })
    }

    private func decodeLegacy(_ legacyData: ScoreCacheLegacyData) throws -> ScoreCacheSnapshot {
        guard !legacyData.isUnreadable else { throw CocoaError(.coderReadCorrupt) }
        guard [legacyData.rows, legacyData.updatedAt, legacyData.detailedUpdatedAt].compactMap({ $0 })
            .reduce(0, { $0 + $1.count }) <= ScoreCacheStore.maximumCacheBytes else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder()
        return ScoreCacheSnapshot(
            rows: try legacyData.rows.map { try decoder.decode([ScoreRow].self, from: $0) },
            updatedAt: try legacyData.updatedAt.map { try decoder.decode(Date.self, from: $0) },
            detailedUpdatedAt: try legacyData.detailedUpdatedAt.map { try decoder.decode(Date.self, from: $0) }
        )
    }

    private func write(_ stored: DiskSnapshot, for session: AppStorageSession) throws {
        let url = fileURL(for: session)
        try files.createDirectory(at: url.deletingLastPathComponent())
        let encoded = try JSONEncoder().encode(stored.snapshot)
        guard encoded.count <= ScoreCacheStore.maximumCacheBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        guard let snapshot = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
        var fields = stored.fields.merging(snapshot) { _, new in new }
        fields["schemaVersion"] = 1
        let data = try JSONSerialization.data(withJSONObject: fields)
        guard data.count <= ScoreCacheStore.maximumCacheBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try files.writeData(
            data,
            to: url,
            options: AppFileSystem.protectedDataWritingOptions
        )
    }

    private func fileURL(for session: AppStorageSession) -> URL {
        storageRoot
            .appending(path: session.accountStorageIdentifier, directoryHint: .isDirectory)
            .appending(path: "score-cache.json")
    }

    private func legacyFileURL(for session: AppStorageSession) -> URL {
        storageRoot
            .appending(path: session.legacyAccountDirectoryNameForMigration, directoryHint: .isDirectory)
            .appending(path: "score-cache.json")
    }

    private func removeLegacyFile(for session: AppStorageSession) {
        let url = legacyFileURL(for: session)
        guard url != fileURL(for: session),
              let data = try? files.readData(at: url, maximumBytes: ScoreCacheStore.maximumCacheBytes),
              (try? decodeStoredData(data)) != nil
        else { return }
        do {
            try files.removeItem(at: url)
            let directory = url.deletingLastPathComponent()
            if try files.contentsOfDirectory(at: directory, options: []).isEmpty { try files.removeItem(at: directory) }
        } catch {
            Self.logger.error("清理成绩迁移文件遇到错误：\(String(describing: error), privacy: .private)")
        }
    }
}
