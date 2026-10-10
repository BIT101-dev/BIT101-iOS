import BIT101TestSupport
import Foundation
import ScheduleDomain
import SchedulePorts
@testable import ScheduleFeature
import SchedulePersistence
import StorageCore
import Testing

@MainActor
struct ScheduleTimeTableTests {
    @Test func touchingSectionEndpointsRoundTripThroughCacheAndShare() throws {
        let slots = [TimeSlot(id: 1, start: "08:00", end: "08:45"), TimeSlot(id: 2, start: "08:45", end: "09:30")]
        #expect(TimeSlot.isValidTable(slots))
        #expect(slots[0].endMinutes == slots[1].startMinutes)
        try ScheduleExportPayload(currentTerm: "term", firstDayString: "2026-09-07", timeTable: slots, courses: []).validate()
        var cache = ScheduleCache()
        cache.timeTable = slots
        let decoded = try #require(SchedulePersistenceStore.decodeCache(try JSONEncoder().encode(cache)).cacheIfReadable)
        #expect(decoded.timeTable == slots)
    }

    @Test func pendingCoursesKeepTimeTableEditingAvailable() async throws {
        let scheduled = try #require(try ScheduleCourseEditor.adding(CourseDraft(title: "待排课程", weeksText: "1"),
            to: [], term: "term", id: "pending").first)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(scheduled)) as? [String: Any])
        object["weeks"] = [] as [Int]
        for field in ["weekday", "startSection", "endSection"] { object[field] = 0 }
        let pending = try JSONDecoder().decode(CourseRecord.self, from: JSONSerialization.data(withJSONObject: object))
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        cache.courseData.store(.init(term: "term", firstDayString: "", courses: [pending], exams: [], updatedAt: Date()))
        let repository = ScheduleRepository(session: { .init(accountIdentifier: "pending") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = ModuleScheduleService()
        let model = ScheduleViewModel(service: service, repository: repository, ddlService: service,
            classroomService: service, platformActions: ModuleSchedulePlatformActions(), newCustomScheduleDraft: { .init() })
        try model.setTimeTable(from: "08:00,08:45")
        #expect(await repository.persistAndWait())
        #expect(repository.persistenceSnapshot.courses == [pending])
        #expect(repository.persistenceSnapshot.timeTable == [.init(id: 1, start: "08:00", end: "08:45")])
    }

    @Test func schoolCoursesArrivingAfterTheTableWasShortenedPreserveThePreviousSnapshot() async throws {
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        var writes = 0
        let repository = ScheduleRepository(session: { .init(accountIdentifier: "school-slots") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in writes += 1 })
        await repository.loadIfNeeded()
        let service = ModuleScheduleService()
        let incoming = try ScheduleCourseEditor.adding(CourseDraft(title: "晚间课程", weeksText: "1", selectedSections: [11, 12]),
            to: [], term: "term", id: "school")
        service.onSync = { _ in CourseSyncPayload(term: "term", firstDayString: "2026-09-07",
            sourceFirstDayString: "2026-09-07", normalizationOffset: 0, rawWeeksByCourse: incoming.map(\.weeks),
            courses: incoming, exams: []) }
        let model = ScheduleViewModel(service: service, repository: repository, ddlService: service,
            classroomService: service, platformActions: ModuleSchedulePlatformActions(), newCustomScheduleDraft: { .init() })
        try model.setTimeTable(from: "08:00,08:45")
        #expect(await repository.persistAndWait())
        let writesBeforeSync = writes
        await model.syncCourses(term: "term")
        #expect(writes == writesBeforeSync && repository.persistenceSnapshot.courses.isEmpty)
        #expect(repository.persistenceSnapshot.coursesUpdatedAt == .distantPast)
        #expect(model.notice?.title == "请调整节次时间表")
        try model.setTimeTable(from: TimeSlot.default.map { "\($0.start),\($0.end)" }.joined(separator: "\n"))
        #expect(await repository.persistAndWait())
        await model.syncCourses(term: "term")
        #expect(repository.persistenceSnapshot.courses == incoming)
        #expect(repository.persistenceSnapshot.hasSupportedCourseSections)
    }

    @Test func incompatibleCourseSectionsKeepTheCommittedDiskSnapshot() async throws {
        let files = ModuleScoreFiles()
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/time-table"), userStateMatches: { _, _ in true })
        let account = AppStorageSession(accountIdentifier: "sections")
        let cache = ScheduleCache()
        let saved = try #require(await store.write(cache, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .cloud, expectedUpdatedAt: nil))
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = try files.readData(at: url)
        var invalid = saved
        invalid.currentTerm = "term"
        invalid.timeTable = [.init(id: 1, start: "08:00", end: "08:45")]
        let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "晚间课程", weeksText: "1", selectedSections: [12]),
            to: [], term: "term", id: "course")
        invalid.courseData.store(.init(term: "term", firstDayString: "", courses: courses, exams: [], updatedAt: Date()))
        #expect(await store.write(invalid, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local,
            expectedUpdatedAt: saved.updatedAt) == nil)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test func classroomCalculatorRunsInBackground() async {
        let result = await Self.backgroundClassrooms()
        #expect(result.count == 5_000 && result.allSatisfy(\.isFreeNow))
    }

    @concurrent
    private static func backgroundClassrooms() async -> [ClassroomAvailability] {
        ClassroomAvailabilityCalculator.availabilities(records: (0..<10_000).map {
            ClassroomRecord(id: String($0), name: String($0), busyTimeCodes: $0.isMultiple(of: 2) ? [1] : []) },
            timeTable: [TimeSlot(id: 1, start: "08:00", end: "08:45")], selectedSections: [], nowMinutes: 8 * 60)
    }
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
