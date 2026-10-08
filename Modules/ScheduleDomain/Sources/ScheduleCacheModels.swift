import Foundation
import ScheduleContracts

public nonisolated enum ScheduleCacheLoadResult: Sendable {
    case loaded(ScheduleCache)
    case missing
    case unreadable

    public var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }

    public var allowsWrite: Bool { !isUnreadable }

    public var cacheIfReadable: ScheduleCache? {
        switch self {
        case .loaded(let cache): return cache
        case .missing: return ScheduleCache()
        case .unreadable: return nil
        }
    }
}

public nonisolated enum ScheduleCacheSaveSource: Sendable {
    case local
    case localWithoutCloudPush
    case cloud
    /// 记录已确认的云端基线，同时保留后续本地编辑的待上传状态。
    case cloudBaseline
}


/// 账号日程的版本化磁盘快照，各业务区域独立拥有其状态。
public nonisolated struct ScheduleCache: Codable, Sendable {
    public static let schemaVersion = 1
    public var courseData = ScheduleCourseData()
    public var ddlData = ScheduleDDLData()
    public var classroomData = ScheduleClassroomData()
    public var presentation = SchedulePresentationPreferences()
    public var syncData = ScheduleSyncData()
    public var updatedAt: Date = .distantPast
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, courseData, ddlData, classroomData, presentation, syncData, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.schemaVersion) else {
            guard ![CodingKeys.courseData, .ddlData, .classroomData, .presentation, .syncData].contains(where: container.contains) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Structured schedule cache requires its schema version."))
            }
            self = try LegacyScheduleCache(from: decoder).migrated()
            try validateTimeTable(codingPath: decoder.codingPath)
            return
        }
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "Schedule cache requires schema version \(Self.schemaVersion); received \(version)."
            )
        }
        courseData = try container.decode(ScheduleCourseData.self, forKey: .courseData)
        ddlData = try container.decode(ScheduleDDLData.self, forKey: .ddlData)
        classroomData = try container.decode(ScheduleClassroomData.self, forKey: .classroomData)
        presentation = try container.decode(SchedulePresentationPreferences.self, forKey: .presentation)
        syncData = try container.decode(ScheduleSyncData.self, forKey: .syncData)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        courseData.reconcileRules()
        try validateTimeTable(codingPath: decoder.codingPath)
    }

    private func validateTimeTable(codingPath: [any CodingKey]) throws {
        guard TimeSlot.hasUniqueIDs(timeTable) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Time table requires unique section IDs."))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(courseData, forKey: .courseData)
        try container.encode(ddlData, forKey: .ddlData)
        try container.encode(classroomData, forKey: .classroomData)
        try container.encode(presentation, forKey: .presentation)
        try container.encode(syncData, forKey: .syncData)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public var firstDayString: String { courseData.firstDayString }
    public var firstDay: Date? { courseData.firstDay }
    public var coursesUpdatedAt: Date { courseData.coursesUpdatedAt }
    public var courses: [CourseRecord] { courseData.courses }
    public var exams: [ExamRecord] { courseData.exams }
    public var cachedCoursesByTerm: [String: [CourseRecord]] { courseData.cachedCoursesByTerm }
    public var termSchedulesByTerm: [String: TermScheduleSnapshot] { courseData.termSchedulesByTerm }
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

        let calendar = ScheduleSharedDateCodec.calendar

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
    public var primaryScheduleTitle: String {
        get { courseData.primaryScheduleTitle }
        set { courseData.primaryScheduleTitle = newValue }
    }
    public var currentTerm: String {
        get { courseData.currentTerm }
        set { courseData.currentTerm = newValue }
    }
    public var manualFirstDayStringsByTerm: [String: String] {
        get { courseData.manualFirstDayStringsByTerm }
        set { courseData.manualFirstDayStringsByTerm = newValue }
    }
    public var manualCourseRulesByTerm: [String: [ScheduleCourseRule]] {
        get { courseData.manualCourseRulesByTerm }
        set { courseData.manualCourseRulesByTerm = newValue }
    }
    public var customSchedules: [CustomScheduleRecord] {
        get { courseData.customSchedules }
        set { courseData.customSchedules = newValue }
    }
    public var timeTable: [TimeSlot] {
        get { courseData.timeTable }
        set { courseData.timeTable = newValue }
    }
    public var sharedSchedules: [SharedScheduleRecord] {
        get { courseData.sharedSchedules }
        set { courseData.sharedSchedules = newValue }
    }
    public var lexueCalendarURL: String {
        get { ddlData.lexueCalendarURL }
        set { ddlData.lexueCalendarURL = newValue }
    }
    public var ddlEvents: [DDLEventRecord] {
        get { ddlData.ddlEvents }
        set { ddlData.ddlEvents = newValue }
    }
    public var lexueDDLCompletionByID: [String: Bool] {
        get { ddlData.lexueDDLCompletionByID }
        set { ddlData.lexueDDLCompletionByID = newValue }
    }
    public var ddlUpdatedAt: Date? {
        get { ddlData.ddlUpdatedAt }
        set { ddlData.ddlUpdatedAt = newValue }
    }
    public var ddlBeforeDay: Int {
        get { ddlData.ddlBeforeDay }
        set { ddlData.ddlBeforeDay = newValue }
    }
    public var ddlAfterDay: Int {
        get { ddlData.ddlAfterDay }
        set { ddlData.ddlAfterDay = newValue }
    }
    public var selectedCampusName: String {
        get { classroomData.selectedCampusName }
        set { classroomData.selectedCampusName = newValue }
    }
    public var selectedCampusCode: String {
        get { classroomData.selectedCampusCode }
        set { classroomData.selectedCampusCode = newValue }
    }
    public var selectedBuildingID: String {
        get { classroomData.selectedBuildingID }
        set { classroomData.selectedBuildingID = newValue }
    }
    public var cachedClassroomCampuses: [CampusRecord] {
        get { classroomData.cachedClassroomCampuses }
        set { classroomData.cachedClassroomCampuses = newValue }
    }
    public var cachedClassroomBuildingsByCampusCode: [String: [BuildingRecord]] {
        get { classroomData.cachedClassroomBuildingsByCampusCode }
        set { classroomData.cachedClassroomBuildingsByCampusCode = newValue }
    }
    public var selectedClassroomSectionIDs: [Int] {
        get { classroomData.selectedClassroomSectionIDs }
        set { classroomData.selectedClassroomSectionIDs = newValue }
    }
    public var isClassroomSectionFilterCustomized: Bool {
        get { classroomData.isClassroomSectionFilterCustomized }
        set { classroomData.isClassroomSectionFilterCustomized = newValue }
    }
    public var showSaturday: Bool {
        get { presentation.showSaturday }
        set { presentation.showSaturday = newValue }
    }
    public var showSunday: Bool {
        get { presentation.showSunday }
        set { presentation.showSunday = newValue }
    }
    public var showExamInfo: Bool {
        get { presentation.showExamInfo }
        set { presentation.showExamInfo = newValue }
    }
    public var scheduleDisplayMode: ScheduleDisplayMode {
        get { presentation.scheduleDisplayMode }
        set { presentation.scheduleDisplayMode = newValue }
    }
    public var scheduleCardContentMode: ScheduleCardContentMode {
        get { presentation.scheduleCardContentMode }
        set { presentation.scheduleCardContentMode = newValue }
    }
    public var showCourseLiveActivityReminder: Bool {
        get { presentation.showCourseLiveActivityReminder }
        set { presentation.showCourseLiveActivityReminder = newValue }
    }
    public var courseLiveActivityLeadMinutes: Int {
        get { presentation.courseLiveActivityLeadMinutes }
        set { presentation.courseLiveActivityLeadMinutes = newValue }
    }
    public var iCloudSyncEnabled: Bool {
        get { syncData.iCloudSyncEnabled }
        set { syncData.iCloudSyncEnabled = newValue }
    }
    public var cloudSyncBaselineAt: Date {
        get { syncData.cloudSyncBaselineAt }
        set { syncData.cloudSyncBaselineAt = newValue }
    }
    public var cloudSyncBaselineRecordTag: String {
        get { syncData.cloudSyncBaselineRecordTag }
        set { syncData.cloudSyncBaselineRecordTag = newValue }
    }
    public var hasUnpushedCloudChanges: Bool {
        get { syncData.hasUnpushedCloudChanges }
        set { syncData.hasUnpushedCloudChanges = newValue }
    }
}

public nonisolated struct ScheduleCourseData: Codable, Equatable, Sendable {
    public var primaryScheduleTitle: String = "课表"
    public var currentTerm: String = ""
    public var manualFirstDayStringsByTerm: [String: String] = [:]
    public var manualCourseRulesByTerm: [String: [ScheduleCourseRule]] = [:]
    public var customSchedules: [CustomScheduleRecord] = []
    public var timeTable: [TimeSlot] = TimeSlot.default
    public var sharedSchedules: [SharedScheduleRecord] = []
    /// 每学期学校数据的唯一来源；历史课程继续供成绩页匹配。
    public var schedulesByTerm: [String: TermScheduleSnapshot] = [:]
    /// 完整日程按相邻两个学期滚动保留，归档学期保留原始课程。
    public var archivedTerms: Set<String> = []

    public var termSchedulesByTerm: [String: TermScheduleSnapshot] {
        schedulesByTerm.filter { !archivedTerms.contains($0.key) }
    }
    public var cachedCoursesByTerm: [String: [CourseRecord]] { schedulesByTerm.mapValues(\.courses) }
    public func schoolCourses(for term: String) -> [CourseRecord] { schedulesByTerm[term]?.courses ?? [] }
    private var selectedSchedule: TermScheduleSnapshot? {
        archivedTerms.contains(currentTerm) ? nil : schedulesByTerm[currentTerm]
    }
    public var firstDayString: String {
        manualFirstDayStringsByTerm[currentTerm] ?? selectedSchedule?.firstDayString ?? ""
    }
    public var firstDay: Date? { ScheduleCache.parseScheduleFirstDay(firstDayString) }
    public var coursesUpdatedAt: Date { selectedSchedule?.updatedAt ?? .distantPast }
    public var exams: [ExamRecord] { selectedSchedule?.exams ?? [] }
    public var courses: [CourseRecord] {
        ScheduleCourseEditor.reconcile(
            rules: manualCourseRulesByTerm[currentTerm] ?? [],
            with: selectedSchedule?.courses ?? []
        ).courses
    }

    public mutating func store(_ snapshot: TermScheduleSnapshot) {
        schedulesByTerm[snapshot.term] = snapshot
        archivedTerms.remove(snapshot.term)
        let result = ScheduleCourseEditor.reconcile(
            rules: manualCourseRulesByTerm[snapshot.term] ?? [], with: snapshot.courses
        )
        setRules(result.validRules, for: snapshot.term)
    }

    public mutating func archive(term: String) {
        guard let snapshot = schedulesByTerm[term] else { return }
        schedulesByTerm[term] = TermScheduleSnapshot(
            term: term, firstDayString: "", courses: snapshot.courses,
            exams: [], updatedAt: snapshot.updatedAt
        )
        archivedTerms.insert(term)
        manualCourseRulesByTerm.removeValue(forKey: term)
    }

    public mutating func setRules(_ rules: [ScheduleCourseRule], for term: String) {
        manualCourseRulesByTerm[term] = rules.isEmpty ? nil : rules
    }

    fileprivate mutating func reconcileRules() {
        for (term, rules) in manualCourseRulesByTerm {
            guard let snapshot = schedulesByTerm[term] else { continue }
            setRules(ScheduleCourseEditor.reconcile(rules: rules, with: snapshot.courses).validRules, for: term)
        }
    }
    public init() {}
}

public nonisolated struct ScheduleDDLData: Codable, Equatable, Sendable {
    public var lexueCalendarURL: String = ""
    public var ddlEvents: [DDLEventRecord] = []
    public var lexueDDLCompletionByID: [String: Bool] = [:]
    public var ddlUpdatedAt: Date? = nil
    public var ddlBeforeDay: Int = 7
    public var ddlAfterDay: Int = 3
    public init() {}
}

public nonisolated struct ScheduleClassroomData: Codable, Equatable, Sendable {
    public var selectedCampusName: String = ""
    public var selectedCampusCode: String = ""
    public var selectedBuildingID: String = ""
    public var cachedClassroomCampuses: [CampusRecord] = []
    public var cachedClassroomBuildingsByCampusCode: [String: [BuildingRecord]] = [:]
    public var selectedClassroomSectionIDs: [Int] = []
    public var isClassroomSectionFilterCustomized: Bool = false
    public init() {}
}

public nonisolated struct SchedulePresentationPreferences: Codable, Equatable, Sendable {
    public var showSaturday: Bool = true
    public var showSunday: Bool = true
    public var showExamInfo: Bool = true
    public var scheduleDisplayMode: ScheduleDisplayMode = .weekly
    public var scheduleCardContentMode: ScheduleCardContentMode = .nameAndLocation
    public var showCourseLiveActivityReminder: Bool = false
    public var courseLiveActivityLeadMinutes: Int = 20 {
        didSet { courseLiveActivityLeadMinutes = Self.normalizedLeadMinutes(courseLiveActivityLeadMinutes) }
    }
    public init() {}

    public static func normalizedLeadMinutes(_ value: Int) -> Int {
        min(max(value, 1), 60)
    }

    private enum CodingKeys: String, CodingKey {
        case showSaturday, showSunday, showExamInfo, scheduleDisplayMode, scheduleCardContentMode
        case showCourseLiveActivityReminder, courseLiveActivityLeadMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showSaturday = try container.decode(Bool.self, forKey: .showSaturday)
        showSunday = try container.decode(Bool.self, forKey: .showSunday)
        showExamInfo = try container.decode(Bool.self, forKey: .showExamInfo)
        scheduleDisplayMode = try container.decode(ScheduleDisplayMode.self, forKey: .scheduleDisplayMode)
        scheduleCardContentMode = try container.decode(ScheduleCardContentMode.self, forKey: .scheduleCardContentMode)
        showCourseLiveActivityReminder = try container.decode(Bool.self, forKey: .showCourseLiveActivityReminder)
        courseLiveActivityLeadMinutes = Self.normalizedLeadMinutes(
            try container.decode(Int.self, forKey: .courseLiveActivityLeadMinutes)
        )
    }
}

public nonisolated struct ScheduleSyncData: Codable, Equatable, Sendable {
    public var iCloudSyncEnabled: Bool = true
    public var cloudSyncBaselineAt: Date = .distantPast
    public var cloudSyncBaselineRecordTag: String = ""
    public var cloudSyncBaselineUserState: Data?
    public var hasUnpushedCloudChanges: Bool = false
    public init() {}
}

/// 历史磁盘格式的集中解码与迁移。
private nonisolated struct LegacyScheduleCache: Decodable, Sendable {
    /// 课程周次已经按学校响应的行级周次完成解析。
    ///
    /// 缓存解码依据此版本判断是否需要行级周次转换。
    private static let courseScheduleParserVersion = 2

    var primaryScheduleTitle = "课表"
    var storedCourseScheduleParserVersion = Self.courseScheduleParserVersion
    var currentTerm: String = ""
    var firstDayString: String = ""
    /// 当前账号在本机为各学期选择的首周日期；学期快照保留学校同步日期。
    var manualFirstDayStringsByTerm: [String: String] = [:]
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
    /// 学校 DDL 的完成状态按事件 ID 保存，供账号同步与刷新复用。
    var lexueDDLCompletionByID: [String: Bool] = [:]
    /// 最近一次成功同步学校 DDL 的时间。
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
    var showExamInfo = true
    var scheduleDisplayMode: ScheduleDisplayMode = .weekly
    var scheduleCardContentMode: ScheduleCardContentMode = .nameAndLocation
    var showCourseLiveActivityReminder = false
    var courseLiveActivityLeadMinutes = 20
    var timeTable: [TimeSlot] = TimeSlot.default
    var sharedSchedules: [SharedScheduleRecord] = []
    var iCloudSyncEnabled = true
    var updatedAt: Date = .distantPast
    var cloudSyncBaselineAt: Date = .distantPast
    var cloudSyncBaselineRecordTag = ""
    var hasUnpushedCloudChanges = false

    /// 首周日期的解码结果，便于课表直接计算当前周数。
    var firstDay: Date? {
        ScheduleCache.parseScheduleFirstDay(firstDayString)
    }

    private enum CodingKeys: String, CodingKey {
        case primaryScheduleTitle
        case storedCourseScheduleParserVersion
        case currentTerm
        case firstDayString
        case manualFirstDayStringsByTerm
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
        case lexueDDLCompletionByID
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
        case showExamInfo
        case scheduleDisplayMode
        case scheduleCardContentMode = "scheduleCardContentModeV2"
        case showCourseLiveActivityReminder
        case courseLiveActivityLeadMinutes
        case timeTable
        case sharedSchedules
        case iCloudSyncEnabled
        case updatedAt
        case cloudSyncBaselineAt
        case cloudSyncBaselineRecordTag
        case hasUnpushedCloudChanges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !container.allKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Legacy schedule cache requires a recognized schedule field."))
        }

        currentTerm = try container.decodeIfPresent(String.self, forKey: .currentTerm) ?? ""
        let decodedCourseScheduleParserVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .storedCourseScheduleParserVersion
        ) ?? 1
        primaryScheduleTitle = Self.clampedScheduleTitle(
            try container.decodeIfPresent(String.self, forKey: .primaryScheduleTitle) ?? "课表"
        )
        firstDayString = try container.decodeIfPresent(String.self, forKey: .firstDayString) ?? ""
        manualFirstDayStringsByTerm = try container.decodeIfPresent(
            [String: String].self,
            forKey: .manualFirstDayStringsByTerm
        ) ?? [:]
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
            cachedCoursesByTerm[currentTerm] = schoolCoursesByTerm[currentTerm] ?? courses
        }
        exams = try container.decodeIfPresent([ExamRecord].self, forKey: .exams) ?? []
        customSchedules = try container.decodeIfPresent([CustomScheduleRecord].self, forKey: .customSchedules) ?? []
        ddlEvents = try container.decodeIfPresent([DDLEventRecord].self, forKey: .ddlEvents) ?? []
        lexueDDLCompletionByID = try container.decodeIfPresent(
            [String: Bool].self,
            forKey: .lexueDDLCompletionByID
        ) ?? [:]
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
        showExamInfo = try container.decodeIfPresent(Bool.self, forKey: .showExamInfo) ?? true
        scheduleDisplayMode = try container.decodeIfPresent(ScheduleDisplayMode.self, forKey: .scheduleDisplayMode) ?? .weekly
        // V2 使用独立存储键，早期开发版的两态实验值按默认值处理，默认显示名称+地点。
        scheduleCardContentMode = try container.decodeIfPresent(ScheduleCardContentMode.self, forKey: .scheduleCardContentMode) ?? .nameAndLocation
        showCourseLiveActivityReminder = try container.decodeIfPresent(Bool.self, forKey: .showCourseLiveActivityReminder) ?? false
        courseLiveActivityLeadMinutes = SchedulePresentationPreferences.normalizedLeadMinutes(
            try container.decodeIfPresent(Int.self, forKey: .courseLiveActivityLeadMinutes) ?? 20
        )
        timeTable = try container.decodeIfPresent([TimeSlot].self, forKey: .timeTable) ?? TimeSlot.default
        sharedSchedules = (try container.decodeIfPresent([SharedScheduleRecord].self, forKey: .sharedSchedules) ?? []).map {
            var schedule = $0
            schedule.title = Self.clampedScheduleTitle(schedule.title)
            return schedule
        }
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? true
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        cloudSyncBaselineAt = try container.decodeIfPresent(Date.self, forKey: .cloudSyncBaselineAt) ?? .distantPast
        cloudSyncBaselineRecordTag = try container.decodeIfPresent(String.self, forKey: .cloudSyncBaselineRecordTag) ?? ""
        hasUnpushedCloudChanges = try container.decodeIfPresent(Bool.self, forKey: .hasUnpushedCloudChanges) ?? false
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
            .union(schoolCoursesByTerm.keys)
            .union(currentTerm.isEmpty ? [] : [currentTerm])
        for term in baselineTerms where schoolCoursesByTerm[term] == nil {
            schoolCoursesByTerm[term] = termSchedulesByTerm[term]?.courses
                ?? cachedCoursesByTerm[term]
                ?? (term == currentTerm ? courses : [])
        }
        for term in baselineTerms {
            if let schoolCourses = schoolCoursesByTerm[term] {
                cachedCoursesByTerm[term] = schoolCourses
                if let snapshot = termSchedulesByTerm[term], snapshot.courses != schoolCourses {
                    termSchedulesByTerm[term] = TermScheduleSnapshot(
                        term: snapshot.term,
                        firstDayString: snapshot.firstDayString,
                        courses: schoolCourses,
                        exams: snapshot.exams,
                        updatedAt: snapshot.updatedAt
                    )
                }
            }
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
            cachedCoursesByTerm[currentTerm] = baseline
            manualCourseRulesByTerm[currentTerm] = reconciliation.validRules
        }
        firstDayString = manualFirstDayStringsByTerm[currentTerm] ?? firstDayString
    }

    /// 把课表标题裁到统一长度上限。调用方先提供默认标题，再传入需要裁切的文本。
    private static func clampedScheduleTitle(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(scheduleNameCharacterLimit))
    }


}

private extension LegacyScheduleCache {
    nonisolated func migrated() -> ScheduleCache {
        var cache = ScheduleCache()
        cache.courseData.primaryScheduleTitle = primaryScheduleTitle
        cache.courseData.currentTerm = currentTerm
        cache.courseData.manualFirstDayStringsByTerm = manualFirstDayStringsByTerm
        cache.courseData.manualCourseRulesByTerm = manualCourseRulesByTerm
        cache.courseData.customSchedules = customSchedules
        cache.courseData.timeTable = timeTable
        cache.courseData.sharedSchedules = sharedSchedules
        cache.ddlData.lexueCalendarURL = lexueCalendarURL
        cache.ddlData.ddlEvents = ddlEvents
        cache.ddlData.lexueDDLCompletionByID = lexueDDLCompletionByID
        cache.ddlData.ddlUpdatedAt = ddlUpdatedAt
        cache.ddlData.ddlBeforeDay = ddlBeforeDay
        cache.ddlData.ddlAfterDay = ddlAfterDay
        cache.classroomData.selectedCampusName = selectedCampusName
        cache.classroomData.selectedCampusCode = selectedCampusCode
        cache.classroomData.selectedBuildingID = selectedBuildingID
        cache.classroomData.cachedClassroomCampuses = cachedClassroomCampuses
        cache.classroomData.cachedClassroomBuildingsByCampusCode = cachedClassroomBuildingsByCampusCode
        cache.classroomData.selectedClassroomSectionIDs = selectedClassroomSectionIDs
        cache.classroomData.isClassroomSectionFilterCustomized = isClassroomSectionFilterCustomized
        cache.presentation.showSaturday = showSaturday
        cache.presentation.showSunday = showSunday
        cache.presentation.showExamInfo = showExamInfo
        cache.presentation.scheduleDisplayMode = scheduleDisplayMode
        cache.presentation.scheduleCardContentMode = scheduleCardContentMode
        cache.presentation.showCourseLiveActivityReminder = showCourseLiveActivityReminder
        cache.presentation.courseLiveActivityLeadMinutes = courseLiveActivityLeadMinutes
        cache.syncData.iCloudSyncEnabled = iCloudSyncEnabled
        cache.syncData.cloudSyncBaselineAt = cloudSyncBaselineAt
        cache.syncData.cloudSyncBaselineRecordTag = cloudSyncBaselineRecordTag
        cache.syncData.hasUnpushedCloudChanges = hasUnpushedCloudChanges
        cache.updatedAt = updatedAt
        cache.courseData.schedulesByTerm = termSchedulesByTerm
        if cache.courseData.schedulesByTerm[currentTerm] == nil,
           !currentTerm.isEmpty || !firstDayString.isEmpty || !courses.isEmpty || !exams.isEmpty {
            cache.courseData.schedulesByTerm[currentTerm] = TermScheduleSnapshot(
                term: currentTerm, firstDayString: firstDayString,
                courses: schoolCoursesByTerm[currentTerm] ?? courses, exams: exams, updatedAt: coursesUpdatedAt
            )
        }
        for (term, courses) in cachedCoursesByTerm where cache.courseData.schedulesByTerm[term] == nil {
            cache.courseData.schedulesByTerm[term] = TermScheduleSnapshot(
                term: term, firstDayString: "", courses: courses, exams: [], updatedAt: .distantPast
            )
            cache.courseData.archivedTerms.insert(term)
        }
        cache.courseData.reconcileRules()
        return cache
    }
}

/// 一条手动调课规则。
///
/// `sourceCourses` 保存规则创建时的学校原始课程；`replacementCourses` 保存显示层结果。
/// 刷新时先比较来源快照，再决定规则继续生效或移除。
public nonisolated struct ScheduleCourseRule: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceIdentity: String
    public let sourceCourses: [CourseRecord]
    public let replacementCourses: [CourseRecord]

    public init(
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

    public var isLocalAddition: Bool {
        sourceCourses.isEmpty
    }
}

/// 一个学期的完整课表快照。滚动本地缓存保留相邻的两个学期。
public nonisolated struct TermScheduleSnapshot: Codable, Equatable, Sendable {
    public let term: String
    public let firstDayString: String
    public let courses: [CourseRecord]
    public let exams: [ExamRecord]
    public let updatedAt: Date

    public var firstDay: Date? {
        ScheduleCache.parseScheduleFirstDay(firstDayString)
    }

    public var hasDisplayableData: Bool {
        !courses.isEmpty || !exams.isEmpty
    }
    public init(term: String, firstDayString: String, courses: [CourseRecord], exams: [ExamRecord], updatedAt: Date) {
        self.term = term
        self.firstDayString = firstDayString
        self.courses = courses
        self.exams = exams
        self.updatedAt = updatedAt
    }
}

/// 导入到本地后的分享课表记录。
///
/// 这类课表用于查看与切换；提醒、DDL、空教室偏好继续使用当前账号的私有课表逻辑。
public nonisolated struct SharedScheduleRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public let importedAt: Date
    public let sharedAt: Date?
    public let currentTerm: String
    public let firstDayString: String
    public let timeTable: [TimeSlot]
    public let courses: [CourseRecord]

    public init(
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

    public var isEmpty: Bool {
        courses.isEmpty
    }
}

/// 课程表和 DDL 共用的日期编解码工具。
///
/// 日程模块内部有多种日期展示形式，各页面共用这些格式器。

/// 地图与外部展示消费的课程快照。
public nonisolated struct ScheduleCourseSnapshot: Equatable, Sendable {
    public let firstDayString: String
    public let timeTable: [TimeSlot]
    public let courses: [CourseRecord]

    public init(firstDayString: String, timeTable: [TimeSlot], courses: [CourseRecord]) {
        self.firstDayString = firstDayString
        self.timeTable = timeTable
        self.courses = courses
    }

    public var firstDay: Date? { ScheduleCache.parseScheduleFirstDay(firstDayString) }
}

public extension ScheduleCache {
    var courseSnapshot: ScheduleCourseSnapshot {
        ScheduleCourseSnapshot(firstDayString: firstDayString, timeTable: timeTable, courses: courses)
    }
}

public nonisolated enum ScheduleCacheTimestamp {
    public static func next(after previous: Date, now: Date) -> Date {
        max(now, previous.addingTimeInterval(0.001))
    }

    public static func restored(recordDate: Date, payloadDate: Date, serverDate: Date? = nil) -> Date? {
        guard abs(recordDate.timeIntervalSince(payloadDate)) <= 1.1 else { return nil }
        return max(recordDate, serverDate ?? recordDate)
    }

    public static func afterCloudSave(_ serverDate: Date, currentDate: Date) -> Date {
        max(serverDate, currentDate)
    }
}
