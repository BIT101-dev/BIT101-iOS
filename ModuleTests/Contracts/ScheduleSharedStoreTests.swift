import BIT101TestSupport
import Foundation
import ScheduleContracts
import ScheduleDomain
import ScheduleSharedStore
import StorageCore
import Testing

@MainActor
struct ScheduleSharedStoreTests {
    @Test(arguments: ["bytes", "courses", "weeks", "field", "aggregate", "revision"])
    func invalidSnapshotsPreserveTheirSource(kind: String) throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/shared-budget"))
        let url = try #require(store.fileURL)
        let course = ScheduleExternalCourseSnapshot(
            id: "fixture",
            name: kind == "field"
                ? String(repeating: "课", count: 1_366)
                : kind == "aggregate"
                    ? String(repeating: "n", count: ScheduleExternalSnapshotCodec.maximumFieldBytes)
                    : "fixture",
            classroom: "", teacher: "",
            weeks: kind == "weeks"
                ? Array(repeating: 1, count: ScheduleCourseConstraints.maximumWeek * 2 + 1) : [1],
            weekday: 1, startSection: 1, endSection: 1)
        let invalid = ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            revision: kind == "revision" ? UInt64.max : 1, isLoggedIn: true,
            studentID: "budget-owner",
            firstDayString: "", timeTable: [],
            courses: kind == "courses"
                ? Array(
                    repeating: course, count: ScheduleExternalSnapshotCodec.maximumCourseCount + 1)
                : kind == "aggregate"
                    ? Array(
                        repeating: course,
                        count: ScheduleExternalSnapshotCodec.maximumEncodedBytes
                            / ScheduleExternalSnapshotCodec.maximumFieldBytes + 1) : [course])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let raw =
            kind == "bytes"
            ? Data(count: ScheduleExternalSnapshotCodec.maximumEncodedBytes + 1)
            : try encoder.encode(invalid)
        #expect(throws: CocoaError.self) { try ScheduleExternalSnapshotCodec.decode(raw) }
        if kind != "bytes" {
            #expect(throws: CocoaError.self) { try ScheduleExternalSnapshotCodec.encode(invalid) }
        }
        try files.writeData(raw, to: url, options: [])
        let reads = files.readCount(at: url)
        #expect(store.load() == nil && files.storedData[url] == raw)
        if kind == "bytes" { #expect(files.readCount(at: url) == reads) }
        #expect(throws: ScheduleExternalSnapshotStoreError.invalidSnapshot) { try store.read() }
        #expect(
            ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .invalid)
        let recovered = ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0), revision: 2,
            isLoggedIn: true, studentID: "budget-owner", firstDayString: "", timeTable: [],
            courses: [])
        #expect(try store.writeIfNewer(recovered))
        #expect(store.load()?.revision == 2)
        #expect(store.clear() && store.load() == nil)
        if kind == "revision" {
            #expect(
                WatchScheduleTransferProtocol.knownRevision(
                    from: WatchScheduleTransferProtocol.requestContext(knownRevision: .max)) == nil)
        }
    }

    @Test(arguments: ["same-account", "new-account"])
    func restoredPhoneSnapshotsAdvancePastWatchHead(account: String) throws {
        let store = ScheduleExternalSnapshotStore(
            files: ModuleScoreFiles(), containerURL: URL(fileURLWithPath: "/watch-recovery"))
        func snapshot(_ revision: UInt64, _ identifier: String, _ seconds: Double)
            -> ScheduleExternalSnapshot
        {
            .init(
                generatedAt: Date(timeIntervalSince1970: seconds), revision: revision,
                isLoggedIn: true, studentID: identifier, firstDayString: "", timeTable: [],
                courses: [])
        }
        try store.write(snapshot(1_000, "same-account", 1_000))
        let phone = snapshot(10, account, 10)
        let request = WatchScheduleTransferProtocol.requestContext(
            knownRevision: try #require(store.load()).revision)
        let knownRevision = try #require(WatchScheduleTransferProtocol.knownRevision(from: request))
        let recovered = try #require(phone.advancingRevision(after: knownRevision))
        #expect(try store.writeIfNewer(recovered))
        #expect(
            store.load()?.studentID == AccountStorageIdentity.stableToken(for: account)
                && store.load()?.revision == 1_001)
        #expect(recovered.advancingRevision(after: 10) == recovered)
        #expect(phone.advancingRevision(after: UInt64.max) == nil)
        #expect(
            WatchScheduleTransferProtocol.knownRevision(from: [
                WatchScheduleTransferProtocol.requestLatestSnapshotKey: true
            ]) == nil)
    }

    @Test(arguments: [UInt64(0), UInt64(1_000)])
    func clearedSnapshotSurviveStoreReconstruction(revision: UInt64) throws {
        let files = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/watch-cleared-version")
        let store = ScheduleExternalSnapshotStore(files: files, containerURL: root)
        let snapshot = ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 100), revision: revision,
            isLoggedIn: true, studentID: "watch-account", firstDayString: "", timeTable: [],
            courses: [])
        try store.write(snapshot)
        #expect(store.clearRetainingVersion() && store.load() == nil)
        let restored = ScheduleExternalSnapshotStore(files: files, containerURL: root)
        #expect(restored.load() == nil && restored.latestRevision == revision)
        #expect(restored.clearRetainingVersion())
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) {
            try restored.writeIfNewer(snapshot)
        }
        #expect(restored.load() == nil)
        let fresh = try #require(snapshot.advancingRevision(after: restored.latestRevision))
        #expect(try restored.writeIfNewer(fresh))
        #expect(restored.load()?.revision == revision + 1)
        files.setFailures(writing: true)
        #expect(restored.clearRetainingVersion() == false)
        #expect(restored.load()?.revision == revision + 1)
        files.setFailures()
        let file = try #require(restored.fileURL)
        try files.writeData(Data("damaged snapshot".utf8), to: file, options: [])
        #expect(restored.clearRetainingVersion() && restored.load() == nil)
        #expect(files.storedData[file] == nil)
    }

    @Test func outOrderSnapshotsPreserveNewAccount() throws {
        let store = ScheduleExternalSnapshotStore(
            files: ModuleScoreFiles(), containerURL: URL(fileURLWithPath: "/module-shared-order"))
        func value(_ revision: UInt64, _ account: String, loggedIn: Bool = true)
            -> ScheduleExternalSnapshot
        {
            ScheduleExternalSnapshot(
                generatedAt: Date(timeIntervalSince1970: 100), revision: revision,
                isLoggedIn: loggedIn, studentID: AccountStorageIdentity.stableToken(for: account),
                firstDayString: "2026-09-28", timeTable: [], courses: [])
        }
        let current = value(2, "new-account")
        #expect(try store.writeIfNewer(current))
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) {
            try store.writeIfNewer(value(1, "old-account"))
        }
        #expect(store.load() == current)
        #expect(try store.writeIfNewer(current) == false)
        let logout = value(3, "new-account", loggedIn: false)
        #expect(try store.writeIfNewer(logout))
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) {
            try store.writeIfNewer(current)
        }
        #expect(store.load() == logout)
        #expect(
            try ScheduleExternalSnapshotCodec.decode(ScheduleExternalSnapshotCodec.encode(logout))
                == logout)
    }

    private func snapshot(studentID: String = "shared-store-account") -> ScheduleExternalSnapshot {
        ScheduleExternalSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0), isLoggedIn: true, studentID: studentID,
            firstDayString: "2026-09-28", timeTable: [], courses: []
        )
    }

    private func observeChange(on center: NotificationCenter, operation: () throws -> Void)
        async throws
    {
        var observer: (any NSObjectProtocol)?
        defer { if let observer { center.removeObserver(observer) } }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            observer = center.addObserver(
                forName: .scheduleExternalSnapshotDidChange, object: nil, queue: nil
            ) { _ in
                continuation.resume()
            }
            do { try operation() } catch { continuation.resume(throwing: error) }
        }
    }

    @Test(.timeLimit(.minutes(1))) func injectedContainerFiles() async throws {
        let files = ModuleScoreFiles()
        let center = NotificationCenter()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-store"),
            notificationCenter: center
        )
        let other = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-store-other"),
            notificationCenter: NotificationCenter()
        )
        let value = snapshot(
            studentID: AccountStorageIdentity.stableToken(for: "shared-store-account"))
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

    @Test(.timeLimit(.minutes(1))) func legacyIdentityMigrationUsesInjectedStore() async throws {
        let files = ModuleScoreFiles()
        let center = NotificationCenter()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-migration"),
            notificationCenter: center
        )
        let url = try #require(store.fileURL)
        let original = try ScheduleExternalSnapshotCodec.encode(snapshot())
        try files.writeData(original, to: url, options: [.atomic])
        let migrated = store.load()
        #expect(
            migrated?.studentID == AccountStorageIdentity.stableToken(for: "shared-store-account"))
        #expect(try files.readData(at: url) == original)
        let sanitized = try #require(migrated)
        try await observeChange(on: center) { try store.write(sanitized) }
        #expect(try ScheduleExternalSnapshotCodec.decode(files.readData(at: url)) == migrated)
    }

    @Test func unreadableDataAndPreserveStoredBytesBytes() throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-failures"),
            notificationCenter: NotificationCenter()
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
        #expect(
            store.load()?.studentID
                == AccountStorageIdentity.stableToken(for: "shared-store-account"))
        #expect(try files.readData(at: url) == legacy)
    }

    @Test func readingFailurePreservesNewerSnapshots() throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/module-shared-failures"))
        func value(_ revision: UInt64) -> ScheduleExternalSnapshot {
            ScheduleExternalSnapshot(
                generatedAt: Date(timeIntervalSince1970: Double(revision)), revision: revision,
                isLoggedIn: true, studentID: "shared-store-account", firstDayString: "",
                timeTable: [], courses: [])
        }
        try store.write(value(2))
        let url = try #require(store.fileURL)
        let original = files.storedData[url]
        files.setFailures(reading: true, existence: true)
        #expect(store.load() == nil)
        #expect(throws: CocoaError(.fileReadNoPermission)) { try store.read() }
        #expect(
            ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState
                == .unavailable)
        #expect(throws: CocoaError(.fileReadNoPermission)) { try store.writeIfNewer(value(1)) }
        #expect(files.storedData[url] == original)
        files.setFailures(removal: true, existence: true)
        #expect(!store.clear())
        #expect(files.storedData[url] == original)
        files.setFailures()
        #expect(throws: ScheduleExternalSnapshotStoreError.staleSnapshot) {
            try store.writeIfNewer(value(1))
        }
        #expect(try store.writeIfNewer(value(3)))
        #expect(store.load()?.revision == 3)
    }

    @Test func unavailableContainersHaveExplicitResults() {
        let store = ScheduleExternalSnapshotStore(
            files: ModuleScoreFiles(), containerURL: nil, notificationCenter: NotificationCenter())
        #expect(store.fileURL == nil)
        #expect(store.load() == nil)
        #expect(throws: ScheduleExternalSnapshotStoreError.sharedContainerUnavailable) {
            try store.read()
        }
        #expect(
            ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState
                == .unavailable)
        #expect(store.save(snapshot()) == false)
        #expect(store.clear() == false)
        #expect(throws: ScheduleExternalSnapshotStoreError.sharedContainerUnavailable) {
            try store.write(snapshot())
        }
    }

    @Test func missingAndMalformedHaveDistinctStates() throws {
        let files = ModuleScoreFiles()
        let store = ScheduleExternalSnapshotStore(
            files: files, containerURL: URL(fileURLWithPath: "/shared-display"))
        #expect(try store.read() == nil)
        #expect(
            ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .missing)
        let url = try #require(store.fileURL)
        try files.writeData(Data("invalid-json".utf8), to: url, options: [])
        #expect(throws: ScheduleExternalSnapshotStoreError.invalidSnapshot) { try store.read() }
        #expect(
            ScheduleOccurrenceResolver.loadResolvedSnapshot(store: store).contentState == .invalid)
        let now = Date(timeIntervalSince1970: 0)
        let timeline = ScheduleOccurrenceResolver.loadResolvedTimeline(
            store: store, now: now, includeDisplayUntilDates: true)
        #expect(timeline.map(\.date) == [now] && timeline.first?.resolved.contentState == .invalid)
        #expect(try store.writeIfNewer(snapshot()))
        #expect(try store.read() != nil)
    }
}

struct ScheduleTimestampPublicContractTests {
    @Test func monotonicVersionsAndRestoreUseDomainRules() {
        let previous = Date(timeIntervalSince1970: 100)
        #expect(ScheduleCacheTimestamp.next(after: previous, now: previous) > previous)
        #expect(
            ScheduleCacheTimestamp.next(after: previous, now: previous.addingTimeInterval(-10))
                > previous)
        #expect(
            ScheduleCacheTimestamp.afterCloudSave(
                previous.addingTimeInterval(-10), currentDate: previous) == previous)
        #expect(
            ScheduleCacheTimestamp.restored(
                recordDate: previous, payloadDate: previous.addingTimeInterval(1),
                serverDate: previous.addingTimeInterval(20)) == previous.addingTimeInterval(20))
        #expect(
            ScheduleCacheTimestamp.restored(
                recordDate: previous, payloadDate: previous.addingTimeInterval(2)) == nil)
    }
}
