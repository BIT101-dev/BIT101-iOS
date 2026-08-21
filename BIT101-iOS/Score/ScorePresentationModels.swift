import Foundation

/// 成绩页本地筛选偏好快照。
struct ScoreFilterPreferenceSnapshot: Codable {
    var selectedTerms: [String] = []
    var selectedCourseTypes: [String] = []
    var sortIndex: String?
    var sortOrder: String?
}

enum ScoreFilterPreferenceStore {
    private static let store = AccountScopedCodableStore<ScoreFilterPreferenceSnapshot>(
        keyPrefix: "score.filter.preferences",
        accountIdentifier: { LoginStorage.shared.currentStudentID }
    )

    static func load() -> ScoreFilterPreferenceSnapshot? {
        store.load()
    }

    static func save(
        selectedTerms: Set<String>,
        selectedCourseTypes: Set<String>,
        sortIndex: ScoreSortIndex,
        sortOrder: ScoreSortOrder
    ) {
        let snapshot = ScoreFilterPreferenceSnapshot(
            selectedTerms: Array(selectedTerms),
            selectedCourseTypes: Array(selectedCourseTypes),
            sortIndex: sortIndex.rawValue,
            sortOrder: sortOrder.rawValue
        )
        store.save(snapshot)
        ExperimentalPreferenceCloudSync.shared.localValueDidChange(in: .scoreFilters)
    }

    /// 写入来自 iCloud 的筛选偏好，不再次触发上传。
    static func applySynced(_ snapshot: ScoreFilterPreferenceSnapshot) {
        store.save(snapshot)
        NotificationCenter.default.post(name: .scoreFilterPreferencesDidChange, object: nil)
    }
}

extension Notification.Name {
    static let scoreFilterPreferencesDidChange = Notification.Name("scoreFilterPreferencesDidChange")
}

enum ScoreSortIndex: String, CaseIterable, Identifiable {
    case courseName
    case score
    case averageScore
    case credit
    case term
    case courseType

    var id: String { rawValue }

    var title: String {
        switch self {
        case .courseName: "名称"
        case .score: "成绩"
        case .averageScore: "均分"
        case .credit: "学分"
        case .term: "学期"
        case .courseType: "种类"
        }
    }

    func isMissingValue(in row: ScoreRow) -> Bool {
        switch self {
        case .courseName: normalizedText(row.courseName).isEmpty
        case .score: scoreComparableValue(from: row.score) == nil
        case .averageScore: numericComparableValue(from: row.averageScore) == nil
        case .credit: numericComparableValue(from: row.creditText) == nil
        case .term: normalizedText(row.term).isEmpty
        case .courseType: normalizedText(row.courseType).isEmpty
        }
    }

    func compare(_ lhs: ScoreRow, _ rhs: ScoreRow) -> ComparisonResult {
        switch self {
        case .courseName:
            normalizedText(lhs.courseName).localizedStandardCompare(normalizedText(rhs.courseName))
        case .score:
            compareNumbers(scoreComparableValue(from: lhs.score), scoreComparableValue(from: rhs.score))
        case .averageScore:
            compareNumbers(numericComparableValue(from: lhs.averageScore), numericComparableValue(from: rhs.averageScore))
        case .credit:
            compareNumbers(numericComparableValue(from: lhs.creditText), numericComparableValue(from: rhs.creditText))
        case .term:
            normalizedText(lhs.term).localizedStandardCompare(normalizedText(rhs.term))
        case .courseType:
            normalizedText(lhs.courseType).localizedStandardCompare(normalizedText(rhs.courseType))
        }
    }

    private func normalizedText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func numericComparableValue(from raw: String) -> Double? {
        let trimmed = normalizedText(raw)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private func scoreComparableValue(from raw: String) -> Double? {
        let trimmed = normalizedText(raw)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case "优秀": return 95
        case "良好": return 85
        case "中等": return 75
        case "及格": return 65
        case "不及格": return 0
        default: return Double(trimmed)
        }
    }

    private func compareNumbers(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        guard let lhs, let rhs else { return .orderedSame }
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

enum ScoreSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ascending: "升序"
        case .descending: "降序"
        }
    }

    var systemImage: String {
        switch self {
        case .ascending: "arrow.up"
        case .descending: "arrow.down"
        }
    }

    var toggled: ScoreSortOrder {
        switch self {
        case .ascending: .descending
        case .descending: .ascending
        }
    }
}
