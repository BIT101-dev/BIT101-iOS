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

    @Test(arguments: [0, 2, 3, 4])
    func smokeUsesTheSmallTermCorrectionPolicy(rawOffset: Int) throws {
        let rows: [[String: Any]] = (1...2).map { index in
            ["KCH": "course-\(index)", "KCM": "课程\(index)", "SKXQ": index, "KSJC": 1, "JSJC": 2,
             "SKZC": String(repeating: "0", count: rawOffset) + "11", "ZCMC": "1-2周", "YPSJDD": "1-2周"]
        }
        let data = try JSONSerialization.data(withJSONObject: ["datas": ["cxxszhxqkb": ["rows": rows]]])
        let response = try JSONDecoder().decode(CourseResponse.self, from: data)
        let rawWeeks = response.parsedCourses.map(\.rawWeeks)
        let normalized = SmallTermWeekNormalizer.normalize(term: "2026-2027-1", firstDayString: "2026-09-07",
            courses: response.courseRecords, rawWeeksByCourse: rawWeeks)
        let expectedOffset = rawOffset == 3 ? 3 : 0
        #expect(normalized.offset == expectedOffset)
        #expect(normalized.firstDayString == (rawOffset == 3 ? "2026-09-28" : "2026-09-07"))
        let payload = CourseSyncPayload(term: "2026-2027-1", firstDayString: normalized.firstDayString,
            sourceFirstDayString: "2026-09-07", normalizationOffset: normalized.offset,
            rawWeeksByCourse: rawWeeks, courses: normalized.courses, exams: [])
        try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(payload)
        let inconsistent = CourseSyncPayload(term: payload.term, firstDayString: payload.firstDayString,
            sourceFirstDayString: payload.sourceFirstDayString, normalizationOffset: expectedOffset == 0 ? 3 : 0,
            rawWeeksByCourse: rawWeeks, courses: payload.courses, exams: [])
        #expect(throws: NSError.self) { try ReleaseNetworkSmokeRunner.validateCourseSyncPayload(inconsistent) }
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
        let id = try await operations.create(.paper, text, { _ in })
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
        let comment = try await operations.comment("course42", "功能验收", { _ in })
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

    @Test(arguments: ["follow-noop", "follow-response-mismatch", "follow-restore-noop"])
    func followProbeRequiresBothTransitionsAndRestoresTheRelationship(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", expectedAccount: 1) }
        #expect(world.nextID == 100)
        if stage == "follow-restore-noop" {
            let journal = try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: #require(world.pending))
            #expect(journal.followTarget == 2 && !world.followsTarget)
            world.stage = "success"
            _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
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
        let dependencies = ReleaseNetworkSmokeDependencies(requiresRequestEvidence: false, checkLogin: { loginCalls += 1; return "fixture" }, writeReport: { reports.append($0.runID) },
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
        let original = Data(#"{"schemaVersion":5,"marker":"fixture","account":1}"#.utf8)
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
        let comment = try await world.operations.comment("course1", "功能验收 legacy", { _ in })
        let reply = try await world.operations.comment("comment\(comment.id)", "功能验收 legacy", { _ in })
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
        let comment = try await world.operations.comment("course1", "功能验收 fixture", { _ in })
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
        let comment = try await world.operations.comment("poster123", "功能验收 fixture", { _ in })
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
        let comment = try await original.operations.comment("course1", "功能验收 fixture", { _ in })
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
        private var user: CommunityUser {
            CommunityUser(id: 1, createTime: "", nickname: "功能验收", avatar: .init(mid: "", url: "", lowUrl: ""), motto: "",
                identity: .init(id: 1, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
        }
        var operations: CommunityWriteSmoke.Operations {
            .init(identity: { .init(accountIdentifier: String(self.account)) }, account: { self.account }, course: { 1 }, create: { kind, text, record in
                if self.stage == "invalid-paper" && kind == .paper {
                    throw NSError(domain: "BIT101.Paper", code: 400, userInfo: [NSLocalizedDescriptionKey: "参数错误awa"])
                }
                if self.stage == "signed-out-paper" && kind == .paper { throw PaperServiceError.notLoggedIn }
                if self.stage == "broken-image" { try record("fixture-image") }
                self.nextID += 1
                let id = self.nextID
                self.contents[kind.rawValue + String(id)] = .init(text: text, owned: true, liked: false,
                    imageMids: [self.stage == "broken-image" ? "wrong" : "fixture-image"])
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
                if self.delayedParent == parent, !self.creationVisible { return [] }
                if self.stage == "deleted-parent-read", parent.hasPrefix("comment"),
                   let id = Int(parent.dropFirst(7)), !self.rows.values.joined().contains(where: { $0.id == id }) {
                    throw NSError(domain: "BIT101.Gallery", code: 500, userInfo: [NSLocalizedDescriptionKey: "获取顶级对象失败Orz"])
                }
                return self.rows[parent] ?? []
            }, comment: { object, text, _ in
                self.nextID += 1
                @MainActor func makeComment(_ id: Int) -> CommunityComment { CommunityComment(id: id, obj: object, images: [.init(mid: "fixture-image", url: "", lowUrl: "")], user: self.user, anonymous: false,
                    createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: true, rate: 0,
                    replyUser: self.user, replyObj: "", text: text, sub: []) }
                let value = makeComment(self.nextID)
                self.rows[object, default: []].append(value)
                let createdKind = object.hasPrefix("comment") ? "reply" : "comment"
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
                        self.contents[key] = .init(text: old.text, owned: old.owned, liked: !old.liked, imageMids: old.imageMids)
                    }
                    throw URLError(.timedOut)
                }
                self.contents[key] = .init(text: old.text, owned: old.owned, liked: !old.liked, imageMids: old.imageMids)
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
        #expect(world.contents.keys.filter { $0.hasPrefix("paper") }.count == (stage == "persistent-like" ? 0 : 1))
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
        let comment = try await world.operations.comment("poster123", "功能验收 fixture", { _ in })
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

    @Test(arguments: ["success", "lost-poster", "lost-reply", "cancelled", "cleanup-failure", "duplicate-comments", "invalid-paper", "signed-out-paper", "broken-image"])
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

    @Test(arguments: ["late-poster", "hidden-poster", "late-paper", "hidden-paper", "late-comment", "hidden-comment", "late-reply", "hidden-reply"])
    func recoveryRetainsUnconfirmedWritesUntilTheirObjectsBecomeVisible(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", expectedAccount: 1) }
        let pending = try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: #require(world.pending))
        #expect(!pending.attempts.isEmpty || !pending.commentAttempts.isEmpty)
        await #expect(throws: (any Error).self) { try await world.smoke.run(marker: "fixture", cleanupOnly: true) }
        #expect(world.pending != nil)
        world.contents.merge(world.delayedContents, uniquingKeysWith: { _, delayed in delayed })
        world.rows.merge(world.delayedRows, uniquingKeysWith: { existing, delayed in existing + delayed })
        world.creationVisible = true
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
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
        let dependencies = ReleaseNetworkSmokeDependencies(requiresRequestEvidence: false, checkLogin: { "fixture" }, writeReport: { stored = $0 },
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
        let dependencies = ReleaseNetworkSmokeDependencies(requiresRequestEvidence: false,
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
