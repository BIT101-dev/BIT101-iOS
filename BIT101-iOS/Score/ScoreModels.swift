import Foundation

/// 成绩页加载状态。
///
/// 与其它模块一致，这里统一成四态，便于成绩页根视图只根据一个状态枚举驱动空态、错误态和加载态。
enum ScoreLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 单个成绩字段。
///
/// 服务端返回的是二维表，这里先把表头和值压成键值对，便于详情页复用。
struct ScoreField: Codable, Hashable {
    let key: String
    let value: String
}

/// 成绩表中的一行课程记录。
///
/// 保留原始表头和值的对应关系，同时提供常用字段的便捷访问器。
struct ScoreRow: Codable, Identifiable {
    let id: String
    let values: [ScoreField]

    /// 使用表头和值数组构造单行成绩记录。
    ///
    /// 之所以不直接依赖固定字段顺序，是因为成绩代理接口本质上返回的是一个“二维表”，
    /// 表头变化时这里仍能靠键名访问保持一定韧性。
    init(index: Int, headers: [String], values: [String]) {
        let pairs = zip(headers, values).map { ScoreField(key: $0, value: $1) }
        self.values = pairs

        let identifier = pairs.first(where: { $0.key == "序号" })?.value
            ?? pairs.first(where: { $0.key == "课程编号" })?.value
            ?? "\(index)"
        id = identifier
    }

    /// 按原始表头读取任意字段，详情页会直接遍历这个访问层。
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

    /// 学分的数值化表示，供统计时直接参与加权计算。
    var numericCredit: Double? {
        Double(creditText)
    }
}

/// 成绩统计摘要。
///
/// 统计逻辑与网页端保持接近：同一课程编号只取最高成绩参与加权计算。
struct ScoreSummary {
    let selectedCourseCount: Int
    let totalCredit: Double
    let weightedAverageScore: Double?
    let weightedAverageGPA: Double?

    /// 从筛选后的成绩列表生成统计摘要。
    ///
    /// 同一课程编号出现多次时，只取最高分参与总学分和加权成绩计算。
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

    /// 把网页端可能返回的等级描述映射为数值成绩。
    private static func scoreValue(from raw: String) -> Double {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "优秀":
            return 95
        case "良好":
            return 85
        case "中等":
            return 75
        case "及格":
            return 65
        case "不及格":
            return 0
        default:
            return Double(raw) ?? 0
        }
    }

    /// 把成绩映射成 GPA。
    private static func gpaValue(from raw: String) -> Double {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "优秀":
            return 4
        case "良好":
            return 3.6
        case "中等":
            return 2.8
        case "及格":
            return 1.7
        case "不及格":
            return 0
        default:
            let score = Double(raw) ?? 0
            if score < 60 { return 0 }
            // 百分制使用学校公布的连续公式；等级制由上面的官方映射处理。
            return 4 - 3 * (100 - score) * (100 - score) / 1600
        }
    }
}
