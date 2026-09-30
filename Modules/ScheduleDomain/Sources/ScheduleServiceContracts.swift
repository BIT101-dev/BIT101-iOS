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
/// 乐学同步除了事件列表外，还可能拿到新的订阅 URL，因此一起返回给上层缓存。
public struct DDLSyncPayload: Sendable {
    public let url: String
    public let events: [DDLEventRecord]

    public init(url: String, events: [DDLEventRecord]) {
        self.url = url
        self.events = events
    }
}

