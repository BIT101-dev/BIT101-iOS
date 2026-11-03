import BIT101TestSupport
import ClientCore
import Combine
import Foundation
import ScoreDomain
import ScorePorts
import StorageCore
import Testing
import TransportCore
import os

@testable import ScoreFeature
@testable import ScoreInfrastructure

@MainActor
struct ScoreInfrastructureBoundaryTests {
    @Test(.timeLimit(.minutes(1)))
    func transcriptDeadlineRetainsDeliveredPages() async throws {
        var reads: [Int] = []
        var published: [Int] = []
        @MainActor final class State { var hold = true }
        let state = State()
        let report = TrustedTranscriptReport(pageCount: 3, timeout: .seconds(1)) { number, _ in
            reads.append(number)
            if number == 2, state.hold { try await Task.sleep(for: .seconds(60)) }
            return Data([1])
        }
        let partial = try await report.loadPages(
            maximumBytes: 3, onPage: { published += $0.pages.map(\.number) })
        #expect(reads == [1, 2] && published == [1] && !report.isInvalid)
        #expect(
            partial.pages.map(\.number) == [1] && (partial.failure as? URLError)?.code == .timedOut)
        state.hold = false
        let recovered = try await report.loadPages(excluding: [1], maximumBytes: 2)
        #expect(recovered.pages.map(\.number) == [2, 3] && recovered.failure == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func transcriptSourceInvalidationRetains() async throws {
        var reads: [Int] = []
        var published: [Int] = []
        let report = TrustedTranscriptReport(pageCount: 3) { number, _ in
            reads.append(number)
            if number == 2 {
                throw TrustedTranscriptReport.Failure.invalidSource(URLError(.badServerResponse))
            }
            return Data([1])
        }
        let result = try await report.loadPages(
            maximumBytes: 3,
            onPage: { page in
                published.append(contentsOf: page.pages.map(\.number))
            })
        #expect(reads == [1, 2] && published == [1])
        #expect(result.pages.map(\.number) == [1] && result.failure != nil && report.isInvalid)
    }

    @Test(.timeLimit(.minutes(1)))
    func transcriptCancelStopsReport() async throws {
        var pages: [Int] = []
        let report = TrustedTranscriptReport(pageCount: 3) { number, _ in
            pages.append(number)
            if number == 2 {
                throw NSError(
                    domain: "fixture", code: 1,
                    userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)])
            }
            return Data([1])
        }
        await #expect(throws: CancellationError.self) {
            try await report.loadPages(maximumBytes: 3)
        }
        #expect(pages == [1, 2])
    }

    nonisolated struct ValueFiles: AppFileService {
        let base: ModuleScoreFiles
        var temporaryDirectoryURL: URL { base.temporaryDirectoryURL }
        func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? {
            base.directoryURL(directory)
        }
        func appGroupContainerURL(identifier: String) -> URL? {
            base.appGroupContainerURL(identifier: identifier)
        }
        func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
        func readData(at url: URL) throws -> Data { try base.readData(at: url) }
        func readData(at url: URL, maximumBytes: Int) throws -> Data {
            try base.readData(at: url, maximumBytes: maximumBytes)
        }
        func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
            try base.writeData(data, to: url, options: options)
        }
        func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
        func removeItem(at url: URL) throws { try base.removeItem(at: url) }
        func setPrivateFileProtection(at url: URL) throws {
            try base.setPrivateFileProtection(at: url)
        }
        func setBackupExcluded(_ excluded: Bool, at url: URL, recursively: Bool) throws {
            try base.setBackupExcluded(excluded, at: url, recursively: recursively)
        }
        func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions)
            throws -> [URL]
        { try base.contentsOfDirectory(at: url, options: options) }
        func regularFileSize(at url: URL) -> Int? { base.regularFileSize(at: url) }
        func atomicFileIdentity(at url: URL) -> String? { base.atomicFileIdentity(at: url) }
        func isRegularFile(at url: URL) -> Bool { base.isRegularFile(at: url) }
        func modificationDate(at url: URL) -> Date? { base.modificationDate(at: url) }
        func setModificationDate(_ date: Date, at url: URL) throws {
            try base.setModificationDate(date, at: url)
        }
        func removeContents(of directory: URL) -> Bool { base.removeContents(of: directory) }
        func totalRegularFileSize(at directory: URL) -> Int64 {
            base.totalRegularFileSize(at: directory)
        }
    }

    @Test(.timeLimit(.minutes(1))) func valueFileBackendsKeepScoreRepositories() async throws {
        let domain = "BIT101ModulesTests.score-value-backends"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let firstFiles = ModuleScoreFiles()
        let secondFiles = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/score-value-backends")
        let first = ScoreCacheStore(
            files: ValueFiles(base: firstFiles), storageRoot: root, defaults: defaults,
            session: { session })
        let second = ScoreCacheStore(
            files: ValueFiles(base: secondFiles), storageRoot: root, defaults: defaults,
            session: { session })
        let firstRows = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        let secondRows = [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])]
        #expect(await first.save(rows: firstRows) != nil)
        #expect(try await second.loadSnapshot() == nil)
        #expect(await second.save(rows: secondRows) != nil)
        #expect(try await first.loadSnapshot()?.rows == firstRows)
        #expect(try await second.loadSnapshot()?.rows == secondRows)
        #expect(firstFiles.storedData.count == 1 && secondFiles.storedData.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func scoreStoresSerializeWrites() async throws {
        let domain = "BIT101ModulesTests.score-independent-cas"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.01)
        })
        let root = URL(fileURLWithPath: "/score-independent-cas")
        let first = ScoreCacheStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        let second = ScoreCacheStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        let initial = ScoreCacheSyncPayload(
            rows: [], updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        let local = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        let remote = ScoreCacheSyncPayload(
            rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])],
            updatedAt: Date(timeIntervalSince1970: 200), detailedUpdatedAt: nil)
        for _ in 0..<12 {
            #expect(try await first.applySynced(initial))
            async let cloud = first.applySynced(remote, replacing: initial)
            async let saved = second.save(rows: local)
            _ = try await (cloud, saved)
            #expect(try await first.syncPayload()?.rows == local)
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func cancelDuringScoreSnapshot(detail: Bool) async throws {
        let domain = "BIT101ModulesTests.score-committed-write"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let entered = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 10)
        })
        let session = AppStorageSession(accountIdentifier: domain)
        let cache = ScoreCacheStore(
            files: files, storageRoot: URL(fileURLWithPath: "/scores"), defaults: defaults,
            session: { session })
        var saves: [AppStorageSession] = []
        var changes: [AppStorageSession] = []
        let saved = cache.localSaves.sink { saves.append($0) }
        let changed = cache.changes.sink { changes.append($0) }
        defer {
            saved.cancel()
            changed.cancel()
            gate.signal()
        }
        let rows = [ScoreRow(index: 0, headers: ["课程名称"], values: ["已提交成绩"])]
        let task = Task {
            detail ? await cache.saveDetailed(rows: rows) : await cache.save(rows: rows)
        }
        defer { task.cancel() }
        try await waitForTestEvent { entered.withLock { $0 } }
        task.cancel()
        gate.signal()
        #expect(await task.value == nil)
        #expect(try await cache.loadSnapshot()?.rows == rows)
        #expect(saves == [session] && changes == [session])
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledQueuedScoreWritesPreserveSnapshot(detail: Bool) async throws {
        let domain = "BIT101ModulesTests.score-queued-write"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let entered = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 10)
        })
        let session = AppStorageSession(accountIdentifier: domain)
        let cache = ScoreCacheStore(
            files: files, storageRoot: URL(fileURLWithPath: "/scores"), defaults: defaults,
            session: { session })
        var saves = 0
        let observation = cache.localSaves.sink { _ in saves += 1 }
        defer {
            observation.cancel()
            gate.signal()
        }
        let first = Task { await cache.save(rows: []) }
        defer { first.cancel() }
        try await waitForTestEvent { entered.withLock { $0 } }
        var queued = false
        let second = Task {
            queued = true
            let rows = [ScoreRow(index: 0, headers: ["课程名称"], values: ["迟到成绩"])]
            return detail ? await cache.saveDetailed(rows: rows) : await cache.save(rows: rows)
        }
        defer { second.cancel() }
        try await waitForTestEvent { queued }
        second.cancel()
        gate.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult != nil && secondResult == nil)
        let snapshot = try await cache.loadSnapshot()
        #expect(snapshot?.rows?.isEmpty == true && saves == 1)
    }

    @Test(arguments: ["缓考", "", "nan", "inf", "-1", "101"])
    func statisticsExcludeUnavailable(score: String) {
        func row(_ number: String, _ value: String, credit: String = "4") -> ScoreRow {
            ScoreRow(index: 0, headers: ["课程编号", "成绩", "学分"], values: [number, value, credit])
        }
        let summary = ScoreSummary.make(from: [
            row("math", "80"), row("math", score), row("pending", score),
            row("bad-credit", "90", credit: "inf"),
        ])
        #expect(summary.selectedCourseCount == 1 && summary.totalCredit == 4)
        #expect(summary.weightedAverageScore == 80 && summary.weightedAverageGPA == 3.25)
        let unavailable = ScoreSummary.make(from: [row("pending", score)])
        #expect(
            unavailable.selectedCourseCount == 0 && unavailable.weightedAverageScore == nil
                && unavailable.weightedAverageGPA == nil)
        let failed = ScoreSummary.make(from: [row("failed", "不及格")])
        #expect(
            failed.totalCredit == 4 && failed.weightedAverageScore == 0
                && failed.weightedAverageGPA == 0)
    }
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func scoreCacheReadsCheckTheirByteBudget(oversized: Bool) async throws {
        let domain = "BIT101ModulesTests.score-byte-budget"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "score-byte-budget")
        let files = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/score-byte-budget")
        let file = root.appending(path: session.accountStorageIdentifier).appending(
            path: "score-cache.json")
        var data = Data(#"{"rows":[]}"#.utf8)
        data.append(
            Data(
                repeating: 32,
                count: ScoreCacheStore.maximumCacheBytes + (oversized ? 1 : 0) - data.count))
        try files.writeData(data, to: file, options: [])
        let cache = ScoreCacheStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        if oversized {
            await #expect(throws: ScoreCacheReadError.self) { try await cache.loadSnapshot() }
            #expect(files.readCount(at: file) == 0)
            #expect(await cache.save(rows: []) == nil)
            #expect(files.storedData[file] == data)
        } else {
            #expect(try await cache.loadSnapshot()?.rows == [])
            #expect(files.readCount(at: file) == 1)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func scoreLegacyCleanupChecksBudgetWithCache(oversized: Bool) async throws {
        let domain = "BIT101ModulesTests.score-legacy-cleanup-budget"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/score-legacy-cleanup-budget")
        let cache = ScoreCacheStore(
            files: files, storageRoot: root, defaults: defaults, session: { session })
        #expect(await cache.save(rows: []) != nil)
        let legacy = root.appending(path: session.legacyAccountDirectoryNameForMigration).appending(
            path: "score-cache.json")
        let previousReads = files.readCount(at: legacy)
        var data = Data(#"{"rows":[]}"#.utf8)
        data.append(
            Data(
                repeating: 32,
                count: ScoreCacheStore.maximumCacheBytes + (oversized ? 1 : 0) - data.count))
        try files.writeData(data, to: legacy, options: [])
        #expect(await cache.save(rows: []) != nil)
        #expect(files.readCount(at: legacy) - previousReads == (oversized ? 0 : 1))
        #expect(files.storedData[legacy] == (oversized ? data : nil))
        #expect(try await cache.loadSnapshot()?.rows == [])
    }

    @Test(.timeLimit(.minutes(1))) func oversizedScoreWritesPreserveSnapshot() async throws {
        let domain = "BIT101ModulesTests.score-write-budget"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "score-write-budget")
        let cache = ScoreCacheStore(
            files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-write-budget"),
            defaults: defaults, session: { session })
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        #expect(await cache.save(rows: rows) != nil)
        let oversized = [
            ScoreRow(
                index: 0, headers: ["正文"],
                values: [String(repeating: "a", count: ScoreCacheStore.maximumCacheBytes)])
        ]
        #expect(await cache.save(rows: oversized) == nil)
        #expect(try await cache.loadSnapshot()?.rows == rows)
    }
    @Test func serviceFailuresProvidePresentationDetails() {
        let challenge = BITLoginAuthenticationChallenge(
            challengeID: "fixture", accessToken: "token",
            status: "sms_required", maskedPhone: nil, expiresIn: 120)
        for error in [
            ScoreServiceError.missingCredentials, .invalidResponse, .requestTimedOut,
            .secondFactorRequired(challenge),
        ] {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(ScoreServiceError.challengeInvalid("认证上下文已变化").errorDescription == "认证上下文已变化")
        #expect(ScoreServiceError.queryFailed("课程查询失败").errorDescription == "课程查询失败")
        #expect(ScoreServiceError.queryFailed("会话已经过期").schoolServiceFailure == .sessionExpired)
        #expect(ScoreServiceError.challengeInvalid("无权访问该资源").schoolServiceFailure == .accessDenied)
        #expect(ScoreServiceError.invalidResponse.schoolServiceFailure == nil)
        let wrapped = ScoreServiceError.queryFailed("课程查询失败").caused(
            by: URLError(.networkConnectionLost))
        #expect(wrapped.localizedDescription == "课程查询失败")
        #expect(
            (wrapped.userInfo[NSUnderlyingErrorKey] as? URLError)?.code == .networkConnectionLost)
        #expect(ScoreCacheReadError.unavailable.errorDescription?.contains("清理") == true)
        #expect(ScoreCacheWriteError.failed.errorDescription?.contains("原始记录已保留") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func clearingFilesRetainsCleanupBoundary() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "BIT101ModulesTests.score.cleanup-write"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.cleanup-write") }
        let started = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            if started.withLock({ value in
                defer { value = true }
                return !value
            }) {
                #expect(gate.wait(timeout: .now() + 5) == .success)
            }
        })
        let root = URL(fileURLWithPath: "/cleanup-write")
        var account = AppStorageSession(accountIdentifier: "cleanup-account")
        let operations = StorageOperationTracker()
        let cache = ScoreCacheStore(
            files: files, storageRoot: root, defaults: defaults, session: { account },
            storageOperations: operations)
        let owner = account
        let task = Task { await cache.saveDetailed(rows: [], for: owner) }
        try await waitForTestEvent { !(!started.withLock({ $0 })) }
        account = AppStorageSession(accountIdentifier: "")
        var cleanupStarted = false
        let cleanup = Task { @MainActor in
            cleanupStarted = true
            await operations.suspendAndDrain()
            return files.removeContents(of: root)
        }
        try await waitForTestEvent { !(!cleanupStarted) }
        #expect(await cache.saveDetailed(rows: [], for: account) == nil)
        await #expect(throws: ScoreCacheReadError.self) {
            try await cache.applySynced(.init(rows: [], updatedAt: Date(), detailedUpdatedAt: nil))
        }
        gate.signal()
        #expect(await cleanup.value)
        _ = await task.value
        #expect(files.storedData.isEmpty)
        operations.resume()
        #expect(await cache.saveDetailed(rows: [], for: account) != nil)
    }

    final class MutableCredentials: SchoolCredentialsProviding {
        var schoolSessionIdentity = SchoolSessionIdentity(accountIdentifier: "A", generation: 0)
        var currentStudentID: String { schoolSessionIdentity.accountIdentifier }
        var currentPassword: String { "fixture-password" }
    }

    final class SuspendedStages: HTTPTransport {
        let suspendedStage: String
        var repeatsAuthentication = false
        var pending: CheckedContinuation<Void, Never>?
        var requests: [String] = []
        init(_ stage: String) { suspendedStage = stage }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes {
                throw HTTPClientError.responseTooLarge
            }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let stage: String
            let path = url.path
            if path.hasSuffix("/sms") {
                stage = "sms"
            } else if path.hasSuffix("/start") {
                stage = "auth"
            } else if path.hasSuffix("/score") {
                stage = "score"
            } else if path.hasSuffix("/cookies") {
                stage = "cookie"
            } else if path.hasSuffix("/Index") {
                stage = "html"
            } else {
                stage = "image"
            }
            requests.append(stage)
            if repeatsAuthentication && ["score", "cookie"].contains(stage) {
                guard requests.count <= 3 else { throw URLError(.badServerResponse) }
                let bytes = Data(
                    #"""
                    {"detail":{"challenge_id":"fixture","access_token":"token","status":"authe\#
                    nticated","expires_in":120}}
                    """#
                    .utf8)
                return (
                    bytes,
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: 202, httpVersion: nil, headerFields: nil))
                )
            }
            if stage == suspendedStage { await withCheckedContinuation { pending = $0 } }
            let text: String
            switch stage {
            case "auth", "sms":
                text =
                    #"""
                    {"challenge_id":"fixture","access_token":"token","status":"authenticated",\#
                    "expires_in":120}
                    """#
            case "cookie": text = #"{"cookie_str":"SESSION=fixture"}"#
            case "score":
                text = #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],["功能验收","C1","80","2"]]}"#
            case "html": text = #"<img src="/cjd/Temp/1.png"><img src="/cjd/Temp/2.png">"#
            default: text = "fixture-image"
            }
            return (
                Data(text.utf8),
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200,
                        httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["auth", "score", "cookie", "html", "image", "sms"])
    func eachScoreAndRejectsAccountOrChange(stage: String) async throws {
        for next in [
            SchoolSessionIdentity(accountIdentifier: "B", generation: 1),
            SchoolSessionIdentity(accountIdentifier: "A", generation: 2),
        ] {
            let credentials = MutableCredentials()
            let transport = SuspendedStages(stage)
            let client = HTTPClient(transport: transport, observer: nil)
            let service = ScoreService(
                credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
                endpointBaseURL: AppURL.required("https://example.invalid"))
            let challenge = BITLoginAuthenticationChallenge(
                challengeID: "fixture", accessToken: "token",
                status: "authenticated", maskedPhone: nil, expiresIn: 120,
                ownerIdentity: credentials.schoolSessionIdentity)
            let task = Task<Void, Error> {
                switch stage {
                case "auth": _ = try await service.startScoreChallenge()
                case "score":
                    _ = try await service.fetchScores(detail: false, authenticatedBy: challenge)
                case "sms": _ = try await service.submitScoreCode("123456", for: challenge)
                default: _ = try await service.fetchTrustedPages()
                }
            }
            try await waitForTestEvent { !(transport.pending == nil) }
            let count = transport.requests.count
            credentials.schoolSessionIdentity = next
            transport.pending?.resume()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(transport.requests.count == count)
            await #expect(throws: CancellationError.self) {
                try await service.fetchScores(detail: true, authenticatedBy: challenge)
            }
            #expect(transport.requests.count == count)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["score", "transcript"])
    func repeatedBusinessAuthEndsWithFailure(mode: String) async throws {
        let credentials = MutableCredentials()
        let transport = SuspendedStages("none")
        transport.repeatsAuthentication = true
        let client = HTTPClient(transport: transport, observer: nil)
        let service = ScoreService(
            credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"))
        let challenge = BITLoginAuthenticationChallenge(
            challengeID: "fixture", accessToken: "token", status: "authenticated",
            maskedPhone: nil, expiresIn: 120, ownerIdentity: credentials.schoolSessionIdentity)
        do {
            if mode == "score" {
                _ = try await service.fetchScores(detail: false, authenticatedBy: challenge)
            } else {
                _ = try await service.fetchTrustedPages()
            }
            Issue.record("Repeated authentication should end with a fresh-operation instruction")
        } catch ScoreServiceError.challengeInvalid(let message) {
            #expect(message.contains("再次要求认证"))
        }
        #expect(transport.requests == (mode == "score" ? ["score"] : ["cookie", "cookie"]))
    }

    @Test(.timeLimit(.minutes(1))) func newScoreChallengesIdentity() async throws {
        let credentials = MutableCredentials()
        let client = HTTPClient(transport: SuspendedStages("none"), observer: nil)
        let service = ScoreService(
            credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"))
        let challenge = try await service.startScoreChallenge()
        #expect(challenge.ownerIdentity == credentials.schoolSessionIdentity)
    }

    struct Credentials: SchoolCredentialsProviding {
        var schoolSessionIdentity: SchoolSessionIdentity {
            .init(accountIdentifier: currentStudentID, generation: 0)
        }
        let currentStudentID = "fixture-account"
        let currentPassword = "fixture-password"
    }

    final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes {
                throw HTTPClientError.responseTooLarge
            }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            throw URLError(.timedOut)
        }
    }

    final class TranscriptPages: HTTPTransport {
        let pageBytes: Int
        var imageRequests = 0
        var pageCount = 2
        var failingPage: String?
        var rejectedPageStatus: Int?
        var paths: [String] = []
        var responseURL: (URL) -> URL = { $0 }
        init(pageBytes: Int) { self.pageBytes = pageBytes }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes {
                throw HTTPClientError.responseTooLarge
            }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            paths.append(url.path)
            if url.path == failingPage {
                if let rejectedPageStatus {
                    return (
                        Data(),
                        try #require(
                            HTTPURLResponse(
                                url: url, statusCode: rejectedPageStatus, httpVersion: nil,
                                headerFields: nil))
                    )
                }
                throw URLError(.networkConnectionLost)
            }
            let data: Data
            if url.path.hasSuffix("/cookies") {
                data = Data(#"{"cookie_str":"SESSION=fixture"}"#.utf8)
            } else if url.path.hasSuffix("/Index") {
                data = Data(
                    (1...pageCount).map { "<img src=\"/cjd/Temp/\($0).png\">" }.joined().utf8)
            } else if url.path.contains("/cjd/Temp/") {
                imageRequests += 1
                data = Data(count: pageBytes)
            } else {
                data = Data(
                    #"""
                    {"challenge_id":"fixture","access_token":"token","status":"authenticated",\#
                    "expires_in":120}
                    """#
                    .utf8)
            }
            return (
                data,
                try #require(
                    HTTPURLResponse(
                        url: responseURL(url), statusCode: 200, httpVersion: nil, headerFields: nil)
                )
            )
        }
    }

    @Test(.timeLimit(.minutes(1))) func transcriptAuthCompletes() async throws {
        let transport = TranscriptPages(pageBytes: 64)
        transport.failingPage = "/cjd/Temp/2.png"
        transport.pageCount = 3
        let client = HTTPClient(transport: transport, observer: nil)
        let service = ScoreService(
            credentials: Credentials(), httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"))
        let challenge = BITLoginAuthenticationChallenge(
            challengeID: "fixture", accessToken: "token", status: "waiting_sms",
            maskedPhone: nil, expiresIn: 120, ownerIdentity: Credentials().schoolSessionIdentity)
        let authenticated = try await service.submitTranscriptCode("123456", for: challenge)
        #expect(
            authenticated.status == "authenticated" && transport.paths == ["/api/auth/fixture/sms"])
        var delivered: [Int] = []
        let partial = try await service.fetchTrustedPages(
            authenticatedBy: authenticated,
            onPage: { page in
                delivered.append(contentsOf: page.pages.map(\.number))
            })
        #expect(delivered == [1, 3])
        #expect(
            partial.pages.map(\.number) == [1, 3] && partial.expectedPageCount == 3
                && partial.failure != nil)
        #expect(transport.paths.contains("/cjd/Temp/3.png"))
        transport.failingPage = nil
        let report = try #require(partial.report)
        let recovered = try await report.loadPages(
            excluding: Set(partial.pages.map(\.number)), maximumBytes: 64)
        #expect(recovered.pages.map(\.number) == [2] && recovered.failure == nil)
        #expect(transport.paths.filter { $0.hasSuffix("/cookies") }.count == 1)
        #expect(transport.paths.filter { $0.hasSuffix("/sms") }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [401, 403, 404, 410])
    func expiredTranscriptSourceStopsDownloads(status: Int) async throws {
        let transport = TranscriptPages(pageBytes: 64)
        transport.pageCount = 3
        transport.failingPage = "/cjd/Temp/2.png"
        transport.rejectedPageStatus = status
        let client = HTTPClient(transport: transport, observer: nil)
        let service = ScoreService(
            credentials: Credentials(), httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"))
        let partial = try await service.fetchTrustedPages()
        #expect(partial.pages.map(\.number) == [1] && partial.report?.isInvalid == true)
        #expect(!transport.paths.contains("/cjd/Temp/3.png") && partial.failure != nil)
    }

    @Test func scoreDecodingRetainsTheMissingFieldPath() {
        do {
            _ = try ScoreService.decodeScoreRows(Data(#"{"msg":"查询成功","data":7}"#.utf8))
            Issue.record("Expected malformed score payload")
        } catch {
            #expect(
                error.localizedDescription == ScoreServiceError.invalidResponse.localizedDescription
            )
            guard
                case DecodingError.typeMismatch(_, let context)? = (error as NSError).userInfo[
                    NSUnderlyingErrorKey] as? DecodingError
            else {
                Issue.record("Expected retained decoding error")
                return
            }
            #expect(context.codingPath.map(\.stringValue) == ["data"])
        }
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: ["report", "image"],
        ["host", "scheme", "port", "path", "https443"])
    func transcriptDownloadsValidateFinalOrigin(stage: String, destination: String) async throws {
        let transport = TranscriptPages(pageBytes: 64)
        transport.responseURL = { url in
            guard
                stage == "report" ? url.path.hasSuffix("/Index") : url.path.hasPrefix("/cjd/Temp/")
            else { return url }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                Issue.record("Transcript fixture URL components unavailable")
                return url
            }
            switch destination {
            case "host": components.host = "outside.example"
            case "scheme": components.scheme = "http"
            case "port": components.port = 8443
            case "path": components.path = "/unrelated/resource"
            default: components.port = 443
            }
            guard let redirected = components.url else {
                Issue.record("Transcript redirect fixture URL unavailable")
                return url
            }
            return redirected
        }
        let client = HTTPClient(transport: UncachedHTTPTransport(base: transport), observer: nil)
        let service = ScoreService(
            credentials: Credentials(), httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"))
        if destination == "https443" {
            #expect(try await service.fetchTrustedPages().pages.count == 2)
        } else {
            var rejected = false
            do {
                _ = try await service.fetchTrustedPages()
            } catch ScoreServiceError.invalidResponse { rejected = true }
            #expect(rejected)
            #expect(transport.imageRequests == (stage == "report" ? 0 : 1))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["pages", "single-page", "aggregate", "exact"])
    func transcriptDownloadsStayWithinTheirPage(scenario: String) async throws {
        let transport = TranscriptPages(pageBytes: scenario == "single-page" ? 129 : 64)
        let limits = TrustedTranscriptResourceLimits(
            maximumPageCount: scenario == "pages" ? 1 : 2,
            maximumEncodedBytes: scenario == "aggregate" ? 127 : 128)
        let client = HTTPClient(transport: UncachedHTTPTransport(base: transport), observer: nil)
        let service = ScoreService(
            credentials: Credentials(), httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"), transcriptLimits: limits)
        if scenario == "exact" {
            let pages = try await service.fetchTrustedPages()
            #expect(pages.pages.count == 2 && pages.pages.reduce(0, { $0 + $1.data.count }) == 128)
        } else if scenario == "aggregate" {
            let partial = try await service.fetchTrustedPages()
            #expect(
                partial.pages.count == 1 && partial.pages[0].data.count == 64
                    && partial.failure is HTTPClientError)
        } else {
            await #expect(throws: HTTPClientError.self) { try await service.fetchTrustedPages() }
        }
        #expect(transport.imageRequests == (scenario == "pages" ? 0 : 2))
    }

    @Test(.timeLimit(.minutes(1))) func productionServiceUsesInjectedEndpoint() async throws {
        let authentication = Transport()
        let downloads = Transport()
        let service = ScoreService(
            credentials: Credentials(),
            httpClient: HTTPClient(transport: authentication, observer: nil),
            sensitiveHTTPClient: HTTPClient(transport: downloads, observer: nil),
            endpointBaseURL: AppURL.required("https://example.invalid"))
        do {
            _ = try await service.startScoreChallenge()
            Issue.record("Expected authentication timeout")
        } catch {
            #expect(
                error.localizedDescription == ScoreServiceError.requestTimedOut.localizedDescription
            )
            #expect(
                ((error as NSError).userInfo[NSUnderlyingErrorKey] as? URLError)?.code == .timedOut)
        }
        let request = try #require(authentication.requests.first)
        #expect(request.url?.absoluteString == "https://example.invalid/api/auth/start")
        let payload =
            try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(payload?["username"] as? String == "fixture-account")
        #expect(payload?["password"] as? String == "fixture-password")
        #expect(authentication.requests.count == 1)
        #expect(downloads.requests.isEmpty)
    }

}

@MainActor
struct ScorePublicContractTests {

    final class Cache: ScoreCaching {
        func recover(rows: [ScoreRow], for session: AppStorageSession) async -> Date? { nil }
        let changeSubject = PassthroughSubject<AppStorageSession, Never>()
        var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
        var loads = 0
        var rows: [ScoreRow] = []
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? {
            loads += 1
            return ScoreCacheSnapshot(rows: rows)
        }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func waitForLoad() async throws {
            try await waitForTestEvent { loads > 0 }
        }
    }
    final class Preferences: ScoreFilterPreferencesStoring {
        func reset() {}
        let changeSubject = PassthroughSubject<AppStorageSession, Never>()
        var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
        var loads = 0
        var hasUnreadableSnapshot: Bool { false }
        func load() -> ScoreFilterPreferenceSnapshot? {
            loads += 1
            return .init()
        }
        func save(
            selectedTerms: Set<String>, selectedCourseTypes: Set<String>, sortIndex: ScoreSortIndex,
            sortOrder: ScoreSortOrder
        ) -> Bool { true }
    }
    struct Service: ScoreListServicing {
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            throw URLError(.notConnectedToInternet)
        }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge)
            async throws -> [ScoreRow]
        { [] }
        func submitScoreCode(_ code: String, for challenge: BITLoginAuthenticationChallenge)
            async throws -> BITLoginAuthenticationChallenge
        { challenge }
    }

    final class Account {
        var session = AppStorageSession(accountIdentifier: "damaged-filter")
    }

}
