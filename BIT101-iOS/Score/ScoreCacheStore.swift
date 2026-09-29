import ClientCore
import Foundation
import OSLog

/// 成绩 iCloud 同步快照，保留详细字段和本地新鲜度，使新设备直接复用已有数据。
nonisolated struct ScoreCacheSyncPayload: Codable, Sendable {
    var rows: [ScoreRow]
    var updatedAt: Date?
    var detailedUpdatedAt: Date?
}

/// 成绩本地快照，把行数据和新鲜度时间放在同一个原子文件中。
nonisolated struct ScoreCacheSnapshot: Codable, Sendable {
    var rows: [ScoreRow]?
    var updatedAt: Date?
    var detailedUpdatedAt: Date?

    var containsData: Bool {
        rows != nil || updatedAt != nil || detailedUpdatedAt != nil
    }
}

nonisolated struct ScoreCacheLegacyData: Sendable {
    let rows: Data?
    let updatedAt: Data?
    let detailedUpdatedAt: Data?

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
    case markChecked
    case synced(ScoreCacheSyncPayload)
}

nonisolated enum ScoreCacheDiskWriteResult: Sendable {
    case saved(ScoreCacheSnapshot)
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
enum ScoreCacheStore {
    private nonisolated static let logger = Logger(subsystem: "BIT101", category: "ScoreCache")
    private static let repository = ScoreCacheDiskRepository()

    static func loadSnapshot(for session: AppStorageSession? = nil) async -> ScoreCacheSnapshot? {
        let session = session ?? AppFileDirectories.scoreCacheSession
        let result = await repository.load(for: session, legacyData: legacyData(for: session))
        switch result {
        case .loaded(let snapshot, let migratedLegacy):
            if migratedLegacy { clearLegacyDefaults(for: session) }
            return snapshot
        case .missing, .unreadable:
            return nil
        }
    }

    static func loadRows(for session: AppStorageSession? = nil) async -> [ScoreRow]? {
        await loadSnapshot(for: session)?.rows
    }

    static func loadUpdatedAt(for session: AppStorageSession? = nil) async -> Date? {
        await loadSnapshot(for: session)?.updatedAt
    }

    static func loadDetailedUpdatedAt(for session: AppStorageSession? = nil) async -> Date? {
        await loadSnapshot(for: session)?.detailedUpdatedAt
    }

    @discardableResult
    static func save(rows: [ScoreRow], for session: AppStorageSession? = nil) async -> Date? {
        let session = session ?? AppFileDirectories.scoreCacheSession
        let result = await repository.mutate(
            .rows(rows),
            for: session,
            legacyData: legacyData(for: session)
        )
        return finishWrite(result, for: session, syncPreference: true)
    }

    @discardableResult
    static func saveDetailed(rows: [ScoreRow], for session: AppStorageSession? = nil) async -> Date? {
        let session = session ?? AppFileDirectories.scoreCacheSession
        let result = await repository.mutate(
            .detailedRows(rows),
            for: session,
            legacyData: legacyData(for: session)
        )
        return finishWrite(result, for: session, syncPreference: true)
    }

    /// 一次成功的简略比较更新可见的新鲜度时间戳，并保留缓存中更完整的成绩行。
    @discardableResult
    static func markChecked(for session: AppStorageSession? = nil) async -> Date? {
        let session = session ?? AppFileDirectories.scoreCacheSession
        let result = await repository.mutate(
            .markChecked,
            for: session,
            legacyData: legacyData(for: session)
        )
        return finishWrite(result, for: session, syncPreference: true)
    }

    /// 文件损坏时返回 nil，使同步协调暂停该域，避免把空快照上传覆盖云端数据。
    static func syncPayload(for session: AppStorageSession? = nil) async -> ScoreCacheSyncPayload? {
        let session = session ?? AppFileDirectories.scoreCacheSession
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
    static func applySynced(
        _ payload: ScoreCacheSyncPayload,
        for session: AppStorageSession? = nil
    ) async -> Bool {
        guard !payload.rows.isEmpty else { return false }
        let session = session ?? AppFileDirectories.scoreCacheSession
        let result = await repository.mutate(
            .synced(payload),
            for: session,
            legacyData: legacyData(for: session)
        )
        guard result.isSaved else {
            _ = finishWrite(result, for: session, syncPreference: false)
            return false
        }
        _ = finishWrite(result, for: session, syncPreference: false)
        return true
    }

    private static func finishWrite(
        _ result: ScoreCacheDiskWriteResult,
        for session: AppStorageSession,
        syncPreference: Bool
    ) -> Date? {
        guard case .saved(let snapshot) = result else {
            if result.isUnreadable {
                logger.error("保留无法读取的成绩缓存，跳过保存")
            }
            return nil
        }

        clearLegacyDefaults(for: session)
        if syncPreference {
            ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .scoreCache, for: session)
        }
        NotificationCenter.default.post(name: .scoreCacheDidChange, object: nil)
        return snapshot.updatedAt
    }

    private static func legacyData(for session: AppStorageSession) -> ScoreCacheLegacyData {
        let defaults = AppFileDirectories.defaults
        func value(_ prefix: String) -> Data? {
            defaults.data(forKey: session.key(prefix))
                ?? defaults.data(forKey: session.legacyKey(prefix))
        }
        return ScoreCacheLegacyData(
            rows: value("score.detail.cache"),
            updatedAt: value("score.detail.cache.updated-at"),
            detailedUpdatedAt: value("score.detail.cache.full-updated-at")
        )
    }

    private static func clearLegacyDefaults(for session: AppStorageSession) {
        let defaults = AppFileDirectories.defaults
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
    private let storageRoot: URL?

    init(files: any AppFileService = AppFileDirectories.files, storageRoot: URL? = nil) {
        self.files = files
        self.storageRoot = storageRoot
    }

    func load(for session: AppStorageSession, legacyData: ScoreCacheLegacyData) -> ScoreCacheDiskReadResult {
        switch readFile(for: session) {
        case .loaded(let snapshot):
            return .loaded(snapshot, migratedLegacy: false)
        case .unreadable:
            return .unreadable
        case .missing:
            guard let snapshot = decodeLegacy(legacyData), snapshot.containsData else { return .missing }
            do {
                try write(snapshot, for: session)
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
        var snapshot: ScoreCacheSnapshot
        switch readFile(for: session) {
        case .loaded(let stored):
            snapshot = stored
        case .missing:
            snapshot = decodeLegacy(legacyData) ?? ScoreCacheSnapshot()
        case .unreadable:
            return .unreadable
        }

        switch mutation {
        case .rows(let rows):
            snapshot.rows = rows
            snapshot.updatedAt = Date()
            if rows.isEmpty { snapshot.detailedUpdatedAt = nil }
        case .detailedRows(let rows):
            let now = Date()
            snapshot.rows = rows
            snapshot.updatedAt = now
            snapshot.detailedUpdatedAt = now
        case .markChecked:
            snapshot.updatedAt = Date()
        case .synced(let payload):
            snapshot = ScoreCacheSnapshot(
                rows: payload.rows,
                updatedAt: payload.updatedAt,
                detailedUpdatedAt: payload.detailedUpdatedAt
            )
        }

        do {
            try write(snapshot, for: session)
            removeLegacyFile(for: session)
            return .saved(snapshot)
        } catch {
            Self.logger.error("保存成绩缓存失败：\(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    private enum ExistingFileResult {
        case loaded(ScoreCacheSnapshot)
        case missing
        case unreadable
    }

    private func readFile(for session: AppStorageSession) -> ExistingFileResult {
        let url = fileURL(for: session)
        guard files.fileExists(at: url) else {
            let legacyURL = legacyFileURL(for: session)
            guard legacyURL != url, files.fileExists(at: legacyURL) else { return .missing }
            let legacyResult = readFile(at: legacyURL)
            guard case .loaded(let snapshot) = legacyResult else { return legacyResult }
            do {
                try write(snapshot, for: session)
                removeLegacyFile(for: session)
            } catch {
                Self.logger.error("成绩缓存迁移写入失败：\(String(describing: error), privacy: .public)")
            }
            return .loaded(snapshot)
        }
        return readFile(at: url)
    }

    private func readFile(at url: URL) -> ExistingFileResult {
        try? files.setPrivateFileProtection(at: url)
        guard let data = try? files.readData(at: url),
              let snapshot = try? JSONDecoder().decode(ScoreCacheSnapshot.self, from: data)
        else {
            Self.logger.error("成绩缓存无法读取，保留原文件：\(url.lastPathComponent, privacy: .public)")
            return .unreadable
        }
        return .loaded(snapshot)
    }

    private func decodeLegacy(_ legacyData: ScoreCacheLegacyData) -> ScoreCacheSnapshot? {
        let decoder = JSONDecoder()
        let snapshot = ScoreCacheSnapshot(
            rows: legacyData.rows.flatMap { try? decoder.decode([ScoreRow].self, from: $0) },
            updatedAt: legacyData.updatedAt.flatMap { try? decoder.decode(Date.self, from: $0) },
            detailedUpdatedAt: legacyData.detailedUpdatedAt.flatMap { try? decoder.decode(Date.self, from: $0) }
        )
        return snapshot.containsData ? snapshot : nil
    }

    private func write(_ snapshot: ScoreCacheSnapshot, for session: AppStorageSession) throws {
        let url = fileURL(for: session)
        try files.createDirectory(at: url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(snapshot)
        try files.writeData(
            data,
            to: url,
            options: AppFileSystem.protectedDataWritingOptions
        )
    }

    private func fileURL(for session: AppStorageSession) -> URL {
        if let storageRoot {
            return storageRoot
                .appending(path: session.accountStorageIdentifier, directoryHint: .isDirectory)
                .appending(path: "score-cache.json")
        }
        return AppFileDirectories.accountSupportFileURL(
            accountDirectoryName: session.accountStorageIdentifier,
            named: "score-cache.json"
        )
    }

    private func legacyFileURL(for session: AppStorageSession) -> URL {
        if let storageRoot {
            return storageRoot
                .appending(path: session.legacyAccountDirectoryNameForMigration, directoryHint: .isDirectory)
                .appending(path: "score-cache.json")
        }
        return AppFileDirectories.accountSupportFileURL(
            accountDirectoryName: session.legacyAccountDirectoryNameForMigration,
            named: "score-cache.json"
        )
    }

    private func removeLegacyFile(for session: AppStorageSession) {
        let url = legacyFileURL(for: session)
        guard url != fileURL(for: session), files.fileExists(at: url),
              let data = try? files.readData(at: url),
              (try? JSONDecoder().decode(ScoreCacheSnapshot.self, from: data)) != nil
        else { return }
        try? files.removeItem(at: url)
        let directory = url.deletingLastPathComponent()
        if (try? files.contentsOfDirectory(at: directory, options: []).isEmpty) == true {
            try? files.removeItem(at: directory)
        }
    }
}

extension Notification.Name {
    static let scoreCacheDidChange = Notification.Name("scoreCacheDidChange")
}
