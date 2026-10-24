import BIT101TestSupport
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
    @Test(.timeLimit(.minutes(1)), arguments: [
        ("phone", 403), ("phone", 503), ("send", 403), ("send", 503),
        ("verify", 403), ("verify", 503), ("login", 403), ("login", 503), ("login", 200)])
    func schoolSMSServiceFailuresPreserveTheirSource(fixture: (String, Int)) async throws {
        let (failedStage, status) = fixture
        let transport = EclassTransport { request in
            let path = try #require(request.url?.path)
            let stage = path.contains("getPhoneNumber") ? "phone" : path.contains("sendSmsCode") ? "send"
                : path.contains("checkToken") ? "verify" : "login"
            if stage == failedStage {
                return (status, status == 200 ? "对不起，无权访问该资源" : #"{"code":500,"message":"upstream unavailable"}"#, nil)
            }
            return (200, stage == "phone" ? #"{"code":200,"data":{"phone":"13800000000","maskTel":"138****0000"}}"# : #"{"code":200}"#, nil)
        }
        let state = TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        let service = service(transport, state: state)
        let context = SchoolSecondFactorContext(execution: "flow", formAction: AppURL.required("https://sso.bit.edu.cn/cas/login"), userObjectID: "user")
        do {
            try await service.completeSchoolAuthentication(context) { _ in "123456" }
            Issue.record("学校短信服务故障应保留来源。")
        } catch {
            #expect(SchoolServiceFailure.from(error) == (status == 503 ? .unavailable : .accessDenied))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [(true, true), (false, true), (true, false)])
    func identitySMSCompletionRequiresTheDeclaredTicketCallback(fixture: (Bool, Bool)) async throws {
        let (validCallback, acceptingTicket) = fixture
        let transport = EclassTransport { request in
            if request.url?.path.hasSuffix("getPhoneNumberByUserId") == true {
                return (200, #"{"code":200,"data":{"phone":"13800000000","maskTel":"138****0000"}}"#, nil)
            }
            return (request.url?.path == "/cas/login" ? 302 : 200, #"{"code":200}"#, nil)
        }
        transport.responseHeaders["Location"] = validCallback
            ? "https://webvpn.bit.edu.cn/login?cas_login=true&ticket=fixture" : "https://outside.invalid/login?ticket=fixture"
        let state = TeachingCenterSessionState(cookieStorage: try #require(URLSessionConfiguration.ephemeral.httpCookieStorage))
        let service = service(transport, state: state)
        let context = SchoolSecondFactorContext(execution: "flow", formAction: AppURL.required("https://sso.bit.edu.cn/cas/login"), userObjectID: "user")
        if validCallback && acceptingTicket {
            try await service.completeSchoolAuthentication(context, acceptingServiceTicket: acceptingTicket) { _ in "123456" }
        } else {
            await #expect(throws: ScheduleServiceError.self) {
                try await service.completeSchoolAuthentication(context, acceptingServiceTicket: acceptingTicket) { _ in "123456" }
            }
        }
        #expect(transport.requests.count == 4)
        #expect(transport.requests.allSatisfy { $0.url?.host == "sso.bit.edu.cn" })
    }

    @Test(.timeLimit(.minutes(1)))
    func parallelSchoolSourcesShareOneSMSChallengeAndSubmission() async throws {
        @MainActor final class Gate { var pending: CheckedContinuation<String, Never>?; var calls = 0; var joined = false }
        let gate = Gate()
        let transport = EclassTransport { request in
            if request.url?.path.hasSuffix("getPhoneNumberByUserId") == true {
                return (200, #"{"code":200,"data":{"phone":"13800000000","maskTel":"138****0000"}}"#, nil)
            }
            return (200, #"{"code":200}"#, nil)
        }
        let service = service(transport)
        let context = SchoolSecondFactorContext(execution: "flow", formAction: AppURL.required("https://sso.bit.edu.cn/gate/cas-success"), userObjectID: "user")
        let handler: SchoolSMSCodeHandler = { _ in
            gate.calls += 1
            return await withCheckedContinuation { gate.pending = $0 }
        }
        let first = Task { try await service.completeSchoolSecondFactor(context, handler: handler, smsDeliveryMode: .send,
            owner: Credentials().schoolSessionIdentity) }
        defer { first.cancel(); gate.pending?.resume(returning: "123456"); gate.pending = nil }
        try await waitForTestEvent { gate.pending != nil }
        let second = Task {
            gate.joined = true
            try await service.completeSchoolSecondFactor(context, handler: handler, smsDeliveryMode: .send,
                owner: Credentials().schoolSessionIdentity)
        }
        defer { second.cancel() }
        try await waitForTestEvent { gate.joined }
        #expect(gate.calls == 1)
        gate.pending?.resume(returning: "123456"); gate.pending = nil
        try await first.value; try await second.value
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("sendSmsCode") == true }.count == 1)
        #expect(transport.requests.filter { $0.url?.path.hasSuffix("checkToken") == true }.count == 1)
        #expect(transport.requests.filter { $0.url?.path == "/gate/cas-success" }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["http", "parse", "timeout"])
    func partialCourseFailuresKeepTheirCacheAndUpdateTheHealthyCourses(failure: String) async throws {
        @MainActor final class State { var failing = true }
        let state = State()
        let transport = EclassTransport { request in
            switch request.url?.path {
            case "/api/my-courses": return (200, #"{"courses":[{"id":1,"name":"第一门"},{"id":2,"name":"第二门"}],"pages":1}"#, nil)
            case "/api/courses/1/activities": return (200, #"{"activities":[{"id":10,"title":"更新作业","submit_times":1,"end_time":"2030-10-01 23:59"}]}"#, nil)
            case "/api/courses/2/activities":
                guard state.failing else { return (200, #"{"activities":[]}"#, nil) }
                if failure == "timeout" { throw URLError(.timedOut) }
                if failure == "http" { return (503, "failure", nil) }
                return (200, #"{"activities":[{"id":22,"submit_times":1,"end_time":"invalid"}]}"#, nil)
            default: return (200, "BEGIN:VCALENDAR\nEND:VCALENDAR", nil)
            }
        }
        func cached(_ id: String, course: Int?) -> DDLEventRecord {
            .init(id: id, group: "eclass", title: "缓存作业", text: "", dueAt: .distantFuture, done: true,
                sourceCourseIDs: course.map { [$0] })
        }
        var cache = ScheduleCache()
        cache.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
        cache.ddlEvents = [cached("eclass:11", course: 1), cached("eclass:22", course: 2),
            cached("eclass:33", course: 3), cached("eclass:44", course: nil)]
        var saved = cache
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "partial-courses") },
            load: { _ in .loaded(cache) }, save: { value, _, _ in saved = value })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        #expect(await model.syncDDL() == false)
        #expect(Set(saved.ddlEvents.map(\.id)) == ["eclass:10", "eclass:22", "eclass:44"])
        #expect(saved.ddlEvents.first { $0.id == "eclass:22" }?.done == true)
        #expect(saved.ddlEvents.first { $0.id == "eclass:10" }?.sourceCourseIDs == [1])
        #expect(model.notice?.title == "DDL 部分更新")
        let restored = try JSONDecoder().decode(ScheduleCache.self, from: JSONEncoder().encode(saved))
        #expect(restored.ddlEvents == saved.ddlEvents)
        state.failing = false
        #expect(await model.syncDDL())
        #expect(saved.ddlEvents.map(\.id) == ["eclass:10"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["eclass", "lexue"])
    func eachDDLSourcePublishesWhileTheOtherSourceIsStillWaiting(heldSource: String) async throws {
        @MainActor final class Gate { var pending: CheckedContinuation<Void, Never>?; var held = false }
        let gate = Gate()
        let transport = EclassTransport { request in
            switch request.url?.path {
            case "/api/my-courses": return (200, #"{"courses":[{"id":1,"name":"课"}],"pages":1}"#, nil)
            case "/api/courses/1/activities": return (200, #"{"activities":[{"id":10,"title":"更新作业","submit_times":1,"end_time":"2030-10-01 23:59"}]}"#, nil)
            default: return (200, "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:new-lexue\nSUMMARY:乐学更新\nDTSTART:20301002T100000Z\nEND:VEVENT\nEND:VCALENDAR", nil)
            }
        }
        transport.beforeResponse = { request in
            if request.url?.path == (heldSource == "eclass" ? "/api/my-courses" : "/calendar.ics"), !gate.held {
                gate.held = true
                await withCheckedContinuation { gate.pending = $0 }
            }
        }
        var cache = ScheduleCache()
        cache.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
        cache.ddlEvents = [DDLEventRecord(id: "old-\(heldSource)", group: heldSource, title: "缓存作业", text: "", dueAt: .distantFuture, done: true)]
        var saved = cache, saves = 0
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "parallel-sources") },
            load: { _ in .loaded(cache) }, save: { value, _, _ in saved = value; saves += 1 })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        let work = Task { await model.syncDDL() }
        defer { work.cancel(); gate.pending?.resume(); gate.pending = nil }
        try await waitForTestEvent { gate.pending != nil && saves == 1 }
        let immediateID = heldSource == "eclass" ? "new-lexue" : "eclass:10"
        #expect(model.isSyncingDDL && saved.ddlEvents.contains { $0.id == immediateID })
        #expect(saved.ddlEvents.contains { $0.id == "old-\(heldSource)" })
        gate.pending?.resume(); gate.pending = nil
        #expect(await work.value && saves == 2)
        #expect(Set(saved.ddlEvents.map(\.id)) == ["new-lexue", "eclass:10"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelledCalendarsRemoveEventsAndUnsupportedTasksRetainTheSource(unsupported: Bool) async throws {
        let calendar = unsupported
            ? "BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:old\nSUMMARY:待办\nDUE:20301002T100000Z\nEND:VTODO\nEND:VCALENDAR"
            : "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:old\nSTATUS:CANCELLED\nEND:VEVENT\nEND:VCALENDAR"
        let transport = EclassTransport { request in
            request.url?.path == "/api/my-courses" ? (200, #"{"courses":[],"pages":0}"#, nil) : (200, calendar, nil)
        }
        let original = DDLEventRecord(id: "old", group: "lexue", title: "待办", text: "", dueAt: .distantFuture, done: false)
        var initial = ScheduleCache()
        initial.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
        initial.ddlEvents = [original]
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "calendar-status") },
            load: { _ in .loaded(initial) }, save: { cache, _, _ in saved = cache })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        #expect(await model.syncDDL() == !unsupported)
        #expect(saved?.ddlEvents == (unsupported ? [original] : []))
        let active = "BEGIN:VEVENT\nUID:old\nSUMMARY:待办\nDTSTART:20301002T100000Z\nEND:VEVENT"
        let cancelled = "BEGIN:VEVENT\nUID:old\nSTATUS:CANCELLED\nEND:VEVENT"
        for body in [active + "\n" + cancelled, cancelled + "\n" + active] {
            #expect(try ScheduleICSParser.parse("BEGIN:VCALENDAR\n\(body)\nEND:VCALENDAR").isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["identical", "course-name", "activity-title", "activity-deadline"])
    func duplicateEclassIdentityConflictsPreserveTheOwnedSource(stage: String) async throws {
        let transport = EclassTransport { request in
            if request.url?.path == "/api/my-courses" {
                let body = try #require(request.httpBody)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                if json["page"] as? Int == 1 { return (200, #"{"courses":[{"id":1,"name":"第一门"}],"page":1,"pages":2}"#, nil) }
                let name = stage == "course-name" ? "发生分歧" : "第一门"
                return (200, "{\"courses\":[{\"id\":1,\"name\":\"\(name)\"},{\"id\":2,\"name\":\"第二门\"}],\"page\":2,\"pages\":2}", nil)
            }
            if request.url?.path.hasSuffix("/activities") == true {
                let second = request.url?.path.contains("/2/") == true
                let title = second && stage == "activity-title" ? "发生分歧" : "作业"
                let deadline = second && stage == "activity-deadline" ? "2030-10-02 23:59" : "2030-10-01 23:59"
                return (200, "{\"activities\":[{\"id\":42,\"title\":\"\(title)\",\"submit_times\":1,\"end_time\":\"\(deadline)\"}]}", nil)
            }
            return (200, "BEGIN:VCALENDAR\nEND:VCALENDAR", nil)
        }
        var initial = ScheduleCache()
        initial.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
        let original = DDLEventRecord(id: "eclass:42", group: "eclass", title: "既有作业", text: "", dueAt: Date(), done: true)
        initial.ddlEvents = [original]
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "duplicate-eclass") },
            load: { _ in .loaded(initial) }, save: { value, _, _ in saved = value })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        #expect(await model.syncDDL() == (stage == "identical"))
        if stage == "identical" { #expect(saved?.ddlEvents.count == 1 && saved?.ddlEvents.first?.title == "作业") }
        else { #expect(saved?.ddlEvents == [original]) }
    }

    @Test(arguments: [
        "BEGIN:VEVENT\nUID:bad\nSUMMARY:bad\nDTSTART:invalid\nEND:VEVENT",
        "BEGIN:VEVENT\nSUMMARY:missing uid\nDTSTART:20261008T100000Z\nEND:VEVENT",
        "BEGIN:VEVENT\nUID:open\nSUMMARY:open\nDTSTART:20261008T100000Z",
        "END:VEVENT",
        "BEGIN:VEVENT\nBEGIN:VEVENT\nEND:VEVENT\nEND:VEVENT",
        "BEGIN:VEVENT\nUID:good\nSUMMARY:good\nDTSTART:20261008T100000Z\nEND:VEVENT\nBEGIN:VEVENT\nUID:bad\nSUMMARY:bad\nDTSTART:invalid\nEND:VEVENT"
    ])
    func malformedCalendarEventsRejectTheCompleteSource(body: String) {
        #expect(throws: ScheduleICSParser.ParseError.self) {
            try ScheduleICSParser.parse("BEGIN:VCALENDAR\n\(body)\nEND:VCALENDAR")
        }
    }

    @Test(arguments: ["Invalid/Zone", "\"Invalid/Zone\"", ""])
    func unrecognizedCalendarTimeZonesRejectTheCompleteSource(identifier: String) {
        let raw = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:timezone\nSUMMARY:作业\nDTSTART;TZID=\(identifier):20261008T100000\nEND:VEVENT\nEND:VCALENDAR"
        #expect(throws: ScheduleICSParser.ParseError.self) { try ScheduleICSParser.parse(raw) }
    }

    @Test(arguments: ["America/New_York", "\"America/New_York\""])
    func knownCalendarTimeZonesPreserveTheCorrectInstant(identifier: String) throws {
        let raw = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:timezone\nSUMMARY:作业\nDTSTART;TZID=\(identifier):20261008T100000\nEND:VEVENT\nEND:VCALENDAR"
        let events = try ScheduleICSParser.parse(raw)
        #expect(events.first?.dueAt == (try Date.ISO8601FormatStyle().parse("2026-10-08T14:00:00Z")))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [#"{"id":0,"name":"异常课程"}"#, #"{"id":2,"name":""}"#, #"{"id":2,"name":" "}"#])
    func mixedValidAndMalformedCoursePagesPreserveTheOwnedDeadlineSource(invalid: String) async throws {
        let transport = EclassTransport { request in
            request.url?.path == "/api/my-courses"
                ? (200, "{\"courses\":[{\"id\":1,\"name\":\"正常课程\"},\(invalid)],\"pages\":1}", nil)
                : (200, "BEGIN:VCALENDAR\nEND:VCALENDAR", nil)
        }
        var initial = ScheduleCache()
        initial.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
        let original = DDLEventRecord(id: "eclass:42", group: "eclass", title: "既有作业", text: "", dueAt: Date(), done: true)
        initial.ddlEvents = [original]
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "course-integrity") },
            load: { _ in .loaded(initial) }, save: { value, _, _ in saved = value })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        #expect(await model.syncDDL() == false)
        #expect(saved?.ddlEvents == [original])
        #expect(model.notice?.title == "DDL 部分更新")
        #expect(transport.requests.count == 2)
    }

    @Test func calendarAlarmPropertiesKeepTheirOwnComponentScope() throws {
        let events = try ScheduleICSParser.parse("""
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:scoped-event
        SUMMARY:课程作业
        DTSTART:20261008T100000Z
        BEGIN:VALARM
        SUMMARY:提醒
        TRIGGER:-PT10M
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """)
        #expect(events.count == 1 && events.first?.title == "课程作业")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func realDDLSourceRetainsCorruptLexueDataAndClearsAValidEmptyCalendar(corrupt: Bool) async throws {
        let calendar = corrupt ? "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:bad\nSUMMARY:bad\nDTSTART:invalid\nEND:VEVENT\nEND:VCALENDAR"
            : "BEGIN:VCALENDAR\nEND:VCALENDAR"
        let transport = EclassTransport { request in
            request.url?.path == "/api/my-courses" ? (200, #"{"courses":[],"pages":0}"#, nil) : (200, calendar, nil)
        }
        var initial = ScheduleCache()
        let lexue = DDLEventRecord(id: "lexue-owned", group: "lexue", title: "cached", text: "", dueAt: Date(), done: true)
        initial.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
        initial.ddlEvents = [lexue]
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "ics-source") },
            load: { _ in .loaded(initial) }, save: { value, _, _ in saved = value })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        #expect(await model.syncDDL() == !corrupt)
        #expect(saved?.ddlEvents == (corrupt ? [lexue] : []))
        #expect(model.notice?.title == (corrupt ? "DDL 部分更新" : "DDL 同步成功"))
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["RRULE:FREQ=DAILY;COUNT=2", "EXDATE:20261008T100000Z", "RECURRENCE-ID:20261009T100000Z"])
    func unsupportedCalendarRecurrencePreservesTheOwnedDeadlineSource(property: String) async throws {
        let calendar = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:recurring\nSUMMARY:作业\nDTSTART:20261008T100000Z\n\(property)\nEND:VEVENT\nEND:VCALENDAR"
        let transport = EclassTransport { request in
            request.url?.path == "/api/my-courses" ? (200, #"{"courses":[],"pages":0}"#, nil) : (200, calendar, nil)
        }
        var initial = ScheduleCache()
        initial.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
        let original = DDLEventRecord(id: "lexue-owned", group: "lexue", title: "cached", text: "", dueAt: Date(), done: true)
        initial.ddlEvents = [original]
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "recurrence") },
            load: { _ in .loaded(initial) }, save: { value, _, _ in saved = value })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        #expect(await model.syncDDL() == false)
        #expect(saved?.ddlEvents == [original])
        #expect(model.notice?.title == "DDL 部分更新")
    }

    @Test(.timeLimit(.minutes(1))) func productionDDLServicePersistsAndReloadsTheOwnedSourceWithCompletion() async throws {
        let transport = EclassTransport { request in
            if request.url?.path == "/calendar.ics" { return (200, "BEGIN:VCALENDAR\nEND:VCALENDAR", nil) }
            return request.url?.path == "/api/my-courses"
                ? (200, #"{"courses":[{"id":1,"name":"操作系统"}],"pages":1}"#, nil)
                : (200, #"{"activities":[{"id":42,"title":"新版作业","submit_times":1,"end_time":"2030-10-01T15:59:00Z"},{"id":43,"type":"material","title":"资料","end_time":"2030-10-01 23:59:00"}]}"#, nil)
        }
        var initial = ScheduleCache()
        initial.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
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
        #expect(reopened.visibleDDLEvents().map(\.id).contains("eclass:42"))
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
        let event = try #require(try activity.event(courseName: "操作系统"))
        #expect(event.id == "eclass:42")
        #expect(event.group == "eclass")
        #expect(event.title == "作业")
        #expect(event.text == "操作系统")
        #expect(event.isSchoolSynced)
        #expect(event.sourceTitle == "课程中心")
    }

    @Test(arguments: [
        #"{"id":1,"submit_times":1,"end_time":"invalid"}"#,
        #"{"id":2,"submit_times":1,"end_time":"invalid","visible_end_at":"2026-10-01 23:59"}"#,
        #"{"id":3,"submit_times":1,"visible_end_at":"2026-02-30 12:00"}"#,
        #"{"id":0,"submit_times":1,"end_time":"2026-10-01 23:59"}"#
    ])
    func providedMalformedHomeworkFieldsRejectTheActivity(json: String) throws {
        let activity = try decodeActivity(json)
        #expect(throws: ScheduleServiceError.self) { try activity.event(courseName: "课程") }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func malformedEclassDeadlinePreservesTheCompleteOwnedSource(corrupt: Bool) async throws {
        let deadline = corrupt ? "invalid" : "null"
        let transport = EclassTransport { request in
            switch request.url?.path {
            case "/api/my-courses": return (200, #"{"courses":[{"id":1,"name":"课程"}],"pages":1}"#, nil)
            case "/api/courses/1/activities": return (200, "{\"activities\":[{\"id\":42,\"submit_times\":1,\"end_time\":\"\(deadline)\"}]}", nil)
            default: return (200, "BEGIN:VCALENDAR\nEND:VCALENDAR", nil)
            }
        }
        var initial = ScheduleCache()
        initial.lexueCalendarURL = "https://lexue.bit.edu.cn/calendar.ics"
        let original = DDLEventRecord(id: "eclass:42", group: "eclass", title: "缓存作业", text: "", dueAt: Date(), done: true)
        initial.ddlEvents = [original]
        var saved: ScheduleCache?
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "eclass-integrity") },
            load: { _ in .loaded(initial) }, save: { value, _, _ in saved = value })
        await repository.loadIfNeeded()
        let model = ScheduleDDLViewModel(service: service(transport), repository: repository)
        #expect(await model.syncDDL() == !corrupt)
        #expect(saved?.ddlEvents == (corrupt ? [original] : []))
        #expect(model.notice?.title == (corrupt ? "DDL 部分更新" : "DDL 同步成功"))
    }

    @Test(arguments: ["material", "MATERIAL"])
    func materialsWithDeadlinesAndHomeworkFieldsAreExcluded(_ type: String) throws {
        let activity = try decodeActivity(#"{"id":1,"type":""# + type + #"","title":"资料","submit_times":1,"end_time":"2026-10-01 23:59:00"}"#)
        #expect(try activity.event(courseName: "课名") == nil)
    }

    @Test func deadlineFallbackAndBlankTitleWorkTogether() throws {
        let activity = try decodeActivity(#"{"id":7,"title":" ","submit_times":1,"end_time":"null","visible_end_at":"2026-10-01 23:59"}"#)
        let event = try #require(try activity.event(courseName: "课名"))
        #expect(event.title == "未命名作业")
        #expect(event.dueAt == EclassActivity.parseTime("2026-10-01 23:59"))
    }

    @Test(arguments: [#"{"id":1,"title":"活动","end_time":"2026-10-01 23:59"}"#,
                      #"{"id":2,"submit_times":1}"#,
                      #"{"id":3,"submit_times":null,"end_time":"2026-10-01 23:59"}"#])
    func activitiesRequireHomeworkIdentityAndDeadline(_ json: String) throws {
        #expect(try decodeActivity(json).event(courseName: "课名") == nil)
    }

    @Test(.timeLimit(.minutes(1))) func allCoursePagesAreRequestedAndDuplicatesAreMerged() async throws {
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
        #expect(result.events.first?.sourceCourseIDs == [1, 2])
        #expect(transport.requests.count == 4)
        #expect(transport.requests.allSatisfy { $0.url?.host == "zy-eclass.bit.edu.cn" })
    }

    @Test(.timeLimit(.minutes(1))) func activityRequestsHaveBoundedConcurrencyAndGlobalOrdering() async throws {
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

    @Test(.timeLimit(.minutes(1)), arguments: [#"{"courses":[{"id":1,"name":"课"}],"page":2,"pages":2}"#,
                      #"{"courses":[],"page":1,"pages":2}"#,
                      #"{"courses":[{"id":0,"name":"课"}],"page":1,"pages":1}"#,
                      #"{"visited_courses":[]}"#, #"{}"#])
    func incompleteCourseResponsesFailExplicitly(_ json: String) async {
        let transport = EclassTransport { _ in (200, json, nil) }
        do {
            _ = try await service(transport).fetchEclassDDLEvents()
            Issue.record("不完整课程响应需要保留业务错误。")
        } catch {
            let actual = error as NSError, expected = ScheduleServiceError.invalidResponse as NSError
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
        await #expect(throws: ScheduleServiceError.self) { try await service(transport).fetchEclassDDLEvents() }
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["1", "3", "null"])
    func changingPageTotalsRejectTheSnapshot(total: String) async {
        var page = 0
        let transport = EclassTransport { _ in
            page += 1
            return (200, "{\"courses\":[{\"id\":\(page),\"name\":\"课\"}],\"page\":\(page),\"pages\":\(page == 1 ? "2" : total)}", nil)
        }
        await #expect(throws: ScheduleServiceError.self) { try await service(transport).fetchEclassDDLEvents() }
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func anUnboundedCourseFeedStopsAtTheSharedBodyBudget() async throws {
        var page = 0
        let transport = EclassTransport { _ in
            page += 1
            let courses = (1 ... 100).map { "{\"id\":\(page * 100 + $0),\"name\":\"课\"}" }.joined(separator: ",")
            return (200, "{\"courses\":[\(courses)]}", nil)
        }
        do {
            _ = try await service(transport).fetchEclassSnapshot(owner: Credentials().schoolSessionIdentity,
                                                                budget: EclassSnapshotBudget(maximumBytes: 4_096))
            Issue.record("Expected the complete snapshot body budget to be exhausted")
        } catch {
            guard case HTTPClientError.responseTooLarge = error else { Issue.record("Expected responseTooLarge, got \(error)"); return }
        }
        #expect(transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func theDeadlineCoversTheResponseAndStopsFurtherRequests() async {
        let transport = EclassTransport { _ in (200, #"{"courses":[],"pages":0}"#, nil) }
        transport.delay = .seconds(60)
        let budget = EclassSnapshotBudget(wait: { _ in
            try await waitForTestEvent { !transport.requests.isEmpty }
        })
        do {
            _ = try await service(transport).fetchEclassSnapshot(owner: Credentials().schoolSessionIdentity,
                                                                budget: budget)
            Issue.record("Expected the complete snapshot deadline to expire")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.timeoutInterval ?? .infinity <= URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn")).timeoutInterval)
        #expect(transport.cancelledRequests == 1)
    }

    @Test(.timeLimit(.minutes(1))) func expiredDeadlineStopsBeforeSendingAnyRequest() async {
        let transport = EclassTransport { _ in Issue.record("Expired snapshot sent a request"); return (200, "{}", nil) }
        do {
            _ = try await service(transport).fetchEclassSnapshot(owner: Credentials().schoolSessionIdentity,
                budget: EclassSnapshotBudget(timeout: 0))
            Issue.record("Expected the expired snapshot deadline")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(transport.requests.isEmpty && transport.cancelledRequests == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func largeMultiCoursePayloadsProduceACompleteOrderedSnapshot() async throws {
        let transport = EclassTransport { request in
            if request.url?.path == "/api/my-courses" {
                return (200, #"{"courses":[{"id":1,"name":"A"},{"id":2,"name":"B"},{"id":3,"name":"C"},{"id":4,"name":"D"}],"pages":1}"#, nil)
            }
            let course = try #require(request.url?.path.split(separator: "/").dropLast().last.flatMap { Int($0) })
            let title = String(repeating: "x", count: 1_536)
            let activities = (1 ... 4_096).map {
                "{\"id\":\(course * 10_000 + $0),\"title\":\"\(title)\",\"type\":\"homework\",\"submit_times\":1,\"end_time\":\"2030-10-01T15:59:00Z\"}"
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
        let transport = EclassTransport { _ in (200, "<html>登录</html>", "https://zy-identity.bit.edu.cn/auth/") }
        do { _ = try await service(transport).fetchEclassDDLEvents(); Issue.record("Expected authentication") }
        catch { #expect(error as? ScheduleServiceError != nil) }
    }

    @Test(.timeLimit(.minutes(1))) func failedCourseActivityRejectsTheCompleteSnapshot() async {
        let transport = EclassTransport { request in
            request.url?.path == "/api/my-courses"
                ? (200, #"{"courses":[{"id":1,"name":"课"}],"pages":1}"#, nil)
                : (503, "failure", nil)
        }
        await #expect(throws: ScheduleServiceError.self) { try await service(transport).fetchEclassDDLEvents() }
    }

    @Test(.timeLimit(.minutes(1))) func cancellationPropagatesThroughTheSourceAggregator() async {
        let transport = EclassTransport { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await service(transport).syncDDLEvents(existingEvents: [], storedURL: "")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func freshSyncDiscoversLexueAndCombinesBothSources(lexueFails: Bool) async throws {
        let transport = EclassTransport { request in
            switch request.url?.path {
            case "/api/my-courses": return (200, #"{"courses":[{"id":1,"name":"新乐学课程"}],"pages":1}"#, nil)
            case "/api/courses/1/activities": return (200, #"{"activities":[{"id":42,"title":"新乐学作业","submit_times":1,"end_time":"2030-10-01 23:59"}]}"#, nil)
            case "/": return (200, lexueFails ? "invalid" : #"{"sesskey":"synthetic"}"#, nil)
            case "/calendar/export.php": return (200, #"<input value="https://lexue.bit.edu.cn/calendar.ics">"#, nil)
            default: return (200, "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:old-software\nSUMMARY:软件工程导论\nDTSTART:20301002T100000Z\nEND:VEVENT\nEND:VCALENDAR", nil)
            }
        }
        let payload = try await service(transport).syncDDLEvents(existingEvents: [], storedURL: "")
        #expect(payload.syncedGroups == (lexueFails ? ["eclass"] : ["eclass", "lexue"]))
        #expect(payload.events.contains { $0.group == "eclass" })
        #expect(payload.events.contains { $0.group == "lexue" && $0.title == "软件工程导论" } == !lexueFails)
        #expect(payload.warnings.isEmpty == !lexueFails)
        #expect(transport.requests.contains { $0.url?.path == "/" })
        if !lexueFails { #expect(payload.url == "https://lexue.bit.edu.cn/calendar.ics") }
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

    @Test(.timeLimit(.minutes(1))) func nativeSchoolSessionRestoresEclassAndRetriesTheSnapshot() async throws {
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

    @Test(.timeLimit(.minutes(1))) func preflightReportsNativeSMSChallengeWithItsSharedContext() async {
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
        var schoolSessionIdentity: SchoolSessionIdentity { .init(accountIdentifier: currentStudentID, generation: 0) }
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
    var responseHeaders: [String: String] = [:]
    var maximumConcurrentRequests = 0
    private var concurrentRequests = 0
    var delay: Duration = .zero
    var cancelledRequests = 0
    var beforeResponse: ((URLRequest) async throws -> Void)?
    let handler: (URLRequest) throws -> (Int, String, String?)
    init(_ handler: @escaping (URLRequest) throws -> (Int, String, String?)) { self.handler = handler }
    func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
        return result
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        concurrentRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
        defer { concurrentRequests -= 1 }
        await Task.yield()
        try await beforeResponse?(request)
        if delay > .zero {
            do { try await Task.sleep(for: delay) }
            catch is CancellationError { cancelledRequests += 1; throw CancellationError() }
        }
        let (status, json, redirectedURL) = try handler(request)
        let url = try #require(redirectedURL.flatMap { URL(string: $0) } ?? request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: responseHeaders.merging(["Content-Type": json.hasPrefix("<") ? "text/html" : "application/json"]) { _, value in value }))
        return (Data(json.utf8), response)
    }
}
