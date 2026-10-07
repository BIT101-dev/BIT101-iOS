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
