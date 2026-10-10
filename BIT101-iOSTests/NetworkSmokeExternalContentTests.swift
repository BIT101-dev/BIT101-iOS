#if DEBUG
import Foundation
import Testing
import ScheduleDomain
import TransportCore
@testable import BIT101_iOS

@Suite("Network smoke external content")
struct NetworkSmokeExternalContentTests {
    @Test(arguments: [#"<a HREF = 'bit101://course/42'>打开</a>"#,
        #"<a class="open" href=bit101://course/42>打开</a>"#,
        #"<a title="x > y" href = "bit101&#58;//course/42">打开</a>"#,
        #"<script>const x = '<a href="wrong">';</script><a href="bit101://course/42">打开</a>"#])
    func landingPagesAcceptHTMLAttributeForms(_ link: String) throws {
        let data = Data(("<!doctype html><html>" + link + "</html>").utf8)
        #expect(try ReleaseNetworkSmokeRunner.validateHTMLResponse(data,
            finalURL: URL(string: "https://open.aihelpme.dev/course/42"), expectedHost: "open.aihelpme.dev",
            expectedPath: "/course/42", expectedAppURL: "bit101://course/42") == data.count)
    }

    @Test(arguments: [#"<!-- <a href="bit101://course/42">打开</a> -->"#,
        #"<script>const x = '<a href="bit101://course/42">';</script>"#,
        #"<style>a[href="bit101://course/42"] { color: red; }</style>"#,
        #"<textarea><a href="bit101://course/42">打开</a></textarea>"#,
        #"<template><a href="bit101://course/42">打开</a></template>"#,
        #"<div href="bit101://course/42">打开</div>"#,
        #"<a data-href="bit101://course/42">打开</a>"#,
        #"<a title="href='bit101://course/42'" href="bit101://course/7">打开</a>"#,
        #"<a href="bit101://course/7" href="bit101://course/42">打开</a>"#])
    func landingPagesRequireAnActualAnchorDestination(_ content: String) throws {
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(Data(("<html>" + content + "</html>").utf8),
                finalURL: URL(string: "https://open.aihelpme.dev/course/42"), expectedHost: "open.aihelpme.dev",
                expectedAppURL: "bit101://course/42")
        }
    }

    @Test("Release smoke validates external content contracts")
    func releaseSmokeExternalJSONContracts() throws {
        for date in ["", "changed-format", "2026/09/28", "2026-02-31"] {
            let payload = CourseSyncPayload(term: "2026-2027-1", firstDayString: date, sourceFirstDayString: date,
                normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: [])
            #expect(throws: URLError.self) { try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload) }
        }
        let payload = CourseSyncPayload(term: "2026-2027-1", firstDayString: "2026-09-28", sourceFirstDayString: "2026-09-28",
            normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: [])
        try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload)
        let landing = Data(#"<!doctype html><html><a href="bit101://course/42">打开</a></html>"#.utf8)
        #expect(try ReleaseNetworkSmokeRunner.validateHTMLResponse(landing,
            finalURL: URL(string: "https://open.aihelpme.dev/course/42"), expectedHost: "open.aihelpme.dev",
            expectedPath: "/course/42", expectedAppURL: "bit101://course/42") > 0)
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(landing,
                finalURL: URL(string: "https://open.aihelpme.dev/course/7"), expectedHost: "open.aihelpme.dev",
                expectedPath: "/course/42", expectedAppURL: "bit101://course/42")
        }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateHTMLResponse(Data("<html>登录</html>".utf8),
                finalURL: URL(string: "https://open.aihelpme.dev/course/42"), expectedHost: "open.aihelpme.dev",
                expectedPath: "/course/42", expectedAppURL: "bit101://course/42")
        }
        let aasa = Data(#"{"applinks":{"details":[{"appID":"Y2T72736G3.BIT101-dev.BIT101-iOS","paths":["/gallery/*","/course/*","/paper/*"]}]}}"#.utf8)
        let associationURL = AppURL.required("https://open.aihelpme.dev/.well-known/apple-app-site-association")
        func association(_ data: Data, status: Int = 200, mime: String = "application/json", url: URL? = nil) throws -> HTTPResponse {
            HTTPResponse(data: data, response: try #require(HTTPURLResponse(url: url ?? associationURL, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": mime])))
        }
        #expect(try ReleaseNetworkSmokeRunner.validateAASA(association(aasa, mime: "application/json; charset=utf-8")) == 3)
        for response in try [association(Data("{}".utf8)), association(aasa, status: 302), association(aasa, mime: "text/plain"),
                             association(aasa, url: AppURL.required("https://open.aihelpme.dev/redirected")),
                             association(Data(repeating: 32, count: 128 * 1024 + 1))] {
            #expect(throws: URLError.self) { try ReleaseNetworkSmokeRunner.validateAASA(response) }
        }
        let excluded = Data(String(decoding: aasa, as: UTF8.self).replacingOccurrences(of: "\"/gallery/*\"", with: "\"NOT /gallery/*\",\"/gallery/*\"").utf8)
        #expect(throws: URLError.self) { try ReleaseNetworkSmokeRunner.validateAASA(association(excluded)) }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateTrustedTranscriptPages([])
        }
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateTrustedTranscriptPages([Data("not an image".utf8)])
        }

        let html = Data("<!doctype html><html><body>BIT101</body></html>".utf8)
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
            #"{"resultCount":1,"results":[{"version":"1.2.3","bundleId":"BIT101-dev.BIT101-iOS","currentVersionReleaseDate":"2026-01-01T00:00:00Z","trackViewUrl":"https://apps.apple.com/cn/app/bit101/id6761147125"}]}"#.utf8
        )
        #expect(try ReleaseNetworkSmokeRunner.validateAppStoreLookup(lookup) == 1)

        let wrongApp = Data(
            #"{"resultCount":1,"results":[{"version":"1.2.3","bundleId":"other.app","currentVersionReleaseDate":"2026-01-01T00:00:00Z","trackViewUrl":"https://apps.apple.com/cn/app/other/id1234567890"}]}"#.utf8
        )
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateAppStoreLookup(wrongApp)
        }

        let disabledNotice = Data(#"{"schema_version":1,"enabled":false}"#.utf8)
        #expect(try ReleaseNetworkSmokeRunner.validateEmergencyUpdateConfiguration(disabledNotice) == false)

        let enabledNotice = Data(
            #"{"schema_version":1,"enabled":true,"notice_id":"maintenance","maximum_affected_build":33,"title":"Update","message":"Install the current release.","update_url":"https://apps.apple.com/cn/app/bit101/id6761147125"}"#.utf8
        )
        #expect(try ReleaseNetworkSmokeRunner.validateEmergencyUpdateConfiguration(enabledNotice))

        let unsupportedNotice = Data(#"{"schema_version":2,"enabled":false}"#.utf8)
        #expect(throws: URLError.self) {
            try ReleaseNetworkSmokeRunner.validateEmergencyUpdateConfiguration(unsupportedNotice)
        }
    }
}
#endif
