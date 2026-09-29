import Foundation

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

/// 成绩缓存仓库。
///
/// 按学号隔离，切换账号后读取当前账号的成绩。
enum ScoreCacheStore {
    private static let fileStore = AccountScopedFileCodableStore<ScoreCacheSnapshot>(
        filename: "score-cache.json",
        session: { AppFileDirectories.scoreCacheSession }
    )
    private static let legacyRowsStore = AccountScopedCodableStore<[ScoreRow]>(
        keyPrefix: "score.detail.cache",
        session: { AppFileDirectories.scoreCacheSession }
    )
    private static let legacyUpdatedAtStore = AccountScopedCodableStore<Date>(
        keyPrefix: "score.detail.cache.updated-at",
        session: { AppFileDirectories.scoreCacheSession }
    )
    private static let legacyDetailedUpdatedAtStore = AccountScopedCodableStore<Date>(
        keyPrefix: "score.detail.cache.full-updated-at",
        session: { AppFileDirectories.scoreCacheSession }
    )

    static func loadRows() -> [ScoreRow]? {
        loadSnapshot()?.rows
    }

    static func save(rows: [ScoreRow]) {
        var snapshot = loadSnapshot() ?? ScoreCacheSnapshot()
        snapshot.rows = rows
        snapshot.updatedAt = Date()
        if rows.isEmpty {
            snapshot.detailedUpdatedAt = nil
        }
        if persist(snapshot) {
            notifyCacheDidChange()
        }
    }

    static func saveDetailed(rows: [ScoreRow]) {
        let now = Date()
        var snapshot = loadSnapshot() ?? ScoreCacheSnapshot()
        snapshot.rows = rows
        snapshot.updatedAt = now
        snapshot.detailedUpdatedAt = now
        if persist(snapshot) {
            notifyCacheDidChange()
        }
    }

    /// 一次成功的简略比较更新可见的新鲜度时间戳，并保留缓存中更完整的成绩行。
    static func markChecked() {
        var snapshot = loadSnapshot() ?? ScoreCacheSnapshot()
        snapshot.updatedAt = Date()
        guard persist(snapshot) else { return }
        notifyCacheDidChange()
    }

    static func loadUpdatedAt() -> Date? {
        loadSnapshot()?.updatedAt
    }

    static func loadDetailedUpdatedAt() -> Date? {
        loadSnapshot()?.detailedUpdatedAt
    }

    static func syncPayload() -> ScoreCacheSyncPayload {
        let snapshot = loadSnapshot() ?? ScoreCacheSnapshot()
        return ScoreCacheSyncPayload(
            rows: snapshot.rows ?? [],
            updatedAt: snapshot.updatedAt,
            detailedUpdatedAt: snapshot.detailedUpdatedAt
        )
    }

    /// 写入来自 iCloud 的成绩缓存，完成云端到本地的单向落地；该操作仅更新本地缓存和变更通知。
    static func applySynced(_ payload: ScoreCacheSyncPayload) {
        // 空云端快照保留本机已有成绩，首次启用实验功能时继续使用本机缓存。
        guard !payload.rows.isEmpty else { return }
        let snapshot = ScoreCacheSnapshot(
            rows: payload.rows,
            updatedAt: payload.updatedAt,
            detailedUpdatedAt: payload.detailedUpdatedAt
        )
        guard persist(snapshot, syncPreference: false) else { return }
        notifyCacheDidChange()
    }

    private static func loadSnapshot() -> ScoreCacheSnapshot? {
        if fileStore.hasStoredFile {
            return fileStore.load()
        }

        let legacySnapshot = ScoreCacheSnapshot(
            rows: legacyRowsStore.load(),
            updatedAt: legacyUpdatedAtStore.load(),
            detailedUpdatedAt: legacyDetailedUpdatedAtStore.load()
        )
        guard legacySnapshot.containsData else { return nil }
        if persistFile(legacySnapshot) {
            clearLegacyDefaults()
        }
        return legacySnapshot
    }

    @discardableResult
    private static func persist(_ snapshot: ScoreCacheSnapshot, syncPreference: Bool = true) -> Bool {
        guard persistFile(snapshot) else { return false }
        clearLegacyDefaults()
        if syncPreference {
            ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .scoreCache)
        }
        return true
    }

    private static func persistFile(_ snapshot: ScoreCacheSnapshot) -> Bool {
        fileStore.save(snapshot)
    }

    private static func clearLegacyDefaults() {
        legacyRowsStore.remove()
        legacyUpdatedAtStore.remove()
        legacyDetailedUpdatedAtStore.remove()
    }

    private static func notifyCacheDidChange() {
        NotificationCenter.default.post(name: .scoreCacheDidChange, object: nil)
    }
}

extension Notification.Name {
    static let scoreCacheDidChange = Notification.Name("scoreCacheDidChange")
}
