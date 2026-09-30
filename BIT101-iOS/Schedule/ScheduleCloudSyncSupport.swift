import ScheduleDomain
import Foundation

#if canImport(CloudKit)
import CloudKit

/// Baseline tags identify known concurrent writes; timestamps resolve incomplete baselines.
///
/// Keeping the decision pure makes the behavior testable without constructing a
/// signed CloudKit container or touching the current account's on-device cache.
nonisolated enum ScheduleCacheReconciliationDecision: Equatable {
    case applyRemote
    case uploadLocal
    case noChange
}

nonisolated enum ScheduleCacheReconciliationPolicy {
    static func decision(
        localUpdatedAt: Date,
        remoteUpdatedAt: Date,
        allowsRemoteApply: Bool
    ) -> ScheduleCacheReconciliationDecision {
        if allowsRemoteApply, remoteUpdatedAt > localUpdatedAt {
            return .applyRemote
        }
        if localUpdatedAt > remoteUpdatedAt {
            return .uploadLocal
        }
        return .noChange
    }

    static func hasConcurrentChanges(
        localHasUnpushedChanges: Bool,
        localBaselineRecordTag: String,
        remoteRecordTag: String,
        localUpdatedAt: Date,
        remoteUpdatedAt: Date
    ) -> Bool {
        guard localHasUnpushedChanges else { return false }
        guard !localBaselineRecordTag.isEmpty, !remoteRecordTag.isEmpty else {
            return remoteUpdatedAt > localUpdatedAt
        }
        return localBaselineRecordTag != remoteRecordTag
    }
}

nonisolated enum ScheduleCacheConflictResolution: Sendable {
    case keepLocal
    case useCloud
}

/// Cross-device user state. School-provided schedule data remains in the local cache.
nonisolated struct ScheduleCloudSyncState: Codable, Sendable {
    static func matches(_ lhs: ScheduleCache, _ rhs: ScheduleCache) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Self(cache: lhs)) == encoder.encode(Self(cache: rhs))
    }

    var primaryScheduleTitle: String
    var manualCourseRulesByTerm: [String: [ScheduleCourseRule]]
    var manualDDLEvents: [DDLEventRecord]
    var lexueDDLCompletionByID: [String: Bool]
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

    init(cache: ScheduleCache) {
        primaryScheduleTitle = cache.primaryScheduleTitle
        manualCourseRulesByTerm = cache.manualCourseRulesByTerm
        manualDDLEvents = cache.ddlEvents.filter { $0.group != "lexue" }
        var completionByID = cache.lexueDDLCompletionByID
        for event in cache.ddlEvents where event.group == "lexue" {
            completionByID[event.id] = event.done
        }
        lexueDDLCompletionByID = completionByID
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

    func apply(to cache: inout ScheduleCache) {
        cache.primaryScheduleTitle = primaryScheduleTitle
        cache.manualCourseRulesByTerm = manualCourseRulesByTerm
        let localLexueEvents = cache.ddlEvents
            .filter { $0.group == "lexue" }
            .map { event in
                var event = event
                event.done = lexueDDLCompletionByID[event.id] ?? event.done
                return event
            }
        cache.lexueDDLCompletionByID = lexueDDLCompletionByID
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

/// Versioned envelope keeps older-client reads distinct from the local cache format.
nonisolated struct ScheduleCloudSyncEnvelope: Codable {
    let schemaVersion: Int
    // Keep the timestamp nested so legacy decoders treat this as a distinct payload format.
    let payload: Payload

    static let currentSchemaVersion = 2

    nonisolated struct Payload: Codable, Sendable {
        let updatedAt: Date
        let state: ScheduleCloudSyncState
    }
}

nonisolated struct DecodedScheduleCloudCache {
    let cache: ScheduleCache
    let requiresPayloadMigration: Bool
}

nonisolated extension ScheduleCache {
    func applyingCloudSyncState(from source: ScheduleCache) -> ScheduleCache {
        var result = self
        ScheduleCloudSyncState(cache: source).apply(to: &result)
        return result
    }
}

#endif
