import BIT101TestSupport
import StorageCore
import Foundation
import ScheduleContracts
import ScheduleSharedStore
import ScheduleDomain
import Testing

struct ScheduleContractsTests {
    @Test func courseSnapshotTracksCourseFieldsAcrossSceneChanges() {
        var cache = ScheduleCache()
        let courses = cache.courseSnapshot
        cache.ddlBeforeDay = 3
        cache.selectedBuildingID = "module-building"
        cache.iCloudSyncEnabled = true
        #expect(cache.courseSnapshot == courses)
        cache.firstDayString = "2026-09-07"
        #expect(cache.courseSnapshot != courses)
        #expect(cache.courseSnapshot.firstDay == ScheduleSharedDateCodec.parseDate("2026-09-07"))
    }

    @Test func domainStorageResultsDescribeMissingReadableAndUnreadableSnapshots() {
        var cache = ScheduleCache()
        cache.primaryScheduleTitle = "领域快照"
        #expect(ScheduleCacheLoadResult.missing.allowsWrite)
        #expect(ScheduleCacheLoadResult.missing.cacheIfReadable?.courses.isEmpty == true)
        #expect(ScheduleCacheLoadResult.loaded(cache).cacheIfReadable?.primaryScheduleTitle == "领域快照")
        #expect(ScheduleCacheLoadResult.unreadable.isUnreadable)
        #expect(ScheduleCacheLoadResult.unreadable.cacheIfReadable == nil)
        #expect(ScheduleCacheLoadResult.unreadable.allowsWrite == false)
    }

    @Test @MainActor func domainCourseEditingSurvivesCacheAndShareRoundTrips() throws {
        var cache = ScheduleCache()
        cache.currentTerm = "2026-2027-1"
        cache.firstDayString = "2026-09-28"
        cache.courses = try ScheduleCourseEditor.adding(
            CourseDraft(
                title: "模块验证课程", classroom: "文萃楼I203",
                weekday: 1, startSection: 1, endSection: 2, weeksText: "1-4,6"
            ),
            to: [], term: cache.currentTerm, id: "domain-course"
        )
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(cache))
        #expect(restored.courses == cache.courses)
        #expect(restored.currentTerm == cache.currentTerm)
        let shared = try ScheduleShareCodeCodec.decode(
            ScheduleShareCodeCodec.encodeLatest(cache: restored), using: restored
        )
        let course = try #require(shared.courses.first)
        #expect(course.name == "模块验证课程")
        #expect(course.weeks == [1, 2, 3, 4, 6])
        #expect(course.classroom == "文萃楼I203")
        #expect(course.startSection == 1)
        #expect(course.endSection == 2)
        #expect(shared.currentTerm == cache.currentTerm)
        #expect(shared.firstDayString == cache.firstDayString)
    }

    @Test func fixedEarlierPayloadAndFutureFieldsUseTheSharedWatchCodec() throws {
        let payload = Data(#"{"isLoggedIn":true,"studentID":"fixture-account","firstDayString":"2026-09-28","timeTable":[{"id":1,"start":"08:00","end":"08:45","futureTimeField":1}],"courses":[{"id":"fixture-course","name":"固定课程","weeks":[1],"weekday":1,"startSection":1,"futureCourseField":true}],"futureSnapshotField":"value"}"#.utf8)
        let context = WatchScheduleTransferProtocol.snapshotContext(payload)
        let decoded = try ScheduleExternalSnapshotCodec.decode(#require(WatchScheduleTransferProtocol.snapshotData(from: context)))
        #expect(decoded.generatedAt == .distantPast)
        #expect(decoded.courses.first?.teacher == "")
        #expect(decoded.courses.first?.classroom == "")
        #expect(decoded.courses.first?.endSection == 1)
        #expect(decoded.timeTable.first?.start == "08:00")
        #expect(try ScheduleExternalSnapshotCodec.decode(ScheduleExternalSnapshotCodec.encode(decoded)) == decoded)
    }

    @Test func incompleteSchedulingIdentityHasAnExplicitDecodeFailure() {
        let payload = Data(#"{"courses":[{"id":"fixture-course","name":"课程","weeks":[1],"startSection":1}]}"#.utf8)
        #expect(throws: DecodingError.self) { try ScheduleExternalSnapshotCodec.decode(payload) }
    }

    @Test func snapshotRoundTripPreservesContract() throws {
        let snapshot = makeSnapshot()
        let data = try ScheduleExternalSnapshotCodec.encode(snapshot)
        let decoded = try ScheduleExternalSnapshotCodec.decode(data)
        #expect(decoded == snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["studentID"] as? String == snapshot.studentID)
        #expect(object["firstDayString"] as? String == "2026-09-28")
    }

    @Test func accountTokensRemainStable() {
        let token = AccountStorageIdentity.stableToken(for: "module-test-account")
        #expect(token.hasPrefix("account-"))
        #expect(AccountStorageIdentity.stableToken(for: token) == token)
        #expect(AccountStorageIdentity.stableToken(for: " module-test-account ") == token)
    }

    @Test func watchPayloadUsesSharedCodec() throws {
        let data = try ScheduleExternalSnapshotCodec.encode(makeSnapshot())
        let context = WatchScheduleTransferProtocol.snapshotContext(data)
        #expect(WatchScheduleTransferProtocol.snapshotData(from: context) == data)
        #expect(WatchScheduleTransferProtocol.requestsLatestSnapshot(WatchScheduleTransferProtocol.requestContext))
    }

    @Test func occurrenceAndRefreshBoundaries() throws {
        let snapshot = makeSnapshot()
        let firstDay = try #require(ScheduleSharedDateCodec.parseDate(snapshot.firstDayString))
        let now = try #require(ScheduleSharedDateCodec.combine(date: firstDay, time: "07:00"))
        let resolved = ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot, now: now)
        #expect(resolved.contentState == .ready)
        let occurrence = try #require(resolved.nextOccurrence)
        #expect(occurrence.startDate == ScheduleSharedDateCodec.combine(date: firstDay, time: "08:00"))
        #expect(occurrence.endDate == ScheduleSharedDateCodec.combine(date: firstDay, time: "08:45"))
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(
            for: resolved.upcomingOccurrences,
            now: now,
            includeDisplayUntilDates: true,
            includeNextMidnight: true
        ) == occurrence.startDate)
    }

    @Test func emptyAndMissingSnapshotsHaveExplicitStates() {
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: nil).contentState == .missing)
        let snapshot = ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            isLoggedIn: true,
            studentID: "account",
            firstDayString: "2026-09-28",
            timeTable: [],
            courses: []
        )
        #expect(ScheduleOccurrenceResolver.resolvedSnapshot(from: snapshot).contentState == .rest)
    }

    private func makeSnapshot() -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_790_553_600),
            isLoggedIn: true,
            studentID: AccountStorageIdentity.stableToken(for: "module-test-account"),
            firstDayString: "2026-09-28",
            timeTable: [ScheduleExternalTimeSlotSnapshot(id: 1, start: "08:00", end: "08:45")],
            courses: [ScheduleExternalCourseSnapshot(
                id: "course", name: "模块验证课程", classroom: "文萃楼I203", teacher: "教师",
                weeks: [1], weekday: 1, startSection: 1, endSection: 1
            )]
        )
    }
}

@MainActor
struct ScheduleSharedStoreTests {
    private func snapshot(studentID: String = "shared-store-account") -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0), isLoggedIn: true, studentID: studentID,
            firstDayString: "2026-09-28", timeTable: [], courses: []
        )
    }

    private func observeChange(on center: NotificationCenter, operation: () throws -> Void) async throws {
        var observer: (any NSObjectProtocol)?
        defer { if let observer { center.removeObserver(observer) } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            observer = center.addObserver(forName: .scheduleExternalSnapshotDidChange, object: nil, queue: nil) { _ in
                continuation.resume()
            }
            do { try operation() } catch { continuation.resume(throwing: error) }
        }
    }

    @Test func injectedContainerFilesAndNotificationsOwnTheSnapshot() async throws {
        let files = ModuleScoreFiles()
        let center = NotificationCenter()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-store"), notificationCenter: center
        )
        let other = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-store-other"), notificationCenter: NotificationCenter()
        )
        let value = snapshot(studentID: AccountStorageIdentity.stableToken(for: "shared-store-account"))
        try await observeChange(on: center) { try store.write(value) }
        let url = try #require(store.fileURL)
        #expect(url.path == "/module-shared-store/Widgets/schedule-widget-snapshot.json")
        #expect(files.writingOptions(at: url) == AppFileSystem.protectedDataWritingOptions)
        #expect(store.load() == value)
        #expect(other.load() == nil)
        #expect(ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .rest)
        try await observeChange(on: center) { #expect(store.clear()) }
        #expect(store.load() == nil)
        #expect(store.clear())
    }

    @Test func legacyIdentityMigrationUsesTheInjectedStore() async throws {
        let files = ModuleScoreFiles()
        let center = NotificationCenter()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-migration"), notificationCenter: center
        )
        let url = try #require(store.fileURL)
        try files.writeData(ScheduleExternalSnapshotCodec.encode(snapshot()), to: url, options: [.atomic])
        var migrated: ScheduleExternalSnapshot?
        try await observeChange(on: center) { migrated = store.load() }
        #expect(migrated?.studentID == AccountStorageIdentity.stableToken(for: "shared-store-account"))
        #expect(try ScheduleExternalSnapshotCodec.decode(files.readData(at: url)) == migrated)
    }

    @Test func unreadableDataAndFailedMutationsPreserveStoredBytes() throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-failures"), notificationCenter: NotificationCenter()
        )
        let url = try #require(store.fileURL)
        let corrupt = Data("corrupt snapshot".utf8)
        try files.writeData(corrupt, to: url, options: [.atomic])
        #expect(store.load() == nil)
        #expect(try files.readData(at: url) == corrupt)
        files.setFailures(writing: true, removal: true)
        #expect(store.save(snapshot()) == false)
        #expect(store.clear() == false)
        #expect(try files.readData(at: url) == corrupt)
        files.setFailures()
        let legacy = try ScheduleExternalSnapshotCodec.encode(snapshot())
        try files.writeData(legacy, to: url, options: [.atomic])
        files.setFailures(writing: true)
        #expect(store.load()?.studentID == AccountStorageIdentity.stableToken(for: "shared-store-account"))
        #expect(try files.readData(at: url) == legacy)
    }

    @Test func unavailableContainersHaveExplicitResults() {
        let store = ScheduleExternalSnapshotStore(files: ModuleScoreFiles(), containerURL: nil, notificationCenter: NotificationCenter())
        #expect(store.fileURL == nil)
        #expect(store.load() == nil)
        #expect(store.save(snapshot()) == false)
        #expect(store.clear() == false)
        #expect(throws: ScheduleExternalSnapshotStoreError.sharedContainerUnavailable) { try store.write(snapshot()) }
    }
}
