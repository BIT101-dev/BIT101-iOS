import BIT101TestSupport
import SchedulePorts
import ClientCore
import Combine
import Foundation
import ScheduleDomain
@testable import ScheduleFeature
import StorageCore
import Testing

@MainActor
struct ScheduleRepositoryBoundaryTests {
    private final class ClockClassroomService: ScheduleClassroomServicing {
        var campusRequests: [String?] = []
        var classroomDates: [Date] = []
        func fetchCurrentTermOnly() async throws -> String { "test-term" }
        func prepareTeachingCenterAccess() async throws {}
        func fetchCampuses() async throws -> [CampusRecord] {
            [CampusRecord(id: "A", name: "校区A", code: "A"), CampusRecord(id: "B", name: "校区B", code: "B")]
        }
        func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] {
            campusRequests.append(campusCode)
            let code = campusCode ?? ""
            return [BuildingRecord(id: "fallback", name: "默认楼", buildingCode: "fallback", campusName: "校区" + code, campusCode: code),
                BuildingRecord(id: code, name: code + "楼", buildingCode: code, campusName: "校区" + code, campusCode: code)]
        }
        func fetchClassrooms(buildingID: String, term: String, date: Date) async throws -> [ClassroomRecord] {
            classroomDates.append(date)
            return []
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [7, 10])
    func classroomDefaultsFollowTheInjectedCourseClock(hour: Int) async throws {
        let firstDay = try #require(ScheduleDateCodec.parseDate("2001-01-01"))
        let courses = ["B", "A"].enumerated().map { index, code in
            CourseRecord(id: code, term: "test-term", name: code, teacher: "", classroom: code + "楼101", description: "",
                weeks: [1], weekday: 1, startSection: index + 1, endSection: index + 1, campus: "校区" + code,
                number: code, credit: 1, hour: 1, type: "", category: "", department: "")
        }
        var initial = ScheduleCache()
        initial.currentTerm = "test-term"
        initial.timeTable = [TimeSlot(id: 1, start: "08:00", end: "09:00"), TimeSlot(id: 2, start: "11:00", end: "12:00")]
        initial.courseData.store(TermScheduleSnapshot(term: "test-term", firstDayString: "2001-01-01", courses: courses, exams: [], updatedAt: firstDay))
        let repository = makeRepository(load: { _ in .loaded(initial) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = ClockClassroomService()
        let model = ScheduleClassroomViewModel(service: service, repository: repository, now: { firstDay.addingTimeInterval(Double(hour) * 3600) })
        await model.refreshClassroomPage()
        let expected = hour == 7 ? "B" : "A"
        #expect(service.campusRequests == [expected])
        #expect(service.classroomDates == [firstDay.addingTimeInterval(Double(hour) * 3600)])
        #expect(model.cache.selectedCampusCode == expected && model.selectedBuildingID == expected)
        #expect(model.notice == nil)
    }

    @Test(.timeLimit(.minutes(1))) func classroomResultsFollowMinuteAndDayBoundaries() async throws {
        var now = try #require(ScheduleDateCodec.parseDate("2026-09-07")).addingTimeInterval(7 * 3600 + 59 * 60)
        var initial = ScheduleCache()
        initial.currentTerm = "test-term"; initial.selectedBuildingID = "building"
        initial.timeTable = [TimeSlot(id: 1, start: "08:00", end: "09:00")]
        initial.selectedClassroomSectionIDs = []
        let repository = makeRepository(load: { _ in .loaded(initial) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = ModuleScheduleService()
        service.classrooms = [ClassroomRecord(id: "room", name: "101", busyTimeCodes: [1])]
        let model = ScheduleClassroomViewModel(service: service, repository: repository, now: { now })
        await model.refreshClassrooms()
        #expect(model.classroomAvailabilities.map(\.id) == ["room"])
        now = now.addingTimeInterval(60)
        #expect(model.classroomAvailabilities.isEmpty)
        now = now.addingTimeInterval(3600)
        #expect(model.classroomAvailabilities.map(\.id) == ["room"])
        now = now.addingTimeInterval(24 * 3600)
        #expect(model.hasExpiredClassroomData(at: now) && model.classroomAvailabilities.isEmpty)
        await model.refreshClassrooms()
        #expect(!model.hasExpiredClassroomData(at: now) && model.classroomAvailabilities.map(\.id) == ["room"])
    }

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

    @Test(.timeLimit(.minutes(1))) func staleCourseDataWritePreservesPresentationAndSyncPreferences() async {
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

    @Test(.timeLimit(.minutes(1))) func syncPreferenceWritePreservesTheLatestCloudBaseline() async {
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

    @Test(.timeLimit(.minutes(1))) func sceneSubscriptionsSeparatePreferencesAndCloudMetadata() async {
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

    @Test(.timeLimit(.minutes(1))) func semesterStartDatePersistsWithinItsAccount() async throws {
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

    @Test(.timeLimit(.minutes(1))) func lateLoadKeepsCurrentAccountData() async throws {
        var account = AppStorageSession(accountIdentifier: "module-account-a")
        let loader = ModuleDeferredScheduleLoad()
        let repository = makeRepository(session: { account }, load: loader.load, save: { _, _, _ in })
        let task = Task { await repository.reload() }
        try await loader.waitUntilStarted()
        account = AppStorageSession(accountIdentifier: "module-account-b")
        repository.resetForCurrentAccount()
        var old = ScheduleCache()
        old.currentTerm = "account-a-term"
        loader.continuation?.resume(returning: .loaded(old))
        #expect(await task.value == false)
        #expect(repository.persistenceSnapshot.currentTerm.isEmpty)
        #expect(repository.isWritable == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["loaded", "missing", "unreadable"])
    func canceledInitialRecoveryAllowsTheSamePageToLoadAgain(result: String) async throws {
        let loader = ModuleDeferredScheduleLoad()
        var loads = 0
        var recovered = ScheduleCache()
        recovered.currentTerm = "recovered-term"
        let repository = makeRepository(load: { account in
            loads += 1
            return loads == 1 ? await loader.load(account) : .loaded(recovered)
        }, save: { _, _, _ in })
        let model = makeViewModel(service: ModuleSemesterStartDateService(), repository: repository)
        let first = Task { await model.loadIfNeeded() }
        try await loader.waitUntilStarted()
        first.cancel()
        loader.continuation?.resume(returning: result == "loaded" ? .loaded(recovered) : result == "missing" ? .missing : .unreadable)
        await first.value
        #expect(!repository.isLoading && !repository.isWritable)
        #expect(model.persistenceSnapshot.currentTerm.isEmpty && model.notice == nil)
        await model.loadIfNeeded()
        #expect(loads == 2 && repository.isWritable && !repository.isLoading)
        #expect(model.persistenceSnapshot.currentTerm == recovered.currentTerm)
        #expect(model.selectedWeek == model.resolvedAutomaticWeek())
        await model.loadIfNeeded()
        #expect(loads == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func lateCanceledRecoveryKeepsTheReplacementLoadAndItsWriteGate() async throws {
        let old = ModuleDeferredScheduleLoad(), current = ModuleDeferredScheduleLoad()
        var loads = 0
        let repository = makeRepository(load: { account in
            loads += 1
            return await (loads == 1 ? old : current).load(account)
        }, save: { _, _, _ in })
        let first = Task { await repository.loadIfNeeded() }
        try await old.waitUntilStarted()
        first.cancel()
        let replacement = Task { await repository.loadIfNeeded() }
        try await current.waitUntilStarted()
        old.continuation?.resume(returning: .missing)
        await first.value
        #expect(repository.isLoading && !repository.isWritable)
        var restored = ScheduleCache()
        restored.currentTerm = "replacement-term"
        current.continuation?.resume(returning: .loaded(restored))
        await replacement.value
        #expect(!repository.isLoading && repository.isWritable)
        #expect(repository.persistenceSnapshot.currentTerm == restored.currentTerm)
        await repository.loadIfNeeded()
        #expect(loads == 2)
    }

    @Test(.timeLimit(.minutes(1))) func delayedReloadPreservesEditsMadeDuringRead() async throws {
        let loader = ModuleDeferredScheduleLoad()
        var first = true
        let repository = makeRepository(load: { account in
            if first { first = false; return .loaded(ScheduleCache()) }
            return await loader.load(account)
        }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let task = Task { await repository.reload() }
        try await loader.waitUntilStarted()
        repository.courseState.primaryScheduleTitle = "本机编辑"
        loader.continuation?.resume(returning: .loaded(ScheduleCache()))
        #expect(await task.value == false)
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "本机编辑")
    }

    @Test(.timeLimit(.minutes(1))) func unreadableCachePreservesMemoryAndWriteGate() async {
        var savedCount = 0
        var first = true
        let repository = makeRepository(load: { _ in
            if first { first = false; return .missing }
            return .unreadable
        }, save: { _, _, _ in savedCount += 1 })
        await repository.loadIfNeeded()
        repository.courseState.primaryScheduleTitle = "保留内容"
        await repository.reload()
        repository.courseState.primaryScheduleTitle = "修改内容"
        _ = await repository.persistAndWait()
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == "保留内容")
        #expect(repository.isWritable == false)
        #expect(repository.notice?.title == "本地课表缓存读取失败")
        #expect(savedCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func pendingInitialReadRetainsStoredDataAndFinishesLoading() async throws {
        let loader = ModuleDeferredScheduleLoad()
        var savedCount = 0
        let repository = makeRepository(load: loader.load, save: { _, _, _ in savedCount += 1 })
        let ddl = ScheduleDDLViewModel(service: ModuleDeferredDDLService(), repository: repository)
        let task = Task { await repository.loadIfNeeded() }
        try await loader.waitUntilStarted()
        repository.presentationPreferences.showSaturday = false
        repository.courseState.primaryScheduleTitle = "修改内容"
        #expect(throws: Error.self) { try ddl.addDDL(DDLDraft()) }
        var stored = ScheduleCache()
        stored.primaryScheduleTitle = "原有课表"
        loader.continuation?.resume(returning: .loaded(stored))
        await task.value
        #expect(repository.persistenceSnapshot.primaryScheduleTitle == stored.primaryScheduleTitle)
        #expect(repository.persistenceSnapshot.presentation == stored.presentation)
        #expect(repository.persistenceSnapshot.ddlEvents.isEmpty)
        #expect(repository.isWritable && !repository.isLoading && savedCount == 0)
        await repository.loadIfNeeded()
    }

    @Test(.timeLimit(.minutes(1))) func persistenceReceivesAccountAndSource() async {
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

    @Test(.timeLimit(.minutes(1))) func ddlResponseAfterAccountSwitchKeepsNewAccountURL() async throws {
        let repository = makeRepository(load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = ModuleDeferredDDLService()
        let ddl = ScheduleDDLViewModel(service: service, repository: repository)
        let task = Task { await ddl.refreshLexueCalendarURL() }
        try await service.waitUntilStarted()
        #expect(ddl.isSyncingDDL)
        repository.resetForCurrentAccount()
        ddl.reset()
        await repository.loadIfNeeded()
        repository.ddlState.lexueCalendarURL = "account-b-calendar"
        service.continuation?.resume(returning: "account-a-calendar")
        await task.value
        #expect(repository.persistenceSnapshot.lexueCalendarURL == "account-b-calendar")
        #expect(ddl.isSyncingDDL == false)
        #expect(ddl.notice == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["saved", "failed", "accountChanged"])
    func subscriptionRefreshPublishesSuccessAfterItsOwnedSaveCompletes(stage: String) async throws {
        var session = AppStorageSession(accountIdentifier: "subscription-save")
        var pending: CheckedContinuation<Void, any Error>?
        var savedURL: String?
        let repository = ScheduleRepository(session: { session }, load: { _ in .missing }, save: { cache, _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
            savedURL = cache.lexueCalendarURL
        })
        await repository.loadIfNeeded()
        let service = ModuleDeferredDDLService()
        let model = ScheduleDDLViewModel(service: service, repository: repository)
        let refresh = Task { await model.refreshLexueCalendarURL() }
        try await service.waitUntilStarted()
        service.continuation?.resume(returning: "https://lexue.bit.edu.cn/calendar/owned.ics")
        try await waitForTestEvent { !(pending == nil) }
        #expect(model.notice == nil && model.isSyncingDDL)
        if stage == "accountChanged" {
            session = AppStorageSession(accountIdentifier: "subscription-next")
            repository.resetForCurrentAccount()
            await repository.loadIfNeeded()
        }
        if stage == "failed" { pending?.resume(throwing: CocoaError(.fileWriteNoPermission)) }
        else { pending?.resume() }
        await refresh.value
        if stage == "saved" {
            #expect(savedURL == repository.persistenceSnapshot.lexueCalendarURL)
            #expect(model.notice?.title == "订阅链接更新成功")
        } else {
            #expect(model.notice?.title != "订阅链接更新成功")
            if stage == "failed" { #expect(repository.notice?.title == "日程保存失败") }
            if stage == "accountChanged" { #expect(repository.persistenceSnapshot.lexueCalendarURL.isEmpty) }
        }
    }

    @Test(.timeLimit(.minutes(1))) func ddlPreferencesUseSharedAccountRepository() async {
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

    @Test(.timeLimit(.minutes(1))) func sceneWritesPreserveOtherSceneChanges() async {
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

    @Test(.timeLimit(.minutes(1))) func settingsSnapshotCapturesConfiguration() async throws {
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

    @Test(.timeLimit(.minutes(1))) func sharingCommandsUseCurrentScheduleContext() async throws {
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
        let code = try await viewModel.exportScheduleCode()
        try await viewModel.importScheduleCode(code)
        let shared = try #require(repository.persistenceSnapshot.sharedSchedules.first)
        #expect(shared.courses.first?.name == "边界课程")
        #expect(shared.currentTerm == "2026-2027-1")
        #expect(viewModel.settingsSnapshot.sharedSchedules.first?.id == shared.id)
        #expect(viewModel.settingsSnapshot.sharedSchedules.first?.title == shared.title)
        #expect(viewModel.settingsSnapshot.hasCourses)
    }

    @Test(.timeLimit(.minutes(1))) func platformActionsReceiveTheRepositorySessionAfterPersistence() async throws {
        let session = AppStorageSession(accountIdentifier: "platform-account")
        let repository = makeRepository(session: { session }, load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let actions = ModuleRecordingSchedulePlatformActions()
        let viewModel = makeViewModel(service: ModuleSemesterStartDateService(), repository: repository, platformActions: actions)
        viewModel.setICloudSyncEnabled(false)
        viewModel.setICloudSyncEnabled(true)
        viewModel.setShowCourseLiveActivityReminder(true)
        try await actions.waitForEnabledActions()
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

    @Test(.timeLimit(.minutes(1))) func sceneSubscriptionsFollowTheirOwnedFieldsAndQueryContext() async {
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

    @Test(.timeLimit(.minutes(1))) func courseSceneWritePreservesOtherSceneDataAndCloudMetadata() async {
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
final class ModuleRecordingSchedulePlatformActions: SchedulePlatformActions {
    var cloudSession: AppStorageSession?
    var reminderSession: AppStorageSession?
    var importedCourses: ScheduleCourseSnapshot?
    var importedTerm: String?
    var calendarContent: ScheduleSystemCalendarContent?
    var calendarTerm: String?
    var calendarMarkerIDs: Set<String>?
    var deleteCount = 0
    var importError: Error?

    func enableCloudSync(session: AppStorageSession) async {
        cloudSession = session
    }

    func enableCourseReminder(session: AppStorageSession) async {
        reminderSession = session
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

    func waitForEnabledActions() async throws {
        try await waitForTestEvent { cloudSession != nil && reminderSession != nil }
    }

}

@MainActor
private final class ModuleDeferredScheduleLoad {
    var continuation: CheckedContinuation<ScheduleCacheLoadResult, Never>?

    func load(_ session: AppStorageSession) async -> ScheduleCacheLoadResult {
        await withCheckedContinuation {
            continuation = $0
        }
    }

    func waitUntilStarted() async throws {
        try await waitForTestEvent { continuation != nil }
    }
}

@MainActor
private final class ModuleDeferredDDLService: ScheduleDDLServicing {
    var continuation: CheckedContinuation<String, Never>?

    func syncDDLEvents(
        existingEvents: [DDLEventRecord], storedURL: String, schoolSMSCodeHandler: SchoolSMSCodeHandler?
    ) async throws -> DDLSyncPayload {
        DDLSyncPayload(url: storedURL, events: existingEvents)
    }

    func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String {
        await withCheckedContinuation {
            continuation = $0
        }
    }

    func waitUntilStarted() async throws {
        try await waitForTestEvent { continuation != nil }
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
    func fetchClassrooms(buildingID: String, term: String, date: Date) async throws -> [ClassroomRecord] { throw ScheduleServiceError.invalidResponse }
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
final class ModuleCourseRequest {
    var response: CheckedContinuation<CourseSyncPayload, Error>?
    private(set) var wasCancelled = false

    func run() async throws -> CourseSyncPayload {
        defer { wasCancelled = Task.isCancelled }
        return try await withCheckedThrowingContinuation {
            response = $0
        }
    }

    func waitUntilStarted() async throws {
        try await waitForTestEvent { response != nil }
    }
}
