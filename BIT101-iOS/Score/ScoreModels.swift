import Foundation

/// 此枚举表示成绩页加载状态。
///
/// 成绩页根视图根据此枚举区分空闲、加载、已加载和失败状态。
enum ScoreLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 此结构表示单个成绩字段。
///
/// 服务端以二维表返回成绩；模型将表头和值保存为键值对，详情页复用这些字段。
struct ScoreField: Codable, Hashable {
    let key: String
    let value: String
}

/// 此结构表示成绩表中的一行课程记录。
///
/// 模型保留原始表头和值的对应关系，并提供常用字段访问器。
struct ScoreRow: Codable, Identifiable {
    let id: String
    let values: [ScoreField]

    /// 使用表头和值数组构造单行成绩记录。
    ///
    /// 模型按表头名称建立字段映射；接口字段顺序变化时，访问器仍按键名读取字段。
    init(index: Int, headers: [String], values: [String]) {
        let pairs = zip(headers, values).map { ScoreField(key: $0, value: $1) }
        self.values = pairs

        let identifier = pairs.first(where: { $0.key == "序号" })?.value
            ?? pairs.first(where: { $0.key == "课程编号" })?.value
            ?? "\(index)"
        id = identifier
    }

    /// 此下标器按原始表头读取任意字段，详情页使用它读取字段。
    subscript(_ key: String) -> String {
        values.first(where: { $0.key == key })?.value ?? ""
    }

    var courseName: String { self["课程名称"] }
    var score: String { self["成绩"] }
    var averageScore: String { self["平均分"] }
    var creditText: String { self["学分"] }
    var term: String { self["开课学期"] }
    var courseType: String { self["课程性质"] }
    var classRank: String { self["本人成绩在班级中占"] }
    var majorRank: String { self["本人成绩在专业中占"] }
    var courseNumber: String { self["课程编号"] }
    var teachingClassesCompletionStatus: String {
        self["该课程所有教学班成绩录入完毕"]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 此属性将学分转换为数值，统计逻辑用该数值计算加权结果。
    var numericCredit: Double? {
        Double(creditText)
    }
}

enum ScoreDetailRefreshDecision: Equatable {
    case fetch
    case reuseCompletedCache
    case reuseRateLimitedCache
}

/// 成绩简略列表更新后，此策略根据缓存和录入状态决定逐课程详情查询。
enum ScoreDetailRefreshPolicy {
    static let incompleteRetryInterval: TimeInterval = 24 * 60 * 60
    private static let ignoredBriefKeys: Set<String> = ["序号", "操作栏"]

    static func decision(
        briefRows: [ScoreRow],
        cachedRows: [ScoreRow]?,
        detailedUpdatedAt: Date?,
        now: Date
    ) -> ScoreDetailRefreshDecision {
        guard let cachedRows, !cachedRows.isEmpty,
              briefRowsMatchCache(briefRows, cachedRows: cachedRows)
        else { return .fetch }

        guard let latestTerm = briefRows.map(\.term).filter({ !$0.isEmpty }).max() else {
            return .fetch
        }
        let relevantRows = cachedRows.filter { $0.term == latestTerm }
        guard !relevantRows.isEmpty else { return .fetch }

        let knownStatuses = relevantRows.map(\.teachingClassesCompletionStatus).filter { !$0.isEmpty }
        if !knownStatuses.isEmpty,
           knownStatuses.allSatisfy({ $0 == "是" })
        {
            return .reuseCompletedCache
        }

        guard knownStatuses.contains("否"),
              let detailedUpdatedAt,
              now.timeIntervalSince(detailedUpdatedAt) < incompleteRetryInterval
        else { return .fetch }
        return .reuseRateLimitedCache
    }

    static func briefRowsMatchCache(_ briefRows: [ScoreRow], cachedRows: [ScoreRow]) -> Bool {
        guard !briefRows.isEmpty, !cachedRows.isEmpty else { return false }
        let briefKeys = Set(briefRows.flatMap { $0.values.map(\.key) })
            .subtracting(ignoredBriefKeys)
        guard !briefKeys.isEmpty else { return false }
        return signatures(for: briefRows, keys: briefKeys) == signatures(for: cachedRows, keys: briefKeys)
    }

    private static func signatures(for rows: [ScoreRow], keys: Set<String>) -> [String] {
        rows.map { row in
            keys.sorted().map { key in
                let value = row[key].trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(key.count):\(key)\(value.count):\(value)"
            }.joined(separator: "|")
        }.sorted()
    }
}

/// 此结构表示成绩统计摘要。
///
/// 统计逻辑参考网页端：同一课程编号对应多条记录时，选择最高成绩参与加权计算。
struct ScoreSummary {
    let selectedCourseCount: Int
    let totalCredit: Double
    let weightedAverageScore: Double?
    let weightedAverageGPA: Double?

    /// 从筛选后的成绩列表生成统计摘要。
    ///
    /// 同一课程编号出现多次时，统计逻辑选择最高分参与总学分和加权成绩计算。
    static func make(from rows: [ScoreRow]) -> ScoreSummary {
        var bestRowsByCourse: [String: ScoreRow] = [:]
        var fallbackRows: [ScoreRow] = []

        for row in rows {
            let courseNumber = row.courseNumber
            if courseNumber.isEmpty {
                fallbackRows.append(row)
                continue
            }

            if let existing = bestRowsByCourse[courseNumber] {
                if scoreValue(from: row.score) > scoreValue(from: existing.score) {
                    bestRowsByCourse[courseNumber] = row
                }
            } else {
                bestRowsByCourse[courseNumber] = row
            }
        }

        let selectedRows = Array(bestRowsByCourse.values) + fallbackRows
        var totalCredit = 0.0
        var totalScore = 0.0
        var totalGPA = 0.0

        for row in selectedRows {
            guard let credit = row.numericCredit, credit > 0 else { continue }
            totalCredit += credit
            totalScore += scoreValue(from: row.score) * credit
            totalGPA += gpaValue(from: row.score) * credit
        }

        return ScoreSummary(
            selectedCourseCount: selectedRows.count,
            totalCredit: totalCredit,
            weightedAverageScore: totalCredit > 0 ? totalScore / totalCredit : nil,
            weightedAverageGPA: totalCredit > 0 ? totalGPA / totalCredit : nil
        )
    }

    /// 将网页端等级描述映射为百分制成绩和 GPA。
    private static func gradeMapping(from raw: String) -> (score: Double, gpa: Double)? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "优秀":
            return (95, 4)
        case "良好":
            return (85, 3.6)
        case "中等":
            return (75, 2.8)
        case "及格":
            return (65, 1.7)
        case "不及格":
            return (0, 0)
        default:
            return nil
        }
    }

    /// 将成绩转换为统计用百分制数值。
    private static func scoreValue(from raw: String) -> Double {
        gradeMapping(from: raw)?.score ?? Double(raw) ?? 0
    }

    /// 此方法将成绩转换为 GPA。
    private static func gpaValue(from raw: String) -> Double {
        if let mapping = gradeMapping(from: raw) {
            return mapping.gpa
        }

        let score = Double(raw) ?? 0
        if score < 60 { return 0 }
        // 百分制使用学校公布的连续公式；等级制由上方的等级映射处理。
        return 4 - 3 * (100 - score) * (100 - score) / 1600
    }
}
