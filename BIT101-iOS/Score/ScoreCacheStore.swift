import Foundation

/// 成绩缓存仓库。
///
/// 按学号隔离，避免切换账号后串用上一位用户的成绩。
/// 保留历史 key 以兼容既有安装；新的完整查询会自动覆盖旧的基础数据。
enum ScoreCacheStore {
    private static let store = AccountScopedCodableStore<[ScoreRow]>(
        keyPrefix: "score.detail.cache",
        accountIdentifier: { LoginStorage.shared.currentStudentID }
    )
    private static let updatedAtStore = AccountScopedCodableStore<Date>(
        keyPrefix: "score.detail.cache.updated-at",
        accountIdentifier: { LoginStorage.shared.currentStudentID }
    )

    static func loadRows() -> [ScoreRow]? {
        store.load()
    }

    static func save(rows: [ScoreRow]) {
        guard !rows.isEmpty else { return }
        store.save(rows)
        updatedAtStore.save(Date())
    }

    static func loadUpdatedAt() -> Date? {
        updatedAtStore.load()
    }
}
