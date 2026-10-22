import CommunityCore
import CommunityTransport
import Foundation
import Testing
@testable import PaperFeature

@MainActor
struct PaperDetailRequestTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func foregroundDetailsPassQueuedPreviewsAndPromoteSharedRequests(upgrade: Bool) async throws {
        let store = PaperDetailRequestStore()
        let (events, entered) = AsyncStream<Int>.makeStream()
        defer { entered.finish() }
        var pending: [Int: CheckedContinuation<PaperDetail, any Error>] = [:]
        func load(_ id: Int) async throws -> PaperDetail {
            try await withCheckedThrowingContinuation { pending[id] = $0; entered.yield(id) }
        }
        var previews = (1...4).map { id in
            Task { try await store.preview(id: id, credentials: credentials) { try await load(id) } }
        }
        var starts = events.makeAsyncIterator()
        for _ in 1...4 { _ = await starts.next() }
        let (queuedEvents, queuedEntered) = AsyncStream<Void>.makeStream()
        defer { queuedEntered.finish() }
        for id in 5...6 {
            previews.append(Task {
                queuedEntered.yield(())
                return try await store.preview(id: id, credentials: credentials) { try await load(id) }
            })
        }
        var queued = queuedEvents.makeAsyncIterator()
        _ = await queued.next(); _ = await queued.next()
        let foregroundID = upgrade ? 6 : 7
        let detail = Task {
            queuedEntered.yield(())
            return try await store.detail(id: foregroundID, credentials: credentials) { try await load(foregroundID) }
        }
        _ = await queued.next()
        pending.removeValue(forKey: 1)?.resume(returning: Self.detail(1))
        #expect(await starts.next() == foregroundID)
        for id in [2, 3, 4, foregroundID] { pending.removeValue(forKey: id)?.resume(returning: Self.detail(id)) }
        for _ in 0..<(upgrade ? 1 : 2) {
            let id = try #require(await starts.next())
            pending.removeValue(forKey: id)?.resume(returning: Self.detail(id))
        }
        for preview in previews { _ = try await preview.value }
        #expect(try await detail.value.id == foregroundID)
    }

    @Test(.timeLimit(.minutes(1))) func previewOwnershipSurvivesRenewalAndTracksSignedInState() async throws {
        let store = PaperDetailRequestStore()
        var loads = 0
        func load() async throws -> PaperDetail { loads += 1; return Self.detail(1) }
        _ = try await store.preview(id: 1, credentials: credentials, load: load)
        let renewed = CommunityCredentials(identity: credentials.identity, cookie: "renewed")
        _ = try await store.detail(id: 1, credentials: renewed, load: load)
        #expect(loads == 1)
        _ = try await store.preview(id: 1, credentials: renewed, load: load)
        let guest = CommunityCredentials(identity: credentials.identity, cookie: "")
        _ = try await store.detail(id: 1, credentials: guest, load: load)
        #expect(loads == 3)
    }

    private let credentials = CommunityCredentials(identity: .init(accountIdentifier: "paper-preview"), cookie: "fixture")

    private static func detail(_ id: Int, title: String = "文章") -> PaperDetail {
        PaperDetail(id: id, title: title, intro: "", content: "正文", createTime: "", updateTime: "",
            updateUser: .placeholder(id: 1, nickname: "作者"), anonymous: false, likeNum: 0, commentNum: 0,
            publicEdit: false, like: false, own: true)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func previewCacheUsesTheBodyDisplayBudget(oversized: Bool) async throws {
        let store = PaperDetailRequestStore()
        let body = String(repeating: "x", count: PaperContentResourceLimits.maximumBodyBytes - 12 + (oversized ? 1 : 0))
        let author = CommunityUser(id: 1, createTime: "", nickname: "作者", avatar: .init(mid: "", url: "", lowUrl: ""),
            motto: "", identity: .init(id: 0, color: "", text: "", createTime: "", updateTime: "", deleteTime: nil))
        let value = PaperDetail(id: 1, title: "文章", intro: "", content: body, createTime: "", updateTime: "",
            updateUser: author, anonymous: false, likeNum: 0, commentNum: 0,
            publicEdit: false, like: false, own: true)
        var loads = 0
        func load() async throws -> PaperDetail { loads += 1; return value }
        #expect(try await store.preview(id: 1, credentials: credentials, load: load).authorName == "作者")
        #expect(try await store.detail(id: 1, credentials: credentials, load: load).content == body)
        #expect(loads == (oversized ? 2 : 1))
    }

    @Test(.timeLimit(.minutes(1))) func previewRequestsShareFourSlotsAndQueuedCancellation() async throws {
        let store = PaperDetailRequestStore()
        let (events, entered) = AsyncStream<Int>.makeStream()
        defer { entered.finish() }
        var completions: [Int: CheckedContinuation<PaperDetail, any Error>] = [:]
        var active = 0
        var peak = 0
        func load(_ id: Int) async throws -> PaperDetail {
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            return try await withCheckedThrowingContinuation {
                completions[id] = $0
                entered.yield(id)
            }
        }
        var tasks = (1...4).map { id in Task { try await store.preview(id: id, credentials: credentials) { try await load(id) } } }
        var starts = events.makeAsyncIterator()
        for _ in 0..<4 { _ = await starts.next() }
        let (queuedEvents, queuedEntered) = AsyncStream<Int>.makeStream()
        defer { queuedEntered.finish() }
        let fifth = Task { queuedEntered.yield(5); return try await store.preview(id: 5, credentials: credentials) { try await load(5) } }
        let cancelled = Task { queuedEntered.yield(6); return try await store.preview(id: 6, credentials: credentials) { try await load(6) } }
        var queued = queuedEvents.makeAsyncIterator()
        _ = await queued.next(); _ = await queued.next()
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("排队消费者需要沿取消结束") }
        catch is CancellationError { #expect(cancelled.isCancelled) }
        #expect(completions.count == 4 && peak == 4)
        completions.removeValue(forKey: 1)?.resume(returning: Self.detail(1))
        #expect(await starts.next() == 5)
        for id in 2...5 { completions.removeValue(forKey: id)?.resume(returning: Self.detail(id)) }
        tasks.append(fifth)
        for task in tasks { _ = try await task.value }
        #expect(active == 0 && peak == 4 && completions.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func coalescedConsumersKeepIndependentCancellation() async throws {
        let store = PaperDetailRequestStore()
        let (events, entered) = AsyncStream<Void>.makeStream()
        defer { entered.finish() }
        var pending: CheckedContinuation<PaperDetail, any Error>?
        var loads = 0
        func load() async throws -> PaperDetail {
            loads += 1
            return try await withCheckedThrowingContinuation { pending = $0; entered.yield(()) }
        }
        let first = Task { try await store.preview(id: 1, credentials: credentials, load: load) }
        var starts = events.makeAsyncIterator()
        _ = await starts.next()
        let (joined, consumerEntered) = AsyncStream<Void>.makeStream()
        defer { consumerEntered.finish() }
        let second = Task { consumerEntered.yield(()); return try await store.preview(id: 1, credentials: credentials, load: load) }
        var consumers = joined.makeAsyncIterator()
        _ = await consumers.next()
        first.cancel()
        do { _ = try await first.value; Issue.record("已取消消费者需要保持取消结果") }
        catch is CancellationError { #expect(first.isCancelled) }
        pending?.resume(returning: Self.detail(1))
        #expect(try await second.value.authorName == "作者")
        #expect(loads == 1)
    }

    @Test(.timeLimit(.minutes(1))) func previewHandoffIsConsumedAndRefreshStaysLive() async throws {
        let store = PaperDetailRequestStore()
        var loads = 0
        func load() async throws -> PaperDetail { loads += 1; return Self.detail(1, title: "版本\(loads)") }
        _ = try await store.preview(id: 1, credentials: credentials, load: load)
        #expect(try await store.detail(id: 1, credentials: credentials, load: load).title == "版本1")
        #expect(try await store.detail(id: 1, credentials: credentials, load: load).title == "版本2")
        _ = try await store.preview(id: 1, credentials: credentials, load: load)
        store.invalidate()
        #expect(try await store.detail(id: 1, credentials: credentials, load: load).title == "版本4")
        let other = CommunityCredentials(identity: .init(accountIdentifier: "other"), cookie: "fixture")
        _ = try await store.preview(id: 1, credentials: credentials, load: load)
        #expect(try await store.detail(id: 1, credentials: other, load: load).title == "版本6")
    }

    @Test(.timeLimit(.minutes(1))) func refreshEpochKeepsFreshWorkSeparateFromAnOlderPreview() async throws {
        let store = PaperDetailRequestStore()
        let (events, entered) = AsyncStream<Void>.makeStream()
        defer { entered.finish() }
        var oldCompletion: CheckedContinuation<PaperDetail, any Error>?
        let old = Task { try await store.preview(id: 1, credentials: credentials) {
            try await withCheckedThrowingContinuation { oldCompletion = $0; entered.yield(()) }
        } }
        var starts = events.makeAsyncIterator()
        _ = await starts.next()
        store.invalidate()
        _ = try await store.preview(id: 1, credentials: credentials) { Self.detail(1, title: "新版本") }
        oldCompletion?.resume(returning: Self.detail(1, title: "旧版本"))
        _ = try await old.value
        let opened = try await store.detail(id: 1, credentials: credentials) {
            Issue.record("当前预览需要保留用于详情复用")
            return Self.detail(1)
        }
        #expect(opened.title == "新版本")
    }

    @Test(.timeLimit(.minutes(1))) func previewCacheRetainsFourResponses() async throws {
        let store = PaperDetailRequestStore()
        var loads = 0
        for id in 1...5 {
            _ = try await store.preview(id: id, credentials: credentials) { loads += 1; return Self.detail(id) }
        }
        _ = try await store.detail(id: 1, credentials: credentials) { loads += 1; return Self.detail(1) }
        #expect(loads == 6)
        _ = try await store.detail(id: 5, credentials: credentials) { loads += 1; return Self.detail(5) }
        #expect(loads == 6)
    }
}
