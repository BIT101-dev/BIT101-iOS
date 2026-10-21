import Foundation

/// 同步课程表和考试后的组合结果。
///
/// 课程、考试和首周日期来自不同接口；“同步课表”按一个业务动作一起更新，返回体集中承载三类数据。
public nonisolated struct CourseSyncPayload: Sendable {
    public let term: String
    public let firstDayString: String
    public let sourceFirstDayString: String
    public let normalizationOffset: Int
    public let rawWeeksByCourse: [[Int]]
    public let sourceDisplayWeeksByCourse: [String?]
    public let courses: [CourseRecord]
    /// nil 表示本次考试来源读取受阻，消费方继续保留该学期已有考试。
    public let exams: [ExamRecord]?
    public let warnings: [String]

    public init(
        term: String,
        firstDayString: String,
        sourceFirstDayString: String,
        normalizationOffset: Int,
        rawWeeksByCourse: [[Int]],
        sourceDisplayWeeksByCourse: [String?] = [],
        courses: [CourseRecord],
        exams: [ExamRecord]?,
        warnings: [String] = []
    ) {
        self.term = term
        self.firstDayString = firstDayString
        self.sourceFirstDayString = sourceFirstDayString
        self.normalizationOffset = normalizationOffset
        self.rawWeeksByCourse = rawWeeksByCourse
        self.sourceDisplayWeeksByCourse = sourceDisplayWeeksByCourse
        self.courses = courses
        self.exams = exams
        self.warnings = warnings
    }
}

/// 同步 DDL 后的组合结果。
///
/// 携带事件、乐学订阅地址、已更新来源和部分失败信息。
public struct DDLSyncPayload: Sendable {
    public let url: String
    public let events: [DDLEventRecord]
    public let syncedGroups: Set<String>
    public let warnings: [String]

    public init(url: String, events: [DDLEventRecord], syncedGroups: Set<String> = ["lexue"], warnings: [String] = []) {
        self.url = url
        self.events = events
        self.syncedGroups = syncedGroups
        self.warnings = warnings
    }
}
