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
    @Test func sharingScheduledCoursesKeepsPendingCoursesInTheLocalCache() throws {
        let scheduled = try #require(ScheduleCourseEditor.adding(CourseDraft(title: "已排课程", weeksText: "1"),
            to: [], term: "term", id: "scheduled").first)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(scheduled)) as? [String: Any])
        object["id"] = "pending"; object["name"] = "待排课程"; object["weeks"] = [] as [Int]
        for field in ["weekday", "startSection", "endSection"] { object[field] = 0 }
        let pending = try JSONDecoder().decode(CourseRecord.self, from: JSONSerialization.data(withJSONObject: object))
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        cache.courseData.store(.init(term: "term", firstDayString: "2026-09-07", courses: [scheduled, pending], exams: [], updatedAt: .distantPast))
        let code = try ScheduleShareCodeCodec.encodeLatest(cache: cache)
        let restored = try ScheduleShareCodeCodec.decode(code, using: cache)
        #expect(restored.courses.map(\.name) == [scheduled.name])
        #expect(cache.courses == [scheduled, pending])
        let malformed = scheduled.replacingWeeks([])
        #expect(throws: ScheduleShareCodeError.self) { try ScheduleShareCodeCodec.encodeLatest(courses: [scheduled, malformed]) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], ["ddl", "custom", "shared", "rules", "presentation", "course", "json"])
    func damagedBlocksResetWhileHealthyCoursesStayAvailableOffline(legacy: Bool, block: String) async throws {
        let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "已有课表", weekday: 1, weeksText: "1-4"),
            to: [], term: "term", id: "course")
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        cache.courseData.store(.init(term: "term", firstDayString: "2026-09-07", courses: courses,
            exams: [], updatedAt: Date(timeIntervalSince1970: 100)))
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as? [String: Any])
        var course = try #require(root["courseData"] as? [String: Any])
        let courseKey = ["custom": "customSchedules", "shared": "sharedSchedules", "rules": "manualCourseRulesByTerm", "course": "schedulesByTerm"][block]
        if let courseKey { course[courseKey] = "damaged" }
        root["courseData"] = course
        if block == "ddl" { root["ddlData"] = ["ddlEvents": "damaged"] }
        if block == "presentation" { root["presentation"] = ["showSaturday": "damaged"] }
        if legacy {
            var flat: [String: Any] = ["storedCourseScheduleParserVersion": 2]
            for key in ["courseData", "ddlData", "presentation"] {
                flat.merge(try #require(root[key] as? [String: Any])) { _, value in value }
            }
            flat["termSchedulesByTerm"] = flat.removeValue(forKey: "schedulesByTerm")
            root = flat
        }
        let bytes = block == "json" ? Data("{damaged".utf8) : try JSONSerialization.data(withJSONObject: root)
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "block-reset")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/block-reset"), userStateMatches: { _, _ in true })
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        try files.writeData(bytes, to: url, options: .atomic)
        let result = await store.load(for: account)
        if block == "json" {
            #expect(result.isUnreadable)
            #expect(try files.readData(at: url) == bytes)
            return
        }
        let restored = try #require(result.cacheIfReadable)
        #expect(restored.isValidForPersistence)
        #expect(restored.courses == (block == "course" ? [] : courses))
        #expect(try files.readData(at: url) == bytes)
        #expect(await store.load(for: account).cacheIfReadable?.courseData == restored.courseData)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test(.timeLimit(.minutes(1))) func anUnselectedCachedTermAppearsWithoutFetchingCourses() async throws {
        let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "已有课表", weekday: 1, weeksText: "1-4"),
            to: [], term: "term", id: "course")
        var cache = ScheduleCache()
        cache.courseData.store(.init(term: "term", firstDayString: "2026-09-07", courses: courses, exams: [], updatedAt: .distantPast))
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "cached-term")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/cached-term"), userStateMatches: { _, _ in true })
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        try files.writeData(JSONEncoder().encode(cache), to: url, options: .atomic)
        let restored = try #require(await store.load(for: account).cacheIfReadable)
        #expect(restored.currentTerm == "term" && restored.courses == courses)
        #expect(SchedulePersistenceStore.decodeCache(try files.readData(at: url)).cacheIfReadable?.currentTerm == "")
    }

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

    @Test(.timeLimit(.minutes(1))) func pendingCoursesKeepTimeTableEditingAvailable() async throws {
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

    @Test(.timeLimit(.minutes(1))) func schoolCoursesArrivingAfterTheTableWasShortenedPreserveThePreviousSnapshot() async throws {
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

    @Test(.timeLimit(.minutes(1))) func incompatibleCourseSectionsKeepTheCommittedDiskSnapshot() async throws {
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

    @Test(.timeLimit(.minutes(1))) func classroomCalculatorRunsInBackground() async {
        let result = await Self.backgroundClassrooms()
        #expect(result.count == 5_000 && result.allSatisfy(\.isFreeNow))
    }

    @concurrent
    private static func backgroundClassrooms() async -> [ClassroomAvailability] {
        ClassroomAvailabilityCalculator.availabilities(records: (0..<10_000).map {
            ClassroomRecord(id: String($0), name: String($0), busyTimeCodes: $0.isMultiple(of: 2) ? [1] : []) },
            timeTable: [TimeSlot(id: 1, start: "08:00", end: "08:45")], selectedSections: [], nowMinutes: 8 * 60)
    }
    @Test(arguments: ["invalid", "reverse", "overlap", "id", "order", "start", "gap"])
    func invalidTablesFailAtCacheAndShareBoundaries(kind: String) throws {
        let first = TimeSlot(id: 1, start: "08:00", end: "08:45")
        let second: TimeSlot
        switch kind {
        case "invalid": second = .init(id: 2, start: "bad", end: "09:45")
        case "reverse": second = .init(id: 2, start: "10:00", end: "09:45")
        case "overlap": second = .init(id: 2, start: "08:30", end: "09:45")
        case "id": second = .init(id: 0, start: "09:00", end: "09:45")
        case "start": second = .init(id: 2, start: "09:00", end: "09:45")
        case "gap": second = .init(id: 3, start: "09:00", end: "09:45")
        default: second = .init(id: 1, start: "09:00", end: "09:45")
        }
        var cache = ScheduleCache()
        cache.timeTable = kind == "start" ? [second] : [first, second]
        let payload = ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: cache.timeTable, courses: [])
        #expect(throws: ScheduleShareCodeError.self) { try payload.validate() }
        #expect(SchedulePersistenceStore.decodeCache(try JSONEncoder().encode(cache)).isUnreadable)
        let legacy = try JSONSerialization.data(withJSONObject: ["timeTable": cache.timeTable.map {
            ["id": $0.id, "start": $0.start, "end": $0.end] as [String: Any]
        }])
        #expect(SchedulePersistenceStore.decodeCache(legacy).isUnreadable)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["school", "manual", "shared"])
    func incompatibleCachedCourseBlocksWaitForExplicitRecoveryBeforeEditing(source: String) async throws {
        let files = ModuleScoreFiles()
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/time-table"), userStateMatches: { _, _ in true })
        let account = AppStorageSession(accountIdentifier: "invalid-sections")
        let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "晚间课程", weeksText: "1", selectedSections: [7]),
            to: [], term: "term", id: "course")
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        let slots = Array(TimeSlot.default.prefix(6))
        if source == "shared" {
            cache.sharedSchedules = [.init(id: "shared", title: "分享课表", payload: .init(
                currentTerm: "term", firstDayString: "", timeTable: slots, courses: courses))]
        } else {
            cache.timeTable = slots
            if source == "manual" {
                cache.manualCourseRulesByTerm = ["term": [.init(id: "rule", sourceIdentity: "", sourceCourses: [], replacementCourses: courses)]]
            } else {
                cache.courseData.store(.init(term: "term", firstDayString: "", courses: courses, exams: [], updatedAt: Date()))
            }
        }
        let bytes = try JSONEncoder().encode(cache), url = store.cacheFileURL(for: account.accountStorageIdentifier)
        try files.writeData(bytes, to: url, options: .atomic)
        let repository = ScheduleRepository(session: { account }, load: { await store.load(for: $0) }, save: { cache, source, _ in
            guard await store.write(cache, accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: source, expectedUpdatedAt: nil) != nil
            else { throw CocoaError(.fileWriteUnknown) }
        })
        await repository.loadIfNeeded()
        #expect(!repository.isWritable && repository.requiresRecoveryConfirmation)
        #expect(await store.load(for: account).cacheIfReadable?.isValidForPersistence == true)
        #expect(try files.readData(at: url) == bytes)
        await repository.confirmRecovery()
        #expect(repository.isWritable && !repository.requiresRecoveryConfirmation)
        #expect(try files.readData(at: url) != bytes)
    }

    @Test(.timeLimit(.minutes(1))) func theDayBoundaryHasOneContractAndShrinkingRetainsCourseData() async throws {
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
