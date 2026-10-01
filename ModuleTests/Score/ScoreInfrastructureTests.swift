import Combine
import StorageCore
import ScoreDomain
import ClientCore
import Foundation
import ScoreFeature
@testable import ScoreInfrastructure
import Testing
import TransportCore

@MainActor
struct ScoreInfrastructureBoundaryTests {
    private struct Credentials: SchoolCredentialsProviding {
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

    @Test func scoreResponseParsingRunsInThePackageHost() throws {
        #expect(try ScoreService.decodeScoreRows(Data(#"{"msg":"查询成功","data":[]}"#.utf8)).isEmpty)
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
        func markChecked(for session: AppStorageSession?) async -> Date? { nil }
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
        let now = Date(timeIntervalSince1970: 100)
        #expect(ScoreDetailRefreshPolicy.decision(briefRows: [high], cachedRows: [high], detailedUpdatedAt: nil, now: now) == .reuseCompletedCache)
        let incomplete = row(0, "90", status: "否")
        #expect(ScoreDetailRefreshPolicy.decision(briefRows: [incomplete], cachedRows: [incomplete], detailedUpdatedAt: now, now: now) == .reuseRateLimitedCache)
        #expect(ScoreDetailRefreshPolicy.decision(briefRows: [incomplete], cachedRows: [incomplete], detailedUpdatedAt: now.addingTimeInterval(-ScoreDetailRefreshPolicy.incompleteRetryInterval), now: now) == .fetch)
    }
}
