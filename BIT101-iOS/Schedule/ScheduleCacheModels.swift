import Foundation

nonisolated struct ScheduleCache: Codable {
    /// 课程周次已经按学校响应的行级周次完成解析。
    ///
    /// 缓存解码会依据这个版本决定是否运行旧版迁移逻辑，保持行级周次结构。
    private static let courseScheduleParserVersion = 2

    var primaryScheduleTitle = "课表"
    var storedCourseScheduleParserVersion = Self.courseScheduleParserVersion
    var currentTerm: String = ""
    var firstDayString: String = ""
    /// 最近一次从学校成功同步课表与考试的时间，用于缓存迁移和快照时间戳。
    var coursesUpdatedAt: Date = .distantPast
    var lexueCalendarURL: String = ""
    var courses: [CourseRecord] = []
    /// 已成功同步过的各学期课表快照，供成绩页本地判断尚未出分的课程。
    var cachedCoursesByTerm: [String: [CourseRecord]] = [:]
    /// 当前学期和下一学期的完整转换快照，滚动本地缓存保留相邻两个学期。
    var termSchedulesByTerm: [String: TermScheduleSnapshot] = [:]
    var exams: [ExamRecord] = []
    var customSchedules: [CustomScheduleRecord] = []
    var ddlEvents: [DDLEventRecord] = []
    /// 最近一次成功同步乐学 DDL 的时间；为空表示尚未成功同步。
    var ddlUpdatedAt: Date?
    var ddlBeforeDay = 7
    var ddlAfterDay = 3
    var selectedCampusName: String = ""
    var selectedCampusCode: String = ""
    var selectedBuildingID: String = ""
    var cachedClassroomCampuses: [CampusRecord] = []
    var cachedClassroomBuildingsByCampusCode: [String: [BuildingRecord]] = [:]
    var selectedClassroomSectionIDs: [Int] = []
    var isClassroomSectionFilterCustomized = false
    var showSaturday = true
    var showSunday = true
    var showBorder = true
    var showHighlightToday = true
    var showDivider = true
    var showCurrentTime = true
    var showExamInfo = true
    var scheduleDisplayMode: ScheduleDisplayMode = .weekly
    var scheduleCardContentMode: ScheduleCardContentMode = .nameAndLocation
    var showCourseLiveActivityReminder = false
    var courseLiveActivityLeadMinutes = 20
    var timeTable: [TimeSlot] = TimeSlot.default
    var sharedSchedules: [SharedScheduleRecord] = []
    var iCloudSyncEnabled = true
    var updatedAt: Date = .distantPast

    /// 首周日期的解码结果，便于课表直接计算当前周数。
    var firstDay: Date? {
        Self.parseScheduleFirstDay(firstDayString)
    }

    private enum CodingKeys: String, CodingKey {
        case primaryScheduleTitle
        case storedCourseScheduleParserVersion
        case currentTerm
        case firstDayString
        case coursesUpdatedAt
        case lexueCalendarURL
        case courses
        case cachedCoursesByTerm
        case termSchedulesByTerm
        case exams
        case customSchedules
        case ddlEvents
        case ddlUpdatedAt
        case ddlBeforeDay
        case ddlAfterDay
        case selectedCampusName
        case selectedCampusCode
        case selectedBuildingID
        case cachedClassroomCampuses
        case cachedClassroomBuildingsByCampusCode
        case selectedClassroomSectionIDs
        case isClassroomSectionFilterCustomized
        case showSaturday
        case showSunday
        case showBorder
        case showHighlightToday
        case showDivider
        case showCurrentTime
        case showExamInfo
        case scheduleDisplayMode
        case scheduleCardContentMode = "scheduleCardContentModeV2"
        case showCourseLiveActivityReminder
        case courseLiveActivityLeadMinutes
        case timeTable
        case sharedSchedules
        case iCloudSyncEnabled
        case updatedAt
    }

    /// 提供一份带默认值的空缓存。
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        currentTerm = try container.decodeIfPresent(String.self, forKey: .currentTerm) ?? ""
        let decodedCourseScheduleParserVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .storedCourseScheduleParserVersion
        ) ?? 1
        primaryScheduleTitle = Self.clampedScheduleTitle(
            try container.decodeIfPresent(String.self, forKey: .primaryScheduleTitle) ?? "课表"
        )
        firstDayString = try container.decodeIfPresent(String.self, forKey: .firstDayString) ?? ""
        let decodedCoursesUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .coursesUpdatedAt)
        lexueCalendarURL = try container.decodeIfPresent(String.self, forKey: .lexueCalendarURL) ?? ""
        courses = try container.decodeIfPresent([CourseRecord].self, forKey: .courses) ?? []
        cachedCoursesByTerm = try container.decodeIfPresent(
            [String: [CourseRecord]].self,
            forKey: .cachedCoursesByTerm
        ) ?? [:]
        termSchedulesByTerm = try container.decodeIfPresent(
            [String: TermScheduleSnapshot].self,
            forKey: .termSchedulesByTerm
        ) ?? [:]
        // 将旧版单学期缓存迁移到按学期保存，保留用户已经保存的课表。
        if cachedCoursesByTerm.isEmpty, !currentTerm.isEmpty, !courses.isEmpty {
            cachedCoursesByTerm[currentTerm] = courses
        }
        exams = try container.decodeIfPresent([ExamRecord].self, forKey: .exams) ?? []
        customSchedules = try container.decodeIfPresent([CustomScheduleRecord].self, forKey: .customSchedules) ?? []
        ddlEvents = try container.decodeIfPresent([DDLEventRecord].self, forKey: .ddlEvents) ?? []
        ddlUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .ddlUpdatedAt)
        ddlBeforeDay = try container.decodeIfPresent(Int.self, forKey: .ddlBeforeDay) ?? 7
        ddlAfterDay = try container.decodeIfPresent(Int.self, forKey: .ddlAfterDay) ?? 3
        selectedCampusName = try container.decodeIfPresent(String.self, forKey: .selectedCampusName) ?? ""
        selectedCampusCode = try container.decodeIfPresent(String.self, forKey: .selectedCampusCode) ?? ""
        selectedBuildingID = try container.decodeIfPresent(String.self, forKey: .selectedBuildingID) ?? ""
        cachedClassroomCampuses = try container.decodeIfPresent([CampusRecord].self, forKey: .cachedClassroomCampuses) ?? []
        cachedClassroomBuildingsByCampusCode = try container.decodeIfPresent(
            [String: [BuildingRecord]].self,
            forKey: .cachedClassroomBuildingsByCampusCode
        ) ?? [:]
        selectedClassroomSectionIDs = try container.decodeIfPresent([Int].self, forKey: .selectedClassroomSectionIDs) ?? []
        isClassroomSectionFilterCustomized = try container.decodeIfPresent(
            Bool.self,
            forKey: .isClassroomSectionFilterCustomized
        ) ?? !selectedClassroomSectionIDs.isEmpty
        showSaturday = try container.decodeIfPresent(Bool.self, forKey: .showSaturday) ?? true
        showSunday = try container.decodeIfPresent(Bool.self, forKey: .showSunday) ?? true
        showBorder = try container.decodeIfPresent(Bool.self, forKey: .showBorder) ?? true
        showHighlightToday = try container.decodeIfPresent(Bool.self, forKey: .showHighlightToday) ?? true
        showDivider = try container.decodeIfPresent(Bool.self, forKey: .showDivider) ?? true
        showCurrentTime = try container.decodeIfPresent(Bool.self, forKey: .showCurrentTime) ?? true
        showExamInfo = try container.decodeIfPresent(Bool.self, forKey: .showExamInfo) ?? true
        scheduleDisplayMode = try container.decodeIfPresent(ScheduleDisplayMode.self, forKey: .scheduleDisplayMode) ?? .weekly
        // V2 使用独立存储键，早期开发版的两态实验值按默认值处理，默认显示名称+地点。
        scheduleCardContentMode = try container.decodeIfPresent(ScheduleCardContentMode.self, forKey: .scheduleCardContentMode) ?? .nameAndLocation
        showCourseLiveActivityReminder = try container.decodeIfPresent(Bool.self, forKey: .showCourseLiveActivityReminder) ?? false
        courseLiveActivityLeadMinutes = min(
            max(try container.decodeIfPresent(Int.self, forKey: .courseLiveActivityLeadMinutes) ?? 20, 1),
            60
        )
        timeTable = try container.decodeIfPresent([TimeSlot].self, forKey: .timeTable) ?? TimeSlot.default
        sharedSchedules = (try container.decodeIfPresent([SharedScheduleRecord].self, forKey: .sharedSchedules) ?? []).map {
            var schedule = $0
            schedule.title = Self.clampedScheduleTitle(schedule.title)
            return schedule
        }
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? true
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        // 老版本只保存原缓存更新时间；迁移时以该时间作为保守基线，
        // 保留已有缓存的时间语义。
        coursesUpdatedAt = decodedCoursesUpdatedAt ?? (courses.isEmpty ? .distantPast : updatedAt)
        if termSchedulesByTerm.isEmpty, !currentTerm.isEmpty, !courses.isEmpty {
            termSchedulesByTerm[currentTerm] = TermScheduleSnapshot(
                term: currentTerm,
                firstDayString: firstDayString,
                courses: courses,
                exams: exams,
                updatedAt: coursesUpdatedAt
            )
        }

        // 旧版已保存的 `-1` 小学期课表在解码时确定性迁移。校正后的数据再次
        // 解码会得到 offset=0，后续解码保持周次不变；该迁移规则适用于 `-1` 小学期。
        // `cachedCoursesByTerm` 只保存课程，可能包含旧的原始周次；迁移仅校正课程周次
        // 和行级安排，日期保持为空。
        let migrationTerms = Set(termSchedulesByTerm.keys).union(cachedCoursesByTerm.keys)
        for term in migrationTerms {
            let snapshot = termSchedulesByTerm[term]
            let sourceCourses = snapshot?.courses ?? cachedCoursesByTerm[term] ?? []
            guard !sourceCourses.isEmpty else { continue }
            let normalized = SmallTermWeekNormalizer.normalize(
                term: term,
                firstDayString: snapshot?.firstDayString
                    ?? (term == currentTerm ? firstDayString : ""),
                courses: sourceCourses
            )
            let narrowedCourses: [CourseRecord]
            if decodedCourseScheduleParserVersion < Self.courseScheduleParserVersion {
                narrowedCourses = CourseScheduleRowParser.narrowedCourses(normalized.courses)
            } else {
                narrowedCourses = normalized.courses
            }
            guard normalized.offset == SmallTermWeekNormalizer.correctionOffset
                || narrowedCourses != sourceCourses
            else { continue }
            if let snapshot {
                termSchedulesByTerm[term] = TermScheduleSnapshot(
                    term: term,
                    firstDayString: normalized.firstDayString,
                    courses: narrowedCourses,
                    exams: snapshot.exams,
                    updatedAt: snapshot.updatedAt
                )
            }
            cachedCoursesByTerm[term] = narrowedCourses
            if currentTerm == term {
                firstDayString = normalized.firstDayString
                courses = narrowedCourses
            }
        }
    }

    /// 把课表标题裁到统一长度上限。调用方先提供默认标题，再传入需要裁切的文本。
    private static func clampedScheduleTitle(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(scheduleNameCharacterLimit))
    }

    /// 解析 `yyyy-MM-dd` 首周日期，供缓存和学期快照共用。
    fileprivate static func parseScheduleFirstDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }
}

/// 一个学期的完整课表快照。滚动本地缓存保留相邻的两个学期。
nonisolated struct TermScheduleSnapshot: Codable {
    let term: String
    let firstDayString: String
    let courses: [CourseRecord]
    let exams: [ExamRecord]
    let updatedAt: Date

    var firstDay: Date? {
        ScheduleCache.parseScheduleFirstDay(firstDayString)
    }

    var hasDisplayableData: Bool {
        !courses.isEmpty || !exams.isEmpty
    }
}

/// 导入到本地后的分享课表记录。
///
/// 这类课表用于查看与切换；提醒、DDL、空教室偏好继续使用当前账号的私有课表逻辑。
struct SharedScheduleRecord: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    let importedAt: Date
    let currentTerm: String
    let firstDayString: String
    let timeTable: [TimeSlot]
    let courses: [CourseRecord]

    init(
        id: String = UUID().uuidString,
        title: String,
        importedAt: Date = Date(),
        payload: ScheduleExportPayload
    ) {
        self.id = id
        self.title = title
        self.importedAt = importedAt
        self.currentTerm = payload.currentTerm
        self.firstDayString = payload.firstDayString
        self.timeTable = payload.timeTable
        self.courses = payload.courses
    }

    var isEmpty: Bool {
        courses.isEmpty
    }
}

/// 课程表和 DDL 共用的日期编解码工具。
///
/// 日程模块内部有多种日期展示形式，各页面共用这些格式器。
