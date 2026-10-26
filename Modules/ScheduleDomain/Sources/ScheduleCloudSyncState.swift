import Foundation

public nonisolated enum ScheduleCacheConflictResolution: Equatable, Sendable {
    case keepLocal
    case useCloud
}

/// Cross-device user state. School-provided schedule data remains in the local cache.
public nonisolated struct ScheduleCloudSyncState: Codable, Sendable {
    public static func matches(_ lhs: ScheduleCache, _ rhs: ScheduleCache) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Self(cache: lhs)) == encoder.encode(Self(cache: rhs))
    }

    var primaryScheduleTitle: String
    var manualCourseRulesByTerm: [String: [ScheduleCourseRule]]
    package var manualDDLEvents: [DDLEventRecord]
    var lexueDDLCompletionByID: [String: Bool]
    var schoolDDLCompletionRetiredAtByID: [String: Date]?
    var customSchedules: [CustomScheduleRecord]
    var ddlBeforeDay: Int
    var ddlAfterDay: Int
    var selectedCampusName: String
    var selectedCampusCode: String
    var selectedBuildingID: String
    var selectedClassroomSectionIDs: [Int]
    var isClassroomSectionFilterCustomized: Bool
    var showSaturday: Bool
    var showSunday: Bool
    var showExamInfo: Bool
    var scheduleDisplayMode: ScheduleDisplayMode
    var scheduleCardContentMode: ScheduleCardContentMode
    var showCourseLiveActivityReminder: Bool
    var courseLiveActivityLeadMinutes: Int
    var timeTable: [TimeSlot]
    var sharedSchedules: [SharedScheduleRecord]

    public var hasValidManualDDLEvents: Bool {
        manualDDLEvents.allSatisfy { !$0.isSchoolSynced && $0.hasValidRecord }
            && DDLImagePolicy.totalBytes(in: manualDDLEvents) <= DDLImagePolicy.maximumTotalBytes
    }

    public init(cache: ScheduleCache) {
        primaryScheduleTitle = cache.primaryScheduleTitle
        manualCourseRulesByTerm = cache.manualCourseRulesByTerm.filter { !$0.value.isEmpty }
        manualDDLEvents = cache.ddlEvents.filter { !$0.isSchoolSynced }
        var completionByID = cache.lexueDDLCompletionByID
        for event in cache.ddlEvents where event.isSchoolSynced && (event.done || completionByID[event.id] != nil) {
            completionByID[event.id] = event.done
        }
        lexueDDLCompletionByID = completionByID
        schoolDDLCompletionRetiredAtByID = cache.ddlData.schoolDDLCompletionRetiredAtByID
        customSchedules = cache.customSchedules
        ddlBeforeDay = cache.ddlBeforeDay
        ddlAfterDay = cache.ddlAfterDay
        selectedCampusName = cache.selectedCampusName
        selectedCampusCode = cache.selectedCampusCode
        selectedBuildingID = cache.selectedBuildingID
        selectedClassroomSectionIDs = cache.selectedClassroomSectionIDs
        isClassroomSectionFilterCustomized = cache.isClassroomSectionFilterCustomized
        showSaturday = cache.showSaturday
        showSunday = cache.showSunday
        showExamInfo = cache.showExamInfo
        scheduleDisplayMode = cache.scheduleDisplayMode
        scheduleCardContentMode = cache.scheduleCardContentMode
        showCourseLiveActivityReminder = cache.showCourseLiveActivityReminder
        courseLiveActivityLeadMinutes = cache.courseLiveActivityLeadMinutes
        timeTable = cache.timeTable
        sharedSchedules = cache.sharedSchedules
    }

    public func apply(to cache: inout ScheduleCache) {
        cache.primaryScheduleTitle = primaryScheduleTitle
        cache.manualCourseRulesByTerm = manualCourseRulesByTerm
        let localLexueEvents = cache.ddlEvents
            .filter { $0.isSchoolSynced }
            .map { event in
                var event = event
                event.done = lexueDDLCompletionByID[event.id] ?? event.done
                return event
            }
        cache.lexueDDLCompletionByID = lexueDDLCompletionByID
        cache.ddlData.schoolDDLCompletionRetiredAtByID = schoolDDLCompletionRetiredAtByID
        cache.ddlEvents = (manualDDLEvents + localLexueEvents).sorted { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id < rhs.id
        }
        cache.customSchedules = customSchedules
        cache.ddlBeforeDay = ddlBeforeDay
        cache.ddlAfterDay = ddlAfterDay
        cache.selectedCampusName = selectedCampusName
        cache.selectedCampusCode = selectedCampusCode
        cache.selectedBuildingID = selectedBuildingID
        cache.selectedClassroomSectionIDs = selectedClassroomSectionIDs
        cache.isClassroomSectionFilterCustomized = isClassroomSectionFilterCustomized
        cache.showSaturday = showSaturday
        cache.showSunday = showSunday
        cache.showExamInfo = showExamInfo
        cache.scheduleDisplayMode = scheduleDisplayMode
        cache.scheduleCardContentMode = scheduleCardContentMode
        cache.showCourseLiveActivityReminder = showCourseLiveActivityReminder
        cache.courseLiveActivityLeadMinutes = courseLiveActivityLeadMinutes
        cache.timeTable = timeTable
        cache.sharedSchedules = sharedSchedules
    }
}

nonisolated extension ScheduleCache {
    public func applyingCloudSyncState(from source: ScheduleCache) -> ScheduleCache {
        var result = self
        ScheduleCloudSyncState(cache: source).apply(to: &result)
        return result
    }
}
