import SchedulePorts
import ClientCore
import Combine
import Foundation
import ScheduleDomain
@testable import ScheduleFeature
import StorageCore
import Testing

@MainActor
struct ScheduleFeatureTests {
    private func makeViewModel(
        repository: ScheduleRepository, actions: any SchedulePlatformActions,
        service: ModuleScheduleService = ModuleScheduleService()
    ) -> ScheduleViewModel {
        return ScheduleViewModel(
            service: service,
            repository: repository,
            ddlService: service,
            classroomService: service,
            platformActions: actions,
            virtualNetworkLikely: { true },
            newCustomScheduleDraft: { CustomScheduleDraft() }
        )
    }

    @Test func courseVerificationFailurePreservesChallengeAndRetryResumesChosenTerm() async throws {
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "verification") },
            load: { _ in .missing }, save: { cache, _, _ in saved = cache })
        await repository.loadIfNeeded()
        let service = ModuleScheduleService()
        service.challenge = BITLoginAuthenticationChallenge(challengeID: "course-verification", accessToken: "token",
            status: "waiting_sms", maskedPhone: "138****0000", expiresIn: 300)
        service.submissionError = .schoolSMSCodeInvalid("验证码错误")
        service.payload = CourseSyncPayload(term: "verified-term", firstDayString: "2026-09-07",
            sourceFirstDayString: "2026-09-07", normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: [])
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions(), service: service)
        await model.syncCourses(term: "verified-term")
        let challenge = try #require(model.smsChallenge)
        await model.submitSMSCode("000000")
        #expect(model.smsChallenge?.challengeID == challenge.challengeID)
        #expect(model.smsVerificationError == "验证码错误")
        #expect(model.courseSyncCoordinator.courseSyncTerm == "verified-term")
        #expect(!model.isSubmittingSMSCode)
        service.submissionError = nil
        await model.submitSMSCode("123456")
        #expect(service.submittedCodes == ["000000", "123456"])
        #expect(model.smsChallenge == nil)
        #expect(model.smsVerificationError == nil)
        #expect(model.courseSyncCoordinator.continuation == nil)
        #expect(saved?.currentTerm == "verified-term")
    }

    @Test func requestsShareOnePhaseAndAccountResetCancelsTheirOwner() async throws {
        var session = AppStorageSession(accountIdentifier: "first")
        let repository = ScheduleRepository(session: { session }, load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = ModuleScheduleService()
        let pending = ModuleCourseRequest()
        service.onSync = { _ in try await pending.run() }
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions(), service: service)
        let request = Task { await model.syncCourses(term: "first-term") }
        await pending.waitUntilStarted()
        #expect(model.isSyncingCourses)
        await model.loadAvailableTerms()
        #expect(service.termRequests == 0)
        session = AppStorageSession(accountIdentifier: "second")
        model.resetForCurrentAccount()
        service.onSync = nil
        service.challenge = BITLoginAuthenticationChallenge(challengeID: "new-account", accessToken: "token",
            status: "waiting_sms", maskedPhone: "138****0000", expiresIn: 300)
        await model.syncCourses(term: "second-term")
        pending.response?.resume(returning: CourseSyncPayload(term: "first-term", firstDayString: "",
            sourceFirstDayString: "", normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: []))
        await request.value
        #expect(pending.wasCancelled)
        #expect(model.smsChallenge?.challengeID == "new-account")
        #expect(model.courseSyncCoordinator.courseSyncTerm == "second-term")
        #expect(model.persistenceSnapshot.currentTerm != "first-term")
        #expect(model.isSyncingCourses == false)
    }

    @Test func cancellingTheCallerReleasesItsRequestPhase() async {
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "cancel") },
            load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = ModuleScheduleService()
        let pending = ModuleCourseRequest()
        service.onSync = { _ in try await pending.run() }
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions(), service: service)
        let request = Task { await model.syncCourses() }
        await pending.waitUntilStarted()
        request.cancel()
        pending.response?.resume(throwing: CancellationError())
        await request.value
        #expect(pending.wasCancelled)
        #expect(model.isSyncingCourses == false)
        #expect(model.smsChallenge == nil)
        #expect(model.notice == nil)
        await model.loadAvailableTerms()
        #expect(service.termRequests == 1)
        #expect(model.hasLoadedAvailableTerms)
    }

    @Test func publicAssemblyOwnsOneRepositoryAcrossAllSubscenes() async {
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "assembly") },
                                            load: { _ in .missing }, save: { _, _, _ in })
        let viewModel = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions())
        #expect(viewModel.ddl.repository === repository)
        #expect(viewModel.classroom.repository === repository)
        await repository.loadIfNeeded()
        let generation = repository.accountGeneration
        viewModel.resetForCurrentAccount()
        #expect(repository.accountGeneration == generation + 1)
        #expect(viewModel.ddl.accountGeneration == repository.accountGeneration)
        #expect(viewModel.classroom.accountGeneration == repository.accountGeneration)
    }

    @Test func scopedChangeStreamReloadsItsAccountOwner() async {
        let first = AppStorageSession(accountIdentifier: "first")
        let second = AppStorageSession(accountIdentifier: "second")
        let changes = PassthroughSubject<AppStorageSession, Never>()
        var firstLoads = 0
        var secondLoads = 0
        var continuation: CheckedContinuation<Void, Never>?
        let firstRepository = ScheduleRepository(session: { first }, load: { _ in
            firstLoads += 1
            if firstLoads == 2 { continuation?.resume(); continuation = nil }
            return .missing
        }, save: { _, _, _ in }, changes: changes.eraseToAnyPublisher())
        let secondRepository = ScheduleRepository(session: { second }, load: { _ in secondLoads += 1; return .missing },
                                                 save: { _, _, _ in }, changes: changes.eraseToAnyPublisher())
        await firstRepository.loadIfNeeded()
        await secondRepository.loadIfNeeded()
        await withCheckedContinuation { continuation = $0; changes.send(first) }
        #expect(firstLoads == 2)
        #expect(secondLoads == 1)
    }

    @Test func cloudEnableWaitsForTheOwnedSaveAndHonorsSaveFailure() async {
        for saveSucceeds in [true, false] {
            var didSave = false
            var initial = ScheduleCache()
            initial.iCloudSyncEnabled = false
            let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "enable") },
                load: { _ in .loaded(initial) }, save: { _, _, _ in
                    if !saveSucceeds { throw CocoaError(.fileWriteNoPermission) }
                    didSave = true
                })
            await repository.loadIfNeeded()
            let actions = ModuleRecordingSchedulePlatformActions()
            let viewModel = makeViewModel(repository: repository, actions: actions)
            viewModel.setICloudSyncEnabled(true)
            await viewModel.cloudSyncEnableTask?.value
            #expect(didSave == saveSucceeds)
            #expect((actions.cloudSession != nil) == saveSucceeds)
        }
    }

    @Test func calendarCommandsPreserveSelectionAndPropagateErrors() async throws {
        let session = AppStorageSession(accountIdentifier: "feature-test")
        let repository = ScheduleRepository(
            session: { session }, load: { _ in .missing }, save: { _, _, _ in }
        )
        await repository.loadIfNeeded()
        let actions = ModuleSchedulePlatformActions()
        let viewModel = makeViewModel(repository: repository, actions: actions)
        let content = ScheduleSystemCalendarContent.courses([], firstDay: Date(timeIntervalSince1970: 0), timeTable: [])

        #expect(try await viewModel.importSystemCalendarEntries(content, term: "chosen-term") == 2)
        #expect(actions.content == content)
        #expect(actions.term == "chosen-term")
        #expect(try await viewModel.deleteSystemCalendarEntries(content, term: "chosen-term") == .changed(2))
        #expect(try await viewModel.deleteSystemCalendarEntries(markerIDs: ["course-w1"], term: "chosen-term") == .noOp)
        #expect(actions.markerIDs == ["course-w1"])

        actions.error = CancellationError()
        await #expect(throws: CancellationError.self) {
            try await viewModel.importSystemCalendarEntries(content, term: "chosen-term")
        }
        await #expect(throws: CancellationError.self) {
            try await viewModel.deleteSystemCalendarEntries(content, term: "chosen-term")
        }
        await #expect(throws: CancellationError.self) {
            try await viewModel.deleteSystemCalendarEntries(markerIDs: ["course-w1"], term: "chosen-term")
        }
    }

    @Test func sceneWritesPreserveOtherDataAndSettingsProjection() async {
        let session = AppStorageSession(accountIdentifier: "feature-scene-test")
        var initial = ScheduleCache()
        initial.ddlBeforeDay = 3
        initial.selectedBuildingID = "building"
        initial.cloudSyncBaselineRecordTag = "baseline"
        var saved: ScheduleCache?
        let repository = ScheduleRepository(
            session: { session }, load: { _ in .loaded(initial) }, save: { cache, _, _ in saved = cache }
        )
        await repository.loadIfNeeded()
        repository.presentationPreferences.showSaturday = false
        _ = await repository.persistAndWait()

        #expect(saved?.showSaturday == false)
        #expect(saved?.ddlBeforeDay == 3)
        #expect(saved?.selectedBuildingID == "building")
        #expect(saved?.cloudSyncBaselineRecordTag == "baseline")
        #expect(ScheduleSettingsSnapshot(courses: repository.courseState, preferences: repository.presentationPreferences, sync: repository.syncState).showSaturday == false)
    }

    @Test func networkNoticeUsesInjectedPresentationContext() {
        let session = AppStorageSession(accountIdentifier: "feature-notice-test")
        let repository = ScheduleRepository(
            session: { session }, load: { _ in .missing }, save: { _, _, _ in }
        )
        let viewModel = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions())
        let networkNotice = viewModel.schoolFailureNotice(title: "学校请求", message: "请求失败", networkFailure: true)
        #expect(networkNotice.message.contains("先关掉魔法试试"))
        #expect(networkNotice.allowsDiagnostics == false)
        let serviceNotice = viewModel.schoolFailureNotice(title: "学校请求", message: "业务状态")
        #expect(serviceNotice.message == "业务状态")
        #expect(serviceNotice.allowsDiagnostics)
    }
}

@MainActor
private final class ModuleSchedulePlatformActions: SchedulePlatformActions {
    var content: ScheduleSystemCalendarContent?
    var term: String?
    var markerIDs: Set<String>?
    var error: Error?

    func enableCloudSync(session: AppStorageSession) async {}
    func enableCourseReminder(session: AppStorageSession) async {}
    func importSystemCalendar(courses: ScheduleCourseSnapshot, term: String) async throws -> Int { 0 }
    func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult { .noOp }

    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int {
        if let error { throw error }
        self.content = content
        self.term = term
        return 2
    }

    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        if let error { throw error }
        self.content = content
        self.term = term
        return .changed(2)
    }

    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        if let error { throw error }
        self.markerIDs = markerIDs
        self.term = term
        return .noOp
    }
}

@MainActor
private final class ModuleScheduleService: ScheduleServicing {
    var challenge: BITLoginAuthenticationChallenge?
    var submissionError: ScheduleServiceError?
    var payload: CourseSyncPayload?
    var submittedCodes: [String] = []
    var onSync: ((String?) async throws -> CourseSyncPayload)?
    var termRequests = 0

    func syncCourses(term: String?) async throws -> CourseSyncPayload {
        if let onSync { return try await onSync(term) }
        if let challenge { throw ScheduleServiceError.secondFactorRequired(challenge) }
        throw CancellationError()
    }
    func fetchAvailableTerms() async throws -> [String] { termRequests += 1; return [] }
    func submitSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge, term: String?) async throws -> CourseSyncPayload {
        submittedCodes.append(code)
        if let submissionError { throw submissionError }
        if let payload { return payload }
        throw CancellationError()
    }
    func submitSMSCodeForTeachingCenterAuthentication(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws {}
    func fetchCurrentTermOnly() async throws -> String { "test-term" }
    func syncDDLEvents(existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> DDLSyncPayload { throw CancellationError() }
    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { "" }
    func prepareTeachingCenterAccess() async throws {}
    func fetchCampuses() async throws -> [CampusRecord] { [] }
    func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] { [] }
    func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] { [] }
}

@MainActor
struct ScheduleRepositoryBoundaryTests {
    private func makeRepository(
        session: @escaping () -> AppStorageSession = { AppStorageSession(accountIdentifier: "schedule-boundary-tests") },
        load: @escaping (AppStorageSession) async -> ScheduleCacheLoadResult,
        save: @escaping (ScheduleCache, ScheduleCacheSaveSource, AppStorageSession) async throws -> Void
    ) -> ScheduleRepository {
        ScheduleRepository(session: session, load: load, save: save)
    }

    private func makeViewModel(
        service: any ScheduleServicing,
        repository: ScheduleRepository,
        platformActions: any SchedulePlatformActions = ModuleRecordingSchedulePlatformActions(),
        newCustomScheduleDraft: @escaping () -> CustomScheduleDraft = { CustomScheduleDraft() }
    ) -> ScheduleViewModel {
        ScheduleViewModel(
            service: service,
            repository: repository,
            ddlService: service,
            classroomService: service,
            platformActions: platformActions,
            newCustomScheduleDraft: newCustomScheduleDraft
        )
    }

    @Test func staleCourseDataWritePreservesPresentationAndSyncPreferences() async {
        var initial = ScheduleCache()
        initial.cloudSyncBaselineRecordTag = "cloud-tag"
        initial.cloudSyncBaselineAt = Date(timeIntervalSince1970: 100)
        initial.hasUnpushedCloudChanges = true
        let repository = makeRepository(load: { _ in .loaded(initial) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        var course = repository.courseState
        repository.presentationPreferences.showSaturday = false
        repository.presentationPreferences.scheduleDisplayMode = .allWeeks
        repository.syncState.iCloudSyncEnabled = false
        course.primaryScheduleTitle = "场景课表"
        repository.courseState = course
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "场景课表")
        #expect(repository.persistenceSnapshot.showSaturday == false)
        #expect(repository.persistenceSnapshot.scheduleDisplayMode == .allWeeks)
        #expect(repository.persistenceSnapshot.iCloudSyncEnabled == false)
        #expect(repository.syncState.cloudSyncBaselineRecordTag == "cloud-tag")
        #expect(repository.syncState.cloudSyncBaselineAt == initial.cloudSyncBaselineAt)
        #expect(repository.syncState.hasUnpushedCloudChanges)
    }

    @Test func syncPreferenceWritePreservesTheLatestCloudBaseline() async {
        var stored = ScheduleCache()
        stored.cloudSyncBaselineRecordTag = "baseline"
        let repository = makeRepository(load: { _ in .loaded(stored) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        var preference = repository.syncState
        stored.cloudSyncBaselineRecordTag = "cloud-tag"
        stored.cloudSyncBaselineAt = Date(timeIntervalSince1970: 100)
        stored.hasUnpushedCloudChanges = true
        await repository.reload()
        preference.iCloudSyncEnabled = false
        repository.syncState = preference
        #expect(repository.syncState.iCloudSyncEnabled == false)
        #expect(repository.syncState.cloudSyncBaselineRecordTag == "cloud-tag")
        #expect(repository.syncState.cloudSyncBaselineAt == stored.cloudSyncBaselineAt)
        #expect(repository.syncState.hasUnpushedCloudChanges)
    }

    @Test func sceneSubscriptionsSeparatePreferencesAndCloudMetadata() async {
        var stored = ScheduleCache()
        let repository = makeRepository(load: { _ in .loaded(stored) }, save: { _, _, _ in })
        var courseChanges = 0
        var ddlChanges = 0
        var classroomChanges = 0
        let subscriptions = [
            repository.courseChanges.sink { courseChanges += 1 },
            repository.ddlChanges.sink { ddlChanges += 1 },
            repository.classroomChanges.sink { classroomChanges += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }
        await repository.loadIfNeeded()
        #expect(courseChanges == 2)
        #expect(ddlChanges == 2)
        #expect(classroomChanges == 2)
        repository.presentationPreferences.showSaturday = false
        #expect(courseChanges == 3)
        repository.syncState.iCloudSyncEnabled = false
        #expect(courseChanges == 4)
        stored = repository.persistenceSnapshot
        stored.cloudSyncBaselineRecordTag = "cloud-tag"
        stored.hasUnpushedCloudChanges = true
        await repository.reload()
        #expect(courseChanges == 4)
        #expect(ddlChanges == 2)
        #expect(classroomChanges == 2)
    }

    @Test func semesterStartDatePersistsWithinItsAccount() async throws {
        var account = AppStorageSession(accountIdentifier: "semester-account-a")
        var savedCaches: [String: ScheduleCache] = [:]
        let repository = makeRepository(
            session: { account },
            load: { session in
                savedCaches[session.accountIdentifier].map(ScheduleCacheLoadResult.loaded) ?? .missing
            },
            save: { cache, _, session in savedCaches[session.accountIdentifier] = cache }
        )
        await repository.loadIfNeeded()
        let viewModel = makeViewModel(service: ModuleSemesterStartDateService(), repository: repository)
        await viewModel.syncCourses(term: "2026-2027-1")
        let chosenDate = try #require(ScheduleDateCodec.parseDate("2026-09-21"))
        viewModel.setSemesterStartDate(chosenDate)
        _ = await repository.persistAndWait()
        let encoded = try JSONEncoder().encode(viewModel.persistenceSnapshot)
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
        #expect(viewModel.persistenceSnapshot.firstDayString == "2026-09-07")
        #expect(viewModel.persistenceSnapshot.manualFirstDayStringsByTerm.isEmpty)

        account = AppStorageSession(accountIdentifier: "semester-account-a")
        repository.resetForCurrentAccount()
        await repository.loadIfNeeded()
        #expect(viewModel.persistenceSnapshot.firstDayString == "2026-09-21")
    }

    @Test func lateLoadKeepsCurrentAccountData() async throws {
        var account = AppStorageSession(accountIdentifier: "module-account-a")
        let loader = ModuleDeferredScheduleLoad()
        let repository = makeRepository(session: { account }, load: loader.load, save: { _, _, _ in })
        let task = Task { await repository.reload() }
        await loader.waitUntilStarted()
        account = AppStorageSession(accountIdentifier: "module-account-b")
        repository.resetForCurrentAccount()
        repository.courseState.currentTerm = "account-b-term"
        var old = ScheduleCache()
        old.currentTerm = "account-a-term"
        loader.continuation?.resume(returning: .loaded(old))
        await task.value
        #expect(repository.persistenceSnapshot.currentTerm == "account-b-term")
        #expect(repository.isWritable == false)
    }

    @Test func delayedReloadPreservesEditsMadeDuringRead() async {
        let loader = ModuleDeferredScheduleLoad()
        let repository = makeRepository(load: loader.load, save: { _, _, _ in })
        let task = Task { await repository.reload() }
        await loader.waitUntilStarted()
        repository.courseState.primaryScheduleTitle = "本机编辑"
        loader.continuation?.resume(returning: .loaded(ScheduleCache()))
        await task.value
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "本机编辑")
    }

    @Test func unreadableCachePreservesMemoryAndWriteGate() async {
        var savedCount = 0
        let repository = makeRepository(load: { _ in .unreadable }, save: { _, _, _ in savedCount += 1 })
        repository.courseState.primaryScheduleTitle = "保留内容"
        await repository.reload()
        _ = await repository.persistAndWait()
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "保留内容")
        #expect(repository.isWritable == false)
        #expect(repository.notice?.title == "本地课表缓存读取失败")
        #expect(savedCount == 0)
    }

    @Test func persistenceReceivesAccountAndSource() async {
        let account = AppStorageSession(accountIdentifier: "module-account")
        var recordedAccount: AppStorageSession?
        var recordedSource: ScheduleCacheSaveSource?
        var recordedTitle: String?
        let repository = makeRepository(session: { account }, load: { _ in .missing }, save: { cache, source, session in
            recordedTitle = cache.primaryScheduleTitle
            recordedSource = source
            recordedAccount = session
        })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "课程"
        _ = await repository.persistAndWait(source: .cloudBaseline)
        #expect(recordedAccount == account)
        #expect(recordedSource == .cloudBaseline)
        #expect(recordedTitle == "课程")
    }

    @Test func ddlResponseAfterAccountSwitchKeepsNewAccountURL() async {
        let repository = makeRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = ModuleDeferredDDLService()
        let ddl = ScheduleDDLViewModel(service: service, repository: repository)
        let task = Task { await ddl.refreshLexueCalendarURL() }
        await service.waitUntilStarted()
        #expect(ddl.isSyncingDDL)
        repository.resetForCurrentAccount()
        ddl.reset()
        repository.ddlState.lexueCalendarURL = "account-b-calendar"
        service.continuation?.resume(returning: "account-a-calendar")
        await task.value
        #expect(repository.persistenceSnapshot.lexueCalendarURL == "account-b-calendar")
        #expect(ddl.isSyncingDDL == false)
        #expect(ddl.notice == nil)
    }

    @Test func ddlPreferencesUseSharedAccountRepository() async {
        let repository = makeRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let ddl = ScheduleDDLViewModel(service: ModuleDeferredDDLService(), repository: repository)
        ddl.setDDLBeforeDay(12)
        ddl.setDDLAfterDay(4)
        #expect(repository.persistenceSnapshot.ddlBeforeDay == 12)
        #expect(repository.persistenceSnapshot.ddlAfterDay == 4)
        #expect(ddl.beforeDay == 12)
        #expect(ddl.afterDay == 4)
    }

    @Test func sceneWritesPreserveOtherSceneChanges() async {
        let repository = makeRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        repository.courseState.currentTerm = "2026-2027-1"
        var ddl = repository.ddlState
        var classroom = repository.classroomState

        repository.courseState.manualFirstDayStringsByTerm[repository.courseState.currentTerm] = "2026-09-28"
        ddl.ddlBeforeDay = 12
        repository.ddlState = ddl
        classroom.selectedCampusName = "良乡校区"
        classroom.selectedBuildingID = "building"
        repository.classroomState = classroom

        #expect(repository.persistenceSnapshot.currentTerm == "2026-2027-1")
        #expect(repository.persistenceSnapshot.firstDayString == "2026-09-28")
        #expect(repository.persistenceSnapshot.ddlBeforeDay == 12)
        #expect(repository.persistenceSnapshot.selectedCampusName == "良乡校区")
        #expect(repository.persistenceSnapshot.selectedBuildingID == "building")
        repository.resolveCurrentTerm("2025-2026-2")
        #expect(repository.persistenceSnapshot.currentTerm == "2026-2027-1")
    }

    @Test func settingsSnapshotCapturesConfiguration() async throws {
        let repository = makeRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        repository.courseState.currentTerm = "2026-2027-1"
        repository.courseState.manualFirstDayStringsByTerm[repository.courseState.currentTerm] = "2026-09-28"
        repository.courseState.primaryScheduleTitle = "学业"
        repository.courseState.timeTable = [TimeSlot(id: 1, start: "08:00", end: "08:45")]
        repository.courseState.data.store(TermScheduleSnapshot(
            term: repository.persistenceSnapshot.currentTerm, firstDayString: "2026-09-21",
            courses: [], exams: [], updatedAt: .distantPast
        ))
        let viewModel = makeViewModel(
            service: ModuleSemesterStartDateService(), repository: repository,
            platformActions: ModuleRecordingSchedulePlatformActions()
        )
        let snapshot = viewModel.settingsSnapshot
        #expect(snapshot.currentTerm == "2026-2027-1")
        #expect(snapshot.primaryScheduleTitle == "学业")
        #expect(snapshot.firstDay == ScheduleDateCodec.parseDate("2026-09-28"))
        #expect(snapshot.schoolFirstDay == ScheduleDateCodec.parseDate("2026-09-21"))
        #expect(snapshot.timeTableText == "08:00, 08:45")
        #expect(snapshot.hasCourses == false)
        viewModel.setShowSaturday(!snapshot.showSaturday)
        #expect(viewModel.settingsSnapshot.showSaturday != snapshot.showSaturday)
        repository.resetForCurrentAccount()
        #expect(viewModel.settingsSnapshot.currentTerm.isEmpty)
        #expect(snapshot.currentTerm == "2026-2027-1")
    }

    @Test func sharingCommandsUseCurrentScheduleContext() async throws {
        let repository = makeRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        repository.courseState.currentTerm = "2026-2027-1"
        repository.courseState.manualFirstDayStringsByTerm[repository.courseState.currentTerm] = "2026-09-28"
        let courses = try ScheduleCourseEditor.adding(
            CourseDraft(title: "边界课程", classroom: "文萃楼I203", weekday: 1, startSection: 1, endSection: 2, weeksText: "1-2"),
            to: [], term: repository.persistenceSnapshot.currentTerm, id: "boundary-course"
        )
        repository.updateCourses(previousCourses: [], currentCourses: courses)
        let viewModel = makeViewModel(
            service: ModuleSemesterStartDateService(), repository: repository,
            platformActions: ModuleRecordingSchedulePlatformActions()
        )
        let code = try viewModel.exportScheduleCode()
        try viewModel.importScheduleCode(code)
        let shared = try #require(repository.persistenceSnapshot.sharedSchedules.first)
        #expect(shared.courses.first?.name == "边界课程")
        #expect(shared.currentTerm == "2026-2027-1")
        #expect(viewModel.settingsSnapshot.sharedSchedules.first?.id == shared.id)
        #expect(viewModel.settingsSnapshot.sharedSchedules.first?.title == shared.title)
        #expect(viewModel.settingsSnapshot.hasCourses)
    }

    @Test func platformActionsReceiveTheRepositorySessionAfterPersistence() async throws {
        let session = AppStorageSession(accountIdentifier: "platform-account")
        let repository = makeRepository(session: { session }, load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let actions = ModuleRecordingSchedulePlatformActions()
        let viewModel = makeViewModel(service: ModuleSemesterStartDateService(), repository: repository, platformActions: actions)
        viewModel.setICloudSyncEnabled(false)
        viewModel.setICloudSyncEnabled(true)
        viewModel.setShowCourseLiveActivityReminder(true)
        await actions.waitForEnabledActions()
        #expect(actions.cloudSession == session)
        #expect(actions.reminderSession == session)
        #expect(viewModel.settingsSnapshot.iCloudSyncEnabled)
        #expect(try await viewModel.importCurrentTermToSystemCalendar() == 7)
        #expect(actions.importedCourses == viewModel.courseSnapshot)
        #expect(actions.importedTerm == viewModel.persistenceSnapshot.currentTerm)
        #expect(try await viewModel.deleteImportedSystemCalendarEvents() == .changed(3))
        #expect(actions.deleteCount == 1)
        let content = ScheduleSystemCalendarContent.courses([], firstDay: Date(timeIntervalSince1970: 0), timeTable: [])
        #expect(try await viewModel.importSystemCalendarEntries(content, term: "selected-term") == 2)
        #expect(actions.calendarContent == content)
        #expect(actions.calendarTerm == "selected-term")
        #expect(try await viewModel.deleteSystemCalendarEntries(content, term: "selected-term") == .changed(2))
        #expect(try await viewModel.deleteSystemCalendarEntries(markerIDs: ["course-w1"], term: "selected-term") == .noOp)
        #expect(actions.calendarMarkerIDs == ["course-w1"])
        actions.importError = CancellationError()
        await #expect(throws: CancellationError.self) {
            try await viewModel.importCurrentTermToSystemCalendar()
        }
        await #expect(throws: CancellationError.self) {
            try await viewModel.importSystemCalendarEntries(content, term: "selected-term")
        }
        await #expect(throws: CancellationError.self) {
            try await viewModel.deleteSystemCalendarEntries(content, term: "selected-term")
        }
        await #expect(throws: CancellationError.self) {
            try await viewModel.deleteSystemCalendarEntries(markerIDs: ["course-w1"], term: "selected-term")
        }
    }

    @Test func sceneSubscriptionsFollowTheirOwnedFieldsAndQueryContext() async {
        let repository = makeRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        var courseChanges = 0
        var ddlChanges = 0
        var classroomChanges = 0
        let subscriptions = [
            repository.courseChanges.sink { courseChanges += 1 },
            repository.ddlChanges.sink { ddlChanges += 1 },
            repository.classroomChanges.sink { classroomChanges += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        repository.ddlState.ddlBeforeDay = 12
        #expect(courseChanges == 0)
        #expect(ddlChanges == 1)
        #expect(classroomChanges == 0)
        repository.ddlState.ddlBeforeDay = 12
        #expect(ddlChanges == 1)

        repository.courseState.primaryScheduleTitle = "场景课表"
        #expect(courseChanges == 1)
        #expect(ddlChanges == 1)
        #expect(classroomChanges == 0)

        repository.classroomState.selectedBuildingID = "building"
        #expect(courseChanges == 1)
        #expect(ddlChanges == 1)
        #expect(classroomChanges == 1)

        repository.courseState.manualFirstDayStringsByTerm[repository.courseState.currentTerm] = "2026-09-28"
        #expect(courseChanges == 2)
        #expect(ddlChanges == 1)
        #expect(classroomChanges == 2)
    }

    @Test func courseSceneWritePreservesOtherSceneDataAndCloudMetadata() async {
        var initial = ScheduleCache()
        initial.cloudSyncBaselineRecordTag = "cloud-tag"
        initial.cloudSyncBaselineAt = Date(timeIntervalSince1970: 100)
        initial.hasUnpushedCloudChanges = true
        let repository = makeRepository(load: { _ in .loaded(initial) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        var course = repository.courseState
        repository.ddlState.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar"
        repository.ddlState.ddlBeforeDay = 12
        repository.classroomState.selectedBuildingID = "building"
        repository.classroomState.cachedClassroomBuildingsByCampusCode = [
            "campus": [BuildingRecord(id: "building", name: "教学楼", buildingCode: "building", campusName: "良乡", campusCode: "campus")]
        ]
        course.primaryScheduleTitle = "场景课表"
        repository.courseState = course

        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "场景课表")
        #expect(repository.persistenceSnapshot.lexueCalendarURL == "https://lexue.bit.edu.cn/calendar")
        #expect(repository.persistenceSnapshot.ddlBeforeDay == 12)
        #expect(repository.persistenceSnapshot.selectedBuildingID == "building")
        #expect(repository.persistenceSnapshot.cachedClassroomBuildingsByCampusCode["campus"]?.first?.id == "building")
        #expect(repository.persistenceSnapshot.cloudSyncBaselineRecordTag == "cloud-tag")
        #expect(repository.persistenceSnapshot.cloudSyncBaselineAt == initial.cloudSyncBaselineAt)
        #expect(repository.persistenceSnapshot.hasUnpushedCloudChanges)
    }

    @Test func customScheduleDraftUsesTheInjectedFactory() {
        let date = Date(timeIntervalSince1970: 100)
        let draft = CustomScheduleDraft(title: "场景草稿", date: date, beginTime: date, endTime: date.addingTimeInterval(3600))
        let repository = makeRepository(load: { _ in .missing }, save: { _, _, _ in })
        let viewModel = makeViewModel(
            service: ModuleSemesterStartDateService(), repository: repository,
            newCustomScheduleDraft: { draft }
        )
        #expect(viewModel.customScheduleDraft(for: nil) == draft)
    }

}

@MainActor
private final class ModuleRecordingSchedulePlatformActions: SchedulePlatformActions {
    var cloudSession: AppStorageSession?
    var reminderSession: AppStorageSession?
    var importedCourses: ScheduleCourseSnapshot?
    var importedTerm: String?
    var calendarContent: ScheduleSystemCalendarContent?
    var calendarTerm: String?
    var calendarMarkerIDs: Set<String>?
    var deleteCount = 0
    var importError: Error?
    private var enableContinuation: CheckedContinuation<Void, Never>?

    func enableCloudSync(session: AppStorageSession) async {
        cloudSession = session
        finishEnablingIfReady()
    }

    func enableCourseReminder(session: AppStorageSession) async {
        reminderSession = session
        finishEnablingIfReady()
    }

    func importSystemCalendar(courses: ScheduleCourseSnapshot, term: String) async throws -> Int {
        if let importError { throw importError }
        importedCourses = courses
        importedTerm = term
        return 7
    }

    func deleteImportedSystemCalendarEvents() async throws -> ScheduleSystemCalendarMutationResult {
        deleteCount += 1
        return .changed(3)
    }

    func importSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> Int {
        if let importError { throw importError }
        calendarContent = content
        calendarTerm = term
        return 2
    }

    func deleteSystemCalendarEntries(_ content: ScheduleSystemCalendarContent, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        if let importError { throw importError }
        calendarContent = content
        calendarTerm = term
        return .changed(2)
    }

    func deleteSystemCalendarEntries(markerIDs: Set<String>, term: String) async throws -> ScheduleSystemCalendarMutationResult {
        if let importError { throw importError }
        calendarMarkerIDs = markerIDs
        calendarTerm = term
        return .noOp
    }

    func waitForEnabledActions() async {
        guard cloudSession == nil || reminderSession == nil else { return }
        await withCheckedContinuation { enableContinuation = $0 }
    }

    private func finishEnablingIfReady() {
        guard cloudSession != nil, reminderSession != nil else { return }
        enableContinuation?.resume()
        enableContinuation = nil
    }
}

@MainActor
private final class ModuleDeferredScheduleLoad {
    var continuation: CheckedContinuation<ScheduleCacheLoadResult, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    func load(_ session: AppStorageSession) async -> ScheduleCacheLoadResult {
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
private final class ModuleDeferredDDLService: ScheduleDDLServicing {
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
private final class ModuleSemesterStartDateService: ScheduleServicing {
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
private final class ModuleCourseRequest {
    var response: CheckedContinuation<CourseSyncPayload, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false

    func run() async throws -> CourseSyncPayload {
        defer { wasCancelled = Task.isCancelled }
        return try await withCheckedThrowingContinuation {
            response = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if response != nil { return }
        await withCheckedContinuation { started = $0 }
    }
}
