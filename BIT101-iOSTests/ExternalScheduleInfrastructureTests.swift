import Foundation
import Combine
import ClientCore
import ScheduleContracts
import SchedulePorts
import ScheduleActivityContracts
import ScheduleSharedStore
import StorageCore
import Testing
import EventKit
import os
@testable import BIT101_iOS

@MainActor
@Suite("Watch and Widget shared runtime contracts")
struct ExternalScheduleInfrastructureTests {
    @Test func foregroundRecoveryRequestsTheSnapshotAfterAnInitialTransferFailure() {
        var requests = 0
        let model = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: Date.init, loadResolvedSnapshot: { date, _ in ScheduleOccurrenceResolver.resolvedSnapshot(from: nil, now: date) },
            clearSnapshot: { true }, activateSync: {}, requestLatestSnapshot: { requests += 1; $0(.failure(.transferFailed)) }))
        model.activate()
        #expect(requests == 1)
        model.handleScenePhase(.background)
        model.handleScenePhase(.active)
        model.activate()
        #expect(requests == 2)
        model.handleScenePhase(.background)
    }
    @Test func failedWatchDeliveryRetainsTheLatestMirrorUntilSuccessfulRetry() throws {
        var buffer = WatchSnapshotDeliveryBuffer()
        let old = ScheduleExternalSnapshot(revision: 1, isLoggedIn: true, studentID: "watch-owner", firstDayString: "", timeTable: [], courses: [])
        let newer = ScheduleExternalSnapshot(revision: 2, isLoggedIn: true, studentID: "watch-owner", firstDayString: "", timeTable: [], courses: [])
        let original = try buffer.accept(old)
        buffer.stage(original)
        #expect(buffer.deliver { _ in throw URLError(.notConnectedToInternet) } == false)
        #expect(buffer.pendingData != nil && buffer.lastDeliveryError != nil)
        let latest = try buffer.accept(newer)
        buffer.stage(latest)
        let delayed = try buffer.accept(old)
        buffer.stage(delayed)
        var delivered: Data?
        #expect(buffer.deliver { delivered = $0 })
        #expect(delivered == latest && buffer.pendingData == nil && buffer.lastDeliveryError == nil)
        #expect(buffer.deliver { _ in Issue.record("成功重试应消费待发送状态。") })
    }

    private nonisolated final class BackgroundCalendarStore: EKEventStore {
        private let onQuery: @Sendable () -> Void
        init(onQuery: @escaping @Sendable () -> Void = {}) {
            self.onQuery = onQuery
            super.init()
        }
        override func calendars(for entityType: EKEntityType) -> [EKCalendar] {
            #expect(!Thread.isMainThread)
            onQuery()
            return []
        }
        override var defaultCalendarForNewEvents: EKCalendar? { nil }
        override var sources: [EKSource] { [] }
    }

    @Test(.timeLimit(.minutes(1))) func queuedCalendarOperationsKeepTheirOriginalAccountAndResetWaitsForTheTransaction() async throws {
        @MainActor final class State {
            var identity = SchoolSessionIdentity(accountIdentifier: "calendar-owner", generation: 0)
            var captureNextOwner = false
            var ownerCaptured = false
            var drainStarted = false
            var drained = false
        }
        let state = State()
        let release = DispatchSemaphore(value: 0)
        let queryCount = OSAllocatedUnfairLock(initialState: 0)
        let store = BackgroundCalendarStore {
            let first = queryCount.withLock { count in count += 1; return count == 1 }
            if first {
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
        }
        let domain = "BIT101Tests.calendar-ownership"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); release.signal() }
        let manager = ScheduleSystemCalendarManager(eventStore: store, defaultsDomain: domain, currentIdentity: {
            if state.captureNextOwner {
                state.captureNextOwner = false
                state.ownerCaptured = true
            }
            return state.identity
        }, requestAccess: {})
        let active = Task { try await manager.deleteAllImportedEvents() }
        try await waitForTestEvent { queryCount.withLock { $0 } > 0 }
        state.captureNextOwner = true
        let queued = Task { try await manager.deleteImportedEvents(markerIDs: ["entry"]) }
        try await waitForTestEvent { state.ownerCaptured }
        state.identity = .init(accountIdentifier: "new-owner", generation: 1)
        let drain = Task {
            state.drainStarted = true
            await manager.finishPendingTransactions()
            state.drained = true
        }
        try await waitForTestEvent { state.drainStarted }
        #expect(!state.drained)
        release.signal()
        #expect(try await active.value == .noOp)
        await #expect(throws: CancellationError.self) { try await queued.value }
        await drain.value
        #expect(state.drained)
        #expect(queryCount.withLock { $0 } == 1)
    }

    @Test(.timeLimit(.minutes(1))) func calendarQueriesAndTransactionsUseTheirOwnExecutor() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101Tests.calendar-executor"))
        defer { defaults.removePersistentDomain(forName: "BIT101Tests.calendar-executor") }
        let manager = ScheduleSystemCalendarManager(eventStore: BackgroundCalendarStore(), defaultsDomain: "BIT101Tests.calendar-executor",
            currentIdentity: { .init(accountIdentifier: "calendar-owner", generation: 0) }, requestAccess: {})
        #expect(try await manager.deleteAllImportedEvents() == .noOp)
        #expect(try await manager.deleteImportedEvents(markerIDs: ["entry"], term: "term") == .noOp)
        let draft = ScheduleSystemCalendarEventDraft(markerID: "entry", title: "课程", location: "", structuredLocation: nil,
            notes: "", startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 3600))
        let error = await #expect(throws: ScheduleSystemCalendarError.self) {
            try await manager.importDrafts([draft], term: "term")
        }
        #expect(error?.localizedDescription == ScheduleSystemCalendarError.noWritableCalendarSource.localizedDescription)
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["import", "delete", "clear"], ["corrupt", "wrong-type", "invalid-batch"])
    func damagedCalendarHistoryPreservesItsSourceBeforeMutations(operation: String, damage: String) async throws {
        let domain = "BIT101Tests.calendar-history"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "calendar-owner")
        let key = session.key("schedule.system-calendar.imported-batches")
        let source: Any = damage == "wrong-type" ? "damaged" : Data((damage == "corrupt" ? "damaged" : "[{\"term\":\"term\"}]").utf8)
        defaults.set(source, forKey: key)
        let queries = OSAllocatedUnfairLock(initialState: 0)
        let manager = ScheduleSystemCalendarManager(eventStore: BackgroundCalendarStore { queries.withLock { $0 += 1 } },
            defaultsDomain: domain, currentIdentity: { .init(accountIdentifier: "calendar-owner", generation: 0) }, requestAccess: {})
        let error = await #expect(throws: ScheduleSystemCalendarError.self) {
            switch operation {
            case "import":
                let draft = ScheduleSystemCalendarEventDraft(markerID: "entry", title: "课程", location: "", structuredLocation: nil,
                    notes: "", startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 3600))
                _ = try await manager.importDrafts([draft], term: "term")
            case "delete": _ = try await manager.deleteImportedEvents(markerIDs: ["entry"], term: "term")
            default: _ = try await manager.deleteAllImportedEvents()
            }
        }
        #expect(error?.localizedDescription == ScheduleSystemCalendarError.importHistoryUnreadable.localizedDescription)
        #expect(queries.withLock { $0 } == 0)
        let retained = defaults.object(forKey: key)
        #expect(retained as? Data == source as? Data && retained as? String == source as? String)
        defaults.set(Data("[]".utf8), forKey: key)
        #expect(try await manager.deleteAllImportedEvents() == .noOp)
    }

    @MainActor @Test func damagedDiskSnapshotsReachTheInvalidDisplayState() throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: URL(fileURLWithPath: "/external-display"))
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .missing)
        let missing = ScheduleOccurrenceResolver.loadResolvedTimeline(store: store, includeDisplayUntilDates: true)
        #expect(missing.count == 1 && missing.first?.resolved.contentState == .missing)
        try files.writeData(Data("invalid-json".utf8), to: #require(store.fileURL), options: [])
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .invalid)
        let invalid = ScheduleOccurrenceResolver.loadResolvedTimeline(store: store, includeDisplayUntilDates: true)
        #expect(invalid.count == 1 && invalid.first?.resolved.contentState == .invalid)
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: ScheduleExternalSnapshotStore(files: files, containerURL: nil)).contentState == .unavailable)
        let unavailable = ScheduleOccurrenceResolver.loadResolvedTimeline(store: ScheduleExternalSnapshotStore(files: files, containerURL: nil), includeDisplayUntilDates: false)
        #expect(unavailable.count == 1 && unavailable.first?.resolved.contentState == .unavailable)
    }
    #if !targetEnvironment(macCatalyst)
    @Test("Live Activity preserves account and course presentation across encoding")
    func liveActivityContractRoundTrip() throws {
        let attributes = CourseReminderActivityAttributes(studentID: "activity-account")
        let state = CourseReminderActivityAttributes.ContentState(
            kindText: "课程", title: "高等数学", classroom: "理教201", teacher: "张老师",
            timeRangeText: "08:00–09:30", countdownTargetDate: Date(timeIntervalSince1970: 1_000))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(CourseReminderActivityAttributes.self,
            from: encoder.encode(attributes)).studentID == "activity-account")
        #expect(try decoder.decode(CourseReminderActivityAttributes.ContentState.self,
            from: encoder.encode(state)) == state)
    }
    @Test(arguments: ["中文课程", "\"\\\n/", "👨‍👩‍👧‍👦é"])
    func liveActivityPayloadFitsCombinedEncodedBudget(text: String) throws {
        let attributes = CourseReminderActivityAttributes(studentID: "activity-account")
        let long = String(repeating: text, count: 4_096)
        let state = CourseReminderActivityAttributes.ContentState(kindText: "课程", title: long,
            classroom: long, teacher: long, timeRangeText: "08:00–09:30", countdownTargetDate: Date(timeIntervalSince1970: 1_000))
        let bounded = try attributes.boundedContentState(state), encoder = JSONEncoder()
        #expect(try encoder.encode(attributes).count + encoder.encode(bounded).count <= 4_096)
        #expect(long.hasPrefix(String(bounded.title.dropLast())) && bounded.title.hasSuffix("…"))
        #expect(bounded.countdownTargetDate == state.countdownTargetDate)
        #expect(bounded.kindText == state.kindText && bounded.timeRangeText == state.timeRangeText)
        let small = CourseReminderActivityAttributes.ContentState(kindText: "课程", title: "高等数学",
            classroom: "理教201", teacher: "张老师", timeRangeText: "08:00–09:30", countdownTargetDate: state.countdownTargetDate)
        #expect(try attributes.boundedContentState(small) == small)
    }
    #endif

    @Test("Snapshot codec preserves the shared contract")
    func snapshotCodecRoundTrip() throws {
        let snapshot = makeSnapshot()
        let data = try ScheduleExternalSnapshotCodec.encode(snapshot)

        #expect(try ScheduleExternalSnapshotCodec.decode(data) == snapshot)
    }

    @Test func deadlineWidgetSnapshotRetainsDataAcrossStorageAndAccountRevisions() throws {
        let deadline = ScheduleExternalDeadlineSnapshot(id: "manual", title: "报告", subtitle: "课程", sourceTitle: "自定义",
            dueAt: Date(timeIntervalSince1970: 1_000_000))
        let snapshot = ScheduleExternalSnapshot(revision: 2, isLoggedIn: true, studentID: "owner",
            firstDayString: "", timeTable: [], courses: [], deadlines: [deadline], ddlAfterDay: 5)
        let advanced = try #require(snapshot.replacingStudentID(with: "opaque-owner").advancingRevision(after: 10))
        let decoded = try ScheduleExternalSnapshotCodec.decode(ScheduleExternalSnapshotCodec.encode(advanced))
        #expect(decoded.deadlines == [deadline] && decoded.ddlAfterDay == 5)
        #expect(decoded.studentID == "opaque-owner" && decoded.revision == 11)
        var legacy = try #require(JSONSerialization.jsonObject(with: ScheduleExternalSnapshotCodec.encode(snapshot)) as? [String: Any])
        legacy.removeValue(forKey: "deadlines")
        legacy.removeValue(forKey: "ddlAfterDay")
        let restored = try ScheduleExternalSnapshotCodec.decode(JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.deadlines.isEmpty && restored.ddlAfterDay == 3)
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL)
        try store.write(snapshot)
        #expect(store.load()?.deadlines == [deadline])
        let cleared = ScheduleExternalSnapshot(revision: 3, isLoggedIn: false, studentID: "owner", firstDayString: "",
            timeTable: [], courses: [])
        #expect(try store.writeIfNewer(cleared))
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: store.load()).contentState == .loggedOut)
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) { try store.writeIfNewer(snapshot) }
    }

    @Test func deadlineWidgetOrdersPendingItemsAndHonorsTheRetentionBoundaryWithoutCourses() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func deadline(_ id: String, _ offset: TimeInterval) -> ScheduleExternalDeadlineSnapshot {
            .init(id: id, title: id, subtitle: "", sourceTitle: "自定义", dueAt: now.addingTimeInterval(offset))
        }
        let snapshot = ScheduleExternalSnapshot(isLoggedIn: true, studentID: "owner", firstDayString: "", timeTable: [], courses: [],
            deadlines: [deadline("later", 3_600), deadline("b", -86_400), deadline("a", -86_400), deadline("expired", -86_401)], ddlAfterDay: 1)
        let resolved = ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: now)
        #expect(resolved.contentState == .ready && resolved.deadlines.map(\.id) == ["a", "b", "later"])
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: now, limit: 1).deadlines.map(\.id) == ["a"])
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: now, limit: 0).contentState == .rest)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: now.addingTimeInterval(2 * 86_400)).contentState == .rest)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: nil).contentState == .missing)
        let signedOut = ScheduleExternalSnapshot(isLoggedIn: false, studentID: "", firstDayString: "", timeTable: [], courses: [],
            deadlines: snapshot.deadlines)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: signedOut).deadlines.isEmpty)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: signedOut).contentState == .loggedOut)
    }

    @Test func deadlineWidgetTimelineRefreshesAtDueTimeExpiryAndMidnight() throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2030-10-01"))
        let now = try #require(ScheduleSharedDateCodec.combine(date: day, time: "12:00"))
        let deadline = ScheduleExternalDeadlineSnapshot(id: "due", title: "报告", subtitle: "", sourceTitle: "课程中心",
            dueAt: now.addingTimeInterval(300))
        let snapshot = ScheduleExternalSnapshot(isLoggedIn: true, studentID: "owner", firstDayString: "", timeTable: [], courses: [],
            deadlines: [deadline], ddlAfterDay: 0)
        #expect(ScheduleDeadlineResolver.timelineDates(from: snapshot, now: now)
            == [now, deadline.dueAt, deadline.dueAt.addingTimeInterval(1), day.addingTimeInterval(86_400), now.addingTimeInterval(86_400)])
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: deadline.dueAt).contentState == .ready)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot, now: deadline.dueAt.addingTimeInterval(1)).contentState == .rest)
        #expect(ScheduleDeadlineResolver.timelineDates(from: nil, now: now)
            == [now, day.addingTimeInterval(86_400), now.addingTimeInterval(86_400)])
    }

    @Test(arguments: ["blank-title", "blank-id", "duplicate-id", "oversized-subtitle", "invalid-retention", "invalid-date"])
    func damagedDeadlineWidgetPayloadsPreserveTheSharedValidationBoundary(field: String) {
        let deadline = ScheduleExternalDeadlineSnapshot(id: field == "blank-id" ? " " : "id", title: field == "blank-title" ? " " : "报告",
            subtitle: field == "oversized-subtitle" ? String(repeating: "x", count: ScheduleExternalSnapshotCodec.maximumFieldBytes + 1) : "",
            sourceTitle: "乐学", dueAt: Date(timeIntervalSince1970: field == "invalid-date" ? .infinity : 100))
        let snapshot = ScheduleExternalSnapshot(isLoggedIn: true, studentID: "owner", firstDayString: "", timeTable: [], courses: [],
            deadlines: field == "duplicate-id" ? [deadline, deadline] : [deadline], ddlAfterDay: field == "invalid-retention" ? 31 : 3)
        #expect(throws: CocoaError.self) { try ScheduleExternalSnapshotCodec.encode(snapshot) }
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot).contentState == .invalid)
    }

    @Test("Watch transfer protocol recognizes requests and snapshots")
    func watchTransferProtocol() throws {
        let data = try ScheduleExternalSnapshotCodec.encode(makeSnapshot())
        let context = WatchScheduleTransferProtocol.snapshotContext(data)

        #expect(WatchScheduleTransferProtocol.knownRevision(from: WatchScheduleTransferProtocol.requestContext(knownRevision: 42)) == 42)
        #expect(WatchScheduleTransferProtocol.requestsLatestSnapshot(WatchScheduleTransferProtocol.requestContext()))
        #expect(WatchScheduleTransferProtocol.snapshotData(from: context) == data)
        #expect(!WatchScheduleTransferProtocol.requestsLatestSnapshot(context))
    }

    @Test("Resolved snapshot states distinguish missing login invalid empty rest and ready")
    func resolvedSnapshotStates() throws {
        let firstDay = try #require(ScheduleSharedDateCodec.parseDate("2026-03-02"))
        let beforeClass = try #require(ScheduleSharedDateCodec.combine(date: firstDay, time: "07:00"))
        let afterClass = try #require(ScheduleSharedDateCodec.combine(date: firstDay, time: "10:00"))

        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: nil, now: beforeClass).contentState == .missing)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(isLoggedIn: false),
            now: beforeClass
        ).contentState == .loggedOut)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(firstDayString: "invalid-date"),
            now: beforeClass
        ).contentState == .invalid)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(includeCourses: false, includeTimeTable: false),
            now: beforeClass
        ).contentState == .rest)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(includeTimeTable: false),
            now: beforeClass
        ).contentState == .invalid)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(),
            now: afterClass
        ).contentState == .rest)

        let ready = ScheduleOccurrenceResolver.resolvedSnapshot(
            from: makeSnapshot(),
            now: beforeClass,
            limit: 1
        )
        #expect(ready.contentState == .ready)
        #expect(ready.upcomingOccurrences.count == 1)
        #expect(ready.nextOccurrence?.title == "高等数学")
    }

    @Test("Timeline planner selects course transitions and midnight")
    func timelineRefreshPlanning() throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2026-03-02"))
        let start = try #require(ScheduleSharedDateCodec.combine(date: day, time: "08:00"))
        let displayUntil = start.addingTimeInterval(5 * 60)
        let occurrence = ScheduleExternalOccurrence(
            id: "course-1",
            title: "高等数学",
            classroom: "理教201",
            teacher: "张老师",
            startDate: start,
            endDate: start.addingTimeInterval(90 * 60),
            displayUntilDate: displayUntil
        )

        let beforeClass = start.addingTimeInterval(-60 * 60)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: [occurrence],
            now: beforeClass,
            includeDisplayUntilDates: true,
            includeNextMidnight: false
        ) == start)

        for leadTime: TimeInterval in [1, 10, 29, 30] {
            #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [occurrence], now: start.addingTimeInterval(-leadTime),
                includeDisplayUntilDates: false, includeNextMidnight: true) == start)
        }
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [occurrence], now: displayUntil.addingTimeInterval(-10),
            includeDisplayUntilDates: true, includeNextMidnight: false) == displayUntil)
        let duringDisplayWindow = start.addingTimeInterval(60)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: [occurrence],
            now: duringDisplayWindow,
            includeDisplayUntilDates: true,
            includeNextMidnight: false
        ) == displayUntil)

        let lateEvening = try #require(ScheduleSharedDateCodec.combine(date: day, time: "23:50"))
        let nextMidnight = ScheduleSharedDateCodec.calendar.date(
            byAdding: .day,
            value: 1,
            to: ScheduleSharedDateCodec.calendar.startOfDay(for: lateEvening)
        )?.addingTimeInterval(1)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: [],
            now: lateEvening,
            includeDisplayUntilDates: false,
            includeNextMidnight: true
        ) == nextMidnight)
        let midnight = try #require(nextMidnight)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [], now: midnight.addingTimeInterval(-10),
            includeDisplayUntilDates: false, includeNextMidnight: true) == midnight)
    }

    @Test(arguments: [true, false])
    func futureTimelineIncludesClassTransitionsAndMidnight(phone: Bool) throws {
        let base = makeSnapshot()
        let course = try #require(base.courses.first)
        let snapshot = ScheduleExternalSnapshot(generatedAt: base.generatedAt, isLoggedIn: base.isLoggedIn,
            studentID: base.studentID, firstDayString: base.firstDayString, timeTable: base.timeTable,
            courses: [ScheduleExternalCourseSnapshot(id: course.id, name: course.name, classroom: course.classroom,
                teacher: course.teacher, weeks: [1, 2], weekday: course.weekday,
                startSection: course.startSection, endSection: course.endSection)])
        let day = try #require(ScheduleSharedDateCodec.parseDate(snapshot.firstDayString))
        let now = try #require(ScheduleSharedDateCodec.combine(date: day, time: "07:00"))
        let resolved = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: now)
        let occurrence = try #require(resolved.nextOccurrence)
        let cutoff = occurrence.startDate.addingTimeInterval(ScheduleOccurrenceResolver.defaultCurrentCourseDisplayDuration)
        let midnight = try #require(ScheduleSharedDateCodec.calendar.date(byAdding: .day, value: 1, to: day))
        let dates = ScheduleTimelineRefreshPlanner.timelineDates(for: resolved.upcomingOccurrences + resolved.upcomingOccurrences,
            now: now, includeDisplayUntilDates: phone)
        #expect(dates == dates.sorted() && Set(dates).count == dates.count)
        #expect(dates.first == now && dates.last == now.addingTimeInterval(24 * 60 * 60))
        #expect(dates.contains(occurrence.startDate) && dates.contains(midnight))
        #expect(dates.contains(cutoff) == phone)
        #expect(dates.contains(occurrence.endDate) == phone)
        let store = ScheduleExternalSnapshotStore(files: PreferenceMemoryFiles(), containerURL: URL(fileURLWithPath: "/timeline-contract"))
        try store.write(snapshot)
        let timeline = ScheduleOccurrenceResolver.loadResolvedTimeline(store: store, now: now, includeDisplayUntilDates: phone, limit: 1)
        #expect(timeline.map(\.date) == dates)
        for entry in timeline {
            let reference = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: entry.date, limit: 1)
            #expect(entry.resolved.contentState == reference.contentState)
            #expect(entry.resolved.upcomingOccurrences == reference.upcomingOccurrences)
        }
        let last = try #require(resolved.upcomingOccurrences.last)
        #expect(last.displayUntilDate == last.endDate)
        #expect(!dates.contains(last.startDate))
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: occurrence.startDate).nextOccurrence?.id == occurrence.id)
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: cutoff).nextOccurrence?.id != occurrence.id)
        let empty = ScheduleTimelineRefreshPlanner.timelineDates(for: [], now: now, includeDisplayUntilDates: phone)
        #expect(empty == [now, midnight, now.addingTimeInterval(24 * 60 * 60)])
    }

    private func makeSnapshot(
        isLoggedIn: Bool = true,
        includeCourses: Bool = true,
        firstDayString: String = "2026-03-02",
        includeTimeTable: Bool = true
    ) -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_772_422_400),
            isLoggedIn: isLoggedIn,
            studentID: "1120260001",
            firstDayString: firstDayString,
            timeTable: includeTimeTable ? [
                ScheduleExternalTimeSlotSnapshot(id: 1, start: "08:00", end: "09:30"),
            ] : [],
            courses: includeCourses ? [
                ScheduleExternalCourseSnapshot(
                    id: "course-1",
                    name: "高等数学",
                    classroom: "理科教学楼201",
                    teacher: "张老师",
                    weeks: [1],
                    weekday: 1,
                    startSection: 1,
                    endSection: 1
                ),
            ] : []
        )
    }
}

@MainActor
struct ExternalScheduleWatchStatusTests {
    @Test(.timeLimit(.minutes(1)))
    func invalidBackgroundReceiptsKeepTheUsableMirror() async throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL)
        let course = ScheduleExternalCourseSnapshot(id: "course", name: "课程", classroom: "", teacher: "",
            weeks: [1], weekday: 1, startSection: 1, endSection: 1)
        let valid = ScheduleExternalSnapshot(revision: 1, isLoggedIn: true, studentID: "watch-semantic",
            firstDayString: "2026-09-07", timeTable: [ScheduleExternalTimeSlotSnapshot(id: 1, start: "08:00", end: "09:00")], courses: [course])
        try store.write(valid)
        let stored = try #require(store.load())
        let invalid = ScheduleExternalSnapshot(revision: 2, isLoggedIn: true, studentID: valid.studentID,
            firstDayString: valid.firstDayString, timeTable: [], courses: [course])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let persistence = WatchSnapshotPersistence(store: store)
        #expect(await persistence.receive(try encoder.encode(invalid), receivedAt: .now, accountIdentifier: nil) == .failure(.invalidPayload))
        #expect(store.load() == stored)
        let loggedOut = ScheduleExternalSnapshot(revision: 3, isLoggedIn: false, studentID: valid.studentID,
            firstDayString: "", timeTable: [], courses: [])
        #expect(await persistence.receive(try ScheduleExternalSnapshotCodec.encode(loggedOut), receivedAt: .now,
            accountIdentifier: nil) == .success(true))
        #expect(store.load()?.isLoggedIn == false && store.load()?.courses.isEmpty == true)
    }

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

    @Test(.timeLimit(.minutes(1))) func unchangedBackgroundReceiptCompletesTheQueuedRefresh() async throws {
        let files = PreferenceMemoryFiles()
        let center = NotificationCenter()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL, notificationCenter: center)
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = ScheduleExternalSnapshot(generatedAt: now, isLoggedIn: true,
            studentID: AppStorageSession(accountIdentifier: AppAccountSession.storage.currentStudentID).accountStorageIdentifier,
            firstDayString: "", timeTable: [], courses: [])
        let data = try ScheduleExternalSnapshotCodec.encode(snapshot)
        let manager = WatchScheduleSyncManager.shared
        let persistence = WatchSnapshotPersistence(store: store)
        #expect(await manager.persistSnapshotData(data, persistence: persistence, notificationCenter: center) == .success(.received))
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
        #expect(await manager.persistSnapshotData(data, persistence: persistence, notificationCenter: center) == .success(.received))
        #expect(model.refreshState == .succeeded)
        try await waitForTestEvent { model.snapshot == snapshot }
        #expect(model.snapshot == snapshot)
        let stale = snapshot.replacingStudentID(with: "another-owner")
        model.requestRefresh()
        #expect(await manager.persistSnapshotData(try ScheduleExternalSnapshotCodec.encode(stale), persistence: persistence, notificationCenter: center) == .failure(.staleSnapshot))
        #expect(model.refreshState == .syncing)
    }

    @Test(arguments: [UInt64(0), UInt64(10)]) func queuedSnapshotReceptionRespectsTheClearingBoundary(revision: UInt64) throws {
        let received = ContinuousClock.now
        let cleared = received.advanced(by: .seconds(1))
        #expect(WatchSnapshotReceptionPolicy.accepts(receivedAt: received, afterClearingAt: nil))
        #expect(WatchSnapshotReceptionPolicy.accepts(receivedAt: received, afterClearingAt: cleared) == false)
        #expect(WatchSnapshotReceptionPolicy.accepts(receivedAt: cleared, afterClearingAt: cleared) == false)
        #expect(WatchSnapshotReceptionPolicy.accepts(receivedAt: cleared.advanced(by: .seconds(1)), afterClearingAt: cleared))
        let snapshot = ScheduleExternalSnapshot(generatedAt: Date(timeIntervalSince1970: 100), revision: revision,
            isLoggedIn: true, studentID: "watch-owner", firstDayString: "", timeTable: [], courses: [])
        let boundary = (revision: snapshot.revision, generatedAt: snapshot.generatedAt)
        #expect(WatchSnapshotReceptionPolicy.accepts(snapshot, afterClearing: nil))
        #expect(WatchSnapshotReceptionPolicy.accepts(snapshot, afterClearing: boundary) == false)
        let fresh = try #require(snapshot.advancingRevision(after: revision))
        #expect(WatchSnapshotReceptionPolicy.accepts(fresh, afterClearing: boundary))
        let legacy = ScheduleExternalSnapshot(generatedAt: snapshot.generatedAt.addingTimeInterval(1),
            isLoggedIn: true, studentID: "watch-owner", firstDayString: "", timeTable: [], courses: [])
        #expect(WatchSnapshotReceptionPolicy.accepts(legacy, afterClearing: boundary) == (revision == 0))
    }

    @Test(.timeLimit(.minutes(1))) func lateResultsRetainTheCurrentRefreshAndClearedState() async {
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
        await model.clearLocalData().value
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func queuedRefreshAcceptsReceiptAfterTheWaitingHint(viaNotification: Bool) async throws {
        let (timeouts, trigger) = AsyncStream<Void>.makeStream()
        defer { trigger.finish() }
        var callbacks: [@MainActor (Result<WatchScheduleSyncOutcome, WatchScheduleSyncError>) -> Void] = []
        let model = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: Date.init, loadResolvedSnapshot: { now, _ in ScheduleOccurrenceResolver.resolvedSnapshot(from: nil, now: now) },
            clearSnapshot: { true }, activateSync: {}, requestLatestSnapshot: { callbacks.append($0) },
            waitForRefreshTimeout: { for await _ in timeouts { return } }
        ))
        model.requestRefresh()
        callbacks[0](.success(.requested))
        trigger.yield(())
        try await waitForTestEvent { model.refreshState == .waiting }
        #expect(model.refreshFeedbackText == "等待手机同步")
        #expect(model.isRefreshing == false)
        if viaNotification { model.handleSnapshotDidChange() }
        else { callbacks[0](.success(.received)) }
        #expect(model.refreshState == .succeeded)
        callbacks[0](.failure(.transferFailed))
        #expect(model.refreshState == .succeeded)
        model.requestRefresh()
        callbacks[0](.success(.received))
        #expect(model.refreshState == .syncing)
        await model.clearLocalData().value
        callbacks[1](.success(.received))
        #expect(model.refreshState == .idle)
    }

    @Test(.timeLimit(.minutes(1))) func failedClearingPreservesTheStoredSnapshotAndReportsTheResult() async throws {
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
        try await waitForTestEvent { model.snapshot == snapshot }
        let previousState = model.contentState
        await model.clearLocalData().value
        #expect(model.snapshot == snapshot)
        #expect(model.contentState == previousState)
        #expect(model.refreshFeedbackText == "清理失败，请重试")
        result.succeeds = true
        await model.clearLocalData().value
        #expect(model.snapshot == nil)
        #expect(model.contentState == .missing)
        #expect(model.refreshState == .idle)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["replacement", "clear", "background"])
    func delayedSnapshotLoadingPreservesTheCurrentOwner(action: String) async throws {
        let first = Date(timeIntervalSince1970: 100), second = Date(timeIntervalSince1970: 200)
        var pending: CheckedContinuation<ScheduleExternalResolvedSnapshot, Never>?
        let model = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: { first }, loadResolvedSnapshot: { now, _ in
                if now == first { return await withCheckedContinuation { pending = $0 } }
                return ScheduleOccurrenceResolver.resolvedSnapshot(from: ScheduleExternalSnapshot(generatedAt: now,
                    isLoggedIn: true, studentID: "new", firstDayString: "", timeTable: [], courses: []), now: now)
            }, clearSnapshot: { true }, activateSync: {}, requestLatestSnapshot: { _ in }
        ))
        let previous = model.reload(now: first)
        try await waitForTestEvent { pending != nil }
        let old = try #require(pending)
        defer { pending?.resume(returning: ScheduleOccurrenceResolver.resolvedSnapshot(from: nil)); pending = nil }
        if action == "replacement" {
            model.reload(now: second)
            try await waitForTestEvent { model.snapshot?.studentID == "new" }
        } else if action == "clear" { await model.clearLocalData().value }
        else { model.handleScenePhase(.background) }
        pending = nil
        old.resume(returning: ScheduleOccurrenceResolver.resolvedSnapshot(from: ScheduleExternalSnapshot(generatedAt: first,
            isLoggedIn: true, studentID: "old", firstDayString: "", timeTable: [], courses: []), now: first))
        await previous.value
        #expect(model.snapshot?.studentID == (action == "replacement" ? "new" : nil))
    }

    @Test(.timeLimit(.minutes(1))) func sharedSnapshotDiskReadAndExpansionRunOutsideTheUIExecutor() async throws {
        let files = PreferenceMemoryFiles()
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: files.temporaryDirectoryURL)
        let snapshot = ScheduleExternalSnapshot(isLoggedIn: true, studentID: "watch-owner",
            firstDayString: "2026-01-01", timeTable: [], courses: [])
        try store.write(snapshot)
        files.interceptNextRead { #expect(!Thread.isMainThread) }
        let resolved = await ScheduleOccurrenceResolver.loadResolvedSnapshotAsync(store: store)
        #expect(resolved.snapshot?.studentID == AccountStorageIdentity.stableToken(for: snapshot.studentID))
    }
}
