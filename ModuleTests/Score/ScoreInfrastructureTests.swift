import BIT101TestSupport
import Combine
import StorageCore
import ScoreDomain
import ClientCore
import Foundation
import ScoreFeature
@testable import ScoreInfrastructure
import Testing
import TransportCore
import os

@MainActor
struct ScoreInfrastructureBoundaryTests {
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
        while !started.withLock({ $0 }) { await Task.yield() }
        account = AppStorageSession(accountIdentifier: "")
        var cleanupStarted = false
        let cleanup = Task { @MainActor in
            cleanupStarted = true
            await operations.suspendAndDrain()
            return files.removeContents(of: root)
        }
        while !cleanupStarted { await Task.yield() }
        #expect(await cache.saveDetailed(rows: [], for: account) == nil)
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
        var pending: CheckedContinuation<Void, Never>?
        var requests: [String] = []
        init(_ stage: String) { suspendedStage = stage }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let stage = url.path.hasSuffix("/sms") ? "sms" : url.path.hasSuffix("/start") ? "auth"
                : url.path.hasSuffix("/score") ? "score" : url.path.hasSuffix("/cookies") ? "cookie"
                : url.path.hasSuffix("/Index") ? "html" : "image"
            requests.append(stage)
            if stage == suspendedStage { await withCheckedContinuation { pending = $0 } }
            let text: String
            switch stage {
            case "auth", "sms": text = #"{"challenge_id":"fixture","access_token":"token","status":"authenticated","expires_in":120}"#
            case "cookie": text = #"{"cookie_str":"SESSION=fixture"}"#
            case "score": text = #"{"msg":"查询成功","data":[["课程名称","成绩"],["功能验收","80"]]}"#
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
            while transport.pending == nil { await Task.yield() }
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

    @Test func newScoreChallengesCarryTheirInitialAccountIdentity() async throws {
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
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            throw URLError(.timedOut)
        }
    }

    private final class TranscriptPages: HTTPTransport {
        let pageBytes: Int
        var imageRequests = 0
        init(pageBytes: Int) { self.pageBytes = pageBytes }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let data: Data
            if url.path.hasSuffix("/cookies") { data = Data(#"{"cookie_str":"SESSION=fixture"}"#.utf8) }
            else if url.path.hasSuffix("/Index") { data = Data(#"<img src="/cjd/Temp/1.png"><img src="/cjd/Temp/2.png">"#.utf8) }
            else if url.path.contains("/cjd/Temp/") { imageRequests += 1; data = Data(count: pageBytes) }
            else { data = Data(#"{"challenge_id":"fixture","access_token":"token","status":"authenticated","expires_in":120}"#.utf8) }
            return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(arguments: ["pages", "single-page", "aggregate", "exact"])
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

    @Test func productionServiceUsesInjectedCredentialsEndpointAndTransport() async throws {
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

    @Test(arguments: ["score.detail.cache", "score.detail.cache.updated-at", "score.detail.cache.full-updated-at"])
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
            #expect(await cache.loadSnapshot() == nil)
            #expect(await cache.syncPayload() == nil)
            #expect(await cache.save(rows: rows) == nil)
            #expect(await cache.applySynced(.init(rows: rows, updatedAt: Date(), detailedUpdatedAt: nil)) == false)
            #expect(defaults.dictionaryRepresentation() as NSDictionary == retained)
            let file = root.appending(path: session.accountStorageIdentifier).appending(path: "score-cache.json")
            #expect(files.fileExists(at: file) == false)
        }
    }

    @Test func healthyLegacyMigrationPreservesRowsAndBothTimestamps() async throws {
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
        #expect(await cache.syncPayload() == .init(rows: rows, updatedAt: date, detailedUpdatedAt: date))
        #expect(defaults.object(forKey: session.legacyKey("score.detail.cache")) == nil)
        #expect(await cache.loadRows() == rows)
    }

    @Test func cloudApplyComparesTheCompleteLocalSnapshotInsideTheRepository() async throws {
        let session = AppStorageSession(accountIdentifier: "score-cas")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score-cas"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-cas") }
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-cas"),
            defaults: defaults, session: { session })
        let initial = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])],
            updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(await cache.applySynced(initial))
        let read = try #require(await cache.syncPayload())
        let newer = [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])]
        #expect(await cache.save(rows: newer) != nil)
        let remote = ScoreCacheSyncPayload(rows: initial.rows, updatedAt: Date(timeIntervalSince1970: 200), detailedUpdatedAt: nil)
        #expect(await cache.applySynced(remote, replacing: read) == false)
        let current = try #require(await cache.syncPayload())
        #expect(current.rows == newer)
        #expect(await cache.applySynced(remote, replacing: current))
        #expect(await cache.syncPayload() == remote)
    }

    @Test(arguments: [false, true])
    func authoritativeEmptyScoreSnapshotReplacesRowsWhileAnInitialEmptyPayloadPreservesThem(detailed: Bool) async throws {
        let domain = "BIT101ModulesTests.score-empty-sync"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "score-empty-sync")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-empty-sync"),
            defaults: defaults, session: { session })
        let initial = ScoreCacheSyncPayload(rows: [ScoreRow(index: 0, headers: ["成绩"], values: ["95"])],
            updatedAt: Date(timeIntervalSince1970: 100), detailedUpdatedAt: nil)
        #expect(await cache.applySynced(initial))
        #expect(await cache.applySynced(.init(rows: [], updatedAt: nil, detailedUpdatedAt: nil), replacing: initial) == false)
        #expect(await cache.syncPayload() == initial)
        let timestamp = Date(timeIntervalSince1970: 200)
        let empty = ScoreCacheSyncPayload(rows: [], updatedAt: detailed ? nil : timestamp,
            detailedUpdatedAt: detailed ? timestamp : nil)
        #expect(await cache.applySynced(empty, replacing: initial))
        #expect(await cache.syncPayload() == empty)
        #expect(await cache.loadRows() == [])
    }

    @Test func scoreDiskFormatPreservesAdditionalFieldsAndClearsReplacedDetailMetadata() async throws {
        let session = AppStorageSession(accountIdentifier: "score-format")
        let files = ModuleScoreFiles(), root = URL(fileURLWithPath: "/score-format")
        let defaults = try #require(UserDefaults(suiteName: "BIT101ModulesTests.score-format"))
        defer { defaults.removePersistentDomain(forName: "BIT101ModulesTests.score-format") }
        let cache = ScoreCacheStore(files: files, storageRoot: root, defaults: defaults, session: { session })
        let rows = [ScoreRow(index: 0, headers: ["成绩"], values: ["80"])]
        #expect(await cache.saveDetailed(rows: rows) != nil)
        #expect(await cache.loadSnapshot()?.detailedUpdatedAt != nil)
        let url = root.appending(path: session.accountStorageIdentifier).appending(path: "score-cache.json")
        var object = try #require(JSONSerialization.jsonObject(with: files.readData(at: url)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        object["additionalField"] = ["nested": [1, 2]]
        try files.writeData(JSONSerialization.data(withJSONObject: object), to: url, options: [])
        #expect(await cache.save(rows: rows) != nil)
        #expect(await cache.loadSnapshot()?.detailedUpdatedAt == nil)
        #expect(await cache.syncPayload()?.detailedUpdatedAt == nil)
        let written = try #require(JSONSerialization.jsonObject(with: files.readData(at: url)) as? [String: Any])
        #expect(written["additionalField"] as? NSDictionary == object["additionalField"] as? NSDictionary)
    }

    @Test(arguments: ["{}", #"{"rows":[],"schemaVersion":2}"#, #"{"rows":[],"schemaVersion":true}"#,
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
        #expect(await cache.loadSnapshot() == nil)
        #expect(await cache.syncPayload() == nil)
        #expect(await cache.save(rows: []) == nil)
        #expect(try files.readData(at: url) == bytes)
    }

    @Test(arguments: [
        #"{"msg":"查询失败","data":[["课程名称","成绩"],["功能验收","95"]]}"#,
        #"{"msg":"查询成功","data":[["错误"],["未登录"]]}"#,
        #"{"msg":"查询成功","data":[["课程名称","成绩"],["功能验收"]]}"#,
        #"{"msg":"查询成功","data":[["课程名称","成绩","成绩"],["功能验收","95","95"]]}"#
    ])
    func malformedAndBusinessFailureScoreResponsesThrow(_ response: String) {
        #expect(throws: (any Error).self) { try ScoreService.decodeScoreRows(Data(response.utf8)) }
    }

    @Test func scoreResponseParsingRunsInThePackageHost() throws {
        #expect(try ScoreService.decodeScoreRows(Data(#"{"msg":"查询成功","data":[]}"#.utf8)).isEmpty)
        #expect(try ScoreService.decodeScoreRows(Data(#"{"msg":"查询成功","data":[["课程名称","成绩"],["功能验收","95"]]}"#.utf8)).first?.courseName == "功能验收")
    }
}

@MainActor
struct ScorePublicContractTests {
    private final class Cache: ScoreCaching {
        let changeSubject = PassthroughSubject<AppStorageSession, Never>()
        var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
        var loads = 0
        private var waiter: CheckedContinuation<Void, Never>?
        func loadSnapshot(for session: AppStorageSession?) async -> ScoreCacheSnapshot? {
            loads += 1
            waiter?.resume(); waiter = nil
            return ScoreCacheSnapshot()
        }
        func save(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func saveDetailed(rows: [ScoreRow], for session: AppStorageSession?) async -> Date? { nil }
        func waitForLoad() async {
            if loads > 0 { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }
    private final class Preferences: ScoreFilterPreferencesStoring {
        let changeSubject = PassthroughSubject<AppStorageSession, Never>()
        var changes: AnyPublisher<AppStorageSession, Never> { changeSubject.eraseToAnyPublisher() }
        var loads = 0
        func load() -> ScoreFilterPreferenceSnapshot? { loads += 1; return .init() }
        func save(selectedTerms: Set<String>, selectedCourseTypes: Set<String>, sortIndex: ScoreSortIndex, sortOrder: ScoreSortOrder) {}
    }
    private struct Service: ScoreListServicing {
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge { throw URLError(.notConnectedToInternet) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { [] }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { challenge }
    }

    @Test(.timeLimit(.minutes(1))) func publicAssemblyAcceptsIndependentStoragePortsAndFiltersEventSources() async {
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
        await cache.waitForLoad()
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
        #expect(ScoreSortIndex.averageScore.compare(first, empty) == .orderedSame)
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
