import BIT101TestSupport
import SchedulePorts
import ScheduleContracts
import ClientCore
import Combine
import Foundation
import ScheduleDomain
@testable import ScheduleFeature
import StorageCore
import Testing

@MainActor
struct ScheduleFeatureTests {
    private func editableCourse(_ id: String, weekday: Int, weeks: String, title: String = "同一课程",
        sections: [Int] = [1, 2], term: String = "term") throws -> CourseRecord {
        try #require(ScheduleCourseEditor.adding(CourseDraft(title: title, classroom: "文萃A101",
            weekday: weekday, weeksText: weeks, selectedSections: sections), to: [], term: term, id: id).first)
    }

    @Test(.timeLimit(.minutes(1)))
    func batchCourseArrangementChangesKeepEverySourceWeekAcrossMergesAndSwaps() async throws {
        for swap in [false, true] {
            for reverse in [false, true] {
                let first = try editableCourse("first", weekday: 1, weeks: "1-5")
                let second = try editableCourse("second", weekday: 2, weeks: "6-10")
                let other = try editableCourse("other", weekday: 7, weeks: "20", title: "其他课程")
                var cache = ScheduleCache()
                cache.currentTerm = "term"
                cache.courseData.store(TermScheduleSnapshot(term: "term", firstDayString: "2026-09-07",
                    courses: [first, second, other], exams: [], updatedAt: Date()))
                var saved: ScheduleCache?
                let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "batch-course-edit") },
                    load: { _ in .loaded(cache) }, save: { value, _, _ in saved = value })
                await repository.loadIfNeeded()
                let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions())
                let occurrence = model.courseArrangementDraft(for: first, week: 2)
                #expect(occurrence.availableWeeks == first.weeks && occurrence.draft.weeksText == "2")
                var arrangements = model.courseArrangementDrafts(forCourseID: first.id)
                #expect(arrangements.count == 2)
                arrangements[0].draft.weekday = 2
                if swap { arrangements[1].draft.weekday = 1 }
                if reverse { arrangements.reverse() }
                try model.updateCourseArrangements(arrangements)
                #expect(await repository.persistAndWait())
                let courses = model.courseState.courses
                #expect(Set(courses.map(\.id)) == ["first", "second", "other"])
                #expect(courses.first { $0.id == "first" }?.weeks == Array(1...5))
                #expect(courses.first { $0.id == "second" }?.weeks == Array(6...10))
                #expect(courses.first { $0.id == "first" }?.weekday == 2)
                #expect(courses.first { $0.id == "second" }?.weekday == (swap ? 1 : 2))
                #expect(saved?.manualCourseRulesByTerm["term"]?.flatMap(\.replacementCourses).filter { $0.name == "同一课程" }.count == 2)
            }
        }
    }

    @Test func occurrenceActionsFollowTheClickedDaySectionsAndSource() throws {
        let monday = try editableCourse("monday", weekday: 1, weeks: "1-5")
        let wednesday = try editableCourse("wednesday", weekday: 3, weeks: "1-5")
        let later = try editableCourse("later", weekday: 3, weeks: "6-10")
        let otherTime = try editableCourse("afternoon", weekday: 3, weeks: "1-5", sections: [5, 6])
        let courses = [monday, otherTime, later, wednesday]
        let entry = ScheduleCalendarEntry(id: "clicked", sourceID: wednesday.id, sourceIDs: courses.map(\.id),
            dayOfWeek: 3, startSection: 0, endSection: 2, title: "同一课程", subtitle: "", detailLines: [], kind: .course)
        #expect(entry.courseOccurrence(in: courses, currentWeek: 2)?.course.id == wednesday.id)
        #expect(entry.courseOccurrence(in: courses, currentWeek: 7)?.course.id == later.id)
        #expect(entry.courseOccurrence(in: courses, currentWeek: 0)?.course.id == wednesday.id)
        #expect(entry.courseOccurrence(in: courses, currentWeek: 0)?.week == 1)
        #expect(entry.courseOccurrence(in: [monday, otherTime], currentWeek: 2) == nil)
    }

    @Test func explicitEmptySectionsAndUnavailableOccurrenceWeeksRequireCorrection() throws {
        var draft = CourseDraft(title: "课程", weeksText: "1-5")
        #expect(try ScheduleCourseEditor.resolve(draft).startSection == 1)
        draft.selectedSections = []
        #expect(throws: Error.self) { try ScheduleCourseEditor.resolve(draft) }
        draft.selectedSections = [2, 3]
        #expect(try ScheduleCourseEditor.resolve(draft).startSection == 2)
        let original = try editableCourse("original", weekday: 1, weeks: "1-5")
        for weeks in [[], [18], [1, 18]] {
            #expect(throws: Error.self) {
                try ScheduleCourseEditor.updatingOccurrence(id: original.id, weeks: weeks, with: draft, in: [original])
            }
        }
    }

    @Test(arguments: [false, true]) func manualDDLFieldsRespectTheSharedByteBudget(detail: Bool) throws {
        let limit = ScheduleCourseConstraints.maximumFieldBytes
        let within = String(repeating: "界", count: limit / 3) + String(repeating: "a", count: limit % 3)
        var draft = DDLDraft(title: detail ? "DDL" : within, text: detail ? within : "")
        let original = try ScheduleDDLEditor.adding(draft, to: [], id: "budget")
        #expect(original.count == 1)
        if detail { draft.text += "a" } else { draft.title += "a" }
        #expect(throws: (any Error).self) { try ScheduleDDLEditor.adding(draft, to: [], id: "budget") }
        #expect(throws: (any Error).self) { try ScheduleDDLEditor.updating(id: "budget", with: draft, in: original) }
        #expect(original.first?.title == (detail ? "DDL" : within))
    }

    @Test(arguments: [1e300, -1e300, Double(Int.min) * 60, .infinity, -.infinity, .nan])
    func ddlRemainingTimeHandlesValuesOutsideIntegerRange(interval: Double) {
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "ddl-range") },
            load: { _ in .missing }, save: { _, _, _ in })
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions())
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let event = DDLEventRecord(id: "range", group: "custom", title: "日程", text: "",
            dueAt: Date(timeIntervalSinceReferenceDate: interval), done: false)
        #expect(model.ddl.ddlRemainingText(for: event, now: now) == "截止时间超出显示范围")
        var regular = event
        regular.dueAt = now.addingTimeInterval(90_060)
        #expect(model.ddl.ddlRemainingText(for: regular, now: now) == "剩余 1天 1小时 1分钟")
        regular.dueAt = now.addingTimeInterval(-90_060)
        #expect(model.ddl.ddlRemainingText(for: regular, now: now) == "已过 1天 1小时 1分钟")
    }

    @Test(.timeLimit(.minutes(1))) func repeatingSchedulesUseTheDisplayedWeekAndEditAsOneRecord() async throws {
        var cache = ScheduleCache()
        cache.currentTerm = "term"
        cache.courseData.store(TermScheduleSnapshot(term: "term", firstDayString: "2026-09-07",
            courses: [], exams: [], updatedAt: Date()))
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "repeating") },
            load: { _ in .loaded(cache) }, save: { value, _, _ in saved = value })
        await repository.loadIfNeeded()
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions())
        model.selectedWeek = 4
        #expect(model.courseDraft(for: model.selectedWeek).weeksText == "4")
        var draft = model.customScheduleDraft(for: nil)
        #expect(draft.selectedWeeks == [4])
        let weekday = ScheduleDateCodec.weekdayIndex(from: draft.date)
        draft.title = "每周活动"
        draft.beginTime = try #require(ScheduleDateCodec.parseTime("12:10"))
        draft.endTime = try #require(ScheduleDateCodec.parseTime("12:40"))
        draft.selectedWeeks = [6, 4, 5, 4]
        try model.addCustomSchedule(draft)
        #expect(await repository.persistAndWait())
        let record = try #require(saved?.customSchedules.first)
        #expect(saved?.customSchedules.count == 1)
        #expect(record.occurrenceDateStrings.count == 3)
        #expect(model.customScheduleDraft(for: record).selectedWeeks == [4, 5, 6])
        for text in record.occurrenceDateStrings {
            #expect(ScheduleDateCodec.weekdayIndex(from: try #require(ScheduleDateCodec.parseDate(text))) == weekday)
        }
        for title in ["", " \n ", String(repeating: "中", count: ScheduleCourseConstraints.maximumFieldBytes)] {
            var invalid = draft; invalid.title = title
            #expect(throws: Error.self) { try model.addCustomSchedule(invalid) }
            #expect(throws: Error.self) { try model.updateCustomSchedule(id: record.id, draft: invalid) }
            #expect(model.customScheduleDraft(for: record).title == record.title)
        }
        var edit = model.customScheduleDraft(for: record)
        edit.title = "统一修改"
        edit.selectedWeeks = [5, 7]
        try model.updateCustomSchedule(id: record.id, draft: edit)
        #expect(await repository.persistAndWait())
        let updated = try #require(saved?.customSchedules.first)
        #expect(updated.id == record.id && updated.title == "统一修改")
        #expect(model.customScheduleDraft(for: updated).selectedWeeks == [5, 7])
        let decoded = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(try #require(saved)))
        #expect(decoded.customSchedules == saved?.customSchedules)
        var empty = edit; empty.selectedWeeks = []
        #expect(throws: Error.self) { try model.updateCustomSchedule(id: record.id, draft: empty) }
        try model.deleteCustomSchedule(id: record.id)
        #expect(await repository.persistAndWait())
        #expect(saved?.customSchedules.isEmpty == true)
    }

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

    @Test(.timeLimit(.minutes(1))) func sharedScheduleSelectionFollowsIdentityAcrossReorderReloadAndDeletion() async {
        let payload = ScheduleExportPayload(currentTerm: "term", firstDayString: "2026-09-07", timeTable: TimeSlot.default, courses: [])
        var cache = ScheduleCache()
        cache.sharedSchedules = [SharedScheduleRecord(id: "z", title: "Z", payload: payload),
                                 SharedScheduleRecord(id: "a", title: "A", payload: payload)]
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "selection") },
            load: { _ in .loaded(cache) }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions())
        model.selectedCourseScheduleIndex = 1
        cache.sharedSchedules.reverse()
        await model.reloadFromDisk()
        #expect(model.activeCourseSchedule.id == "z")
        #expect(model.selectedCourseScheduleIndex == 2)
        repository.courseState.sharedSchedules.reverse()
        #expect(model.activeCourseSchedule.id == "z")
        #expect(model.selectedCourseScheduleIndex == 1)
        repository.courseState.sharedSchedules.removeAll { $0.id == "z" }
        #expect(model.activeCourseSchedule.isPrimary)
        #expect(model.selectedCourseScheduleIndex == 0)
    }

    @Test func currentWeekFollowsTheSuppliedClockAcrossTheWeekBoundary() throws {
        let first = try #require(ScheduleDateCodec.parseDate("2026-09-07"))
        let next = try #require(ScheduleDateCodec.parseDate("2026-09-14"))
        #expect(resolvedCurrentWeek(firstDay: first, now: first) == 1)
        #expect(resolvedCurrentWeek(firstDay: first, now: next) == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func firstCourseSyncSelectsTheReturnedTermAndPublishesItsSchedule(requiresSMS: Bool) async throws {
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "first-sync") },
            load: { _ in .missing }, save: { cache, _, _ in saved = cache })
        let service = ModuleScheduleService()
        let course = try editableCourse("first-course", weekday: 1, weeks: "1-20")
        let payload = CourseSyncPayload(term: "term", firstDayString: "2026-09-07",
            sourceFirstDayString: "2026-09-07", normalizationOffset: 0, rawWeeksByCourse: [], courses: [course], exams: [])
        service.payload = payload
        if requiresSMS {
            service.challenge = BITLoginAuthenticationChallenge(challengeID: "first-sync", accessToken: "token",
                status: "waiting_sms", maskedPhone: "138****0000", expiresIn: 300)
        } else {
            service.onSync = { term in #expect(term == nil); return payload }
        }
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions(), service: service)
        await model.loadIfNeeded()
        #expect(model.activeCourseSchedule.currentTerm.isEmpty && !model.hasCourseData)
        await model.syncCourses()
        if requiresSMS { await model.submitSMSCode("123456") }
        #expect(model.activeCourseSchedule.currentTerm == "term")
        #expect(model.hasCourseData && model.activeCourseSchedule.courses == [course])
        #expect(model.activeCourseSchedule.firstDayString == payload.firstDayString)
        #expect(model.courseState.coursesUpdatedAt != .distantPast)
        #expect(saved?.currentTerm == "term" && saved?.courses == [course])
        #expect(!model.isSyncingCourses && model.smsChallenge == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func existingCourseRefreshPublishesContentAndItsSuccessfulUpdateTime(contentChanged: Bool, switchesTerm: Bool) async throws {
        let targetTerm = switchesTerm ? "next-term" : "term"
        let old = try editableCourse("same-course", weekday: 1, weeks: "1-20", title: "原课程")
        let updated = try editableCourse("same-course", weekday: contentChanged ? 3 : 1,
            weeks: contentChanged ? "2-20" : "1-20", title: contentChanged ? "更新课程" : "原课程", term: targetTerm)
        var disk = ScheduleCache()
        disk.currentTerm = "term"
        disk.courseData.store(TermScheduleSnapshot(term: "term", firstDayString: "2026-09-07",
            courses: [old], exams: [], updatedAt: Date(timeIntervalSince1970: 1)))
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "existing-refresh") },
            load: { _ in .loaded(disk) }, save: { cache, _, _ in disk = cache })
        let service = ModuleScheduleService()
        service.onSync = { term in
            #expect(term == targetTerm)
            return CourseSyncPayload(term: targetTerm, firstDayString: "2026-09-07",
                sourceFirstDayString: "2026-09-07", normalizationOffset: 0, rawWeeksByCourse: [], courses: [updated], exams: [])
        }
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions(), service: service)
        await model.loadIfNeeded()
        let previousUpdate = model.courseState.coursesUpdatedAt
        var changes = 0
        let observation = model.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        if switchesTerm { await model.syncCourses(term: targetTerm) } else { await model.syncSelectedTerm() }
        #expect(model.activeCourseSchedule.currentTerm == targetTerm)
        #expect(model.activeCourseSchedule.courses == [updated] && model.hasCourseData)
        #expect(model.courseState.coursesUpdatedAt > previousUpdate)
        #expect(disk.courses == [updated] && disk.coursesUpdatedAt == model.courseState.coursesUpdatedAt)
        if switchesTerm { #expect(disk.termSchedulesByTerm["term"]?.courses == [old]) }
        #expect(changes > 0 && !model.isSyncingCourses)
    }

    @Test(.timeLimit(.minutes(1))) func courseVerificationFailurePreservesChallengeAndRetryResumesChosenTerm() async throws {
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

    @Test(.timeLimit(.minutes(1))) func requestsShareOnePhaseAndAccountResetCancelsTheirOwner() async throws {
        var session = AppStorageSession(accountIdentifier: "first")
        let repository = ScheduleRepository(session: { session }, load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = ModuleScheduleService()
        let pending = ModuleCourseRequest()
        service.onSync = { _ in try await pending.run() }
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions(), service: service)
        let request = Task { await model.syncCourses(term: "first-term") }
        try await pending.waitUntilStarted()
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

    @Test(.timeLimit(.minutes(1))) func cancellingTheCallerReleasesItsRequestPhase() async throws {
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "cancel") },
            load: { _ in .missing }, save: { _, _, _ in })
        await repository.loadIfNeeded()
        let service = ModuleScheduleService()
        let pending = ModuleCourseRequest()
        service.onSync = { _ in try await pending.run() }
        let model = makeViewModel(repository: repository, actions: ModuleSchedulePlatformActions(), service: service)
        let request = Task { await model.syncCourses() }
        try await pending.waitUntilStarted()
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

    @Test(.timeLimit(.minutes(1))) func publicAssemblyOwnsOneRepositoryAcrossAllSubscenes() async {
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

    @Test(.timeLimit(.minutes(1))) func scopedChangeStreamReloadsItsAccountOwner() async throws {
        let first = AppStorageSession(accountIdentifier: "first")
        let second = AppStorageSession(accountIdentifier: "second")
        let changes = PassthroughSubject<AppStorageSession, Never>()
        var firstLoads = 0
        var secondLoads = 0
        let firstRepository = ScheduleRepository(session: { first }, load: { _ in
            firstLoads += 1
            return .missing
        }, save: { _, _, _ in }, changes: changes.eraseToAnyPublisher())
        let secondRepository = ScheduleRepository(session: { second }, load: { _ in secondLoads += 1; return .missing },
                                                 save: { _, _, _ in }, changes: changes.eraseToAnyPublisher())
        await firstRepository.loadIfNeeded()
        await secondRepository.loadIfNeeded()
        changes.send(first)
        try await waitForTestEvent { firstLoads == 2 }
        #expect(firstLoads == 2)
        #expect(secondLoads == 1)
    }

    @Test(.timeLimit(.minutes(1))) func cloudEnableWaitsForTheOwnedSaveAndHonorsSaveFailure() async {
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

    @Test(.timeLimit(.minutes(1))) func calendarCommandsPreserveSelectionAndPropagateErrors() async throws {
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

    @Test(.timeLimit(.minutes(1))) func sceneWritesPreserveOtherDataAndSettingsProjection() async {
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
final class ModuleSchedulePlatformActions: SchedulePlatformActions {
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
final class ModuleScheduleService: ScheduleServicing {
    var challenge: BITLoginAuthenticationChallenge?
    var submissionError: ScheduleServiceError?
    var payload: CourseSyncPayload?
    var submittedCodes: [String] = []
    var onSync: ((String?) async throws -> CourseSyncPayload)?
    var termRequests = 0
    var classrooms: [ClassroomRecord] = []

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
    func fetchClassrooms(buildingID: String, term: String, date: Date) async throws -> [ClassroomRecord] { classrooms }
}
