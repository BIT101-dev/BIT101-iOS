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
    @Test(.timeLimit(.minutes(1)), arguments: ["complete", "fallback", "empty", "truncated", "wrong-start", "missing", "reversed", "duplicate", "drift", "wrong-response", "full-terminal"])
    @MainActor func eclassSmokeRequiresTheCompleteCoursePageSequence(stage: String) async throws {
        let collector = NetworkSmokeRequestCollector()
        let operation = {
            let selected = stage == "missing" ? [2] : stage == "truncated" ? [1]
                : stage == "reversed" ? [2, 1] : stage == "duplicate" ? [1, 1]
                : ["fallback", "empty", "full-terminal"].contains(stage) ? [1] : [1, 2]
            var courses = Set<Int>()
            for page in selected {
                let ids = stage == "empty" ? [] : stage == "full-terminal" ? Array(1...100) : [40 + page]
                courses.formUnion(ids)
                var request = URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn/api/my-courses"))
                request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["page": stage == "wrong-start" ? 99 : page,
                    "page_size": 100, "fields": "id,name", "conditions": [String: String]()])
                var body: [String: Any] = ["courses": ids.map { ["id": $0] }]
                if stage != "fallback" && stage != "full-terminal" {
                    body["page"] = stage == "wrong-response" ? 99 : page
                    body["pages"] = stage == "empty" ? 0 : stage == "drift" && page == 2 ? 3 : 2
                }
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                await HTTPRequestEvidenceContext.didReceive?(request, HTTPResponse(data: try JSONSerialization.data(withJSONObject: body), response: response))
            }
            for id in courses {
                let request = URLRequest(url: AppURL.required("https://zy-eclass.bit.edu.cn/api/courses/\(id)/activities"))
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                await HTTPRequestEvidenceContext.didReceive?(request, HTTPResponse(data: Data(), response: response))
            }
        }
        if ["complete", "fallback", "empty"].contains(stage) { try await collector.perform(operation, required: true) }
        else { await #expect(throws: NetworkSmokeRequestError.self) { try await collector.perform(operation, required: true) } }
    }
    @Test(arguments: [#"<a HREF = 'bit101://course/42'>打开</a>"#,
        #"<a class="open" href=bit101://course/42>打开</a>"#,
        #"<a title="x > y" href = "bit101&#58;//course/42">打开</a>"#,
        #"<script>const x = '<a href="wrong">';</script><a href="bit101://course/42">打开</a>"#,
        #"<div hidden><a href="wrong">隐藏</a></div><a href="bit101://course/42">打开</a>"#,
        #"<a style="display: none; display: block" href="bit101://course/42">打开</a>"#,
        #"<a href="bit101://course/42"><span>打开</span></a>"#,
        #"<a href="bit101://course/42"><img src="open.png"></a>"#,
        #"<a style="visibility:hidden;visibility:visible;opacity:0;opacity:1" href="bit101://course/42">打开</a>"#,
        #"<a style="opacity:100%" href="bit101://course/42">打开</a>"#,
        #"<dialog open><a href="bit101://course/42">打开</a></dialog>"#,
        #"<details open><a href="bit101://course/42">打开</a></details>"#,
        #"<details><summary><a href="bit101://course/42">打开</a></summary><p>内容</p></details>"#])
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
        #"<details><summary>说明</summary><summary><a href="bit101://course/42">打开</a></summary></details>"#])
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

        let html = Data("<!doctype html><html><head><title>BIT101</title></head><body>BIT101</body></html>".utf8)
        for invalid in ["<html><title>BIT101</title></html>", "<html><title>BIT101</title><body></body></html>", "<html></html>", "<html><title>登录</title></html>", "<html><script><title>BIT101</title></script></html>"] {
            #expect(throws: URLError.self) { try ReleaseNetworkSmokeRunner.validateHTMLResponse(Data(invalid.utf8), finalURL: URL(string: "https://bit101.cn/gallery/"), expectedHost: "bit101.cn") }
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

@MainActor
extension ReleaseNetworkSmokeLifecycleTests {
    @Test(.timeLimit(.minutes(1)), arguments: CommunityWriteSmoke.Kind.allCases)
    func directedRepliesUseEachProductionServiceAndPreserveTheirWireTarget(kind: CommunityWriteSmoke.Kind) async throws {
        let transport = CommentTransport()
        let operations = commentOperations(transport)
        let destination = CommunityWriteSmoke.CommentDestination(kind: kind, object: "comment42",
            replyObjectID: "comment43", replyUID: 7)
        let reply = try await operations.comment(destination, "功能验收", { _ in }, {})
        let payload = try #require(transport.submissions.last)
        #expect(payload["obj"] as? String == "comment42")
        #expect(payload["reply_obj"] as? String == "comment43" && payload["reply_uid"] as? Int == 7)
        #expect(payload["rate"] == nil && reply.rate == 0)
        #expect(reply.replyObj == "comment43" && reply.replyUser.id == 7)
        #expect(reply.images.count == (kind == .poster ? 1 : 0))
    }
    @Test(.timeLimit(.minutes(1))) func knownCommentReadsStopAtTheirPageAndRecoveryScansTheCompleteHistory() async throws {
        let transport = CommentTransport()
        let operations = commentOperations(transport)
        #expect(try await operations.comments("course42", [42]).map(\.id) == [42])
        #expect(transport.pages == ["new:0"])
        transport.pages.removeAll()
        #expect(Set(try await operations.comments("course42", nil).map(\.id)) == [41, 42])
        #expect(transport.pages == ["old:0", "old:1", "old:2"])
        transport.pages.removeAll()
        #expect(try await operations.comments("course42", [99]).allSatisfy { $0.id != 99 })
        #expect(transport.pages == ["new:0", "new:1", "new:2"])
    }
    private func commentOperations(_ transport: CommentTransport) -> CommunityWriteSmoke.Operations {
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        return .production(papers: PaperService(session: session), courses: CourseService(session: session),
            gallery: GalleryService(session: session, preferences: {
                CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
                    useWebView: false, hideMakeupOutliers: false)
            }))
    }
    private final class CommentTransport: HTTPTransport {
        var submissions: [[String: Any]] = []
        var pages: [String] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let response: Any
            if url.path == "/upload/image" {
                response = ["mid": "fixture-image", "url": "", "low_url": ""]
            } else if request.httpMethod == "POST" {
                let body = try #require(request.httpBody)
                let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                submissions.append(payload)
                response = comment(id: 44, object: payload["obj"] as? String ?? "", payload: payload)
            } else {
                let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)).queryItems ?? []
                let order = query.first { $0.name == "order" }?.value ?? ""
                let page = Int(query.first { $0.name == "page" }?.value ?? "0") ?? 0
                pages.append("\(order):\(page)")
                response = page < 2 ? [comment(id: order == "new" ? 42 - page : 41 + page, object: "course42")] : []
            }
            return (try JSONSerialization.data(withJSONObject: response),
                try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        private func comment(id: Int, object: String, payload: [String: Any] = [:]) -> [String: Any] {
            func user(_ id: Int) -> [String: Any] {
                ["id": id, "create_time": "", "nickname": "功能验收", "motto": "",
                    "avatar": ["mid": "", "url": "", "low_url": ""],
                    "identity": ["id": 1, "color": "", "text": "", "create_time": "", "update_time": ""]]
            }
            let mids = payload["image_mids"] as? [String] ?? []
            return ["id": id, "obj": object, "images": mids.map { ["mid": $0, "url": "", "low_url": ""] },
                "user": user(1), "anonymous": false, "create_time": "", "update_time": "", "like": false,
                "like_num": 0, "comment_num": 0, "own": true, "rate": payload["rate"] as? Int ?? 0,
                "reply_user": user(payload["reply_uid"] as? Int ?? 0), "reply_obj": payload["reply_obj"] as? String ?? "",
                "text": payload["text"] as? String ?? "功能验收", "sub": []]
        }
    }

    final class CommunityWorld {
        var followsTarget = true
        var account = 1
        var nextID = 100
        var contents: [String: CommunityWriteSmoke.Content] = [
            "poster77": .init(text: "原有内容", owned: true, liked: false),
            "course1": .init(text: "", owned: false, liked: true)]
        var rows: [String: [CommunityComment]] = [:]
        var delayedContents: [String: CommunityWriteSmoke.Content] = [:]
        var delayedRows: [String: [CommunityComment]] = [:]
        var delayedParent: String?
        var delayedFollow: Bool?
        var delayedCourseLike: Bool?
        var creationVisible = false
        var pending: Data?
        var commentDeletionRequests: [Int] = []
        var stage: String
        var injected = false
        var cancel: (() -> Void)?
        init(stage: String) { self.stage = stage }
        private func switchAccount(during operation: String) -> Bool {
            guard stage == "switch-" + operation, !injected else { return false }
            injected = true
            account = 2
            return true
        }
        private var user: CommunityUser { makeUser(1) }
        private func makeUser(_ id: Int) -> CommunityUser {
            CommunityUser(id: id, createTime: "", nickname: "功能验收", avatar: .init(mid: "", url: "", lowUrl: ""), motto: "",
                identity: .init(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
        }
        var operations: CommunityWriteSmoke.Operations {
            .init(identity: { .init(accountIdentifier: String(self.account)) }, account: { self.account }, course: { 1 }, create: { kind, text, record, submit in
                if self.stage == "upload-poster" { throw URLError(.networkConnectionLost) }
                if self.stage == "cancel-before-poster" { self.cancel?() }
                if self.stage == "invalid-paper" && kind == .paper {
                    throw NSError(domain: "BIT101.Paper", code: 400, userInfo: [NSLocalizedDescriptionKey: "参数错误awa"])
                }
                if self.stage == "signed-out-paper" && kind == .paper { throw PaperServiceError.notLoggedIn }
                if self.stage == "broken-image" { try record("fixture-image") }
                try submit()
                if self.stage == "unsent-poster" {
                    throw CommunityWriteSmoke.SubmissionNotSent(underlying: CancellationError())
                }
                self.nextID += 1
                let id = self.nextID
                self.contents[kind.rawValue + String(id)] = .init(text: text, owned: true, liked: false,
                    imageMids: [self.stage == "broken-image" ? "wrong" : "fixture-image"],
                    anonymous: self.stage == "create-anonymous-" + kind.rawValue,
                    publicAccess: self.stage == "create-public-" + kind.rawValue,
                    title: self.stage == "create-title" ? "错误标题" : kind == .poster ? "功能验收" : text,
                    intro: self.stage == "create-intro" ? "错误摘要" : text,
                    tags: self.stage == "create-tags" ? ["错误标签"] : [], claimID: self.stage == "create-claim" ? 1 : 0,
                    images: [.init(mid: "fixture-image", url: "https://fixture.invalid/image.jpg", lowUrl: "https://fixture.invalid/low.jpg")])
                if self.stage == "persistent-find", kind == .paper, !self.injected {
                    self.injected = true; throw URLError(.networkConnectionLost)
                }
                if ["late-" + kind.rawValue, "hidden-" + kind.rawValue].contains(self.stage), !self.injected {
                    self.injected = true
                    if self.stage.hasPrefix("late-") {
                        let key = kind.rawValue + String(id)
                        self.delayedContents[key] = self.contents.removeValue(forKey: key)
                    }
                    throw URLError(.networkConnectionLost)
                }
                if self.stage == "lost-poster" && !self.injected {
                    self.injected = true; throw URLError(.networkConnectionLost)
                }
                return id
            }, find: { kind, marker in
                if self.stage == "persistent-find" && kind == .paper { throw URLError(.timedOut) }
                if self.stage == "hidden-" + kind.rawValue, !self.creationVisible { return [] }
                return self.contents.compactMap { key, value in
                    guard key.hasPrefix(kind.rawValue), value.owned, value.text.hasPrefix(marker) else { return nil }
                    return Int(key.dropFirst(kind.rawValue.count))
                }
            }, read: { kind, id in
                if self.stage == "route-read" { throw NSError(domain: "BIT101.Gallery", code: 404) }
                if self.switchAccount(during: "read") { return nil }
                return self.contents[kind.rawValue + String(id)]
            }, edit: { kind, id, text in
                let key = kind.rawValue + String(id)
                self.contents[key] = .init(text: text, owned: true, liked: false, imageMids: ["fixture-image"],
                    anonymous: self.stage == "edit-anonymous-" + kind.rawValue,
                    publicAccess: self.stage == "edit-public-" + kind.rawValue,
                    title: self.stage == "edit-title" ? "错误标题" : kind == .poster ? "功能验收" : text,
                    intro: self.stage == "edit-intro" ? "错误摘要" : text,
                    tags: self.stage == "edit-tags" ? ["错误标签"] : [], claimID: self.stage == "edit-claim" ? 1 : 0)
            }, delete: { kind, id in
                try Task.checkCancellation()
                if self.stage == "persistent-delete" && kind == .paper { throw URLError(.timedOut) }
                if self.switchAccount(during: "delete") { throw NSError(domain: "fixture", code: 404) }
                if self.stage == "cleanup-failure" && !self.injected { self.injected = true; throw URLError(.timedOut) }
                self.contents[kind.rawValue + String(id)] = nil
            }, comments: { parent, _ in
                if self.stage == "route-comments" { throw NSError(domain: "BIT101.Gallery", code: 404) }
                if self.switchAccount(during: "comments") { return [] }
                if self.delayedParent == parent, !self.creationVisible { return [] }
                if self.stage == "deleted-parent-read", parent.hasPrefix("comment"),
                   let id = Int(parent.dropFirst(7)), !self.rows.values.joined().contains(where: { $0.id == id }) {
                    throw NSError(domain: "BIT101.Gallery", code: 500, userInfo: [NSLocalizedDescriptionKey: "获取顶级对象失败Orz"])
                }
                return self.rows[parent] ?? []
            }, comment: { destination, text, _, submit in
                let object = destination.object
                if self.stage == "upload-comment" { throw URLError(.networkConnectionLost) }
                if self.stage == "cancel-before-comment" { self.cancel?() }
                try submit()
                self.nextID += 1
                @MainActor func makeComment(_ id: Int, readback: Bool = false) -> CommunityComment {
                    let reply = object.hasPrefix("comment")
                    let wrongRate = self.stage == "wrong-rating" || self.stage == "readback-rating" && readback
                    return CommunityComment(id: id, obj: object, images: [.init(mid: "fixture-image", url: "", lowUrl: "")],
                        user: self.user, anonymous: self.stage == "anonymous-reply" && reply,
                        createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: true,
                        rate: object.hasPrefix("course") && !wrongRate ? 6 : 0,
                        replyUser: self.makeUser((self.stage == "wrong-reply-user" && reply || self.stage == "wrong-directed-user" && destination.replyUID != nil) ? 77 : destination.replyUID ?? 0),
                        replyObj: (self.stage == "wrong-reply-object" && reply || self.stage == "wrong-directed-object" && destination.replyObjectID != nil) ? "comment77" : destination.replyObjectID ?? "", text: text, sub: [])
                }
                let value = makeComment(self.nextID)
                self.rows[object, default: []].append(makeComment(self.nextID, readback: true))
                let createdKind = destination.replyObjectID != nil ? "directed" : object.hasPrefix("comment") ? "reply" : "comment"
                if ["late-" + createdKind, "hidden-" + createdKind].contains(self.stage), !self.injected {
                    self.injected = true; self.delayedParent = object
                    if self.stage.hasPrefix("late-") { self.delayedRows[object] = self.rows.removeValue(forKey: object) }
                    throw URLError(.networkConnectionLost)
                }
                if object.hasPrefix("comment") && !self.injected && ["lost-reply", "cancelled"].contains(self.stage) {
                    self.injected = true; self.cancel?(); throw CancellationError()
                }
                if self.stage == "duplicate-comments", object.hasPrefix("comment"), let main = Int(object.dropFirst(7)) {
                    return makeComment(main)
                }
                return value
            }, deleteComment: { id in
                try Task.checkCancellation()
                self.commentDeletionRequests.append(id)
                if self.stage == "silent-comment-delete" { return }
                if self.stage == "missing-comment" { throw NSError(domain: "fixture", code: 404) }
                if self.switchAccount(during: "comment-delete") { throw NSError(domain: "fixture", code: 404) }
                for parent in self.rows.keys { self.rows[parent]?.removeAll { $0.id == id } }
                if self.stage == "lost-delete-response" && !self.injected {
                    self.injected = true
                    throw URLError(.networkConnectionLost)
                }
            }, like: { kind, id in
                let key = kind.rawValue + String(id)
                let old = try #require(self.contents[key])
                if self.stage == "late-course-toggle", kind == .course {
                    self.delayedCourseLike = !old.liked
                    throw URLError(.timedOut)
                }
                if self.stage == "persistent-like" && kind == .course {
                    if !self.injected {
                        self.injected = true
                        self.contents[key] = .init(text: old.text, owned: old.owned, liked: !old.liked, imageMids: old.imageMids,
                            anonymous: old.anonymous, publicAccess: old.publicAccess)
                    }
                    throw URLError(.timedOut)
                }
                self.contents[key] = .init(text: old.text, owned: old.owned, liked: !old.liked, imageMids: old.imageMids,
                    anonymous: old.anonymous, publicAccess: old.publicAccess)
                return !old.liked
            }, likeComment: { _, id in
                let parent = try #require(self.rows.first(where: { $0.value.contains(where: { $0.id == id }) })?.key)
                let index = try #require(self.rows[parent]?.firstIndex(where: { $0.id == id }))
                let current = try #require(self.rows[parent]?[index])
                let changed = !current.like
                if self.stage != "comment-like-noop" && !(self.stage == "comment-like-restore" && current.like) {
                    self.rows[parent]?[index] = current.updatingLike(changed, likeNum: changed ? 1 : 0)
                }
                return changed
            }, verifyImages: { images in
                guard !images.isEmpty, self.stage != "image-download" else { throw URLError(.cannotDecodeContentData) }
            }, followTarget: { 2 }, following: { _ in self.followsTarget }, follow: { _ in
                if self.stage == "late-follow-toggle" {
                    self.delayedFollow = !self.followsTarget
                    throw URLError(.timedOut)
                }
                if self.stage == "follow-noop" || (self.stage == "follow-restore-noop" && !self.followsTarget) {
                    return self.followsTarget
                }
                self.followsTarget.toggle()
                if self.stage == "persistent-follow" { throw URLError(.timedOut) }
                return self.stage == "follow-response-mismatch" ? !self.followsTarget : self.followsTarget
            })
        }
        var smoke: CommunityWriteSmoke {
            .init(operations: operations, load: { self.pending }, save: { self.pending = $0 })
        }
    }

}
#endif

#if DEBUG
extension NetworkEvidenceProjectionTests {
    @Test(arguments: ["registered", "header-missing", "other-host", "other-path"])
    func encryptedSchoolEvidenceUsesItsRegisteredBodyFormat(stage: String) throws {
        let host = stage == "other-host" ? "example.invalid" : "sso.bit.edu.cn"
        let path = stage == "other-path" ? "other" : "getPhoneNumberByUserId"
        let url = try #require(URL(string: "https://\(host)/cas/api/protected/sms/\(path)"))
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stage != "header-missing" { request.setValue("true", forHTTPHeaderField: "hasCrypto") }
        request.httpBody = Data("fixture-encrypted-secret".utf8)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let evidence = NetworkSmokeHTTPRequestEvidence(request: request, response: response)
        #expect(evidence.ambiguousParameters == (stage == "registered" ? nil : ["JSON"]))
        #expect(evidence.finalAmbiguousParameters == evidence.ambiguousParameters && evidence.bodyParameterNames.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self).contains("fixture-encrypted-secret"))
    }
}
#endif

#if DEBUG
let smokePaperContent = #"{"blocks":[{"type":"header","data":{"text":"Title","level":1}},{"type":"paragraph","data":{"text":"Readable <b>body</b>"}},{"type":"image","data":{"file":{"url":"https://image.invalid/paper.png"}}}]}"#
extension ReleaseNetworkSmokeLifecycleTests {
    private final class Services: NetworkSmokeGalleryServicing, NetworkSmokeCourseServicing, NetworkSmokePaperServicing,
        NetworkSmokeMineServicing, NetworkSmokeScheduleServicing, ScoreListServicing, TrustedTranscriptServicing {
        let stage: String
        let image: Data
        var rawResponse: ((Data) -> Void)?
        var observed = Set<String>()
        var webvpnVerified = false
        var ssoVerified = false
        private var verificationChallenge: BITLoginAuthenticationChallenge { .init(challengeID: "fixture", accessToken: "fixture", status: "sms_required", maskedPhone: "***", expiresIn: 60) }
        init(stage: String, image: Data) { self.stage = stage; self.image = image }
        private var user: CommunityUser {
            CommunityUser(id: 1, createTime: "", nickname: "fixture", avatar: CommunityImage(mid: "image", url: "https://image.invalid/image.png", lowUrl: ""), motto: "",
                identity: CommunityIdentity(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
        }
        private var poster: CommunityPoster {
            makePoster(id: 1, likes: 2, date: "2026-01-02T00:00:00Z")
        }
        private func makePoster(id: Int, likes: Int, date: String) -> CommunityPoster {
            CommunityPoster(anonymous: false, claim: CommunityClaim(id: 1, text: "fixture"), commentNum: 0, createTime: date, editTime: "", id: id, images: [user.avatar],
                likeNum: likes, public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
        }
        private func comment(object: String, id: Int = 1, likes: Int = 0, date: String = "2026-01-01T00:00:00Z") -> CommunityComment {
            CommunityComment(id: id, obj: object, images: [], user: user, anonymous: false,
                createTime: date, updateTime: "", like: false, likeNum: likes, commentNum: 0, own: false,
                rate: 0, replyUser: user, replyObj: "", text: "fixture", sub: [])
        }
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            observed.insert("gallery-\(kind.rawValue)"); return posterPage(page ?? 0)
        }
        private func posterPage(_ page: Int) -> GalleryPageBatch<CommunityPoster> {
            if stage == "feed-images-missing-success" {
                let value = CommunityPoster(anonymous: false, claim: poster.claim, commentNum: 0, createTime: poster.createTime, editTime: "", id: page + 1,
                    images: [],
                    likeNum: 0, public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
                return .init(items: page < 2 ? [value] : [], nextSourcePage: page + 1, canLoadMore: page == 0)
            }
            return .init(items: page == 0 ? [poster] : [], nextSourcePage: page + 1, canLoadMore: false)
        }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> { posterPage(sourcePage) }
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            let batch = posterPage(startPage)
            if stage == "bot-classification-failure" { return batch }
            let items = (stage == "bot-empty-gap" ? [] : batch.items).map {
                CommunityPoster(anonymous: $0.anonymous, claim: $0.claim, commentNum: $0.commentNum, createTime: $0.createTime,
                    editTime: $0.editTime, id: $0.id, images: $0.images, likeNum: $0.likeNum, public: $0.public,
                    tags: ["BOT"], text: $0.text, title: $0.title, updateTime: $0.updateTime, user: $0.user)
            }
            return .init(items: items, nextSourcePage: batch.nextSourcePage, canLoadMore: batch.canLoadMore, sourceIDs: batch.sourceIDs)
        }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            observed.insert("gallery-search-\(query.order.rawValue)")
            if query.text == NetworkSmokePaging.excludedSearchText && stage != "gallery-search-ignored-failure" {
                return .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
            }
            if query.text.isEmpty {
                let second = makePoster(id: 2, likes: 1, date: "2026-01-01T00:00:00Z")
                let reversed = stage == "poster-\(query.order.rawValue)-order-failure"
                return .init(items: (page ?? 0) == 0 ? (reversed ? [second, poster] : [poster, second]) : [],
                    nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
            }
            return .init(items: (page ?? 0) == 0 ? [makePoster(id: stage == "gallery-search-target-failure" ? 1 : 41, likes: 2, date: "2026-01-02T00:00:00Z")] : [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts { GalleryMessageUnreadCounts() }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] {
            observed.insert("message-read")
            guard stage != "message-empty-gap", let lastID, lastID > 8 else { return [] }
            let id = lastID == Int.max ? 9 : 8
            return try JSONDecoder().decode([GalleryMessage].self,
                from: Data("[{\"fromUser\":{},\"id\":\(id),\"linkObj\":\"poster1\",\"obj\":\"poster1\",\"text\":\"\",\"updateTime\":\"\"}]".utf8))
        }
        func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
            observed.insert("fixture-poster-\(id)")
            if stage == "maintained-fixtures-success", id == 1 { throw URLError(.resourceUnavailable) }
            return GalleryPosterDetail(anonymous: false, claim: poster.claim, commentNum: 0, createTime: "", editTime: "", id: stage == "entity-identity-failure" ? id + 1 : id,
                images: stage == "fixture-image-missing-failure" ? [] : [.init(mid: "fixture", url: "https://image.invalid/fixture.png", lowUrl: "")],
                like: false, likeNum: 0, own: false, plugins: "", public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
        }
        func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment> {
            observed.insert("gallery-comments-\(page ?? 0)")
            observed.insert("gallery-order-\(order.rawValue)")
            if stage == "gallery-comment-ranking-failure", order == .like {
                return .init(items: [comment(object: objectID, likes: 1), comment(object: objectID, id: 2, likes: 2)],
                    nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
            }
            if stage == "gallery-comment-page-failure", page != nil { throw URLError(.cannotParseResponse) }
            if stage == "gallery-comment-page-failure" { return .init(items: [comment(object: objectID)], nextSourcePage: 3, canLoadMore: true) }
            return .init(items: orderedComments(objectID, order: order, page: page ?? 0), nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        private func orderedComments(_ object: String, order: CommunityCommentOrder, page: Int) -> [CommunityComment] {
            guard page == 0 else { return [] }
            let values = [comment(object: object, likes: 2, date: "2026-01-02T00:00:00Z"),
                comment(object: object, id: 2, likes: 1)]
            return order == .oldest ? Array(values.reversed()) : values
        }
        func fetchClaims() async throws -> [CommunityClaim] { [poster.claim] }
        func fetchSubscriptions(page: Int) async throws -> [GallerySubscription] { [] }
        func fetchReportTypes() async throws -> [GalleryReportType] {
            let data = stage == "report-types-empty-gap" ? "[]" : stage == "report-types-duplicate-failure"
                ? #"[{"id":1,"text":"first"},{"id":1,"text":"second"}]"# : stage == "report-types-text-failure"
                ? #"[{"id":1,"text":"  "}]"# : #"[{"id":1,"text":"fixture"}]"#
            return try JSONDecoder().decode([GalleryReportType].self, from: Data(data.utf8))
        }
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            if search == NetworkSmokePaging.excludedSearchText && stage != "course-search-ignored-failure" { return [] }
            if !search.isEmpty { observed.insert("course-search-\(search)-\(page)") }
            if stage == "empty-list-failure" { return [] }
            guard page == 0 || stage == "repeated-page-failure" || !search.isEmpty && stage == "course-search-later-success" && page <= 2 else { return [] }
            let id = search.isEmpty || stage == "course-search-target-failure" ? 1 : stage == "course-search-later-success" && page < 2 ? page + 1 : 43
            return [CourseSummary(detail: CourseDetail(id: id, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false))]
        }
        func fetchCourse(id: Int) async throws -> CourseDetail {
            observed.insert("course-detail")
            observed.insert("fixture-course-\(id)")
            if stage == "maintained-fixtures-success", id == 1 { throw URLError(.resourceUnavailable) }
            if stage == "community-failure" { throw URLError(.timedOut) }
            return CourseDetail(id: stage == "entity-identity-failure" ? id + 1 : id, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false)
        }
        func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] {
            [.init(term: "2026-2027-1", avgScore: stage == "course-history-statistics-failure" ? 101 : 85, maxScore: 100, studentNum: 30)]
        }
        func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment] {
            observed.insert("course-comments-\(page ?? 0)")
            if stage == "course-comment-ranking-failure" {
                return [comment(object: "course\(courseID)"), comment(object: "course\(courseID)", id: 2, date: "2026-01-02T00:00:00Z")]
            }
            if stage == "course-comment-page-failure" { return [comment(object: "course\(courseID)")] }
            return orderedComments("course\(courseID)", order: .newest, page: page ?? 0)
        }
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            if search == NetworkSmokePaging.excludedSearchText && stage != "paper-search-ignored-failure" { return [] }
            observed.insert("paper-list")
            if let search { observed.insert("paper-search-\(search)-\(page)") }
            if stage == "paper-default-date-failure", search != nil { return [] }
            if stage == "empty-list-failure" { return [] }
            if stage == "paper-\(order.requestValue ?? "newest")-order-failure" || stage == "paper-newest-date-failure" && order == .newest || stage == "paper-default-date-failure" {
                return page == 0 ? (0..<2).map { index in
                    PaperSummary(id: index + 1, title: "fixture", intro: "", likeNum: index, commentNum: index,
                        updateTime: stage.contains("-date-") ? "invalid" : index == 0 ? "2026-01-01T00:00:00Z" : "2026-01-02T00:00:00Z")
                } : []
            }
            guard page == 0 else { return [] }
            return [PaperSummary(id: search == nil || stage == "paper-search-target-failure" ? 1 : 45, title: "fixture", intro: "", likeNum: 2, commentNum: 2, updateTime: "2026-01-02T00:00:00Z"),
                PaperSummary(id: 2, title: "fixture", intro: "", likeNum: 1, commentNum: 1, updateTime: "2026-01-01T00:00:00Z")]
        }
        func fetchPaper(id: Int) async throws -> PaperDetail {
            observed.insert("fixture-paper-\(id)")
            if stage == "maintained-fixtures-success", id == 1 { throw URLError(.resourceUnavailable) }
            let content = stage.contains("paper-media-") ? smokePaperContent.replacingOccurrences(of: "\"url\":\"https://image.invalid/paper.png\"", with: "\"url\":\"https://image.invalid/paper.png\",\"low_url\":\"https://image.invalid/paper-low.png\"") : smokePaperContent
            return PaperDetail(id: stage == "entity-identity-failure" ? id + 1 : id, title: "fixture", intro: "", content: stage == "paper-content-failure" ? "" : content, createTime: "", updateTime: "", updateUser: user,
                anonymous: false, likeNum: 0, commentNum: 0, publicEdit: false, like: false, own: false)
        }
        func fetchPreviewMetadata(id: Int) async throws -> PaperPreviewMetadata { try await fetchPaper(id: id).previewMetadata }
        func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment] {
            observed.insert("paper-comments-\(page ?? 0)")
            observed.insert("paper-order-\(order.rawValue)")
            if stage == "paper-comment-ranking-failure", order == .oldest {
                return [comment(object: "paper\(paperID)", date: "2026-01-02T00:00:00Z"),
                    comment(object: "paper\(paperID)", id: 2)]
            }
            if stage == "paper-comment-page-failure", page != nil { throw URLError(.cannotParseResponse) }
            return stage == "paper-comment-page-failure" ? [comment(object: "paper\(paperID)")] : orderedComments("paper\(paperID)", order: order, page: page ?? 0)
        }
        func fetchMyInfo() async throws -> MineUserInfo { observed.insert("mine"); return try await fetchUserInfo(id: 1) }
        func fetchUserInfo(id: Int) async throws -> MineUserInfo { MineUserInfo(user: user, followingNum: 0, followerNum: 0, following: false, follower: false, own: true) }
        func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster] { page == 0 ? [poster] : [] }
        func fetchMyPosters(page: Int) async throws -> [CommunityPoster] { page == 0 ? [poster] : [] }
        func fetchFollowers(page: Int) async throws -> [CommunityUser] { [] }
        func fetchFollowings(page: Int) async throws -> [CommunityUser] { [] }
        func fetchCurrentTermOnly() async throws -> String {
            if stage.hasPrefix("all-sms-") && stage != "all-sms-not-required" && !webvpnVerified { throw ScheduleServiceError.secondFactorRequired(verificationChallenge) }
            return "fixture-1"
        }
        func fetchAvailableTerms() async throws -> [String] { ["fixture-1"] }
        func syncCourses(term: String?) async throws -> CourseSyncPayload {
            observed.insert("schedule")
            rawResponse?(Data("course-response".utf8))
            let exams: [ExamRecord] = stage == "invalid-exam-failure" || stage == "pending-exam-success"
                ? [.init(id: "exam", term: "fixture-1", name: stage == "invalid-exam-failure" ? "" : "待排课程", courseID: "",
                    teacher: "", classroom: "", dateString: "", beginTime: "", endTime: "", examMode: "", seatID: "")] : []
            let pending = stage == "pending-course-gap"
            let courses: [CourseRecord] = stage == "empty-course-gap" ? [] : [.init(id: "course", term: term ?? "fixture-1", name: "课程", teacher: "", classroom: "",
                description: "", weeks: pending ? [] : [1, 3, 5], weekday: pending ? 0 : 1, startSection: pending ? 0 : 1, endSection: pending ? 0 : 2,
                campus: "", number: "CS101", credit: 1, hour: 1, type: "", category: "", department: "")]
            return CourseSyncPayload(term: stage == "schedule-term-failure" ? "other-term" : term ?? "fixture-1", firstDayString: "2026-03-02", sourceFirstDayString: "2026-03-02",
                normalizationOffset: 0, rawWeeksByCourse: courses.map(\.weeks), sourceDisplayWeeksByCourse: courses.map { _ in nil }, courses: courses, exams: exams)
        }
        func submitVerificationCodeForTeachingCenterAuthentication(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws { webvpnVerified = true }
        func prepareTeachingCenterAccess() async throws {}
        func fetchCampuses() async throws -> [CampusRecord] { [CampusRecord(id: "campus", name: "fixture", code: "campus")] }
        func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] { [BuildingRecord(id: "building", name: "fixture", buildingCode: "building", campusName: "fixture", campusCode: stage == "campus-selection-failure" ? "other" : "campus")] }
        var classroomDate: Date?
        func fetchClassrooms(buildingID: String, term: String, date: Date) async throws -> [ClassroomRecord] {
            classroomDate = date
            if stage == "empty-classroom-gap" { return [] }
            return [ClassroomRecord(id: "room", name: "fixture", busyTimeCodes: stage == "invalid-classroom-failure" ? [0] : [])]
        }
        func fetchEclassDDLEvents(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> EclassDDLResult {
            if stage.hasPrefix("all-sms-") && stage != "all-sms-not-required" && !ssoVerified {
                let handler = try #require(schoolSMSCodeHandler)
                _ = try await handler(.init(maskedPhone: "***", purpose: "school_sso_second_factor"))
                ssoVerified = true
            }
            return try await fetchEclassDDLEventsForPreflight()
        }
        func fetchEclassDDLEventsForPreflight() async throws -> EclassDDLResult {
            observed.insert("eclass")
            return EclassDDLResult(events: [], courseCount: 1, activityCount: 0, activityTypes: [:], homeworkWithoutDeadlineCount: 0)
        }
        func refreshLexueCalendarURL(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> String { try await refreshLexueCalendarURLForPreflight() }
        func refreshLexueCalendarURLForPreflight() async throws -> String { "https://lexue.bit.edu.cn/fixture.ics" }
        func syncDDLEventsForPreflight(existingEvents: [DDLEventRecord], storedURL: String) async throws -> DDLSyncPayload {
            observed.insert("lexue")
            if stage == "ddl-failure" { throw URLError(.timedOut) }
            if stage == "ddl-invalid-calendar-failure" { throw ScheduleServiceError.invalidCalendarData }
            return DDLSyncPayload(url: storedURL, events: [])
        }
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge {
            if stage.hasPrefix("all-sms-") && stage != "all-sms-not-required" { throw ScoreServiceError.secondFactorRequired(verificationChallenge) }
            return BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "fixture", status: "authenticated", maskedPhone: nil, expiresIn: 60) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] {
            return [ScoreRow(index: 0, headers: ["序号", "课程编号", "课程名称", "成绩", "开课学期", "学分"],
                values: ["1", "CS101", "课程", stage == "all-score-mismatch-failure" && detail ? "80" : "90", "2025", "2"])]
        }
        func submitScoreVerificationCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { .init(challengeID: "fixture", accessToken: "fixture", status: "authenticated", maskedPhone: nil, expiresIn: 60) }
        func fetchTrustedTranscriptPages(onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages {
            if stage.hasPrefix("all-sms-") && stage != "all-sms-not-required" { throw ScoreServiceError.secondFactorRequired(verificationChallenge) }
            return .init([image])
        }
        func submitTranscriptVerificationCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { return challenge }
        func fetchTrustedTranscriptPages(authenticatedBy challenge: BITLoginAuthenticationChallenge, onPage: TrustedTranscriptPageDelivery?) async throws -> TrustedTranscriptPages { .init([image]) }
    }
    private final class External: HTTPTransport {
        let image: Data
        let redirectHost: String?
        let aasaStage: String
        var requests: [URLRequest] = []
        var imageBudgets: [Int?] = []
        init(image: Data, redirectHost: String? = nil, aasaStage: String = "") {
            self.image = image; self.redirectHost = redirectHost; self.aasaStage = aasaStage
        }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            if let path = request.url?.path, path.hasSuffix(".jpg") || path.hasSuffix(".png") {
                imageBudgets.append(maximumBytes)
                if aasaStage == "image-budget-failure", maximumBytes != nil { throw HTTPClientError.responseTooLarge }
            }
            let result = try await data(for: request)
            if let maximumBytes, result.0.count > maximumBytes { throw HTTPClientError.responseTooLarge }
            return result
        }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let url = try #require(request.url)
            var finalURL = url
            let data: Data
            var status = 200
            var headers: [String: String] = [:]
            if request.httpMethod == "OPTIONS" {
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://bit101.cn")
                #expect(request.value(forHTTPHeaderField: "Access-Control-Request-Method") == "POST")
                #expect(request.value(forHTTPHeaderField: "Access-Control-Request-Headers") == "content-type")
                data = Data(); status = 204; headers["Access-Control-Allow-Origin"] = "*"
                headers["Access-Control-Allow-Methods"] = aasaStage == "cors-method-failure" ? "OPTIONS" : "post, OPTIONS"
                headers["Access-Control-Allow-Headers"] = aasaStage == "cors-header-failure" ? "x-custom" : "Content-Type"
            } else if url.path.hasSuffix("apple-app-site-association") {
                let json = #"{"applinks":{"details":[{"appID":"Y2T72736G3.BIT101-dev.BIT101-iOS","paths":["/gallery/*","/course/*","/paper/*"]}]}}"#
                data = Data((aasaStage == "aasa-exclusion-failure" ? json.replacingOccurrences(of: "\"/gallery/*\"", with: "\"NOT /gallery/*\",\"/gallery/*\"") : json).utf8)
                headers["Content-Type"] = aasaStage == "aasa-mime-failure" ? "text/plain" : "application/json"
                if aasaStage == "aasa-redirect-failure" { status = 302; headers["Location"] = "/association" }
                if aasaStage == "aasa-followed-redirect-failure" { finalURL = AppURL.required("https://open.aihelpme.dev/association") }
            } else if url.host == "itunes.apple.com" {
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "requestTime" } == true)
                #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
                #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                data = Data(#"{"resultCount":1,"results":[{"version":"1.0","bundleId":"BIT101-dev.BIT101-iOS","currentVersionReleaseDate":"2026-01-01T00:00:00Z","trackViewUrl":"https://apps.apple.com/app/id6761147125"}]}"#.utf8)
            } else if url.host == "update.aihelpme.dev" {
                data = Data(#"{"schema_version":1,"enabled":false}"#.utf8)
            } else if url.path.hasSuffix(".jpg") || url.path.hasSuffix(".png") {
                if aasaStage == "paper-image-failure", url.path == "/paper.png" { throw URLError(.resourceUnavailable) }
                if aasaStage == "paper-media-original-failure", url.path == "/paper.png" { throw URLError(.resourceUnavailable) }
                if aasaStage == "paper-media-thumbnail-failure", url.path == "/paper-low.png" { throw URLError(.resourceUnavailable) }
                data = image
            } else {
                if url.path.isEmpty || url.path == "/" { finalURL = try #require(URL(string: "https://bit101.cn/gallery/")) }
                data = Data("<html><title>BIT101</title><body><a href=\"bit101:/\(url.path)\">fixture</a></body></html>".utf8)
            }
            if url.host == redirectHost { status = 302 }
            return (data, try #require(HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: nil, headerFields: headers)))
        }
    }
    @Test("Full smoke orchestration preserves success, intermediate failures and subsequent scopes", .timeLimit(.minutes(1)), arguments:
        ["gallery-search-ignored-failure", "course-search-ignored-failure", "paper-search-ignored-failure", "bot-empty-gap", "gallery-search-target-failure", "message-empty-gap", "all-success", "all-sms-success", "all-sms-not-required", "all-sms-community-login-failure", "all-sms-community-login-empty-failure", "all-sms-app-store-failure", "community-failure", "schedule-success", "ddl-success", "ddl-failure", "ddl-invalid-calendar-failure", "raw-write-failure",
         "app-store-redirect-failure", "emergency-redirect-failure", "aasa-redirect-failure", "aasa-followed-redirect-failure",
         "aasa-mime-failure", "aasa-exclusion-failure", "image-budget-failure", "entity-identity-failure", "repeated-page-failure",
         "gallery-comment-page-failure", "course-comment-page-failure", "paper-comment-page-failure", "gallery-comment-ranking-failure", "paper-comment-ranking-failure", "cors-method-failure", "cors-header-failure",
         "schedule-term-failure", "historical-term-success", "maintained-fixtures-success", "feed-images-missing-success", "fixture-image-missing-failure",
         "missing-fixtures-failure", "fixture-course-number-failure", "empty-list-failure", "all-score-mismatch-failure",
         "bot-classification-failure", "paper-like-order-failure", "paper-comment-order-failure", "paper-newest-date-failure", "paper-default-date-failure", "paper-content-failure", "paper-image-failure", "campus-selection-failure",
         "invalid-exam-failure", "pending-exam-success", "empty-course-gap", "pending-course-gap", "invalid-classroom-failure", "empty-classroom-gap", "paper-media-success", "paper-media-original-failure", "paper-media-thumbnail-failure",
         "school-independent-success", "transcript-independent-success", "schedule-independent-success", "ddl-independent-success",
         "course-comment-ranking-failure", "course-history-statistics-failure", "poster-like-order-failure", "poster-new-order-failure", "message-account-missing-failure", "message-account-mismatch-failure", "course-search-target-failure", "paper-search-target-failure", "course-search-later-success", "report-types-empty-gap", "report-types-duplicate-failure", "report-types-text-failure"])
    func completeOrchestration(stage: String) async throws {
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }.pngData())
        let services = Services(stage: stage, image: image)
        let productionServices = Services(stage: stage, image: image)
        let redirectHost = stage == "app-store-redirect-failure" || stage == "all-sms-app-store-failure" ? "itunes.apple.com"
            : stage == "emergency-redirect-failure" ? "update.aihelpme.dev" : nil
        let external = External(image: image, redirectHost: redirectHost, aasaStage: stage)
        let association = External(image: image, aasaStage: stage)
        let externalClient = HTTPClient(transport: external, observer: nil)
        let files = PreferenceMemoryFiles()
        let media = AppMedia.makeEnvironment(files: files, previewStorage: MediaPreviewStorage(files: files),
            imageHTTPClient: externalClient, avatarHTTPClient: externalClient)
        var reports: [ReleaseNetworkSmokeReport] = []
        var feedback = 0
        var rawWrites = 0
        var loginChecks = 0
        let sessionEvidence = ["初始账号资料 ID：1", "无效凭据切换：认证拒绝", "恢复账号资料 ID：1"]
        let dependencies = ReleaseNetworkSmokeDependencies(requiresRequestEvidence: false, checkLogin: {
            loginChecks += 1
            if stage == "all-sms-community-login-empty-failure" { return nil }
            if stage.contains("independent") || stage == "all-sms-community-login-failure" { throw URLError(.notConnectedToInternet) }
            return "fixture"
        }, writeReport: { reports.append($0) },
            clearRawCourseResponse: {}, writeRawCourseResponse: { _, runID in
                rawWrites += 1
                #expect(runID == stage)
                if stage == "raw-write-failure" { throw CocoaError(.fileWriteNoPermission) }
            }, makeGallery: { services }, makeCourses: { services }, makePapers: { services }, makeMine: { services },
            productionSessionProbe: { sessionEvidence }, externalHTTPClient: externalClient,
            imageProbe: { try await media.verifyRemoteImage(at: $0) }, aasaHTTPClient: HTTPClient(transport: association, observer: nil),
            feedbackProbe: { _ in feedback += 1 },
            loadScheduleCache: { ScheduleCache() }, makeScores: { services }, makeSchedule: { handler in services.rawResponse = handler; return services },
            makeProductionSchedule: { productionServices }, makeEclassSchedule: { services })
        let scope: NetworkSmokeScope = stage.hasPrefix("gallery-search-") || stage == "message-empty-gap" || stage == "course-history-statistics-failure" || stage.hasPrefix("course-search-") || stage.hasPrefix("poster-") || stage.hasPrefix("message-account-") || stage.hasPrefix("report-types-") ? .bit101 : stage.hasPrefix("school-") ? .school : stage.hasPrefix("transcript-") ? .transcript : stage.hasPrefix("all-") || redirectHost != nil || stage.hasPrefix("aasa") ? .all : stage == "community-failure" || stage == "image-budget-failure" || stage == "entity-identity-failure" || stage == "repeated-page-failure" || stage.contains("comment-page") || stage.contains("comment-ranking") || stage.hasPrefix("cors") || stage.hasPrefix("bot-") || stage.hasPrefix("paper-") || stage.contains("fixtures") || stage == "feed-images-missing-success" || stage == "fixture-image-missing-failure" || stage == "fixture-course-number-failure" || stage == "empty-list-failure" ? .bit101 : stage.hasPrefix("ddl") ? .ddl : .schedule
        let runner = ReleaseNetworkSmokeRunner(dependencies: dependencies)
        let smsHandler: SchoolSMSCodeHandler = { _ in "fixture-code" }
        let report = await runner.run(scope: scope, runID: stage, capture: stage == "raw-write-failure" ? .rawCourseResponse : .none,
            term: stage == "historical-term-success" ? "historical-1" : nil, communityExpectedAccount: stage == "message-account-missing-failure" ? nil : stage == "message-account-mismatch-failure" ? 2 : 1,
            fixtures: stage == "missing-fixtures-failure" ? nil : NetworkSmokeFixtures(posterID: 41, courseID: 43,
                courseNumber: stage == "fixture-course-number-failure" ? "OTHER" : "COURSE", paperID: 45),
            schoolSMSCodeHandler: stage.hasPrefix("all-sms-") ? smsHandler : nil)
        if scope.includes(.bit101) && !stage.contains("community-login") {
            #expect(services.observed.isSuperset(of: ["gallery-follow", "gallery-hot", "gallery-newest"]))
            #expect(report.executedProbes.contains("gallery.following") && report.executedProbes.contains("gallery.hot"))
        }
        #expect(report.passed == (!stage.hasSuffix("failure") || stage == "missing-fixtures-failure" || stage.hasPrefix("report-types-")), "\(stage): \(report.failures)")
        if stage == "all-success" || stage == "maintained-fixtures-success" {
            #expect(services.observed.isSuperset(of: ["course-search-COURSE-0", "course-search-COURSE-1", "paper-search-fixture-0", "paper-search-fixture-1"]))
            #expect(report.executedProbes.contains("course.search") && report.executedProbes.contains("paper.search"))
        }
        if stage.contains("search-target-failure") || stage.contains("search-ignored-failure") { #expect(report.failures.contains { $0.contains(stage.hasPrefix("course-") ? "course.search" : stage.hasPrefix("gallery-") ? "gallery.search" : "paper.search") }) }
        if stage == "course-search-later-success" { #expect(services.observed.contains("course-search-COURSE-2")) }
        if stage.hasPrefix("poster-") { #expect(report.failures.contains { $0.contains("gallery.search") }) }
        if stage.hasPrefix("report-types-") {
            let exempted = Set(["community.report-types", "message.follow", "message.system", "message.like", "message.comment"])
            #expect(report.coverageComplete && Set(report.exemptedProbes.keys) == exempted)
            #expect(exempted.isDisjoint(with: report.executedProbes) && exempted.isDisjoint(with: report.requestEvidence.map(\.probe)))
        }
        if stage == "course-comment-ranking-failure" { #expect(report.failures.contains { $0.contains("course.comments") }) }
        if stage.hasPrefix("message-account-") { #expect(report.failures.count == 1 && !services.observed.contains("message-read")) }
        if stage == "course-history-statistics-failure" { #expect(report.failures.contains { $0.contains("course.history") }) }
        if stage == "maintained-fixtures-success" {
            #expect(services.observed.isSuperset(of: GallerySearchOrder.allCases.map { "gallery-search-\($0.rawValue)" }))
            for kind in ["gallery", "paper"] {
                #expect(services.observed.isSuperset(of: CommunityCommentOrder.allCases.map { "\(kind)-order-\($0.rawValue)" }))
            }
            #expect(services.observed.isSuperset(of: ["fixture-poster-41", "fixture-course-43", "fixture-paper-45"]))
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
            #expect(!report.coverageComplete && report.skippedProbes.contains { $0.contains("维护对象配置") })
        }
        #expect(report.productionSessionEvidence == (scope.includes(.bit101) && !stage.contains("community-login") ? sessionEvidence : []))
        if stage == "all-sms-success" {
            #expect(report.schoolSMSCoverage == "verified")
            #expect(services.webvpnVerified && productionServices.webvpnVerified)
            #expect(Set(report.verifiedSMSProbes.filter { $0.purpose == "webvpn" }.map(\.probe)) == ["school.session", "schedule.current-term"])
            #expect(Set(report.verifiedSMSProbes.map(\.purpose)) == NetworkSmokeScope.all.requiredSMSPurposes)
        }
        if stage.hasPrefix("all-sms-") {
            #expect(Set(report.authenticatedSchoolProbes.map(\.purpose)) == NetworkSmokeScope.all.requiredSMSPurposes)
            #expect(Set(report.requestedSMSPurposes) == Set(report.verifiedSMSProbes.map(\.purpose)))
            #expect(report.schoolSMSCoverage == (stage == "all-sms-not-required" ? "not_required" : "verified"))
            #expect(Set(NetworkSmokeScope.school.requiredProbes).isSubset(of: Set(report.executedProbes)))
            #expect(report.coverageComplete == !stage.contains("community-login"), "\(stage): \(report.coverageGaps)")
            if stage.contains("community-login") { #expect(!services.observed.contains("gallery-newest")) }
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
            #expect(Set(scope.requiredProbes).subtracting(report.executedProbes)
                == ["gallery.detail", "gallery.image", "gallery.comments", "gallery.web", "course.detail", "course.comments",
                    "course.history", "course.web", "course.search", "paper.search", "paper.detail", "paper.image", "paper.comments", "paper.web"])
        } else {
            let deferred: Set<String> = stage.contains("community-login") ? Set(NetworkSmokeProbe.allCases.filter(\.requiresCommunitySession).map(\.rawValue))
                : stage == "entity-identity-failure" ? ["paper.search", "paper.image", "gallery.image"]
                : stage == "paper-content-failure" ? ["paper.search", "paper.image"] : stage == "campus-selection-failure" ? ["classroom.occupancy"] : []
            #expect(Set(report.executedProbes) == Set(scope.requiredProbes).subtracting(deferred))
        }
        #expect(reports.count == 1 && reports[0].passed == report.passed)
        #expect(loginChecks == (scope.includes(.authentication) ? 1 : 0))
        if scope.includes(.bit101) {
            #expect(feedback == 1)
            #expect(services.observed.contains("mine") == !stage.contains("community-login"))
            #expect(services.observed.contains("paper-list") == !stage.contains("community-login"))
        }
        #expect(association.requests.count == (scope.includes(.bit101) ? 1 : 0))
        #expect(external.requests.allSatisfy { $0.url?.path.hasSuffix("apple-app-site-association") == false })
        if scope.includes(.bit101) {
            #expect(!external.imageBudgets.isEmpty && external.imageBudgets.allSatisfy { $0 == RemoteImageResourceLimits.maximumEncodedBytes })
        }
        if stage == "entity-identity-failure" {
            #expect(report.failures.count == 3)
            for name in ["gallery.detail", "course.detail", "paper.detail"] { #expect(report.failures.contains { $0.contains(name) }) }
        }
        if stage == "paper-content-failure" || stage == "paper-image-failure" || stage == "campus-selection-failure" {
            let probe = stage == "paper-content-failure" ? "paper.detail" : stage == "paper-image-failure" ? "paper.image" : "classroom.buildings"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        if stage.contains("comment-ranking") {
            let probe = stage.hasPrefix("gallery") ? "gallery.comments" : stage.hasPrefix("course") ? "course.comments" : "paper.comments"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        if ["bot-empty-gap", "empty-classroom-gap", "message-empty-gap", "empty-course-gap", "pending-course-gap"].contains(stage) {
            let probe = stage == "bot-empty-gap" ? "gallery.bots" : stage == "message-empty-gap" ? "message." : stage.contains("course-gap") ? "schedule.sync" : "classroom.occupancy"
            #expect(report.passed && !report.coverageComplete && report.coverageGaps.contains { $0.contains(probe) })
        }
        if stage.contains("comment-page") {
            let kind = String(stage.prefix { $0 != "-" })
            let probe = kind == "gallery" ? "gallery.comments" : kind == "course" ? "course.comments" : "paper.comments"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
            #expect(services.observed.contains("\(kind)-comments-\(kind == "gallery" ? 3 : 1)"))
        }
        if stage.hasPrefix("cors") { #expect(report.failures.count == 1 && report.failures[0].contains("feedback.preflight")) }
        if stage.hasPrefix("aasa") { #expect(report.failures.count == 1 && report.failures[0].contains("web.association")) }
        if scope.includes(.schedule) { #expect(services.observed.contains("schedule")) }
        if scope.includes(.schedule) {
            #expect(report.currentTerm == "fixture-1")
            #expect(report.requestedTerm == (stage == "historical-term-success" ? "historical-1" : nil))
            #expect(report.validatedTerm == (stage == "schedule-term-failure" || stage == "invalid-exam-failure" || stage.contains("course-gap") ? nil : report.requestedTerm ?? "fixture-1"))
        }
        if report.executedProbes.contains("classroom.occupancy") {
            let occupancy = try #require(report.requestEvidence.first { $0.probe == "classroom.occupancy" })
            let queryDate = try #require(services.classroomDate)
            #expect(occupancy.expectedParameters == ["XNXQDM": report.requestedTerm ?? "fixture-1", "JXLDM": "building",
                "RQ": ScheduleDateCodec.formatDate(queryDate), "XQDM": "1", "XNDM": stage == "historical-term-success" ? "historical" : "fixture"])
        }
        if scope.includes(.ddl) { #expect(services.observed.isSuperset(of: ["eclass", "lexue"])) }
        if stage == "raw-write-failure" { #expect(rawWrites == 1 && report.failures.contains { $0.contains("原始课表采样写入") }) }
        if stage == "ddl-failure" || stage == "ddl-invalid-calendar-failure" {
            #expect(report.failures.count == 1 && report.failures[0].contains("lexue.ddl"))
        }
        if let redirectHost {
            let probe = redirectHost == "itunes.apple.com" ? "update.app-store" : "update.emergency"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        let next = await runner.run(scope: .transcript, runID: "next", schoolSMSCodeHandler: stage.hasPrefix("all-sms-") ? smsHandler : nil)
        #expect(next.passed && next.failures.isEmpty && next.coverageComplete)
        #expect(reports.count == 2)
    }
}
#endif
