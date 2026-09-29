import ClientCore
//
//  CourseModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Foundation

/// 课程评分展示工具。
///
/// 后端课程与课程评论评分当前仍按 10 分制返回，iOS 端统一折算成 5 分制展示。
enum CourseRatingText {
    nonisolated static func value(from raw: Double) -> Double {
        max(0, raw) / 2
    }

    nonisolated static func value(from raw: Int) -> Double {
        value(from: Double(raw))
    }

    nonisolated static func text(from raw: Double, empty: String = "暂无") -> String {
        guard raw > 0 else { return empty }
        return String(format: "%.1f/5", value(from: raw))
    }

    nonisolated static func text(from raw: Int, empty: String = "未评分") -> String {
        text(from: Double(raw), empty: empty)
    }
}

/// 课程列表单项。
///
/// 模型保留课程列表与详情入口所需的基础字段。
nonisolated struct CourseSummary: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: Int
    let name: String
    let number: String
    let credit: Double?
    let likeNum: Int
    let commentNum: Int
    let rate: Double
    let teachersName: String
    let teachersNumber: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case number
        case credit
        case credits
        case likeNum
        case commentNum
        case rate
        case teachersName
        case teachersNumber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        number = try container.decode(String.self, forKey: .number)
        credit = container.decodeFlexibleDoubleIfPresent(forKeys: [.credit, .credits])
        likeNum = try container.decode(Int.self, forKey: .likeNum)
        commentNum = try container.decode(Int.self, forKey: .commentNum)
        rate = try container.decode(Double.self, forKey: .rate)
        teachersName = try container.decode(String.self, forKey: .teachersName)
        teachersNumber = try container.decode(String.self, forKey: .teachersNumber)
    }

    init(detail: CourseDetail) {
        id = detail.id
        name = detail.name
        number = detail.number
        credit = detail.credit
        likeNum = detail.likeNum
        commentNum = detail.commentNum
        rate = detail.rate
        teachersName = detail.teachersName
        teachersNumber = detail.teachersNumber
    }
}

/// 从深链或其它业务页面进入课程详情时携带的导航上下文。
///
/// 课程号/名称入口只携带外部身份字段，统一目的地负责检索、消歧和失败展示。
struct CourseNavigationRequest: Identifiable, Hashable {
    let id = UUID()
    let courseID: Int
    /// 课程详情需要课程号或课程名时，使用统一检索流程完成匹配。
    let lookupCourseName: String?
    let lookupCourseNumber: String?
    let lookupTeacher: String?
    let preparedCourse: CourseSummary?
    let searchQuery: String?
    let searchResults: [CourseSummary]?

    var hasLookupIdentity: Bool {
        lookupCourseName != nil || lookupCourseNumber != nil
    }

    init(
        courseID: Int,
        lookupCourseName: String? = nil,
        lookupCourseNumber: String? = nil,
        lookupTeacher: String? = nil,
        preparedCourse: CourseSummary? = nil,
        searchQuery: String? = nil,
        searchResults: [CourseSummary]? = nil
    ) {
        self.courseID = courseID
        self.lookupCourseName = lookupCourseName
        self.lookupCourseNumber = lookupCourseNumber
        self.lookupTeacher = lookupTeacher
        self.preparedCourse = preparedCourse
        self.searchQuery = searchQuery
        self.searchResults = searchResults
    }

    /// 从仅含教务字段的记录跳转到统一课程详情/评价页。
    static func lookup(courseName: String, courseNumber: String, teacher: String = "") -> Self {
        Self(
            courseID: 0,
            lookupCourseName: courseName,
            lookupCourseNumber: courseNumber,
            lookupTeacher: teacher
        )
    }
}

/// 课程详情。
///
/// 详情接口在课程基础信息外，还会返回当前用户的点赞状态。
nonisolated struct CourseDetail: Decodable, Equatable, Sendable {
    let id: Int
    let name: String
    let number: String
    let credit: Double?
    let likeNum: Int
    let commentNum: Int
    let rate: Double
    let teachersName: String
    let teachersNumber: String
    let like: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case number
        case credit
        case credits
        case likeNum
        case commentNum
        case rate
        case teachersName
        case teachersNumber
        case like
    }

    init(
        id: Int,
        name: String,
        number: String,
        credit: Double?,
        likeNum: Int,
        commentNum: Int,
        rate: Double,
        teachersName: String,
        teachersNumber: String,
        like: Bool
    ) {
        self.id = id
        self.name = name
        self.number = number
        self.credit = credit
        self.likeNum = likeNum
        self.commentNum = commentNum
        self.rate = rate
        self.teachersName = teachersName
        self.teachersNumber = teachersNumber
        self.like = like
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        number = try container.decode(String.self, forKey: .number)
        credit = container.decodeFlexibleDoubleIfPresent(forKeys: [.credit, .credits])
        likeNum = try container.decode(Int.self, forKey: .likeNum)
        commentNum = try container.decode(Int.self, forKey: .commentNum)
        rate = try container.decode(Double.self, forKey: .rate)
        teachersName = try container.decode(String.self, forKey: .teachersName)
        teachersNumber = try container.decode(String.self, forKey: .teachersNumber)
        like = try container.decode(Bool.self, forKey: .like)
    }

    /// 返回替换点赞状态后的新课程详情。
    func updatingLike(_ like: Bool, likeNum: Int) -> CourseDetail {
        CourseDetail(
            id: id,
            name: name,
            number: number,
            credit: credit,
            likeNum: likeNum,
            commentNum: commentNum,
            rate: rate,
            teachersName: teachersName,
            teachersNumber: teachersNumber,
            like: like
        )
    }
}

/// 单门课程的历史成绩统计。
///
/// 课程详情页按学期展示课程成绩统计。
nonisolated struct CourseHistoryGrade: Codable, Identifiable, Equatable, Sendable {
    let term: String
    let avgScore: Double?
    let maxScore: Double?
    let studentNum: Int?

    var id: String { term }

    private enum CodingKeys: String, CodingKey {
        case term
        case avgScore
        case maxScore
        case studentNum
    }

    init(term: String, avgScore: Double?, maxScore: Double?, studentNum: Int?) {
        self.term = term
        self.avgScore = avgScore
        self.maxScore = maxScore
        self.studentNum = studentNum
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        term = try container.decode(String.self, forKey: .term)
        avgScore = container.decodeFlexibleDoubleIfPresent(forKeys: [.avgScore])
        maxScore = container.decodeFlexibleDoubleIfPresent(forKeys: [.maxScore])
        studentNum = container.decodeFlexibleIntIfPresent(forKeys: [.studentNum])
    }
}

enum CourseHistoryMakeupPolicy {
    private static let requiredCoursePrefix = "10"
    private static let electiveCoursePrefix = "99"
    private static let maximumExcludedStudentCount = 5
    private static let minimumPairedYears = 2
    private static let strongCountRatio = 0.35
    private static let pairwiseOutlierRatio = 0.20
    private static let globalOutlierMultiplier = 10.0

    /// 识别 10 开头必修课中按学年重复出现的低人数补考学期。
    ///
    /// 学习人数不超过 5 的数据点始终清理。99 开头选修课保留其余数据；一个学年只有一个数据点时保留；同一学年有两个数据点时，
    /// 先按跨学年稳定的低人数学期位置清理，再清理人数相差十倍及以上的明确离群点。
    static func hiddenTerms(in grades: [CourseHistoryGrade], courseNumber: String) -> Set<String> {
        let lowCountTerms: Set<String> = Set(
            grades.compactMap { grade in
                guard let studentNum = grade.studentNum,
                      studentNum <= maximumExcludedStudentCount
                else {
                    return nil
                }
                return grade.term
            }
        )

        let normalizedNumber = courseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedNumber.hasPrefix(requiredCoursePrefix),
              !normalizedNumber.hasPrefix(electiveCoursePrefix)
        else {
            return lowCountTerms
        }

        let samples = grades
            .compactMap(ComparableGrade.init)
            .filter { sample in
                guard let studentNum = sample.grade.studentNum else { return true }
                return studentNum > maximumExcludedStudentCount
            }
        let groupedByAcademicYear = Dictionary(grouping: samples, by: \.academicYear)
        let pairedYears = groupedByAcademicYear.values.compactMap { yearSamples -> [ComparableGrade]? in
            guard yearSamples.count == 2 else { return nil }
            return yearSamples.sorted { $0.semester < $1.semester }
        }
        let pairComparisons = pairedYears.compactMap { pair -> PairComparison? in
            guard
                let firstCount = pair[0].grade.studentNum,
                let secondCount = pair[1].grade.studentNum,
                firstCount > 0,
                secondCount > 0
            else {
                return nil
            }

            let lowerIndex = firstCount <= secondCount ? 0 : 1
            let higherIndex = lowerIndex == 0 ? 1 : 0
            let lower = pair[lowerIndex]
            let higher = pair[higherIndex]
            let ratio = Double(lower.grade.studentNum ?? 0) / Double(higher.grade.studentNum ?? 1)
            return PairComparison(lower: lower, countRatio: ratio)
        }

        var firstPassHiddenTerms = Set<String>()
        let strongPairs = pairComparisons.filter { $0.countRatio <= strongCountRatio }
        if strongPairs.count >= minimumPairedYears,
           let dominantSemester = dominantLowerSemester(in: strongPairs),
           strongPairs.filter({ $0.lower.semester == dominantSemester }).count * 2 > strongPairs.count {
            firstPassHiddenTerms.formUnion(
                strongPairs
                    .filter { $0.lower.semester == dominantSemester }
                    .map { $0.lower.grade.term }
            )
        }

        // 主学期位置变化时，年内相对人数差异仍可作为第一遍清理依据。
        firstPassHiddenTerms.formUnion(
            pairComparisons
                .filter { $0.countRatio <= pairwiseOutlierRatio }
                .map { $0.lower.grade.term }
        )

        let remainingSamples = samples.filter { !firstPassHiddenTerms.contains($0.grade.term) }
        let secondPassHiddenTerms = globalOutlierTerms(in: remainingSamples)
        return lowCountTerms
            .union(firstPassHiddenTerms)
            .union(secondPassHiddenTerms)
    }

    /// 第二遍忽略学期位置，对第一遍剩余的全部数据点统一比较人数。
    /// 使用高位人数基线识别至少低十倍的离群点，避免某个学期固定为主学期的前提。
    private static func globalOutlierTerms(in samples: [ComparableGrade]) -> Set<String> {
        let counts = samples.compactMap(\.grade.studentNum).filter { $0 > 0 }.sorted()
        guard counts.count >= 2 else { return [] }

        let upperBaselineIndex = min(
            counts.count - 1,
            Int(ceil(Double(counts.count) * 0.75)) - 1
        )
        let upperBaseline = Double(counts[upperBaselineIndex])
        return Set(samples.compactMap { sample in
            guard
                let count = sample.grade.studentNum,
                Double(count) * globalOutlierMultiplier <= upperBaseline
            else {
                return nil
            }
            return sample.grade.term
        })
    }

    private static func dominantLowerSemester(in pairs: [PairComparison]) -> Int? {
        let counts = Dictionary(grouping: pairs, by: { $0.lower.semester })
            .mapValues(\.count)
        return counts.max { left, right in
            if left.value == right.value {
                return left.key > right.key
            }
            return left.value < right.value
        }?.key
    }

    private struct PairComparison {
        let lower: ComparableGrade
        let countRatio: Double
    }

    private struct ComparableGrade {
        let grade: CourseHistoryGrade
        let academicYear: String
        let semester: Int

        nonisolated init?(_ grade: CourseHistoryGrade) {
            let components = grade.term.split(separator: "-")
            guard
                components.count >= 3,
                let semesterComponent = components.last,
                let semester = Int(semesterComponent),
                semester > 0
            else {
                return nil
            }

            self.grade = grade
            self.academicYear = components.dropLast().joined(separator: "-")
            self.semester = semester
        }
    }
}

/// 历史成绩加载状态。
enum CourseHistoryGradeLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

private nonisolated extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKeys keys: [Key]) -> Double? {
        for key in keys {
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let parsed = Double(trimmed) {
                    return parsed
                }
            }
        }
        return nil
    }

    func decodeFlexibleIntIfPresent(forKeys keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let parsed = Int(trimmed) {
                    return parsed
                }
                if let parsed = Double(trimmed) {
                    return Int(parsed)
                }
            }
        }
        return nil
    }
}

/// 课程页整体加载状态。
///
/// 列表页只需要区分“首屏加载中 / 已有内容 / 首屏失败”这几类状态，
/// 细粒度的分页加载单独放在 `CoursePagedState` 里维护。
enum CourseLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 课程列表分页状态。
///
/// 这里把首屏状态和分页游标放在一起，避免视图层分别维护多组彼此耦合的布尔值。
struct CoursePagedState {
    var items: [CourseSummary] = []
    var status: CourseLoadStatus = .idle
    var nextPage = 0
    var isLoadingMore = false
    var canLoadMore = true
}

extension CoursePagedState: PagedItemsState {}

/// 课程详情加载状态。
///
/// 课程详情页与评论列表是两条并行的数据流，因此详情本体单独维护自己的加载状态。
enum CourseDetailLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}
