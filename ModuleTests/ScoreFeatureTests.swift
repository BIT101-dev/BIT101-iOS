import TransportCore
import CommunityCore
import DesignSystemKit
import ClientCore
import StorageCore
import Foundation
import Testing
@testable import ScoreFeature

@MainActor
@Suite(.serialized)
struct ScoreFeatureTests {
    private func clearPreferences() {
        UserDefaults(suiteName: "BIT101ModulesTests.score")?.removePersistentDomain(forName: "BIT101ModulesTests.score")
    }

    private func makeViewModel(
        service: any ScoreListServicing,
        session: @escaping @MainActor () -> AppStorageSession = { AppStorageSession(accountIdentifier: "module-score") }
    ) -> (ScoreViewModel, ScoreCacheStore) {
        clearPreferences()
        let defaults = UserDefaults(suiteName: "BIT101ModulesTests.score")!
        let notifications = NotificationCenter()
        let cache = ScoreCacheStore(
            files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/module-score"), defaults: defaults,
            session: session, notificationCenter: notifications
        )
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: session, notificationCenter: notifications)
        let viewModel = ScoreViewModel(
            service: service, cacheStore: cache, preferenceStore: preferences, currentScoreCacheSession: session,
            scheduleCoursesDidChange: Notification.Name("moduleScoreCoursesChanged"), loadScheduleCourses: { _ in [:] },
            notificationCenter: notifications
        )
        return (viewModel, cache)
    }

    private final class ScoreServiceSpy: ScoreListServicing {
        private(set) var requestedDetailValues: [Bool] = []
        private let requiresSMS: Bool
        private let detailedRowsOverride: [ScoreRow]?

        init(requiresSMS: Bool = false, detailedRows: [ScoreRow]? = nil) {
            self.requiresSMS = requiresSMS
            detailedRowsOverride = detailedRows
        }

        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            if requiresSMS {
                throw ScoreServiceError.secondFactorRequired(BITLoginAuthenticationChallenge(
                    challengeID: "challenge-1",
                    accessToken: "token-1",
                    status: "waiting_sms",
                    maskedPhone: "138****0000",
                    expiresIn: 300
                ))
            }
            return authenticatedChallenge
        }

        func fetchScores(
            detail: Bool,
            authenticatedBy challenge: BITLoginAuthenticationChallenge
        ) async throws -> [ScoreRow] {
            requestedDetailValues.append(detail)
            return detail ? detailedRows : briefRows
        }

        func submitScoreSMSCode(
            _ code: String,
            for challenge: BITLoginAuthenticationChallenge
        ) async throws -> BITLoginAuthenticationChallenge {
            authenticatedChallenge
        }

        private var authenticatedChallenge: BITLoginAuthenticationChallenge {
            BITLoginAuthenticationChallenge(
                challengeID: "challenge-1",
                accessToken: "token-1",
                status: "authenticated",
                maskedPhone: nil,
                expiresIn: 1_800
            )
        }

        private var briefRows: [ScoreRow] {
            [ScoreRow(
                index: 0,
                headers: ["课程编号", "课程名称", "成绩", "学分", "开课学期", "课程性质"],
                values: ["MATH-1", "高等数学", "90", "4", "2025-2026-1", "必修"]
            )]
        }

        private var detailedRows: [ScoreRow] {
            detailedRowsOverride ?? [ScoreRow(
                index: 0,
                headers: ["课程编号", "课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"],
                values: ["MATH-1", "高等数学", "90", "82.5", "4", "2025-2026-1", "必修"]
            )]
        }
    }

    @MainActor
    private final class ScoreCacheSessionHolder {
        var session: AppStorageSession

        init(session: AppStorageSession) {
            self.session = session
        }
    }

    @MainActor
    private final class DelayedScoreServiceSpy: ScoreListServicing {
        private var challengeContinuation: CheckedContinuation<BITLoginAuthenticationChallenge, Error>?
        private var startContinuation: CheckedContinuation<Void, Never>?
        private var hasStarted = false
        private(set) var fetchCount = 0

        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            hasStarted = true
            startContinuation?.resume()
            startContinuation = nil
            return try await withCheckedThrowingContinuation { continuation in
                challengeContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }

        func completeStart(with challenge: BITLoginAuthenticationChallenge) {
            challengeContinuation?.resume(returning: challenge)
            challengeContinuation = nil
        }

        func fetchScores(
            detail: Bool,
            authenticatedBy challenge: BITLoginAuthenticationChallenge
        ) async throws -> [ScoreRow] {
            fetchCount += 1
            return []
        }

        func submitScoreSMSCode(
            _ code: String,
            for challenge: BITLoginAuthenticationChallenge
        ) async throws -> BITLoginAuthenticationChallenge {
            challenge
        }
    }

    @Test("Score refresh requests fields required by the detail UI")
    @MainActor
    func scoreRefreshRequestsDetailedRows() async {
        let service = ScoreServiceSpy()
        let (viewModel, _) = makeViewModel(service: service)
        defer { clearPreferences() }

        await viewModel.refresh()

        #expect(service.requestedDetailValues == [false, true])
        #expect(viewModel.rows.first?.averageScore == "82.5")
    }

    @Test("Score refresh preserves detailed mode after SMS authentication")
    @MainActor
    func scoreSMSRefreshRequestsDetailedRows() async {
        let service = ScoreServiceSpy(requiresSMS: true)
        let (viewModel, _) = makeViewModel(service: service)
        defer { clearPreferences() }

        await viewModel.refresh()
        await viewModel.submitSMSCode("123456")

        #expect(service.requestedDetailValues == [false, true])
        #expect(viewModel.rows.first?.averageScore == "82.5")
    }

    @Test("A delayed score challenge cannot write into the newly selected account")
    @MainActor
    func delayedScoreChallengeIsDiscardedAfterAccountSwitch() async {
        let activeSession = ScoreCacheSessionHolder(
            session: AppStorageSession(accountIdentifier: "score-account-a")
        )
        let service = DelayedScoreServiceSpy()
        let (viewModel, _) = makeViewModel(service: service, session: { activeSession.session })
        defer { clearPreferences() }

        let refreshTask = Task { await viewModel.refresh() }
        await service.waitUntilStarted()

        activeSession.session = AppStorageSession(accountIdentifier: "score-account-b")
        viewModel.resetForCurrentAccount()
        service.completeStart(with: BITLoginAuthenticationChallenge(
            challengeID: "account-a-challenge",
            accessToken: "account-a-token",
            status: "authenticated",
            maskedPhone: nil,
            expiresIn: 300
        ))
        await refreshTask.value

        let fetchCount = service.fetchCount
        #expect(fetchCount == 0)
        #expect(viewModel.rows.isEmpty)
        #expect(viewModel.smsChallenge == nil)
        #expect(!viewModel.isSyncing)
    }

    @Test("Unchanged score refresh presents the latest-state notice")
    @MainActor
    func unchangedScoreRefreshPresentsNotice() async {
        let rows = [ScoreRow(
            index: 0,
            headers: ["课程编号", "课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"],
            values: ["MATH-1", "高等数学", "90", "82.5", "4", "2025-2026-1", "必修"]
        )]
        let service = ScoreServiceSpy(detailedRows: rows)
        let (viewModel, cache) = makeViewModel(service: service)
        await cache.saveDetailed(rows: rows)
        defer { clearPreferences() }
        await viewModel.refresh()

        #expect(viewModel.alert?.title == "成绩已是最新")
        #expect(viewModel.alert?.message == "本次获取结果与本地成绩完全一致。")
        await cache.save(rows: [])
    }

    @Test("Qualitative scores use their numeric ordering")
    func qualitativeScoresUseNumericOrdering() {
        let excellent = makeRow(index: 0, score: "优秀")
        let pass = makeRow(index: 1, score: "及格")

        #expect(ScoreSortIndex.score.compare(excellent, pass) == .orderedDescending)
        #expect(!ScoreSortIndex.score.isMissingValue(in: excellent))
    }

    @Test("Missing values are identified independently from sort direction")
    func missingValuesAreIdentified() {
        let missing = makeRow(index: 0, score: "")
        #expect(ScoreSortIndex.score.isMissingValue(in: missing))
        #expect(ScoreSortOrder.ascending.toggled == .descending)
    }

    private func makeRow(index: Int, score: String) -> ScoreRow {
        ScoreRow(
            index: index,
            headers: ["课程编号", "课程名称", "成绩", "学分"],
            values: ["MATH-\(index)", "高等数学", score, "4"]
        )
    }
}


nonisolated final class ModuleScoreFiles: AppFileService, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [URL: Data] = [:]
    private var dates: [URL: Date] = [:]
    private var directories: Set<URL> = []
    private var failsWriting = false
    private var failsRemoval = false
    private var options: [URL: Data.WritingOptions] = [:]
    func setFailures(writing: Bool = false, removal: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        failsWriting = writing
        failsRemoval = removal
    }
    func writingOptions(at url: URL) -> Data.WritingOptions? {
        lock.lock(); defer { lock.unlock() }
        return options[url]
    }
    var temporaryDirectoryURL: URL { URL(fileURLWithPath: "/module-score") }
    func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? { temporaryDirectoryURL }
    func appGroupContainerURL(identifier: String) -> URL? { temporaryDirectoryURL }
    func fileExists(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return data[url] != nil || directories.contains(url)
    }
    func readData(at url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = data[url] else { throw CocoaError(.fileReadNoSuchFile) }
        return value
    }
    func writeData(_ value: Data, to url: URL, options: Data.WritingOptions) throws {
        lock.lock(); defer { lock.unlock() }
        if failsWriting { throw CocoaError(.fileWriteNoPermission) }
        data[url] = value
        dates[url] = Date()
        self.options[url] = options
    }
    func createDirectory(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        directories.insert(url)
    }
    func removeItem(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if failsRemoval { throw CocoaError(.fileWriteNoPermission) }
        data.removeValue(forKey: url)
        dates.removeValue(forKey: url)
        directories.remove(url)
    }
    func setPrivateFileProtection(at url: URL) throws {}
    func setExcludedFromBackup(at url: URL) throws {}
    func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(data.keys).union(directories)).filter { $0.deletingLastPathComponent() == url }
    }
    func regularFileSize(at url: URL) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return data[url]?.count
    }
    func isRegularFile(at url: URL) -> Bool { regularFileSize(at: url) != nil }
    func modificationDate(at url: URL) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return dates[url]
    }
    func setModificationDate(_ date: Date, at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        dates[url] = date
    }
    func removeContents(of directory: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let prefix = directory.path + "/"
        data = data.filter { !$0.key.path.hasPrefix(prefix) }
        dates = dates.filter { !$0.key.path.hasPrefix(prefix) }
        directories = Set(directories.filter { !$0.path.hasPrefix(prefix) })
        return true
    }
    func totalRegularFileSize(at directory: URL) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return data.filter { $0.key.path.hasPrefix(directory.path + "/") }.values.reduce(0) { $0 + Int64($1.count) }
    }
}
