import BIT101TestSupport
import Foundation
import ScheduleDomain
@testable import ScheduleFeature
import SchedulePersistence
import StorageCore
import Testing

@MainActor
struct ScheduleTimeTableTests {
    @Test(arguments: ["invalid", "reverse", "overlap", "id", "order"])
    func invalidTablesFailAtCacheAndShareBoundaries(kind: String) throws {
        let first = TimeSlot(id: 1, start: "08:00", end: "08:45")
        let second: TimeSlot
        switch kind {
        case "invalid": second = .init(id: 2, start: "bad", end: "09:45")
        case "reverse": second = .init(id: 2, start: "10:00", end: "09:45")
        case "overlap": second = .init(id: 2, start: "08:30", end: "09:45")
        case "id": second = .init(id: 0, start: "09:00", end: "09:45")
        default: second = .init(id: 1, start: "09:00", end: "09:45")
        }
        var cache = ScheduleCache()
        cache.timeTable = [first, second]
        let payload = ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: cache.timeTable, courses: [])
        #expect(throws: ScheduleShareCodeError.self) { try payload.validate() }
        #expect(SchedulePersistenceStore.decodeCache(try JSONEncoder().encode(cache)).isUnreadable)
        let legacy = try JSONSerialization.data(withJSONObject: ["timeTable": [
            ["id": first.id, "start": first.start, "end": first.end],
            ["id": second.id, "start": second.start, "end": second.end]]])
        #expect(SchedulePersistenceStore.decodeCache(legacy).isUnreadable)
    }

    @Test func theDayBoundaryHasOneContractAndShrinkingRetainsCourseData() async throws {
        let slots = [TimeSlot(id: 1, start: "23:00", end: "24:00")]
        #expect(TimeSlot.isValidTable(slots))
        try ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: slots, courses: []).validate()
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "课程", weeksText: "1", selectedSections: [2]),
            to: [], term: "term", id: "course")
        cache.manualCourseRulesByTerm = ["term": [.init(id: "rule", sourceIdentity: "", sourceCourses: [], replacementCourses: courses)]]
        var writes = 0
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "time-table") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in writes += 1 })
        await repository.loadIfNeeded()
        let service = ModuleScheduleService()
        let model = ScheduleViewModel(service: service, repository: repository, ddlService: service,
            classroomService: service, platformActions: ModuleSchedulePlatformActions(), newCustomScheduleDraft: { .init() })
        #expect(throws: Error.self) { try model.setTimeTable(from: "23:00,24:00") }
        #expect(repository.persistenceSnapshot.timeTable == TimeSlot.default && writes == 0)
        #expect(repository.persistenceSnapshot.courses == courses)
        repository.courseState.manualCourseRulesByTerm = [:]
        try model.setTimeTable(from: "23:00,24:00")
        #expect(repository.persistenceSnapshot.timeTable == slots)
    }
}
