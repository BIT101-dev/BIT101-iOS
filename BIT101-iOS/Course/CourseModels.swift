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
        guard raw > 0 else { return empty }
        return String(format: "%.1f/5", value(from: raw))
    }
}

/// 课程列表单项。
///
/// 当前底部课程页先承接课程浏览与详情能力，因此模型只保留列表展示所需字段。
struct CourseSummary: Decodable, Identifiable, Equatable, Hashable {
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
/// 日程页已经取得课程搜索结果时，会把命中的教师课程和同名课程首屏一起带过来；
/// 这样详情可以立即打开，返回列表时也无需再等待一次搜索请求。
struct CourseNavigationRequest: Identifiable {
    let id = UUID()
    let courseID: Int
    let preparedCourse: CourseSummary?
    let searchQuery: String?
    let searchResults: [CourseSummary]?

    init(
        courseID: Int,
        preparedCourse: CourseSummary? = nil,
        searchQuery: String? = nil,
        searchResults: [CourseSummary]? = nil
    ) {
        self.courseID = courseID
        self.preparedCourse = preparedCourse
        self.searchQuery = searchQuery
        self.searchResults = searchResults
    }
}

/// 课程详情。
///
/// 详情接口在课程基础信息外，还会返回当前用户的点赞状态。
struct CourseDetail: Decodable, Equatable {
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
/// Web 端称为“历史记录”，iOS 端在详情页展示为“历史成绩”。
struct CourseHistoryGrade: Decodable, Identifiable, Equatable {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        term = try container.decode(String.self, forKey: .term)
        avgScore = container.decodeFlexibleDoubleIfPresent(forKeys: [.avgScore])
        maxScore = container.decodeFlexibleDoubleIfPresent(forKeys: [.maxScore])
        studentNum = container.decodeFlexibleIntIfPresent(forKeys: [.studentNum])
    }
}

/// 历史成绩加载状态。
enum CourseHistoryGradeLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

private extension KeyedDecodingContainer {
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
