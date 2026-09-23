import Foundation

/// 日程模块本地缓存。
///
/// 这是 iOS 端整个日程模块的单一持久化快照：
/// - 课表
/// - 考试
/// - DDL
/// - 自定义日程
/// - 空教室偏好
/// - 课表显示设置
/// - 灵动岛提醒设置
nonisolated struct ScheduleCache: Codable {
    /// 课程周次已经按学校响应的行级周次完成解析。
    ///
    /// 缓存解码依据此版本判断是否需要行级周次转换。
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
    /// 这里保留学校最近一次成功返回的原始课表，手动调课存入规则层。
    var schoolCoursesByTerm: [String: [CourseRecord]] = [:]
    /// 手动调课规则，课表页面展示时叠加到学校原始课表。
    var manualCourseRulesByTerm: [String: [ScheduleCourseRule]] = [:]
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
        case schoolCoursesByTerm
        case manualCourseRulesByTerm
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
        schoolCoursesByTerm = try container.decodeIfPresent(
            [String: [CourseRecord]].self,
            forKey: .schoolCoursesByTerm
        ) ?? [:]
        manualCourseRulesByTerm = try container.decodeIfPresent(
            [String: [ScheduleCourseRule]].self,
            forKey: .manualCourseRulesByTerm
        ) ?? [:]
        termSchedulesByTerm = try container.decodeIfPresent(
            [String: TermScheduleSnapshot].self,
            forKey: .termSchedulesByTerm
        ) ?? [:]
        // 将根级课程数组合入当前学期缓存项。
        if !currentTerm.isEmpty, !courses.isEmpty, cachedCoursesByTerm[currentTerm]?.isEmpty ?? true {
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
        // coursesUpdatedAt 缺失时，使用现有缓存更新时间作为课程数据的时间基线。
        coursesUpdatedAt = decodedCoursesUpdatedAt ?? (courses.isEmpty ? .distantPast : updatedAt)
        if !currentTerm.isEmpty, !courses.isEmpty {
            if termSchedulesByTerm[currentTerm]?.courses.isEmpty ?? true {
                termSchedulesByTerm[currentTerm] = TermScheduleSnapshot(
                    term: currentTerm,
                    firstDayString: firstDayString,
                    courses: courses,
                    exams: termSchedulesByTerm[currentTerm]?.exams ?? exams,
                    updatedAt: termSchedulesByTerm[currentTerm]?.updatedAt ?? coursesUpdatedAt
                )
            }
        }

        let baselineTerms = Set(termSchedulesByTerm.keys)
            .union(cachedCoursesByTerm.keys)
            .union(currentTerm.isEmpty ? [] : [currentTerm])
        for term in baselineTerms where schoolCoursesByTerm[term] == nil {
            schoolCoursesByTerm[term] = termSchedulesByTerm[term]?.courses
                ?? cachedCoursesByTerm[term]
                ?? (term == currentTerm ? courses : [])
        }

        // 解析器版本低于当前版本时，按行级周次规范化 `-1` 小学期记录。
        // 规范化后的 offset 为 0，重复解码保持周次稳定；cachedCoursesByTerm 的课程也应用此规则。
        let migrationTerms = Set(termSchedulesByTerm.keys)
            .union(cachedCoursesByTerm.keys)
            .union(schoolCoursesByTerm.keys)
        for term in migrationTerms {
            let snapshot = termSchedulesByTerm[term]
            let sourceCourses: [CourseRecord]
            if let schoolCourses = schoolCoursesByTerm[term], !schoolCourses.isEmpty {
                sourceCourses = schoolCourses
            } else if let snapshot, !snapshot.courses.isEmpty {
                sourceCourses = snapshot.courses
            } else {
                sourceCourses = cachedCoursesByTerm[term] ?? snapshot?.courses ?? []
            }
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
            schoolCoursesByTerm[term] = narrowedCourses
            if currentTerm == term {
                firstDayString = normalized.firstDayString
                courses = narrowedCourses
            }
        }

        if let baseline = schoolCoursesByTerm[currentTerm] {
            let reconciliation = ScheduleCourseEditor.reconcile(
                rules: manualCourseRulesByTerm[currentTerm] ?? [],
                with: baseline
            )
            courses = reconciliation.courses
            cachedCoursesByTerm[currentTerm] = reconciliation.courses
            manualCourseRulesByTerm[currentTerm] = reconciliation.validRules
        }
    }

    /// 把课表标题裁到统一长度上限。调用方先提供默认标题，再传入需要裁切的文本。
    private static func clampedScheduleTitle(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(scheduleNameCharacterLimit))
    }

    /// 解析 `yyyy-MM-dd` 首周日期，供缓存和学期快照共用。
    fileprivate static func parseScheduleFirstDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-")
        guard
            parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2]),
            (1 ... 12).contains(month),
            (1 ... 31).contains(day)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
        return date
    }
}

/// 一条手动调课规则。
///
/// `sourceCourses` 保存规则创建时的学校原始课程；`replacementCourses` 保存显示层结果。
/// 刷新时先比较来源快照，再决定规则继续生效或移除。
nonisolated struct ScheduleCourseRule: Codable, Identifiable, Hashable {
    let id: String
    let sourceIdentity: String
    let sourceCourses: [CourseRecord]
    let replacementCourses: [CourseRecord]

    init(
        id: String = UUID().uuidString,
        sourceIdentity: String,
        sourceCourses: [CourseRecord],
        replacementCourses: [CourseRecord]
    ) {
        self.id = id
        self.sourceIdentity = sourceIdentity
        self.sourceCourses = sourceCourses
        self.replacementCourses = replacementCourses
    }

    var isLocalAddition: Bool {
        sourceCourses.isEmpty
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
    let sharedAt: Date?
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
        self.sharedAt = payload.exportedAt
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
