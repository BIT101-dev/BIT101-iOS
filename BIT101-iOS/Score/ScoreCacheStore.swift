import Foundation

/// 成绩缓存仓库。
///
/// 按学号隔离，避免切换账号后串用上一位用户的成绩。当前缓存的是列表查询返回的基础成绩；
/// `score.detail.cache` 只是兼容既有安装的历史 key，不再表示请求使用 `detail=true`。
enum ScoreCacheStore {
    private static let store = AccountScopedCodableStore<[ScoreRow]>(
        keyPrefix: "score.detail.cache",
        accountIdentifier: { LoginStorage.shared.currentStudentID }
    )

    static func loadRows() -> [ScoreRow]? {
        store.load()
    }

    static func save(rows: [ScoreRow]) {
        guard !rows.isEmpty else { return }
        store.save(rows)
    }
}
