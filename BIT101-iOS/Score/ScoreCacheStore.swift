import Foundation

/// 成绩 iCloud 同步快照；保留详细字段及本地新鲜度，避免新设备立即重复查询。
struct ScoreCacheSyncPayload: Codable {
    var rows: [ScoreRow]
    var updatedAt: Date?
    var detailedUpdatedAt: Date?
}

/// 成绩缓存仓库。
///
/// 按学号隔离，避免切换账号后串用上一位用户的成绩。
/// 保留历史 key 以兼容既有安装；新的完整查询会自动覆盖旧的基础数据。
enum ScoreCacheStore {
    /// Hosted tests run inside the installed app and otherwise share its standard defaults.
    /// Keep stub responses away from the signed-in user's real score cache.
    private static var cacheAccountIdentifier: String {
#if ICLOUD_CROSS_DEVICE_SMOKE
        // The opt-in cross-device smoke must inspect the signed-in account's real cache.
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
        // Release builds contain no XCTest detection or test-only namespace strings.
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
        store.save(rows)
        updatedAtStore.save(Date())
        ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .scoreCache)
    }

    static func saveDetailed(rows: [ScoreRow]) {
        guard !rows.isEmpty else { return }
        let now = Date()
        store.save(rows)
        updatedAtStore.save(now)
        detailedUpdatedAtStore.save(now)
        ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .scoreCache)
    }

    /// A successful brief comparison refreshes the visible freshness timestamp
    /// without replacing the richer cached rows.
    static func markChecked() {
        updatedAtStore.save(Date())
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

    /// 写入来自 iCloud 的成绩缓存，不回传云端，也不触发学校服务器请求。
    static func applySynced(_ payload: ScoreCacheSyncPayload) {
        // 空云端快照不清除本机已有成绩，避免首次启用实验功能时由空设备反向覆盖。
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
}

extension Notification.Name {
    static let scoreCacheDidChange = Notification.Name("scoreCacheDidChange")
}
