import ClientCore
import Combine
import CommunityTransport
import Foundation
import ScheduleContracts
import ScheduleDomain
import SchedulePorts
import ScheduleSharedStore
import StorageCore
import Testing
import UserNotifications

@testable import BIT101_iOS
@testable import ScheduleFeature
@testable import ScheduleInfrastructure

@MainActor
struct ScheduleCalendarTransactionTests {
    @Test func calendarMarkersKeepAccount() throws {
        let first = AppStorageSession(accountIdentifier: "calendar-A")
        let second = AppStorageSession(accountIdentifier: "calendar-B")
        let guest = AppStorageSession(accountIdentifier: "")
        let term = "2026-2027-1"
        let url = try #require(
            ScheduleSystemCalendarEventMarker.url(id: "course-w1", term: term, session: first))
        #expect(ScheduleSystemCalendarEventMarker.matches(url, session: first, term: term))
        #expect(ScheduleSystemCalendarEventMarker.matches(url, session: first))
        #expect(
            AppDeepLinkRoute(url: url)
                == .calendarEvent(
                    markerID: "course-w1", term: term, account: first.accountStorageIdentifier))
        #expect(
            ScheduleSystemCalendarEventMarker.matches(url, session: second, term: term) == false)
        #expect(ScheduleSystemCalendarEventMarker.matches(url, session: guest, term: term) == false)
        #expect(
            ScheduleSystemCalendarEventMarker.matches(url, session: first, term: "other") == false)
        #expect(url.absoluteString.contains(first.accountIdentifier) == false)
        for foreign in [
            nil, URL(string: "bit101://calendar-course/course-w1?term=2026-2027-1"),
            URL(string: "https://example.invalid/course-w1"),
        ] {
            #expect(
                ScheduleSystemCalendarEventMarker.matches(foreign, session: first, term: term)
                    == false)
        }
        for value in [
            "bit101://calendar-course/course-w1?term=term",
            "bit101://calendar-course/?term=term&account=owner",
        ] {
            let invalid = try #require(URL(string: value))
            #expect(AppDeepLinkRoute(url: invalid) == nil)
        }
    }

    @Test func consumersResolvePersistedAccountSnapshot() throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: files.temporaryDirectoryURL)
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = ScheduleExternalSnapshot(
            generatedAt: now, isLoggedIn: true,
            studentID: "shared-reader", firstDayString: "", timeTable: [], courses: [])
        try store.write(snapshot)
        let resolved = ScheduleOccurrenceResolver.loadResolvedSnapshot(
            store: store, now: now, limit: 1)
        #expect(
            resolved.snapshot?.studentID == AccountStorageIdentity.stableToken(for: "shared-reader")
        )
        #expect(resolved.snapshot?.generatedAt == now)
        #expect(resolved.upcomingOccurrences.isEmpty)
        #expect(store.clear())
        #expect(
            ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store, now: now).contentState
                == .missing)
    }

    @Test func calendarQuerySlicesCoverLongRanges() throws {
        let calendar = ScheduleSharedDateCodec.calendar
        let start = try #require(
            calendar.date(from: DateComponents(year: 2020, month: 2, day: 29, hour: 12)))
        let end = try #require(
            calendar.date(from: DateComponents(year: 2040, month: 3, day: 1, hour: 12)))
        let ranges = ScheduleSystemCalendarQuery.intervals(start: start, end: end)
        #expect(ranges.count == 6 && ranges.first?.start == start && ranges.last?.end == end)
        for range in ranges {
            let maximumEnd = try #require(calendar.date(byAdding: .year, value: 4, to: range.start))
            #expect(range.start < range.end && range.end <= maximumEnd)
        }
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(previous.end == next.start)
        }
        let current = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 8)))
        #expect(ranges.contains { $0.contains(current) })
        let fourYears = try #require(calendar.date(byAdding: .year, value: 4, to: start))
        #expect(
            ScheduleSystemCalendarQuery.intervals(start: start, end: fourYears) == [
                DateInterval(start: start, end: fourYears)
            ])
        #expect(ScheduleSystemCalendarQuery.intervals(start: end, end: start).isEmpty)
        #expect(ScheduleSystemCalendarQuery.intervals(start: start, end: start).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func calendarPermissionResumeChecksCancel(cancel: Bool) async throws {
        @MainActor final class State {
            var identity = SchoolSessionIdentity(accountIdentifier: "calendar-owner", generation: 0)
            var resume: CheckedContinuation<Void, Never>?
        }
        let state = State()
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.calendar-permission"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.calendar-permission") }
        let manager = ScheduleSystemCalendarManager(
            defaultsDomain: "BIT101Tests.calendar-permission", currentIdentity: { state.identity },
            requestAccess: { await withCheckedContinuation { state.resume = $0 } })
        let task = Task { try await manager.deleteAllImportedEvents() }
        try await waitForTestEvent { !(state.resume == nil) }
        if cancel {
            task.cancel()
        } else {
            state.identity = .init(accountIdentifier: "calendar-owner", generation: 1)
        }
        state.resume?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(
            defaults.dictionaryRepresentation().keys.contains(
                AppStorageSession(accountIdentifier: "calendar-owner").key(
                    "schedule.system-calendar.imported-batches")) == false)
    }

    @Test(arguments: [0, 1, 2])
    func failedBatchesDiscardPendingMutations(failureStage: Int) throws {
        enum Failure: Error { case injected }
        var pending: [String] = []
        var committed: [String] = []
        var resets = 0
        #expect(throws: Failure.self) {
            try ScheduleSystemCalendarTransaction.run(reset: {
                pending.removeAll()
                resets += 1
            }) {
                pending.append("remove-old")
                if failureStage == 0 { throw Failure.injected }
                pending.append("save-first")
                if failureStage == 1 { throw Failure.injected }
                pending.append("save-second")
                throw Failure.injected
            }
        }
        #expect(pending.isEmpty && resets == 1)
        try ScheduleSystemCalendarTransaction.run(reset: {
            pending.removeAll()
            resets += 1
        }) {
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
    @Test func noticeComponentsKeepZones() throws {
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
