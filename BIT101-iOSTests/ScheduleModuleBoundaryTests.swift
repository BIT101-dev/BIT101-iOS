import ClientCore
import Foundation
import Testing
@testable import BIT101_iOS

@MainActor
private final class DeferredScheduleLoad {
    var continuation: CheckedContinuation<ScheduleCacheStore.LoadResult, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    func load(_ session: AppStorageSession) async -> ScheduleCacheStore.LoadResult {
        await withCheckedContinuation {
            continuation = $0
            startContinuation?.resume()
            startContinuation = nil
        }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
}

@MainActor
private final class DeferredDDLService: ScheduleDDLServicing {
    var continuation: CheckedContinuation<String, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    func syncDDLEvents(
        existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?
    ) async throws -> DDLSyncPayload {
        DDLSyncPayload(url: storedURL, events: existingEvents)
    }

    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String {
        await withCheckedContinuation {
            continuation = $0
            startContinuation?.resume()
            startContinuation = nil
        }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
}

@MainActor
private final class SemesterStartDateService: ScheduleServicing {
    var firstDayString = "2026-09-07"
    var courses: [CourseRecord] = []

    func syncCourses(term: String?) async throws -> CourseSyncPayload {
        CourseSyncPayload(
            term: term ?? "2026-2027-1",
            firstDayString: firstDayString,
            sourceFirstDayString: firstDayString,
            normalizationOffset: 0,
            rawWeeksByCourse: courses.map(\.weeks),
            courses: courses,
            exams: []
        )
    }

    func fetchAvailableTerms() async throws -> [String] { throw ScheduleServiceError.invalidResponse }
    func fetchCurrentTermOnly() async throws -> String { throw ScheduleServiceError.invalidResponse }
    func prepareTeachingCenterAccess() async throws { throw ScheduleServiceError.invalidResponse }
    func fetchCampuses() async throws -> [CampusRecord] { throw ScheduleServiceError.invalidResponse }
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] { throw ScheduleServiceError.invalidResponse }
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] { throw ScheduleServiceError.invalidResponse }
    func submitSMSCode(
        _ code: String, for challenge: BITLoginAuthenticationChallenge, term: String?
    ) async throws -> CourseSyncPayload { throw ScheduleServiceError.invalidResponse }
    func submitSMSCodeForTeachingCenterAuthentication(
        _ code: String, for challenge: BITLoginAuthenticationChallenge
    ) async throws { throw ScheduleServiceError.invalidResponse }
    func syncDDLEvents(
        existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?
    ) async throws -> DDLSyncPayload { throw ScheduleServiceError.invalidResponse }
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String {
        throw ScheduleServiceError.invalidResponse
    }
}

@MainActor
struct ScheduleModuleBoundaryTests {
    @Test func semesterStartDatePreservesCoursesAcrossRefreshAndTermSwitch() async throws {
        let bundle = Bundle(for: ErrorReportAndSchedulePolicyTests.self)
        let fixtureURL = bundle.url(
            forResource: "schedule-service-response", withExtension: "json", subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "schedule-service-response", withExtension: "json")
        let fixture = try #require(fixtureURL)
        let courses = try JSONDecoder().decode(CourseResponse.self, from: Data(contentsOf: fixture)).courseRecords
        let service = SemesterStartDateService()
        service.courses = courses
        let repository = ScheduleRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let viewModel = ScheduleViewModel(service: service, repository: repository)
        let term = "2026-2027-1"

        await viewModel.syncCourses(term: term)
        #expect(viewModel.cache.firstDayString == "2026-09-07")
        #expect(viewModel.cache.manualFirstDayStringsByTerm.isEmpty)
        #expect(viewModel.cache.courses == courses)

        let chosenDate = try #require(ScheduleDateCodec.parseDate("2026-09-23"))
        viewModel.setSemesterStartDate(chosenDate)
        #expect(viewModel.cache.firstDayString == "2026-09-21")
        #expect(viewModel.cache.termSchedulesByTerm[term]?.firstDayString == "2026-09-07")
        #expect(viewModel.cache.courses == courses)
        #expect(viewModel.selectedWeek == viewModel.resolvedAutomaticWeek())

        service.firstDayString = "2026-09-14"
        await viewModel.syncCourses(term: term)
        #expect(viewModel.cache.firstDayString == "2026-09-21")
        #expect(viewModel.cache.termSchedulesByTerm[term]?.firstDayString == "2026-09-14")
        #expect(viewModel.cache.courses == courses)

        await viewModel.syncCourses(term: "2026-2027-2")
        #expect(viewModel.cache.firstDayString == "2026-09-14")
        await viewModel.syncCourses(term: term)
        #expect(viewModel.cache.firstDayString == "2026-09-21")

        viewModel.setSemesterStartDate(nil)
        #expect(viewModel.cache.firstDayString == "2026-09-14")
        #expect(viewModel.cache.manualFirstDayStringsByTerm.isEmpty)
        #expect(viewModel.cache.courses == courses)
    }

    @Test func semesterStartDatePersistsWithinItsAccount() async throws {
        var account = AppStorageSession(accountIdentifier: "semester-account-a")
        var savedCaches: [String: ScheduleCache] = [:]
        let repository = ScheduleRepository(
            session: { account },
            load: { session in
                savedCaches[session.accountIdentifier].map(ScheduleCacheStore.LoadResult.loaded) ?? .missing
            },
            save: { cache, _, session in savedCaches[session.accountIdentifier] = cache }
        )
        await repository.loadIfNeeded()
        let viewModel = ScheduleViewModel(service: SemesterStartDateService(), repository: repository)
        await viewModel.syncCourses(term: "2026-2027-1")
        let chosenDate = try #require(ScheduleDateCodec.parseDate("2026-09-21"))
        viewModel.setSemesterStartDate(chosenDate)
        let encoded = try JSONEncoder().encode(viewModel.cache)
        let decoded = try JSONDecoder().decode(ScheduleCache.self, from: encoded)
        #expect(decoded.firstDayString == "2026-09-21")
        #expect(decoded.manualFirstDayStringsByTerm == ["2026-2027-1": "2026-09-21"])
        #expect(decoded.termSchedulesByTerm["2026-2027-1"]?.firstDayString == "2026-09-07")
        let reloaded = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(decoded))
        #expect(reloaded.firstDayString == decoded.firstDayString)

        account = AppStorageSession(accountIdentifier: "semester-account-b")
        repository.resetForCurrentAccount()
        await repository.loadIfNeeded()
        await viewModel.syncCourses(term: "2026-2027-1")
        #expect(viewModel.cache.firstDayString == "2026-09-07")
        #expect(viewModel.cache.manualFirstDayStringsByTerm.isEmpty)

        account = AppStorageSession(accountIdentifier: "semester-account-a")
        repository.resetForCurrentAccount()
        await repository.loadIfNeeded()
        #expect(viewModel.cache.firstDayString == "2026-09-21")
    }

    @Test func lateLoadKeepsCurrentAccountData() async throws {
        var account = AppStorageSession(accountIdentifier: "module-account-a")
        let loader = DeferredScheduleLoad()
        let repository = ScheduleRepository(session: { account }, load: loader.load, save: { _, _, _ in })
        let task = Task { await repository.reload() }
        await loader.waitUntilStarted()
        account = AppStorageSession(accountIdentifier: "module-account-b")
        repository.resetForCurrentAccount()
        repository.cache.currentTerm = "account-b-term"
        var old = ScheduleCache()
        old.currentTerm = "account-a-term"
        loader.continuation?.resume(returning: .loaded(old))
        await task.value
        #expect(repository.cache.currentTerm == "account-b-term")
        #expect(repository.isWritable == false)
    }

    @Test func delayedReloadPreservesEditsMadeDuringRead() async {
        let loader = DeferredScheduleLoad()
        let repository = ScheduleRepository(load: loader.load, save: { _, _, _ in })
        let task = Task { await repository.reload() }
        await loader.waitUntilStarted()
        repository.cache.primaryScheduleTitle = "本机编辑"
        loader.continuation?.resume(returning: .loaded(ScheduleCache()))
        await task.value
        #expect(repository.cache.primaryScheduleTitle == "本机编辑")
    }

    @Test func unreadableCachePreservesMemoryAndWriteGate() async {
        var savedCount = 0
        let repository = ScheduleRepository(load: { _ in .unreadable }, save: { _, _, _ in savedCount += 1 })
        repository.cache.primaryScheduleTitle = "保留内容"
        await repository.reload()
        repository.persist()
        #expect(repository.cache.primaryScheduleTitle == "保留内容")
        #expect(repository.isWritable == false)
        #expect(repository.notice?.title == "本地课表缓存读取失败")
        #expect(savedCount == 0)
    }

    @Test func persistenceReceivesAccountAndSource() async {
        let account = AppStorageSession(accountIdentifier: "module-account")
        var recordedAccount: AppStorageSession?
        var recordedSource: ScheduleCacheStore.SaveSource?
        var recordedTitle: String?
        let repository = ScheduleRepository(session: { account }, load: { _ in .missing }, save: { cache, source, session in
            recordedTitle = cache.primaryScheduleTitle
            recordedSource = source
            recordedAccount = session
        })
        await repository.loadIfNeeded()
        repository.cache.primaryScheduleTitle = "课程"
        repository.persist(source: .cloudBaseline)
        #expect(recordedAccount == account)
        #expect(recordedSource == .cloudBaseline)
        #expect(recordedTitle == "课程")
    }

    @Test func ddlResponseAfterAccountSwitchKeepsNewAccountURL() async {
        let repository = ScheduleRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = DeferredDDLService()
        let ddl = ScheduleDDLViewModel(service: service, repository: repository)
        let task = Task { await ddl.refreshLexueCalendarURL() }
        await service.waitUntilStarted()
        #expect(ddl.isSyncingDDL)
        repository.resetForCurrentAccount()
        ddl.reset()
        repository.cache.lexueCalendarURL = "account-b-calendar"
        service.continuation?.resume(returning: "account-a-calendar")
        await task.value
        #expect(repository.cache.lexueCalendarURL == "account-b-calendar")
        #expect(ddl.isSyncingDDL == false)
        #expect(ddl.notice == nil)
    }

    @Test func ddlPreferencesUseSharedAccountRepository() async {
        let repository = ScheduleRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let ddl = ScheduleDDLViewModel(service: DeferredDDLService(), repository: repository)
        ddl.setDDLBeforeDay(12)
        ddl.setDDLAfterDay(4)
        #expect(repository.cache.ddlBeforeDay == 12)
        #expect(repository.cache.ddlAfterDay == 4)
        #expect(ddl.beforeDay == 12)
        #expect(ddl.afterDay == 4)
    }
}
