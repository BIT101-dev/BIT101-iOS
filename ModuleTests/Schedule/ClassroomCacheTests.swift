import BIT101TestSupport
import Foundation
import ScheduleDomain
import SchedulePorts
import SchedulePersistence
import StorageCore
import Testing
@testable import ScheduleFeature

@MainActor
struct ClassroomCacheTests {
    private final class Service: ScheduleClassroomServicing {
        var queries: [String] = []
        var buildingQueries: [String?] = []
        var error: Error?
        var buildingSuffix = "1"
        func fetchCurrentTermOnly() async throws -> String { "term" }
        func prepareTeachingCenterAccess() async throws {}
        func fetchCampuses() async throws -> [CampusRecord] {
            [CampusRecord(id: "a", name: "校区A", code: "a"), CampusRecord(id: "b", name: "校区B", code: "b")]
        }
        func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
            buildingQueries.append(campusCode)
            let campus = campusCode ?? "a"
            return [BuildingRecord(id: campus, name: "教学楼", buildingCode: campus + buildingSuffix, campusName: "校区", campusCode: campus)]
        }
        func fetchClassrooms(buildingID: String, term: String, date: Date) async throws -> [ClassroomRecord] {
            queries.append(buildingID)
            if let error { throw error }
            return [ClassroomRecord(id: buildingID + "-room", name: "101", busyTimeCodes: [1])]
        }
    }

    private func initialCache() -> ScheduleCache {
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        cache.selectedCampusCode = "a"
        cache.selectedBuildingID = "a1"
        cache.timeTable = [TimeSlot(id: 1, start: "08:00", end: "09:00")]
        cache.selectedClassroomSectionIDs = []
        cache.isClassroomSectionFilterCustomized = true
        return cache
    }

    @Test(.timeLimit(.minutes(1)))
    func dailyEntryReusesResultsAndKeepsMinuteFilteringLocal() async throws {
        var now = try #require(ScheduleDateCodec.parseDate("2026-09-07")).addingTimeInterval(7 * 3600 + 59 * 60)
        let initial = initialCache(), service = Service()
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "daily-classroom") },
            load: { _ in .loaded(initial) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let model = ScheduleClassroomViewModel(service: service, repository: repository, now: { now })
        await model.refreshClassroomPage(force: false)
        #expect(model.classroomAvailabilities.map(\.id) == ["a1-room"])
        now = now.addingTimeInterval(60)
        await model.refreshClassroomPage(force: false)
        #expect(model.classroomAvailabilities.isEmpty)
        #expect(service.queries == ["a1"] && service.buildingQueries.count == 1)
        await model.refreshClassroomPage()
        #expect(service.queries == ["a1", "a1"])
    }

    @Test(.timeLimit(.minutes(1)))
    func readOnlyScheduleStorageKeepsClassroomSelectionAvailable() async throws {
        let service = Service()
        var writes = 0
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "readonly-classroom") },
            load: { _ in .unreadable }, save: { _, _, _ in writes += 1 })
        await repository.loadIfNeeded()
        let now = try #require(ScheduleDateCodec.parseDate("2026-09-07")).addingTimeInterval(7 * 3600)
        let model = ScheduleClassroomViewModel(service: service, repository: repository, now: { now })
        model.setSelectedClassroomSectionIDs([])
        await model.refreshClassroomPage(force: false)
        await model.selectCampus(code: "b")?.value
        #expect(service.buildingQueries == ["a", "b"] && service.queries == ["a1", "b1"])
        #expect(model.classroomAvailabilities.map(\.id) == ["b1-room"] && writes == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func persistedQueriesSurviveRelaunchAndRefreshAtSchoolMidnight() async throws {
        var now = try #require(ScheduleDateCodec.parseDate("2026-09-07")).addingTimeInterval(24 * 3600 - 60)
        var disk = try JSONEncoder().encode(initialCache())
        let service = Service()
        func open() async throws -> (ScheduleRepository, ScheduleClassroomViewModel) {
            let initial = try JSONDecoder().decode(ScheduleCache.self, from: disk)
            let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "relaunch-classroom") },
                load: { _ in .loaded(initial) }, save: { value, _, _ in disk = try JSONEncoder().encode(value) })
            await repository.loadIfNeeded()
            return (repository, ScheduleClassroomViewModel(service: service, repository: repository, now: { now }))
        }
        let (repository, model) = try await open()
        await model.refreshClassroomPage(force: false)
        #expect(await repository.persistAndWait())
        let (_, reopened) = try await open()
        await reopened.refreshClassroomPage(force: false)
        #expect(service.queries == ["a1"] && service.buildingQueries == ["a"])
        #expect(reopened.classroomLastUpdatedAt == now)
        now = now.addingTimeInterval(60)
        await reopened.refreshClassroomPage(force: false)
        await reopened.refreshClassroomPage(force: false)
        #expect(service.queries == ["a1", "a1"] && service.buildingQueries == ["a", "a"])
        #expect(reopened.classroomLastUpdatedAt == now && !reopened.hasExpiredClassroomData(at: now))
    }

    @Test(.timeLimit(.minutes(1)))
    func failedRefreshRetainsResultsAndManualRetryRecovers() async throws {
        var now = try #require(ScheduleDateCodec.parseDate("2026-09-07")).addingTimeInterval(7 * 3600)
        let initial = initialCache(), service = Service()
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "failed-classroom") },
            load: { _ in .loaded(initial) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let model = ScheduleClassroomViewModel(service: service, repository: repository, now: { now })
        await model.refreshClassroomPage(force: false)
        let successfulUpdate = model.classroomLastUpdatedAt
        service.error = ScheduleServiceError.teachingCenterSessionExpired
        now = now.addingTimeInterval(60)
        await model.refreshClassroomPage()
        await model.refreshClassroomPage(force: false)
        #expect(service.queries == ["a1", "a1"] && model.notice != nil)
        #expect(model.classroomAvailabilities.map(\.id) == ["a1-room"])
        #expect(model.classroomLastUpdatedAt == successfulUpdate)
        service.error = nil
        await model.refreshClassroomPage()
        #expect(service.queries == ["a1", "a1", "a1"] && model.classroomLastUpdatedAt == now)
        await model.selectCampus(code: "b")?.value
        await model.selectCampus(code: "a")?.value
        #expect(service.queries == ["a1", "a1", "a1", "b1"] && service.buildingQueries == ["a", "b"])
        #expect(model.classroomAvailabilities.map(\.id) == ["a1-room"])
    }

    @Test(.timeLimit(.minutes(1)))
    func initialFailureWaitsForExplicitRetryAndChangedBuildingKeepsItsOwnResults() async throws {
        var now = try #require(ScheduleDateCodec.parseDate("2026-09-07")).addingTimeInterval(7 * 3600)
        let initial = initialCache(), service = Service()
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "initial-failure-classroom") },
            load: { _ in .loaded(initial) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let model = ScheduleClassroomViewModel(service: service, repository: repository, now: { now })
        service.error = ScheduleServiceError.teachingCenterSessionExpired
        await model.refreshClassroomPage(force: false)
        await model.refreshClassroomPage(force: false)
        #expect(service.queries == ["a1"] && model.classroomLastUpdatedAt == nil)
        service.error = nil
        await model.refreshClassroomPage()
        #expect(model.classroomAvailabilities.map(\.id) == ["a1-room"])
        now = now.addingTimeInterval(24 * 3600)
        service.buildingSuffix = "2"
        service.error = ScheduleServiceError.teachingCenterSessionExpired
        await model.refreshClassroomPage(force: false)
        #expect(model.selectedBuildingID == "a2" && service.queries == ["a1", "a1", "a2"])
        #expect(model.classroomAvailabilities.isEmpty && model.classroomLastUpdatedAt == nil)
    }

    @Test func earlierCacheWithoutDailyFieldsDecodes() throws {
        let expected = initialCache()
        let bytes = try JSONEncoder().encode(expected)
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: bytes)
        #expect(restored.classroomData == expected.classroomData)
        #expect(restored.classroomData.classroomRefreshDay == nil)
        #expect(restored.classroomData.cachedClassroomQueriesByBuildingID == nil)
    }

    @Test(.timeLimit(.minutes(1))) func damagedClassroomQueryPreservesPersonalSchedulesAndOtherBuildings() async throws {
        var cache = initialCache()
        cache.customSchedules = [CustomScheduleRecord(id: "personal", title: "活动", subtitle: "", description: "",
            dateString: "2026-09-07", beginTime: "12:00", endTime: "13:00")]
        let date = try #require(ScheduleDateCodec.parseDate("2026-09-07"))
        let room = ClassroomRecord(id: "a1-room", name: "101", busyTimeCodes: [1])
        let valid = ClassroomQueryCache(term: "term", queryDate: date, attemptedAt: date, updatedAt: date, records: [room])
        var invalid = valid
        invalid.records = [ClassroomRecord(id: "a2-room", name: "102", busyTimeCodes: [0])]
        cache.classroomData.cachedClassroomQueriesByBuildingID = ["a1": valid, "a2": invalid]
        let bytes = try JSONEncoder().encode(cache)
        let files = ModuleScoreFiles(), account = AppStorageSession(accountIdentifier: "damaged-classroom")
        let store = SchedulePersistenceStore(files: files, storageRoot: URL(fileURLWithPath: "/damaged-classroom"),
            userStateMatches: { _, _ in true })
        let url = store.cacheFileURL(for: account.accountStorageIdentifier)
        try files.writeData(bytes, to: url, options: .atomic)
        let result = await store.load(for: account)
        let restored = try #require(result.cacheIfReadable)
        #expect(result.isRecovered && restored.customSchedules == cache.customSchedules)
        #expect(restored.classroomData.cachedClassroomQueriesByBuildingID == ["a1": valid])
        #expect(try files.readData(at: url) == bytes)
    }
}
