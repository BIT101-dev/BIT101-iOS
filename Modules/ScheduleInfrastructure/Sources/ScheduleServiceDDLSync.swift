import ClientCore
import Foundation
import ScheduleDomain
import SchedulePorts
import TransportCore

extension ScheduleService {
    /// 两个来源独立推进，成功来源立即交付；课程中心按课程保留待恢复内容。
    public func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String,
        schoolSMSCodeHandler: SchoolSMSCodeHandler? = nil, onSource: DDLSyncSourceDelivery? = nil) async throws -> DDLSyncPayload {
        let owner = credentials.schoolSessionIdentity
        try validateAuthenticationOwner(owner)
        return try await withThrowingTaskGroup(of: (String, Result<DDLSyncPayload, any Error>).self) { group in
            group.addTask {
                do {
                    let result = try await self.fetchEclassDDLEvents(schoolSMSCodeHandler: schoolSMSCodeHandler)
                    let events = Self.mergingEclassCourses(result, existingEvents: existingEvents)
                    let warnings = result.failure.map {
                        ["课程中心：\(result.failedCourseIDs.count) 门课程读取受阻，已保留缓存。\($0.localizedDescription)"]
                    } ?? []
                    return ("课程中心", .success(.init(url: storedURL, events: events, syncedGroups: ["eclass"], warnings: warnings)))
                } catch {
                    if TaskCancellation.matches(error) { throw error }
                    return ("课程中心", .failure(error))
                }
            }
            group.addTask {
                do {
                    let result = try await self.syncDDLEvents(existingEvents: existingEvents, storedURL: storedURL,
                        schoolSMSCodeHandler: schoolSMSCodeHandler, smsDeliveryMode: .send, owner: owner)
                    return ("乐学", .success(result))
                } catch {
                    if TaskCancellation.matches(error) { throw error }
                    return ("乐学", .failure(error))
                }
            }
            var events: [DDLEventRecord] = [], groups: Set<String> = [], warnings: [String] = []
            var calendarURL = storedURL
            var firstError: (any Error)?
            let doneByID = Dictionary(existingEvents.map { ($0.id, $0.done) }, uniquingKeysWith: { first, _ in first })
            for try await (source, result) in group {
                try validateAuthenticationOwner(owner)
                switch result {
                case .success(let payload):
                    let completed = payload.events.map { event in
                        var event = event; event.done = doneByID[event.id] ?? event.done; return event
                    }
                    let update = DDLSyncPayload(url: payload.url, events: completed,
                        syncedGroups: payload.syncedGroups, warnings: payload.warnings)
                    try await onSource?(update)
                    try validateAuthenticationOwner(owner)
                    events.append(contentsOf: completed)
                    groups.formUnion(payload.syncedGroups)
                    warnings.append(contentsOf: payload.warnings)
                    if payload.syncedGroups.contains("lexue") { calendarURL = payload.url }
                case .failure(let error):
                    firstError = firstError ?? error
                    warnings.append("\(source)：\(error.localizedDescription)")
                }
            }
            guard !groups.isEmpty else { throw firstError ?? ScheduleServiceError.invalidResponse }
            return DDLSyncPayload(url: calendarURL, events: events, syncedGroups: groups, warnings: warnings)
        }
    }

    private nonisolated static func mergingEclassCourses(_ result: EclassDDLResult, existingEvents: [DDLEventRecord]) -> [DDLEventRecord] {
        guard !result.failedCourseIDs.isEmpty else { return result.events }
        var retained = Dictionary(existingEvents.filter {
            $0.group == "eclass" && ($0.sourceCourseIDs.map { !$0.isDisjoint(with: result.failedCourseIDs) } ?? true)
        }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for event in result.events {
            var event = event
            if let previous = retained[event.id] {
                event.sourceCourseIDs = (event.sourceCourseIDs ?? []).union(previous.sourceCourseIDs ?? [])
            }
            retained[event.id] = event
        }
        return retained.values.sorted { $0.dueAt == $1.dueAt ? $0.id < $1.id : $0.dueAt < $1.dueAt }
    }
}
