import Combine
import ScoreDomain
import ScheduleDomain
import SchedulePorts
@testable import ScoreInfrastructure
import CommunityTransport
import CommunityCore
@testable import GalleryFeature
@testable import CommunityUI
@testable import ScheduleFeature
@testable import MediaKit
@testable import ScoreFeature
import StorageCore
import TransportCore
import ClientCore
import ScheduleContracts
import Foundation
import os
import Security
import Testing
import UIKit
@testable import BIT101_iOS

@MainActor
struct AppSettingsPersistenceBoundaryTests {
    @Test func settingsSnapshotsShareGuestKeysAndAccountMigrations() throws {
        let domain = "BIT101AppTests.settings-boundary"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        var session = AppStorageSession(accountIdentifier: "")
        let settings = AppSettingsStore(defaults: defaults, session: { session })
        settings.markSharedScheduleImportGuideSeen()
        let guest = try #require(AppSettingsStore.loadSnapshotFromDefaults(
            for: AppSettingsStore.defaultAccountIdentifier, defaults: defaults
        ))
        #expect(guest.hasSeenSharedScheduleImportGuide)
        #expect(defaults.data(forKey: "app.settings.snapshot.__default__") != nil)

        session = AppStorageSession(accountIdentifier: "settings-a")
        var legacy = AppSettingsSnapshot()
        legacy.hasSeenSharedScheduleImportGuide = true
        let encoded = try JSONEncoder().encode(legacy)
        let oldKey = session.legacyKey(AppSettingsStore.storageKeyPrefix)
        defaults.set(encoded, forKey: oldKey)
        settings.reloadForCurrentAccount()
        #expect(settings.hasSeenSharedScheduleImportGuide)
        #expect(defaults.data(forKey: oldKey) == nil)
        #expect(defaults.data(forKey: session.key(AppSettingsStore.storageKeyPrefix)) != nil)

        session = AppStorageSession(accountIdentifier: "settings-b")
        defaults.set(encoded, forKey: AppSettingsStore.legacyStorageKey)
        settings.reloadForCurrentAccount()
        #expect(settings.hasSeenSharedScheduleImportGuide)
        #expect(defaults.data(forKey: AppSettingsStore.legacyStorageKey) == nil)
        session = AppStorageSession(accountIdentifier: "settings-c")
        settings.reloadForCurrentAccount()
        #expect(settings.hasSeenSharedScheduleImportGuide == false)
        session = AppStorageSession(accountIdentifier: "")
        settings.reloadForCurrentAccount()
        #expect(settings.hasSeenSharedScheduleImportGuide)
    }
}

@Suite("App deep links")
struct AppDeepLinkRouteTests {
    @Test("Universal links route gallery and course details")
    func universalLinks() throws {
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://open.aihelpme.dev/gallery/123"))) == .gallery(123))
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://open.aihelpme.dev/course/456"))) == .course(456))
    }

    @Test("Custom links remain supported and foreign hosts are rejected")
    func customAndForeignLinks() throws {
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "bit101://schedule/courses"))) == .scheduleCourses)
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "bit101://paper/7"))) == .paper(7))
        #expect(AppDeepLinkRoute(url: try #require(URL(string: "https://example.com/gallery/123"))) == nil)
    }
}

@Suite("Image cache disk quota")
struct ImageCacheDiskQuotaTests {
    @Test("Quota pruning evicts least-recently-used entries and protects active files")
    func prunesOldestFilesAndProtectsActiveEntry() async throws {
        let files = AppFileDirectories.files
        let directory = files.temporaryDirectoryURL.appending(
            path: "image-cache-quota-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try files.createDirectory(at: directory)
        defer { try? files.removeItem(at: directory) }

        let oldest = directory.appending(path: "oldest.jpg")
        let middle = directory.appending(path: "middle.jpg")
        let protected = directory.appending(path: "protected.jpg")
        let imageData = Data(repeating: 1, count: 600_000)
        for file in [oldest, middle, protected] {
            try files.writeData(imageData, to: file, options: [.atomic])
        }
        try files.setModificationDate(Date(timeIntervalSince1970: 1), at: oldest)
        try files.setModificationDate(Date(timeIntervalSince1970: 2), at: middle)
        try files.setModificationDate(Date(timeIntervalSince1970: 3), at: protected)

        let quota = ImageCacheDiskQuota(
            files: files,
            directories: [directory],
            cacheLimitMB: { 1 },
            pruneInterval: 0
        )
        await quota.enforce(force: true, protecting: Set([protected]))

        #expect(!files.fileExists(at: oldest))
        #expect(!files.fileExists(at: middle))
        #expect(files.fileExists(at: protected))
    }
}

@Suite("Score cache file safety")
struct ScoreCacheDiskRepositoryTests {
    @Test("Unreadable score snapshots block replacement and remain intact")
    func preservesUnreadableSnapshot() async throws {
        let files = AppFileDirectories.files
        let root = files.temporaryDirectoryURL.appending(
            path: "score-cache-safety-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let session = AppStorageSession(accountIdentifier: "score-store-\(UUID().uuidString)")
        let repository = ScoreCacheDiskRepository(files: files, storageRoot: root)
        defer { try? files.removeItem(at: root) }

        let rows = [ScoreRow(index: 0, headers: ["课程名称"], values: ["离散数学"])]
        let saved = await repository.mutate(
            .detailedRows(rows),
            for: session,
            legacyData: .empty
        )
        #expect(saved.isSaved)

        let fileURL = root
            .appending(path: session.accountStorageIdentifier, directoryHint: .isDirectory)
            .appending(path: "score-cache.json")
        let corruptData = Data("invalid score cache".utf8)
        try files.writeData(corruptData, to: fileURL, options: [.atomic])

        let loadResult = await repository.load(for: session, legacyData: .empty)
        #expect(loadResult.isUnreadable)

        let replacement = await repository.mutate(
            .rows([]),
            for: session,
            legacyData: .empty
        )
        #expect(replacement.isUnreadable)
        #expect(try files.readData(at: fileURL) == corruptData)
    }
}

nonisolated final class PreferenceMemoryFiles: AppFileService, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let requireExistingParentDirectories: Bool
    private struct State {
        var data: [URL: Data] = [:]
        var directories: Set<URL> = []
    }
    init(requireExistingParentDirectories: Bool = false) {
        self.requireExistingParentDirectories = requireExistingParentDirectories
    }
    var temporaryDirectoryURL: URL { URL(fileURLWithPath: "/preference-sync") }
    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? { temporaryDirectoryURL }
    func appGroupContainerURL(identifier: String) -> URL? { temporaryDirectoryURL }
    func fileExists(at url: URL) -> Bool { state.withLock { $0.data[url] != nil } }
    func readData(at url: URL) throws -> Data {
        try state.withLock { state in
            guard let value = state.data[url] else { throw CocoaError(.fileReadNoSuchFile) }
            return value
        }
    }
    func writeData(_ value: Data, to url: URL, options: Data.WritingOptions) throws {
        try state.withLock { state in
            if requireExistingParentDirectories && !state.directories.contains(url.deletingLastPathComponent()) {
                throw CocoaError(.fileNoSuchFile)
            }
            state.data[url] = value
        }
    }
    func removeItem(at url: URL) throws { state.withLock { $0.data[url] = nil } }
    func createDirectory(at url: URL) throws { _ = state.withLock { $0.directories.insert(url) } }
    func setPrivateFileProtection(at url: URL) throws {}
    func setExcludedFromBackup(at url: URL) throws {}
    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        state.withLock { state in state.data.keys.filter { $0.deletingLastPathComponent() == url } }
    }
    func regularFileSize(at url: URL) -> Int? { state.withLock { $0.data[url]?.count } }
    func isRegularFile(at url: URL) -> Bool { regularFileSize(at: url) != nil }
    func modificationDate(at url: URL) -> Date? { nil }
    func setModificationDate(_ date: Date, at url: URL) throws {}
    func removeContents(of directory: URL) -> Bool {
        return state.withLock { state in
            state.data = state.data.filter { !$0.key.path.hasPrefix(directory.path + "/") }
            state.directories = state.directories.filter { !$0.path.hasPrefix(directory.path + "/") }
            return true
        }
    }
    func totalRegularFileSize(at directory: URL) -> Int64 {
        return state.withLock { state in
            return state.data.filter { $0.key.path.hasPrefix(directory.path + "/") }.values.reduce(0) { $0 + Int64($1.count) }
        }
    }
}

@Suite("Login bootstrap behavior")
struct LoginBootstrapTests {
    private final class LoginServiceStub: LoginServicing {
        enum CheckResult {
            case signedOut
            case failed
        }

        let savedStudentID: String
        let savedPassword = "saved-password"
        let hasCachedSession: Bool
        let checkResult: CheckResult
        private(set) var checkLoginCalls = 0

        init(
            studentID: String = "1120260001",
            hasCachedSession: Bool = true,
            checkResult: CheckResult
        ) {
            savedStudentID = studentID
            self.hasCachedSession = hasCachedSession
            self.checkResult = checkResult
        }

        func checkLogin() async throws -> String? {
            checkLoginCalls += 1
            switch checkResult {
            case .signedOut: return nil
            case .failed: throw URLError(.notConnectedToInternet)
            }
        }

        func login(studentID: String, password: String) async throws -> String { studentID }
        func logout() {}
    }

    @Test("Cached sessions show the app shell before network validation")
    func cachedSessionIsOptimistic() {
        let viewModel = LoginViewModel(service: LoginServiceStub(checkResult: .failed))
        #expect(viewModel.screenState == .signedIn(studentID: "1120260001"))
    }

    @Test("Without a cached session the app starts signed out")
    func missingCachedSessionStartsSignedOut() {
        let service = LoginServiceStub(hasCachedSession: false, checkResult: .failed)
        let viewModel = LoginViewModel(service: service)

        #expect(viewModel.screenState == .signedOut)
        #expect(service.checkLoginCalls == 0)
    }

    @Test("Transient validation failures stay silent and signed in")
    func transientFailureKeepsSession() async {
        let viewModel = LoginViewModel(service: LoginServiceStub(checkResult: .failed))
        await viewModel.bootstrapIfNeeded()
        #expect(viewModel.screenState == .signedIn(studentID: "1120260001"))
        #expect(viewModel.alert == nil)
    }

    @Test("Only an explicit signed-out response dismisses the app shell")
    func explicitSignOutDismissesSession() async {
        let viewModel = LoginViewModel(service: LoginServiceStub(checkResult: .signedOut))
        await viewModel.bootstrapIfNeeded()
        #expect(viewModel.screenState == .signedOut)
    }
}

@Suite("Shared infrastructure")
struct InfrastructureTests {
    private nonisolated struct TestItem: Identifiable, Equatable {
        let id: Int
    }

    private nonisolated struct TestPagedState: PagedItemsState {
        var items: [TestItem] = []
        var nextPage = 0
        var isLoadingMore = false
        var canLoadMore = true
    }

    private nonisolated struct TestCursorState: CursorPagedItemsState {
        var items: [TestItem] = []
        var nextCursor: Int?
        var isLoadingMore = false
        var canLoadMore = true
    }

    @Test("Cancellation signals are normalized")
    func cancellationSignalsAreNormalized() {
        #expect(TaskCancellation.matches(CancellationError()))
        #expect(TaskCancellation.matches(URLError(.cancelled)))
        #expect(!TaskCancellation.matches(URLError(.timedOut)))
    }

    @Test("Community timestamps use one parser and preserve fallback text")
    func communityDateText() {
        #expect(AppDateText.date(from: "2026-09-05T12:34:56.000+0800") != nil)
        #expect(AppDateText.date(from: "not-a-date") == nil)
        #expect(AppDateText.relativeText(from: "not-a-date", fallback: "未知时间") == "未知时间")
    }

    @Test("Codable snapshots are isolated by account")
    func codableSnapshotsAreIsolatedByAccount() throws {
        let suiteName = "AccountScopedCodableStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var session = AppStorageSession(accountIdentifier: "student-a")
        let store = AccountScopedCodableStore<[String]>(
            keyPrefix: "test.snapshot",
            defaults: defaults,
            session: { session }
        )

        let oldKey = session.legacyKey("test.snapshot")
        defaults.set(try JSONEncoder().encode(["A"]), forKey: oldKey)
        #expect(store.load() == ["A"])
        #expect(defaults.object(forKey: oldKey) == nil)
        store.save(["A"])
        #expect(store.load() == ["A"])

        session = AppStorageSession(accountIdentifier: "student-b")
        #expect(store.load() == nil)
        store.save(["B"])
        #expect(store.load() == ["B"])

        session = AppStorageSession(accountIdentifier: "student-a")
        #expect(store.load() == ["A"])
    }

    @Test("Blank accounts use the guest namespace")
    func blankAccountsUseGuestNamespace() {
        let store = AccountScopedCodableStore<[String]>(
            keyPrefix: "test.snapshot",
            session: { AppStorageSession(accountIdentifier: "  ") }
        )

        #expect(store.storageKey == "test.snapshot.guest")
    }

    @Test("Storage sessions centralize account keys and filesystem-safe names")
    func storageSessionNames() {
        let guest = AppStorageSession(accountIdentifier: " \n ")
        #expect(guest.key("test.snapshot") == "test.snapshot.guest")
        #expect(guest.accountDirectoryName == "__default__")

        let account = AppStorageSession(accountIdentifier: "student/a")
        let storageIdentifier = "account-f075dae4022cfb12f24efad0580c7d242ff6360fc0287305a8a399231e4a62ae"
        #expect(account.key("test.snapshot") == "test.snapshot.\(storageIdentifier)")
        #expect(account.accountStorageIdentifier == storageIdentifier)
        #expect(AccountStorageIdentity.stableToken(for: storageIdentifier) == storageIdentifier)
        #expect(!account.accountStorageIdentifier.contains("student"))
        #expect(account.accountDirectoryName == "__encoded__73747564656E742F61")
        #expect(account.legacyAccountDirectoryName == "student_a")
        #expect(account.legacyAccountDirectoryNameForMigration == account.accountDirectoryName)

        let underscoreAccount = AppStorageSession(accountIdentifier: "student_a")
        #expect(underscoreAccount.legacyAccountDirectoryName == "student_a")
        #expect(underscoreAccount.legacyAccountDirectoryNameForMigration == underscoreAccount.accountDirectoryName)
        #expect(account.accountDirectoryName != underscoreAccount.accountDirectoryName)
        #expect(account.accountStorageIdentifier != underscoreAccount.accountStorageIdentifier)
    }

    @Test("Account-scoped file snapshots round-trip and remain isolated")
    func accountScopedFileSnapshots() throws {
        let files = AppFileDirectories.files
        let firstSession = AppStorageSession(accountIdentifier: "file-store-\(UUID().uuidString)")
        var session = firstSession
        let store = AccountScopedFileCodableStore<[String]>(
            filename: "snapshot-test.json",
            session: { session }
        )
        let firstDirectory = store.fileURL.deletingLastPathComponent()
        defer { try? files.removeItem(at: firstDirectory) }

        #expect(store.save(["first-account"]))
        #expect(store.load() == ["first-account"])
        #expect(try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        session = AppStorageSession(accountIdentifier: "file-store-\(UUID().uuidString)")
        let secondDirectory = store.fileURL.deletingLastPathComponent()
        defer { try? files.removeItem(at: secondDirectory) }
        #expect(store.load() == nil)
        #expect(store.save(["second-account"]))

        session = firstSession
        #expect(store.load() == ["first-account"])

        #expect(AppFileSystem.protectedDataWritingOptions.contains(.atomic))
        #expect(
            AppFileSystem.protectedDataWritingOptions.contains(
                .completeFileProtectionUntilFirstUserAuthentication
            )
        )
        session = firstSession
        store.remove()
        #expect(!store.hasStoredFile)
        #expect(store.load() == nil)
    }

    @Test("Keychain deletion status accepts completed and absent items")
    func keychainDeletionStatus() {
        #expect(LoginStorage.keychainDeleteSucceeded(status: errSecSuccess))
        #expect(LoginStorage.keychainDeleteSucceeded(status: errSecItemNotFound))
        #expect(!LoginStorage.keychainDeleteSucceeded(status: errSecNotAvailable))
    }

    @Test("Paged state advances and stops on an empty page")
    func pagedStateAdvancesAndStops() {
        var state = TestPagedState()

        state.applyFirstPage([TestItem(id: 1), TestItem(id: 2)])
        #expect(state.nextPage == 1)
        #expect(state.shouldLoadMore(currentID: 2))

        state.isLoadingMore = true
        #expect(!state.shouldLoadMore(currentID: 2))

        state.appendPage([])
        #expect(state.nextPage == 2)
        #expect(!state.canLoadMore)

        state.resetPagination()
        #expect(state.items.isEmpty)
        #expect(state.nextPage == 0)
        #expect(state.canLoadMore)
    }

    @Test("Cursor state preserves backend cursor semantics")
    func cursorStateAdvancesAndStops() {
        var state = TestCursorState()

        state.applyFirstCursorPage([TestItem(id: 10), TestItem(id: 9)])
        #expect(state.nextCursor == 9)
        #expect(state.shouldLoadMore(currentID: 9))

        state.appendCursorPage([TestItem(id: 8)])
        #expect(state.items.map(\.id) == [10, 9, 8])
        #expect(state.nextCursor == 8)

        state.appendCursorPage([])
        #expect(state.nextCursor == 8)
        #expect(!state.canLoadMore)

        state.resetCursorPagination()
        #expect(state.items.isEmpty)
        #expect(state.nextCursor == nil)
        #expect(state.canLoadMore)
    }
}

@Suite("Composer draft storage")
struct ComposerDraftStorageTests {
    @Test("Persisted image assets are bounded JPEG data")
    func persistedImageSizeAndEncoding() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80))
        let source = renderer.jpegData(withCompressionQuality: 1) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }

        let persisted = try ComposerDraftImageCompressor.compress(source)
        #expect(persisted.count <= ComposerDraftImageCompressor.maximumBytes)
        #expect(UIImage(data: persisted) != nil)
    }
}

@Suite("Score presentation logic", .serialized)
struct ScorePresentationTests {
    @Test("Successful empty score response returns an empty result")
    func successfulEmptyScoreResponse() throws {
        let response = Data(#"{"msg":"查询成功OvO","data":[]}"#.utf8)

        #expect(try ScoreService.decodeScoreRows(response).isEmpty)
    }

    @Test("Empty score response preserves the server failure message")
    func emptyScoreFailureMessage() {
        let response = Data(#"{"msg":"成绩服务暂不可用","data":[]}"#.utf8)

        #expect(throws: ScoreServiceError.self) {
            try ScoreService.decodeScoreRows(response)
        }
    }

}

@MainActor
@Suite("Score detail refresh policy")
struct ScoreDetailRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Unchanged completed scores reuse detailed cache")
    func completedCacheIsReused() {
        let brief = [makeBrief(score: "90")]
        let cached = [makeDetailed(score: "90", completion: "是")]
        #expect(ScoreDetailRefreshPolicy.decision(
            briefRows: brief,
            cachedRows: cached,
            detailedUpdatedAt: nil,
            now: now
        ) == .reuseCompletedCache)
    }

    @Test("New deleted or changed brief scores require detail refresh")
    func changedBriefRequiresDetails() {
        let cached = [makeDetailed(score: "90", completion: "是")]
        #expect(ScoreDetailRefreshPolicy.decision(
            briefRows: [makeBrief(score: "91")],
            cachedRows: cached,
            detailedUpdatedAt: now,
            now: now
        ) == .fetch)
        #expect(ScoreDetailRefreshPolicy.decision(
            briefRows: [makeBrief(score: "90"), makeBrief(number: "NEW-1", score: "88")],
            cachedRows: cached,
            detailedUpdatedAt: now,
            now: now
        ) == .fetch)
        #expect(ScoreDetailRefreshPolicy.decision(
            briefRows: [],
            cachedRows: cached,
            detailedUpdatedAt: now,
            now: now
        ) == .fetch)
    }

    @Test("Incomplete unchanged details are limited to once per day")
    func incompleteCacheIsRateLimited() {
        let brief = [makeBrief(score: "90")]
        let cached = [makeDetailed(score: "90", completion: "否")]
        #expect(ScoreDetailRefreshPolicy.decision(
            briefRows: brief,
            cachedRows: cached,
            detailedUpdatedAt: now.addingTimeInterval(-60 * 60),
            now: now
        ) == .reuseRateLimitedCache)
        #expect(ScoreDetailRefreshPolicy.decision(
            briefRows: brief,
            cachedRows: cached,
            detailedUpdatedAt: now.addingTimeInterval(-25 * 60 * 60),
            now: now
        ) == .fetch)
    }

    private func makeBrief(number: String = "MATH-1", score: String) -> ScoreRow {
        ScoreRow(
            index: 0,
            headers: ["序号", "开课学期", "课程编号", "课程名称", "成绩", "学分", "操作栏"],
            values: ["1", "2025-2026-2", number, "高等数学", score, "4", "查看"]
        )
    }

    private func makeDetailed(number: String = "MATH-1", score: String, completion: String) -> ScoreRow {
        ScoreRow(
            index: 0,
            headers: [
                "序号", "开课学期", "课程编号", "课程名称", "成绩", "学分", "操作栏",
                "平均分", "该课程所有教学班成绩录入完毕", "本人成绩在班级中占",
            ],
            values: ["9", "2025-2026-2", number, "高等数学", score, "4", "", "82.5", completion, "10%"]
        )
    }
}

@Suite("Watch and Widget shared runtime contracts")
struct ExternalScheduleInfrastructureTests {
    @Test("Snapshot codec preserves the shared contract")
    func snapshotCodecRoundTrip() throws {
        let snapshot = makeSnapshot()
        let data = try ScheduleExternalSnapshotCodec.encode(snapshot)

        #expect(try ScheduleExternalSnapshotCodec.decode(data) == snapshot)
    }

    @Test("Watch transfer protocol recognizes requests and snapshots")
    func watchTransferProtocol() throws {
        let data = try ScheduleExternalSnapshotCodec.encode(makeSnapshot())
        let context = WatchScheduleTransferProtocol.snapshotContext(data)

        #expect(WatchScheduleTransferProtocol.requestData == Data("request_latest_schedule_snapshot".utf8))
        #expect(WatchScheduleTransferProtocol.requestsLatestSnapshot(WatchScheduleTransferProtocol.requestContext))
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
