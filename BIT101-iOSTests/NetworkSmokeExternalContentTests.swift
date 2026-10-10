#if DEBUG
import Foundation
import Testing
import ScheduleDomain
import TransportCore
import CommunityCore
import CommunityTransport
import GalleryFeature
@testable import PaperFeature
import CourseFeature
@testable import BIT101_iOS

@Suite("Network smoke external content")
struct NetworkSmokeExternalContentTests {
    @Test @MainActor func paperPagingChecksEachLiveRankingSnapshot() async throws {
        let first = PaperSummary(id: 1, title: "", intro: "", likeNum: 2, commentNum: 2, updateTime: "2026-01-01T00:00:00Z")
        let changed = PaperSummary(id: 2, title: "", intro: "", likeNum: 3, commentNum: 3, updateTime: "2026-01-02T00:00:00Z")
        for order in PaperSortOrder.allCases {
            let sample = try await NetworkSmokePaging.paperPage(order: order,
                currentIdentity: { CommunitySessionIdentity(accountIdentifier: "paper-smoke") }) { page in
                page == 0 ? [first] : [changed]
            }
            #expect(sample.map(\.id) == [1, 2])
            await #expect(throws: URLError.self) {
                try await NetworkSmokePaging.paperPage(order: order,
                    currentIdentity: { CommunitySessionIdentity(accountIdentifier: "paper-smoke") }) { _ in [first, changed] }
            }
        }
    }
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

@MainActor
extension ReleaseNetworkSmokeLifecycleTests {
    @Test(arguments: CommunityWriteSmoke.Kind.allCases)
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

    @Test func knownCommentReadsStopAtTheirPageAndRecoveryScansTheCompleteHistory() async throws {
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
                    publicAccess: self.stage == "create-public-" + kind.rawValue)
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
                    publicAccess: self.stage == "edit-public-" + kind.rawValue)
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
            }, followTarget: { 2 }, following: { _ in self.followsTarget }, follow: { _ in
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
