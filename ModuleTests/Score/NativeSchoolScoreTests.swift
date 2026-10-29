import ClientCore
import DesignSystemKit
import Combine
import BIT101TestSupport
import Foundation
import ScoreDomain
import ScorePorts
@testable import ScoreInfrastructure
import Testing
import TransportCore
import StorageCore
@testable import ScoreFeature

@MainActor
struct NativeSchoolScoreTests {
    private final class VerificationTransport: HTTPTransport {
        var requests: [URLRequest] = []
        var rejectsCaptcha = false
        var locksAccount = false
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            let step = requests.count
            var snapshot: [String: Any] = ["challenge_id": "captcha-flow", "access_token": "token", "expires_in": 300,
                "status": step == 1 ? "waiting_captcha" : (step == 2 ? "waiting_sms" : "authenticated")]
            if step == 1 { snapshot["captcha_image"] = "data:image/png;base64,AQID" }
            if step == 2, rejectsCaptcha { snapshot["status"] = "failed"; snapshot["error"] = "验证码错误或已失效 (1320007)" }
            if step == 2, locksAccount { snapshot["error"] = "账号已被锁定 (code:1030028)" }
            let body: [String: Any] = step == 1 && url.path.hasSuffix("/cjd/cookies") ? ["detail": snapshot] : snapshot
            return (try JSONSerialization.data(withJSONObject: body),
                try #require(HTTPURLResponse(url: url, statusCode: step == 2 && locksAccount ? 401 : (step == 1 ? 202 : 200),
                    httpVersion: nil, headerFields: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func relayCaptchaContinuesToSMSForScoresAndTranscripts(transcript: Bool) async throws {
        let credentials = Credentials(), transport = VerificationTransport()
        let client = HTTPClient(transport: transport, observer: nil)
        let service = ScoreService(credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://login.fixture.invalid"))
        var initial: BITLoginAuthenticationChallenge?
        do {
            if transcript { _ = try await service.fetchTrustedTranscriptPages() }
            else { _ = try await service.startScoreChallenge() }
        } catch ScoreServiceError.secondFactorRequired(let challenge) { initial = challenge }
        let captcha = try #require(initial)
        #expect(captcha.isCaptcha && captcha.requiresVerification && captcha.captchaImageData == Data([1, 2, 3]))
        #expect(captcha.ownerIdentity == credentials.schoolSessionIdentity)
        var pendingSMS: BITLoginAuthenticationChallenge?
        do {
            if transcript { _ = try await service.submitTranscriptVerificationCode("aB12", for: captcha) }
            else { _ = try await service.submitScoreVerificationCode("aB12", for: captcha) }
        } catch ScoreServiceError.secondFactorRequired(let challenge) { pendingSMS = challenge }
        let sms = try #require(pendingSMS)
        #expect(!sms.isCaptcha && sms.requiresVerification && sms.captchaImageData == nil)
        let authenticated = try await (transcript ? service.submitTranscriptVerificationCode("123456", for: sms)
            : service.submitScoreVerificationCode("123456", for: sms))
        #expect(authenticated.status == "authenticated" && authenticated.ownerIdentity == captcha.ownerIdentity)
        #expect(transport.requests.map { $0.url?.lastPathComponent }.suffix(2) == ["captcha", "sms"])
        for (request, code) in zip(transport.requests.suffix(2), ["aB12", "123456"]) {
            #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "X-Challenge-Token") == "token")
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
            #expect(body?["code"] == code)
        }
    }

    @Test(.timeLimit(.minutes(1))) func rejectedRelayCaptchaRetainsItsReasonAndEndsTheChallenge() async throws {
        let transport = VerificationTransport(); transport.rejectsCaptcha = true
        let credentials = Credentials(), client = HTTPClient(transport: transport, observer: nil)
        let service = ScoreService(credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://login.fixture.invalid"))
        var initial: BITLoginAuthenticationChallenge?
        do { _ = try await service.startScoreChallenge() }
        catch ScoreServiceError.secondFactorRequired(let challenge) { initial = challenge }
        do {
            _ = try await service.submitScoreVerificationCode("wrong", for: #require(initial))
            Issue.record("失败的图形验证应结束当前挑战。")
        } catch ScoreServiceError.challengeInvalid(let message) { #expect(message.contains("1320007")) }
        #expect(transport.requests.count == 2)
    }

    @Test func captchaValidationPreservesCaseAndTheProtocolLength() {
        #expect(AppVerificationCode.normalize(" aB12 ", isCaptcha: true) == "aB12")
        #expect(AppVerificationCode.isValid("aB12", isCaptcha: true))
        #expect(AppVerificationCode.isValid("Ab12Cd34Ef56Gh78", isCaptcha: true))
        #expect(!AppVerificationCode.isValid("Ab12 Cd34", isCaptcha: true))
        #expect(!AppVerificationCode.isValid("", isCaptcha: true))
        #expect(!AppVerificationCode.isValid("Ab12Cd34Ef56Gh789", isCaptcha: true))
    }

    @Test(.timeLimit(.minutes(1))) func lockedVerificationEndsTheScoreChallengeAndKeepsCachedGrades() async throws {
        let credentials = Credentials(), transport = VerificationTransport(); transport.locksAccount = true
        let client = HTTPClient(transport: transport, observer: nil)
        let service = ScoreService(credentials: credentials, httpClient: client, sensitiveHTTPClient: client,
            endpointBaseURL: AppURL.required("https://login.fixture.invalid"))
        let domain = "BIT101ModulesTests.locked-score"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "locked-score")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/locked-score"),
            defaults: defaults, session: { session })
        let old = ScoreRow(index: 0, headers: ["课程编号", "课程名称", "成绩"], values: ["old", "缓存课程", "95"])
        let savedAt = try #require(await cache.saveDetailed(rows: [old]))
        let model = ScoreViewModel(service: service, cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }), currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        await model.restoreCachedDataIfNeeded(); await model.refresh()
        #expect(model.verificationChallenge?.isCaptcha == true)
        await model.submitVerificationCode("aB12")
        #expect(model.verificationChallenge == nil && model.verificationError == nil)
        #expect(SchoolServiceFailure.from(model.alert?.underlyingError) == .accountLocked)
        #expect(model.rows.map(\.values) == [old.values] && model.lastUpdatedAt == savedAt)
        #expect(transport.requests.count == 2)
    }

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
        func submitTranscriptVerificationCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge {
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
    private static func gradeNotice(_ message: String) -> String {
        grades.components(separatedBy: "</tr>")[0] + "</tr>"
            + (message.isEmpty ? "" : "<tr><td colspan='5'>\(message)</td></tr>") + "</table>"
    }

    @Test(arguments: ["", "未查询到数据", "查询异常，请稍后重试", "说明"])
    func emptyGradeTablesRequireTheExplicitEmptyResult(message: String) throws {
        if message.isEmpty || message == "未查询到数据" {
            #expect(try NativeSchoolScoreParser.parse(Self.gradeNotice(message)).records.isEmpty)
        } else {
            #expect(throws: ScoreServiceError.self) { try NativeSchoolScoreParser.parse(Self.gradeNotice(message)) }
        }
    }

    @Test func schoolHTMLReferencesDecodeOnceForTextFormsAndLinks() throws {
        for (encoded, expected) in [("&amp;lt;", "&lt;"), ("&amp;#65;", "&#65;"), ("&#65;&#x1F600;", "A😀"),
            ("&#X41;&unknown;", "A&unknown;"), ("&quot;&apos;&amp;", "\"'&")] {
            #expect(SchoolLoginHTMLParser.decodeHTML(encoded) == expected)
            let html = Self.grades.replacingOccurrences(of: "数学 &amp; 计算", with: encoded)
            #expect(try NativeSchoolScoreParser.parse(html).records.first?.values[1] == expected)
        }
        let html = Self.grades.replacingOccurrences(of: "cjfx?id=1", with: "cjfx?id=1&amp;amp;term=2")
        #expect(try NativeSchoolScoreParser.parse(html).records.first?.detailPath == "/jsxsd/kscj/cjfx?id=1&amp;term=2")
        let form = SchoolLoginHTMLParser.parse(html: #"<input id='login-croypto' value='&amp;lt;'><input id='login-page-flowkey' value='&amp;#65;'>"#)
        #expect(form.salt == "&lt;" && form.execution == "&#65;")
    }
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
        var nativeBody: String?
        var nativeStatus = 200
        var relayOffline = false
        var failedDetails: Set<String> = []
        var restrictedDetails: Set<String> = []
        var pauseDetails = false
        var detailsEntered = false
        var holdDetails = false
        var pendingDetails: [String: CheckedContinuation<Void, Never>] = [:]
        var detailBodies: [String: String] = [:]
        var activeDetails = 0
        var maximumActiveDetails = 0
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            if relayOffline, url.host == "relay.invalid" { throw URLError(.notConnectedToInternet) }
            let body: String
            switch url.path {
            case "/jsxsd/kscj/cjcx_list": body = nativeBody ?? (malformedNative ? "<html>service unavailable</html>" : NativeSchoolScoreTests.grades)
            case "/jsxsd/kscj/cjfx":
                detailsEntered = true
                activeDetails += 1
                maximumActiveDetails = max(maximumActiveDetails, activeDetails)
                defer { activeDetails -= 1 }
                if pauseDetails { try await Task.sleep(for: .seconds(60)) }
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
                if holdDetails { await withCheckedContinuation { pendingDetails[id] = $0 } }
                body = restrictedDetails.contains(id) ? "<html>对不起，无权访问该资源</html>"
                    : failedDetails.contains(id) ? "<html>changed detail protocol</html>" : detailBodies[id] ?? NativeSchoolScoreTests.detail
            case "/api/auth/start": body = #"{"challenge_id":"remote","access_token":"token","status":"authenticated"}"#
            case "/api/jwb/bit101/score": body = #"{"msg":"查询成功","data":[["课程编号","课程名称","成绩","学分"],["CS1","remote","90","3"]]}"#
            case "/api/jwb/cjd/cookies": body = #"{"cookie_str":"remote=fixture"}"#
            case "/cjd/ScoreReport2/Index": body = #"<img src="/cjd/Temp/page.png">"#
            case "/cjd/Temp/page.png": body = "page-data"
            default: throw URLError(.badURL)
            }
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: url.host == "jwms.bit.edu.cn" ? nativeStatus : 200, httpVersion: nil, headerFields: nil)))
        }
    }
    private final class Observer: HTTPClientObserving {
        var validationFailures: [(String, Int)] = []
        func willSend(_ request: URLRequest) async throws {}
        func didFinish(request: URLRequest, finalRequest: URLRequest?, data: Data?, response: URLResponse?, error: Error?, elapsed: TimeInterval) async {
            if error != nil, let status = (response as? HTTPURLResponse)?.statusCode { validationFailures.append((request.url?.path ?? "", status)) }
        }
    }
    private func service(_ credentials: Credentials, _ transport: Transport, _ authenticator: Authenticator,
        observer: (any HTTPClientObserving)? = nil) -> ScoreService {
        let client = HTTPClient(transport: transport, observer: observer)
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
        #expect(transport.requests.count == 2 && transport.requests.allSatisfy { $0.url?.host == "jwms.bit.edu.cn" })
        let parsed = try NativeSchoolScoreParser.parse(Self.grades)
        #expect(parsed.records.first?.values[1] == "数学 & 计算" && parsed.records.first?.values[2] == "优秀")
        #expect(brief.first?.score == "优秀" && ScoreSummary.make(from: brief).weightedAverageGPA == 4)
        #expect(try NativeSchoolScoreParser.detail(Self.detail) == ["60", "90", "85", "95", "30", "100", "是", "前10%", "前20%", "前30%"])
    }

    @Test(arguments: ["优秀", "良好", "中等", "及格", "不及格"])
    func nativeGradesKeepTheSchoolLabelsAndDomainGPA(grade: String) throws {
        let table = try NativeSchoolScoreParser.parse(Self.grades.replacingOccurrences(of: ">优秀<", with: ">\(grade)<"))
        let rows = table.records.enumerated().map { ScoreRow(index: $0.offset, headers: table.headers, values: $0.element.values) }
        let grades = ["优秀": 4.0, "良好": 3.6, "中等": 2.8, "及格": 1.7, "不及格": 0.0]
        let expected = try #require(grades[grade])
        let actual = try #require(ScoreSummary.make(from: rows).weightedAverageGPA)
        #expect(rows.first?.score == grade)
        #expect(abs(actual - expected) <= expected.ulp * 2)
    }

    @Test func detailLinksFollowTheirResourceAcrossColumnsAndHTMLEntities() throws {
        let html = Self.grades.replacingOccurrences(of: "<td>3</td>", with:
            #"<td><a onclick="open(&quot;/jsxsd/kscj/cjfx?id=1&amp;term=2&quot;)">3</a></td>"#)
            .replacingOccurrences(of: #"<a onclick="JsMod('/jsxsd/kscj/cjfx?id=1')">详情</a>"#, with: "")
        let table = try NativeSchoolScoreParser.parse(html)
        #expect(table.records.first?.detailPath == "/jsxsd/kscj/cjfx?id=1&term=2")
    }

    @Test(.timeLimit(.minutes(1))) func nativeDetailsUseFourConcurrentRequestsAndPreserveCourseOrder() async throws {
        let credentials = Credentials(), transport = Transport()
        let parts = Self.grades.components(separatedBy: "</tr>")
        transport.nativeBody = parts[0] + "</tr>" + (1...8).map { index in
            (parts[1] + "</tr>").replacingOccurrences(of: "CS1", with: "CS\(index)")
                .replacingOccurrences(of: "id=1'", with: "id=\(index)'")
        }.joined() + "</table>"
        transport.detailBodies = Dictionary(uniqueKeysWithValues: (1...8).map { (String($0), Self.detail.replacingOccurrences(of: "平均分：85", with: "平均分：\(80 + $0)")) })
        transport.holdDetails = true
        let service = service(credentials, transport, Authenticator(credentials.schoolSessionIdentity))
        let challenge = try await service.startScoreChallenge()
        let task = Task { try await service.fetchScores(detail: true, authenticatedBy: challenge) }
        defer {
            task.cancel()
            for pending in transport.pendingDetails.values { pending.resume() }
            transport.pendingDetails.removeAll()
        }
        try await waitForTestEvent { transport.pendingDetails.count == 4 }
        #expect(transport.maximumActiveDetails == 4)
        for index in [4, 3, 2, 1, 8, 7, 6, 5] {
            let id = String(index)
            try await waitForTestEvent { transport.pendingDetails[id] != nil }
            transport.pendingDetails.removeValue(forKey: id)?.resume()
        }
        let rows = try await task.value
        #expect(rows.map(\.courseNumber) == (1...8).map { "CS\($0)" })
        #expect(rows.map(\.averageScore) == (1...8).map { String(80 + $0) })
        #expect(transport.maximumActiveDetails == 4)
    }

    @Test(.timeLimit(.minutes(1))) func localProtocolFailureUsesOneRemoteChallenge() async throws {
        let credentials = Credentials(), transport = Transport()
        transport.malformedNative = true
        let authenticator = Authenticator(credentials.schoolSessionIdentity)
        let observer = Observer()
        let service = service(credentials, transport, authenticator, observer: observer)
        let challenge = try await service.startScoreChallenge()
        #expect(try await service.fetchScores(detail: false, authenticatedBy: challenge).count == 1)
        #expect(try await service.fetchScores(detail: true, authenticatedBy: challenge).count == 1)
        #expect(transport.requests.compactMap { $0.url?.path } == ["/jsxsd/kscj/cjcx_list", "/api/auth/start", "/api/jwb/bit101/score", "/api/jwb/bit101/score"])
        #expect(observer.validationFailures.count == 1 && observer.validationFailures.first?.0 == "/jsxsd/kscj/cjcx_list" && observer.validationFailures.first?.1 == 200)
    }

    @Test(.timeLimit(.minutes(1))) func transcriptUsesLocalSchoolCookiesAndExistingDownloads() async throws {
        let credentials = Credentials(), transport = Transport()
        let authenticator = Authenticator(credentials.schoolSessionIdentity)
        let pages = try await service(credentials, transport, authenticator).fetchTrustedTranscriptPages()
        #expect(pages.pages.count == 1 && authenticator.targets == [.transcript])
        #expect(transport.requests.allSatisfy { $0.url?.host == "jwb.bit.edu.cn" && $0.value(forHTTPHeaderField: "Cookie") == "report=fixture" })
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func partialDetailsKeepFreshFieldsAndMatchingCachedFields(strictFailure: Bool) async throws {
        let credentials = Credentials(), transport = Transport(), observer = Observer()
        let extra = (2...3).map { number in
            "<tr><td>CS\(number)</td><td>课程\(number)</td><td>85</td><td>3</td><td><a href='/jsxsd/kscj/cjfx?id=\(number)'>详情</a></td></tr>"
        }.joined()
        transport.nativeBody = Self.grades.replacingOccurrences(of: "</table>", with: extra + "</table>")
        transport.failedDetails = ["2"]
        if strictFailure { transport.restrictedDetails = ["3"] }
        let service = service(credentials, transport, Authenticator(credentials.schoolSessionIdentity), observer: observer)
        let domain = "BIT101ModulesTests.native-score"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "native-score")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/native-score"), defaults: defaults, session: { session })
        let old = ScoreRow(index: 1, headers: ["课程编号", "课程名称", "成绩", "学分", "操作栏", "平均分"],
            values: ["CS2", "课程2", "85", "3", "详情", "70"])
        #expect(await cache.saveDetailed(rows: [old]) != nil)
        let model = ScoreViewModel(service: service, cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }), currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        await model.restoreCachedDataIfNeeded(); await model.refresh()
        #expect(model.state == .loaded && model.alert != nil)
        let expected = ["85", "70", strictFailure ? "" : "85"]
        #expect(model.rows.map(\.averageScore) == expected)
        #expect(SchoolServiceFailure.from(model.alert?.underlyingError) == (strictFailure ? .accessDenied : nil))
        let saved = try #require(await cache.loadSnapshot())
        #expect(saved.rows?.map(\.averageScore) == expected && saved.detailedUpdatedAt == nil)
        #expect(transport.requests.count == 4 && transport.requests.allSatisfy { $0.url?.host == "jwms.bit.edu.cn" })
        #expect(observer.validationFailures.count == (strictFailure ? 2 : 1) && observer.validationFailures.first?.1 == 200)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func schoolFailuresKeepTheirOriginAndSkipTheRelay(httpFailure: Bool) async throws {
        let credentials = Credentials(), transport = Transport(), observer = Observer()
        transport.nativeBody = "<html>对不起，无权访问该资源</html>"
        if httpFailure { transport.nativeStatus = 503 }
        let service = service(credentials, transport, Authenticator(credentials.schoolSessionIdentity), observer: observer)
        let challenge = try await service.startScoreChallenge()
        do { _ = try await service.fetchScores(detail: false, authenticatedBy: challenge); Issue.record("学校访问限制需要呈现学校来源。") }
        catch {
            let expected: SchoolServiceFailure = httpFailure ? .unavailable : .accessDenied
            #expect(SchoolServiceFailure.from(error) == expected)
            #expect(SchoolServiceFailure.from(PartialScoreResult(rows: [], failure: error)) == expected)
        }
        #expect(transport.requests.count == 1 && observer.validationFailures.first?.1 == (httpFailure ? 503 : 200))
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: [false, true])
    func gradeNoticesKeepCachedRowsUntilAnExplicitEmptyResult(empty: Bool) async throws {
        let credentials = Credentials(), transport = Transport()
        transport.nativeBody = Self.gradeNotice(empty ? "未查询到数据" : "查询异常，请稍后重试")
        transport.relayOffline = true
        let domain = "BIT101ModulesTests.score-table-notice"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = AppStorageSession(accountIdentifier: "score-table-notice")
        let cache = ScoreCacheStore(files: ModuleScoreFiles(), storageRoot: URL(fileURLWithPath: "/score-table-notice"), defaults: defaults,
            session: { session })
        let old = ScoreRow(index: 0, headers: ["课程编号", "课程名称", "成绩", "学分", "平均分"], values: ["CS1", "已缓存课程", "95", "3", "85"])
        let savedAt = try #require(await cache.saveDetailed(rows: [old]))
        let model = ScoreViewModel(service: service(credentials, transport, Authenticator(credentials.schoolSessionIdentity)), cacheStore: cache,
            preferenceStore: ScoreFilterPreferenceStore(defaults: defaults, session: { session }), currentScoreCacheSession: { session },
            scheduleCoursesChanges: Empty().eraseToAnyPublisher(), loadScheduleCourses: { _ in [:] })
        await model.restoreCachedDataIfNeeded(); await model.refresh()
        let persisted = try #require(await cache.loadSnapshot())
        #expect(model.state == .loaded)
        if empty {
            #expect(model.rows.isEmpty && persisted.rows?.isEmpty == true && persisted.detailedUpdatedAt != nil)
            #expect(transport.requests.allSatisfy { $0.url?.host == "jwms.bit.edu.cn" })
        } else {
            #expect(model.alert != nil && model.rows.map(\.values) == [old.values])
            #expect(persisted.rows?.map(\.values) == [old.values] && persisted.detailedUpdatedAt == savedAt)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancellationStopsRemainingDetailsAndKeepsTheRelayIdle() async throws {
        let credentials = Credentials(), transport = Transport()
        transport.pauseDetails = true
        let service = service(credentials, transport, Authenticator(credentials.schoolSessionIdentity))
        let challenge = try await service.startScoreChallenge()
        _ = try await service.fetchScores(detail: false, authenticatedBy: challenge)
        let pending = Task { try await service.fetchScores(detail: true, authenticatedBy: challenge) }
        defer { pending.cancel() }
        try await waitForTestEvent { transport.detailsEntered }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(transport.requests.count == 2 && transport.requests.allSatisfy { $0.url?.host == "jwms.bit.edu.cn" })
    }

    @Test(.timeLimit(.minutes(1))) func anExpiredDetailBudgetKeepsTheSummaryAndStartsZeroRequests() async throws {
        let credentials = Credentials(), transport = Transport()
        let session = SchoolAuthenticatedSession(baseURL: SchoolServiceTarget.grades.baseURL, cookieHeader: "", owner: credentials.schoolSessionIdentity)
        let challenge = BITLoginAuthenticationChallenge(challengeID: "budget", accessToken: "", status: "authenticated", maskedPhone: nil, expiresIn: nil, nativeSession: session)
        let query = NativeSchoolScoreQuery(challenge)
        query.table = try NativeSchoolScoreParser.parse(Self.grades)
        let reader = NativeSchoolScoreReader(client: HTTPClient(transport: transport, observer: nil), validate: {}, query: query, deadline: .now)
        do { _ = try await reader.fetch(detail: true, session: session); Issue.record("详情预算结束需要保留部分结果。") }
        catch let partial as PartialScoreResult { #expect(partial.rows.count == 1 && (partial.failure as? URLError)?.code == .timedOut) }
        #expect(transport.requests.isEmpty)
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
