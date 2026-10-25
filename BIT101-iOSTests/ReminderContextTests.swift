import Foundation
import BackgroundTasks
import Combine
import CommunityTransport
import ScheduleSync
import ScheduleDomain
import StorageCore
import Testing
@testable import BIT101_iOS

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import UserNotifications

@MainActor
private final class ReminderNotificationCenterFixture: ScheduleReminderNotificationCenter {
    var authorization: UNAuthorizationStatus = .authorized
    var pending: [String: UNNotificationRequest] = [:]
    var delivered: [String] = []
    var failedAdds = Set<Int>()
    var additions = 0
    var beforeAdd: ((UNNotificationRequest) async -> Void)?
    func authorizationStatus() async -> UNAuthorizationStatus { authorization }
    func pendingRequests() async -> [UNNotificationRequest] { Array(pending.values) }
    func deliveredIdentifiers() async -> [String] { delivered }
    func add(_ request: UNNotificationRequest) async throws {
        additions += 1
        await beforeAdd?(request)
        pending[request.identifier] = request
        if failedAdds.contains(additions) { throw CocoaError(.fileWriteUnknown) }
    }
    func removePending(_ identifiers: [String]) { for identifier in identifiers { pending.removeValue(forKey: identifier) } }
    func removeDelivered(_ identifiers: [String]) { delivered.removeAll { identifiers.contains($0) } }
    func requestAuthorization() async throws -> Bool { authorization == .authorized }
}

extension ReminderContextTests {
    @Test(.timeLimit(.minutes(1))) func pendingCredentialsPreserveNotificationsUntilTheSessionResolves() async {
        let (center, session, _) = notificationFixture()
        let original = center.pending.mapValues(\.content.title)
        var resolved = false
        let signedOut = ScheduleReminderSession(studentID: "", storage: session.storage, generation: 0, signedIn: false)
        let context = ScheduleReminderContext(currentSession: { signedOut }, isSessionResolved: { resolved }, loadCache: { _ in .missing })
        let manager = ScheduleLiveActivityManager(context: context, notificationCenter: center)
        await manager.refreshFromCurrentCache()
        #expect(center.pending.mapValues(\.content.title) == original)
        await #expect(throws: CocoaError(.fileReadNoPermission)) { try await manager.preferredBackgroundRefreshBeginDate() }
        resolved = true
        await manager.refreshFromCurrentCache()
        #expect(Set(center.pending.keys) == ["other"] && center.delivered == ["other"])
    }

    @Test(.timeLimit(.minutes(1))) func unreadableCachePreservesNotificationsAndBackgroundScheduleUntilRecovery() async {
        let (center, session, _) = notificationFixture()
        let original = center.pending.mapValues(\.content.title)
        let delivered = center.delivered
        var result = ScheduleCacheLoadResult.unreadable
        let context = ScheduleReminderContext(currentSession: { session }, isSessionResolved: { true }, loadCache: { _ in result })
        let manager = ScheduleLiveActivityManager(context: context, notificationCenter: center)
        await manager.refreshFromCurrentCache()
        #expect(center.pending.mapValues(\.content.title) == original && center.delivered == delivered)
        var scheduled: [Date?] = []
        var refreshed = 0
        func refresh() async -> Bool {
            await ScheduleReminderBackgroundRefresh.refreshIfCurrent(isCurrent: { true },
                nextBeginDate: { try await manager.preferredBackgroundRefreshBeginDate() },
                schedule: { scheduled.append($0); return true },
                refresh: { refreshed += 1; await manager.refreshFromCurrentCache() })
        }
        #expect(await refresh() == false)
        #expect(scheduled.isEmpty && refreshed == 0)
        #expect(center.pending.mapValues(\.content.title) == original && center.delivered == delivered)
        result = .missing
        #expect(await refresh())
        #expect(scheduled.count == 1 && scheduled[0] == nil && refreshed == 1)
        #expect(Set(center.pending.keys) == ["other"] && center.delivered == ["other"])
    }

    private func notificationFixture() -> (ReminderNotificationCenterFixture, ScheduleReminderSession, [CourseReminderOccurrence]) {
        let center = ReminderNotificationCenterFixture()
        for identifier in ["BIT101.ScheduleReminder.A.0", "BIT101.ScheduleReminder.A.1", "BIT101.ScheduleReminder.A.9", "other"] {
            let content = UNMutableNotificationContent()
            content.title = "原提醒"
            center.pending[identifier] = UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false))
        }
        center.delivered = ["BIT101.ScheduleReminder.A.9", "other"]
        let session = ScheduleReminderSession(studentID: "A", storage: AppStorageSession(accountIdentifier: "A"), generation: 1, signedIn: true)
        let occurrences = (1...3).map { index in
            let start = Date().addingTimeInterval(Double(index) * 3600)
            return CourseReminderOccurrence(kindText: "上课", title: "新课程", classroom: "", teacher: "",
                startDate: start, endDate: start.addingTimeInterval(1800))
        }
        return (center, session, occurrences)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [1, 2, 3])
    func failedNotificationReplacementRestoresAcceptedRequestsEvenAfterACommit(failedAdd: Int) async throws {
        let (center, session, occurrences) = notificationFixture()
        let original = center.pending.mapValues(\.content.title)
        center.failedAdds = [failedAdd]
        await #expect(throws: CocoaError.self) {
            _ = try await ScheduleReminderNotifications(center: center).synchronize(for: occurrences, leadMinutes: 10,
                session: session, isCurrent: { true })
        }
        #expect(center.pending.mapValues(\.content.title) == original)
        #expect(center.delivered == ["BIT101.ScheduleReminder.A.9", "other"])
    }

    @Test(.timeLimit(.minutes(1))) func acceptedNotificationReplacementReportsTheActualCountAndRemovesObsoleteRequests() async throws {
        let (center, session, occurrences) = notificationFixture()
        let count = try await ScheduleReminderNotifications(center: center).synchronize(for: occurrences, leadMinutes: 10,
            session: session, isCurrent: { true })
        #expect(count == 3 && center.additions == 3)
        #expect(center.pending.count == 4 && center.pending["BIT101.ScheduleReminder.A.9"] == nil)
        #expect(center.pending["other"]?.content.title == "原提醒")
        #expect(center.delivered == ["other"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["empty", "denied"])
    func emptyOrUnauthorizedNotificationPlansClearTheirOwnedRequests(boundary: String) async throws {
        let (center, session, occurrences) = notificationFixture()
        if boundary == "denied" { center.authorization = .denied }
        let count = try await ScheduleReminderNotifications(center: center).synchronize(
            for: boundary == "empty" ? [] : occurrences, leadMinutes: 10, session: session, isCurrent: { true })
        #expect(count == 0 && center.additions == 0)
        #expect(Set(center.pending.keys) == ["other"] && center.delivered == ["other"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["cancel", "account"])
    func interruptedNotificationReplacementKeepsTheCurrentOwner(boundary: String) async throws {
        let (center, session, occurrences) = notificationFixture()
        let original = center.pending.mapValues(\.content.title)
        var current = true
        let gate = AsyncStream<Void>.makeStream()
        var entered = false
        center.beforeAdd = { _ in
            center.beforeAdd = nil
            entered = true
            var events = gate.stream.makeAsyncIterator()
            _ = await events.next()
        }
        let task = Task {
            try await ScheduleReminderNotifications(center: center).synchronize(for: occurrences, leadMinutes: 10,
                session: session, isCurrent: { current })
        }
        defer { task.cancel(); gate.continuation.finish() }
        try await waitForTestEvent { entered }
        if boundary == "cancel" { task.cancel() } else { current = false }
        gate.continuation.yield(())
        gate.continuation.finish()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        if boundary == "cancel" { #expect(center.pending.mapValues(\.content.title) == original) }
        else { #expect(center.pending["BIT101.ScheduleReminder.A.0"] == nil) }
        #expect(center.pending["other"]?.content.title == "原提醒")
    }

    @Test(.timeLimit(.minutes(1))) func notificationRollbackFailureReachesTheCaller() async {
        let (center, session, occurrences) = notificationFixture()
        center.failedAdds = [2, 3]
        do {
            _ = try await ScheduleReminderNotifications(center: center).synchronize(for: occurrences, leadMinutes: 10,
                session: session, isCurrent: { true })
            Issue.record("系统恢复失败应传递到调用方")
        } catch {
            #expect(error.localizedDescription.contains("1 条原提醒恢复失败"))
        }
    }
}
#endif

@MainActor
struct ReminderContextTests {
    @Test(arguments: ["replace", "failure", "clear"])
    func backgroundPlanReplacementPreservesThePreviousPlanWhenSubmissionFails(operation: String) {
        let previous = Date(timeIntervalSince1970: 100), replacement = Date(timeIntervalSince1970: 200)
        var pending: Date? = previous
        var events: [String] = []
        let success = ScheduleReminderBackgroundRefresh.schedule(earliestBeginDate: operation == "clear" ? nil : replacement,
            submit: { request in
                events.append("submit")
                if operation == "failure" { throw BGTaskScheduler.Error(.unavailable) }
                pending = request.earliestBeginDate
            }, cancel: { events.append("cancel"); pending = nil })
        #expect(success == (operation != "failure"))
        #expect(events == [operation == "clear" ? "cancel" : "submit"])
        #expect(pending == (operation == "failure" ? previous : operation == "replace" ? replacement : nil))
    }

    @Test(.timeLimit(.minutes(1))) func unreadableReminderStatePreservesTheExternalDisplaySchedule() async {
        let session = AppStorageSession(accountIdentifier: "reminder-read-failure")
        var unreadable = true
        var events: [String] = []
        let adapter = AppExternalDisplayCoordinator(currentSession: { session }, isSessionResolved: { true }, isSignedIn: { true },
            activateWatch: {}, resetPresentation: {}, exportWidget: { events.append("widget") },
            nextReminderRefresh: {
                if unreadable { throw CocoaError(.fileReadCorruptFile) }
                return nil
            }, scheduleBackgroundRefresh: { _ in events.append("schedule") },
            endActivities: { events.append("end") }, refreshActivities: { events.append($0) })
        await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: true, session: session)
        #expect(events == ["widget"])
        unreadable = false
        await adapter.refresh(trigger: "refresh", syncWidgetSnapshot: true, session: session)
        #expect(events == ["widget", "widget", "schedule", "refresh"])
    }

    @Test(.timeLimit(.minutes(1)))
    func firedTimerCanRearmWhileItsRefreshContinues() async throws {
        let timer = ScheduleReminderTimer()
        var wasCancelled = true
        var completed = false
        defer { timer.cancel() }
        timer.schedule(after: .zero) {
            let refresh = Task { @MainActor in
                timer.schedule(after: .seconds(3600)) { Issue.record("Future timer fired during the current refresh") }
                await Task.yield()
                wasCancelled = Task.isCancelled
            }
            await withTaskCancellationHandler { await refresh.value } onCancel: { refresh.cancel() }
            completed = true
        }
        try await waitForTestEvent { completed }
        #expect(wasCancelled == false)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledWaitingTimerLeavesItsActionUnexecuted() async {
        let timer = ScheduleReminderTimer()
        var calls = 0
        timer.schedule(after: .zero) { calls += 1 }
        timer.cancel()
        await Task.yield()
        #expect(calls == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["current", "cancelled", "account"])
    func backgroundRefreshRespectsTheOwnerAfterItsSuspendedRead(boundary: String) async throws {
        var current = true
        let gate = AsyncStream<Date>.makeStream()
        var readStarted = false
        var scheduled: [Date?] = []
        var refreshed = 0
        let target = Date(timeIntervalSince1970: 3900)
        let task = Task {
            await ScheduleReminderBackgroundRefresh.refreshIfCurrent(isCurrent: { current },
                nextBeginDate: {
                    readStarted = true
                    var events = gate.stream.makeAsyncIterator()
                    return await events.next()
                },
                schedule: { scheduled.append($0); return true }, refresh: { refreshed += 1 })
        }
        defer { task.cancel(); gate.continuation.finish() }
        try await waitForTestEvent { readStarted }
        if boundary == "cancelled" { task.cancel() }
        if boundary == "account" { current = false }
        gate.continuation.yield(target)
        gate.continuation.finish()
        let completed = await task.value
        #expect(completed == (boundary == "current"))
        #expect(scheduled == (boundary == "current" ? [target] : []) && refreshed == (boundary == "current" ? 1 : 0))
    }

    @Test(.timeLimit(.minutes(1))) func failedReschedulingKeepsTheCurrentRefreshAndReportsFailure() async {
        var refreshed = 0
        let completed = await ScheduleReminderBackgroundRefresh.refreshIfCurrent(isCurrent: { true },
            nextBeginDate: { Date() }, schedule: { _ in false }, refresh: { refreshed += 1 })
        #expect(refreshed == 1)
        #expect(completed == false)
    }

    @Test(arguments: [0.5, 1.0, 1.5])
    func aRefreshImmediatelyBeforeTheWindowKeepsBothReminderTriggers(_ remaining: Double) {
        let course = CourseReminderOccurrence(kindText: "上课", title: "边界", classroom: "", teacher: "",
            startDate: Date(timeIntervalSince1970: 3900), endDate: Date(timeIntervalSince1970: 4500))
        let now = Date(timeIntervalSince1970: 3300 - remaining)
        #expect(ScheduleReminderPlanner.nextFutureRefreshPoint(for: [course], leadMinutes: 10, now: now) == Date(timeIntervalSince1970: 3300))
        #expect(ScheduleReminderNotificationDate.futureDisplayDate(for: course, among: [course], leadMinutes: 10, now: now) == Date(timeIntervalSince1970: 3300))
        let components = ScheduleReminderNotificationDate.components(for: Date(timeIntervalSince1970: 3300.5))
        #expect(components.calendar?.date(from: components) == Date(timeIntervalSince1970: 3301))
    }
    @Test(.timeLimit(.minutes(1))) func delayedCacheLoadHonorsItsCapturedAccountGeneration() async throws {
        var current = ScheduleReminderSession(studentID: "A", storage: AppStorageSession(accountIdentifier: "A"), generation: 1, signedIn: true)
        let gate = AsyncStream<ScheduleCache>.makeStream()
        var entered = false
        let context = ScheduleReminderContext(currentSession: { current }, isSessionResolved: { true }, loadCache: { captured in
            #expect(captured.accountIdentifier == "A")
            entered = true
            var events = gate.stream.makeAsyncIterator()
            return .loaded(await events.next() ?? ScheduleCache())
        })
        let task = Task { try? await context.loadCurrentCache() }
        defer { task.cancel(); gate.continuation.finish() }
        try await waitForTestEvent { entered }
        current = ScheduleReminderSession(studentID: "A", storage: current.storage, generation: 3, signedIn: true)
        gate.continuation.yield(ScheduleCache())
        gate.continuation.finish()
        #expect(await task.value == nil)
    }

    @Test(.timeLimit(.minutes(1))) func currentSnapshotUsesTheInjectedAccountPartition() async throws {
        let session = ScheduleReminderSession(studentID: "B", storage: AppStorageSession(accountIdentifier: "B"), generation: 1, signedIn: true)
        let context = ScheduleReminderContext(currentSession: { session }, isSessionResolved: { true }, loadCache: { storage in
            #expect(storage == session.storage)
            var cache = ScheduleCache()
            cache.primaryScheduleTitle = "injected reminder"
            return .loaded(cache)
        })
        let value = try await context.loadCurrentCache()
        #expect(value.session == session)
        #expect(value.cache.primaryScheduleTitle == "injected reminder")
    }
}

@MainActor
struct ReminderPlannerTests {
    @Test(arguments: [false, true])
    func simultaneousActivitiesHaveAnOrderIndependentReminder(reverse: Bool) {
        func occurrence(_ title: String, start: Double, end: Double) -> CourseReminderOccurrence {
            .init(kindText: "日程", title: title, classroom: "", teacher: "",
                startDate: Date(timeIntervalSince1970: start), endDate: Date(timeIntervalSince1970: end))
        }
        let long = occurrence("长活动", start: 0, end: 10800), short = occurrence("短活动", start: 0, end: 3600)
        let next = occurrence("下一项", start: 4500, end: 8100)
        let activities = (reverse ? [short, long] : [long, short]) + [next]
        #expect(ScheduleReminderPlanner.displayWindowStarts(for: activities, leadMinutes: 30).last == Date(timeIntervalSince1970: 4200))
        #expect(ScheduleReminderPlanner.effectiveDisplayWindowStart(for: next, among: activities, leadMinutes: 30) == Date(timeIntervalSince1970: 4200))
    }
    @Test(arguments: [1, 5, 30, 60])
    func bulkReminderWindowsPreserveOverlapsAndSimultaneousStarts(leadMinutes: Int) {
        let occurrences = (0..<120).map { index in
            let start = index / 3 * 600
            let duration = (index % 7 + 1) * 900
            return CourseReminderOccurrence(kindText: "日程", title: "\(index)", classroom: "", teacher: "",
                startDate: Date(timeIntervalSince1970: Double(start)),
                endDate: Date(timeIntervalSince1970: Double(start + duration)))
        }
        let starts = ScheduleReminderPlanner.displayWindowStarts(for: occurrences, leadMinutes: leadMinutes)
        #expect(starts == occurrences.map {
            ScheduleReminderPlanner.effectiveDisplayWindowStart(for: $0, among: occurrences, leadMinutes: leadMinutes)
        })
    }

    @Test func bulkReminderWindowsHandleAnEntireLargeSchedule() {
        let occurrences = (0..<10_400).map { index in
            let start = Double(index * 7200)
            return CourseReminderOccurrence(kindText: "上课", title: "\(index)", classroom: "", teacher: "",
                startDate: Date(timeIntervalSince1970: start),
                endDate: Date(timeIntervalSince1970: start + 3600))
        }
        #expect(ScheduleReminderPlanner.displayWindowStarts(for: occurrences, leadMinutes: 30) ==
            occurrences.map { $0.startDate.addingTimeInterval(-1800) })
        #expect(ScheduleReminderPlanner.nextFutureRefreshPoint(for: occurrences, leadMinutes: 30,
            now: Date(timeIntervalSince1970: 1)) == Date(timeIntervalSince1970: 5400))
    }

    @Test(arguments: [Int.min, -1, 0, 1, 60, 61, Int.max])
    func reminderWindowsApplyTheLeadMinuteBounds(leadMinutes: Int) {
        let occurrence = CourseReminderOccurrence(kindText: "上课", title: "提前量边界", classroom: "", teacher: "",
            startDate: Date(timeIntervalSince1970: 7200), endDate: Date(timeIntervalSince1970: 10800))
        let expectedStart = Date(timeIntervalSince1970: leadMinutes < 1 ? 7140 : leadMinutes > 60 ? 3600 : 7200 - Double(leadMinutes * 60))
        #expect(ScheduleReminderPlanner.effectiveDisplayWindowStart(
            for: occurrence, among: [occurrence], leadMinutes: leadMinutes) == expectedStart)
        #expect(ScheduleReminderPlanner.nextFutureRefreshPoint(
            for: [occurrence], leadMinutes: leadMinutes, now: Date(timeIntervalSince1970: 0)) == expectedStart)
    }

    @Test func reminderCandidatesIncludeTheWeeksBeforeSemesterStart() throws {
        var cache = ScheduleCache()
        cache.currentTerm = "2030-2031-1"
        cache.manualFirstDayStringsByTerm[cache.currentTerm] = "2030-09-16"
        let courses = try ScheduleCourseEditor.adding(CourseDraft(title: "首周前课程", weekday: 1,
            startSection: 1, endSection: 1, weeksText: "-2,-1,1"), to: [], term: cache.currentTerm, id: "negative-reminder")
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: [], currentCourses: courses)
        let now = try #require(ScheduleDateCodec.parseDate("2030-09-01"))
        let occurrences = ScheduleReminderPlanner.resolveOccurrences(from: cache, now: now)
        #expect(occurrences.map { ScheduleDateCodec.formatDate($0.startDate) } == ["2030-09-02", "2030-09-09", "2030-09-16"])
    }

    @Test func reminderWindowsRespectThePreviousOccurrenceAndNextBoundary() {
        let previous = CourseReminderOccurrence(kindText: "上课", title: "previous", classroom: "", teacher: "",
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 3600))
        let next = CourseReminderOccurrence(kindText: "日程", title: "next", classroom: "", teacher: "",
            startDate: Date(timeIntervalSince1970: 3900), endDate: Date(timeIntervalSince1970: 4500))
        let occurrences = [previous, next]
        #expect(ScheduleReminderPlanner.effectiveDisplayWindowStart(for: next, among: occurrences, leadMinutes: 30) == Date(timeIntervalSince1970: 3300))
        #expect(ScheduleReminderPlanner.nextFutureRefreshPoint(for: occurrences, leadMinutes: 30,
            now: Date(timeIntervalSince1970: 3200)) == Date(timeIntervalSince1970: 3300))
        #expect(ScheduleReminderPlanner.nextFutureRefreshPoint(for: occurrences, leadMinutes: 30,
            now: Date(timeIntervalSince1970: 3300)) == next.startDate)
        #expect(ScheduleReminderPlanner.nextFutureRefreshPoint(for: occurrences, leadMinutes: 30,
            now: next.endDate) == nil)
    }

    @Test(arguments: [4800.0, 7200.0], [1, 5, 30])
    func overlappingOccurrencesRetainAFutureReminderWindow(previousEnd: Double, leadMinutes: Int) {
        let previous = CourseReminderOccurrence(kindText: "日程", title: "长日程", classroom: "", teacher: "",
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: previousEnd))
        let next = CourseReminderOccurrence(kindText: "上课", title: "重叠课程", classroom: "", teacher: "",
            startDate: Date(timeIntervalSince1970: 3900), endDate: Date(timeIntervalSince1970: 4500))
        let occurrences = [previous, next]
        let display = ScheduleReminderPlanner.effectiveDisplayWindowStart(for: next, among: occurrences, leadMinutes: leadMinutes)
        #expect(display == Date(timeIntervalSince1970: leadMinutes == 1 ? 3840 : 3600))
        #expect(display < next.startDate)
        #expect(ScheduleReminderPlanner.nextFutureRefreshPoint(for: occurrences, leadMinutes: leadMinutes,
            now: Date(timeIntervalSince1970: 3300)) == display)
        #expect(ScheduleReminderPlanner.nextFutureRefreshPoint(for: occurrences, leadMinutes: leadMinutes, now: display) == next.startDate)
    }

    @Test func reminderCandidatesKeepValidFutureOccurrencesAndDeduplicateIDs() throws {
        var cache = ScheduleCache()
        let valid = CustomScheduleRecord(id: "future", title: "未来日程", subtitle: " 地点 ", description: "",
            dateString: "2030-09-02", beginTime: "10:00", endTime: "11:00")
        cache.customSchedules = [valid, valid,
            CustomScheduleRecord(id: "expired", title: "过去", subtitle: "", description: "", dateString: "2020-09-02", beginTime: "10:00", endTime: "11:00"),
            CustomScheduleRecord(id: "invalid", title: "错误时间", subtitle: "", description: "", dateString: "2030-09-02", beginTime: "11:00", endTime: "10:00")]
        let now = try #require(ScheduleDateCodec.parseDate("2030-09-01"))
        let candidates = ScheduleReminderPlanner.resolveOccurrences(from: cache, now: now)
        #expect(candidates.count == 1)
        #expect(candidates.first?.title == "未来日程")
        #expect(candidates.first?.classroom == "地点")
        #expect(ScheduleReminderPlanner.timeRangeText(start: try #require(candidates.first?.startDate),
            end: try #require(candidates.first?.endDate)) == "10:00-11:00")
        var recurring = valid
        recurring.additionalDateStrings = ["2030-09-09", "2030-09-16"]
        cache.customSchedules = [recurring, recurring]
        let later = try #require(ScheduleDateCodec.parseDate("2030-09-08"))
        #expect(ScheduleReminderPlanner.resolveOccurrences(from: cache, now: later)
            .map { ScheduleDateCodec.formatDate($0.startDate) } == ["2030-09-09", "2030-09-16"])
    }
}

@MainActor
struct CloudSyncPresentationTests {
    @Test func cloudPresentationOwnsItsAccountGenerationAndFailureState() {
        var account = ScheduleCloudAccount(studentID: "A", session: AppStorageSession(accountIdentifier: "A"), generation: 1)
        let changes = PassthroughSubject<CommunitySessionIdentity, Never>()
        let presentation = ScheduleCloudSyncPresentation(currentAccount: { account }, accountChanges: changes.eraseToAnyPublisher())
        presentation.receive(account: account, status: .failed("连接中断"))
        #expect(presentation.message.contains("连接中断"))
        let old = account
        account = ScheduleCloudAccount(studentID: "A", session: account.session, generation: 3)
        changes.send(.init(accountIdentifier: "A", generation: 3))
        #expect(presentation.status == .idle)
        presentation.receive(account: old, status: .synchronized)
        #expect(presentation.status == .idle)
        presentation.receive(account: account, status: .synchronized)
        changes.send(.init(accountIdentifier: "A", generation: 1))
        #expect(presentation.status == .synchronized)
        #expect(presentation.message == "课表已与 iCloud 同步。")
    }
}
