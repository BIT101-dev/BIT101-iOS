import ClientCore
import SchedulePorts
import CommunityTransport
@testable import ScheduleFeature
@testable import ScheduleInfrastructure
import StorageCore
import ScheduleDomain
import ScheduleContracts
import ScheduleSharedStore
import Foundation
import Combine
import Testing
@testable import BIT101_iOS

import UserNotifications

@MainActor
struct ScheduleCalendarTransactionTests {
    @Test func calendarMarkersKeepAccountAndTermOwnershipAcrossEventIdentifierChanges() throws {
        let first = AppStorageSession(accountIdentifier: "calendar-A")
        let second = AppStorageSession(accountIdentifier: "calendar-B")
        let guest = AppStorageSession(accountIdentifier: "")
        let term = "2026-2027-1"
        let url = try #require(ScheduleSystemCalendarEventMarker.url(id: "course-w1", term: term, session: first))
        #expect(ScheduleSystemCalendarEventMarker.matches(url, session: first, term: term))
        #expect(ScheduleSystemCalendarEventMarker.matches(url, session: first))
        #expect(ScheduleSystemCalendarEventMarker.matches(url, session: second, term: term) == false)
        #expect(ScheduleSystemCalendarEventMarker.matches(url, session: guest, term: term) == false)
        #expect(ScheduleSystemCalendarEventMarker.matches(url, session: first, term: "other") == false)
        #expect(url.absoluteString.contains(first.accountIdentifier) == false)
        for foreign in [nil, URL(string: "bit101://calendar-course/course-w1?term=2026-2027-1"),
                        URL(string: "https://example.invalid/course-w1")] {
            #expect(ScheduleSystemCalendarEventMarker.matches(foreign, session: first, term: term) == false)
        }
    }

    @Test func sharedConsumersResolveThePersistedAccountSnapshotAndItsClearBoundary() throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL)
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = ScheduleExternalSnapshot(generatedAt: now, isLoggedIn: true,
            studentID: "shared-reader", firstDayString: "", timeTable: [], courses: [])
        try store.write(snapshot)
        let resolved = ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store, now: now, limit: 1)
        #expect(resolved.snapshot?.studentID == AccountStorageIdentity.stableToken(for: "shared-reader"))
        #expect(resolved.snapshot?.generatedAt == now)
        #expect(resolved.upcomingOccurrences.isEmpty)
        #expect(store.clear())
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store, now: now).contentState == .missing)
    }

    @Test func calendarQuerySlicesCoverLongRangesAndLeapYearBoundaries() throws {
        let calendar = ScheduleSharedDateCodec.calendar
        let start = try #require(calendar.date(from: DateComponents(year: 2020, month: 2, day: 29, hour: 12)))
        let end = try #require(calendar.date(from: DateComponents(year: 2040, month: 3, day: 1, hour: 12)))
        let ranges = ScheduleSystemCalendarQuery.intervals(start: start, end: end)
        #expect(ranges.count == 6 && ranges.first?.start == start && ranges.last?.end == end)
        for range in ranges {
            let maximumEnd = try #require(calendar.date(byAdding: .year, value: 4, to: range.start))
            #expect(range.start < range.end && range.end <= maximumEnd)
        }
        for (previous, next) in zip(ranges, ranges.dropFirst()) { #expect(previous.end == next.start) }
        let current = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)))
        #expect(ranges.contains { $0.contains(current) })
        let fourYears = try #require(calendar.date(byAdding: .year, value: 4, to: start))
        #expect(ScheduleSystemCalendarQuery.intervals(start: start, end: fourYears) == [DateInterval(start: start, end: fourYears)])
        #expect(ScheduleSystemCalendarQuery.intervals(start: end, end: start).isEmpty)
        #expect(ScheduleSystemCalendarQuery.intervals(start: start, end: start).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func calendarPermissionContinuationChecksCancellationAndAccountBeforeEventKit(cancel: Bool) async throws {
        var identity = SchoolSessionIdentity(accountIdentifier: "calendar-owner", generation: 0)
        var resume: CheckedContinuation<Void, Never>?
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.calendar-permission"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.calendar-permission") }
        let manager = ScheduleSystemCalendarManager(defaults: defaults, currentIdentity: { identity },
            requestAccess: { await withCheckedContinuation { resume = $0 } })
        let task = Task { try await manager.deleteAllImportedEvents() }
        while resume == nil { await Task.yield() }
        if cancel { task.cancel() } else { identity = .init(accountIdentifier: "calendar-owner", generation: 1) }
        resume?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(defaults.dictionaryRepresentation().keys.contains(AppStorageSession(accountIdentifier: "calendar-owner").key("schedule.system-calendar.imported-batches")) == false)
    }

    @Test(arguments: [0, 1, 2])
    func failedBatchesDiscardPendingMutationsBeforeTheNextCommit(failureStage: Int) throws {
        enum Failure: Error { case injected }
        var pending: [String] = []
        var committed: [String] = []
        var resets = 0
        #expect(throws: Failure.self) {
            try ScheduleSystemCalendarTransaction.run(reset: { pending.removeAll(); resets += 1 }) {
                pending.append("remove-old")
                if failureStage == 0 { throw Failure.injected }
                pending.append("save-first")
                if failureStage == 1 { throw Failure.injected }
                pending.append("save-second")
                throw Failure.injected
            }
        }
        #expect(pending.isEmpty && resets == 1)
        try ScheduleSystemCalendarTransaction.run(reset: { pending.removeAll(); resets += 1 }) {
            pending.append("next-batch")
            committed += pending
            pending.removeAll()
        }
        #expect(committed == ["next-batch"])
        #expect(resets == 1)
    }
}

@MainActor
struct ScheduleNotificationTimeZoneTests {
    @Test func notificationComponentsKeepTheAbsoluteInstantAcrossTimeZones() throws {
        let target = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 86_400)
        let components = ScheduleReminderNotificationDate.components(for: target)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        #expect(trigger.nextTriggerDate() == target)
        for identifier in ["America/Los_Angeles", "Europe/London", "Asia/Tokyo"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: identifier))
            #expect(calendar.date(from: components) == target)
        }
    }
}

@MainActor
struct ExternalScheduleWatchStatusTests {
    private final class ClearResult { var succeeds = false }

    @Test func coldActivationKeepsTheLatestRequestAndClearingInvalidatesIt() throws {
        let queue = WatchScheduleRequestQueue()
        var results: [Int] = []
        #expect(queue.begin(isActivated: false, completion: { _ in results.append(1) }) == nil)
        #expect(queue.begin(isActivated: false, completion: { _ in results.append(2) }) == nil)
        let pending = try #require(queue.takePending())
        #expect(pending.generation == queue.generation)
        pending.completion(.success(.requested))
        #expect(results == [2])
        #expect(queue.takePending() == nil)
        let immediate = queue.begin(isActivated: true, completion: { _ in results.append(3) })
        let live = try #require(immediate)
        #expect(live == queue.generation)
        #expect(queue.takePending() == nil)
        #expect(queue.begin(isActivated: false, completion: { _ in results.append(4) }) == nil)
        queue.clear()
        #expect(queue.generation > live)
        #expect(queue.takePending() == nil)
        #expect(results == [2])
    }

    @Test func unchangedBackgroundReceiptCompletesTheQueuedRefresh() throws {
        let files = PreferenceMemoryFiles()
        let center = NotificationCenter()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL, notificationCenter: center)
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = ScheduleExternalSnapshot(generatedAt: now, isLoggedIn: true,
            studentID: AppStorageSession(accountIdentifier: AppAccountSession.storage.currentStudentID).accountStorageIdentifier,
            firstDayString: "", timeTable: [], courses: [])
        let data = try ScheduleExternalSnapshotCodec.encode(snapshot)
        let manager = WatchScheduleSyncManager.shared
        #expect(manager.persistSnapshotData(data, store: store, notificationCenter: center) == .success(.received))
        let model = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: { now }, loadResolvedSnapshot: { now, _ in ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store, now: now) },
            clearSnapshot: { true }, activateSync: {}, requestLatestSnapshot: { $0(.success(.requested)) }
        ))
        let observation = center.publisher(for: WatchScheduleSyncManager.snapshotReceivedNotification).sink { _ in
            MainActor.assumeIsolated { model.handleSnapshotDidChange() }
        }
        defer { observation.cancel() }
        model.requestRefresh()
        #expect(model.refreshState == .syncing)
        #expect(manager.persistSnapshotData(data, store: store, notificationCenter: center) == .success(.received))
        #expect(model.refreshState == .succeeded)
        #expect(model.snapshot == snapshot)
        let stale = snapshot.replacingStudentID(with: "another-owner")
        model.requestRefresh()
        #expect(manager.persistSnapshotData(try ScheduleExternalSnapshotCodec.encode(stale), store: store, notificationCenter: center) == .failure(.staleSnapshot))
        #expect(model.refreshState == .syncing)
    }

    @Test func queuedSnapshotReceptionRespectsTheClearingBoundary() {
        let received = ContinuousClock.now
        let cleared = received.advanced(by: .seconds(1))
        #expect(WatchSnapshotReceptionPolicy.accepts(receivedAt: received, afterClearingAt: nil))
        #expect(WatchSnapshotReceptionPolicy.accepts(receivedAt: received, afterClearingAt: cleared) == false)
        #expect(WatchSnapshotReceptionPolicy.accepts(receivedAt: cleared, afterClearingAt: cleared) == false)
        #expect(WatchSnapshotReceptionPolicy.accepts(receivedAt: cleared.advanced(by: .seconds(1)), afterClearingAt: cleared))
    }

    @Test func lateResultsRetainTheCurrentRefreshAndClearedState() {
        var callbacks: [@MainActor (Result<WatchScheduleSyncOutcome, WatchScheduleSyncError>) -> Void] = []
        let model = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: Date.init, loadResolvedSnapshot: { now, _ in ScheduleOccurrenceResolver.resolvedSnapshot(from: nil, now: now) },
            clearSnapshot: { true }, activateSync: {}, requestLatestSnapshot: { callbacks.append($0) }
        ))
        model.requestRefresh()
        model.handleSnapshotDidChange()
        model.requestRefresh()
        callbacks[0](.failure(.transferFailed))
        #expect(model.refreshState == .syncing)
        callbacks[1](.success(.received))
        #expect(model.refreshState == .succeeded)
        model.clearLocalData()
        callbacks[1](.failure(.transferFailed))
        #expect(model.refreshState == .idle)
        #expect(model.snapshot == nil)
    }

    @Test func aQueuedRequestWaitsForReceiptAndImmediateReceiptCompletesRefresh() {
        var completion: (@MainActor (Result<WatchScheduleSyncOutcome, WatchScheduleSyncError>) -> Void)?
        let model = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: Date.init, loadResolvedSnapshot: { now, _ in ScheduleOccurrenceResolver.resolvedSnapshot(from: nil, now: now) },
            clearSnapshot: { true }, activateSync: {}, requestLatestSnapshot: { completion = $0 }
        ))
        model.requestRefresh()
        completion?(.success(.requested))
        #expect(model.refreshState == .syncing)
        completion?(.success(.received))
        #expect(model.refreshState == .succeeded)
        let immediate = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: Date.init, loadResolvedSnapshot: { now, _ in ScheduleOccurrenceResolver.resolvedSnapshot(from: nil, now: now) },
            clearSnapshot: { true }, activateSync: {}, requestLatestSnapshot: { $0(.success(.received)) }
        ))
        immediate.requestRefresh()
        #expect(immediate.refreshState == .succeeded)
    }

    @Test func failedClearingPreservesTheStoredSnapshotAndReportsTheResult() {
        let now = Date()
        let snapshot = ScheduleExternalSnapshot(generatedAt: now, isLoggedIn: true,
            studentID: "watch-owner", firstDayString: "", timeTable: [], courses: [])
        let result = ClearResult()
        let model = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: { now }, loadResolvedSnapshot: { date, _ in
                ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: date)
            }, clearSnapshot: { result.succeeds }, activateSync: {}, requestLatestSnapshot: { _ in }
        ))
        model.reload()
        let previousState = model.contentState
        model.clearLocalData()
        #expect(model.snapshot == snapshot)
        #expect(model.contentState == previousState)
        #expect(model.refreshFeedbackText == "清理失败，请重试")
        result.succeeds = true
        model.clearLocalData()
        #expect(model.snapshot == nil)
        #expect(model.contentState == .missing)
        #expect(model.refreshState == .idle)
    }
}

@Suite("Extended schedule invariants")
struct ExtendedSchedulePolicyTests {
    @Test @MainActor
    func sharedSnapshotClearPublishesEmptyStateAndRejectsAnEarlierCompletion() async {
        var released: CheckedContinuation<Bool, Never>?
        var started: CheckedContinuation<Void, Never>?
        var published: [ScheduleExternalSnapshot] = []
        var generations: [UInt64] = []
        let pending = Task {
            await ScheduleWidgetExporter.clearSharedSnapshot(clearSnapshot: { generation in
                generations.append(generation)
                return await withCheckedContinuation {
                    released = $0
                    started?.resume(); started = nil
                }
            }, publishSnapshot: { published.append($0) })
        }
        await withCheckedContinuation { started = $0 }
        let cleared = await ScheduleWidgetExporter.clearSharedSnapshot(clearSnapshot: { generation in
            generations.append(generation)
            return true
        }, publishSnapshot: { published.append($0) })
        released?.resume(returning: true)
        #expect(await pending.value)
        #expect(cleared && generations.count == 2 && generations[0] < generations[1])
        #expect(published.count == 1 && published[0].courses.isEmpty && published[0].firstDayString.isEmpty)
        let failed = await ScheduleWidgetExporter.clearSharedSnapshot(clearSnapshot: { _ in false },
            publishSnapshot: { _ in Issue.record("清理失败需要保留外部发布状态") })
        #expect(failed == false)
    }

    @Test("External schedule exports discard stale accounts and generations")
    func externalSnapshotExportGeneration() {
        let accountA = AppStorageSession(accountIdentifier: "schedule-account-a")
        let accountB = AppStorageSession(accountIdentifier: "schedule-account-b")

        #expect(!ScheduleSnapshotExportPolicy.isCurrent(
            capturedSession: accountA,
            currentSession: accountB,
            generation: 4,
            currentGeneration: 4
        ))
        #expect(!ScheduleSnapshotExportPolicy.isCurrent(
            capturedSession: accountB,
            currentSession: accountB,
            generation: 3,
            currentGeneration: 4
        ))
        #expect(ScheduleSnapshotExportPolicy.isCurrent(
            capturedSession: accountB,
            currentSession: accountB,
            generation: 4,
            currentGeneration: 4
        ))
        #expect(ScheduleSnapshotExportPolicy.acceptsWrite(generation: 4, latestGeneration: 4))
        #expect(!ScheduleSnapshotExportPolicy.acceptsWrite(generation: 3, latestGeneration: 4))
        let snapshot = ScheduleExternalSnapshot(isLoggedIn: true, studentID: accountA.accountStorageIdentifier,
            firstDayString: "", timeTable: [], courses: [])
        #expect(!ScheduleSnapshotExportPolicy.requiresAccountReset(snapshot: snapshot, session: accountA, isLoggedIn: true))
        #expect(ScheduleSnapshotExportPolicy.requiresAccountReset(snapshot: snapshot, session: accountB, isLoggedIn: true))
        #expect(ScheduleSnapshotExportPolicy.requiresAccountReset(snapshot: snapshot, session: accountA, isLoggedIn: false))
        #expect(!ScheduleSnapshotExportPolicy.requiresAccountReset(snapshot: nil, session: accountA, isLoggedIn: true))
    }

    @Test("Display modes expose stable identifiers and titles")
    func displayModesAreStable() {
        #expect(ScheduleDisplayMode.allCases.map(\.rawValue) == ["weekly", "allWeeks"])
        #expect(ScheduleDisplayMode.weekly.title == "按周显示")
        #expect(ScheduleDisplayMode.allWeeks.title == "全学期叠加")
    }

    @Test("Display mode survives cache encoding")
    func displayModeRoundTrip() throws {
        var cache = ScheduleCache()
        cache.scheduleDisplayMode = .allWeeks

        let data = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(ScheduleCache.self, from: data)

        #expect(decoded.scheduleDisplayMode == .allWeeks)
    }

    @Test("Old caches default to weekly display")
    func oldCacheDefaultsToWeekly() throws {
        let data = Data(#"{"currentTerm":"2026-2027-1","courses":[]}"#.utf8)
        let cache = try JSONDecoder().decode(ScheduleCache.self, from: data)

        #expect(cache.scheduleDisplayMode == .weekly)
    }

    @Test("Week codec skips zero and keeps negative offsets contiguous")
    func weekCodecBoundaries() {
        let offsets = [-15, -8, -1, 0, 1, 7, 14]
        let weeks = offsets.map(ScheduleWeekCodec.weekNumber(forDayOffset:))

        #expect(weeks == [-3, -2, -1, 1, 1, 2, 3])
    }

    @Test("Automatic week policy only clamps calculated positions")
    func automaticWeekPolicy() {
        #expect(ScheduleAutomaticWeekPolicy.clamped(-100) == -12)
        #expect(ScheduleAutomaticWeekPolicy.clamped(-12) == -12)
        #expect(ScheduleAutomaticWeekPolicy.clamped(20) == 20)
        #expect(ScheduleAutomaticWeekPolicy.clamped(100) == 20)
    }

    @Test("Course rows preserve half-credit values")
    func preservesFractionalCredits() throws {
        let data = Data("""
        {
            "datas": {
                "cxxszhxqkb": {
                    "rows": [
                        {"KCM":"数安实践","KCH":"100120078","XF":1.5,"XS":24},
                        {"KCM":"软安实践","KCH":"100120084","XF":"1.5","XS":24}
                    ]
                }
            }
        }
        """.utf8)
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)

        #expect(response.courseRecords.map(\.credit) == [1.5, 1.5])
        #expect(response.courseRecords.map(\.creditText) == ["1.5", "1.5"])
    }

    @Test("Unchanged source silently reapplies a manual course rule")
    func unchangedSourceReappliesManualRule() {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        let rule = ScheduleCourseRule(
            sourceIdentity: scheduleCourseSourceIdentity(original),
            sourceCourses: [original],
            replacementCourses: [replacement]
        )

        let result = ScheduleCourseEditor.reconcile(
            rules: [rule],
            with: [original]
        )

        #expect(result.invalidRules.isEmpty)
        #expect(result.validRules.count == 1)
        #expect(result.courses == [replacement])
    }

    @Test("Holiday deletion keeps school snapshots raw and persists a manual rule")
    func holidayDeletionPreservesRawCourses() throws {
        let repeating = course(id: "repeat", number: "MATH-1", weeks: [1, 2, 3], weekday: 2)
        let singleWeek = course(id: "single", number: "ENG-1", weeks: [2], weekday: 2)
        let originals = [repeating, singleWeek]
        let holidayCourses = ScheduleCourseEditor.removingOccurrences(
            from: originals,
            week: 2,
            weekday: 2
        )
        var cache = manualEditCache(with: originals)

        ScheduleCourseEditor.updateCacheForManualCourseChange(
            in: &cache,
            previousCourses: originals,
            currentCourses: holidayCourses
        )

        #expect(cache.courses == holidayCourses)
        #expect(cache.courseData.schoolCourses(for: repeating.term) == originals)
        #expect(cache.cachedCoursesByTerm[repeating.term] == originals)
        #expect(cache.termSchedulesByTerm[repeating.term]?.courses == originals)
        #expect(cache.manualCourseRulesByTerm[repeating.term]?.count == 2)
        let restoredHolidayCourses = ScheduleCourseEditor.reconcile(
            rules: cache.manualCourseRulesByTerm[repeating.term] ?? [],
            with: originals
        )
        #expect(Set(restoredHolidayCourses.courses) == Set(holidayCourses))

        let decoded = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(Set(decoded.courses) == Set(holidayCourses))
        #expect(decoded.courseData.schoolCourses(for: repeating.term) == originals)
        #expect(decoded.cachedCoursesByTerm[repeating.term] == originals)
        #expect(decoded.termSchedulesByTerm[repeating.term]?.courses == originals)
    }

    @Test("Day transfer keeps school snapshots raw and persists a manual rule")
    func transferPreservesRawCourses() throws {
        let source = course(id: "source", number: "MATH-1", weeks: [1, 2, 3], weekday: 2)
        let target = course(id: "target", number: "ENG-1", weeks: [2], weekday: 4)
        let originals = [source, target]
        let movedCourses = try ScheduleCourseEditor.transferring(
            courses: originals,
            fromWeek: 2,
            fromWeekday: 2,
            toWeek: 2,
            toWeekday: 4,
            makeID: { "moved" }
        )
        var cache = manualEditCache(with: originals)

        ScheduleCourseEditor.updateCacheForManualCourseChange(
            in: &cache,
            previousCourses: originals,
            currentCourses: movedCourses
        )

        #expect(cache.courses == movedCourses)
        #expect(cache.courseData.schoolCourses(for: source.term) == originals)
        #expect(cache.cachedCoursesByTerm[source.term] == originals)
        #expect(cache.termSchedulesByTerm[source.term]?.courses == originals)
        let restoredMovedCourses = ScheduleCourseEditor.reconcile(
            rules: cache.manualCourseRulesByTerm[source.term] ?? [],
            with: originals
        )
        #expect(Set(restoredMovedCourses.courses) == Set(movedCourses))

        let decoded = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(Set(decoded.courses) == Set(movedCourses))
        #expect(decoded.courseData.schoolCourses(for: source.term) == originals)
        #expect(decoded.cachedCoursesByTerm[source.term] == originals)
        #expect(decoded.termSchedulesByTerm[source.term]?.courses == originals)
    }

    @Test("Changes in another course leave this rule active")
    func unrelatedCourseChangeLeavesRuleActive() {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        let other = course(id: "other", number: "ENG-1", weeks: [1, 2, 3])
        let changedOther = course(id: "other", number: "ENG-1", weeks: [4, 5], weekday: 4)
        let rule = ScheduleCourseRule(
            sourceIdentity: scheduleCourseSourceIdentity(original),
            sourceCourses: [original],
            replacementCourses: [replacement]
        )

        let result = ScheduleCourseEditor.reconcile(
            rules: [rule],
            with: [original, changedOther]
        )

        #expect(result.invalidRules.isEmpty)
        #expect(Set(result.courses) == Set([replacement, changedOther]))
        #expect(other != changedOther)
    }

    @Test("Any source change removes the corresponding manual rule")
    func changedSourceRemovesManualRule() {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let changed = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], classroom: "新教室")
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        let rule = ScheduleCourseRule(
            sourceIdentity: scheduleCourseSourceIdentity(original),
            sourceCourses: [original],
            replacementCourses: [replacement]
        )

        let result = ScheduleCourseEditor.reconcile(
            rules: [rule],
            with: [changed]
        )

        #expect(result.validRules.isEmpty)
        #expect(result.invalidRules.count == 1)
        #expect(result.courses == [changed])
    }

    @Test("Manual course rules survive cache encoding")
    func manualCourseRuleCacheRoundTrip() throws {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        let replacement = course(id: "course", number: "MATH-1", weeks: [1, 2, 3], weekday: 5)
        var cache = ScheduleCache()
        cache.currentTerm = original.term
        cache.courseData.store(TermScheduleSnapshot(term: original.term, firstDayString: "",
            courses: [original], exams: [], updatedAt: .distantPast))
        cache.manualCourseRulesByTerm[original.term] = [
            ScheduleCourseRule(
                sourceIdentity: scheduleCourseSourceIdentity(original),
                sourceCourses: [original],
                replacementCourses: [replacement]
            )
        ]

        let decoded = try JSONDecoder().decode(
            ScheduleCache.self,
            from: JSONEncoder().encode(cache)
        )

        #expect(decoded.courses == [replacement])
        #expect(decoded.manualCourseRulesByTerm[original.term]?.count == 1)
        #expect(decoded.courseData.schoolCourses(for: original.term) == [original])
    }

    @Test("Course editing rejects discontinuous sections")
    func discontinuousSectionsAreRejected() {
        var draft = CourseDraft(title: "课程", weeksText: "1")
        draft.selectedSections = [3, 5]
        draft.startSection = 3
        draft.endSection = 5

        #expect(throws: Error.self) {
            try ScheduleCourseEditor.resolve(draft)
        }
    }

    @Test("Course editing blocks overlaps with an existing course")
    func courseConflictIsBlocking() {
        let candidate = course(
            id: "candidate",
            number: "MATH-1",
            weeks: [2],
            weekday: 1,
            startSection: 3,
            endSection: 4
        )
        let existing = course(
            id: "existing",
            number: "ENG-1",
            weeks: [2],
            weekday: 1,
            startSection: 4,
            endSection: 5
        )

        #expect(
            ScheduleCourseEditor.conflictDescription(
                candidates: [candidate],
                against: [existing]
            ) != nil
        )
    }

    @Test("School authentication timeout uses the transport failure path")
    func schoolAuthenticationTimeoutClassification() {
        let error = ScheduleServiceError.challengeInvalid("统一身份认证请求超时，请稍后重试")

        #expect(error.isSchoolTransportFailure)
    }

    @Test("Course week parser accepts Chinese commas and removes duplicates")
    func courseWeekParser() throws {
        #expect(try ScheduleCourseEditor.parseWeeks("1-3，3，5") == [1, 2, 3, 5])
        #expect(ScheduleWeekCodec.formatWeeks([5, 3, 2, 1, 3]) == "1-3,5")
    }

    @Test("Course editor rejects malformed week ranges")
    func courseWeekParserRejectsMalformedRanges() {
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("0-3") }
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("3-1") }
        #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks("1,a") }
    }

    @Test("Occurrence editing splits a repeated course")
    func occurrenceEditingSplitsRepeatedCourse() throws {
        let original = course(id: "course", number: "MATH-1", weeks: [1, 2, 3])
        var draft = CourseDraft(title: "调整后的课", weeksText: "")
        draft.weekday = 5

        let result = try ScheduleCourseEditor.updatingOccurrence(
            id: original.id,
            week: 2,
            with: draft,
            in: [original],
            adjustedID: "adjusted"
        )

        #expect(result.count == 2)
        #expect(result[0].weeks == [1, 3])
        #expect(result[1].id == "adjusted")
        #expect(result[1].weeks == [2])
        #expect(result[1].weekday == 5)
    }

    @Test("Arrangement editing merges separated weeks")
    func arrangementEditingMergesSeparatedWeeks() throws {
        let firstPart = course(id: "course-a", number: "SOFT-1", weeks: [1, 2, 3, 4, 5])
        let secondPart = course(id: "course-b", number: "SOFT-1", weeks: [7, 8, 9])
        var draft = CourseDraft(title: "软件工程导论", weeksText: "1-5,7-9")
        draft.weekday = 2
        draft.startSection = 3
        draft.endSection = 4

        let result = try ScheduleCourseEditor.updatingArrangement(
            id: firstPart.id,
            with: draft,
            in: [firstPart, secondPart]
        )

        #expect(result.count == 1)
        #expect(result[0].id == firstPart.id)
        #expect(result[0].weeks == [1, 2, 3, 4, 5, 7, 8, 9])
        #expect(result[0].weekday == 2)
        #expect(result[0].startSection == 3)
        #expect(result[0].endSection == 4)
    }

    @Test("Whole-course deletion removes every separated arrangement")
    func wholeCourseDeletionRemovesSeparatedWeeks() {
        let firstPart = course(id: "course-a", number: "SOFT-1", weeks: [1, 2, 3, 4, 5])
        let secondPart = course(id: "course-b", number: "SOFT-1", weeks: [7, 8, 9])
        let other = course(id: "other", number: "MATH-1", weeks: [1, 2])

        let result = ScheduleCourseEditor.deleting(id: firstPart.id, from: [firstPart, secondPart, other])

        #expect(result.map(\.id) == ["other"])
    }

    @Test("Arrangement editing keeps other time arrangements")
    func arrangementEditingKeepsOtherTimes() throws {
        let monday = course(id: "monday", number: "SOFT-1", weeks: [1, 2, 3], weekday: 3)
        let thursday = course(id: "thursday", number: "SOFT-1", weeks: [1, 2, 3], weekday: 4)
        let friday = course(id: "friday", number: "SOFT-1", weeks: [4, 5], weekday: 5)
        var draft = CourseDraft(title: "软件工程导论", weeksText: "1-3")
        draft.weekday = 6

        let result = try ScheduleCourseEditor.updatingArrangement(
            id: monday.id,
            with: draft,
            in: [monday, thursday, friday]
        )

        #expect(result.count == 3)
        #expect(result.first(where: { $0.id == monday.id })?.weekday == 6)
        #expect(result.first(where: { $0.id == thursday.id })?.weekday == 4)
        #expect(result.first(where: { $0.id == friday.id })?.weekday == 5)
    }

    @Test("Different locations create independent arrangements")
    func arrangementEditingSeparatesLocations() throws {
        let literary = course(id: "literary", number: "SOFT-1", weeks: [1, 2], weekday: 1, classroom: "文萃楼F404")
        let comprehensive = course(id: "comprehensive", number: "SOFT-1", weeks: [1, 2], weekday: 1, classroom: "综教A101")
        var draft = CourseDraft(title: "软件工程导论", weeksText: "1-2")
        draft.classroom = "文萃楼F405"

        let result = try ScheduleCourseEditor.updatingArrangement(
            id: literary.id,
            with: draft,
            in: [literary, comprehensive]
        )

        #expect(result.first(where: { $0.id == literary.id })?.classroom == "文萃楼F405")
        #expect(result.first(where: { $0.id == comprehensive.id })?.classroom == "综教A101")
    }

    @Test("Deleting the last occurrence removes the course")
    func deletingLastOccurrenceRemovesCourse() {
        let original = course(id: "course", number: "MATH-1", weeks: [2])

        #expect(ScheduleCourseEditor.deletingOccurrence(id: original.id, week: 2, from: [original]).isEmpty)
    }

    @Test("Transferring a day clears source and target occurrences")
    func transferringCourses() throws {
        let source = course(id: "source", number: "MATH-1", weeks: [2], weekday: 1)
        let target = course(id: "target", number: "ENG-1", weeks: [3], weekday: 5)

        let result = try ScheduleCourseEditor.transferring(
            courses: [source, target],
            fromWeek: 2,
            fromWeekday: 1,
            toWeek: 3,
            toWeekday: 5,
            makeID: { "moved" }
        )

        #expect(result.count == 1)
        #expect(result[0].id == "moved")
        #expect(result[0].weeks == [3])
        #expect(result[0].weekday == 5)
    }

    @Test("DDL merge keeps manual items and sorts all events")
    func ddlMerge() {
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = Date(timeIntervalSince1970: 200)
        let manual = DDLEventRecord(id: "manual", group: "main", title: "手动", text: "", dueAt: newDate, done: true)
        let synced = DDLEventRecord(id: "synced", group: "lexue", title: "乐学", text: "", dueAt: oldDate, done: false)
        let oldSynced = DDLEventRecord(id: "old-synced", group: "lexue", title: "旧", text: "", dueAt: Date(timeIntervalSince1970: 50), done: true)

        let result = ScheduleDDLEditor.mergingSyncedEvents([synced], into: [manual, oldSynced])

        #expect(result.map(\.id) == ["synced", "manual"])
        #expect(result.first?.done == false)
    }

    @Test("DDL editor rejects blank titles")
    func ddlTitleValidation() {
        let draft = DDLDraft(title: "  ")
        #expect(throws: Error.self) { try ScheduleDDLEditor.adding(draft, to: []) }
    }

    private func course(
        id: String,
        number: String,
        weeks: [Int] = [1],
        weekday: Int = 1,
        classroom: String = "教室",
        startSection: Int = 1,
        endSection: Int = 2
    ) -> CourseRecord {
        CourseRecord(
            id: id,
            term: "2026-2027-1",
            name: number,
            teacher: "教师",
            classroom: classroom,
            description: "",
            weeks: weeks,
            weekday: weekday,
            startSection: startSection,
            endSection: endSection,
            campus: "",
            number: number,
            credit: 2,
            hour: 32,
            type: "",
            category: "",
            department: ""
        )
    }

    private func manualEditCache(with courses: [CourseRecord]) -> ScheduleCache {
        let term = courses[0].term
        var cache = ScheduleCache()
        cache.currentTerm = term
        cache.courseData.store(TermScheduleSnapshot(
            term: term,
            firstDayString: "2026-09-07",
            courses: courses,
            exams: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        return cache
    }
}

@MainActor
struct AppScheduleCacheEffectsTests {
    private final class State {
        let session = AppStorageSession(accountIdentifier: "effects-account")
        var generation = 0
        var identity: CommunitySessionIdentity { CommunitySessionIdentity(accountIdentifier: session.accountIdentifier, generation: generation) }
        var pushes = 0
        var reconciliations = 0
        var authorizations = 0
        var refreshes: [String] = []
        var changeGenerationDuringAuthorization = false
        var importedCourses: ScheduleCourseSnapshot?
        var importedDrafts: [ScheduleSystemCalendarEventDraft] = []
        var calendarTerm: String?
        var deletedMarkers = Set<String>()
        var deleteAllCount = 0
        var pushWaiter: CheckedContinuation<Void, Never>?

        func waitForPush() async {
            if pushes > 0 { return }
            await withCheckedContinuation { pushWaiter = $0 }
        }
    }

    private func effects(_ state: State) -> AppScheduleCacheEffects {
        AppScheduleCacheEffects(
            currentSession: { state.session }, currentIdentity: { state.identity },
            pushCloud: { state.pushes += 1; state.pushWaiter?.resume(); state.pushWaiter = nil },
            reconcileCloud: { state.reconciliations += 1 },
            requestReminderAuthorization: {
                state.authorizations += 1
                if state.changeGenerationDuringAuthorization { state.generation += 1 }
            },
            refreshReminder: { state.refreshes.append($0) },
            importCourses: { state.importedCourses = $0; state.calendarTerm = $1; return 7 },
            importDrafts: { state.importedDrafts = $0; state.calendarTerm = $1; return $0.count },
            deleteEntries: { state.deletedMarkers = $0; state.calendarTerm = $1; return .changed($0.count) },
            deleteAllEntries: { state.deleteAllCount += 1; return .changed(3) }
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func injectedCloudAndReminderActionsRespectAccountOwnership() async {
        let selected = State()
        let surrounding = State()
        let actions = effects(selected)
        let other = AppStorageSession(accountIdentifier: "other-account")
        await actions.didSave(session: other, source: .local, cloudSyncEnabled: true)
        await actions.didSave(session: selected.session, source: .cloud, cloudSyncEnabled: true)
        await actions.didSave(session: selected.session, source: .local, cloudSyncEnabled: false)
        await actions.enableCloudSync(session: other)
        await actions.enableCourseReminder(session: other)
        #expect(selected.pushes == 0 && selected.reconciliations == 0 && selected.authorizations == 0)
        await actions.didSave(session: selected.session, source: .local, cloudSyncEnabled: true)
        await selected.waitForPush()
        await actions.enableCloudSync(session: selected.session)
        await actions.enableCourseReminder(session: selected.session)
        #expect(selected.pushes == 1 && selected.reconciliations == 1 && selected.authorizations == 1)
        #expect(selected.refreshes == ["reminder_toggle_enabled"])
        selected.changeGenerationDuringAuthorization = true
        await actions.enableCourseReminder(session: selected.session)
        #expect(selected.authorizations == 2)
        #expect(selected.refreshes.count == 1)
        #expect(surrounding.pushes == 0 && surrounding.reconciliations == 0 && surrounding.authorizations == 0)
    }

    @Test func calendarActionsUseInjectedBackendAndPreserveEntryIdentity() async throws {
        let state = State()
        let actions = effects(state)
        let snapshot = ScheduleCache().courseSnapshot
        #expect(try await actions.importSystemCalendar(courses: snapshot, term: "term") == 7)
        #expect(state.importedCourses == snapshot && state.calendarTerm == "term")
        let content = ScheduleSystemCalendarContent.customSchedule(CustomScheduleRecord(id: "effects-entry",
            title: "日程", subtitle: "", description: "", dateString: "2026-09-07", beginTime: "09:00", endTime: "10:00"))
        #expect(try await actions.importSystemCalendarEntries(content, term: "term") == 1)
        #expect(state.importedDrafts.first?.title == "日程")
        #expect(try await actions.deleteSystemCalendarEntries(content, term: "term") == .changed(1))
        #expect(state.deletedMarkers == Set(state.importedDrafts.map(\.markerID)))
        #expect(try await actions.deleteSystemCalendarEntries(markerIDs: ["selected-entry"], term: "selected-term") == .changed(1))
        #expect(state.deletedMarkers == ["selected-entry"] && state.calendarTerm == "selected-term")
        #expect(try await actions.deleteImportedSystemCalendarEvents() == .changed(3))
        #expect(state.deleteAllCount == 1)
    }
}
