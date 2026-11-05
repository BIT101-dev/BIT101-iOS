import Foundation
import ScheduleContracts

public nonisolated enum ScheduleCacheLoadResult: Sendable {
    case loaded(ScheduleCache)
    /// 有效部分供展示，用户确认恢复后提交新的完整快照。
    case recovered(ScheduleCache)
    case damaged
    case missing
    case unreadable

    public var isUnreadable: Bool {
        switch self {
        case .damaged, .unreadable: true
        case .loaded, .recovered, .missing: false
        }
    }

    public var isDamaged: Bool {
        if case .damaged = self { return true }
        return false
    }

    public var isRecovered: Bool {
        if case .recovered = self { return true }
        return false
    }

    public var allowsWrite: Bool {
        switch self {
        case .loaded, .missing: true
        case .recovered, .damaged, .unreadable: false
        }
    }

    public var cacheIfReadable: ScheduleCache? {
        switch self {
        case .loaded(let cache), .recovered(let cache): return cache
        case .missing: return ScheduleCache()
        case .damaged, .unreadable: return nil
        }
    }
}

public nonisolated enum ScheduleCacheSaveSource: Sendable {
    /// 保存本机业务修改与自动元数据更新。
    case local
    case localWithoutCloudPush
    /// 用户核对部分恢复结果后明确提交。
    case recovery
    /// 用户确认以当前可用日程重建损坏文件。
    case rebuild
    case cloud
    /// 记录已确认的云端参照状态，同时保留后续本地编辑的待上传状态。
    case cloudBaseline
}

/// 账号日程的版本化磁盘快照，各业务区域独立拥有其状态。
public nonisolated struct ScheduleCache: Codable, Sendable {
    public static let schemaVersion = 1
    public static let maximumEncodedBytes = 64 * 1_024 * 1_024
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
            guard
                ![CodingKeys.courseData, .ddlData, .classroomData, .presentation, .syncData]
                    .contains(where: container.contains)
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Structured schedule cache requires its schema version."))
            }
            self = try LegacyScheduleCache(from: decoder).migrated()
            removeDuplicateRecords()
            correctSchoolParityWeeks()
            try validateForPersistence(codingPath: decoder.codingPath)
            return
        }
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription:
                    """
                    Schedule cache requires schema version \(Self.schemaVersion); received \
                    \(version).
                    """
            )
        }
        courseData = try container.decode(ScheduleCourseData.self, forKey: .courseData)
        ddlData = try container.decode(ScheduleDDLData.self, forKey: .ddlData)
        classroomData = try container.decode(ScheduleClassroomData.self, forKey: .classroomData)
        presentation = try container.decode(
            SchedulePresentationPreferences.self, forKey: .presentation)
        syncData = try container.decode(ScheduleSyncData.self, forKey: .syncData)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        removeDuplicateRecords()
        correctSchoolParityWeeks()
        try validateForPersistence(codingPath: decoder.codingPath)
    }

    /// 历史缓存中的完全相同记录按首次出现顺序合并，身份冲突继续参与完整校验。
    private mutating func removeDuplicateRecords() {
        func unique<Record: Hashable>(_ records: [Record]) -> [Record] {
            var seen = Set<Record>()
            return records.filter { seen.insert($0).inserted }
        }
        courseData.schedulesByTerm = courseData.schedulesByTerm.mapValues { snapshot in
            TermScheduleSnapshot(
                term: snapshot.term, firstDayString: snapshot.firstDayString,
                courses: unique(snapshot.courses), exams: unique(snapshot.exams),
                updatedAt: snapshot.updatedAt)
        }
        courseData.manualCourseRulesByTerm = courseData.manualCourseRulesByTerm.mapValues { rules in
            unique(rules).map { rule in
                ScheduleCourseRule(
                    id: rule.id, sourceIdentity: rule.sourceIdentity,
                    sourceCourses: unique(rule.sourceCourses),
                    replacementCourses: unique(rule.replacementCourses))
            }
        }
        courseData.customSchedules = unique(courseData.customSchedules)
        ddlData.ddlEvents = unique(ddlData.ddlEvents)
        courseData.sharedSchedules = unique(courseData.sharedSchedules).map { shared in
            SharedScheduleRecord(
                id: shared.id, title: shared.title, importedAt: shared.importedAt,
                payload: ScheduleExportPayload(
                    exportedAt: shared.sharedAt, currentTerm: shared.currentTerm,
                    firstDayString: shared.firstDayString, timeTable: shared.timeTable,
                    courses: unique(shared.courses)))
        }
    }

    private mutating func correctSchoolParityWeeks() {
        for (term, snapshot) in courseData.schedulesByTerm {
            let corrected = CourseScheduleRowParser.correctingParityWeeks(snapshot.courses)
            guard corrected != snapshot.courses else { continue }
            courseData.schedulesByTerm[term] = TermScheduleSnapshot(
                term: term, firstDayString: snapshot.firstDayString,
                courses: corrected, exams: snapshot.exams, updatedAt: snapshot.updatedAt)
            courseData.manualCourseRulesByTerm[term] = courseData.manualCourseRulesByTerm[term]?.map
            { rule in
                let original = snapshot.courses.filter {
                    courseSourceIdentity($0) == rule.sourceIdentity
                }
                guard courseSourcesEqual(original, rule.sourceCourses) else { return rule }
                return ScheduleCourseRule(
                    id: rule.id, sourceIdentity: rule.sourceIdentity,
                    sourceCourses: CourseScheduleRowParser.correctingParityWeeks(
                        rule.sourceCourses),
                    replacementCourses: rule.replacementCourses)
            }
        }
    }

    private func validateForPersistence(codingPath: [any CodingKey]) throws {
        if let field = invalidPersistenceField {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: codingPath + [field],
                    debugDescription:
                        """
                        Schedule records require valid identities, dates, time ranges and secti\
                        on placements.
                        """
                ))
        }
    }

    public var hasValidTimeTables: Bool {
        TimeSlot.isValidTable(timeTable)
            && sharedSchedules.allSatisfy { TimeSlot.isValidTable($0.timeTable) }
    }

    public var hasValidCoursePlacements: Bool {
        courseData.schedulesByTerm.values.allSatisfy { hasValidCourses($0.courses) }
            && sharedSchedules.allSatisfy { hasValidCourses($0.courses) }
            && manualCourseRulesByTerm.values.allSatisfy { rules in
                hasUniqueIdentities(rules.map(\.id))
                    && rules.allSatisfy {
                        !$0.sourceIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && hasValidCourses($0.sourceCourses)
                            && hasValidCourses($0.replacementCourses)
                    }
            }
    }

    public var isValidForPersistence: Bool { invalidPersistenceField == nil }

    private enum ValidationField: String, CodingKey {
        case timeTable, courses, customSchedules, ddlEvents, sharedSchedules, exams, classroomData
    }

    private var invalidPersistenceField: ValidationField? {
        if !hasValidTimeTables { return .timeTable }
        if !hasValidCoursePlacements || !hasSupportedCourseSections { return .courses }
        if !customSchedules.allSatisfy(\.hasValidPlacement)
            || Set(customSchedules.map(\.id)).count != customSchedules.count
        {
            return .customSchedules
        }
        if !ddlEvents.allSatisfy(\.hasValidRecord) || !hasUniqueIdentities(ddlEvents.map(\.id))
            || DDLImagePolicy.totalBytes(in: ddlEvents) > DDLImagePolicy.maximumTotalBytes
        {
            return .ddlEvents
        }
        if !hasUniqueIdentities(sharedSchedules.map(\.id)) { return .sharedSchedules }
        if !courseData.schedulesByTerm.values.allSatisfy({
            $0.exams.allSatisfy(\.hasValidPlacement) && hasUniqueIdentities($0.exams.map(\.id))
        }) {
            return .exams
        }
        for queries in [
            classroomData.cachedClassroomQueriesByBuildingID,
            classroomData.nextDayClassroomQueriesByBuildingID,
        ] {
            if queries?.contains(where: {
                $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.value.isValid
            }) == true {
                return .classroomData
            }
        }
        return nil
    }

    private func hasUniqueIdentities(_ ids: [String]) -> Bool {
        ids.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && Set(ids).count == ids.count
    }

    private func hasValidCourses(_ courses: [CourseRecord]) -> Bool {
        courses.allSatisfy(\.hasValidPlacement) && hasUniqueIdentities(courses.map(\.id))
    }

    public var hasSupportedCourseSections: Bool {
        let terms = Set(courseData.schedulesByTerm.keys).subtracting(courseData.archivedTerms)
            .union(manualCourseRulesByTerm.keys)
        let coursesByTerm = terms.map { term in
            ScheduleCourseEditor.reconcile(
                rules: manualCourseRulesByTerm[term] ?? [],
                with: courseData.archivedTerms.contains(term)
                    ? [] : courseData.schoolCourses(for: term)
            ).courses
        }
        return coursesByTerm.allSatisfy { hasUniqueIdentities($0.map(\.id)) }
            && TimeSlot.supports(coursesByTerm.flatMap { $0 }, in: timeTable)
            && sharedSchedules.allSatisfy { TimeSlot.supports($0.courses, in: $0.timeTable) }
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
    public var termSchedulesByTerm: [String: TermScheduleSnapshot] {
        courseData.termSchedulesByTerm
    }
    /// 解析 `yyyy-MM-dd` 首周日期，供缓存和学期快照共用。
    static func parseScheduleFirstDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-")
        guard
            parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2]),
            (1...12).contains(month),
            (1...31).contains(day)
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
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            return nil
        }
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
