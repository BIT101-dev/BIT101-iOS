#if RELEASE_NETWORK_SMOKE
import XCTest
@testable import BIT101_iOS

/// 发布前真机网络冒烟测试。
///
/// 测试根据编译条件或 `BIT101_NETWORK_SMOKE_SCOPE` 选择 smoke 范围，调用共享 runner。
/// 采样宿主的当前登录态冒烟通过 `bit101://network-smoke/...` 在主进程内触发同一 runner。
nonisolated final class ReleaseNetworkSmokeTests: XCTestCase {
    @MainActor private var scope: NetworkSmokeScope? {
#if SMOKE_BIT101
        return .bit101
#elseif SMOKE_SCHOOL
        return .school
#else
        let rawValue = ProcessInfo.processInfo.environment["BIT101_NETWORK_SMOKE_SCOPE"] ?? "all"
        return NetworkSmokeScope(rawValue: rawValue)
#endif
    }

    @MainActor
    func testReleaseNetworkFlows() async {
        guard let scope else {
            XCTFail("BIT101_NETWORK_SMOKE_SCOPE 无效")
            return
        }
        let report = await ReleaseNetworkSmokeRunner().run(scope: scope)
        XCTAssertEqual(report.scope, scope)
        XCTAssertTrue(report.executedProbes.contains("BIT101 登录状态"))
        XCTAssertTrue(report.passed, report.failureMessage)
        XCTAssertTrue(report.coverageComplete, report.failureMessage)
    }
}
#endif

#if DEBUG
import Foundation
import Testing
import ClientCore
import ScoreDomain
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
    @Test(arguments: [#"{"KCM":"课程","SKXQ":8,"KSJC":1,"JSJC":2,"ZCMC":"1周"}"#,
        #"{"KCM":"课程","SKXQ":1,"KSJC":0,"JSJC":2,"ZCMC":"1周"}"#,
        #"{"KCM":"课程","SKXQ":1,"KSJC":1,"JSJC":2}"#])
    func smokeRejectsIncompleteCoursePlacements(_ row: String) throws {
        let response = try JSONDecoder().decode(CourseResponse.self,
            from: Data((#"{"datas":{"cxxszhxqkb":{"rows":["# + row + #"]}}}"#).utf8))
        let payload = CourseSyncPayload(term: "2026-2027-1", firstDayString: "2026-09-28", sourceFirstDayString: "2026-09-28",
            normalizationOffset: 0, rawWeeksByCourse: response.parsedCourses.map(\.rawWeeks), courses: response.courseRecords, exams: [])
        #expect(throws: URLError.self) { try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload) }
    }

    @Test(arguments: [#"<link rel="stylesheet" href="https://resource.invalid/style.css">"#,
        #"<span style="background-image:url(https://resource.invalid/image.png)">文字</span>"#,
        #"<body background="https://resource.invalid/image.png"><svg><image href="https://resource.invalid/a.svg"/></svg></body>"#,
        #"<img src="https://resource.invalid/image.png""#])
    func articleHTMLKeepsInlineFormattingAndLinksAlongAResourceFreeImport(_ resource: String) {
        let html = #"<strong>正文</strong><a href="https://example.org/article">链接</a>"# + resource
        let safe = PaperContentRenderer.sanitizedHTML(html)
        #expect(!safe.contains("resource.invalid") && !safe.contains("style="))
        #expect(safe.contains("<strong>正文</strong>"))
        let text = PaperContentRenderer.attributedText(from: html)
        #expect(String(text.characters).contains("正文") && String(text.characters).contains("链接"))
        #expect(text.runs.contains { $0.link?.absoluteString == "https://example.org/article" })
    }

    private final class PaperWrites: HTTPTransport {
        var content = ""
        var methods: [String] = []
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let method = try #require(request.httpMethod)
            methods.append(method)
            let response: Data
            if method == "GET" {
                let user: [String: Any] = ["id": 1, "create_time": "", "nickname": "功能验收", "motto": "",
                    "avatar": ["mid": "", "url": "", "low_url": ""],
                    "identity": ["id": 1, "color": "", "text": "", "create_time": "", "update_time": ""]]
                response = try JSONSerialization.data(withJSONObject: ["id": 1, "title": "功能验收", "intro": "功能验收",
                    "content": content, "create_time": "", "update_time": "2026-10-01T08:00:00Z", "update_user": user,
                    "anonymous": false, "like_num": 0, "comment_num": 0, "public_edit": false, "like": false, "own": true])
            } else {
                let body = try #require(request.httpBody)
                let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                content = try #require(payload["content"] as? String)
                if method == "PUT" { #expect(payload["last_time"] as? Double == 1_790_841_600) }
                let editor = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
                let blocks = try #require(editor["blocks"] as? [[String: Any]])
                #expect(blocks.allSatisfy { $0["type"] as? String == "paragraph" })
                response = method == "POST" ? Data(#"{"id":1}"#.utf8) : Data()
            }
            return (response, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test func onlineArticleValidationUsesTheEditorWireFormatAndReadsItsText() async throws {
        let transport = PaperWrites()
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        let operations = CommunityWriteSmoke.Operations.production(papers: PaperService(session: session))
        let text = "功能验收 <正文> & 内容\n第二行"
        let id = try await operations.create(.paper, text)
        #expect(try await operations.read(.paper, id)?.text == text)
        try await operations.edit(.paper, id, text + " 编辑")
        #expect(try await operations.read(.paper, id)?.text == text + " 编辑")
        #expect(transport.methods == ["POST", "GET", "GET", "PUT", "GET"])
    }

    private final class CourseWrites: HTTPTransport {
        var comments = 0
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let body = try #require(request.httpBody)
            let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(payload["obj"] as? String == "course42" && payload["rate"] as? Int == 6)
            comments += 1
            let response = Data(#"{"id":1,"obj":"course42","images":[],"user":{"id":1,"nickname":"功能验收","avatar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":1,"color":"","text":"","create_time":"","update_time":""},"create_time":""},"anonymous":false,"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":6,"reply_user":{"id":1,"nickname":"功能验收","avatar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":1,"color":"","text":"","create_time":"","update_time":""},"create_time":""},"reply_obj":"","text":"功能验收","sub":[]}"#.utf8)
            let url = try #require(request.url)
            return (response, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test func onlineCourseReviewIncludesItsRequiredRating() async throws {
        let transport = CourseWrites()
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        let operations = CommunityWriteSmoke.Operations.production(courses: CourseService(session: session))
        let comment = try await operations.comment("course42", "功能验收")
        #expect(comment.rate == 6 && transport.comments == 1)
    }

    @Test(arguments: [(CommunityWriteSmoke.Kind.paper, "BIT101.Paper", "文章不存在Orz", true),
        (.poster, "BIT101.Gallery", "帖子不存在Orz", true), (.paper, "BIT101.Gallery", "文章不存在Orz", false),
        (.paper, "BIT101.Paper", "服务暂时繁忙", false), (.course, "BIT101.Paper", "文章不存在Orz", false)])
    func knownResourceAbsenceKeepsOtherServerFailuresVisible(fixture: (CommunityWriteSmoke.Kind, String, String, Bool)) {
        let (kind, domain, message, missing) = fixture
        let error = NSError(domain: domain, code: 500, userInfo: [NSLocalizedDescriptionKey: message])
        #expect(CommunityWriteSmoke.Operations.isMissingContent(error, kind: kind) == missing)
    }

    @Test func journalSurvivesRestartAndRetainsTheRecoveryRecordOnStorageFailure() throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let directory = files.temporaryDirectoryURL.appendingPathComponent("NetworkSmoke", isDirectory: true)
        let original = Data("recovery".utf8)
        var legacyRemoved = false
        #expect(try CommunityWriteSmoke.loadJournal(files: files, directory: directory, legacyData: original,
            removeLegacy: { legacyRemoved = true }) == original)
        #expect(legacyRemoved)
        #expect(try CommunityWriteSmoke.loadJournal(files: files, directory: directory, legacyData: nil) == original)
        files.setFailures(writing: true)
        #expect(throws: CocoaError.self) { try CommunityWriteSmoke.saveJournal(Data("new".utf8), files: files, directory: directory) }
        #expect(try CommunityWriteSmoke.loadJournal(files: files, directory: directory, legacyData: nil) == original)
        files.setFailures(removal: true)
        #expect(throws: CocoaError.self) { try CommunityWriteSmoke.saveJournal(nil, files: files, directory: directory) }
        #expect(try CommunityWriteSmoke.loadJournal(files: files, directory: directory, legacyData: nil) == original)
        files.setFailures()
        try CommunityWriteSmoke.saveJournal(nil, files: files, directory: directory)
        #expect(try CommunityWriteSmoke.loadJournal(files: files, directory: directory, legacyData: nil) == nil)
        files.setFailures(writing: true)
        legacyRemoved = false
        #expect(throws: CocoaError.self) {
            try CommunityWriteSmoke.loadJournal(files: files, directory: directory, legacyData: original,
                removeLegacy: { legacyRemoved = true })
        }
        #expect(legacyRemoved == false)
    }

    @Test func savingFailureStopsOnlineCreation() async {
        let world = CommunityWorld(stage: "success")
        let smoke = CommunityWriteSmoke(operations: world.operations, load: { nil }, save: { _ in throw CocoaError(.fileWriteNoPermission) })
        await #expect(throws: (any Error).self) { try await smoke.run(marker: "fixture") }
        #expect(world.nextID == 100)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
    }

    @Test func concurrentRunnerEntrypointsSerializeCommunityRecovery() async throws {
        var waiting: CheckedContinuation<Void, Never>?
        var reached: CheckedContinuation<Void, Never>?
        var entered = false
        var runs: [String] = []
        var reports: [String] = []
        var loginCalls = 0
        var rawCleanupCalls = 0
        let dependencies = ReleaseNetworkSmokeDependencies(checkLogin: { loginCalls += 1; return "fixture" }, writeReport: { reports.append($0.runID) },
            clearRawCourseResponse: { rawCleanupCalls += 1; throw CocoaError(.fileWriteNoPermission) },
            communityWriteProbe: { id, _ in
                runs.append(id)
                if id == "first" {
                    await withCheckedContinuation { waiting = $0; entered = true; reached?.resume(); reached = nil }
                }
                return ["服务端清理确认完成"]
            })
        let first = Task { await ReleaseNetworkSmokeRunner(dependencies: dependencies).run(scope: .communityCleanup, runID: "first") }
        if !entered { await withCheckedContinuation { reached = $0 } }
        let cancelled = Task { await ReleaseNetworkSmokeRunner(dependencies: dependencies).run(scope: .all, runID: "cancelled") }
        await Task.yield()
        cancelled.cancel()
        let cancelledReport = await cancelled.value
        #expect(!cancelledReport.passed && cancelledReport.executedProbes.isEmpty)
        #expect(loginCalls == 1 && reports.isEmpty && rawCleanupCalls == 0)
        let second = Task { await ReleaseNetworkSmokeRunner(dependencies: dependencies).run(scope: .communityCleanup, runID: "second") }
        await Task.yield()
        #expect(runs == ["first"])
        let resume = try #require(waiting)
        resume.resume()
        let initial = await first.value
        let next = await second.value
        #expect(initial.passed && next.passed)
        #expect(runs == ["first", "second"])
        #expect(loginCalls == 2 && reports == ["first", "second"])
        #expect(rawCleanupCalls == 0)
    }

    private final class CommunityWorld {
        var account = 1
        var nextID = 100
        var contents: [String: CommunityWriteSmoke.Content] = [
            "poster77": .init(text: "原有内容", owned: true, liked: false),
            "course1": .init(text: "", owned: false, liked: true)]
        var rows: [String: [CommunityComment]] = [:]
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
        private var user: CommunityUser {
            CommunityUser(id: 1, createTime: "", nickname: "功能验收", avatar: .init(mid: "", url: "", lowUrl: ""), motto: "",
                identity: .init(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
        }
        var operations: CommunityWriteSmoke.Operations {
            .init(identity: { .init(accountIdentifier: String(self.account)) }, account: { self.account }, course: { 1 }, create: { kind, text in
                if self.stage == "invalid-paper" && kind == .paper {
                    throw NSError(domain: "BIT101.Paper", code: 400, userInfo: [NSLocalizedDescriptionKey: "参数错误awa"])
                }
                self.nextID += 1
                let id = self.nextID
                self.contents[kind.rawValue + String(id)] = .init(text: text, owned: true, liked: false)
                if self.stage == "lost-poster" && !self.injected {
                    self.injected = true; throw URLError(.networkConnectionLost)
                }
                return id
            }, find: { kind, marker in
                if self.stage == "persistent-find" && kind == .paper { throw URLError(.timedOut) }
                return self.contents.compactMap { key, value in
                    guard key.hasPrefix(kind.rawValue), value.owned, value.text.hasPrefix(marker) else { return nil }
                    return Int(key.dropFirst(kind.rawValue.count))
                }
            }, read: { kind, id in
                if self.switchAccount(during: "read") { return nil }
                return self.contents[kind.rawValue + String(id)]
            }, edit: { kind, id, text in
                let key = kind.rawValue + String(id)
                self.contents[key] = .init(text: text, owned: true, liked: false)
            }, delete: { kind, id in
                try Task.checkCancellation()
                if self.stage == "persistent-delete" && kind == .paper { throw URLError(.timedOut) }
                if self.switchAccount(during: "delete") { throw NSError(domain: "fixture", code: 404) }
                if self.stage == "cleanup-failure" && !self.injected { self.injected = true; throw URLError(.timedOut) }
                self.contents[kind.rawValue + String(id)] = nil
            }, comments: { parent in
                if self.switchAccount(during: "comments") { return [] }
                if self.stage == "deleted-parent-read", parent.hasPrefix("comment"),
                   let id = Int(parent.dropFirst(7)), !self.rows.values.joined().contains(where: { $0.id == id }) {
                    throw NSError(domain: "BIT101.Gallery", code: 500, userInfo: [NSLocalizedDescriptionKey: "获取顶级对象失败Orz"])
                }
                return self.rows[parent] ?? []
            }, comment: { object, text in
                self.nextID += 1
                @MainActor func makeComment(_ id: Int) -> CommunityComment { CommunityComment(id: id, obj: object, images: [], user: self.user, anonymous: false,
                    createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: true, rate: 0,
                    replyUser: self.user, replyObj: "", text: text, sub: []) }
                let value = makeComment(self.nextID)
                self.rows[object, default: []].append(value)
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
                        self.contents[key] = .init(text: old.text, owned: old.owned, liked: !old.liked)
                    }
                    throw URLError(.timedOut)
                }
                self.contents[key] = .init(text: old.text, owned: old.owned, liked: !old.liked)
                return !old.liked
            })
        }
        var smoke: CommunityWriteSmoke {
            .init(operations: operations, load: { self.pending }, save: { self.pending = $0 })
        }
    }

    @Test func confirmedCommentAbsenceRetiresALostDeletionResponseBeforeRecovery() async throws {
        let world = CommunityWorld(stage: "lost-delete-response")
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture") }
        let data = try #require(world.pending)
        let journal = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((journal["comments"] as? [Int])?.isEmpty == true)
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
        world.stage = "success"
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
        #expect(world.commentDeletionRequests.count == 6)
        #expect(Set(world.commentDeletionRequests).count == 6)
    }

    @Test(arguments: ["persistent-find", "persistent-like", "persistent-delete"])
    func independentObjectsAreCleanedWhileOneRecoveryOperationKeepsFailing(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture") }
        #expect(world.pending != nil)
        #expect(world.contents.keys.filter { $0.hasPrefix("poster") } == ["poster77"])
        #expect(world.contents.keys.filter { $0.hasPrefix("paper") }.count == (stage == "persistent-delete" ? 1 : 0))
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
        world.stage = "success"
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
        #expect(world.contents["course1"]?.liked == true)
    }

    @Test(arguments: ["read", "comments", "delete", "comment-delete"])
    func interruptedCleanupRetainsPersistedJournalForItsOriginalAccount(operation: String) async throws {
        let world = CommunityWorld(stage: "switch-" + operation)
        world.contents["poster123"] = .init(text: "功能验收 fixture", owned: true, liked: false)
        let comment = try await world.operations.comment("poster123", "功能验收 fixture")
        world.pending = Data(#"{"marker":"功能验收 fixture","account":1,"attempts":[],"targets":[{"kind":"poster","id":123}],"parents":["poster123"],"comments":[\#(comment.id)],"likes":[],"evidence":[]}"#.utf8)
        await #expect(throws: CancellationError.self) { try await world.smoke.run(marker: "fixture", cleanupOnly: true) }
        #expect(world.pending != nil)
        #expect(world.contents["poster123"] != nil)
        world.account = 1
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
    }

    @Test func repliesAreConfirmedWhileTheirParentCommentsRemainReadable() async throws {
        let world = CommunityWorld(stage: "deleted-parent-read")
        let evidence = try await world.smoke.run(marker: "fixture")
        #expect(evidence.filter { $0.hasPrefix("服务端确认删除 comment") }.count == 6)
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
    }

    @Test(arguments: ["success", "lost-poster", "lost-reply", "cancelled", "cleanup-failure", "duplicate-comments", "invalid-paper"])
    func communityWritesCleanAfterLostResponsesCancellationAndResume(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        let task = Task { try await world.smoke.run(marker: "fixture") }
        world.cancel = { task.cancel() }
        let result = await task.result
        if stage == "success" {
            let evidence = try result.get()
            #expect(evidence.filter { $0.hasPrefix("服务端确认删除 comment") }.count == 6)
        } else { if case .success = result { Issue.record("故障注入应保留验收失败结果") } }
        if stage == "invalid-paper", case let .failure(error) = result {
            #expect(error.localizedDescription.contains("创建 paper：参数错误awa"))
        }
        if stage == "cleanup-failure" {
            #expect(world.pending != nil)
            let current = world.account
            world.account = 2
            await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", cleanupOnly: true) }
            #expect(world.pending != nil)
            world.account = current
            _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
        #expect(world.contents["course1"]?.liked == true)
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
    }

    private final class Scores: ScoreListServicing, TrustedTranscriptServicing {
        let stage: String
        let image: Data
        var submissions = 0
        init(stage: String, image: Data) { self.stage = stage; self.image = image }
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge { throw ScoreServiceError.invalidResponse }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { throw ScoreServiceError.invalidResponse }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { throw ScoreServiceError.invalidResponse }
        func fetchTrustedTranscriptPages() async throws -> [Data] {
            if stage == "invalid" { return [] }
            throw ScoreServiceError.secondFactorRequired(BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "fixture",
                status: "sms_required", maskedPhone: "***", expiresIn: 60))
        }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> [Data] {
            submissions += 1
            if stage == "smsFailure" { throw ScoreServiceError.challengeInvalid("验证码错误") }
            return [image]
        }
    }

    @Test("Transcript orchestration records authentication, cancellation and SMS continuation", arguments: ["blocked", "invalid", "cancelled", "smsSuccess", "smsFailure"])
    func transcriptOrchestration(stage: String) async throws {
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }.pngData())
        let scores = Scores(stage: stage, image: image)
        var stored: ReleaseNetworkSmokeReport?
        let dependencies = ReleaseNetworkSmokeDependencies(checkLogin: { "fixture" }, writeReport: { stored = $0 },
            clearRawCourseResponse: {}, writeRawCourseResponse: { _, _ in Issue.record("成绩单流程使用独立探针") }, makeScores: { scores })
        let handler: SchoolSMSCodeHandler = { _ in
            if stage == "cancelled" { throw CancellationError() }
            return "123456"
        }
        let report = await ReleaseNetworkSmokeRunner(dependencies: dependencies).run(scope: .transcript, runID: "transcript",
            schoolSMSCodeHandler: ["cancelled", "smsSuccess", "smsFailure"].contains(stage) ? handler : nil)
        #expect(report.executedProbes == NetworkSmokeScope.transcript.requiredProbes)
        #expect(report.passed == (stage == "smsSuccess"))
        #expect(report.coverageComplete == (["blocked", "invalid", "smsSuccess"].contains(stage)))
        #expect(report.verifiedSMSProbes.map(\.purpose) == (stage == "smsSuccess" ? ["jwb_cjd"] : []))
        #expect(report.authenticationBlockers.count == (stage == "blocked" ? 1 : 0))
        #expect(scores.submissions == (["smsSuccess", "smsFailure"].contains(stage) ? 1 : 0))
        #expect(stored?.passed == report.passed)
    }

    @Test("Cleanup, authentication and report failures retain failed evidence", arguments: ["cleanup", "signedOut", "login", "report"])
    func failureEvidence(stage: String) async {
        var loginCalls = 0
        var reportCalls = 0
        var stored: ReleaseNetworkSmokeReport?
        let dependencies = ReleaseNetworkSmokeDependencies(
            checkLogin: {
                loginCalls += 1
                if stage == "login" { throw URLError(.notConnectedToInternet) }
                return nil
            }, writeReport: { report in
                reportCalls += 1
                if stage == "report" { throw CocoaError(.fileWriteNoPermission) }
                stored = report
            }, clearRawCourseResponse: {
                if stage == "cleanup" { throw CocoaError(.fileWriteNoPermission) }
            }, writeRawCourseResponse: { _, _ in Issue.record("认证失败应在学校采样之前结束") }
        )
        let runner = ReleaseNetworkSmokeRunner(dependencies: dependencies)
        let report = await runner.run(scope: .all, runID: "fixture", capture: .rawCourseResponse)
        #expect(!report.passed)
        #expect(!report.coverageComplete)
        #expect(report.runID == "fixture")
        #expect(report.requiredProbes == NetworkSmokeScope.all.requiredProbes)
        #expect(reportCalls == 1)
        #expect(loginCalls == (stage == "cleanup" ? 0 : 1))
        #expect(report.failures.count == (stage == "report" ? 2 : 1))
        #expect(stored?.runID == (stage == "report" ? nil : "fixture"))
        let next = await runner.run(scope: .school, runID: "next")
        #expect(next.failures.count == report.failures.count)
        #expect(next.requiredProbes == NetworkSmokeScope.school.requiredProbes)
    }
}
#endif

#if DEBUG
extension ReleaseNetworkSmokeLifecycleTests {
    private final class Services: NetworkSmokeGalleryServicing, NetworkSmokeCourseServicing, NetworkSmokePaperServicing,
        NetworkSmokeMineServicing, NetworkSmokeScheduleServicing, ScoreListServicing, TrustedTranscriptServicing {
        let stage: String
        let image: Data
        var rawResponse: ((Data) -> Void)?
        var observed = Set<String>()
        init(stage: String, image: Data) { self.stage = stage; self.image = image }
        private var user: CommunityUser {
            CommunityUser(id: 1, createTime: "", nickname: "fixture", avatar: CommunityImage(mid: "image", url: "https://image.invalid/image.png", lowUrl: ""), motto: "",
                identity: CommunityIdentity(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
        }
        private var poster: CommunityPoster {
            CommunityPoster(anonymous: false, claim: CommunityClaim(id: 1, text: "fixture"), commentNum: 0, createTime: "", editTime: "", id: 1, images: [user.avatar],
                likeNum: 0, public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
        }
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            observed.insert("gallery"); return .init(items: [poster], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> { GalleryPageBatch<CommunityPoster>(items: [poster], nextSourcePage: 1, canLoadMore: false) }
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> { GalleryPageBatch<CommunityPoster>(items: [poster], nextSourcePage: 1, canLoadMore: false) }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            .init(items: [poster], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        func fetchMessageUnreadCounts() async throws -> GalleryMessageUnreadCounts { GalleryMessageUnreadCounts() }
        func fetchMessages(type: GalleryMessageType, lastID: Int?) async throws -> [GalleryMessage] { [] }
        func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
            GalleryPosterDetail(anonymous: false, claim: poster.claim, commentNum: 0, createTime: "", editTime: "", id: id, images: poster.images,
                like: false, likeNum: 0, own: false, plugins: "", public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
        }
        func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment> {
            .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        func fetchClaims() async throws -> [CommunityClaim] { [poster.claim] }
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            [CourseSummary(detail: CourseDetail(id: 1, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false))]
        }
        func fetchCourse(id: Int) async throws -> CourseDetail {
            observed.insert("course-detail")
            if stage == "community-failure" { throw URLError(.timedOut) }
            return CourseDetail(id: id, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false)
        }
        func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] { [] }
        func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment] { [] }
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            observed.insert("paper-list")
            return [PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")]
        }
        func fetchPaper(id: Int) async throws -> PaperDetail {
            PaperDetail(id: id, title: "fixture", intro: "", content: "fixture", createTime: "", updateTime: "", updateUser: user,
                anonymous: false, likeNum: 0, commentNum: 0, publicEdit: false, like: false, own: false)
        }
        func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment] { [] }
        func fetchMyInfo() async throws -> MineUserInfo { observed.insert("mine"); return try await fetchUserInfo(id: 1) }
        func fetchUserInfo(id: Int) async throws -> MineUserInfo { MineUserInfo(user: user, followingNum: 0, followerNum: 0, following: false, follower: false, own: true) }
        func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster] { [poster] }
        func fetchMyPosters(page: Int) async throws -> [CommunityPoster] { [poster] }
        func fetchFollowers(page: Int) async throws -> [CommunityUser] { [] }
        func fetchFollowings(page: Int) async throws -> [CommunityUser] { [] }
        func fetchCurrentTermOnly() async throws -> String { "fixture-1" }
        func fetchAvailableTerms() async throws -> [String] { ["fixture-1"] }
        func syncCourses(term: String?) async throws -> CourseSyncPayload {
            observed.insert("schedule")
            rawResponse?(Data("course-response".utf8))
            return CourseSyncPayload(term: term ?? "fixture-1", firstDayString: "2026-03-02", sourceFirstDayString: "2026-03-02",
                normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: [])
        }
        func submitSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge, term: String?) async throws -> CourseSyncPayload { try await syncCourses(term: term) }
        func submitSMSCodeForTeachingCenterAuthentication(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws {}
        func prepareTeachingCenterAccess() async throws {}
        func fetchCampuses() async throws -> [CampusRecord] { [CampusRecord(id: "campus", name: "fixture", code: "campus")] }
        func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] { [BuildingRecord(id: "building", name: "fixture", buildingCode: "building", campusName: "fixture", campusCode: "campus")] }
        func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] { [ClassroomRecord(id: "room", name: "fixture", busyTimeCodes: [])] }
        func fetchEclassDDLEvents(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> EclassDDLResult { try await fetchEclassDDLEventsForPreflight() }
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
        func startScoreChallenge() async throws -> BITLoginAuthenticationChallenge { BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "fixture", status: "authenticated", maskedPhone: nil, expiresIn: 60) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { [] }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { try await startScoreChallenge() }
        func fetchTrustedTranscriptPages() async throws -> [Data] { [image] }
        func submitTranscriptSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> [Data] { [image] }
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
                data = Data(); status = 204; headers["Access-Control-Allow-Origin"] = "*"
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
                data = image
            } else {
                if url.path.isEmpty || url.path == "/" { finalURL = try #require(URL(string: "https://bit101.cn/gallery/")) }
                data = Data("<html><a href=\"bit101:/\(url.path)\">fixture</a></html>".utf8)
            }
            if url.host == redirectHost { status = 302 }
            return (data, try #require(HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: nil, headerFields: headers)))
        }
    }

    @Test("Full smoke orchestration preserves success, intermediate failures and subsequent scopes", arguments:
        ["all-success", "community-failure", "schedule-success", "ddl-success", "ddl-failure", "ddl-invalid-calendar-failure", "raw-write-failure",
         "app-store-redirect-failure", "emergency-redirect-failure", "aasa-redirect-failure", "aasa-followed-redirect-failure",
         "aasa-mime-failure", "aasa-exclusion-failure", "image-budget-failure"])
    func completeOrchestration(stage: String) async throws {
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }.pngData())
        let services = Services(stage: stage, image: image)
        let redirectHost = stage == "app-store-redirect-failure" ? "itunes.apple.com"
            : stage == "emergency-redirect-failure" ? "update.aihelpme.dev" : nil
        let external = External(image: image, redirectHost: redirectHost, aasaStage: stage)
        let association = External(image: image, aasaStage: stage)
        var reports: [ReleaseNetworkSmokeReport] = []
        var feedback = 0
        var rawWrites = 0
        let dependencies = ReleaseNetworkSmokeDependencies(checkLogin: { "fixture" }, writeReport: { reports.append($0) },
            clearRawCourseResponse: {}, writeRawCourseResponse: { _, runID in
                rawWrites += 1
                #expect(runID == stage)
                if stage == "raw-write-failure" { throw CocoaError(.fileWriteNoPermission) }
            }, makeGallery: { services }, makeCourses: { services }, makePapers: { services }, makeMine: { services },
            externalHTTPClient: HTTPClient(transport: external, observer: nil), aasaHTTPClient: HTTPClient(transport: association, observer: nil),
            feedbackProbe: { _ in feedback += 1 },
            loadScheduleCache: { ScheduleCache() }, makeScores: { services }, makeSchedule: { handler in services.rawResponse = handler; return services },
            makeEclassSchedule: { services })
        let scope: NetworkSmokeScope = stage == "all-success" || redirectHost != nil || stage.hasPrefix("aasa") ? .all : stage == "community-failure" || stage == "image-budget-failure" ? .bit101 : stage.hasPrefix("ddl") ? .ddl : .schedule
        let runner = ReleaseNetworkSmokeRunner(dependencies: dependencies)
        let report = await runner.run(scope: scope, runID: stage, capture: stage == "raw-write-failure" ? .rawCourseResponse : .none)
        #expect(report.passed == !stage.hasSuffix("failure"))
        #expect(Set(report.executedProbes) == Set(scope.requiredProbes))
        #expect(reports.count == 1 && reports[0].passed == report.passed)
        if scope.includes(.bit101) { #expect(feedback == 1 && services.observed.contains("mine") && services.observed.contains("paper-list")) }
        #expect(association.requests.count == (scope.includes(.bit101) ? 1 : 0))
        #expect(external.requests.allSatisfy { $0.url?.path.hasSuffix("apple-app-site-association") == false })
        if scope.includes(.bit101) {
            #expect(!external.imageBudgets.isEmpty && external.imageBudgets.allSatisfy { $0 == RemoteImageResourceLimits.maximumEncodedBytes })
        }
        if stage.hasPrefix("aasa") { #expect(report.failures.count == 1 && report.failures[0].contains("App 链接关联配置")) }
        if scope.includes(.schedule) { #expect(services.observed.contains("schedule")) }
        if scope.includes(.ddl) { #expect(services.observed.isSuperset(of: ["eclass", "lexue"])) }
        if stage == "raw-write-failure" { #expect(rawWrites == 1 && report.failures.contains { $0.contains("原始课表采样写入") }) }
        if stage == "ddl-failure" || stage == "ddl-invalid-calendar-failure" {
            #expect(report.failures.count == 1 && report.failures[0].contains("乐学 DDL 下载"))
        }
        if let redirectHost {
            let probe = redirectHost == "itunes.apple.com" ? "App Store 更新接口" : "紧急更新配置接口"
            #expect(report.failures.count == 1 && report.failures[0].contains(probe))
        }
        let next = await runner.run(scope: .transcript, runID: "next")
        #expect(next.passed && next.failures.isEmpty && next.coverageComplete)
        #expect(reports.count == 2)
    }
}
#endif
