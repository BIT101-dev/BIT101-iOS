import BIT101TestSupport
import SchedulePorts
import ClientCore
import Foundation
import ScheduleDomain
@testable import ScheduleFeature
import SchedulePersistence
import StorageCore
import Testing

@MainActor
struct SchedulePersistenceTests {
    private func store(files: ModuleScoreFiles, root: String = "/schedule") -> SchedulePersistenceStore {
        SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: root), userStateMatches: { $0.primaryScheduleTitle == $1.primaryScheduleTitle })
    }

    @Test func independentStoresOwnTheirPathsAndAccounts() async throws {
        let files = ModuleScoreFiles()
        let first = store(files: files, root: "/first")
        let second = store(files: files, root: "/second")
        let account = AppStorageSession(accountIdentifier: "account")
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = "first"
        let saved = await first.write(cache, accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil)
        #expect(saved?.primaryScheduleTitle == "first")
        #expect(await first.load(for: account).cacheIfReadable?.primaryScheduleTitle == "first")
        #expect(await second.load(for: account).cacheIfReadable?.primaryScheduleTitle == "课表")
        #expect(await first.load(for: AppStorageSession(accountIdentifier: "other")).cacheIfReadable?.primaryScheduleTitle == "课表")
    }

    @Test func preciseDiskVersionsRoundTripAndRejectAnEarlierCompareToken() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "precise-versions")
        var initial = ScheduleCache()
        initial.updatedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let first = try #require(await persistence.write(initial, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil))
        #expect(await persistence.load(for: account).cacheIfReadable?.updatedAt == first.updatedAt)
        var edit = first
        edit.primaryScheduleTitle = "second"
        let second = try #require(await persistence.write(edit, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: first.updatedAt))
        #expect(second.updatedAt > first.updatedAt)
        #expect(await persistence.load(for: account).cacheIfReadable?.updatedAt == second.updatedAt)
        #expect(await persistence.write(initial, accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .cloud, expectedUpdatedAt: first.updatedAt) == nil)
        #expect(await persistence.load(for: account).cacheIfReadable?.primaryScheduleTitle == "second")
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        #expect(SchedulePersistenceStore.decodeCache(try legacyEncoder.encode(initial)).cacheIfReadable?.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func malformedAggregateSectionsPreserveTheCompleteDiskTransaction() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "malformed-sections")
        let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
        for key in ["courses", "cachedCoursesByTerm", "ddlEvents", "customSchedules", "selectedClassroomSectionIDs", "timeTable"] {
            let bytes = try JSONSerialization.data(withJSONObject: ["primaryScheduleTitle": "retained", key: "malformed"])
            try files.writeData(bytes, to: url, options: [])
            #expect(await persistence.load(for: account).isUnreadable)
            #expect(await persistence.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier,
                legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
            #expect(try files.readData(at: url) == bytes)
        }
    }

    @Test func corruptedSourceKeepsItsBytesAndWriteGate() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "corrupt")
        let url = persistence.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = Data("corrupt-source".utf8)
        try files.writeData(bytes, to: url, options: [])
        #expect(await persistence.load(for: account).isUnreadable)
        #expect(await persistence.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test func failedWritesReturnFailureAndPreserveTheStoredVersion() async throws {
        let files = ModuleScoreFiles()
        let persistence = store(files: files)
        let account = AppStorageSession(accountIdentifier: "write-failure")
        let initial = ScheduleCache()
        #expect(await persistence.write(initial, accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) != nil)
        files.setFailures(writing: true)
        var update = initial
        update.primaryScheduleTitle = "edited"
        #expect(await persistence.write(update, accountIdentifier: account.accountStorageIdentifier, legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        #expect(await persistence.load(for: account).cacheIfReadable?.primaryScheduleTitle == initial.primaryScheduleTitle)
    }

    @Test func repositoryReportsSaveFailureAndPreservesEdits() async {
        let account = AppStorageSession(accountIdentifier: "repository")
        let repository = ScheduleRepository(session: { account }, load: { _ in .missing }, save: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "edited"
        #expect(await repository.persistAndWait() == false)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "edited")
        #expect(repository.notice?.title == "日程保存失败")
    }

    @Test func ddlSuccessWaitsForPersistence() async {
        let account = AppStorageSession(accountIdentifier: "ddl")
        let repository = ScheduleRepository(session: { account }, load: { _ in .missing }, save: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        await repository.loadIfNeeded()
        let viewModel = ScheduleDDLViewModel(service: DDLService(), repository: repository)
        #expect(await viewModel.syncDDL() == false)
        #expect(viewModel.notice == nil)
        #expect(repository.notice?.title == "日程保存失败")
    }

    private final class DelayedWriter {
        var stored: ScheduleCache?
        var writes: [(String, AppStorageSession)] = []
        var failsFirstWrite = false
        private var started: CheckedContinuation<Void, Never>?
        private var completion: CheckedContinuation<Void, Never>?

        func save(_ cache: ScheduleCache, session: AppStorageSession) async throws {
            writes.append((cache.primaryScheduleTitle, session))
            if writes.count == 1 {
                await withCheckedContinuation { completion = $0; started?.resume(); started = nil }
                if failsFirstWrite { throw CocoaError(.fileWriteNoPermission) }
            }
            stored = cache
            stored?.updatedAt = Date(timeIntervalSince1970: Double(writes.count))
        }

        func waitUntilStarted() async {
            if completion != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finishFirstWrite() { completion?.resume(); completion = nil }
    }

    private func repository(writer: DelayedWriter, session: @escaping () -> AppStorageSession) -> ScheduleRepository {
        ScheduleRepository(session: session, load: { _ in writer.stored.map(ScheduleCacheLoadResult.loaded) ?? .missing }, save: { cache, _, session in try await writer.save(cache, session: session) })
    }

    @Test func queuedWritesPreserveOrderAndReloadTheCommittedVersion() async {
        let account = AppStorageSession(accountIdentifier: "queued")
        let writer = DelayedWriter()
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "first"
        repository.persist()
        await writer.waitUntilStarted()
        await repository.reload()
        repository.courseState.primaryScheduleTitle = "second"
        repository.persist()
        writer.finishFirstWrite()
        #expect(await repository.persistAndWait())
        #expect(writer.writes.map(\.0) == ["first", "second", "second"])
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "second")
        #expect(repository.persistenceSnapshot.updatedAt == Date(timeIntervalSince1970: 3))
    }

    @Test func editsMadeDuringSavingRemainInMemory() async {
        let account = AppStorageSession(accountIdentifier: "editing")
        let writer = DelayedWriter()
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "saved"
        let saving = Task { await repository.persistAndWait() }
        await writer.waitUntilStarted()
        await repository.reload()
        repository.courseState.primaryScheduleTitle = "editing"
        writer.finishFirstWrite()
        #expect(await saving.value)
        #expect(writer.stored?.primaryScheduleTitle == "saved")
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "editing")
    }

    @Test func cancelledWaiterKeepsCommittedDataAndReturnsCancellationOutcome() async {
        let account = AppStorageSession(accountIdentifier: "cancelled-waiter")
        let writer = DelayedWriter()
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "committed-edit"
        let saving = Task { await repository.persistAndWait() }
        await writer.waitUntilStarted()
        saving.cancel()
        writer.finishFirstWrite()
        #expect(await saving.value == false)
        #expect(writer.stored?.primaryScheduleTitle == "committed-edit")
        #expect(repository.notice == nil)
    }

    @Test func oldAccountFailuresAndQueuedWritesStayWithTheirOwner() async {
        var account = AppStorageSession(accountIdentifier: "old")
        let writer = DelayedWriter()
        writer.failsFirstWrite = true
        let repository = repository(writer: writer, session: { account })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "old-edit"
        let saving = Task { await repository.persistAndWait() }
        await writer.waitUntilStarted()
        repository.persist()
        account = AppStorageSession(accountIdentifier: "current")
        repository.resetForCurrentAccount()
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "current-edit"
        writer.finishFirstWrite()
        #expect(await saving.value == false)
        #expect(await repository.persistAndWait())
        #expect(writer.writes.map(\.0) == ["old-edit", "current-edit"])
        #expect(writer.writes.last?.1 == account)
        #expect(repository.notice == nil)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "current-edit")
    }

    private struct DDLService: ScheduleDDLServicing {
        func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> DDLSyncPayload {
            DDLSyncPayload(url: "https://example.invalid/calendar", events: [])
        }
        func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { "https://example.invalid/calendar" }
    }
}

@MainActor
struct SchedulePersistenceCoordinatorTests {
    @Test func queuedSavesValidateTheGenerationAcrossAccountRoundTrips() async {
        let coordinator = SchedulePersistenceCoordinator()
        var generation = 1
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var writes: [Int] = []
        let first = Task { await coordinator.perform(isCurrent: { true }) {
            started = true
            await withCheckedContinuation { release = $0 }
            writes.append(1)
            return true
        } }
        while !started { await Task.yield() }
        let oldGeneration = generation
        let queued = Task { await coordinator.perform(isCurrent: { generation == oldGeneration }) {
            writes.append(2)
            return true
        } }
        await Task.yield()
        generation = 3
        release?.resume()
        #expect(await first.value)
        #expect(await queued.value == false)
        #expect(writes == [1])
        #expect(await coordinator.perform(isCurrent: { generation == 3 }) {
            writes.append(3)
            return true
        })
        #expect(writes == [1, 3])
    }

    @Test func cancellationRetainsTheCommittedWriteAndSkipsQueuedWork() async {
        let coordinator = SchedulePersistenceCoordinator()
        var started = false
        var release: CheckedContinuation<Void, Never>?
        var writes: [Int] = []
        let saving = Task { await coordinator.perform(isCurrent: { true }) {
            started = true
            await withCheckedContinuation { release = $0 }
            writes.append(1)
            return true
        } }
        while !started { await Task.yield() }
        let queued = Task { await coordinator.perform(isCurrent: { true }) {
            writes.append(2)
            return true
        } }
        await Task.yield()
        queued.cancel()
        saving.cancel()
        release?.resume()
        #expect(await saving.value == false)
        #expect(await queued.value == false)
        #expect(writes == [1])
        #expect(await coordinator.perform(isCurrent: { true }) { writes.append(3); return true })
        #expect(writes == [1, 3])
    }
}

@MainActor
struct ScheduleSchemaAndEditingTests {
    private func course(id: String = "school", weekday: Int = 1, weeks: String = "1-4") throws -> CourseRecord {
        try #require(ScheduleCourseEditor.adding(
            CourseDraft(title: "课程", classroom: "文萃楼I203", weekday: weekday,
                startSection: 1, endSection: 2, weeksText: weeks),
            to: [], term: "2026-2027-1", id: id
        ).first)
    }

    private func snapshot(_ courses: [CourseRecord], term: String = "2026-2027-1") -> TermScheduleSnapshot {
        TermScheduleSnapshot(term: term, firstDayString: "2026-09-07", courses: courses,
            exams: [], updatedAt: Date(timeIntervalSince1970: 100))
    }

    @Test func versionedDiskUsesOneSchoolAuthorityAndDerivedPresentation() throws {
        let original = try course()
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courseData.store(snapshot([original]))
        let edited = try ScheduleCourseEditor.updatingOccurrence(id: original.id, week: 2,
            with: CourseDraft(title: "调课", weekday: 3, startSection: 3, endSection: 4), in: cache.courses,
            adjustedID: "adjusted")
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: cache.courses, currentCourses: edited)
        let bytes = try JSONEncoder().encode(cache)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == ScheduleCache.schemaVersion)
        for key in ["courses", "cachedCoursesByTerm", "schoolCoursesByTerm", "termSchedulesByTerm", "firstDayString", "exams"] {
            #expect(object[key] == nil)
        }
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: bytes)
        #expect(restored.courses == edited)
        #expect(restored.courseData.schoolCourses(for: original.term) == [original])
        #expect(restored.coursesUpdatedAt == Date(timeIntervalSince1970: 100))
        #expect(restored.termSchedulesByTerm[original.term]?.courses == [original])
    }

    @Test func flatMigrationChoosesSchoolBaselineAndPreservesOtherSections() throws {
        let original = try course()
        let obsolete = try course(id: "obsolete", weekday: 4)
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        let object: [String: Any] = [
            "storedCourseScheduleParserVersion": 2, "currentTerm": original.term,
            "firstDayString": "2026-09-07", "courses": try json([obsolete]),
            "cachedCoursesByTerm": try json([original.term: [obsolete]]),
            "schoolCoursesByTerm": try json([original.term: [original]]),
            "termSchedulesByTerm": try json([original.term: snapshot([obsolete])]),
            "primaryScheduleTitle": "  标题  ", "ddlBeforeDay": 12, "selectedBuildingID": "building",
            "courseLiveActivityLeadMinutes": 100, "cloudSyncBaselineRecordTag": "tag"
        ]
        let cache = try JSONDecoder().decode(ScheduleCache.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(cache.courses == [original])
        #expect(cache.cachedCoursesByTerm[original.term] == [original])
        #expect(cache.termSchedulesByTerm[original.term]?.courses == [original])
        #expect(cache.primaryScheduleTitle == "标题")
        #expect(cache.ddlData.ddlBeforeDay == 12)
        #expect(cache.classroomData.selectedBuildingID == "building")
        #expect(cache.presentation.courseLiveActivityLeadMinutes == 60)
        #expect(cache.syncData.cloudSyncBaselineRecordTag == "tag")
        let roundTrip = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(roundTrip.courseData == cache.courseData)
    }

    @Test func historicalCourseSummariesMigrateAndArchiveWithoutLosingGradeMatching() throws {
        let original = try course()
        let encoder = JSONEncoder()
        let map = try JSONSerialization.jsonObject(with: encoder.encode(["past": [original]]))
        let bytes = try JSONSerialization.data(withJSONObject: ["cachedCoursesByTerm": map])
        var cache = try JSONDecoder().decode(ScheduleCache.self, from: bytes)
        #expect(cache.courseData.archivedTerms == ["past"])
        #expect(cache.cachedCoursesByTerm["past"] == [original])
        #expect(cache.termSchedulesByTerm.isEmpty)
        cache.courseData.store(snapshot([original]))
        cache.currentTerm = original.term
        cache.courseData.archive(term: original.term)
        #expect(cache.courses.isEmpty)
        #expect(cache.firstDayString.isEmpty)
        #expect(cache.coursesUpdatedAt == .distantPast)
        #expect(cache.cachedCoursesByTerm[original.term] == [original])
        cache.courseData.store(snapshot([original]))
        #expect(cache.courses == [original])
        #expect(cache.firstDayString == "2026-09-07")
    }

    @Test func datesMigrateForEmptySchedulesAndOverridesStayTermScoped() throws {
        let bytes = Data(#"{"currentTerm":"2026-2027-1","firstDayString":"2026-09-07"}"#.utf8)
        var cache = try JSONDecoder().decode(ScheduleCache.self, from: bytes)
        #expect(cache.firstDayString == "2026-09-07")
        cache.manualFirstDayStringsByTerm[cache.currentTerm] = "2026-09-28"
        cache.currentTerm = "second"
        #expect(cache.firstDayString.isEmpty)
        cache.currentTerm = "2026-2027-1"
        #expect(cache.firstDayString == "2026-09-28")
        cache.manualFirstDayStringsByTerm.removeValue(forKey: cache.currentTerm)
        #expect(cache.firstDayString == "2026-09-07")
    }

    @Test(arguments: ["99", "null", #""future""#, "1"])
    func rejectedSchemasProtectStoredBytesAndWriteAdmission(header: String) async throws {
        let files = ModuleScoreFiles()
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/schedule"), userStateMatches: { _, _ in true })
        let account = AppStorageSession(accountIdentifier: "schema-owner")
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        let bytes = Data("{\"schemaVersion\":\(header),\"currentTerm\":\"retained\"}".utf8)
        try files.writeData(bytes, to: url, options: [])
        #expect(await store.load(for: account).isUnreadable)
        #expect(await store.write(ScheduleCache(), accountIdentifier: account.accountStorageIdentifier,
            legacyAccountIdentifier: account.legacyAccountDirectoryNameForMigration, source: .local, expectedUpdatedAt: nil) == nil)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test func pendingCloudCourseRulesSurviveUntilTheSchoolSnapshotArrives() throws {
        let original = try course()
        let replacement = try ScheduleCourseEditor.updatingArrangement(id: original.id,
            with: CourseDraft(title: "云端调课", weekday: 3, weeksText: "1-4"), in: [original])
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courseData.setRules([ScheduleCourseRule(sourceIdentity: scheduleCourseSourceIdentity(original),
            sourceCourses: [original], replacementCourses: replacement)], for: original.term)
        var restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(restored.manualCourseRulesByTerm[original.term]?.count == 1)
        #expect(restored.courses.isEmpty)
        restored.courseData.store(snapshot([original]))
        #expect(restored.courses == replacement)
        #expect(restored.manualCourseRulesByTerm[original.term]?.count == 1)
        restored.courseData.store(snapshot([]))
        #expect(restored.manualCourseRulesByTerm[original.term] == nil)
        #expect(restored.courses.isEmpty)
    }

    @Test func changedSchoolSourceRetiresAdjustmentAndKeepsLocalAddition() throws {
        let original = try course()
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courseData.store(snapshot([original]))
        let moved = try ScheduleCourseEditor.updatingArrangement(id: original.id,
            with: CourseDraft(title: "修改课程", weekday: 2, weeksText: "1-4"), in: cache.courses)
        let withAddition = try ScheduleCourseEditor.adding(CourseDraft(title: "个人课程", weekday: 4, weeksText: "1"),
            to: moved, term: original.term, id: "local")
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: cache.courses, currentCourses: withAddition)
        #expect(cache.manualCourseRulesByTerm[original.term]?.count == 2)
        let refreshed = try course(weekday: 5)
        cache.courseData.store(snapshot([refreshed]))
        #expect(cache.courses.map(\.id) == ["school", "local"])
        #expect(cache.courses.first?.weekday == 5)
        #expect(cache.manualCourseRulesByTerm[original.term]?.count == 1)
    }

    @Test func transferringAndDeletingOccurrencesPreserveTheOriginalSchoolSnapshot() throws {
        let original = try course()
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courseData.store(snapshot([original]))
        let transferred = ScheduleCourseEditor.transferring(courses: cache.courses,
            fromWeek: 2, fromWeekday: 1, toWeek: 3, toWeekday: 4, makeID: { "moved" })
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: cache.courses, currentCourses: transferred)
        #expect(cache.courses.first?.weeks == [1, 3, 4])
        #expect(cache.courses.last?.weeks == [3])
        #expect(cache.courses.last?.weekday == 4)
        let deleted = ScheduleCourseEditor.deletingOccurrence(id: "moved", week: 3, from: cache.courses)
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: cache.courses, currentCourses: deleted)
        #expect(cache.courses.count == 1)
        #expect(cache.courseData.schoolCourses(for: original.term) == [original])
        #expect(ScheduleCourseEditor.transferring(courses: deleted, fromWeek: 1, fromWeekday: 1, toWeek: 1, toWeekday: 1) == deleted)
        #expect(ScheduleCourseEditor.deletingOccurrence(id: "missing", week: 1, from: deleted) == deleted)
    }

    @Test func editingValidationAndConflictBoundaries() throws {
        let resolved = try ScheduleCourseEditor.resolve(CourseDraft(title: "  标题  ", buildingName: "文萃楼", roomNumber: "I203",
            weeksText: "-2--1,1-3,3", selectedSections: [3, 2, 2, 1]))
        #expect(resolved.title == "标题")
        #expect(resolved.classroom == "文萃楼 I203")
        #expect(resolved.weeks == [-2, -1, 1, 2, 3])
        #expect(resolved.startSection == 1)
        #expect(resolved.endSection == 3)
        for draft in [CourseDraft(title: " ", weeksText: "1"), CourseDraft(title: "课程", weekday: 8, weeksText: "1"),
            CourseDraft(title: "课程", weeksText: "1", selectedSections: [1, 3])] {
            #expect(throws: Error.self) { try ScheduleCourseEditor.resolve(draft) }
        }
        for weeks in ["", "0", "3-1", "a", "1-0"] {
            #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks(weeks) }
        }
        let original = try course()
        let overlap = try course(id: "overlap")
        #expect(ScheduleCourseEditor.conflictDescription(candidates: [original], against: [overlap])?.contains("发生冲突") == true)
        #expect(ScheduleCourseEditor.conflictDescription(candidates: [original], against: [try course(id: "other", weekday: 2)]) == nil)
        #expect(ScheduleCourseEditor.deleting(id: original.id, from: [original]).isEmpty)
    }
}
