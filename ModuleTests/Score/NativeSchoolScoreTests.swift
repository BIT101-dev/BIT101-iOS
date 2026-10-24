import ClientCore
import Foundation
import ScoreDomain
import ScorePorts
@testable import ScoreInfrastructure
import Testing
import TransportCore

@MainActor
struct NativeSchoolScoreTests {
    private final class TranscriptPort: TrustedTranscriptServicing {
        var challenge: BITLoginAuthenticationChallenge?
        var hadDelivery = false
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            hadDelivery = onPage != nil
            return .init([Data([1]), Data([2])])
        }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge,
            onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            self.challenge = challenge
            return try await fetchTrustedTranscriptPages(onPage: onPage)
        }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge {
            challenge
        }
    }

    @Test(.timeLimit(.minutes(1))) func transcriptConveniencesPreserveAuthenticationPageNumbersAndServiceIdentity() async throws {
        let first = TranscriptPort(), second = TranscriptPort()
        let challenge = BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "token",
            status: "ready", maskedPhone: nil, expiresIn: nil)
        let pages = try await first.fetchTrustedTranscriptPages(authenticatedBy: challenge)
        #expect(first.challenge == challenge && !first.hadDelivery)
        #expect(pages.pages.map(\.number) == [1, 2] && pages.expectedPageCount == 2)
        #expect(pages.pages.map(\.data) == [Data([1]), Data([2])])
        #expect(first.transcriptServiceIdentity == first.transcriptServiceIdentity)
        #expect(first.transcriptServiceIdentity != second.transcriptServiceIdentity)
    }

    @Test(.timeLimit(.minutes(1))) func transcriptCapacityRetainsDeliveredPagesAndRejectsInvalidReports() async throws {
        let invalid = TrustedTranscriptReport(pageCount: 0) { _, _ in Data([1]) }
        await #expect(throws: ScoreServiceError.self) { try await invalid.loadPages(maximumBytes: 1) }
        let report = TrustedTranscriptReport(pageCount: 2) { number, _ in Data([UInt8(number)]) }
        let partial = try await report.loadPages(maximumBytes: 1)
        #expect(partial.pages.map(\.number) == [1] && partial.failure != nil && !report.isInvalid)
        let remaining = try await report.loadPages(excluding: [1], maximumBytes: 1)
        #expect(remaining.pages.map(\.number) == [2] && remaining.failure == nil)
    }

    private static let grades = #"<table id="dataList"><tr><th>课程编号</th><th>课程名称</th><th>成绩</th><th>学分</th><th>操作栏</th></tr><tr><td>CS1</td><td>数学 &amp; 计算</td><td><a onclick="JsMod('/jsxsd/kscj/pscj_list.do')">优秀</a></td><td>3</td><td><a onclick="JsMod('/jsxsd/kscj/cjfx?id=1')">详情</a></td></tr></table>"#
    private static let detail = #"<table id="dataList"></table><table id="dataList"><tr><td>班级人数：30</td><td>专业人数：60</td><td>学习人数：90</td><td>平均分：85</td><td>最高分：100</td><td>该课程所有教学班成绩录入完毕：是</td></tr></table><table id="dataList"><tr><td>本人成绩：95</td><td>本人成绩在班级中占：前10%</td><td>本人成绩在专业中占：前20%</td><td>本人成绩在所有学生中占：前30%</td></tr></table>"#
    private final class Credentials: SchoolCredentialsProviding {
        var generation = 0
        let currentStudentID = "owner"
        let currentPassword = "school-B"
        var schoolSessionIdentity: SchoolSessionIdentity { .init(accountIdentifier: currentStudentID, generation: generation) }
    }
    private final class Authenticator: SchoolServiceAuthenticating {
        let owner: SchoolSessionIdentity
        var targets: [SchoolServiceTarget] = []
        var failure: Error?
        init(_ owner: SchoolSessionIdentity) { self.owner = owner }
        func authenticate(_ target: SchoolServiceTarget) async throws -> SchoolAuthenticatedSession {
            targets.append(target)
            if let failure { throw failure }
            return .init(baseURL: target.baseURL, cookieHeader: "report=fixture", owner: owner)
        }
    }
    private final class Transport: HTTPTransport {
        var requests: [URLRequest] = []
        var malformedNative = false
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            let body: String
            switch url.path {
            case "/jsxsd/kscj/cjcx_list": body = malformedNative ? "<html>service unavailable</html>" : NativeSchoolScoreTests.grades
            case "/jsxsd/kscj/cjfx": body = NativeSchoolScoreTests.detail
            case "/api/auth/start": body = #"{"challenge_id":"remote","access_token":"token","status":"authenticated"}"#
            case "/api/jwb/bit101/score": body = #"{"msg":"查询成功","data":[["课程编号","课程名称","成绩","学分"],["CS1","remote","90","3"]]}"#
            case "/api/jwb/cjd/cookies": body = #"{"cookie_str":"remote=fixture"}"#
            case "/cjd/ScoreReport2/Index": body = #"<img src="/cjd/Temp/page.png">"#
            case "/cjd/Temp/page.png": body = "page-data"
            default: throw URLError(.badURL)
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }
    private func service(_ credentials: Credentials, _ transport: Transport, _ authenticator: Authenticator) -> ScoreService {
        let client = HTTPClient(transport: transport, observer: nil)
        return ScoreService(credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://relay.invalid"), nativeAuthenticator: authenticator, nativeHTTPClient: client)
    }

    @Test(.timeLimit(.minutes(1))) func localGradesReuseOneAuthenticationForBothPhases() async throws {
        let credentials = Credentials(), transport = Transport()
        let authenticator = Authenticator(credentials.schoolSessionIdentity)
        let service = service(credentials, transport, authenticator)
        let challenge = try await service.startScoreChallenge()
        let brief = try await service.fetchScores(detail: false, authenticatedBy: challenge)
        let detailed = try await service.fetchScores(detail: true, authenticatedBy: challenge)
        #expect(brief.count == 1 && detailed.count == 1)
        #expect(detailed.first?.averageScore == "85" && detailed.first?.classRank == "前10%")
        #expect(authenticator.targets == [.grades])
        #expect(transport.requests.count == 3 && transport.requests.allSatisfy { $0.url?.host == "jwms.bit.edu.cn" })
        let parsed = try NativeSchoolScoreParser.parse(Self.grades)
        #expect(parsed.records.first?.values[1] == "数学 & 计算" && parsed.records.first?.values[2] == "95")
        #expect(try NativeSchoolScoreParser.detail(Self.detail) == ["60", "90", "85", "95", "30", "100", "是", "前10%", "前20%", "前30%"])
    }

    @Test func detailLinksFollowTheirResourceAcrossColumnsAndHTMLEntities() throws {
        let html = Self.grades.replacingOccurrences(of: "<td>3</td>", with:
            #"<td><a onclick="open(&quot;/jsxsd/kscj/cjfx?id=1&amp;term=2&quot;)">3</a></td>"#)
            .replacingOccurrences(of: #"<a onclick="JsMod('/jsxsd/kscj/cjfx?id=1')">详情</a>"#, with: "")
        let table = try NativeSchoolScoreParser.parse(html)
        #expect(table.records.first?.detailPath == "/jsxsd/kscj/cjfx?id=1&term=2")
    }

    @Test(.timeLimit(.minutes(1))) func localProtocolFailureUsesOneRemoteChallenge() async throws {
        let credentials = Credentials(), transport = Transport()
        transport.malformedNative = true
        let authenticator = Authenticator(credentials.schoolSessionIdentity)
        let service = service(credentials, transport, authenticator)
        let challenge = try await service.startScoreChallenge()
        #expect(try await service.fetchScores(detail: false, authenticatedBy: challenge).count == 1)
        #expect(transport.requests.compactMap { $0.url?.path } == ["/jsxsd/kscj/cjcx_list", "/api/auth/start", "/api/jwb/bit101/score"])
    }

    @Test(.timeLimit(.minutes(1))) func transcriptUsesLocalSchoolCookiesAndExistingDownloads() async throws {
        let credentials = Credentials(), transport = Transport()
        let authenticator = Authenticator(credentials.schoolSessionIdentity)
        let pages = try await service(credentials, transport, authenticator).fetchTrustedTranscriptPages()
        #expect(pages.pages.count == 1 && authenticator.targets == [.transcript])
        #expect(transport.requests.allSatisfy { $0.url?.host == "jwb.bit.edu.cn" && $0.value(forHTTPHeaderField: "Cookie") == "report=fixture" })
    }

    @Test(.timeLimit(.minutes(1))) func nativeCancellationKeepsRelayIdle() async throws {
        let credentials = Credentials(), transport = Transport()
        let authenticator = Authenticator(credentials.schoolSessionIdentity)
        authenticator.failure = CancellationError()
        let service = service(credentials, transport, authenticator)
        await #expect(throws: CancellationError.self) { try await service.startScoreChallenge() }
        await #expect(throws: CancellationError.self) { try await service.fetchTrustedTranscriptPages() }
        #expect(transport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func changedAccountCancelsLocalBusinessRequest() async throws {
        let credentials = Credentials(), transport = Transport()
        let authenticator = Authenticator(credentials.schoolSessionIdentity)
        let service = service(credentials, transport, authenticator)
        let challenge = try await service.startScoreChallenge()
        credentials.generation += 1
        await #expect(throws: CancellationError.self) { try await service.fetchScores(detail: false, authenticatedBy: challenge) }
        #expect(transport.requests.isEmpty)
    }

    @Test func malformedHeadersAndRowsPreserveProtocolFailure() {
        #expect(throws: ScoreServiceError.self) { try NativeSchoolScoreParser.parse("<html>CAS</html>") }
        #expect(throws: ScoreServiceError.self) { try NativeSchoolScoreParser.parse(Self.grades.replacingOccurrences(of: "<td>3</td>", with: "")) }
        #expect(throws: ScoreServiceError.self) { try NativeSchoolScoreParser.detail("<html>CAS</html>") }
    }
}
