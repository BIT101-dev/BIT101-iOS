import BIT101TestSupport
import ClientCore
import Foundation
import ScheduleDomain
import SchedulePorts
import StorageCore
import Testing
import TransportCore

@testable import ScheduleFeature
@testable import ScheduleInfrastructure

extension EclassDDLTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func malformedEclassDeadlinePreservesSource(corrupt: Bool) async throws {
        let due = corrupt ? "invalid" : "null"
        let transport = EclassTransport { request in
            switch request.url?.path {
            case "/api/my-courses":
                return (200, #"{"courses":[{"id":1,"name":"课程"}],"pages":1}"#, nil)
            case "/api/courses/1/activities":
                return (
                    200,
                    "{\"activities\":[{\"id\":42,\"submit_times\":1,\"end_time\":\"\(due)\"}]}",
                    nil
                )
            default: return (200, "BEGIN:VCALENDAR\nEND:VCALENDAR", nil)
            }
        }
        var initial = ScheduleCache()
        initial.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
        let original = DDLEventRecord(
            id: "eclass:42", group: "eclass", title: "缓存作业", text: "", dueAt: Date(), done: true)
        initial.ddlEvents = [original]
        var saved: ScheduleCache?
        let repository = ScheduleRepository(
            session: { AppStorageSession(accountIdentifier: "eclass-integrity") },
            load: { _ in .loaded(initial) }, save: { value, _, _ in saved = value })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        #expect(await model.syncDDL() == !corrupt)
        #expect(saved?.ddlEvents == (corrupt ? [original] : []))
        #expect(model.notice?.title == (corrupt ? "DDL 部分更新" : "DDL 同步成功"))
    }

    @Test(arguments: ["material", "MATERIAL"])
    func materialsWithDeadlinesAreExcludedExcluded(_ type: String) throws {
        let activity = try decodeActivity(
            #"{"id":1,"type":""# + type
                + #"","title":"资料","submit_times":1,"end_time":"2026-10-01 23:59:00"}"#)
        #expect(try activity.event(courseName: "课名") == nil)
    }

    @Test func deadlineFallbackAndBlankTitleWorkTogether() throws {
        let activity = try decodeActivity(
            #"""
            {"id":7,"title":" ","submit_times":1,"end_time":"null","visible_end_at":"2026-10-0\#
            1 23:59"}
            """#
        )
        let event = try #require(try activity.event(courseName: "课名"))
        #expect(event.title == "未命名作业")
        #expect(event.dueAt == EclassActivity.parseTime("2026-10-01 23:59"))
    }

    @Test(arguments: [
        #"{"id":1,"title":"活动","end_time":"2026-10-01 23:59"}"#,
        #"{"id":2,"submit_times":1}"#,
        #"{"id":3,"submit_times":null,"end_time":"2026-10-01 23:59"}"#,
    ])
    func activitiesRequireHomeworkIdentity(_ json: String) throws {
        #expect(try decodeActivity(json).event(courseName: "课名") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func allCoursePagesAreRequested() async throws {
        let transport = EclassTransport { request in
            if request.url?.path == "/api/my-courses" {
                let body = try #require(request.httpBody)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(json["page_size"] as? Int == 100)
                #expect(json["fields"] as? String == "id,name")
                #expect((json["conditions"] as? [String: String])?.isEmpty == true)
                return (
                    200,
                    json["page"] as? Int == 1
                        ? #"{"courses":[{"id":1,"name":"第一门"}],"page":1,"pages":2}"#
                        : #"""
                        {"courses":[{"id":1,"name":"第一门"},{"id":2,"name":"第二门"}],"page":2,"pag\#
                        es":2}
                        """#,
                    nil
                )
            }
            return (
                200,
                #"""
                {"activities":[{"id":42,"title":"作业","submit_times":1,"end_time":"2026-10-01 2\#
                3:59"}]}
                """#,
                nil
            )
        }
        let result = try await service(transport).fetchEclassDDLEvents()
        #expect(result.courseCount == 2)
        #expect(result.activityCount == 2)
        #expect(result.events.count == 1)
        #expect(result.events.first?.sourceCourseIDs == [1, 2])
        #expect(transport.requests.count == 4)
        #expect(transport.requests.allSatisfy { $0.url?.host == "zy-eclass.bit.edu.cn" })
    }

    @Test(.timeLimit(.minutes(1))) func activityRequestsHaveBoundedConcurrency() async throws {
        let transport = EclassTransport { request in
            if request.url?.path == "/api/my-courses" {
                let courses = (1...9).map { #"{"id":\#($0),"name":"course"}"# }.joined(
                    separator: ",")
                return (200, #"{"courses":["# + courses + #"],"pages":1}"#, nil)
            }
            let id = try #require(
                request.url?.path.split(separator: "/").dropLast().last.flatMap { Int($0) })
            return (
                200,
                #"""
                {"activities":[{"id":\#(id),"submit_times":1,"end_time":"2026-10-01 0\#(10-id)\#
                :00:00"}]}
                """#,
                nil
            )
        }
        let result = try await service(transport).fetchEclassDDLEvents()
        #expect(result.events.map(\.id) == (1...9).reversed().map { "eclass:\($0)" })
        #expect(transport.maximumConcurrentRequests <= 4)
        #expect(transport.maximumConcurrentRequests > 1)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            #"{"courses":[{"id":1,"name":"课"}],"page":2,"pages":2}"#,
            #"{"courses":[],"page":1,"pages":2}"#,
            #"{"courses":[{"id":0,"name":"课"}],"page":1,"pages":1}"#,
            #"{"visited_courses":[]}"#, #"{}"#,
        ])
    func incompleteCourseResponsesFailExplicitly(_ json: String) async {
        let transport = EclassTransport { _ in (200, json, nil) }
        do {
            _ = try await service(transport).fetchEclassDDLEvents()
            Issue.record("不完整课程响应需要保留业务错误。")
        } catch {
            let actual = error as NSError
            let expected = ScheduleServiceError.invalidResponse as NSError
            #expect(actual.domain == expected.domain && actual.code == expected.code)
            if json == #"{}"# || json == #"{"visited_courses":[]}"# {
                #expect(actual.userInfo[NSUnderlyingErrorKey] != nil)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func repeatedCoursePagesStopTheSync() async {
        let transport = EclassTransport { _ in
            (200, #"{"courses":[{"id":1,"name":"课"}],"pages":3}"#, nil)
        }
        await #expect(throws: ScheduleServiceError.self) {
            try await service(transport).fetchEclassDDLEvents()
        }
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["1", "3", "null"])
    func changingPageTotalsRejectTheSnapshot(total: String) async {
        var page = 0
        let transport = EclassTransport { _ in
            page += 1
            return (
                200,
                """
                {\"courses\":[{\"id\":\(page),\"name\":\"课\"}],\"page\":\(page),\"pages\":\
                \(page == 1 ? "2" : total)}
                """,
                nil
            )
        }
        await #expect(throws: ScheduleServiceError.self) {
            try await service(transport).fetchEclassDDLEvents()
        }
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func unboundedCourseFeedStopsAtBodyBudget() async throws {
        var page = 0
        let transport = EclassTransport { _ in
            page += 1
            let courses = (1...100).map { "{\"id\":\(page * 100 + $0),\"name\":\"课\"}" }.joined(
                separator: ",")
            return (200, "{\"courses\":[\(courses)]}", nil)
        }
        do {
            _ = try await service(transport).fetchEclassSnapshot(
                owner: Credentials().schoolSessionIdentity,
                budget: EclassSnapshotBudget(maximumBytes: 4_096))
            Issue.record("Expected the complete snapshot body budget to be exhausted")
        } catch {
            guard case HTTPClientError.responseTooLarge = error else {
                Issue.record("Expected responseTooLarge, got \(error)")
                return
            }
        }
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func deadlineCoversResponseStopsFurtherRequests() async {
        let transport = EclassTransport { _ in (200, #"{"courses":[],"pages":0}"#, nil) }
        transport.delay = .seconds(60)
        let budget = EclassSnapshotBudget(wait: { _ in
            try await waitForTestEvent { !transport.requests.isEmpty }
        })
        do {
            _ = try await service(transport).fetchEclassSnapshot(
                owner: Credentials().schoolSessionIdentity,
                budget: budget)
            Issue.record("Expected the complete snapshot deadline to expire")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(transport.requests.count == 1)
        #expect(
            transport.requests.first?.timeoutInterval ?? .infinity
                <= URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn")).timeoutInterval)
        #expect(transport.cancelledRequests == 1)
    }

    @Test(.timeLimit(.minutes(1))) func expiredDeadlineStops() async {
        let transport = EclassTransport { _ in
            Issue.record("Expired snapshot sent a request")
            return (200, "{}", nil)
        }
        do {
            _ = try await service(transport).fetchEclassSnapshot(
                owner: Credentials().schoolSessionIdentity,
                budget: EclassSnapshotBudget(timeout: 0))
            Issue.record("Expected the expired snapshot deadline")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(transport.requests.isEmpty && transport.cancelledRequests == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func largeMultiCourseSnapshot() async throws {
        let transport = EclassTransport { request in
            if request.url?.path == "/api/my-courses" {
                return (
                    200,
                    #"""
                    {"courses":[{"id":1,"name":"A"},{"id":2,"name":"B"},{"id":3,"name":"C"},{"\#
                    id":4,"name":"D"}],"pages":1}
                    """#,
                    nil
                )
            }
            let course = try #require(
                request.url?.path.split(separator: "/").dropLast().last.flatMap { Int($0) })
            let title = String(repeating: "x", count: 1_536)
            let activities = (1...4_096).map {
                """
                {\"id\":\(course * 10_000 + $0),\"title\":\"\(title)\",\"type\":\"homework\",\"\
                submit_times\":1,\"end_time\":\"2030-10-01T15:59:00Z\"}
                """
            }.joined(separator: ",")
            return (200, "{\"activities\":[\(activities)]}", nil)
        }
        let result = try await service(transport).fetchEclassDDLEvents()
        #expect(result.courseCount == 4 && result.activityCount == 16_384)
        #expect(result.events.count == 16_384 && result.activityTypes == ["homework": 16_384])
        #expect(result.events.map(\.id) == result.events.map(\.id).sorted())
        #expect(transport.maximumConcurrentRequests <= 4)
    }

    @Test(.timeLimit(.minutes(1))) func emptyCourseListIsAValidCompleteResult() async throws {
        let transport = EclassTransport { _ in (200, #"{"courses":[],"page":1,"pages":0}"#, nil) }
        let result = try await service(transport).fetchEclassDDLEvents()
        #expect(result.courseCount == 0)
        #expect(result.events.isEmpty)
        #expect(transport.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [401, 403, 302])
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

    @Test(.timeLimit(.minutes(1))) func redirectedLoginHTMLRequiresEclassLogin() async {
        let transport = EclassTransport { _ in
            (200, "<html>登录</html>", "https://zy-identity.bit.edu.cn/auth/")
        }
        do {
            _ = try await service(transport).fetchEclassDDLEvents()
            Issue.record("Expected authentication")
        } catch { #expect(error as? ScheduleServiceError != nil) }
    }

    @Test(.timeLimit(.minutes(1))) func failedCourseActivityRejectsSnapshot() async {
        let transport = EclassTransport { request in
            request.url?.path == "/api/my-courses"
                ? (200, #"{"courses":[{"id":1,"name":"课"}],"pages":1}"#, nil)
                : (503, "failure", nil)
        }
        await #expect(throws: ScheduleServiceError.self) {
            try await service(transport).fetchEclassDDLEvents()
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelPropagatesSourceAggregator() async {
        let transport = EclassTransport { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await service(transport).syncDDLEvents(existingEvents: [], storedURL: "")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func freshSyncDiscoversLexue(lexueFails: Bool) async throws {
        let transport = EclassTransport { request in
            switch request.url?.path {
            case "/api/my-courses":
                return (200, #"{"courses":[{"id":1,"name":"新乐学课程"}],"pages":1}"#, nil)
            case "/api/courses/1/activities":
                return (
                    200,
                    #"""
                    {"activities":[{"id":42,"title":"新乐学作业","submit_times":1,"end_time":"2030-\#
                    10-01 23:59"}]}
                    """#,
                    nil
                )
            case "/": return (200, lexueFails ? "invalid" : #"{"sesskey":"synthetic"}"#, nil)
            case "/calendar/export.php":
                return (200, #"<input value="https://lexue.bit.edu.cn/calendar.ics">"#, nil)
            default:
                return (
                    200,
                    """
                    BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:old-software\nSUMMARY:软件工程导论\nDTSTART:20\
                    301002T100000Z\nEND:VEVENT\nEND:VCALENDAR
                    """,
                    nil
                )
            }
        }
        let payload = try await service(transport).syncDDLEvents(existingEvents: [], storedURL: "")
        #expect(payload.syncedGroups == (lexueFails ? ["eclass"] : ["eclass", "lexue"]))
        #expect(payload.events.contains { $0.group == "eclass" })
        #expect(
            payload.events.contains { $0.group == "lexue" && $0.title == "软件工程导论" } == !lexueFails)
        #expect(payload.warnings.isEmpty == !lexueFails)
        #expect(transport.requests.contains { $0.url?.path == "/" })
        if !lexueFails { #expect(payload.url == "https://lexue.bit.edu.cn/calendar.ics") }
    }

    @Test func eclassCookiesAreClearedWithAccount() throws {
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let state = TeachingCenterSessionState(cookieStorage: storage)
        let school = try #require(
            HTTPCookie(properties: [
                .domain: "zy-eclass.bit.edu.cn", .path: "/api",
                .name: "session", .value: "synthetic", .secure: "TRUE",
                .expires: Date().addingTimeInterval(3600),
            ]))
        let other = try #require(
            HTTPCookie(properties: [
                .domain: "example.com", .path: "/",
                .name: "other", .value: "synthetic",
            ]))
        storage.setCookie(school)
        storage.setCookie(other)
        state.clearSchoolCookies()
        #expect(storage.cookies?.map(\.domain) == ["example.com"])
    }

    @Test(.timeLimit(.minutes(1))) func nativeSchoolSessionRestoresEclass() async throws {
        var pageRequests = 0
        let transport = EclassTransport { request in
            if request.url?.path == "/user/index" { return (200, "<html>课程中心</html>", nil) }
            pageRequests += 1
            return pageRequests == 1 ? (401, "", nil) : (200, #"{"courses":[],"pages":0}"#, nil)
        }
        let result = try await service(transport).fetchEclassDDLEvents()
        #expect(result.courseCount == 0)
        #expect(
            transport.requests.map { $0.url?.path } == [
                "/api/my-courses", "/user/index", "/api/my-courses",
            ])
    }

    @Test(.timeLimit(.minutes(1))) func preflightReportsNativeSmsContext() async {
        let html =
            #"""
            <form action="/cas/login"><input id="login-page-flowkey" value="flow"><input id="u\#
            ser-object-id" value="user"><div id="secondSmsLoginForm"></div></form>
            """#
        let transport = EclassTransport { request in
            request.url?.path == "/user/index"
                ? (200, html, "https://sso.bit.edu.cn/cas/login") : (401, "", nil)
        }
        do {
            _ = try await service(transport).probeEclassEvents()
            Issue.record("Expected a native SMS challenge")
        } catch {
            guard case ScheduleServiceError.schoolSecondFactorRequired = error else {
                Issue.record("Expected schoolSecondFactorRequired")
                return
            }
        }
        #expect(transport.requests.count == 2)
    }
}
