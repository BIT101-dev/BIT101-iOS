#if DEBUG
import Foundation
import ClientCore
@testable import ScheduleInfrastructure
import StorageCore
import MediaKit
import SchedulePorts
import ScorePorts
import ScoreDomain
import UIKit
import Testing
import ScheduleDomain
import TransportCore
import CommunityCore
import CommunityTransport
@testable import GalleryFeature
@testable import PaperFeature
@testable import MineFeature
import CourseFeature
@testable import BIT101_iOS
@Suite("Network smoke external content")
struct NetworkSmokeExternalContentTests {
    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "complete", "fallback", "empty", "truncated", "wrong-start", "missing", "reversed",
            "duplicate", "drift", "wrong-response", "full-terminal",
        ])
    @MainActor func eclassSmokeRequiresCompleteCourseSequence(stage: String) async throws {
        let collector = NetworkSmokeRequestCollector()
        let operation = {
            let selected =
                stage == "missing"
                ? [2]
                : stage == "truncated"
                    ? [1]
                    : stage == "reversed"
                        ? [2, 1]
                        : stage == "duplicate"
                            ? [1, 1]
                            : ["fallback", "empty", "full-terminal"].contains(stage)
                                ? [1] : [1, 2]
            var courses = Set<Int>()
            for page in selected {
                let ids =
                    stage == "empty"
                    ? [] : stage == "full-terminal" ? Array(1...100) : [40 + page]
                courses.formUnion(ids)
                var request = URLRequest(
                    url: AppURL.required("https://zy-eclass.bit.edu.cn/api/my-courses"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "page": stage == "wrong-start" ? 99 : page,
                    "page_size": 100, "fields": "id,name", "conditions": [String: String](),
                ])
                var body: [String: Any] = ["courses": ids.map { ["id": $0] }]
                if stage != "fallback" && stage != "full-terminal" {
                    body["page"] = stage == "wrong-response" ? 99 : page
                    body["pages"] = stage == "empty" ? 0 : stage == "drift" && page == 2 ? 3 : 2
                }
                let url = try #require(request.url)
                let response = try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                await HTTPRequestEvidenceContext.didReceive?(
                    request,
                    HTTPResponse(
                        data: try JSONSerialization.data(withJSONObject: body),
                        response: response))
            }
            for id in courses {
                let request = URLRequest(
                    url: AppURL.required(
                        "https://zy-eclass.bit.edu.cn/api/courses/\(id)/activities"))
                let url = try #require(request.url)
                let response = try #require(
                    HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                await HTTPRequestEvidenceContext.didReceive?(
                    request, HTTPResponse(data: Data(), response: response))
            }
        }
        if ["complete", "fallback", "empty"].contains(stage) {
            try await collector.perform(operation, required: true)
        } else {
            await #expect(throws: NetworkSmokeRequestError.self) {
                try await collector.perform(operation, required: true)
            }
        }
    }
    @Test(arguments: [
        #"<a HREF = 'bit101://course/42'>打开</a>"#,
        #"<a class="open" href=bit101://course/42>打开</a>"#,
        #"<a title="x > y" href = "bit101&#58;//course/42">打开</a>"#,
        #"<script>const x = '<a href="wrong">';</script><a href="bit101://course/42">打开</a>"#,
        #"<div hidden><a href="wrong">隐藏</a></div><a href="bit101://course/42">打开</a>"#,
        #"<a style="display: none; display: block" href="bit101://course/42">打开</a>"#,
        #"<a href="bit101://course/42"><span>打开</span></a>"#,
        #"<a href="bit101://course/42"><img src="open.png"></a>"#,
        #"""
        <a style="visibility:hidden;visibility:visible;opacity:0;opacity:1" href="bit101:/\#
        /course/42">打开</a>
        """#,
        #"<a style="opacity:100%" href="bit101://course/42">打开</a>"#,
        #"<dialog open><a href="bit101://course/42">打开</a></dialog>"#,
        #"<details open><a href="bit101://course/42">打开</a></details>"#,
        #"<details><summary><a href="bit101://course/42">打开</a></summary><p>内容</p></details>"#,
    ])
    func landingPagesAcceptHTMLAttributeForms(_ link: String) throws {
        let data = Data(("<!doctype html><html>" + link + "</html>").utf8)
        #expect(
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                data,
                finalURL: URL(string: "https://open.aihelpme.dev/course/42"),
                expectedHost: "open.aihelpme.dev",
                expectedPath: "/course/42", expectedAppURL: "bit101://course/42") == data.count)
    }
    @Test(arguments: [
        #"<!-- <a href="bit101://course/42">打开</a> -->"#,
        #"<script>const x = '<a href="bit101://course/42">';</script>"#,
        #"<style>a[href="bit101://course/42"] { color: red; }</style>"#,
        #"<textarea><a href="bit101://course/42">打开</a></textarea>"#,
        #"<template><a href="bit101://course/42">打开</a></template>"#,
        #"<div href="bit101://course/42">打开</div>"#,
        #"<a data-href="bit101://course/42">打开</a>"#,
        #"<a title="href='bit101://course/42'" href="bit101://course/7">打开</a>"#,
        #"<a href="bit101://course/7" href="bit101://course/42">打开</a>"#,
        #"<a hidden href="bit101://course/42">打开</a>"#,
        #"<a hidden="false" href="bit101://course/42">打开</a>"#,
        #"<div hidden><a href="bit101://course/42">打开</a></div>"#,
        #"<div style="display:none"><a href="bit101://course/42">打开</a></div>"#,
        #"<a style="DISPLAY: /* hidden */ none !IMPORTANT" href="bit101://course/42">打开</a>"#,
        #"<a style="display:none!important;display:block" href="bit101://course/42">打开</a>"#,
        #"<a inert href="bit101://course/42">打开</a>"#,
        #"<noscript><a href="bit101://course/42">打开</a></noscript>"#,
        #"<a href="bit101://course/42"></a>"#,
        #"<a href="bit101://course/42"> &#32;&nbsp; </a>"#,
        #"<a href="bit101://course/42"><span hidden>打开</span></a>"#,
        #"<a href="bit101://course/42"><!-- 打开 --><script>open()</script></a>"#,
        #"<a style="visibility:hidden" href="bit101://course/42">打开</a>"#,
        #"<div style="opacity:0"><a href="bit101://course/42">打开</a></div>"#,
        #"<a style="opacity:0%" href="bit101://course/42">打开</a>"#,
        #"<a style="opacity:-10%" href="bit101://course/42">打开</a>"#,
        #"<a style="opacity:-1" href="bit101://course/42">打开</a>"#,
        #"<a style="opacity:0!important;opacity:1" href="bit101://course/42">打开</a>"#,
        #"<a style="pointer-events:none" href="bit101://course/42">打开</a>"#,
        #"<dialog><a href="bit101://course/42">打开</a></dialog>"#,
        #"<details><summary>说明</summary><a href="bit101://course/42">打开</a></details>"#,
        #"""
        <details><summary>说明</summary><summary><a href="bit101://course/42">打开</a></summar\#
        y></details>
        """#,
    ])
    func landingPagesRequireActualAnchorDestination(_ content: String) throws {
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                Data(("<html>" + content + "</html>").utf8),
                finalURL: URL(string: "https://open.aihelpme.dev/course/42"),
                expectedHost: "open.aihelpme.dev",
                expectedAppURL: "bit101://course/42")
        }
    }
    @Test("Release smoke validates external content contracts")
    func releaseSmokeExternalJSONContracts() throws {
        for date in ["", "changed-format", "2026/09/28", "2026-02-31"] {
            let payload = CourseSyncPayload(
                term: "2026-2027-1", firstDayString: date, sourceFirstDayString: date,
                normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: [])
            #expect(throws: URLError.self) {
                try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload)
            }
        }
        let payload = CourseSyncPayload(
            term: "2026-2027-1", firstDayString: "2026-09-28",
            sourceFirstDayString: "2026-09-28",
            normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: [])
        try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload)
        let landing = Data(
            #"<!doctype html><html><a href="bit101://course/42">打开</a></html>"#.utf8)
        #expect(
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                landing,
                finalURL: URL(string: "https://open.aihelpme.dev/course/42"),
                expectedHost: "open.aihelpme.dev",
                expectedPath: "/course/42", expectedAppURL: "bit101://course/42") > 0)
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                landing,
                finalURL: URL(string: "https://open.aihelpme.dev/course/7"),
                expectedHost: "open.aihelpme.dev",
                expectedPath: "/course/42", expectedAppURL: "bit101://course/42")
        }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                Data("<html>登录</html>".utf8),
                finalURL: URL(string: "https://open.aihelpme.dev/course/42"),
                expectedHost: "open.aihelpme.dev",
                expectedPath: "/course/42", expectedAppURL: "bit101://course/42")
        }
        let aasa = Data(
            #"""
            {"applinks":{"details":[{"appID":"Y2T72736G3.BIT101-dev.BIT101-iOS","paths":["\#
            /gallery/*","/course/*","/paper/*"]}]}}
            """#
            .utf8)
        let associationURL = AppURL.required(
            "https://open.aihelpme.dev/.well-known/apple-app-site-association")
        func association(
            _ data: Data, status: Int = 200, mime: String = "application/json", url: URL? = nil
        ) throws -> HTTPResponse {
            HTTPResponse(
                data: data,
                response: try #require(
                    HTTPURLResponse(
                        url: url ?? associationURL, statusCode: status,
                        httpVersion: nil, headerFields: ["Content-Type": mime])))
        }
        #expect(
            try ReleaseNetworkSmokeRunner.validateAASA(
                association(aasa, mime: "application/json; charset=utf-8")) == 3)
        for response in try [
            association(Data("{}".utf8)), association(aasa, status: 302),
            association(aasa, mime: "text/plain"),
            association(aasa, url: AppURL.required("https://open.aihelpme.dev/redirected")),
            association(Data(repeating: 32, count: 128 * 1024 + 1)),
        ] {
            #expect(throws: URLError.self) {
                try ReleaseNetworkSmokeRunner.validateAASA(response)
            }
        }
        let excluded = Data(
            String(decoding: aasa, as: UTF8.self).replacingOccurrences(
                of: "\"/gallery/*\"", with: "\"NOT /gallery/*\",\"/gallery/*\""
            ).utf8)
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateAASA(association(excluded))
        }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateTranscriptPages([])
        }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateTranscriptPages([Data("not an image".utf8)])
        }

        let html = Data(
            "<!doctype html><html><head><title>BIT101</title></head><body>BIT101</body></html>"
                .utf8)
        for invalid in [
            "<html><title>BIT101</title></html>",
            "<html><title>BIT101</title><body></body></html>", "<html></html>",
            "<html><title>登录</title></html>",
            "<html><script><title>BIT101</title></script></html>",
        ] {
            #expect(throws: URLError.self) {
                try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                    Data(invalid.utf8), finalURL: URL(string: "https://bit101.cn/gallery/"),
                    expectedHost: "bit101.cn")
            }
        }
        #expect(
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                html,
                finalURL: URL(string: "https://bit101.cn/gallery/"),
                expectedHost: "bit101.cn"
            ) == html.count
        )
        #expect(
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                html,
                finalURL: URL(string: "https://open.aihelpme.dev/gallery/123"),
                expectedHost: "open.aihelpme.dev"
            ) == html.count
        )
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                html,
                finalURL: URL(string: "https://example.com/gallery/123"),
                expectedHost: "open.aihelpme.dev"
            )
        }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(
                Data("not a web document".utf8),
                finalURL: URL(string: "https://open.aihelpme.dev/gallery/123"),
                expectedHost: "open.aihelpme.dev"
            )
        }

        let lookup = Data(
            #"""
            {"resultCount":1,"results":[{"version":"1.2.3","bundleId":"BIT101-dev.BIT101-i\#
            OS","currentVersionReleaseDate":"2026-01-01T00:00:00Z","trackViewUrl":"https:/\#
            /apps.apple.com/cn/app/bit101/id6761147125"}]}
            """#
            .utf8
        )
        #expect(try ReleaseNetworkSmokeRunner.validateAppStoreLookup(lookup) == 1)

        let wrongApp = Data(
            #"""
            {"resultCount":1,"results":[{"version":"1.2.3","bundleId":"other.app","current\#
            VersionReleaseDate":"2026-01-01T00:00:00Z","trackViewUrl":"https://apps.apple.\#
            com/cn/app/other/id1234567890"}]}
            """#
            .utf8
        )
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateAppStoreLookup(wrongApp)
        }

        let disabledNotice = Data(#"{"schema_version":1,"enabled":false}"#.utf8)
        #expect(try ReleaseNetworkSmokeRunner.validateEmergencyUpdate(disabledNotice) == false)

        let enabledNotice = Data(
            #"""
            {"schema_version":1,"enabled":true,"notice_id":"maintenance","maximum_affected\#
            _build":33,"title":"Update","message":"Install the current release.","update_u\#
            rl":"https://apps.apple.com/cn/app/bit101/id6761147125"}
            """#
            .utf8
        )
        #expect(try ReleaseNetworkSmokeRunner.validateEmergencyUpdate(enabledNotice))

        let unsupportedNotice = Data(#"{"schema_version":2,"enabled":false}"#.utf8)
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateEmergencyUpdate(unsupportedNotice)
        }
    }
}

extension NetworkEvidenceProjectionTests {
    @Test(arguments: ["registered", "header-missing", "other-host", "other-path"])
    func encryptedSchoolEvidenceUsesFormat(stage: String) throws {
        let host = stage == "other-host" ? "example.invalid" : "sso.bit.edu.cn"
        let path = stage == "other-path" ? "other" : "getPhoneNumberByUserId"
        let url = try #require(URL(string: "https://\(host)/cas/api/protected/sms/\(path)"))
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stage != "header-missing" {
            request.setValue("true", forHTTPHeaderField: "hasCrypto")
        }
        request.httpBody = Data("fixture-encrypted-secret".utf8)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response)
        #expect(evidence.ambiguousParameters == (stage == "registered" ? nil : ["JSON"]))
        #expect(
            evidence.finalAmbiguousParameters == evidence.ambiguousParameters
                && evidence.bodyParameterNames.isEmpty)
        #expect(
            !String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains(
                "fixture-encrypted-secret"))
    }
}
#endif

#if DEBUG
let smokePaperContent =
    #"""
    {"blocks":[{"type":"header","data":{"text":"Title","level":1}},{"type":"paragraph","da\#
    ta":{"text":"Readable <b>body</b>"}},{"type":"image","data":{"file":{"url":"https://im\#
    age.invalid/paper.png"}}}]}
    """#
extension ReleaseNetworkSmokeLifecycleTests {
    @Test(
        "Full smoke orchestration preserves success, intermediate failures and subsequent scopes",
        .timeLimit(.minutes(1)),
        arguments: [
            "gallery-search-ignored-failure", "course-search-ignored-failure",
            "paper-search-ignored-failure", "bot-empty-gap", "gallery-search-target-failure",
            "message-empty-gap", "all-success", "all-sms-success", "all-sms-captcha-failure",
            "all-sms-not-required", "all-sms-community-login-failure",
            "all-sms-community-login-empty-failure", "all-sms-app-store-failure",
            "community-failure", "schedule-success", "ddl-success", "ddl-failure",
            "ddl-invalid-calendar-failure", "raw-write-failure",
            "app-store-redirect-failure", "emergency-redirect-failure", "aasa-redirect-failure",
            "aasa-followed-redirect-failure",
            "aasa-mime-failure", "aasa-exclusion-failure", "image-budget-failure",
            "entity-identity-failure", "repeated-page-failure",
            "gallery-comment-page-failure", "course-comment-page-failure",
            "paper-comment-page-failure", "gallery-comment-ranking-failure",
            "paper-comment-ranking-failure", "cors-method-failure", "cors-header-failure",
            "schedule-term-failure", "historical-term-success", "maintained-fixtures-success",
            "feed-images-missing-success", "fixture-image-missing-failure",
            "missing-fixtures-failure", "fixture-course-number-failure", "empty-list-failure",
            "all-score-mismatch-failure",
            "bot-classification-failure", "paper-like-order-failure",
            "paper-comment-order-failure", "paper-newest-date-failure",
            "paper-default-date-failure", "paper-content-failure", "paper-image-failure",
            "campus-selection-failure",
            "invalid-exam-failure", "pending-exam-success", "empty-course-gap",
            "pending-course-gap", "invalid-classroom-failure", "empty-classroom-gap",
            "paper-media-success", "paper-media-original-failure",
            "paper-media-thumbnail-failure",
            "school-independent-success", "transcript-independent-success",
            "schedule-independent-success", "ddl-independent-success",
            "course-comment-ranking-failure", "course-history-statistics-failure",
            "poster-like-order-failure", "poster-new-order-failure",
            "message-account-missing-failure", "message-account-mismatch-failure",
            "course-search-target-failure", "paper-search-target-failure",
            "course-search-later-success", "report-types-empty-gap",
            "report-types-duplicate-failure", "report-types-text-failure",
        ])
    func completeOrchestration(stage: String) async throws {
        let captchaBlocked = stage == "all-sms-captcha-failure"
        let image = try #require(
            UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image {
                $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }.pngData())
        let services = Services(stage: stage, image: image)
        let productionServices = Services(stage: stage, image: image)
        let redirectHost =
            stage == "app-store-redirect-failure" || stage == "all-sms-app-store-failure"
            ? "itunes.apple.com"
            : stage == "emergency-redirect-failure" ? "update.aihelpme.dev" : nil
        let external = External(image: image, redirectHost: redirectHost, aasaStage: stage)
        let association = External(image: image, aasaStage: stage)
        let externalClient = HTTPClient(transport: external, observer: nil)
        let files = PreferenceMemoryFiles()
        let media = AppMedia.makeEnvironment(
            files: files, previewStorage: MediaPreviewStorage(files: files),
            imageHTTPClient: externalClient, avatarHTTPClient: externalClient)
        var reports: [ReleaseNetworkSmokeReport] = []
        var feedback = 0
        var rawWrites = 0
        var loginChecks = 0
        let sessionEvidence = ["初始账号资料 ID：1", "无效凭据切换：认证拒绝", "恢复账号资料 ID：1"]
        let dependencies = ReleaseNetworkSmokeDependencies(
            requiresRequestEvidence: false,
            checkLogin: {
                loginChecks += 1
                if stage == "all-sms-community-login-empty-failure" { return nil }
                if stage.contains("independent") || stage == "all-sms-community-login-failure" {
                    throw URLError(.notConnectedToInternet)
                }
                return "fixture"
            }, writeReport: { reports.append($0) },
            clearRawCourseResponse: {},
            writeRawCourseResponse: { _, runID in
                rawWrites += 1
                #expect(runID == stage)
                if stage == "raw-write-failure" { throw CocoaError(.fileWriteNoPermission) }
            }, makeGallery: { services }, makeCourses: { services }, makePapers: { services },
            makeMine: { services },
            productionSessionProbe: { sessionEvidence }, externalHTTPClient: externalClient,
            imageProbe: { try await media.verifyRemoteImage(at: $0) },
            aasaHTTPClient: HTTPClient(transport: association, observer: nil),
            feedbackProbe: { _ in feedback += 1 },
            loadScheduleCache: { ScheduleCache() }, makeScores: { services },
            makeSchedule: { handler in
                services.rawResponse = handler
                return services
            },
            makeProductionSchedule: { productionServices }, makeEclassSchedule: { services })
        let scope: NetworkSmokeScope =
            stage.hasPrefix("gallery-search-") || stage == "message-empty-gap"
                || stage == "course-history-statistics-failure"
                || stage.hasPrefix("course-search-") || stage.hasPrefix("poster-")
                || stage.hasPrefix("message-account-") || stage.hasPrefix("report-types-")
            ? .bit101
            : stage.hasPrefix("school-")
                ? .school
                : stage.hasPrefix("transcript-")
                    ? .transcript
                    : stage.hasPrefix("all-") || redirectHost != nil || stage.hasPrefix("aasa")
                        ? .all
                        : stage == "community-failure" || stage == "image-budget-failure"
                            || stage == "entity-identity-failure"
                            || stage == "repeated-page-failure"
                            || stage.contains("comment-page")
                            || stage.contains("comment-ranking") || stage.hasPrefix("cors")
                            || stage.hasPrefix("bot-") || stage.hasPrefix("paper-")
                            || stage.contains("fixtures")
                            || stage == "feed-images-missing-success"
                            || stage == "fixture-image-missing-failure"
                            || stage == "fixture-course-number-failure"
                            || stage == "empty-list-failure"
                            ? .bit101 : stage.hasPrefix("ddl") ? .ddl : .schedule
        let runner = ReleaseNetworkSmokeRunner(dependencies: dependencies)
        let smsHandler: SchoolSMSCodeHandler = { request in
            #expect(!captchaBlocked || request.purpose == "school_sso_second_factor")
            return "fixture-code"
        }
        let report = await runner.run(
            scope: scope, runID: stage,
            capture: stage == "raw-write-failure" ? .rawCourseResponse : .none,
            term: stage == "historical-term-success" ? "historical-1" : nil,
            communityExpectedAccount: stage == "message-account-missing-failure"
                ? nil : stage == "message-account-mismatch-failure" ? 2 : 1,
            fixtures: stage == "missing-fixtures-failure"
                ? nil
                : NetworkSmokeFixtures(
                    posterID: 41, courseID: 43,
                    courseNumber: stage == "fixture-course-number-failure" ? "OTHER" : "COURSE",
                    paperID: 45),
            schoolSMSCodeHandler: stage.hasPrefix("all-sms-") ? smsHandler : nil)
        if scope.includes(.bit101) && !stage.contains("community-login") {
            #expect(
                services.observed.isSuperset(of: [
                    "gallery-follow", "gallery-hot", "gallery-newest",
                ]))
            #expect(
                report.executedProbes.contains("gallery.following")
                    && report.executedProbes.contains("gallery.hot"))
        }
        #expect(
            report.passed
                == (!stage.hasSuffix("failure") || stage == "missing-fixtures-failure"
                    || stage.hasPrefix("report-types-")),
            "\(stage): \(report.failures)")
        if stage == "all-success" || stage == "maintained-fixtures-success" {
            #expect(
                services.observed.isSuperset(of: [
                    "course-search-COURSE-0", "course-search-COURSE-1",
                    "paper-search-fixture-0", "paper-search-fixture-1",
                ]))
            #expect(
                report.executedProbes.contains("course.search")
                    && report.executedProbes.contains("paper.search"))
        }
        if stage.contains("search-target-failure") || stage.contains("search-ignored-failure") {
            #expect(
                report.failures.contains {
                    $0.contains(
                        stage.hasPrefix("course-")
                            ? "course.search"
                            : stage.hasPrefix("gallery-") ? "gallery.search" : "paper.search")
                })
        }
        if stage == "course-search-later-success" {
            #expect(services.observed.contains("course-search-COURSE-2"))
        }
        if stage.hasPrefix("poster-") {
            #expect(report.failures.contains { $0.contains("gallery.search") })
        }
        if stage.hasPrefix("report-types-") {
            let exempted = Set([
                "community.report-types", "message.follow", "message.system", "message.like",
                "message.comment",
            ])
            #expect(report.coverageComplete && Set(report.exemptedProbes.keys) == exempted)
            #expect(
                exempted.isDisjoint(with: report.executedProbes)
                    && exempted.isDisjoint(with: report.requestEvidence.map(\.probe)))
        }
        if stage == "course-comment-ranking-failure" {
            #expect(report.failures.contains { $0.contains("course.comments") })
        }
        if stage.hasPrefix("message-account-") {
            #expect(report.failures.count == 1 && !services.observed.contains("message-read"))
        }
        if stage == "course-history-statistics-failure" {
            #expect(report.failures.contains { $0.contains("course.history") })
        }
        if stage == "maintained-fixtures-success" {
            #expect(
                services.observed.isSuperset(
                    of: GallerySearchOrder.allCases.map { "gallery-search-\($0.rawValue)" }))
            for kind in ["gallery", "paper"] {
                #expect(
                    services.observed.isSuperset(
                        of: CommunityCommentOrder.allCases.map {
                            "\(kind)-order-\($0.rawValue)"
                        }))
            }
            #expect(
                services.observed.isSuperset(of: [
                    "fixture-poster-41", "fixture-course-43", "fixture-paper-45",
                ]))
            #expect(external.requests.contains { $0.url?.path == "/paper.png" })
        }
        if stage == "paper-media-success" {
            #expect(external.requests.contains { $0.url?.path == "/paper.png" })
            #expect(external.requests.contains { $0.url?.path == "/paper-low.png" })
        }
        if stage == "paper-media-original-failure" || stage == "paper-media-thumbnail-failure" {
            #expect(report.failures.count == 1 && report.failures[0].contains("paper.image"))
        }
        if stage == "feed-images-missing-success" || stage == "maintained-fixtures-success" {
            #expect(external.requests.contains { $0.url?.path == "/fixture.png" })
        }
        if stage == "fixture-image-missing-failure" {
            #expect(report.failures.contains { $0.contains("gallery.image") })
        }
        if stage == "missing-fixtures-failure" {
            #expect(
                !report.coverageComplete
                    && report.skippedProbes.contains { $0.contains("维护对象配置") })
        }
        #expect(
            report.productionSessionEvidence
                == (scope.includes(.bit101) && !stage.contains("community-login")
                    ? sessionEvidence : []))
        if stage == "all-sms-success" {
            #expect(report.schoolSMSCoverage == "verified")
            #expect(services.webvpnVerified && productionServices.webvpnVerified)
            #expect(
                Set(report.verifiedSMSProbes.filter { $0.purpose == "webvpn" }.map(\.probe))
                    == ["school.session", "schedule.current-term"])
            #expect(
                Set(report.verifiedSMSProbes.map(\.purpose))
                    == NetworkSmokeScope.all.requiredSMSPurposes)
        }
        if stage.hasPrefix("all-sms-") && !captchaBlocked {
            #expect(
                Set(report.authenticatedSchoolProbes.map(\.purpose))
                    == NetworkSmokeScope.all.requiredSMSPurposes)
            #expect(
                Set(report.requestedSMSPurposes) == Set(report.verifiedSMSProbes.map(\.purpose))
            )
            #expect(
                report.schoolSMSCoverage
                    == (stage == "all-sms-not-required" ? "not_required" : "verified"))
            #expect(
                Set(NetworkSmokeScope.school.requiredProbes).isSubset(
                    of: Set(report.executedProbes)))
            #expect(
                report.coverageComplete == !stage.contains("community-login"),
                "\(stage): \(report.coverageGaps)")
            if stage.contains("community-login") {
                #expect(!services.observed.contains("gallery-newest"))
            }
        }
        if stage == "all-sms-not-required" {
            #expect(report.schoolSMSCoverage == "not_required")
            #expect(report.verifiedSMSProbes.isEmpty && report.requestedSMSPurposes.isEmpty)
        }
        if stage == "repeated-page-failure" {
            #expect(report.failures.contains { $0.contains("course.list") })
            #expect(services.observed.contains("fixture-course-43"))
            #expect(report.coverageComplete)
        }
        if stage == "missing-fixtures-failure" {
            #expect(
                Set(scope.requiredProbes).subtracting(report.executedProbes)
                    == [
                        "gallery.detail", "gallery.image", "gallery.comments", "gallery.web",
                        "course.detail", "course.comments",
                        "course.history", "course.web", "course.search", "paper.search",
                        "paper.detail", "paper.image", "paper.comments", "paper.web",
                    ])
        } else {
            let deferred: Set<String> =
                stage.contains("community-login")
                ? Set(
                    NetworkSmokeProbe.allCases.filter(\.requiresCommunitySession).map(
                        \.rawValue))
                : captchaBlocked
                    ? [
                        "score.brief", "score.detail", "schedule.sync", "classroom.campuses",
                        "classroom.buildings", "classroom.occupancy",
                    ]
                    : stage == "entity-identity-failure"
                        ? ["paper.search", "paper.image", "gallery.image"]
                        : stage == "paper-content-failure"
                            ? ["paper.search", "paper.image"]
                            : stage == "campus-selection-failure" ? ["classroom.occupancy"] : []
            #expect(
                Set(report.executedProbes) == Set(scope.requiredProbes).subtracting(deferred))
        }
        #expect(reports.count == 1 && reports[0].passed == report.passed)
        #expect(loginChecks == (scope.includes(.authentication) ? 1 : 0))
        if scope.includes(.bit101) {
            #expect(feedback == 1)
            #expect(services.observed.contains("mine") == !stage.contains("community-login"))
            #expect(
                services.observed.contains("paper-list") == !stage.contains("community-login"))
        }
        #expect(association.requests.count == (scope.includes(.bit101) ? 1 : 0))
        #expect(
            external.requests.allSatisfy {
                $0.url?.path.hasSuffix("apple-app-site-association") == false
            })
        if scope.includes(.bit101) {
            #expect(
                !external.imageBudgets.isEmpty
                    && external.imageBudgets.allSatisfy {
                        $0 == RemoteImageResourceLimits.maximumEncodedBytes
                    })
        }
        if stage == "entity-identity-failure" {
            #expect(report.failures.count == 3)
            for name in ["gallery.detail", "course.detail", "paper.detail"] {
                #expect(report.failures.contains { $0.contains(name) })
            }
        }
        if stage == "paper-content-failure" || stage == "paper-image-failure"
            || stage == "campus-selection-failure"
        {
            let probe =
                stage == "paper-content-failure"
                ? "paper.detail"
                : stage == "paper-image-failure" ? "paper.image" : "classroom.buildings"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        if stage.contains("comment-ranking") {
            let probe =
                stage.hasPrefix("gallery")
                ? "gallery.comments"
                : stage.hasPrefix("course") ? "course.comments" : "paper.comments"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        if [
            "bot-empty-gap", "empty-classroom-gap", "message-empty-gap", "empty-course-gap",
            "pending-course-gap",
        ].contains(stage) {
            let probe =
                stage == "bot-empty-gap"
                ? "gallery.bots"
                : stage == "message-empty-gap"
                    ? "message."
                    : stage.contains("course-gap") ? "schedule.sync" : "classroom.occupancy"
            #expect(
                report.passed && !report.coverageComplete
                    && report.coverageGaps.contains { $0.contains(probe) })
        }
        if stage.contains("comment-page") {
            let kind = String(stage.prefix { $0 != "-" })
            let probe =
                kind == "gallery"
                ? "gallery.comments" : kind == "course" ? "course.comments" : "paper.comments"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
            #expect(services.observed.contains("\(kind)-comments-\(kind == "gallery" ? 3 : 1)"))
        }
        if stage.hasPrefix("cors") {
            #expect(
                report.failures.count == 1 && report.failures[0].contains("feedback.preflight"))
        }
        if stage.hasPrefix("aasa") {
            #expect(
                report.failures.count == 1 && report.failures[0].contains("web.association"))
        }
        if scope.includes(.schedule) {
            #expect(services.observed.contains("schedule") == !captchaBlocked)
            #expect(report.currentTerm == (captchaBlocked ? nil : "fixture-1"))
            #expect(
                report.requestedTerm
                    == (stage == "historical-term-success" ? "historical-1" : nil))
            #expect(
                report.validatedTerm
                    == (captchaBlocked || stage == "schedule-term-failure"
                        || stage == "invalid-exam-failure" || stage.contains("course-gap")
                        ? nil : report.requestedTerm ?? "fixture-1"))
        }
        if report.executedProbes.contains("classroom.occupancy") {
            let occupancy = try #require(
                report.requestEvidence.first { $0.probe == "classroom.occupancy" })
            let queryDate = try #require(services.classroomDate)
            #expect(
                occupancy.expectedParameters == [
                    "XNXQDM": report.requestedTerm ?? "fixture-1", "JXLDM": "building",
                    "RQ": ScheduleDateCodec.formatDate(queryDate), "XQDM": "1",
                    "XNDM": stage == "historical-term-success" ? "historical" : "fixture",
                ])
        }
        if scope.includes(.ddl) {
            #expect(services.observed.isSuperset(of: ["eclass", "lexue"]))
        }
        if stage == "raw-write-failure" {
            #expect(rawWrites == 1 && report.failures.contains { $0.contains("原始课表采样写入") })
        }
        if stage == "ddl-failure" || stage == "ddl-invalid-calendar-failure" {
            #expect(report.failures.count == 1 && report.failures[0].contains("lexue.ddl"))
        }
        if let redirectHost {
            let probe =
                redirectHost == "itunes.apple.com" ? "update.app-store" : "update.emergency"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        let next = await runner.run(
            scope: .transcript, runID: "next",
            schoolSMSCodeHandler: stage.hasPrefix("all-sms-") ? smsHandler : nil)
        #expect(
            next.passed == !captchaBlocked && next.failures.isEmpty
                && next.authenticationBlockers.isEmpty == !captchaBlocked
                && next.coverageComplete == !captchaBlocked, "\(stage): \(next.summaryLine)")
        #expect(reports.count == 2)
    }
}
#endif
