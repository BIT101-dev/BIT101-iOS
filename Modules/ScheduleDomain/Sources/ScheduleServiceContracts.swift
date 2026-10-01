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
    public let courses: [CourseRecord]
    public let exams: [ExamRecord]

    public init(
        term: String,
        firstDayString: String,
        sourceFirstDayString: String,
        normalizationOffset: Int,
        rawWeeksByCourse: [[Int]],
        courses: [CourseRecord],
        exams: [ExamRecord]
    ) {
        self.term = term
        self.firstDayString = firstDayString
        self.sourceFirstDayString = sourceFirstDayString
        self.normalizationOffset = normalizationOffset
        self.rawWeeksByCourse = rawWeeksByCourse
        self.courses = courses
        self.exams = exams
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
