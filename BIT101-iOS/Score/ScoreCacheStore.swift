import Foundation

/// 成绩 iCloud 同步快照，保留详细字段和本地新鲜度，使新设备直接复用已有数据。
struct ScoreCacheSyncPayload: Codable {
    var rows: [ScoreRow]
    var updatedAt: Date?
    var detailedUpdatedAt: Date?
}

/// 成绩缓存仓库。
///
/// 按学号隔离，切换账号后读取当前账号的成绩。
/// 保留历史 key 兼容既有安装；新的完整查询覆盖旧的基础数据。
enum ScoreCacheStore {
    /// Hosted tests run inside the installed app and share its standard defaults.
    /// Stub responses use a dedicated account namespace, while the signed-in user's score cache remains separate.
    private static var cacheAccountIdentifier: String {
#if ICLOUD_CROSS_DEVICE_SMOKE
        // ICLOUD_CROSS_DEVICE_SMOKE reads the signed-in account's real cache.
        return LoginStorage.shared.currentStudentID
#elseif DEBUG
        let environment = ProcessInfo.processInfo.environment
        if NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil {
            return "__bit101_tests__"
        }
        return LoginStorage.shared.currentStudentID
#else
        // Release builds resolve the account identifier from LoginStorage and compile without the XCTest detection branch.
        return LoginStorage.shared.currentStudentID
#endif
    }

    private static let store = AccountScopedCodableStore<[ScoreRow]>(
        keyPrefix: "score.detail.cache",
        accountIdentifier: { cacheAccountIdentifier }
    )
    private static let updatedAtStore = AccountScopedCodableStore<Date>(
        keyPrefix: "score.detail.cache.updated-at",
        accountIdentifier: { cacheAccountIdentifier }
    )
    private static let detailedUpdatedAtStore = AccountScopedCodableStore<Date>(
        keyPrefix: "score.detail.cache.full-updated-at",
        accountIdentifier: { cacheAccountIdentifier }
    )

    static func loadRows() -> [ScoreRow]? {
        store.load()
    }

    static func save(rows: [ScoreRow]) {
        guard !rows.isEmpty else { return }
        persist(rows: rows, updatedAt: Date())
    }

    static func saveDetailed(rows: [ScoreRow]) {
        guard !rows.isEmpty else { return }
        let now = Date()
        persist(rows: rows, updatedAt: now, detailedUpdatedAt: now)
    }

    /// 一次成功的简略比较更新可见的新鲜度时间戳，并保留缓存中更完整的成绩行。
    static func markChecked() {
        updatedAtStore.save(Date())
        ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .scoreCache)
    }

    static func loadUpdatedAt() -> Date? {
        updatedAtStore.load()
    }

    static func loadDetailedUpdatedAt() -> Date? {
        detailedUpdatedAtStore.load()
    }

    static func syncPayload() -> ScoreCacheSyncPayload {
        ScoreCacheSyncPayload(
            rows: store.load() ?? [],
            updatedAt: updatedAtStore.load(),
            detailedUpdatedAt: detailedUpdatedAtStore.load()
        )
    }

    /// 写入来自 iCloud 的成绩缓存，完成云端到本地的单向落地；该操作仅更新本地缓存和变更通知。
    static func applySynced(_ payload: ScoreCacheSyncPayload) {
        // 空云端快照保留本机已有成绩，首次启用实验功能时继续使用本机缓存。
        guard !payload.rows.isEmpty else { return }
        store.save(payload.rows)
        if let updatedAt = payload.updatedAt {
            updatedAtStore.save(updatedAt)
        } else {
            updatedAtStore.remove()
        }
        if let detailedUpdatedAt = payload.detailedUpdatedAt {
            detailedUpdatedAtStore.save(detailedUpdatedAt)
        } else {
            detailedUpdatedAtStore.remove()
        }
        NotificationCenter.default.post(name: .scoreCacheDidChange, object: nil)
    }

    private static func persist(
        rows: [ScoreRow],
        updatedAt: Date,
        detailedUpdatedAt: Date? = nil
    ) {
        store.save(rows)
        updatedAtStore.save(updatedAt)
        if let detailedUpdatedAt {
            detailedUpdatedAtStore.save(detailedUpdatedAt)
        }
        ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .scoreCache)
    }
}

extension Notification.Name {
    static let scoreCacheDidChange = Notification.Name("scoreCacheDidChange")
}
