import ClientCore
import Foundation
import ScheduleDomain
import SchedulePorts
import StorageCore
import Testing
import TransportCore
@testable import ScheduleInfrastructure
@testable import ScheduleFeature

@MainActor
struct EclassDDLTests {
    @Test func productionDDLServicePersistsAndReloadsTheOwnedSourceWithCompletion() async throws {
        let transport = EclassTransport { request in
            request.url?.path == "/api/my-courses"
                ? (200, #"{"courses":[{"id":1,"name":"操作系统"}],"pages":1}"#, nil)
                : (200, #"{"activities":[{"id":42,"title":"新版作业","submit_times":1,"end_time":"2030-10-01T15:59:00Z"},{"id":43,"type":"material","title":"资料","end_time":"2030-10-01 23:59:00"}]}"#, nil)
        }
        var initial = ScheduleCache()
        initial.ddlEvents = [
            DDLEventRecord(id: "eclass:42", group: "eclass", title: "缓存作业", text: "", dueAt: Date(), done: true),
            DDLEventRecord(id: "manual", group: "main", title: "手动日程", text: "", dueAt: Date().addingTimeInterval(3600), done: false),
        ]
        var saved: ScheduleCache?
        let account = AppStorageSession(accountIdentifier: "pipeline-test")
        let repository = ScheduleRepository(session: { account }, load: { _ in .loaded(initial) }, save: { cache, _, owner in
            #expect(owner == account)
            saved = cache
        })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        #expect(await model.syncDDL())
        let persisted = try #require(saved)
        let synced = try #require(persisted.ddlEvents.first(where: { $0.id == "eclass:42" }))
        #expect(synced.title == "新版作业")
        #expect(synced.text == "操作系统")
        #expect(synced.done)
        #expect(synced.dueAt == EclassActivity.parseTime("2030-10-01 23:59:00"))
        #expect(persisted.ddlEvents.count == 2)
        let encoded = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(ScheduleCache.self, from: encoded)
        let reloaded = ScheduleRepository(session: { account }, load: { _ in .loaded(decoded) }, save: { _, _, _ in })
        let reopened = ScheduleDDLViewModel(service: service(transport), repository: reloaded)
        await reloaded.loadIfNeeded()
        #expect(reopened.visibleDDLEvents.map(\.id).contains("eclass:42"))
        #expect(reopened.cache.lexueDDLCompletionByID["eclass:42"] == true)
    }

    @Test(arguments: ["2026-10-01 23:59:00", "2026-10-01 23:59", "2026/10/01 23:59:00",
                      "2026/10/01 23:59", "2026-10-01T23:59:00", "2026-10-01T23:59",
                      "2026-10-01T23:59:00+08:00", "2026-10-01T15:59:00Z", "2026-10-01T11:59:00-04:00"])
    func deadlinesRepresentTheSameInstant(_ text: String) throws {
        let expected = try Date.ISO8601FormatStyle().parse("2026-10-01T15:59:00Z")
        #expect(EclassActivity.parseTime(text) == expected)
    }

    @Test(arguments: ["", "null", " NULL ", "bad", "2026-02-30 12:00:00", "2026-10-01 25:00:00",
                      "2026-10-01", "2026-10-01 23:59:00 trailing"])
    func invalidDeadlineValuesAreExcluded(_ text: String) {
        #expect(EclassActivity.parseTime(text) == nil)
    }

    @Test func fractionalSecondsAndWhitespaceArePreserved() throws {
        let date = try #require(EclassActivity.parseTime(" 2026-10-01T15:59:00.123Z \n"))
        let whole = try #require(EclassActivity.parseTime("2026-10-01 23:59:00"))
        #expect(abs(date.timeIntervalSince(whole) - 0.123) < 0.00001)
    }

    @Test(arguments: [#""submit_times":0"#, #""late_submission_count":0"#, #""is_review_homework":false"#])
    func homeworkUsesFieldPresence(_ field: String) throws {
        let activity = try decodeActivity(#"{"id":42,"title":" 作业 ","type":"unknown","end_time":"2026-10-01 23:59:00","# + field + "}")
        let event = try #require(activity.event(courseName: "操作系统"))
        #expect(event.id == "eclass:42")
        #expect(event.group == "eclass")
        #expect(event.title == "作业")
        #expect(event.text == "操作系统")
        #expect(event.isSchoolSynced)
        #expect(event.sourceTitle == "课程中心")
    }

    @Test(arguments: ["material", "MATERIAL"])
    func materialsWithDeadlinesAndHomeworkFieldsAreExcluded(_ type: String) throws {
        let activity = try decodeActivity(#"{"id":1,"type":""# + type + #"","title":"资料","submit_times":1,"end_time":"2026-10-01 23:59:00"}"#)
        #expect(activity.event(courseName: "课名") == nil)
    }

    @Test func deadlineFallbackAndBlankTitleWorkTogether() throws {
        let activity = try decodeActivity(#"{"id":7,"title":" ","submit_times":1,"end_time":"null","visible_end_at":"2026-10-01 23:59"}"#)
        let event = try #require(activity.event(courseName: "课名"))
        #expect(event.title == "未命名作业")
        #expect(event.dueAt == EclassActivity.parseTime("2026-10-01 23:59"))
    }

    @Test(arguments: [#"{"id":1,"title":"活动","end_time":"2026-10-01 23:59"}"#,
                      #"{"id":2,"submit_times":1}"#,
                      #"{"id":0,"submit_times":1,"end_time":"2026-10-01 23:59"}"#,
                      #"{"id":3,"submit_times":null,"end_time":"2026-10-01 23:59"}"#])
    func activitiesRequireHomeworkIdentityAndDeadline(_ json: String) throws {
        #expect(try decodeActivity(json).event(courseName: "课名") == nil)
    }

    @Test func allCoursePagesAreRequestedAndDuplicatesAreMerged() async throws {
        let transport = EclassTransport { request in
            if request.url?.path == "/api/my-courses" {
                let body = try #require(request.httpBody)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(json["page_size"] as? Int == 100)
                #expect(json["fields"] as? String == "id,name")
                #expect((json["conditions"] as? [String: String])?.isEmpty == true)
                return (200, json["page"] as? Int == 1
                    ? #"{"courses":[{"id":1,"name":"第一门"}],"page":1,"pages":2}"#
                    : #"{"courses":[{"id":1,"name":"第一门"},{"id":2,"name":"第二门"}],"page":2,"pages":2}"#, nil)
            }
            return (200, #"{"activities":[{"id":42,"title":"作业","submit_times":1,"end_time":"2026-10-01 23:59"}]}"#, nil)
        }
        let result = try await service(transport).fetchEclassDDLEvents()
        #expect(result.courseCount == 2)
        #expect(result.activityCount == 2)
        #expect(result.events.count == 1)
        #expect(transport.requests.count == 4)
        #expect(transport.requests.allSatisfy { $0.url?.host == "zy-eclass.bit.edu.cn" })
    }

    @Test func activityRequestsHaveBoundedConcurrencyAndGlobalOrdering() async throws {
        let transport = EclassTransport { request in
            if request.url?.path == "/api/my-courses" {
                let courses = (1 ... 9).map { #"{"id":\#($0),"name":"course"}"# }.joined(separator: ",")
                return (200, #"{"courses":["# + courses + #"],"pages":1}"#, nil)
            }
            let id = try #require(request.url?.path.split(separator: "/").dropLast().last.flatMap { Int($0) })
            return (200, #"{"activities":[{"id":\#(id),"submit_times":1,"end_time":"2026-10-01 0\#(10-id):00:00"}]}"#, nil)
        }
        let result = try await service(transport).fetchEclassDDLEvents()
        #expect(result.events.map(\.id) == (1 ... 9).reversed().map { "eclass:\($0)" })
        #expect(transport.maximumConcurrentRequests <= 4)
        #expect(transport.maximumConcurrentRequests > 1)
    }

    @Test(arguments: [#"{"courses":[{"id":1,"name":"课"}],"page":2,"pages":2}"#,
                      #"{"courses":[],"page":1,"pages":2}"#,
                      #"{"courses":[{"id":0,"name":"课"}],"page":1,"pages":1}"#,
                      #"{"visited_courses":[]}"#, #"{}"#])
    func incompleteCourseResponsesFailExplicitly(_ json: String) async {
        let transport = EclassTransport { _ in (200, json, nil) }
        await #expect(throws: ScheduleServiceError.self) { try await service(transport).fetchEclassDDLEvents() }
    }

    @Test func repeatedCoursePagesStopTheSync() async {
        let transport = EclassTransport { _ in
            (200, #"{"courses":[{"id":1,"name":"课"}],"pages":3}"#, nil)
        }
        await #expect(throws: ScheduleServiceError.self) { try await service(transport).fetchEclassDDLEvents() }
        #expect(transport.requests.count == 2)
    }

    @Test func emptyCourseListIsAValidCompleteResult() async throws {
        let transport = EclassTransport { _ in (200, #"{"courses":[],"page":1,"pages":0}"#, nil) }
        let result = try await service(transport).fetchEclassDDLEvents()
        #expect(result.courseCount == 0)
        #expect(result.events.isEmpty)
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [401, 403, 302])
    func authenticationStatusRequiresEclassLogin(_ status: Int) async {
        let transport = EclassTransport { _ in (status, "", nil) }
        do {
            _ = try await service(transport).fetchEclassDDLEvents()
            Issue.record("Expected an authentication challenge")
        } catch {
            guard case ScheduleServiceError.eclassAuthenticationFailed = error else {
                Issue.record("Expected eclassAuthenticationFailed, got \(error)")
                return
            }
        }
    }

    @Test func redirectedLoginHTMLRequiresEclassLogin() async {
        let transport = EclassTransport { _ in (200, "<html>登录</html>", "https://zy-identity.bit.edu.cn/auth/") }
        do { _ = try await service(transport).fetchEclassDDLEvents(); Issue.record("Expected authentication") }
        catch { #expect(error as? ScheduleServiceError != nil) }
    }

    @Test func failedCourseActivityRejectsTheCompleteSnapshot() async {
        let transport = EclassTransport { request in
            request.url?.path == "/api/my-courses"
                ? (200, #"{"courses":[{"id":1,"name":"课"}],"pages":1}"#, nil)
                : (503, "failure", nil)
        }
        await #expect(throws: ScheduleServiceError.self) { try await service(transport).fetchEclassDDLEvents() }
    }

    @Test func cancellationPropagatesThroughTheSourceAggregator() async {
        let transport = EclassTransport { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await service(transport).syncDDLEvents(existingEvents: [], storedURL: "")
        }
    }

    @Test func freshEclassSyncRecordsItsSourceWithoutLexueDiscovery() async throws {
        let transport = EclassTransport { _ in (200, #"{"courses":[],"pages":0}"#, nil) }
        let payload = try await service(transport).syncDDLEvents(existingEvents: [], storedURL: "")
        #expect(payload.syncedGroups == ["eclass"])
        #expect(payload.warnings.isEmpty)
        #expect(transport.requests.count == 1)
    }

    @Test func eclassCookiesAreClearedWithTheirSchoolAccount() throws {
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let state = TeachingCenterSessionState(cookieStorage: storage)
        let school = try #require(HTTPCookie(properties: [.domain: "zy-eclass.bit.edu.cn", .path: "/api",
            .name: "session", .value: "synthetic", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]))
        let other = try #require(HTTPCookie(properties: [.domain: "example.com", .path: "/",
            .name: "other", .value: "synthetic"]))
        storage.setCookie(school)
        storage.setCookie(other)
        state.clearSchoolAuthenticationCookies()
        #expect(storage.cookies?.map(\.domain) == ["example.com"])
    }

    @Test func nativeSchoolSessionRestoresEclassAndRetriesTheSnapshot() async throws {
        var pageRequests = 0
        let transport = EclassTransport { request in
            if request.url?.path == "/user/index" { return (200, "<html>课程中心</html>", nil) }
            pageRequests += 1
            return pageRequests == 1 ? (401, "", nil) : (200, #"{"courses":[],"pages":0}"#, nil)
        }
        let result = try await service(transport).fetchEclassDDLEvents()
        #expect(result.courseCount == 0)
        #expect(transport.requests.map { $0.url?.path } == ["/api/my-courses", "/user/index", "/api/my-courses"])
    }

    @Test func preflightReportsNativeSMSChallengeWithItsSharedContext() async {
        let html = #"<form action="/cas/login"><input id="login-page-flowkey" value="flow"><input id="user-object-id" value="user"><div id="secondSmsLoginForm"></div></form>"#
        let transport = EclassTransport { request in
            request.url?.path == "/user/index" ? (200, html, "https://sso.bit.edu.cn/cas/login") : (401, "", nil)
        }
        do {
            _ = try await service(transport).fetchEclassDDLEventsForPreflight()
            Issue.record("Expected a native SMS challenge")
        } catch {
            guard case ScheduleServiceError.schoolSecondFactorRequired = error else { Issue.record("Expected schoolSecondFactorRequired"); return }
        }
        #expect(transport.requests.count == 2)
    }

    private func decodeActivity(_ json: String) throws -> EclassActivity {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(EclassActivity.self, from: Data(json.utf8))
    }

    private func service(_ transport: EclassTransport, state: TeachingCenterSessionState? = nil) -> ScheduleService {
        ScheduleService(credentials: Credentials(), crypto: Crypto(), schoolSessionRestorer: Restorer(),
            teachingCenterState: state ?? TeachingCenterSessionState(cookieStorage: .sharedCookieStorage(forGroupContainerIdentifier: "BIT101ModulesTests.eclass")),
            transport: transport)
    }

    private struct Credentials: SchoolCredentialsProviding {
        let currentStudentID = "eclass-test"
        let currentPassword = "synthetic"
    }
    private struct Restorer: SchoolSessionRestoring {
        func restoreSchoolSessionIfNeeded() async throws -> String? { "synthetic" }
    }
    private struct Crypto: SchoolServiceCryptoProviding {
        let schoolURLCryptoPublicKey = "synthetic"
        let browserUserAgent = "synthetic"
        func schoolProtectedHeaders() -> [String: String] { [:] }
        func encryptSchoolURLCryptoBody(object: [String: String], publicKeyPEM: String) throws -> (body: String, encryptedKey: String, aesKey: Data) {
            ("", "", Data())
        }
        func decryptSchoolURLCryptoResponse(_ data: Data, aesKey: Data) throws -> Data { data }
    }
}

@MainActor
private final class EclassTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var maximumConcurrentRequests = 0
    private var concurrentRequests = 0
    let handler: (URLRequest) throws -> (Int, String, String?)
    init(_ handler: @escaping (URLRequest) throws -> (Int, String, String?)) { self.handler = handler }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        concurrentRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
        defer { concurrentRequests -= 1 }
        await Task.yield()
        let (status, json, redirectedURL) = try handler(request)
        let url = try #require(redirectedURL.flatMap { URL(string: $0) } ?? request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": json.hasPrefix("<") ? "text/html" : "application/json"]))
        return (Data(json.utf8), response)
    }
}
