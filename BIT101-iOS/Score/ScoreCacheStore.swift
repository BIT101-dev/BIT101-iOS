import Foundation

/// 成绩完整结果缓存快照。
///
/// 只缓存 `detail=true` 的完整成绩，不缓存网页端用于快速预览的轻量结果，避免列表字段语义降级。
private struct ScoreCacheSnapshot: Codable {
    let updatedAt: Date
    let rows: [ScoreRow]
}

/// 成绩缓存仓库。
///
/// 按学号隔离，避免切换账号后串用上一位用户的成绩。
enum ScoreCacheStore {
    private static let keyPrefix = "score.detail.cache"

    static func loadRows() -> [ScoreRow]? {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let snapshot = try? JSONDecoder().decode(ScoreCacheSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot.rows
    }

    static func save(rows: [ScoreRow]) {
        guard !rows.isEmpty else { return }
        let snapshot = ScoreCacheSnapshot(updatedAt: Date(), rows: rows)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static var storageKey: String {
        let studentID = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = studentID.isEmpty ? "guest" : studentID
        return "\(keyPrefix).\(suffix)"
    }
}
