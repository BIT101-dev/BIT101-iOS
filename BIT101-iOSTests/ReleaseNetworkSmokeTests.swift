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
    @Test func articleUnknownBlocksKeepTheirPositionAndOfferTheOriginal() {
        let raw = #"{"blocks":[{"id":"first","type":"paragraph","data":{"text":"正文"}},{"id":"future","type":"table","data":{"content":[["单元格"]]}},{"id":"last","type":"paragraph","data":{"text":"末段"}}]}"#
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(blocks.map(\.id) == ["first", "future", "last"])
        if case .requiresOriginal = blocks[1] {} else { Issue.record("Extended content should keep an original-reading placeholder") }
        #expect(PaperEditorContentBuilder.canEditAsPlainText(raw) == false)
    }

    @Test(arguments: ["body", "blocks", "block"])
    func articleResourceBudgetsStopBeforeRichTextImport(kind: String) throws {
        let raw: String
        switch kind {
        case "body": raw = String(repeating: "x", count: PaperContentResourceLimits.maximumBodyBytes + 1)
        case "blocks":
            let block: [String: Any] = ["type": "paragraph", "data": ["text": "text"]]
            raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": Array(repeating: block,
                count: PaperContentResourceLimits.maximumBlocks + 1)]), as: UTF8.self)
        default:
            raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": [["type": "paragraph",
                "data": ["text": String(repeating: "x", count: PaperContentResourceLimits.maximumBlockBytes + 1)]]]]), as: UTF8.self)
        }
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(blocks.count == 1)
        if case .requiresOriginal = blocks[0] {} else { Issue.record("Oversized content should offer original reading") }
    }

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
        (.paper, "BIT101.Paper", "服务暂时繁忙", false), (.course, "BIT101.Paper", "文章不存在Orz", false)], [404, 500])
    func knownResourceAbsenceKeepsOtherServerFailuresVisible(fixture: (CommunityWriteSmoke.Kind, String, String, Bool), status: Int) {
        let (kind, domain, message, missing) = fixture
        let error = NSError(domain: domain, code: status, userInfo: [NSLocalizedDescriptionKey: message])
        #expect(CommunityWriteSmoke.Operations.isMissingContent(error, kind: kind) == missing)
    }

    private final class MissingRoute: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            return (Data(#"{"message":"Not Found"}"#.utf8),
                try #require(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)))
        }
    }

    @Test func routeFailuresRemainVisibleThroughProductionReadAndCommentOperations() async {
        let session = CommunitySession(httpClient: HTTPClient(transport: MissingRoute(), observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "fixture"), cookie: "fixture") }, refresh: { _ in })
        let operations = CommunityWriteSmoke.Operations.production(papers: PaperService(session: session),
            gallery: GalleryService(session: session, preferences: {
                CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false)
            }))
        for kind in [CommunityWriteSmoke.Kind.paper, .poster] {
            await #expect(throws: (any Error).self) { try await operations.read(kind, 1) }
        }
        await #expect(throws: (any Error).self) { try await operations.comments("poster1") }
        await #expect(throws: (any Error).self) { try await operations.deleteComment(1) }
    }

    @Test func journalSurvivesRestartAndRetainsTheRecoveryRecordOnStorageFailure() throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let directory = files.temporaryDirectoryURL.appendingPathComponent("NetworkSmoke", isDirectory: true)
        let original = try JSONEncoder().encode(CommunityWriteSmoke.Journal(marker: "recovery", account: 1))
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
        await #expect(throws: (any Error).self) { try await smoke.run(marker: "fixture", expectedAccount: 1) }
        #expect(world.nextID == 100)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
    }

    @Test func declaredSmokeAccountIsCheckedBeforeRecoveryAndOnlineWrites() async throws {
        let world = CommunityWorld(stage: "success")
        let original = try JSONEncoder().encode(CommunityWriteSmoke.Journal(marker: "fixture", account: 1))
        world.pending = original
        for account in [nil, 2] as [Int?] {
            await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", expectedAccount: account) }
            #expect(world.pending == original && world.nextID == 100 && world.followsTarget)
        }
        let evidence = try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        #expect(evidence.contains("验收账号 user1") && world.nextID > 100 && world.pending == nil)
    }

    @Test func followInterruptionRetainsItsTargetUntilTheOriginalRelationshipIsConfirmed() async throws {
        let world = CommunityWorld(stage: "persistent-follow")
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", expectedAccount: 1) }
        let pending = try #require(world.pending)
        #expect(try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: pending).followTarget == 2)
        world.stage = "success"
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.followsTarget && world.pending == nil)
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
            communityWriteProbe: { id, _, _, _ in
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

    @Test(arguments: [false, true])
    func historicalJournalMigratesItsRecoveryIdentifiers(legacyPreferences: Bool) throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let directory = files.temporaryDirectoryURL.appendingPathComponent("NetworkSmoke", isDirectory: true)
        let original = Data(#"{"marker":"fixture","account":1,"targets":[{"kind":"poster","id":101}],"comments":[201]}"#.utf8)
        if !legacyPreferences { try CommunityWriteSmoke.saveJournal(original, files: files, directory: directory) }
        var removed = false
        let loaded = try CommunityWriteSmoke.loadJournal(files: files, directory: directory,
            legacyData: legacyPreferences ? original : nil, removeLegacy: { removed = true })
        let migrated = try #require(loaded)
        let payload = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(payload["schemaVersion"] as? Int == CommunityWriteSmoke.Journal.currentVersion)
        #expect((payload["targets"] as? [[String: Any]])?.first?["id"] as? Int == 101)
        #expect(payload["comments"] as? [Int] == [201])
        #expect((payload["likes"] as? [Any])?.isEmpty == true)
        #expect(removed == legacyPreferences)
        #expect(try CommunityWriteSmoke.loadJournal(files: files, directory: directory, legacyData: nil) == migrated)
    }

    @Test func futureJournalKeepsTheOriginalRecoveryState() throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let directory = files.temporaryDirectoryURL.appendingPathComponent("NetworkSmoke", isDirectory: true)
        let original = Data(#"{"schemaVersion":4,"marker":"fixture","account":1}"#.utf8)
        var removed = false
        #expect(throws: DecodingError.self) {
            try CommunityWriteSmoke.loadJournal(files: files, directory: directory, legacyData: original,
                removeLegacy: { removed = true })
        }
        #expect(removed == false)
        try CommunityWriteSmoke.saveJournal(original, files: files, directory: directory)
        #expect(throws: DecodingError.self) {
            try CommunityWriteSmoke.loadJournal(files: files, directory: directory, legacyData: nil)
        }
        #expect(try files.readData(at: directory.appendingPathComponent("community-write-journal.json")) == original)
    }

    @Test func historicalJournalRecoversItsCreatedObject() async throws {
        let world = CommunityWorld(stage: "success")
        world.contents["poster101"] = .init(text: "fixture", owned: true, liked: false)
        world.pending = Data(#"{"marker":"fixture","account":1,"targets":[{"kind":"poster","id":101}]}"#.utf8)
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.contents["poster101"] == nil)
        #expect(world.contents["poster77"]?.text == "原有内容" && world.pending == nil)
    }

    @Test func historicalJournalRecoversCourseCommentsAndReplies() async throws {
        let world = CommunityWorld(stage: "success")
        let comment = try await world.operations.comment("course1", "功能验收 legacy")
        let reply = try await world.operations.comment("comment\(comment.id)", "功能验收 legacy")
        world.pending = Data("""
        {"marker":"功能验收 legacy","account":1,"targets":[{"kind":"course","id":1}],"comments":[\(comment.id),\(reply.id)]}
        """.utf8)
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
        #expect(world.commentDeletionRequests == [reply.id, comment.id])
        #expect(world.contents["course1"]?.liked == true)
    }

    @Test func unmappedCommentKeepsAmbiguousFailuresUntilParentAbsenceIsConfirmed() async throws {
        let world = CommunityWorld(stage: "silent-comment-delete")
        let comment = try await world.operations.comment("course1", "功能验收 fixture")
        var journal = CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1)
        journal.comments = [comment.id]
        world.pending = try JSONEncoder().encode(journal)
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", cleanupOnly: true) }
        let pending = try #require(world.pending)
        #expect(try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: pending).comments == [comment.id])
        #expect(world.rows["course1"]?.count == 1)
        world.rows = [:]
        world.stage = "missing-comment"
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", cleanupOnly: true) }
        #expect(try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: #require(world.pending)).comments == [comment.id])
        journal.parents = ["course1"]
        journal.commentParents = [comment.id: "course1"]
        world.pending = try JSONEncoder().encode(journal)
        world.stage = "success"
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
    }

    @Test(arguments: ["route-read", "route-comments", "missing-comment"])
    func routeFailuresPreserveRecoveryUntilTheServerConfirmsCleanup(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        world.contents["poster123"] = .init(text: "功能验收 fixture", owned: true, liked: false)
        let comment = try await world.operations.comment("poster123", "功能验收 fixture")
        var journal = CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1)
        journal.targets = [.init(kind: .poster, id: 123)]
        journal.parents = ["poster123"]
        journal.comments = [comment.id]
        journal.commentParents = [comment.id: "poster123"]
        world.pending = try JSONEncoder().encode(journal)
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", cleanupOnly: true) }
        let pending = try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: #require(world.pending))
        #expect(pending.targets == journal.targets)
        #expect(world.contents["poster123"] != nil)
        if stage != "route-read" { #expect(pending.comments == journal.comments) }
        world.stage = "success"
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil && world.contents["poster123"] == nil)
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
    }

    @Test(arguments: [false, true])
    func restartedCleanupConfirmsAnAlreadyDeletedCommentFromItsPersistedParent(legacy: Bool) async throws {
        let original = CommunityWorld(stage: "success")
        let comment = try await original.operations.comment("course1", "功能验收 fixture")
        var journal = CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1)
        journal.parents = ["course1"]
        journal.comments = [comment.id]
        journal.commentParents = [comment.id: "course1"]
        journal.evidence = ["创建 comment\(comment.id) 目标 course1"]
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        if legacy { payload["schemaVersion"] = 1; payload.removeValue(forKey: "commentParents") }
        let saved = try JSONSerialization.data(withJSONObject: payload)
        #expect(try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: saved).commentParents == [comment.id: "course1"])
        try await original.operations.deleteComment(comment.id)
        let restarted = CommunityWorld(stage: "success")
        restarted.pending = saved
        let evidence = try await restarted.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(restarted.pending == nil)
        #expect(evidence.contains("服务端清理确认完成"))
        #expect(restarted.commentDeletionRequests == [comment.id])
    }

    private final class CommunityWorld {
        var followsTarget = true
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
                self.contents[kind.rawValue + String(id)] = .init(text: text, owned: true, liked: false, imageMids: ["fixture-image"])
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
                if self.stage == "route-read" { throw NSError(domain: "BIT101.Gallery", code: 404) }
                if self.switchAccount(during: "read") { return nil }
                return self.contents[kind.rawValue + String(id)]
            }, edit: { kind, id, text in
                let key = kind.rawValue + String(id)
                self.contents[key] = .init(text: text, owned: true, liked: false, imageMids: ["fixture-image"])
            }, delete: { kind, id in
                try Task.checkCancellation()
                if self.stage == "persistent-delete" && kind == .paper { throw URLError(.timedOut) }
                if self.switchAccount(during: "delete") { throw NSError(domain: "fixture", code: 404) }
                if self.stage == "cleanup-failure" && !self.injected { self.injected = true; throw URLError(.timedOut) }
                self.contents[kind.rawValue + String(id)] = nil
            }, comments: { parent in
                if self.stage == "route-comments" { throw NSError(domain: "BIT101.Gallery", code: 404) }
                if self.switchAccount(during: "comments") { return [] }
                if self.stage == "deleted-parent-read", parent.hasPrefix("comment"),
                   let id = Int(parent.dropFirst(7)), !self.rows.values.joined().contains(where: { $0.id == id }) {
                    throw NSError(domain: "BIT101.Gallery", code: 500, userInfo: [NSLocalizedDescriptionKey: "获取顶级对象失败Orz"])
                }
                return self.rows[parent] ?? []
            }, comment: { object, text in
                self.nextID += 1
                @MainActor func makeComment(_ id: Int) -> CommunityComment { CommunityComment(id: id, obj: object, images: [.init(mid: "fixture-image", url: "", lowUrl: "")], user: self.user, anonymous: false,
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
                        self.contents[key] = .init(text: old.text, owned: old.owned, liked: !old.liked, imageMids: old.imageMids)
                    }
                    throw URLError(.timedOut)
                }
                self.contents[key] = .init(text: old.text, owned: old.owned, liked: !old.liked, imageMids: old.imageMids)
                return !old.liked
            }, followTarget: { 2 }, following: { _ in self.followsTarget }, follow: { _ in
                self.followsTarget.toggle()
                if self.stage == "persistent-follow" { throw URLError(.timedOut) }
                return self.followsTarget
            })
        }
        var smoke: CommunityWriteSmoke {
            .init(operations: operations, load: { self.pending }, save: { self.pending = $0 })
        }
    }

    @Test func confirmedCommentAbsenceRetiresALostDeletionResponseBeforeRecovery() async throws {
        let world = CommunityWorld(stage: "lost-delete-response")
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", expectedAccount: 1) }
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
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", expectedAccount: 1) }
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
        let evidence = try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        #expect(evidence.filter { $0.hasPrefix("服务端确认删除 comment") }.count == 6)
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
    }

    @Test(arguments: ["success", "lost-poster", "lost-reply", "cancelled", "cleanup-failure", "duplicate-comments", "invalid-paper"])
    func communityWritesCleanAfterLostResponsesCancellationAndResume(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        let task = Task { try await world.smoke.run(marker: "fixture", expectedAccount: 1) }
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
        var webvpnVerified = false
        var ssoVerified = false
        private var smsChallenge: BITLoginAuthenticationChallenge { .init(challengeID: "fixture", accessToken: "fixture", status: "sms_required", maskedPhone: "***", expiresIn: 60) }
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
            GalleryPosterDetail(anonymous: false, claim: poster.claim, commentNum: 0, createTime: "", editTime: "", id: stage == "entity-identity-failure" ? id + 1 : id, images: poster.images,
                like: false, likeNum: 0, own: false, plugins: "", public: true, tags: [], text: "fixture", title: "fixture", updateTime: "", user: user)
        }
        func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment> {
            .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }
        func fetchClaims() async throws -> [CommunityClaim] { [poster.claim] }
        func fetchReportTypes() async throws -> [GalleryReportType] { [] }
        func fetchCourses(search: String, page: Int) async throws -> [CourseSummary] {
            guard page == 0 || stage == "repeated-page-failure" else { return [] }
            return [CourseSummary(detail: CourseDetail(id: 1, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false))]
        }
        func fetchCourse(id: Int) async throws -> CourseDetail {
            observed.insert("course-detail")
            if stage == "community-failure" { throw URLError(.timedOut) }
            return CourseDetail(id: stage == "entity-identity-failure" ? id + 1 : id, name: "fixture", number: "COURSE", credit: 1, likeNum: 0, commentNum: 0, rate: 0, teachersName: "", teachersNumber: "", like: false)
        }
        func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] { [] }
        func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment] { [] }
        func fetchPapers(search: String?, order: PaperSortOrder, page: Int) async throws -> [PaperSummary] {
            observed.insert("paper-list")
            guard page == 0 else { return [] }
            return [PaperSummary(id: 1, title: "fixture", intro: "", likeNum: 0, commentNum: 0, updateTime: "")]
        }
        func fetchPaper(id: Int) async throws -> PaperDetail {
            PaperDetail(id: stage == "entity-identity-failure" ? id + 1 : id, title: "fixture", intro: "", content: "fixture", createTime: "", updateTime: "", updateUser: user,
                anonymous: false, likeNum: 0, commentNum: 0, publicEdit: false, like: false, own: false)
        }
        func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment] { [] }
        func fetchMyInfo() async throws -> MineUserInfo { observed.insert("mine"); return try await fetchUserInfo(id: 1) }
        func fetchUserInfo(id: Int) async throws -> MineUserInfo { MineUserInfo(user: user, followingNum: 0, followerNum: 0, following: false, follower: false, own: true) }
        func fetchUserPosters(userID: Int, page: Int) async throws -> [CommunityPoster] { page == 0 ? [poster] : [] }
        func fetchMyPosters(page: Int) async throws -> [CommunityPoster] { page == 0 ? [poster] : [] }
        func fetchFollowers(page: Int) async throws -> [CommunityUser] { [] }
        func fetchFollowings(page: Int) async throws -> [CommunityUser] { [] }
        func fetchCurrentTermOnly() async throws -> String {
            if stage == "all-sms-success" && !webvpnVerified { throw ScheduleServiceError.secondFactorRequired(smsChallenge) }
            return "fixture-1"
        }
        func fetchAvailableTerms() async throws -> [String] { ["fixture-1"] }
        func syncCourses(term: String?) async throws -> CourseSyncPayload {
            observed.insert("schedule")
            rawResponse?(Data("course-response".utf8))
            return CourseSyncPayload(term: term ?? "fixture-1", firstDayString: "2026-03-02", sourceFirstDayString: "2026-03-02",
                normalizationOffset: 0, rawWeeksByCourse: [], courses: [], exams: [])
        }
        func submitSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge, term: String?) async throws -> CourseSyncPayload { try await syncCourses(term: term) }
        func submitSMSCodeForTeachingCenterAuthentication(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws { webvpnVerified = true }
        func prepareTeachingCenterAccess() async throws {}
        func fetchCampuses() async throws -> [CampusRecord] { [CampusRecord(id: "campus", name: "fixture", code: "campus")] }
        func fetchBuildings(campusCode: String?) async throws -> [BuildingRecord] { [BuildingRecord(id: "building", name: "fixture", buildingCode: "building", campusName: "fixture", campusCode: "campus")] }
        func fetchClassrooms(buildingID: String, term: String) async throws -> [ClassroomRecord] { [ClassroomRecord(id: "room", name: "fixture", busyTimeCodes: [])] }
        func fetchEclassDDLEvents(schoolSMSCodeHandler: SchoolSMSCodeHandler?) async throws -> EclassDDLResult {
            if stage == "all-sms-success" && !ssoVerified {
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
            if stage == "all-sms-success" { throw ScoreServiceError.secondFactorRequired(smsChallenge) }
            return BITLoginAuthenticationChallenge(challengeID: "fixture", accessToken: "fixture", status: "authenticated", maskedPhone: nil, expiresIn: 60) }
        func fetchScores(detail: Bool, authenticatedBy challenge: BITLoginAuthenticationChallenge) async throws -> [ScoreRow] { [] }
        func submitScoreSMSCode(_ code: String, for challenge: BITLoginAuthenticationChallenge) async throws -> BITLoginAuthenticationChallenge { .init(challengeID: "fixture", accessToken: "fixture", status: "authenticated", maskedPhone: nil, expiresIn: 60) }
        func fetchTrustedTranscriptPages() async throws -> [Data] {
            if stage == "all-sms-success" { throw ScoreServiceError.secondFactorRequired(smsChallenge) }
            return [image]
        }
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
        ["all-success", "all-sms-success", "all-sms-not-required", "community-failure", "schedule-success", "ddl-success", "ddl-failure", "ddl-invalid-calendar-failure", "raw-write-failure",
         "app-store-redirect-failure", "emergency-redirect-failure", "aasa-redirect-failure", "aasa-followed-redirect-failure",
         "aasa-mime-failure", "aasa-exclusion-failure", "image-budget-failure", "entity-identity-failure", "repeated-page-failure"])
    func completeOrchestration(stage: String) async throws {
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }.pngData())
        let services = Services(stage: stage, image: image)
        let productionServices = Services(stage: stage, image: image)
        let redirectHost = stage == "app-store-redirect-failure" ? "itunes.apple.com"
            : stage == "emergency-redirect-failure" ? "update.aihelpme.dev" : nil
        let external = External(image: image, redirectHost: redirectHost, aasaStage: stage)
        let association = External(image: image, aasaStage: stage)
        var reports: [ReleaseNetworkSmokeReport] = []
        var feedback = 0
        var rawWrites = 0
        let sessionEvidence = ["初始账号资料 ID：1", "无效凭据切换：认证拒绝", "恢复账号资料 ID：1"]
        let dependencies = ReleaseNetworkSmokeDependencies(checkLogin: { "fixture" }, writeReport: { reports.append($0) },
            clearRawCourseResponse: {}, writeRawCourseResponse: { _, runID in
                rawWrites += 1
                #expect(runID == stage)
                if stage == "raw-write-failure" { throw CocoaError(.fileWriteNoPermission) }
            }, makeGallery: { services }, makeCourses: { services }, makePapers: { services }, makeMine: { services },
            productionSessionProbe: { sessionEvidence }, externalHTTPClient: HTTPClient(transport: external, observer: nil), aasaHTTPClient: HTTPClient(transport: association, observer: nil),
            feedbackProbe: { _ in feedback += 1 },
            loadScheduleCache: { ScheduleCache() }, makeScores: { services }, makeSchedule: { handler in services.rawResponse = handler; return services },
            makeProductionSchedule: { productionServices }, makeEclassSchedule: { services })
        let scope: NetworkSmokeScope = stage.hasPrefix("all-") || redirectHost != nil || stage.hasPrefix("aasa") ? .all : stage == "community-failure" || stage == "image-budget-failure" || stage == "entity-identity-failure" || stage == "repeated-page-failure" ? .bit101 : stage.hasPrefix("ddl") ? .ddl : .schedule
        let runner = ReleaseNetworkSmokeRunner(dependencies: dependencies)
        let smsHandler: SchoolSMSCodeHandler = { _ in "fixture-code" }
        let report = await runner.run(scope: scope, runID: stage, capture: stage == "raw-write-failure" ? .rawCourseResponse : .none,
            schoolSMSCodeHandler: stage.hasPrefix("all-sms-") ? smsHandler : nil)
        #expect(report.passed == !stage.hasSuffix("failure"))
        #expect(report.productionSessionEvidence == (scope.includes(.bit101) ? sessionEvidence : []))
        if stage == "all-sms-success" {
            #expect(report.schoolSMSCoverage == "verified")
            #expect(services.webvpnVerified && productionServices.webvpnVerified)
            #expect(Set(report.verifiedSMSProbes.filter { $0.purpose == "webvpn" }.map(\.probe)) == ["生产学校会话", "当前学期"])
            #expect(Set(report.verifiedSMSProbes.map(\.purpose)) == NetworkSmokeScope.all.requiredSMSPurposes)
        }
        if stage.hasPrefix("all-sms-") {
            #expect(Set(report.authenticatedSchoolProbes.map(\.purpose)) == NetworkSmokeScope.all.requiredSMSPurposes)
            #expect(Set(report.requestedSMSPurposes) == Set(report.verifiedSMSProbes.map(\.purpose)))
            #expect(report.coverageComplete)
        }
        if stage == "all-sms-not-required" {
            #expect(report.schoolSMSCoverage == "not_required")
            #expect(report.verifiedSMSProbes.isEmpty && report.requestedSMSPurposes.isEmpty)
        }
        if stage == "repeated-page-failure" {
            #expect(report.failures.contains { $0.contains("学业课程列表") })
            #expect(Set(scope.requiredProbes).subtracting(report.executedProbes)
                == ["学业课程详情", "学业课程评论", "学业课程历史成绩", "学业课程网页详情"])
            #expect(!report.coverageComplete)
        } else { #expect(Set(report.executedProbes) == Set(scope.requiredProbes)) }
        #expect(reports.count == 1 && reports[0].passed == report.passed)
        if scope.includes(.bit101) { #expect(feedback == 1 && services.observed.contains("mine") && services.observed.contains("paper-list")) }
        #expect(association.requests.count == (scope.includes(.bit101) ? 1 : 0))
        #expect(external.requests.allSatisfy { $0.url?.path.hasSuffix("apple-app-site-association") == false })
        if scope.includes(.bit101) {
            #expect(!external.imageBudgets.isEmpty && external.imageBudgets.allSatisfy { $0 == RemoteImageResourceLimits.maximumEncodedBytes })
        }
        if stage == "entity-identity-failure" {
            #expect(report.failures.count == 3)
            for name in ["话廊帖子详情", "学业课程详情", "文章详情"] { #expect(report.failures.contains { $0.contains(name) }) }
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
        let next = await runner.run(scope: .transcript, runID: "next", schoolSMSCodeHandler: stage == "all-sms-success" ? smsHandler : nil)
        #expect(next.passed && next.failures.isEmpty && next.coverageComplete)
        #expect(reports.count == 2)
    }
}
#endif
