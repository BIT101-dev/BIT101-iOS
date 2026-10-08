import ScoreDomain
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
    private let changeSubject = PassthroughSubject<AppStorageSession, Never>()
    public var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
    private let saveSubject = PassthroughSubject<AppStorageSession, Never>()
    public var localSaves: AnyPublisher<AppStorageSession, Never> { saveSubject.eraseToAnyPublisher() }
    private nonisolated static let logger = Logger(subsystem: "BIT101", category: "ScoreCache")
    private let repository: ScoreCacheDiskRepository
    private let defaults: UserDefaults
    private let currentSession: () -> AppStorageSession
    private let storageOperations: StorageOperationTracker

    public init(files: any AppFileService, storageRoot: URL, defaults: UserDefaults, session: @escaping () -> AppStorageSession, storageOperations: StorageOperationTracker = StorageOperationTracker()) {
        self.repository = ScoreCacheDiskRepository(files: files, storageRoot: storageRoot)
        self.defaults = defaults
        self.currentSession = session
        self.storageOperations = storageOperations
    }

    public func loadSnapshot(for session: AppStorageSession? = nil) async -> ScoreCacheSnapshot? {
        guard storageOperations.begin() else { return nil }
        defer { storageOperations.finish() }
        let session = session ?? currentSession()
        let result = await repository.load(for: session, legacyData: legacyData(for: session))
        switch result {
        case .loaded(let snapshot, let migratedLegacy):
            if migratedLegacy { clearLegacyDefaults(for: session) }
            return snapshot
        case .missing, .unreadable:
            return nil
        }
    }

    public func loadRows(for session: AppStorageSession? = nil) async -> [ScoreRow]? {
        await loadSnapshot(for: session)?.rows
    }

    public func loadUpdatedAt(for session: AppStorageSession? = nil) async -> Date? {
        await loadSnapshot(for: session)?.updatedAt
    }

    @discardableResult
    public func save(rows: [ScoreRow], for session: AppStorageSession? = nil) async -> Date? {
        guard storageOperations.begin() else { return nil }
        defer { storageOperations.finish() }
        let session = session ?? currentSession()
        let result = await repository.mutate(
            .rows(rows),
            for: session,
            legacyData: legacyData(for: session)
        )
        return finishWrite(result, for: session, syncPreference: true)
    }

    @discardableResult
    public func saveDetailed(rows: [ScoreRow], for session: AppStorageSession? = nil) async -> Date? {
        guard storageOperations.begin() else { return nil }
        defer { storageOperations.finish() }
        let session = session ?? currentSession()
        let result = await repository.mutate(
            .detailedRows(rows),
            for: session,
            legacyData: legacyData(for: session)
        )
        return finishWrite(result, for: session, syncPreference: true)
    }

    /// 文件损坏时返回 nil，使同步协调暂停该域，避免把空快照上传覆盖云端数据。
    public func syncPayload(for session: AppStorageSession? = nil) async -> ScoreCacheSyncPayload? {
        guard storageOperations.begin() else { return nil }
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
            return nil
        }
    }

    /// 写入来自 iCloud 的成绩缓存；损坏的本地文件保留原样，等待明确恢复。
    @discardableResult
    public func applySynced(
        _ payload: ScoreCacheSyncPayload,
        for session: AppStorageSession? = nil,
        replacing expected: ScoreCacheSyncPayload? = nil
    ) async -> Bool {
        guard storageOperations.begin() else { return false }
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
            return false
        }
        _ = finishWrite(result, for: session, syncPreference: false)
        return true
    }

    private func finishWrite(
        _ result: ScoreCacheDiskWriteResult,
        for session: AppStorageSession,
        syncPreference: Bool
    ) -> Date? {
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
            guard !Task.isCancelled else { return .superseded }
            snapshot = ScoreCacheSnapshot(
                rows: payload.rows,
                updatedAt: payload.updatedAt,
                detailedUpdatedAt: payload.detailedUpdatedAt
            )
        }

        do {
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
        guard files.fileExists(at: url) else {
            let legacyURL = legacyFileURL(for: session)
            guard legacyURL != url, files.fileExists(at: legacyURL) else { return .missing }
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
        return readFile(at: url)
    }

    private func readFile(at url: URL) -> ExistingFileResult {
        try? files.setPrivateFileProtection(at: url)
        guard let data = try? files.readData(at: url),
              let stored = try? decodeStoredData(data)
        else {
            Self.logger.error("成绩缓存无法读取，保留原文件：\(url.lastPathComponent, privacy: .public)")
            return .unreadable
        }
        return .loaded(stored)
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
        guard let snapshot = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
        var fields = stored.fields.merging(snapshot) { _, new in new }
        fields["schemaVersion"] = 1
        let data = try JSONSerialization.data(withJSONObject: fields)
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
        guard url != fileURL(for: session), files.fileExists(at: url),
              let data = try? files.readData(at: url),
              (try? decodeStoredData(data)) != nil
        else { return }
        try? files.removeItem(at: url)
        let directory = url.deletingLastPathComponent()
        if (try? files.contentsOfDirectory(at: directory, options: []).isEmpty) == true {
            try? files.removeItem(at: directory)
        }
    }
}
