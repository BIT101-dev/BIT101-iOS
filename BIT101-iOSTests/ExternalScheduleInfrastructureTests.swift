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
    @Test func sharedDeadlineTimelineAdvancesItsWindowAndTransfersTheCompleteSnapshot() throws {
        let now = try #require(ScheduleSharedDateCodec.parseDate("2026-10-24"))
        let deadlines = (1...5).map { number in
            ScheduleExternalDeadlineSnapshot(id: "ddl-\(number)", title: "作业 \(number)", subtitle: "课程",
                sourceTitle: "乐学", dueAt: now.addingTimeInterval(Double(number * 60)))
        }
        func snapshot(_ values: [ScheduleExternalDeadlineSnapshot], loggedIn: Bool = true) -> ScheduleExternalSnapshot {
            .init(generatedAt: now, revision: 4, isLoggedIn: loggedIn, studentID: "widget-owner", firstDayString: "",
                timeTable: [], courses: [], customSchedules: [.init(id: "event", title: "个人日程", subtitle: "地点",
                    dateStrings: ["2026-10-24"], beginTime: "08:00", endTime: "09:00")], deadlines: values, ddlAfterDay: 0)
        }
        let encoded = try ScheduleExternalSnapshotCodec.encode(snapshot(deadlines))
        let restored = try ScheduleExternalSnapshotCodec.decode(encoded)
        #expect(restored == snapshot(deadlines))
        let entries = ScheduleDeadlineResolver.timelineEntries(from: restored, now: now)
        #expect(entries.first?.resolved.deadlines.map(\.id) == Array(deadlines.prefix(4)).map(\.id))
        #expect(entries.last?.date == now.addingTimeInterval(61))
        #expect(entries.last?.resolved.deadlines.map(\.id) == Array(deadlines.suffix(4)).map(\.id))
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: nil, now: now).contentState == .missing)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot([], loggedIn: false), now: now).contentState == .loggedOut)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot([]), now: now).contentState == .rest)
        #expect(ScheduleDeadlineResolver.resolvedSnapshot(from: snapshot([deadlines[0], deadlines[0]]), now: now).contentState == .invalid)
        let transfer = WatchScheduleTransferProtocol.snapshotContext(encoded)
        #expect(WatchScheduleTransferProtocol.snapshotData(from: transfer) == encoded)
        let request = WatchScheduleTransferProtocol.requestContext(knownRevision: restored.revision)
        #expect(WatchScheduleTransferProtocol.requestsLatestSnapshot(request))
        #expect(WatchScheduleTransferProtocol.knownRevision(from: request) == restored.revision)
        #expect(WatchScheduleTransferProtocol.knownRevision(from: transfer) == nil)
    }

    @Test func externalCoursePresentationAndRefreshUseTheSameSchoolDates() throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2026-10-24"))
        let now = try #require(ScheduleSharedDateCodec.combine(date: day, time: "08:00"))
        let labels = ["今天", "明天", "后天", "大后天", "10月28日"]
        for (offset, label) in labels.enumerated() {
            let start = now.addingTimeInterval(Double(offset * 86_400))
            let occurrence = ScheduleExternalOccurrence(id: "course", title: "课程", classroom: "文萃楼I101", teacher: "教师",
                startDate: start, endDate: start.addingTimeInterval(3_600), displayUntilDate: start.addingTimeInterval(3_600))
            #expect(occurrence.relativeDayText(referenceDate: now) == label)
            #expect(occurrence.rangeText == "08:00-09:00")
            #expect(occurrence.countdownTargetDate(at: start) == occurrence.displayUntilDate)
            #expect(occurrence.countdownTargetDate(at: start.addingTimeInterval(-1)) == start)
            if offset == 0 {
                #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [occurrence], now: now,
                    includeDisplayUntilDates: true, includeNextMidnight: true) == occurrence.displayUntilDate)
            }
        }
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [], now: now,
            includeDisplayUntilDates: false, includeNextMidnight: false) == now.addingTimeInterval(1_800))
        #expect(ScheduleDisplayNormalizer.courseCardClassroomText("文萃楼I101") == "文萃I\n101")
        #expect(ScheduleDisplayNormalizer.courseCardClassroomText("") == "")
    }

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
        override func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate {
            #expect(!Thread.isMainThread)
            #expect(calendars == nil)
            return NSPredicate(value: true)
        }
        override func events(matching predicate: NSPredicate) -> [EKEvent] {
            #expect(!Thread.isMainThread)
            return []
        }
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
        #expect(try await manager.rebuildImportHistory() == 0)
        #expect(try await manager.deleteAllImportedEvents() == .noOp)
    }

    @Test func calendarHistoryRecoveryFindsMovedEventsAndKeepsAccountOwnership() throws {
        let session = AppStorageSession(accountIdentifier: "calendar-owner")
        let foreign = AppStorageSession(accountIdentifier: "other-owner")
        let start = Date(timeIntervalSince1970: 100), finish = Date(timeIntervalSince1970: 200)
        func record(_ id: String, _ owner: AppStorageSession?, calendar: String = "personal-calendar", end: Date? = nil) -> ScheduleSystemCalendarManager.ImportHistoryEvent {
            .init(id: id, calendarID: calendar,
                url: owner.flatMap { ScheduleSystemCalendarEventMarker.url(id: id, term: "term", session: $0) }, start: start, end: end ?? finish)
        }
        let batches = ScheduleSystemCalendarManager.recoveredBatches(from: [record("owned", session), record("foreign", foreign),
            record("unmarked", nil), record("invalid", session, end: start), record("no-calendar", session, calendar: "")], session: session)
        #expect(batches.count == 1)
        let batch = try #require(batches.first)
        #expect(batch.term == "term" && batch.calendarIdentifier == "personal-calendar")
        #expect(batch.eventIdentifiers == ["owned"] && batch.startDate == start && batch.endDate == finish)
    }

    @Test func recoveredCalendarBatchesKeepMovedEventsAcrossIncrementalImports() throws {
        typealias Manager = ScheduleSystemCalendarManager
        let session = AppStorageSession(accountIdentifier: "calendar-owner")
        let start = Date(timeIntervalSince1970: 100), end = Date(timeIntervalSince1970: 200)
        let events = ["BIT101", "personal", "work"].map { calendar in
            Manager.ImportHistoryEvent(id: calendar, calendarID: calendar,
                url: ScheduleSystemCalendarEventMarker.url(id: calendar, term: "term", session: session), start: start, end: end)
        }
        let recovered = Manager.recoveredBatches(from: events, session: session)
        let added = Manager.ImportedBatch(term: "term", calendarIdentifier: "BIT101", eventIdentifiers: ["new"],
            startDate: start.addingTimeInterval(100), endDate: end.addingTimeInterval(100))
        let merged = Manager.mergingImport(added, into: recovered, removing: [])
        let persisted = try JSONDecoder().decode([Manager.ImportedBatch].self, from: JSONEncoder().encode(merged))
        #expect(Set(persisted.flatMap(\.eventIdentifiers)) == ["BIT101", "personal", "work", "new"])
        #expect(persisted.first { $0.calendarIdentifier == "personal" }?.eventIdentifiers == ["personal"])
        let next = Manager.mergingImport(added, into: persisted, removing: ["BIT101", "personal", "new"])
        #expect(Set(next.flatMap(\.eventIdentifiers)) == ["work", "new"])
        #expect(next.first { $0.calendarIdentifier == "work" }?.eventIdentifiers == ["work"])
        #expect(next.first { $0.calendarIdentifier == "BIT101" }?.startDate == added.startDate)
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

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func snapshotReceiptsReuseTheSingleStoreChangeRead(changed: Bool) async throws {
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
        var seedWritten = false
        let seed = center.publisher(for: .scheduleExternalSnapshotDidChange).sink { _ in
            MainActor.assumeIsolated { seedWritten = true }
        }
        #expect(await manager.persistSnapshotData(data, persistence: persistence, notificationCenter: center) == .success(.received))
        try await waitForTestEvent { seedWritten }
        seed.cancel()
        var loads = 0
        let model = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: { now }, loadResolvedSnapshot: { now, _ in
                loads += 1
                return ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store, now: now)
            },
            clearSnapshot: { true }, activateSync: {}, requestLatestSnapshot: { $0(.success(.requested)) }
        ))
        await model.reload().value
        let changes = center.publisher(for: .scheduleExternalSnapshotDidChange).sink { _ in
            MainActor.assumeIsolated { model.handleSnapshotDidChange() }
        }
        let observation = center.publisher(for: WatchScheduleSyncManager.snapshotReceivedNotification).sink { _ in
            MainActor.assumeIsolated { model.handleSnapshotReceived() }
        }
        defer { changes.cancel(); observation.cancel() }
        model.requestRefresh()
        try await waitForTestEvent { loads == 2 }
        #expect(model.refreshState == .syncing)
        let incoming = changed ? ScheduleExternalSnapshot(generatedAt: now.addingTimeInterval(1), isLoggedIn: true,
            studentID: snapshot.studentID, firstDayString: "", timeTable: [], courses: []) : snapshot
        #expect(await manager.persistSnapshotData(try ScheduleExternalSnapshotCodec.encode(incoming), persistence: persistence, notificationCenter: center) == .success(.received))
        try await waitForTestEvent { model.snapshot == incoming && model.refreshState == .succeeded }
        #expect(loads == (changed ? 3 : 2))
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
        if viaNotification { model.handleSnapshotReceived() }
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

    @Test(.timeLimit(.minutes(1)), arguments: [ScheduleExternalContentState.unavailable, .invalid])
    func transientReadFailuresKeepLoadedCoursesAndAdvanceTime(failure: ScheduleExternalContentState) async throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2026-10-24"))
        let morning = try #require(ScheduleSharedDateCodec.combine(date: day, time: "08:00"))
        let later = try #require(ScheduleSharedDateCodec.combine(date: day, time: "10:30"))
        let end = try #require(ScheduleSharedDateCodec.combine(date: day, time: "13:00"))
        let snapshot = ScheduleExternalSnapshot(generatedAt: morning, isLoggedIn: true,
            studentID: "watch-owner", firstDayString: "", timeTable: [], courses: [], customSchedules: [
                .init(id: "first", title: "第一节", subtitle: "", dateStrings: ["2026-10-24"], beginTime: "09:00", endTime: "10:00"),
                .init(id: "second", title: "第二节", subtitle: "", dateStrings: ["2026-10-24"], beginTime: "11:00", endTime: "12:00")])
        var reading = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: morning)
        let model = WatchScheduleStatusModel(dependencies: WatchScheduleStatusDependencies(
            now: { morning }, loadResolvedSnapshot: { _, _ in reading },
            clearSnapshot: { true }, activateSync: {}, requestLatestSnapshot: { _ in }))
        await model.reload(now: morning).value
        #expect(model.nextOccurrence?.title == "第一节")
        reading = .init(snapshot: nil, upcomingOccurrences: [], contentState: failure)
        await model.reload(now: later).value
        #expect(model.snapshot == snapshot)
        #expect(model.contentState == .ready)
        #expect(model.nextOccurrence?.title == "第二节")
        #expect(model.isUsingCachedSnapshot)
        await model.reload(now: end).value
        #expect(model.snapshot == snapshot && model.contentState == .rest && model.nextOccurrence == nil)
        reading = ScheduleOccurrenceResolver.resolvedSnapshot(from: nil, now: end)
        await model.reload(now: end).value
        reading = .init(snapshot: nil, upcomingOccurrences: [], contentState: failure)
        await model.reload(now: end).value
        #expect(model.snapshot == nil && model.contentState == failure)
        #expect(model.isUsingCachedSnapshot == false)
        let replacement = snapshot.replacingStudentID(with: "second-owner")
        reading = ScheduleOccurrenceResolver.resolvedSnapshot(from: replacement, now: morning)
        await model.reload(now: morning).value
        reading = .init(snapshot: nil, upcomingOccurrences: [], contentState: failure)
        await model.reload(now: later).value
        #expect(model.snapshot?.studentID == "second-owner")
        model.handleSnapshotDidChange()
        try await waitForTestEvent { model.snapshot == nil }
        #expect(model.isUsingCachedSnapshot == false)
        reading = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: morning)
        await model.reload(now: morning).value
        reading = ScheduleOccurrenceResolver.resolvedSnapshot(from: ScheduleExternalSnapshot(isLoggedIn: false,
            studentID: "", firstDayString: "", timeTable: [], courses: []), now: later)
        await model.reload(now: later).value
        #expect(model.contentState == .loggedOut && model.nextOccurrence == nil)
        reading = .init(snapshot: nil, upcomingOccurrences: [], contentState: failure)
        await model.reload(now: later).value
        #expect(model.snapshot == nil && model.contentState == failure && model.isUsingCachedSnapshot == false)
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
