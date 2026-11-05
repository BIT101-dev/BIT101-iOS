#if RELEASE_NETWORK_SMOKE
import XCTest
@testable import BIT101_iOS

/// 发布前真机网络验收测试。
///
/// 测试根据编译条件或 `BIT101_NETWORK_SMOKE_SCOPE` 选择 smoke 范围，调用共享 runner。
/// 采样宿主的当前登录态网络验收通过 `bit101://network-smoke/...` 在主进程内触发同一 runner。
nonisolated final class ReleaseNetworkSmokeTests: XCTestCase {
    @MainActor var scope: NetworkSmokeScope? {
        #if SMOKE_BIT101
        return .bit101
        #elseif SMOKE_SCHOOL
        return .school
        #else
        let rawValue =
            ProcessInfo.processInfo.environment["BIT101_NETWORK_SMOKE_SCOPE"] ?? "all"
        return NetworkSmokeScope(rawValue: rawValue)
        #endif
    }

    @MainActor
    func testReleaseNetworkFlows() async {
        guard let scope else {
            XCTFail("BIT101_NETWORK_SMOKE_SCOPE 无效")
            return
        }
        guard
            let request = ReleaseNetworkSmokeLaunchRequest(
                scope: scope, environment: ProcessInfo.processInfo.environment)
        else {
            XCTFail("网络 Smoke 环境参数需要有效的采样、课程、维护对象及专用账号配置")
            return
        }
        let report = await ReleaseNetworkSmokeRunner().run(
            scope: request.scope, runID: request.runID,
            capture: request.capture, term: request.term,
            communityFollowTarget: request.communityFollowTarget,
            communityExpectedAccount: request.communityExpectedAccount,
            communityRecoveryConfirmation: request.communityRecoveryConfirmation,
            fixtures: request.fixtures)
        XCTAssertEqual(report.scope, scope)
        XCTAssertTrue(Set(report.executedProbes).isSuperset(of: scope.requiredProbes))
        XCTAssertTrue(report.passed, report.failureMessage)
        XCTAssertTrue(report.coverageComplete, report.failureMessage)
    }
}
#endif

#if DEBUG
import Darwin
import Foundation
import Testing
import ClientCore
import ScoreDomain
import ScorePorts
import CommunityCore
import CommunityTransport
import ScheduleDomain
import SchedulePorts
import TransportCore
import StorageCore
@testable import GalleryFeature
@testable import PaperFeature
@testable import MineFeature
@testable import ScheduleInfrastructure
import CourseFeature
import UIKit
import MediaKit
@testable import BIT101_iOS

@Suite("Network smoke lifecycle")
@MainActor
struct ReleaseNetworkSmokeLifecycleTests {
    @Test func homepageRequiresVisibleBodyBootstrap() throws {
        let bootstrap =
            #"""
            <html><head><title>BIT101</title><script type="module" src="/assets/index.js">\#
            </script></head><body><div id="app"></div></body></html>
            """#
        try NetworkSmokeHTML.validate(bootstrap, appURL: nil)
        for invalid in [
            bootstrap.replacingOccurrences(of: "type=\"module\"", with: "type=\"text/plain\""),
            bootstrap.replacingOccurrences(of: "id=\"app\"", with: "id=\"other\""),
            bootstrap.replacingOccurrences(of: "id=\"app\"", with: "id=\"app\" hidden"),
            bootstrap.replacingOccurrences(
                of: "/assets/index.js", with: "//unrelated.invalid/index.js"),
            "<html><title>BIT101</title><body><div hidden>内容</div></body></html>",
        ] {
            #expect(throws: URLError.self) {
                try NetworkSmokeHTML.validate(invalid, appURL: nil)
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func unsentCreationReleasesItsRecoveryAttempt() async throws {
        let world = CommunityWorld(stage: "unsent-poster")
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        }
        #expect(world.pending == nil && Set(world.contents.keys) == ["poster77", "course1"])
        world.stage = "success"
        _ = try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        #expect(world.pending == nil)
    }
    @Test(.timeLimit(.minutes(1))) func productionSubmissionSeparatesFailure() async throws {
        let route = MissingRoute()
        let observer = AdmissionObserver()
        let client = HTTPClient(transport: route, observer: observer)
        let request = URLRequest(url: AppURL.required("https://example.invalid/probe"))
        await #expect(throws: CommunityWriteSmoke.SubmissionNotSent.self) {
            try await CommunityWriteSmoke.Operations.submission {
                _ = try await client.send(request)
            }
        }
        observer.reject = false
        await #expect(throws: HTTPClientError.self) {
            try await CommunityWriteSmoke.Operations.submission {
                _ = try await client.send(request)
            }
        }
        await #expect(throws: CommunityWriteSmoke.SubmissionNotSent.self) {
            try await CommunityWriteSmoke.Operations.submission { throw CancellationError() }
        }
    }

    @Test(.timeLimit(.minutes(1))) func connectionFailureReleasesPersistedAttempt() async throws {
        let world = CommunityWorld(stage: "success")
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(socket >= 0)
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socket, $0, &length)
            }
        }
        try #require(queried == 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 5
        let session = URLSessionTransport.make(configuration: configuration)
        let client = HTTPClient(transport: session, observer: nil)
        var request = URLRequest(
            url: AppURL.required(
                "https://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/create"))
        request.httpMethod = "POST"
        var operations = world.operations
        operations.create = { _, _, _, submit in
            try await CommunityWriteSmoke.Operations.submission {
                try submit()
                _ = try await client.send(request)
                return 1
            }
        }
        let smoke = CommunityWriteSmoke(
            operations: operations, load: { world.pending }, save: { world.pending = $0 })
        await #expect(throws: (any Error).self) {
            try await smoke.run(marker: "fixture", expectedAccount: 1)
        }
        #expect(world.pending == nil && Set(world.contents.keys) == ["poster77", "course1"])
        _ = try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        #expect(world.pending == nil)
    }

    final class AdmissionObserver: HTTPClientObserving {
        var reject = true
        func willSend(_ request: URLRequest) async throws {
            if reject { throw URLError(.notConnectedToInternet) }
        }
        func didFinish(
            request: URLRequest, finalRequest: URLRequest?, data: Data?, response: URLResponse?,
            error: (any Error)?, elapsed: TimeInterval
        ) async {}
    }
    func correctedSchedulePayload(
        courses: [CourseRecord]? = nil, date: String = "2026-11-09"
    ) throws -> CourseSyncPayload {
        let rows: [[String: Any]] = (1...2).map { index in
            [
                "KCH": "course-\(index)", "KCM": "课程\(index)", "SKXQ": index, "KSJC": 1,
                "JSJC": 2,
                "SKZC": "00011", "ZCMC": "1-2周", "YPSJDD": "1-2周",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "datas": ["cxxszhxqkb": ["rows": rows]]
        ])
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)
        return CourseSyncPayload(
            term: "2026-2027-1", firstDayString: date, sourceFirstDayString: "2026-10-19",
            normalizationOffset: 3, rawWeeksByCourse: response.parsedCourses.map(\.rawWeeks),
            sourceDisplayWeeksByCourse: response.datas.cxxszhxqkb.rows.map(\.displayWeeks),
            courses: courses ?? response.courseRecords, exams: [])
    }

    @Test func smokeUsesSchoolDatesTransitions() throws {
        let original = NSTimeZone.default
        NSTimeZone.default = try #require(TimeZone(identifier: "America/New_York"))
        defer { NSTimeZone.default = original }
        try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(correctedSchedulePayload())
    }

    @Test func smokeRejectsIncorrectPublishedWeeks() throws {
        let payload = try correctedSchedulePayload()
        let wrongWeeks = payload.courses.map { $0.replacingWeeks([4, 5]) }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(
                correctedSchedulePayload(courses: wrongWeeks))
        }
        let truncatedWeeks = payload.courses.map { $0.replacingWeeks([1]) }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(
                correctedSchedulePayload(courses: truncatedWeeks))
        }
        #expect(throws: NSError.self) {
            try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(
                correctedSchedulePayload(date: "2026-11-08"))
        }
    }

    @Test(arguments: [
        #"{"KCM":"课程","SKXQ":8,"KSJC":1,"JSJC":2,"ZCMC":"1周"}"#,
        #"{"KCM":"课程","SKXQ":1,"KSJC":0,"JSJC":2,"ZCMC":"1周"}"#,
        #"{"KCM":"课程","SKXQ":1,"KSJC":1,"JSJC":2}"#, #"{}"#, #"{"KCM":"  "}"#,
    ])
    func smokeRejectsIncompleteCoursePlacements(_ row: String) throws {
        let response = try JSONDecoder().decode(
            CourseResponse.self,
            from: Data((#"{"datas":{"cxxszhxqkb":{"rows":["# + row + #"]}}}"#).utf8))
        let payload = CourseSyncPayload(
            term: "2026-2027-1", firstDayString: "2026-09-28",
            sourceFirstDayString: "2026-09-28",
            normalizationOffset: 0, rawWeeksByCourse: response.parsedCourses.map(\.rawWeeks),
            courses: response.courseRecords, exams: [])
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload)
        }
    }

    @Test func pendingCoursesKeepDistinctIdentities() throws {
        let rows: [[String: String]] = [
            ["KCM": "课程甲", "SKJS": "教师甲"], ["KCM": "课程甲", "SKJS": "教师乙"],
            ["KCM": "课程乙"], ["KCH": "CS101", "KCM": "  "],
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "datas": ["cxxszhxqkb": ["rows": rows]]
        ])
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)
        let courses = response.courseRecords
        #expect(Set(courses.map(\.id)).count == 4)
        #expect(courses.map(\.name) == ["课程甲", "课程甲", "课程乙", "CS101"])
        #expect(courses[0].id.contains(scheduleCourseIdentity(courses[0])))
        func payload(_ records: [CourseRecord]) -> CourseSyncPayload {
            CourseSyncPayload(
                term: "2026-2027-1", firstDayString: "2026-09-28",
                sourceFirstDayString: "2026-09-28",
                normalizationOffset: 0, rawWeeksByCourse: records.map(\.weeks),
                sourceDisplayWeeksByCourse: records.map { _ in nil }, courses: records,
                exams: [])
        }
        try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload(courses))
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(
                payload(courses + [courses[0]]))
        }
    }

    @Test(arguments: ["课程名称", "课程编号", "成绩", "学分"])
    func scoreSmokeRequiresTheStatisticalFields(_ missingField: String) throws {
        let fields = [("课程名称", "课程甲"), ("课程编号", "CS101"), ("成绩", "90"), ("学分", "2")]
        let full = ScoreRow(index: 0, headers: fields.map { $0.0 }, values: fields.map { $0.1 })
        try NetworkSmokePaging.checkScores(brief: [full], detailed: [full])
        #expect(ScoreSummary.make(from: [full]).totalCredit == 2)
        let missing = fields.filter { $0.0 != missingField }
        let row = ScoreRow(
            index: 0, headers: missing.map { $0.0 }, values: missing.map { $0.1 })
        #expect(throws: URLError.self) {
            try NetworkSmokePaging.checkScores(brief: [row], detailed: [row])
        }
        #expect(throws: URLError.self) {
            try NetworkSmokePaging.checkScores(brief: [full], detailed: [row])
        }
    }

    @Test(arguments: [0, 2, 3, 4])
    func smokeUsesTheSmallTermCorrectionPolicy(rawOffset: Int) throws {
        var rows: [[String: Any]] = (1...2).map { index in
            [
                "KCH": "course-\(index)", "KCM": "课程\(index)", "SKXQ": index, "KSJC": 1,
                "JSJC": 2,
                "SKZC": String(repeating: "0", count: rawOffset) + "11", "ZCMC": "1-2周",
                "YPSJDD": "1-2周",
            ]
        }
        rows.append([
            "KCH": "ordinary", "KCM": "普通课程", "SKXQ": 3, "KSJC": 1, "JSJC": 2,
            "SKZC": "11", "ZCMC": "1-2周", "YPSJDD": "",
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "datas": ["cxxszhxqkb": ["rows": rows]]
        ])
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)
        let rawWeeks = response.parsedCourses.map(\.rawWeeks)
        #expect(
            response.courseRecords.count == 3 && response.courseRecords.last?.description == "")
        let normalized = SmallTermWeekNormalizer.normalize(
            term: "2026-2027-1", firstDayString: "2026-09-07",
            courses: response.courseRecords, rawWeeksByCourse: rawWeeks)
        let expectedOffset = rawOffset == 3 ? 3 : 0
        #expect(normalized.offset == expectedOffset)
        #expect(normalized.firstDayString == (rawOffset == 3 ? "2026-09-28" : "2026-09-07"))
        let payload = CourseSyncPayload(
            term: "2026-2027-1", firstDayString: normalized.firstDayString,
            sourceFirstDayString: "2026-09-07", normalizationOffset: normalized.offset,
            rawWeeksByCourse: rawWeeks,
            sourceDisplayWeeksByCourse: response.datas.cxxszhxqkb.rows.map(\.displayWeeks),
            courses: normalized.courses, exams: [])
        try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload)
        let inconsistent = CourseSyncPayload(
            term: payload.term, firstDayString: payload.firstDayString,
            sourceFirstDayString: payload.sourceFirstDayString,
            normalizationOffset: expectedOffset == 0 ? 3 : 0,
            rawWeeksByCourse: rawWeeks,
            sourceDisplayWeeksByCourse: payload.sourceDisplayWeeksByCourse,
            courses: payload.courses, exams: [])
        #expect(throws: NSError.self) {
            try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(inconsistent)
        }
    }

    @Test(arguments: [
        #"<link rel="stylesheet" href="https://resource.invalid/style.css">"#,
        #"<span style="background-image:url(https://resource.invalid/image.png)">文字</span>"#,
        #"""
        <body background="https://resource.invalid/image.png"><svg><image href="https://re\#
        source.invalid/a.svg"/></svg></body>
        """#,
        #"<img src="https://resource.invalid/image.png""#,
    ])
    func articleHtmlKeepsInlineFormatting(_ resource: String) {
        let html =
            #"<strong>正文</strong><a href="https://example.org/article">链接</a>"# + resource
        let safe = PaperContentRenderer.sanitizedHTML(html)
        #expect(!safe.contains("resource.invalid") && !safe.contains("style="))
        #expect(safe.contains("<strong>正文</strong>"))
        let text = PaperContentRenderer.attributedText(from: html)
        #expect(
            String(text.characters).contains("正文") && String(text.characters).contains("链接"))
        #expect(text.runs.contains { $0.link?.absoluteString == "https://example.org/article" })
    }

    final class PaperWrites: HTTPTransport {
        var content = ""
        var methods: [String] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let method = try #require(request.httpMethod)
            if url.path == "/user/check" {
                return (
                    Data(),
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            }
            methods.append(method)
            let response: Data
            if method == "GET" {
                let user: [String: Any] = [
                    "id": 1, "create_time": "", "nickname": "功能验收", "motto": "",
                    "avatar": ["mid": "", "url": "", "low_url": ""],
                    "identity": [
                        "id": 1, "color": "", "text": "", "create_time": "", "update_time": "",
                    ],
                ]
                response = try JSONSerialization.data(withJSONObject: [
                    "id": 1, "title": "功能验收", "intro": "功能验收",
                    "content": content, "create_time": "",
                    "update_time": "2026-10-01T08:00:00Z", "update_user": user,
                    "anonymous": false, "like_num": 0, "comment_num": 0, "public_edit": false,
                    "like": false, "own": true,
                ])
            } else {
                let body = try #require(request.httpBody)
                let payload = try #require(
                    JSONSerialization.jsonObject(with: body) as? [String: Any])
                content = try #require(payload["content"] as? String)
                if method == "PUT" { #expect(payload["last_time"] as? Double == 1_790_841_600) }
                let editor = try #require(
                    JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
                let blocks = try #require(editor["blocks"] as? [[String: Any]])
                #expect(blocks.allSatisfy { $0["type"] as? String == "paragraph" })
                response = method == "POST" ? Data(#"{"id":1}"#.utf8) : Data()
            }
            return (
                response,
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1))) func onlineArticleValidationUsesEditorFormat() async throws {
        let transport = PaperWrites()
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture")
            }, refresh: { _ in })
        let operations = CommunityWriteSmoke.Operations.production(
            papers: PaperService(session: session))
        let text = "功能验收 <正文> & 内容\n第二行"
        let id = try await operations.create(.paper, text, { _ in }, {})
        #expect(try await operations.read(.paper, id)?.text == text)
        try await operations.edit(.paper, id, text + " 编辑")
        #expect(try await operations.read(.paper, id)?.text == text + " 编辑")
        #expect(transport.methods == ["POST", "GET", "GET", "PUT", "GET"])
    }

    final class CourseWrites: HTTPTransport {
        var comments = 0
        var courseNumber = "fixture"
        var paths: [String] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            paths.append(url.path)
            if request.httpMethod == "GET" {
                let data = try JSONSerialization.data(withJSONObject: [
                    "id": 42, "name": "fixture", "number": courseNumber,
                    "like_num": 0, "comment_num": 0, "rate": 0, "teachers_name": "",
                    "teachers_number": "", "like": false,
                ])
                return (
                    data,
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            }
            let body = try #require(request.httpBody)
            let payload = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(payload["obj"] as? String == "course42" && payload["rate"] as? Int == 6)
            comments += 1
            let response = Data(
                #"""
                {"id":1,"obj":"course42","images":[],"user":{"id":1,"nickname":"功能验收","ava\#
                tar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":1,"color\#
                ":"","text":"","create_time":"","update_time":""},"create_time":""},"anony\#
                mous":false,"create_time":"","update_time":"","like":false,"like_num":0,"c\#
                omment_num":0,"own":true,"rate":6,"reply_user":{"id":1,"nickname":"功能验收","\#
                avatar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":1,"co\#
                lor":"","text":"","create_time":"","update_time":""},"create_time":""},"re\#
                ply_obj":"","text":"功能验收","sub":[]}
                """#
                .utf8)
            return (
                response,
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1))) func onlineCourseReviewIncludesRequiredRating() async throws {
        let transport = CourseWrites()
        let session = CommunitySession(
            httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture")
            }, refresh: { _ in })
        let operations = CommunityWriteSmoke.Operations.production(
            courses: CourseService(session: session))
        let comment = try await operations.comment(
            .init(kind: .course, object: "course42"), "功能验收", { _ in }, {})
        #expect(comment.rate == 6 && transport.comments == 1)
    }

    @Test(.timeLimit(.minutes(1))) func writeCourseTargetUsesItsMaintainedIdentity()
        async throws
    {
        let route = CourseWrites()
        let session = CommunitySession(
            httpClient: HTTPClient(transport: route, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture")
            }, refresh: { _ in })
        let fixture = NetworkSmokeFixtures(
            posterID: 1, courseID: 42, courseNumber: "fixture", paperID: 1)
        let operations = CommunityWriteSmoke.Operations.production(
            courses: CourseService(session: session), courseFixture: fixture)
        #expect(try await operations.course() == 42)
        route.courseNumber = "other"
        await #expect(throws: URLError.self) { try await operations.course() }
        let missing = CommunityWriteSmoke.Operations.production(
            courses: CourseService(session: session))
        await #expect(throws: URLError.self) { try await missing.course() }
        #expect(route.paths == ["/courses/42", "/courses/42"] && route.comments == 0)
    }

    @Test func resourceRecoveryConsumesFailures() {
        #expect(
            CommunityWriteSmoke.Operations.isMissingContent(
                PaperServiceError.missingPaper, kind: .paper))
        #expect(
            CommunityWriteSmoke.Operations.isMissingContent(
                GalleryServiceError.missingPoster, kind: .poster))
        #expect(
            !CommunityWriteSmoke.Operations.isMissingContent(
                GalleryServiceError.missingPoster, kind: .paper))
        #expect(
            !CommunityWriteSmoke.Operations.isMissingContent(
                PaperServiceError.missingPaper, kind: .course))
        #expect(
            !CommunityWriteSmoke.Operations.isMissingContent(
                NSError(
                    domain: "BIT101.Paper", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "文章不存在Orz"]), kind: .paper))
    }

    final class MissingRoute: HTTPTransport {
        var knownContent = false
        var status = 404
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            if url.path == "/user/check" {
                return (
                    Data(),
                    try #require(
                        HTTPURLResponse(
                            url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            }
            let message =
                knownContent
                ? (url.path.hasPrefix("/papers/") ? "文章不存在Orz" : "帖子不存在Orz") : "Not Found"
            return (
                try JSONSerialization.data(withJSONObject: ["message": message]),
                try #require(
                    HTTPURLResponse(
                        url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            )
        }
    }

    @Test(.timeLimit(.minutes(1))) func routeFailuresRemainVisibleProductionRead() async throws {
        let route = MissingRoute()
        let session = CommunitySession(
            httpClient: HTTPClient(transport: route, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: {
                .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture")
            }, refresh: { _ in })
        let operations = CommunityWriteSmoke.Operations.production(
            papers: PaperService(session: session),
            gallery: GalleryService(
                session: session,
                preferences: {
                    CommunityPreferenceSnapshot(
                        hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
                        useWebView: false, hideMakeupOutliers: false)
                }))
        for kind in [CommunityWriteSmoke.Kind.paper, .poster] {
            await #expect(throws: (any Error).self) { try await operations.read(kind, 1) }
        }
        await #expect(throws: (any Error).self) {
            try await operations.comments("poster1", nil)
        }
        try await operations.deleteComment(1)
        route.status = 500
        await #expect(throws: (any Error).self) { try await operations.deleteComment(1) }
        route.knownContent = true
        for status in [400, 404, 500] {
            route.status = status
            for kind in [CommunityWriteSmoke.Kind.paper, .poster] {
                #expect(try await operations.read(kind, 1) == nil)
            }
            await #expect(throws: (any Error).self) {
                try await operations.comments("poster1", nil)
            }
        }
    }

    @Test func journalSurvivesRestart() throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let directory = files.temporaryDirectoryURL.appendingPathComponent(
            "NetworkSmoke", isDirectory: true)
        let original = try JSONEncoder().encode(
            CommunityWriteSmoke.Journal(marker: "功能验收 recovery", account: 1))
        var legacyRemoved = false
        #expect(
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: original,
                removeLegacy: { legacyRemoved = true }) == original)
        #expect(legacyRemoved)
        #expect(
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: nil) == original)
        files.setFailures(writing: true)
        #expect(throws: CocoaError.self) {
            try CommunityWriteSmoke.saveJournal(
                Data("new".utf8), files: files, directory: directory)
        }
        #expect(
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: nil) == original)
        files.setFailures(removal: true)
        #expect(throws: CocoaError.self) {
            try CommunityWriteSmoke.saveJournal(nil, files: files, directory: directory)
        }
        #expect(
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: nil) == original)
        files.setFailures()
        try CommunityWriteSmoke.saveJournal(nil, files: files, directory: directory)
        #expect(
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: nil) == nil)
        files.setFailures(writing: true)
        legacyRemoved = false
        #expect(throws: CocoaError.self) {
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: original,
                removeLegacy: { legacyRemoved = true })
        }
        #expect(legacyRemoved == false)
    }

    @Test(arguments: [false, true])
    func unreadableJournalKeepsRecoveryState(metadataUnavailable: Bool) throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let directory = files.temporaryDirectoryURL.appendingPathComponent(
            "NetworkSmoke", isDirectory: true)
        let original = try JSONEncoder().encode(
            CommunityWriteSmoke.Journal(marker: "功能验收 recovery", account: 1))
        try CommunityWriteSmoke.saveJournal(original, files: files, directory: directory)
        files.setFailures(reading: true, metadata: metadataUnavailable)
        #expect(
            ReleaseNetworkSmokeReportStore.hasPendingCommunityWrites(
                files: files, directory: directory, legacyData: nil))
        var removed = false
        for legacy in [nil, original] {
            #expect(throws: CocoaError.self) {
                try CommunityWriteSmoke.loadJournal(
                    files: files, directory: directory, legacyData: legacy,
                    removeLegacy: { removed = true })
            }
        }
        #expect(removed == false)
        files.setFailures(removal: true, metadata: metadataUnavailable)
        #expect(throws: CocoaError.self) {
            try CommunityWriteSmoke.saveJournal(nil, files: files, directory: directory)
        }
        files.setFailures()
        #expect(
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: nil) == original)
        try CommunityWriteSmoke.saveJournal(nil, files: files, directory: directory)
        #expect(
            !ReleaseNetworkSmokeReportStore.hasPendingCommunityWrites(
                files: files, directory: directory, legacyData: nil))
        #expect(
            ReleaseNetworkSmokeReportStore.hasPendingCommunityWrites(
                files: files, directory: directory, legacyData: original))
    }

    @Test(.timeLimit(.minutes(1))) func savingFailureStopsOnlineCreation() async {
        let world = CommunityWorld(stage: "success")
        let smoke = CommunityWriteSmoke(
            operations: world.operations, load: { nil },
            save: { _ in throw CocoaError(.fileWriteNoPermission) })
        await #expect(throws: (any Error).self) {
            try await smoke.run(marker: "fixture", expectedAccount: 1)
        }
        #expect(world.nextID == 100)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
    }

    @Test(.timeLimit(.minutes(1))) func declaredSmokeAccountIsChecked() async throws {
        let world = CommunityWorld(stage: "success")
        let original = try JSONEncoder().encode(
            CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1))
        world.pending = original
        for account in [nil, 2] as [Int?] {
            await #expect(throws: (any Error).self) {
                try await world.smoke.run(marker: "fixture", expectedAccount: account)
            }
            #expect(world.pending == original && world.nextID == 100 && world.followsTarget)
        }
        let evidence = try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        #expect(evidence.contains("验收账号 user1") && world.nextID > 100 && world.pending == nil)
    }

    @Test(.timeLimit(.minutes(1))) func followInterruptionRetainsTargetConfirmed() async throws {
        let world = CommunityWorld(stage: "persistent-follow")
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        }
        let pending = try #require(world.pending)
        #expect(
            try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: pending)
                .followTarget == 2)
        world.stage = "success"
        let journal = try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: pending)
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        let confirmation = CommunityWriteRecoveryConfirmation(
            marker: journal.marker, account: 1,
            serverReceipt: "fixture-request-finished", kinds: [], parents: [],
            settledMutations: journal.pendingMutationIDs)
        _ = try await world.smoke.run(
            marker: "fixture", cleanupOnly: true, recoveryConfirmation: confirmation)
        #expect(world.followsTarget && world.pending == nil)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["follow-noop", "follow-response-mismatch", "follow-restore-noop"])
    func followProbeRequiresTransitions(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        }
        #expect(world.nextID == 100)
        if stage == "follow-restore-noop" {
            let journal = try JSONDecoder().decode(
                CommunityWriteSmoke.Journal.self, from: #require(world.pending))
            #expect(journal.followTarget == 2 && !world.followsTarget)
            world.stage = "success"
            _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(world.followsTarget && world.pending == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["late-follow-toggle", "late-course-toggle"])
    func uncertainToggleRetainsRecoveryAcrossState(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        }
        #expect(world.followsTarget && world.contents["course1"]?.liked == true)
        let journal = try JSONDecoder().decode(
            CommunityWriteSmoke.Journal.self, from: #require(world.pending))
        #expect(!journal.pendingMutationIDs.isEmpty)
        world.stage = "success"
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(world.pending != nil)
        if let followed = world.delayedFollow { world.followsTarget = followed }
        if let liked = world.delayedCourseLike {
            world.contents["course1"] = .init(text: "", owned: false, liked: liked)
        }
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(world.pending != nil)
        let confirmation = CommunityWriteRecoveryConfirmation(
            marker: journal.marker, account: 1,
            serverReceipt: "fixture-delayed-request-finished", kinds: [], parents: [],
            settledMutations: journal.pendingMutationIDs)
        _ = try await world.smoke.run(
            marker: "fixture", cleanupOnly: true, recoveryConfirmation: confirmation)
        #expect(
            world.pending == nil && world.followsTarget
                && world.contents["course1"]?.liked == true)
    }

    final class Scores: ScoreListServicing, TrustedTranscriptServicing {
        let stage: String
        let image: Data
        var submissions = 0
        init(stage: String, image: Data) {
            self.stage = stage
            self.image = image
        }
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            throw ScoreServiceError.invalidResponse
        }
        func fetchScores(
            detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge
        ) async throws -> [ScoreRow] { throw ScoreServiceError.invalidResponse }
        func submitScoreCode(_ code: String, for challenge: BITLoginAuthenticationChallenge)
            async throws -> BITLoginAuthenticationChallenge
        { throw ScoreServiceError.invalidResponse }
        func fetchTrustedPages(onPage: TrustedTranscriptPageDelivery?) async throws
            -> TrustedTranscriptPages
        {
            if stage == "sampleGap" {
                throw NetworkSmokePaging.SamplingError.insufficientSample("维护样本需要补齐")
            }
            if stage == "nativeBlocked" {
                throw ScheduleServiceError.schoolSecondFactorRequired
            }
            if stage == "invalid" { return .init([]) }
            throw ScoreServiceError.secondFactorRequired(
                BITLoginAuthenticationChallenge(
                    challengeID: "fixture", accessToken: "fixture",
                    status: "sms_required", maskedPhone: "***", expiresIn: 60))
        }
        func submitTranscriptCode(
            _ code: String, for challenge: BITLoginAuthenticationChallenge
        ) async throws -> BITLoginAuthenticationChallenge {
            submissions += 1
            if stage == "smsFailure" { throw ScoreServiceError.challengeInvalid("验证码错误") }
            return challenge
        }
        func fetchTrustedPages(
            authenticatedBy challenge: BITLoginAuthenticationChallenge,
            onPage: TrustedTranscriptPageDelivery?
        ) async throws -> TrustedTranscriptPages { .init([image]) }
    }

}
#endif
