import Foundation

/// 成绩缓存仓库。
///
/// 按学号隔离，避免切换账号后串用上一位用户的成绩。只缓存 `detail=true` 的完整成绩。
enum ScoreCacheStore {
    private static let keyPrefix = "score.detail.cache"

    static func loadRows() -> [ScoreRow]? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode([ScoreRow].self, from: data)
    }

    static func save(rows: [ScoreRow]) {
        guard !rows.isEmpty, let data = try? JSONEncoder().encode(rows) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static var storageKey: String {
        let studentID = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = studentID.isEmpty ? "guest" : studentID
        return "\(keyPrefix).\(suffix)"
    }
}
