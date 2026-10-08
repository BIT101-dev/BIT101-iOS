import BIT101TestSupport
import StorageCore
import Foundation
import ScheduleContracts
import ScheduleSharedStore
import ScheduleDomain
import Testing

struct ScheduleContractsTests {
    @Test func extremeCourseFieldsAndShareExpansionAreRejectedBeforeAllocation() throws {
        for input in ["1-1000000000", String(Int.max), String(Int.min), "-1000000000-1"] {
            #expect(throws: Error.self) { try ScheduleCourseEditor.parseWeeks(input) }
        }
        #expect(try ScheduleCourseEditor.parseWeeks("-2,-1,1-3") == [-2, -1, 1, 2, 3])
        #expect(throws: Error.self) {
            try ScheduleCourseEditor.resolve(CourseDraft(title: "范围", startSection: 1, endSection: Int.max, weeksText: "1"))
        }
        let day = try #require(ScheduleSharedDateCodec.parseDate("2030-09-16"))
        #expect(ScheduleSharedDateCodec.combine(firstDay: day, week: Int.max, weekday: 1, time: "08:00") == nil)
        #expect(ScheduleSharedDateCodec.combine(firstDay: day, week: Int.min, weekday: 1, time: "08:00") == nil)
        #expect(ScheduleSharedDateCodec.combine(firstDay: day, week: 1, weekday: Int.max, time: "08:00") == nil)
        let oversized = "BIT101SCH3:" + String(repeating: "A", count: ScheduleShareCodeCodec.maximumEncodedBytes)
        #expect(throws: ScheduleShareCodeError.invalidFormat) { try ScheduleShareCodeCodec.decode(oversized, using: ScheduleCache()) }
        let expanded = Data(repeating: 32, count: ScheduleShareCodeCodec.maximumDecodedBytes + 1)
        let compressed = try (expanded as NSData).compressed(using: .lzfse) as Data
        #expect(throws: ScheduleShareCodeError.decompressionFailed) {
            try ScheduleShareCodeCodec.decode("BIT101SCH3:" + compressed.base64EncodedString(), using: ScheduleCache())
        }
    }

    @Test func sharePayloadValidatesCourseFieldsTimeSlotsAndCapacity() throws {
        let slots = TimeSlot.default
        for (weeks, weekday, first, last) in [([Int.max], 1, 1, 1), ([1], 8, 1, 1), ([1], 1, 0, 1), ([1], 1, 1, Int.max), ([1], 1, 1, slots.count + 1)] {
            let course = sharedCourse(weeks: weeks, weekday: weekday, first: first, last: last)
            let payload = ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: slots, courses: [course])
            #expect(throws: ScheduleShareCodeError.invalidFormat) { try payload.validate() }
        }
        let course = sharedCourse(weeks: [-2, -1, 1])
        try ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: slots, courses: [course]).validate()
        #expect(throws: ScheduleShareCodeError.invalidFormat) {
            try ScheduleShareCodeCodec.encodeLatest(courses: Array(repeating: course, count: ScheduleShareCodeCodec.maximumCourseCount + 1))
        }
        let midnight = ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: [TimeSlot(id: 1, start: "23:00", end: "24:00")], courses: [course])
        try midnight.validate()
        let day = try #require(ScheduleSharedDateCodec.parseDate("2030-09-16"))
        for time in ["08::00", ":08:00:", "08:00:", ":08:00", "08:", ":00"] {
            #expect(ScheduleSharedDateCodec.combine(date: day, time: time) == nil)
            #expect(TimeSlot.parseMinutes(time) == 0)
            let malformed = ScheduleExportPayload(currentTerm: "", firstDayString: "", timeTable: [TimeSlot(id: 1, start: time, end: "09:00")], courses: [course])
            #expect(throws: ScheduleShareCodeError.invalidFormat) { try malformed.validate() }
        }
    }

    @Test func externalOccurrencesRetainCoursesBeforeTheFirstWeek() throws {
        let snapshot = ScheduleExternalSnapshot(generatedAt: .distantPast, isLoggedIn: true, studentID: "negative-weeks",
            firstDayString: "2030-09-16", timeTable: [.init(id: 1, start: "08:00", end: "08:45")],
            courses: [.init(id: "negative", name: "首周前课程", classroom: "", teacher: "", weeks: [-2, -1, 1], weekday: 1, startSection: 1, endSection: 1)])
        let now = try #require(ScheduleSharedDateCodec.parseDate("2030-09-01"))
        let occurrences = ScheduleOccurrenceResolver.upcomingOccurrences(from: snapshot, now: now)
        #expect(occurrences.count == 3)
        #expect(occurrences.map { ScheduleSharedDateCodec.formatDate($0.startDate) } == ["2030-09-02", "2030-09-09", "2030-09-16"])
    }

    private func sharedCourse(weeks: [Int], weekday: Int = 1, first: Int = 1, last: Int = 1) -> CourseRecord {
        CourseRecord(id: "share-validation", term: "", name: "课程", teacher: "", classroom: "", description: "", weeks: weeks,
            weekday: weekday, startSection: first, endSection: last, campus: "", number: "", credit: 0, hour: 0, type: "", category: "", department: "")
    }

    @Test @MainActor func scheduleDateDisplaysUseTheSharedSchoolTimeZone() throws {
        let day = try #require(ScheduleSharedDateCodec.parseDate("2026-10-01"))
        #expect(ScheduleDateCodec.formatTime(day) == "00:00")
        #expect(ScheduleSharedDateCodec.formatTime(day) == "00:00")
        #expect(ScheduleDateCodec.calendar == ScheduleSharedDateCodec.calendar)
        #expect(ScheduleDateCodec.formatCompactDate(day) == "10.1")
        #expect(ScheduleDateCodec.formatDate(day.addingTimeInterval(-1)) == "2026-09-30")
    }

    @Test func courseSnapshotTracksCourseFieldsAcrossSceneChanges() {
        var cache = ScheduleCache()
        let courses = cache.courseSnapshot
        cache.ddlBeforeDay = 3
        cache.selectedBuildingID = "module-building"
        cache.iCloudSyncEnabled = true
        #expect(cache.courseSnapshot == courses)
        cache.manualFirstDayStringsByTerm[cache.currentTerm] = "2026-09-07"
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
        cache.manualFirstDayStringsByTerm[cache.currentTerm] = "2026-09-28"
        let courses = try ScheduleCourseEditor.adding(
            CourseDraft(
                title: "模块验证课程", classroom: "文萃楼I203",
                weekday: 1, startSection: 1, endSection: 2, weeksText: "1-4,6"
            ),
            to: [], term: cache.currentTerm, id: "domain-course"
        )
        ScheduleCourseEditor.updateCacheForManualCourseChange(in: &cache, previousCourses: [], currentCourses: courses)
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
        for leadTime: TimeInterval in [1, 10, 29, 30] {
            for displayDates in [true, false] {
                #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [occurrence], now: occurrence.startDate.addingTimeInterval(-leadTime),
                    includeDisplayUntilDates: displayDates, includeNextMidnight: true) == occurrence.startDate)
            }
        }
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [occurrence], now: occurrence.displayUntilDate.addingTimeInterval(-10),
            includeDisplayUntilDates: true, includeNextMidnight: false) == occurrence.displayUntilDate)
        let midnight = try #require(ScheduleSharedDateCodec.calendar.date(byAdding: .day, value: 1, to: firstDay)).addingTimeInterval(1)
        #expect(ScheduleTimelineRefreshPlanner.nextRefreshDate(for: [], now: midnight.addingTimeInterval(-10),
            includeDisplayUntilDates: false, includeNextMidnight: true) == midnight)
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
    @Test func outOfOrderSnapshotsPreserveTheNewAccountAndLogout() throws {
        let store = ScheduleExternalSnapshotStore(files: ModuleScoreFiles(), containerURL: URL(fileURLWithPath: "/module-shared-order"))
        func value(_ revision: UInt64, _ account: String, loggedIn: Bool = true) -> ScheduleExternalSnapshot {
            ScheduleExternalSnapshot(generatedAt: Date(timeIntervalSince1970: 100), revision: revision,
                isLoggedIn: loggedIn, studentID: AccountStorageIdentity.stableToken(for: account),
                firstDayString: "2026-09-28", timeTable: [], courses: [])
        }
        let current = value(2, "new-account")
        #expect(try store.writeIfNewer(current))
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) { try store.writeIfNewer(value(1, "old-account")) }
        #expect(store.load() == current)
        #expect(try store.writeIfNewer(current) == false)
        let logout = value(3, "new-account", loggedIn: false)
        #expect(try store.writeIfNewer(logout))
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) { try store.writeIfNewer(current) }
        #expect(store.load() == logout)
        #expect(try ScheduleExternalSnapshotCodec.decode(ScheduleExternalSnapshotCodec.encode(logout)) == logout)
    }

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
        let original = try ScheduleExternalSnapshotCodec.encode(snapshot())
        try files.writeData(original, to: url, options: [.atomic])
        let migrated = store.load()
        #expect(migrated?.studentID == AccountStorageIdentity.stableToken(for: "shared-store-account"))
        #expect(try files.readData(at: url) == original)
        let sanitized = try #require(migrated)
        try await observeChange(on: center) { try store.write(sanitized) }
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

struct ScheduleTimestampPublicContractTests {
    @Test func monotonicVersionsAndCloudRestorationUseDomainRules() {
        let previous = Date(timeIntervalSince1970: 100)
        #expect(ScheduleCacheTimestamp.next(after: previous, now: previous) > previous)
        #expect(ScheduleCacheTimestamp.next(after: previous, now: previous.addingTimeInterval(-10)) > previous)
        #expect(ScheduleCacheTimestamp.afterCloudSave(previous.addingTimeInterval(-10), currentDate: previous) == previous)
        #expect(ScheduleCacheTimestamp.restored(recordDate: previous, payloadDate: previous.addingTimeInterval(1), serverDate: previous.addingTimeInterval(20)) == previous.addingTimeInterval(20))
        #expect(ScheduleCacheTimestamp.restored(recordDate: previous, payloadDate: previous.addingTimeInterval(2)) == nil)
    }
}
