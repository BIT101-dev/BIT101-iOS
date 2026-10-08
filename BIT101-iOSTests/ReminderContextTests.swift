import Foundation
import Combine
import CommunityTransport
import ScheduleSync
import ScheduleDomain
import StorageCore
import Testing
@testable import BIT101_iOS

@MainActor
struct ReminderContextTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["current", "cancelled", "account"])
    func backgroundRefreshRespectsTheOwnerAfterItsSuspendedRead(boundary: String) async {
        var current = true
        var read: CheckedContinuation<Date?, Never>?
        var scheduled: [Date?] = []
        var refreshed = 0
        let target = Date(timeIntervalSince1970: 3900)
        let task = Task {
            await ScheduleReminderBackgroundRefresh.refreshIfCurrent(isCurrent: { current },
                nextBeginDate: { await withCheckedContinuation { read = $0 } },
                schedule: { scheduled.append($0) }, refresh: { refreshed += 1 })
        }
        while read == nil { await Task.yield() }
        if boundary == "cancelled" { task.cancel() }
        if boundary == "account" { current = false }
        read?.resume(returning: target)
        let completed = await task.value
        #expect(completed == (boundary == "current"))
        #expect(scheduled == (boundary == "current" ? [target] : []) && refreshed == (boundary == "current" ? 1 : 0))
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
    @Test func delayedCacheLoadHonorsItsCapturedAccountGeneration() async {
        var current = ScheduleReminderSession(studentID: "A", storage: AppStorageSession(accountIdentifier: "A"), generation: 1, signedIn: true)
        var loadContinuation: CheckedContinuation<ScheduleCache, Never>?
        var enteredContinuation: CheckedContinuation<Void, Never>?
        let context = ScheduleReminderContext(currentSession: { current }, loadCache: { captured in
            #expect(captured.accountIdentifier == "A")
            return await withCheckedContinuation {
                loadContinuation = $0
                enteredContinuation?.resume(); enteredContinuation = nil
            }
        })
        let task = Task { await context.loadCurrentCache() }
        await withCheckedContinuation { enteredContinuation = $0 }
        current = ScheduleReminderSession(studentID: "A", storage: current.storage, generation: 3, signedIn: true)
        loadContinuation?.resume(returning: ScheduleCache())
        #expect(await task.value == nil)
    }

    @Test func currentSnapshotUsesTheInjectedAccountPartition() async {
        let session = ScheduleReminderSession(studentID: "B", storage: AppStorageSession(accountIdentifier: "B"), generation: 1, signedIn: true)
        let context = ScheduleReminderContext(currentSession: { session }, loadCache: { storage in
            #expect(storage == session.storage)
            var cache = ScheduleCache()
            cache.primaryScheduleTitle = "injected reminder"
            return cache
        })
        let value = await context.loadCurrentCache()
        #expect(value?.session == session)
        #expect(value?.cache.primaryScheduleTitle == "injected reminder")
    }
}

@MainActor
struct ReminderPlannerTests {
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
