#if RELEASE_NETWORK_SMOKE
@testable import BIT101_iOS
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

extension ReleaseNetworkSmokeLifecycleTests {
    @Test(.timeLimit(.minutes(1))) func concurrentRunnerEntrypointsRecovery() async throws {
        var waiting: CheckedContinuation<Void, Never>?
        var entered = false
        var runs: [String] = []
        var reports: [String] = []
        var loginCalls = 0
        var rawCleanupCalls = 0
        let dependencies = ReleaseNetworkSmokeDependencies(
            requiresRequestEvidence: false,
            checkLogin: {
                loginCalls += 1
                return "fixture"
            }, writeReport: { reports.append($0.runID) },
            clearRawCourseResponse: {
                rawCleanupCalls += 1
                throw CocoaError(.fileWriteNoPermission)
            },
            communityWriteProbe: { id, _, _, _, _, _, _ in
                runs.append(id)
                if id == "first" {
                    await withCheckedContinuation {
                        waiting = $0
                        entered = true
                    }
                }
                return ["服务端清理确认完成"]
            })
        let first = Task {
            await ReleaseNetworkSmokeRunner(dependencies: dependencies).run(
                scope: .communityCleanup, runID: "first")
        }
        defer {
            first.cancel()
            waiting?.resume()
        }
        try await waitForTestEvent { entered }
        let cancelled = Task {
            await ReleaseNetworkSmokeRunner(dependencies: dependencies).run(
                scope: .all, runID: "cancelled")
        }
        await Task.yield()
        cancelled.cancel()
        let cancelledReport = await cancelled.value
        #expect(!cancelledReport.passed && cancelledReport.executedProbes.isEmpty)
        #expect(loginCalls == 1 && reports.isEmpty && rawCleanupCalls == 0)
        let second = Task {
            await ReleaseNetworkSmokeRunner(dependencies: dependencies).run(
                scope: .communityCleanup, runID: "second")
        }
        await Task.yield()
        #expect(runs == ["first"])
        let resume = try #require(waiting)
        resume.resume()
        waiting = nil
        let initial = await first.value
        let next = await second.value
        #expect(initial.passed && next.passed)
        #expect(runs == ["first", "second"])
        #expect(loginCalls == 2 && reports == ["first", "second"])
        #expect(rawCleanupCalls == 0)
    }

    @Test(arguments: [false, true])
    func historicalJournalMigratesRecoveryIds(legacyPreferences: Bool) throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let directory = files.temporaryDirectoryURL.appendingPathComponent(
            "NetworkSmoke", isDirectory: true)
        let original = Data(
            #"""
            {"marker":"功能验收 fixture","account":1,"targets":[{"kind":"poster","id":101}],"c\#
            omments":[201]}
            """#
            .utf8)
        if !legacyPreferences {
            try CommunityWriteSmoke.saveJournal(original, files: files, directory: directory)
        }
        var removed = false
        let loaded = try CommunityWriteSmoke.loadJournal(
            files: files, directory: directory,
            legacyData: legacyPreferences ? original : nil, removeLegacy: { removed = true })
        let migrated = try #require(loaded)
        let payload = try #require(
            JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(payload["schemaVersion"] as? Int == CommunityWriteSmoke.Journal.currentVersion)
        #expect((payload["targets"] as? [[String: Any]])?.first?["id"] as? Int == 101)
        #expect(payload["comments"] as? [Int] == [201])
        #expect((payload["likes"] as? [Any])?.isEmpty == true)
        #expect(removed == legacyPreferences)
        #expect(
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: nil) == migrated)
    }

    @Test func futureJournalKeepsTheOriginalRecoveryState() throws {
        let files = PreferenceMemoryFiles(requireExistingParentDirectories: true)
        let directory = files.temporaryDirectoryURL.appendingPathComponent(
            "NetworkSmoke", isDirectory: true)
        let original = Data(
            """
            {\"schemaVersion\":\(CommunityWriteSmoke.Journal.currentVersion + 1),\"marker\"\
            :\"fixture\",\"account\":1}
            """
            .utf8)
        var removed = false
        #expect(throws: DecodingError.self) {
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: original,
                removeLegacy: { removed = true })
        }
        #expect(removed == false)
        try CommunityWriteSmoke.saveJournal(original, files: files, directory: directory)
        #expect(throws: DecodingError.self) {
            try CommunityWriteSmoke.loadJournal(
                files: files, directory: directory, legacyData: nil)
        }
        #expect(
            try files.readData(
                at: directory.appendingPathComponent("community-write-journal.json"))
                == original)
    }

    @Test(.timeLimit(.minutes(1))) func historicalJournalRecoversItsCreatedObject() async throws {
        let world = CommunityWorld(stage: "success")
        world.contents["poster101"] = .init(text: "功能验收 fixture", owned: true, liked: false)
        world.pending = Data(
            #"{"marker":"功能验收 fixture","account":1,"targets":[{"kind":"poster","id":101}]}"#
                .utf8)
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.contents["poster101"] == nil)
        #expect(world.contents["poster77"]?.text == "原有内容" && world.pending == nil)
    }

    @Test(.timeLimit(.minutes(1))) func historicalJournalRecoversCourseComments() async throws {
        let world = CommunityWorld(stage: "success")
        let comment = try await world.operations.comment(
            .init(kind: .course, object: "course1"), "功能验收 legacy", { _ in }, {})
        let reply = try await world.operations.comment(
            .init(kind: .course, object: "comment\(comment.id)"), "功能验收 legacy", { _ in }, {})
        world.pending = Data(
            """
            {"marker":"功能验收 legacy","account":1,"targets":[{"kind":"course","id":1}],"comments"\
            :[\(comment.id),\(reply.id)]}
            """.utf8)
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
        #expect(world.commentDeletionRequests == [reply.id, comment.id])
        #expect(world.contents["course1"]?.liked == true)
    }

    @Test(.timeLimit(.minutes(1))) func unmappedCommentKeepsAmbiguousConfirmed() async throws {
        let world = CommunityWorld(stage: "silent-comment-delete")
        let comment = try await world.operations.comment(
            .init(kind: .course, object: "course1"), "功能验收 fixture", { _ in }, {})
        var journal = CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1)
        journal.comments = [comment.id]
        world.pending = try JSONEncoder().encode(journal)
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        let pending = try #require(world.pending)
        #expect(
            try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: pending).comments
                == [comment.id])
        #expect(world.rows["course1"]?.count == 1)
        world.rows = [:]
        world.stage = "missing-comment"
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(
            try JSONDecoder().decode(
                CommunityWriteSmoke.Journal.self, from: #require(world.pending)
            ).comments == [comment.id])
        journal.parents = ["course1"]
        journal.commentParents = [comment.id: "course1"]
        world.pending = try JSONEncoder().encode(journal)
        world.stage = "success"
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
    }

    @Test(
        .timeLimit(.minutes(1)), arguments: ["route-read", "route-comments", "missing-comment"])
    func routeFailuresPreserveRecoveryUntilCleanup(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        world.contents["poster123"] = .init(text: "功能验收 fixture", owned: true, liked: false)
        let comment = try await world.operations.comment(
            .init(kind: .poster, object: "poster123"), "功能验收 fixture", { _ in }, {})
        var journal = CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1)
        journal.targets = [.init(kind: .poster, id: 123)]
        journal.parents = ["poster123"]
        journal.comments = [comment.id]
        journal.commentParents = [comment.id: "poster123"]
        world.pending = try JSONEncoder().encode(journal)
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        let pending = try JSONDecoder().decode(
            CommunityWriteSmoke.Journal.self, from: #require(world.pending))
        #expect(pending.targets == journal.targets)
        #expect(world.contents["poster123"] != nil)
        if stage != "route-read" { #expect(pending.comments == journal.comments) }
        world.stage = "success"
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil && world.contents["poster123"] == nil)
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func restartedCleanupConfirmsParent(legacy: Bool) async throws {
        let original = CommunityWorld(stage: "success")
        let comment = try await original.operations.comment(
            .init(kind: .course, object: "course1"), "功能验收 fixture", { _ in }, {})
        var journal = CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1)
        journal.parents = ["course1"]
        journal.comments = [comment.id]
        journal.commentParents = [comment.id: "course1"]
        journal.evidence = ["创建 comment\(comment.id) 目标 course1"]
        var payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        if legacy {
            payload["schemaVersion"] = 1
            payload.removeValue(forKey: "commentParents")
        }
        let saved = try JSONSerialization.data(withJSONObject: payload)
        #expect(
            try JSONDecoder().decode(CommunityWriteSmoke.Journal.self, from: saved)
                .commentParents == [comment.id: "course1"])
        try await original.operations.deleteComment(comment.id)
        let restarted = CommunityWorld(stage: "success")
        restarted.pending = saved
        let evidence = try await restarted.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(restarted.pending == nil)
        #expect(evidence.contains("服务端清理确认完成"))
        #expect(restarted.commentDeletionRequests.isEmpty)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["marker", "account", "target", "comment", "parent", "follow"])
    func invalidRecoveryIdentityKeepsJournal(field: String) async throws {
        let world = CommunityWorld(stage: "success")
        var journal = CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1)
        journal.attempts = [.poster, .paper]
        var payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        switch field {
        case "marker": payload["marker"] = ""
        case "account": payload["account"] = 0
        case "target": payload["targets"] = [["kind": "poster", "id": 0]]
        case "comment": payload["comments"] = [-1]
        case "parent": payload["parents"] = ["course0"]
        default: payload["followTarget"] = 0
        }
        let original = try JSONSerialization.data(withJSONObject: payload)
        world.pending = original
        await #expect(throws: DecodingError.self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(world.pending == original && world.commentDeletionRequests.isEmpty)
        #expect(world.contents["poster77"]?.text == "原有内容" && world.followsTarget)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["功能验收 fixture-other", "原有内容"])
    func recoveryPreservesComments(text: String) async throws {
        let world = CommunityWorld(stage: "success")
        let comment = try await world.operations.comment(
            .init(kind: .poster, object: "poster77"), text, { _ in }, {})
        world.contents["poster77"] = .init(text: text, owned: true, liked: true)
        var journal = CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1)
        journal.targets = [.init(kind: .poster, id: 77)]
        journal.likes = [.init(target: journal.targets[0], original: false)]
        journal.parents = ["poster77"]
        journal.comments = [comment.id]
        journal.commentParents = [comment.id: "poster77"]
        world.pending = try JSONEncoder().encode(journal)
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(world.pending != nil && world.commentDeletionRequests.isEmpty)
        #expect(
            world.contents["poster77"]?.text == text
                && world.contents["poster77"]?.liked == true)
        #expect(world.rows["poster77"]?.map(\.id) == [comment.id])
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["absent", "late", "account", "marker", "receipt", "scope", "unconfirmed"])
    func serverAbsenceConfirmationKeepsRecoverable(mode: String) async throws {
        let world = CommunityWorld(stage: "success")
        var journal = CommunityWriteSmoke.Journal(marker: "功能验收 fixture", account: 1)
        journal.attempts = [.poster]
        journal.parents = ["course1"]
        journal.commentAttempts = ["course1"]
        world.pending = try JSONEncoder().encode(journal)
        let original = world.pending
        if mode == "late" {
            world.contents["poster123"] = .init(text: journal.marker, owned: true, liked: false)
        }
        let confirmation = CommunityWriteRecoveryConfirmation(
            marker: mode == "marker" ? "功能验收 other" : journal.marker,
            account: mode == "account" ? 2 : 1,
            serverReceipt: mode == "receipt" ? " " : "backend-reconciliation",
            kinds: ["poster"], parents: ["course1"])
        if ["absent", "late"].contains(mode) {
            let evidence = try await world.smoke.run(
                marker: "fixture", cleanupOnly: true, recoveryConfirmation: confirmation)
            #expect(world.pending == nil && world.contents["poster123"] == nil)
            #expect(evidence.contains("服务端确认未创建评论 course1：backend-reconciliation"))
            #expect(
                evidence.contains(
                    mode == "absent"
                        ? "服务端确认未创建 poster：backend-reconciliation" : "服务端确认删除 poster123"))
        } else {
            await #expect(throws: (any Error).self) {
                try await world.smoke.run(
                    marker: "fixture", cleanupOnly: mode != "scope", expectedAccount: 1,
                    recoveryConfirmation: mode == "unconfirmed" ? nil : confirmation)
            }
            let restored = try #require(world.pending)
            let saved = try #require(original)
            #expect(
                try JSONSerialization.jsonObject(with: restored) as? NSDictionary
                    == JSONSerialization.jsonObject(with: saved) as? NSDictionary)
        }
    }

    @Test(.timeLimit(.minutes(1))) func confirmedCommentAbsenceResponse() async throws {
        let world = CommunityWorld(stage: "lost-delete-response")
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        }
        let data = try #require(world.pending)
        let journal = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((journal["comments"] as? [Int])?.isEmpty == true)
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
        world.stage = "success"
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
        #expect(world.commentDeletionRequests.count == 9)
        #expect(Set(world.commentDeletionRequests).count == 9)
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["persistent-find", "persistent-like", "persistent-delete"])
    func independentObjectsAreCleaned(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        }
        #expect(world.pending != nil)
        #expect(world.contents.keys.filter { $0.hasPrefix("poster") } == ["poster77"])
        #expect(
            world.contents.keys.filter { $0.hasPrefix("paper") }.count
                == (stage == "persistent-like" ? 0 : 1))
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
        world.stage = "success"
        let journal = try JSONDecoder().decode(
            CommunityWriteSmoke.Journal.self, from: #require(world.pending))
        let confirmation =
            journal.pendingMutationIDs.isEmpty
            ? nil
            : CommunityWriteRecoveryConfirmation(
                marker: journal.marker, account: 1, serverReceipt: "fixture-request-finished",
                kinds: [], parents: [], settledMutations: journal.pendingMutationIDs)
        _ = try await world.smoke.run(
            marker: "fixture", cleanupOnly: true, recoveryConfirmation: confirmation)
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
        #expect(world.contents["course1"]?.liked == true)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["read", "comments", "delete", "comment-delete"])
    func interruptedCleanupRetainsPersistedAccount(operation: String) async throws {
        let world = CommunityWorld(stage: "switch-" + operation)
        world.contents["poster123"] = .init(text: "功能验收 fixture", owned: true, liked: false)
        let comment = try await world.operations.comment(
            .init(kind: .poster, object: "poster123"), "功能验收 fixture", { _ in }, {})
        world.pending = Data(
            #"""
            {"marker":"功能验收 fixture","account":1,"attempts":[],"targets":[{"kind":"poster"\#
            ,"id":123}],"parents":["poster123"],"comments":[\#(comment.id)],"likes":[],"ev\#
            idence":[]}
            """#
            .utf8)
        await #expect(throws: CancellationError.self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(world.pending != nil)
        #expect(world.contents["poster123"] != nil)
        world.account = 1
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
    }

    @Test(.timeLimit(.minutes(1))) func repliesAreConfirmed() async throws {
        let world = CommunityWorld(stage: "deleted-parent-read")
        let evidence = try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        #expect(evidence.filter { $0.hasPrefix("服务端确认删除 comment") }.count == 9)
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "success", "lost-poster", "lost-reply", "cancelled", "cleanup-failure",
            "duplicate-comments", "invalid-paper", "signed-out-paper", "broken-image",
            "upload-poster", "upload-comment", "cancel-before-poster", "cancel-before-comment",
            "create-anonymous-poster", "create-anonymous-paper", "edit-anonymous-poster",
            "edit-anonymous-paper",
            "create-public-poster", "create-public-paper", "edit-public-poster",
            "edit-public-paper",
            "create-title", "create-intro", "create-tags", "create-claim", "edit-title",
            "edit-intro", "edit-tags", "edit-claim",
            "comment-like-noop", "comment-like-restore", "image-download",
            "wrong-rating", "readback-rating", "anonymous-reply", "wrong-reply-user",
            "wrong-reply-object", "wrong-directed-user", "wrong-directed-object",
        ])
    func communityWritesClean(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        let task = Task { try await world.smoke.run(marker: "fixture", expectedAccount: 1) }
        world.cancel = { task.cancel() }
        let result = await task.result
        if stage == "success" {
            let evidence = try result.get()
            #expect(evidence.filter { $0.hasPrefix("服务端确认删除 comment") }.count == 9)
            Attachment.record(
                try JSONEncoder().encode(evidence), named: "community-write-contract.json")
        } else {
            if case .success = result { Issue.record("故障注入应保留验收失败结果") }
        }
        if stage == "invalid-paper", case .failure(let error) = result {
            #expect(error.localizedDescription.contains("创建 paper：参数错误awa"))
        }
        if stage == "cleanup-failure" {
            #expect(world.pending != nil)
            let current = world.account
            world.account = 2
            await #expect(throws: (any Error).self) {
                try await world.smoke.run(marker: "fixture", cleanupOnly: true)
            }
            #expect(world.pending != nil)
            world.account = current
            _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
        #expect(world.contents["course1"]?.liked == true)
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failedSubmissionJournalPreservesObjects(comment: Bool) async throws {
        let world = CommunityWorld(stage: "success")
        var injected = false
        let smoke = CommunityWriteSmoke(
            operations: world.operations, load: { world.pending },
            save: { data in
                if let data {
                    let journal = try JSONDecoder().decode(
                        CommunityWriteSmoke.Journal.self, from: data)
                    let recordsSubmission =
                        comment ? !journal.commentAttempts.isEmpty : !journal.attempts.isEmpty
                    if recordsSubmission && !injected {
                        injected = true
                        throw CocoaError(.fileWriteNoPermission)
                    }
                }
                world.pending = data
            })
        await #expect(throws: (any Error).self) {
            try await smoke.run(marker: "fixture", expectedAccount: 1)
        }
        #expect(injected && world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            "late-poster", "hidden-poster", "late-paper", "hidden-paper", "late-comment",
            "hidden-comment", "late-reply", "hidden-reply", "late-directed", "hidden-directed",
        ])
    func recoveryRetainsUnconfirmedWritesVisible(stage: String) async throws {
        let world = CommunityWorld(stage: stage)
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", expectedAccount: 1)
        }
        let pending = try JSONDecoder().decode(
            CommunityWriteSmoke.Journal.self, from: #require(world.pending))
        #expect(!pending.attempts.isEmpty || !pending.commentAttempts.isEmpty)
        await #expect(throws: (any Error).self) {
            try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        }
        #expect(world.pending != nil)
        world.contents.merge(world.delayedContents, uniquingKeysWith: { _, delayed in delayed })
        world.rows.merge(
            world.delayedRows, uniquingKeysWith: { existing, delayed in existing + delayed })
        world.creationVisible = true
        _ = try await world.smoke.run(marker: "fixture", cleanupOnly: true)
        #expect(world.pending == nil)
        #expect(Set(world.contents.keys) == ["poster77", "course1"])
        #expect(world.rows.values.allSatisfy { $0.isEmpty })
    }

    @Test(
        "Transcript orchestration records authentication, cancellation and SMS continuation",
        .timeLimit(.minutes(1)),
        arguments: [
            "blocked", "nativeBlocked", "invalid", "cancelled", "smsSuccess", "smsFailure",
            "sampleGap",
        ])
    func transcriptOrchestration(stage: String) async throws {
        let image = try #require(
            UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image {
                $0.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }.pngData())
        let scores = Scores(stage: stage, image: image)
        var stored: ReleaseNetworkSmokeReport?
        let dependencies = ReleaseNetworkSmokeDependencies(
            requiresRequestEvidence: false, checkLogin: { "fixture" },
            writeReport: { stored = $0 },
            clearRawCourseResponse: {},
            writeRawCourseResponse: { _, _ in Issue.record("成绩单流程使用独立探针") },
            makeScores: { scores })
        let handler: SchoolSMSCodeHandler = { _ in
            if stage == "cancelled" { throw CancellationError() }
            return "123456"
        }
        let report = await ReleaseNetworkSmokeRunner(dependencies: dependencies).run(
            scope: .transcript, runID: "transcript",
            schoolSMSCodeHandler: ["cancelled", "smsSuccess", "smsFailure"].contains(stage)
                ? handler : nil)
        #expect(report.executedProbes == NetworkSmokeScope.transcript.requiredProbes)
        #expect(report.passed == ["smsSuccess", "sampleGap"].contains(stage))
        #expect(
            report.coverageComplete
                == (["blocked", "nativeBlocked", "invalid", "smsSuccess"].contains(stage)))
        #expect(
            report.verifiedSMSProbes.map(\.purpose)
                == (stage == "smsSuccess" ? ["jwb_cjd"] : []))
        #expect(
            report.authenticationBlockers.count
                == (["blocked", "nativeBlocked"].contains(stage) ? 1 : 0))
        #expect(scores.submissions == (["smsSuccess", "smsFailure"].contains(stage) ? 1 : 0))
        #expect(stored?.passed == report.passed)
        if stage == "sampleGap" {
            #expect(
                report.failures.isEmpty
                    && report.coverageGaps.contains { $0.hasPrefix("score.transcript（") })
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], ["valid", "empty", "error"])
    func communityWriteProbesRequireSuccessfulLogin(cleanup: Bool, login: String) async {
        var calls: [Bool] = []
        let dependencies = ReleaseNetworkSmokeDependencies(
            requiresRequestEvidence: false,
            checkLogin: {
                if login == "error" { throw URLError(.notConnectedToInternet) }
                return login == "valid" ? "fixture" : nil
            }, writeReport: { _ in },
            communityWriteProbe: { _, cleanupOnly, _, _, _, _, _ in
                calls.append(cleanupOnly)
                return ["服务端清理确认完成"]
            })
        let report = await ReleaseNetworkSmokeRunner(dependencies: dependencies).run(
            scope: cleanup ? .communityCleanup : .communityWrites, runID: "fixture")
        let executes = cleanup || login == "valid"
        #expect(calls == (executes ? [cleanup] : []))
        #expect(
            report.executedProbes.contains(NetworkSmokeProbe.communityWrites.rawValue)
                == executes)
        #expect(
            report.failures.contains { $0.hasPrefix("[community.login]") } == (login != "valid")
        )
    }

    @Test(
        "Cleanup, authentication and report failures retain failed evidence",
        .timeLimit(.minutes(1)), arguments: ["cleanup", "signedOut", "login", "report"])
    func failureEvidence(stage: String) async {
        var loginCalls = 0
        var reportCalls = 0
        var stored: ReleaseNetworkSmokeReport?
        let dependencies = ReleaseNetworkSmokeDependencies(
            requiresRequestEvidence: false,
            checkLogin: {
                loginCalls += 1
                if stage == "login" { throw URLError(.notConnectedToInternet) }
                return nil
            },
            writeReport: { report in
                reportCalls += 1
                if stage == "report" { throw CocoaError(.fileWriteNoPermission) }
                stored = report
            },
            clearRawCourseResponse: {
                if stage == "cleanup" { throw CocoaError(.fileWriteNoPermission) }
            }, writeRawCourseResponse: { _, _ in Issue.record("认证失败应在学校采样之前结束") }
        )
        let runner = ReleaseNetworkSmokeRunner(dependencies: dependencies)
        let report = await runner.run(
            scope: .all, runID: "fixture", capture: .rawCourseResponse)
        #expect(!report.passed)
        #expect(!report.coverageComplete)
        #expect(report.runID == "fixture")
        #expect(report.requiredProbes == NetworkSmokeScope.all.requiredProbes)
        #expect(reportCalls == 1)
        #expect(loginCalls == (stage == "cleanup" ? 0 : 1))
        #expect(
            report.failures.contains {
                $0.hasPrefix(stage == "cleanup" ? "[原始课表采样清理]" : "[community.login]")
            })
        #expect(
            report.failures.contains { $0.hasPrefix("网络 Smoke 报告写入失败：") } == (stage == "report")
        )
        #expect(stored?.runID == (stage == "report" ? nil : "fixture"))
        let next = await runner.run(scope: .bit101, runID: "next")
        #expect(next.runID == "next" && !next.passed)
        #expect(
            next.failures.contains {
                $0.hasPrefix(stage == "cleanup" ? "[原始课表采样清理]" : "[community.login]")
            })
        #expect(next.requiredProbes == NetworkSmokeScope.bit101.requiredProbes)
    }
}
#endif
