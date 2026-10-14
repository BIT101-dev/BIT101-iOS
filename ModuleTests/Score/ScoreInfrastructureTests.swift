import BIT101TestSupport
import Combine
import StorageCore
import ScoreDomain
import ScorePorts
import ClientCore
import Foundation
@testable import ScoreFeature
@testable import ScoreInfrastructure
import Testing
import TransportCore
import os

@MainActor
struct ScoreInfrastructureBoundaryTests {
    private nonisolated struct ValueFiles: AppFileService {
        let base: ModuleScoreFiles
        var temporaryDirectoryURL: URL { base.temporaryDirectoryURL }
        func directoryURL(_ directory: FileManager.SearchPathDirectory) -> URL? { base.directoryURL(directory) }
        func appGroupContainerURL(identifier: String) -> URL? { base.appGroupContainerURL(identifier: identifier) }
        func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
        func readData(at url: URL) throws -> Data { try base.readData(at: url) }
        func readData(at url: URL, maximumBytes: Int) throws -> Data { try base.readData(at: url, maximumBytes: maximumBytes) }
        func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try base.writeData(data, to: url, options: options) }
        func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }
        func removeItem(at url: URL) throws { try base.removeItem(at: url) }
        func setPrivateFileProtection(at url: URL) throws { try base.setPrivateFileProtection(at: url) }
        func setBackupExcluded(_ excluded: Bool, at url: URL, recursively: Bool) throws { try base.setBackupExcluded(excluded, at: url, recursively: recursively) }
        func contentsOfDirectory(at url: URL, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] { try base.contentsOfDirectory(at: url, options: options) }
        func regularFileSize(at url: URL) -> Int? { base.regularFileSize(at: url) }
        func atomicFileIdentity(at url: URL) -> String? { base.atomicFileIdentity(at: url) }
        func isRegularFile(at url: URL) -> Bool { base.isRegularFile(at: url) }
        func modificationDate(at url: URL) -> Date? { base.modificationDate(at: url) }
        func setModificationDate(_ date: Date, at url: URL) throws { try base.setModificationDate(date, at: url) }
        func removeContents(of directory: URL) -> Bool { base.removeContents(of: directory) }
        func totalRegularFileSize(at directory: URL) -> Int64 { base.totalRegularFileSize(at: directory) }
    }

    @Test(.timeLimit(.minutes(1))) func valueFileBackendsKeepIndependentScoreRepositories() async throws {
        let domain = "BIT101ModulesTests.score-value-backends"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let firstFiles = ModuleScoreFiles(), secondFiles = ModuleScoreFiles()
        let root = URL(fileURLWithPath: "/score-value-backends")
        let first = ScoreCacheStore(files: ValueFiles(base: firstFiles), storageRoot: root, defaults: defaults, session: { session })
        let second = ScoreCacheStore(files: ValueFiles(base: secondFiles), storageRoot: root, defaults: defaults, session: { session })
        let firstRows = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        let secondRows = [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])]
        #expect(await first.save(rows: firstRows) != nil)
        #expect(try await second.loadSnapshot() == nil)
        #expect(await second.save(rows: secondRows) != nil)
        #expect(await first.loadRows() == firstRows)
        #expect(await second.loadRows() == secondRows)
        #expect(firstFiles.storedData.count == 1 && secondFiles.storedData.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func independentScoreStoresSerializeCloudComparisonWithLocalWrites() async throws {
        let domain = "BIT101ModulesTests.score-independent-cas"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.01)
        })
        let root = URL(fileURLWithPath: "/score-independent-cas")
        let first = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session })
        let second = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session })
        let initial = ScoreCacheSyncPayload(rows: [], updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        let local = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        let remote = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])],
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
    func cancellationDuringScoreCommitPublishesTheSavedSnapshot(detail: Bool) async throws {
        let domain = "BIT101ModulesTests.score-committed-write"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let entered = OSAllocatedUnfairLock(initialState: false), gate = DispatchSemaphore(value: 0)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 10)
        })
        let session = AppStorageSession(accountIdentifier: domain)
        let cache = ScoreCacheStore(files: files, storageRoot: URL(fileURLWithPath: "/scores"), defaults: defaults, session: { session })
        var saves: [AppStorageSession] = [], changes: [AppStorageSession] = []
        let saved = cache.localSaves.sink { saves.append($0) }, changed = cache.changes.sink { changes.append($0) }
        defer { saved.cancel(); changed.cancel(); gate.signal() }
        let rows = [ScoreRow(index: 0, headers: ["课程名称"], values: ["已提交成绩"])]
        let task = Task { detail ? await cache.saveDetailed(rows: rows) : await cache.save(rows: rows) }
        defer { task.cancel() }
        try await waitForTestEvent { entered.withLock { $0 } }
        task.cancel(); gate.signal()
        #expect(await task.value == nil)
        #expect(await cache.loadRows() == rows)
        #expect(saves == [session] && changes == [session])
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledQueuedScoreWritesPreserveTheCommittedSnapshot(detail: Bool) async throws {
        let domain = "BIT101ModulesTests.score-queued-write"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let entered = OSAllocatedUnfairLock(initialState: false), gate = DispatchSemaphore(value: 0)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            entered.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 10)
        })
        let session = AppStorageSession(accountIdentifier: domain)
        let cache = ScoreCacheStore(files: files, storageRoot: URL(fileURLWithPath: "/scores"), defaults: defaults, session: { session })
        var saves = 0
        let observation = cache.localSaves.sink { _ in saves += 1 }
        defer { observation.cancel(); gate.signal() }
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
        second.cancel(); gate.signal()
        let firstResult = await first.value, secondResult = await second.value
        #expect(firstResult != nil && secondResult == nil)
        let snapshot = try await cache.loadSnapshot()
        #expect(snapshot?.rows?.isEmpty == true && saves == 1)
    }

    @Test(arguments: ["缓考", "", "nan", "inf", "-1", "101"])
    func statisticsExcludeUnavailableAndInvalidScores(score: String) {
        func row(_ number: String, _ value: String, credit: String = "4") -> ScoreRow {
            ScoreRow(index: 0, headers: ["课程编号", "成绩", "学分"], values: [number, value, credit])
        }
        let summary = ScoreSummary.make(from: [row("math", "80"), row("math", score), row("pending", score), row("bad-credit", "90", credit: "inf")])
        #expect(summary.selectedCourseCount == 1 && summary.totalCredit == 4)
        #expect(summary.weightedAverageScore == 80 && summary.weightedAverageGPA == 3.25)
        let unavailable = ScoreSummary.make(from: [row("pending", score)])
        #expect(unavailable.selectedCourseCount == 0 && unavailable.weightedAverageScore == nil && unavailable.weightedAverageGPA == nil)
        let failed = ScoreSummary.make(from: [row("failed", "不及格")])
        #expect(failed.totalCredit == 4 && failed.weightedAverageScore == 0 && failed.weightedAverageGPA == 0)
    }
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func scoreCacheReadsCheckTheirByteBudgetBeforeLoading(oversized: Bool) async throws {
        let domain = "BIT101ModulesTests.score-byte-budget"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "score-byte-budget")
        let files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/score-byte-budget")
        let file = root.appending(path: session.accountStorageIdentifier).appending(path: "score-cache.json")
        var data = Data(#"{"rows":[]}"#.utf8)
        data.append(Data(repeating: 32, count: ScoreCacheStore.maximumCacheBytes + (oversized ? 1 : 0) - data.count))
        try files.writeData(data, to: file, options: [])
        let cache = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session })
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
    func scoreLegacyCleanupChecksItsBudgetWithAHealthyCurrentCache(oversized: Bool) async throws {
        let domain = "BIT101ModulesTests.score-legacy-cleanup-budget"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: domain)
        let files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/score-legacy-cleanup-budget")
        let cache = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session })
        #expect(await cache.save(rows: []) != nil)
        let legacy = root.appending(path: session.legacyAccountDirectoryNameForMigration).appending(path: "score-cache.json")
        let previousReads = files.readCount(at: legacy)
        var data = Data(#"{"rows":[]}"#.utf8)
        data.append(Data(repeating: 32, count: ScoreCacheStore.maximumCacheBytes + (oversized ? 1 : 0) - data.count))
        try files.writeData(data, to: legacy, options: [])
        #expect(await cache.save(rows: []) != nil)
        #expect(files.readCount(at: legacy) - previousReads == (oversized ? 0 : 1))
        #expect(files.storedData[legacy] == (oversized ? data : nil))
        #expect(await cache.loadRows() == [])
    }

    @Test(.timeLimit(.minutes(1))) func oversizedScoreWritesPreserveThePreviouslyCommittedSnapshot() async throws {
        let domain = "BIT101ModulesTests.score-write-budget"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "score-write-budget")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-write-budget"),
            defaults: defaults, session: { session })
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        #expect(await cache.save(rows: rows) != nil)
        let oversized = [ScoreRow(index: 0, headers: ["正文"], values: [String(repeating: "a", count: ScoreCacheStore.maximumCacheBytes)])]
        #expect(await cache.save(rows: oversized) == nil)
        #expect(await cache.loadRows() == rows)
    }
    @Test func serviceFailuresProvidePresentationDetails() {
        let challenge = BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "token",
            status: "sms_required", maskedPhone: nil, expiresIn: 120)
        for error in [ScoreServiceError.missingCredentials, .invalidResponse, .requestTimedOut, .secondFactorRequired(challenge)] {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(ScoreServiceError.challengeInvalid("认证上下文已变化").errorDescription == "认证上下文已变化")
        #expect(ScoreServiceError.queryFailed("课程查询失败").errorDescription == "课程查询失败")
        #expect(ScoreCacheReadError.unavailable.errorDescription?.contains("清理") == true)
        #expect(ScoreCacheWriteError.failed.errorDescription?.contains("原始记录已保留") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func clearingFilesDuringAnOwnedWriteRetainsTheCleanupBoundary() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score.cleanup-write"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score.cleanup-write") }
        let started = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let files = ModuleScoreFiles(beforeCreatingDirectory: {
            if started.withLock({ value in defer { value = true }; return !value }) { gate.wait() }
        })
        let root = URL(fileURLWithPath: "/cleanup-write")
        var account = AppStorageSession(accountIdentifier: "cleanup-account")
        let operations = StorageOperationTracker()
        let cache = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { account }, storageOperations: operations)
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
        await #expect(throws: ScoreCacheReadError.self) { try await cache.applySynced(.init(rows: [], updatedAt: Date(), detailedUpdatedAt: nil)) }
        gate.signal()
        #expect(await cleanup.value)
        _ = await task.value
        #expect(files.storedData.isEmpty)
        operations.resume()
        #expect(await cache.saveDetailed(rows: [], for: account) != nil)
    }

    private final class MutableCredentials: SchoolCredentialsProviding {
        var schoolSessionIdentity = SchoolSessionIdentity(accountIdentifier: "A", generation: 0)
        var currentStudentID: String { schoolSessionIdentity.accountIdentifier }
        var currentPassword: String { "fixture-password" }
    }

    private final class SuspendedStages: HTTPTransport {
        let suspendedStage: String
        var repeatsAuthentication = false
        var pending: CheckedContinuation<Void, Never>?
        var requests: [String] = []
        init(_ stage: String) { suspendedStage = stage }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let stage = url.path.hasSuffix("/sms") ? "sms" : url.path.hasSuffix("/start") ? "auth"
                : url.path.hasSuffix("/score") ? "score" : url.path.hasSuffix("/cookies") ? "cookie"
                : url.path.hasSuffix("/Index") ? "html" : "image"
            requests.append(stage)
            if repeatsAuthentication && ["score", "cookie"].contains(stage) {
                guard requests.count <= 3 else { throw URLError(.badServerResponse) }
                let bytes = Data(#"{"detail":{"challenge_id":"fixture","access_token":"token","status":"authenticated","expires_in":120}}"#.utf8)
                return (bytes, try #require(HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)))
            }
            if stage == suspendedStage { await withCheckedContinuation { pending = $0 } }
            let text: String
            switch stage {
            case "auth", "sms": text = #"{"challenge_id":"fixture","access_token":"token","status":"authenticated","expires_in":120}"#
            case "cookie": text = #"{"cookie_str":"SESSION=fixture"}"#
            case "score": text = #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],["功能验收","C1","80","2"]]}"#
            case "html": text = #"<img src="/cjd/Temp/1.png"><img src="/cjd/Temp/2.png">"#
            default: text = "fixture-image"
            }
            return (Data(text.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["auth", "score", "cookie", "html", "image", "sms"])
    func eachScoreAndTranscriptStageRejectsAnAccountOrGenerationChange(stage: String) async throws {
        for next in [SchoolSessionIdentity(accountIdentifier: "B", generation: 1),
                     SchoolSessionIdentity(accountIdentifier: "A", generation: 2)] {
            let credentials = MutableCredentials()
            let transport = SuspendedStages(stage)
            let client = HTTPClient(transport: transport, observer: nil)
            let service = ScoreService(credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
                endpointBaseURL: AppURL.required("https://example.invalid"))
            let challenge = BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "token",
                status: "authenticated", maskedPhone: nil, expiresIn: 120,
                ownerIdentity: credentials.schoolSessionIdentity)
            let task = Task<Void, Error> {
                switch stage {
                case "auth": _ = try await service.startScoreChallenge()
                case "score": _ = try await service.fetchScores(detail: false, authenticatedBy: challenge)
                case "sms": _ = try await service.submitScoreSMSCode("123456", for: challenge)
                default: _ = try await service.fetchTrustedTranscriptPages()
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
    func repeatedBusinessAuthenticationEndsWithAnActionableFailure(mode: String) async throws {
        let credentials = MutableCredentials(), transport = SuspendedStages("none")
        transport.repeatsAuthentication = true
        let client = HTTPClient(transport: transport, observer: nil)
        let service = ScoreService(credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"))
        let challenge = BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "token", status: "authenticated",
            maskedPhone: nil, expiresIn: 120, ownerIdentity: credentials.schoolSessionIdentity)
        do {
            if mode == "score" { _ = try await service.fetchScores(detail: false, authenticatedBy: challenge) }
            else { _ = try await service.fetchTrustedTranscriptPages() }
            Issue.record("Repeated authentication should end with a fresh-operation instruction")
        } catch ScoreServiceError.challengeInvalid(let message) { #expect(message.contains("再次要求认证")) }
        #expect(transport.requests == (mode == "score" ? ["score"] : ["cookie", "cookie"]))
    }

    @Test(.timeLimit(.minutes(1))) func newScoreChallengesCarryTheirInitialAccountIdentity() async throws {
        let credentials = MutableCredentials()
        let client = HTTPClient(transport: SuspendedStages("none"), observer: nil)
        let service = ScoreService(credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"))
        let challenge = try await service.startScoreChallenge()
        #expect(challenge.ownerIdentity == credentials.schoolSessionIdentity)
    }

    private struct Credentials: SchoolCredentialsProviding {
        var schoolSessionIdentity: SchoolSessionIdentity { .init(accountIdentifier: currentStudentID, generation: 0) }
        let currentStudentID = "fixture-account"
        let currentPassword = "fixture-password"
    }

    private final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            throw URLError(.timedOut)
        }
    }

    private final class TranscriptPages: HTTPTransport {
        let pageBytes: Int
        var imageRequests = 0
        var responseURL: (URL) -> URL = { $0 }
        init(pageBytes: Int) { self.pageBytes = pageBytes }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let data: Data
            if url.path.hasSuffix("/cookies") { data = Data(#"{"cookie_str":"SESSION=fixture"}"#.utf8) }
            else if url.path.hasSuffix("/Index") { data = Data(#"<img src="/cjd/Temp/1.png"><img src="/cjd/Temp/2.png">"#.utf8) }
            else if url.path.contains("/cjd/Temp/") { imageRequests += 1; data = Data(count: pageBytes) }
            else { data = Data(#"{"challenge_id":"fixture","access_token":"token","status":"authenticated","expires_in":120}"#.utf8) }
            return (data, try #require(HTTPURLResponse(url: responseURL(url), statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["report", "image"], ["host", "scheme", "port", "path", "https443"])
    func transcriptDownloadsValidateTheFinalOriginAndResourcePath(stage: String, destination: String) async throws {
        let transport = TranscriptPages(pageBytes: 64)
        transport.responseURL = { url in
            guard stage == "report" ? url.path.hasSuffix("/Index") : url.path.hasPrefix("/cjd/Temp/") else { return url }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                Issue.record("Transcript fixture URL components unavailable"); return url
            }
            switch destination {
            case "host": components.host = "outside.example"
            case "scheme": components.scheme = "http"
            case "port": components.port = 8443
            case "path": components.path = "/unrelated/resource"
            default: components.port = 443
            }
            guard let redirected = components.url else { Issue.record("Transcript redirect fixture URL unavailable"); return url }
            return redirected
        }
        let client = HTTPClient(transport: UncachedHTTPTransport(base: transport), observer: nil)
        let service = ScoreService(credentials: Credentials(), httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"))
        if destination == "https443" {
            #expect(try await service.fetchTrustedTranscriptPages().count == 2)
        } else {
            var rejected = false
            do {
                _ = try await service.fetchTrustedTranscriptPages()
            } catch ScoreServiceError.invalidResponse { rejected = true }
            #expect(rejected)
            #expect(transport.imageRequests == (stage == "report" ? 0 : 1))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["pages", "single-page", "aggregate", "exact"])
    func transcriptDownloadsStayWithinTheirPageAndByteBudgets(scenario: String) async throws {
        let transport = TranscriptPages(pageBytes: scenario == "single-page" ? 129 : 64)
        let limits = TrustedTranscriptResourceLimits(maximumPageCount: scenario == "pages" ? 1 : 2,
            maximumEncodedBytes: scenario == "aggregate" ? 127 : 128)
        let client = HTTPClient(transport: UncachedHTTPTransport(base: transport), observer: nil)
        let service = ScoreService(credentials: Credentials(), httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://example.invalid"), transcriptLimits: limits)
        if scenario == "exact" {
            let pages = try await service.fetchTrustedTranscriptPages()
            #expect(pages.count == 2 && pages.reduce(0, { $0 + $1.count }) == 128)
        } else {
            await #expect(throws: HTTPClientError.self) { try await service.fetchTrustedTranscriptPages() }
        }
        #expect(transport.imageRequests == (scenario == "pages" ? 0 : scenario == "single-page" ? 1 : 2))
    }

    @Test(.timeLimit(.minutes(1))) func productionServiceUsesInjectedCredentialsEndpointAndTransport() async throws {
        let authentication = Transport()
        let downloads = Transport()
        let service = ScoreService(credentials: Credentials(), httpClient: HTTPClient(transport: authentication, observer: nil), sensitiveHTTPClient: HTTPClient(transport: downloads, observer: nil), endpointBaseURL: AppURL.required("https://example.invalid"))
        await #expect(throws: ScoreServiceError.self) { try await service.startScoreChallenge() }
        let request = try #require(authentication.requests.first)
        #expect(request.url?.absoluteString == "https://example.invalid/api/auth/start")
        let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(payload?["username"] as? String == "fixture-account")
        #expect(payload?["password"] as? String == "fixture-password")
        #expect(authentication.requests.count == 1)
        #expect(downloads.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["score.detail.cache", "score.detail.cache.updated-at", "score.detail.cache.full-updated-at"])
    func partialLegacyCorruptionPreservesEveryFragmentAndPausesSync(prefix: String) async throws {
        for malformedType in [false, true] {
            let domain = "BIT101ModulesTests.score-legacy-corruption.\(prefix).\(malformedType)"
            let defaults = try #require(UserDefaults(suiteName: domain))
            defaults.removePersistentDomain(forName: domain)
            defer { defaults.removePersistentDomain(forName: domain) }
            let session = AppStorageSession(accountIdentifier: "legacy-corruption")
            let files = ModuleScoreFiles()
            let root = URL(fileURLWithPath: "/score-legacy-corruption")
            let cache = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session })
            let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])]
            let encoder = JSONEncoder()
            defaults.set(try encoder.encode(rows), forKey: session.key("score.detail.cache"))
            defaults.set(try encoder.encode(Date()), forKey: session.key("score.detail.cache.updated-at"))
            defaults.set(try encoder.encode(Date()), forKey: session.key("score.detail.cache.full-updated-at"))
            defaults.set(malformedType ? "damaged" as Any : Data("damaged".utf8), forKey: session.key(prefix))
            let retained = defaults.dictionaryRepresentation() as NSDictionary
            await #expect(throws: ScoreCacheReadError.self) { try await cache.loadSnapshot() }
            await #expect(throws: ScoreCacheReadError.self) { try await cache.syncPayload() }
            #expect(await cache.save(rows: rows) == nil)
            await #expect(throws: ScoreCacheReadError.self) { try await cache.applySynced(.init(rows: rows, updatedAt: Date(), detailedUpdatedAt: nil)) }
            #expect(defaults.dictionaryRepresentation() as NSDictionary == retained)
            let file = root.appending(path: session.accountStorageIdentifier).appending(path: "score-cache.json")
            #expect(files.fileExists(at: file) == false)
        }
    }

    @Test(.timeLimit(.minutes(1))) func healthyLegacyMigrationPreservesRowsAndBothTimestamps() async throws {
        let domain = "BIT101ModulesTests.score-legacy-valid"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "legacy-valid")
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["90"])]
        let date = Date(timeIntervalSince1970: 100)
        let encoder = JSONEncoder()
        defaults.set(try encoder.encode(rows), forKey: session.legacyKey("score.detail.cache"))
        defaults.set(try encoder.encode(date), forKey: session.legacyKey("score.detail.cache.updated-at"))
        defaults.set(try encoder.encode(date), forKey: session.legacyKey("score.detail.cache.full-updated-at"))
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/legacy-valid"),
            defaults: defaults, session: { session })
        #expect(try await cache.syncPayload() == .init(rows: rows, updatedAt: date, detailedUpdatedAt: date))
        #expect(defaults.object(forKey: session.legacyKey("score.detail.cache")) == nil)
        #expect(await cache.loadRows() == rows)
    }

    @Test(.timeLimit(.minutes(1))) func cloudApplyComparesTheCompleteLocalSnapshotInsideTheRepository() async throws {
        let session = AppStorageSession(accountIdentifier: "score-cas")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score-cas"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-cas") }
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-cas"),
            defaults: defaults, session: { session })
        let initial = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])],
            updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(try await cache.applySynced(initial))
        let read = try #require(try await cache.syncPayload())
        let newer = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        #expect(await cache.save(rows: newer) != nil)
        let remote = ScoreCacheSyncPayload(rows: initial.rows, updatedAt: Date(timeIntervalSince1970: 200), detailedUpdatedAt: nil)
        #expect(try await cache.applySynced(remote, replacing: read) == false)
        let current = try #require(try await cache.syncPayload())
        #expect(current.rows == newer)
        #expect(try await cache.applySynced(remote, replacing: current))
        #expect(try await cache.syncPayload() == remote)
    }

    @Test(.timeLimit(.minutes(1))) func cloudApplyReportsWriteFailureAndPreservesTheSavedSnapshot() async throws {
        let session = AppStorageSession(accountIdentifier: "score-write-failure")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score-write-failure"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-write-failure") }
        let files = ModuleScoreFiles()
        let cache = ScoreCacheStore(files: files, storageRoot: URL(fileURLWithPath: "/score-write-failure"), defaults: defaults, session: { session })
        let original = ScoreCacheSyncPayload(rows: [], updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(try await cache.applySynced(original))
        let remote = ScoreCacheSyncPayload(rows: [], updatedAt: Date(timeIntervalSince1970: 200), detailedUpdatedAt: nil)
        files.setFailures(writing: true)
        await #expect(throws: ScoreCacheWriteError.self) { try await cache.applySynced(remote, replacing: original) }
        #expect(try await cache.syncPayload() == original)
        files.setFailures()
        #expect(try await cache.applySynced(remote, replacing: original))
        #expect(try await cache.syncPayload() == remote)
        let bytes = files.storedData
        files.setFailures(protection: true)
        await #expect(throws: ScoreCacheReadError.self) { try await cache.syncPayload() }
        await #expect(throws: ScoreCacheReadError.self) { try await cache.applySynced(original) }
        #expect(files.storedData == bytes)
        files.setFailures()
        #expect(try await cache.syncPayload() == remote)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func authoritativeEmptyScoreSnapshotReplacesRowsWhileAnInitialEmptyPayloadPreservesThem(detailed: Bool) async throws {
        let domain = "BIT101ModulesTests.score-empty-sync"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "score-empty-sync")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-empty-sync"),
            defaults: defaults, session: { session })
        let initial = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])],
            updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(try await cache.applySynced(initial))
        #expect(try await cache.applySynced(.init(rows: [], updatedAt: nil, detailedUpdatedAt: nil), replacing: initial) == false)
        #expect(try await cache.syncPayload() == initial)
        let timestamp = Date(timeIntervalSince1970: 200)
        let empty = ScoreCacheSyncPayload(rows: [], updatedAt: detailed ? nil : timestamp,
            detailedUpdatedAt: detailed ? timestamp : nil)
        #expect(try await cache.applySynced(empty, replacing: initial))
        #expect(try await cache.syncPayload() == empty)
        #expect(await cache.loadRows() == [])
    }

    @Test(.timeLimit(.minutes(1))) func scoreDiskFormatPreservesAdditionalFieldsAndClearsReplacedDetailMetadata() async throws {
        let session = AppStorageSession(accountIdentifier: "score-format")
        let files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/score-format")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score-format"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-format") }
        let cache = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session })
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])]
        #expect(await cache.saveDetailed(rows: rows) != nil)
        #expect(try await cache.loadSnapshot()?.detailedUpdatedAt != nil)
        let url = root.appending(path: session.accountStorageIdentifier).appending(path: "score-cache.json")
        var object = try #require(JSONSerialization.jsonObject(with: files.readData(at: url)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        object["additionalField"] = ["nested": [1, 2]]
        try files.writeData(JSONSerialization.data(withJSONObject: object), to: url, options: [])
        #expect(await cache.save(rows: rows) != nil)
        #expect(try await cache.loadSnapshot()?.detailedUpdatedAt == nil)
        #expect(try await cache.syncPayload()?.detailedUpdatedAt == nil)
        let written = try #require(JSONSerialization.jsonObject(with: files.readData(at: url)) as? [String: Any])
        #expect(written["additionalField"] as? NSDictionary == object["additionalField"] as? NSDictionary)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["{}", #"{"rows":[],"schemaVersion":2}"#, #"{"rows":[],"schemaVersion":true}"#,
                      #"{"rows":[],"schemaVersion":null}"#, #"{"rows":[],"schemaVersion":"1"}"#])
    func unsupportedScoreDiskFormatsPreserveTheirBytes(_ json: String) async throws {
        let session = AppStorageSession(accountIdentifier: "score-format-rejected")
        let files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/score-format-rejected")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score-format-rejected"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-format-rejected") }
        let cache = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session })
        let url = root.appending(path: session.accountStorageIdentifier).appending(path: "score-cache.json")
        let bytes = Data(json.utf8)
        try files.writeData(bytes, to: url, options: [])
        await #expect(throws: ScoreCacheReadError.self) { try await cache.loadSnapshot() }
        await #expect(throws: ScoreCacheReadError.self) { try await cache.syncPayload() }
        #expect(await cache.save(rows: []) == nil)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test(arguments: [
        #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],[" ","C1","","2"]]}"#,
        #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],["课程"," ","","2"]]}"#,
        #"{"msg":"查询失败","data":[["课程名称","成绩"],["功能验收","95"]]}"#,
        #"{"msg":"查询成功","data":[["错误"],["未登录"]]}"#,
        #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],["功能验收","C1","95"]]}"#,
        #"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分","成绩"],["功能验收","C1","95","2","95"]]}"#
    ])
    func malformedAndBusinessFailureScoreResponsesThrow(_ response: String) {
        #expect(throws: (any Error).self) { try ScoreService.decodeScoreRows(Data(response.utf8)) }
    }

    @Test func scoreResponseParsingRunsInThePackageHost() throws {
        #expect(try ScoreService.decodeScoreRows(Data(#"{"msg":"查询成功","data":[]}"#.utf8)).isEmpty)
        #expect(try ScoreService.decodeScoreRows(Data(#"{"msg":"查询成功","data":[["课程名称","课程编号","成绩","学分"],["功能验收","C1","95","2"]]}"#.utf8)).first?.courseName == "功能验收")
    }

    @Test(arguments: Array(ScoreRow.requiredHeaderNames).sorted())
    func scoreResponseRequiresTheSharedHeaders(missing: String) throws {
        let headers = ScoreRow.requiredHeaderNames.sorted().filter { $0 != missing }
        let response = try JSONSerialization.data(withJSONObject: ["msg": "查询成功", "data": [headers]])
        #expect(throws: ScoreServiceError.self) { try ScoreService.decodeScoreRows(response) }
    }
}

@MainActor
struct ScorePublicContractTests {
    @Test(arguments: [false, true])
    func filterPreferenceEditsRetainFutureFieldsAndClearKnownOptionalFields(legacy: Bool) throws {
        let domain = "BIT101ModulesTests.score-filter-format"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        var session = AppStorageSession(accountIdentifier: "filter-format")
        let key = session.key("score.filter.preferences")
        let sourceKey = legacy ? session.legacyKey("score.filter.preferences") : key
        defaults.set(Data(#"{"selectedTerms":["old"],"selectedCourseTypes":[],"sortIndex":"score","sortOrder":"descending","futureSetting":{"enabled":true,"values":[1,2]}}"#.utf8), forKey: sourceKey)
        let store = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        #expect(store.load()?.selectedTerms == ["old"])
        #expect(store.save(selectedTerms: ["new"], selectedCourseTypes: [], sortIndex: .score, sortOrder: .ascending))
        store.applySynced(.init())
        let data = try #require(defaults.data(forKey: key))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["sortIndex"] == nil && object["sortOrder"] == nil)
        #expect((object["futureSetting"] as? [String: Any])?["values"] as? [Int] == [1, 2])
        #expect(defaults.object(forKey: session.legacyKey("score.filter.preferences")) == nil)
        session = AppStorageSession(accountIdentifier: "other-filter-format")
        #expect(store.save(selectedTerms: [], selectedCourseTypes: [], sortIndex: .term, sortOrder: .ascending))
        let otherData = try #require(defaults.data(forKey: session.key("score.filter.preferences")))
        let other = try #require(try JSONSerialization.jsonObject(with: otherData) as? [String: Any])
        #expect(other["futureSetting"] == nil)
        session = AppStorageSession(accountIdentifier: "filter-format")
        #expect(store.load()?.sortOrder == nil)
    }

    @Test(arguments: ["99", "true", "null", "\"1\""], [false, true])
    func unsupportedFilterPreferenceFormatsRetainTheirBytes(version: String, legacy: Bool) throws {
        let domain = "BIT101ModulesTests.score-filter-future"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "future-filter")
        let key = legacy ? session.legacyKey("score.filter.preferences") : session.key("score.filter.preferences")
        let source = Data(("{\"schemaVersion\":" + version + ",\"selectedTerms\":[],\"selectedCourseTypes\":[]}").utf8)
        defaults.set(source, forKey: key)
        let store = ScoreFilterPreferenceStore(defaults: defaults, session: { session })
        #expect(store.hasUnreadableSnapshot && store.load() == nil)
        #expect(!store.save(selectedTerms: [], selectedCourseTypes: [], sortIndex: .score, sortOrder: .ascending))
        store.applySynced(.init())
        #expect(defaults.data(forKey: key) == source)
        if legacy { #expect(defaults.object(forKey: session.key("score.filter.preferences")) == nil) }
    }

    @Test(arguments: [#"{}"#, #"{"selectedTerms":[]}"#, #"{"selectedCourseTypes":[]}"#, #"{"selectedTerms":null,"selectedCourseTypes":[]}"#])
    func incompleteFilterPreferencesRetainTheReadFailure(_ source: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ScoreFilterPreferenceSnapshot.self, from: Data(source.utf8)) }
    }

    @Test("Memory backend shares the production file service contract")
    func fileServiceContract() throws {
        let files = ModuleScoreFiles()
        try verifyFileServiceContract(files, root: URL(fileURLWithPath: "/file-service-contract"),
            setRemovalFailure: { files.setFailures(removal: $0) })
    }
    private final class Cache: ScoreCaching {
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
    private final class Preferences: ScoreFilterPreferencesStoring {
        let changeSubject = PassthroughSubject<AppStorageSession, Never>()
        var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
        var loads = 0
        var hasUnreadableSnapshot: Bool { false }
        func load() -> ScoreFilterPreferenceSnapshot? { loads += 1; return .init() }
        func save(selectedTerms: Set<String>, selectedCourseTypes: Set<String>, sortIndex: ScoreSortIndex, sortOrder: ScoreSortOrder) -> Bool { true }
    }
    private struct Service: ScoreListServicing {
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge { throw URLError(.notConnectedToInternet) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { [] }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
    }

    private final class Account {
        var session = AppStorageSession(accountIdentifier: "damaged-filter")
    }

    @Test(.timeLimit(.minutes(1)), .serialized, arguments: [false, true])
    func unreadableFilterPreferencesReachThePageAndRetainTheirOriginalBytes(empty: Bool) async throws {
        let domain = "BIT101ModulesTests.score-filter-corruption"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = Account()
        let key = account.session.key("score.filter.preferences")
        let damaged = Data("damaged".utf8)
        defaults.set(damaged, forKey: key)
        let preferences = ScoreFilterPreferenceStore(defaults: defaults, session: { account.session })
        let cache = Cache()
        cache.rows = empty ? [] : [ScoreRow(index: 0, headers: ["课程名称", "成绩", "开课学期", "课程性质"],
            values: ["fixture", "90", "fixture", "必修"])]
        var changes = 0
        let observation = preferences.changes.sink { _ in changes += 1 }
        defer { observation.cancel() }
        let model = ScoreViewModel(service: Service(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { account.session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in [:] })
        #expect(model.alert?.title == "筛选偏好读取受阻")
        await model.restoreCachedDataIfNeeded()
        model.setSortOrder(.descending)
        #expect(model.alert?.title == "筛选偏好保存受阻")
        #expect(model.sortOrder == .descending && changes == 0)
        #expect(defaults.data(forKey: key) == damaged)
        account.session = AppStorageSession(accountIdentifier: "healthy-filter")
        model.resetForCurrentAccount()
        #expect(model.alert == nil)
        await model.restoreCachedDataIfNeeded()
        model.setSortOrder(.descending)
        #expect(preferences.load()?.sortOrder == (empty ? nil : ScoreSortOrder.descending.rawValue))
        #expect((changes > 0) == !empty && defaults.data(forKey: key) == damaged)
    }

    @Test(.timeLimit(.minutes(1))) func publicAssemblyAcceptsIndependentStoragePortsAndFiltersEventSources() async throws {
        let cache = Cache(), surroundingCache = Cache()
        let preferences = Preferences(), surroundingPreferences = Preferences()
        let session = AppStorageSession(accountIdentifier: "public-score")
        let model = ScoreViewModel(service: Service(), cacheStore: cache, preferenceStore: preferences,
            currentScoreCacheSession: { session }, scheduleCoursesChanges: Empty().eraseToAnyPublisher(),
            loadScheduleCourses: { _ in [:] })
        surroundingPreferences.changeSubject.send(session)
        #expect(preferences.loads == 1)
        preferences.changeSubject.send(AppStorageSession(accountIdentifier: "other"))
        #expect(preferences.loads == 1)
        preferences.changeSubject.send(session)
        #expect(preferences.loads == 2)
        surroundingCache.changeSubject.send(session)
        cache.changeSubject.send(AppStorageSession(accountIdentifier: "other"))
        #expect(cache.loads == 0)
        cache.changeSubject.send(session)
        try await cache.waitForLoad()
        #expect(cache.loads == 1)
        #expect(surroundingCache.loads == 0)
        withExtendedLifetime(model) {}
    }

    @Test func everySortingFieldUsesItsOwnValueAndReportsMissingFields() {
        let headers = ["课程名称", "成绩", "平均分", "学分", "开课学期", "课程性质"]
        let first = ScoreRow(index: 0, headers: headers, values: [" A ", "85", "80", "1", "A", "A"])
        let second = ScoreRow(index: 1, headers: headers, values: ["B", "95", "90", "4", "B", "B"])
        let empty = ScoreRow(index: 2, headers: [], values: [])
        #expect(ScoreSortIndex.allCases.map(\.title) == ["名称", "成绩", "均分", "学分", "学期", "种类"])
        for field in ScoreSortIndex.allCases {
            #expect(field.id == field.rawValue)
            #expect(field.compare(first, second) == .orderedAscending)
            #expect(field.compare(second, first) == .orderedDescending)
            #expect(field.compare(first, first) == .orderedSame)
            #expect(field.isMissingValue(in: first) == false)
            #expect(field.isMissingValue(in: empty))
        }
        #expect(ScoreSortIndex.averageScore.compare(first, empty) == .orderedAscending)
        #expect(ScoreSortIndex.averageScore.compare(empty, first) == .orderedDescending)
        #expect(ScoreSortOrder.ascending.toggled == .descending)
        #expect(ScoreSortOrder.descending.toggled == .ascending)
        #expect(ScoreSortOrder.allCases.map(\.title) == ["升序", "降序"])
        #expect(ScoreSortOrder.ascending.id == "ascending")
    }

    @Test func domainPoliciesRunThroughTheirPublicContracts() {
        func row(_ index: Int, _ score: String, status: String = "是") -> ScoreRow {
            ScoreRow(index: index, headers: ["课程编号", "课程名称", "成绩", "学分", "开课学期", "该课程所有教学班成绩录入完毕"],
                values: ["math", "数学", score, "4", "2026-2027-1", status])
        }
        let low = row(0, "及格"), high = row(1, "优秀")
        let summary = ScoreSummary.make(from: [low, high])
        #expect(summary.selectedCourseCount == 1)
        #expect(summary.totalCredit == 4)
        #expect(summary.weightedAverageScore == 95)
        #expect(ScoreSortIndex.score.compare(high, low) == .orderedDescending)
        #expect(ScoreRowComparison.rowsMatch([high, low], [low, high]))
        #expect(ScoreRowComparison.briefRowsMatchCache([high], cachedRows: [high]))
        #expect(!ScoreRowComparison.rowsMatch([high], [low]))
        #expect(ScoreRowComparison.rowsMatch([], []))
        #expect(!ScoreRowComparison.rowsMatch([high], []))
        let position = ScoreRow(index: 0, headers: ["序号", "操作栏"], values: ["1", "查看"])
        #expect(!ScoreRowComparison.rowsMatch([position], [position]))
        #expect(!ScoreRowComparison.briefRowsMatchCache([], cachedRows: [high]))
        #expect(!ScoreRowComparison.briefRowsMatchCache([position], cachedRows: [position]))
        #expect(!ScoreRowComparison.briefRowsMatchCache([high], cachedRows: [low]))
    }
}
