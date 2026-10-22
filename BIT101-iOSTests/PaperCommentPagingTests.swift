import CommunityCore
import CommunityTransport
import Foundation
@testable import PaperFeature
import Testing
import TransportCore

@MainActor
struct PaperCommentPagingTests {
    private static func revalidationPaper(_ id: Int, title: String) -> PaperDetail {
        PaperDetail(id: id, title: title, intro: "", content: title, createTime: "", updateTime: "",
            updateUser: .placeholder(id: 1, nickname: "作者"), anonymous: false, likeNum: 0, commentNum: 0,
            publicEdit: false, like: false, own: true)
    }

    private final class RevalidatingService: PaperDetailServicing {
        var pending: CheckedContinuation<PaperDetail, any Error>?
        var likeRequests = 0
        func cachedPaper(id: Int) async -> PaperDetail? { PaperCommentPagingTests.revalidationPaper(id, title: "缓存正文") }
        func fetchPaper(id: Int) async throws -> PaperDetail { try await withCheckedThrowingContinuation { pending = $0 } }
        func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment] { [] }
        func likePaper(id: Int) async throws -> CommunityLikeResult { likeRequests += 1; throw URLError(.unsupportedURL) }
        func sendLike(objectID: String) async throws -> CommunityLikeResult { throw URLError(.unsupportedURL) }
        func createComment(objectID: String, text: String, replyObjectID: String?, replyUID: Int?, anonymous: Bool) async throws -> CommunityComment { throw URLError(.unsupportedURL) }
        func updatePaper(id: Int, title: String, intro: String, content: String, anonymous: Bool, publicEdit: Bool, lastUpdatedAt: String) async throws { throw URLError(.unsupportedURL) }
        func deletePaper(id: Int) async throws { throw URLError(.unsupportedURL) }
    }

    @Test(.timeLimit(.minutes(1)))
    func publicArticleContentKeepsLikesPendingUntilAnAuthenticatedRead() async throws {
        let service = RevalidatingService()
        let model = PaperDetailViewModel(initialPaper: .init(id: 1, title: "文章", intro: "", likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        let loading = Task { await model.bootstrapIfNeeded() }
        defer { loading.cancel(); service.pending?.resume(throwing: CancellationError()); service.pending = nil }
        try await waitForTestEvent { service.pending != nil }
        var detail = Self.revalidationPaper(1, title: "公开正文")
        detail.isViewerAuthenticated = false
        service.pending?.resume(returning: detail); service.pending = nil
        await loading.value
        #expect(model.paper?.content == "公开正文" && !model.hasKnownLikeState)
        #expect(model.likeStateMessage == "社区认证后可点赞")
        await model.likePaper()
        #expect(service.likeRequests == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cachedArticleAppearsDuringRevalidationAndSurvivesAFailedRead(fails: Bool) async throws {
        let service = RevalidatingService()
        let model = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "列表标题", intro: "", likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        let loading = Task { await model.bootstrapIfNeeded() }
        defer { loading.cancel(); service.pending?.resume(throwing: CancellationError()); service.pending = nil }
        try await waitForTestEvent { service.pending != nil }
        #expect(model.paper?.title == "缓存正文")
        #expect(model.paper?.content == "缓存正文")
        if fails { service.pending?.resume(throwing: URLError(.notConnectedToInternet)) }
        else { service.pending?.resume(returning: Self.revalidationPaper(1, title: "更新正文")) }
        service.pending = nil
        await loading.value
        #expect(model.paper?.title == (fails ? "缓存正文" : "更新正文"))
        #expect(model.paper?.content == (fails ? "缓存正文" : "更新正文"))
        #expect(model.contentBlocks.isEmpty == false)
        #expect(model.paperStatus == (fails ? .failed(URLError(.notConnectedToInternet).localizedDescription) : .loaded))
    }

    private final class Transport: HTTPTransport {
        var pages: [Int] = []
        var stalls = false
        var pendingDetail: CheckedContinuation<Void, Error>?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            if url.path.hasSuffix("/papers/1") {
                try await withCheckedThrowingContinuation { pendingDetail = $0 }
                throw URLError(.timedOut)
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            if url.path.hasSuffix("/user/check") { return (Data(), response) }
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "page" }?.value.flatMap(Int.init) ?? 0
            pages.append(page)
            let id = stalls || page < 3 ? 1 : 2
            let user = #"{"id":1,"create_time":"","nickname":"用户","avatar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":0,"color":"","text":"","create_time":"","update_time":""}}"#
            let data = Data("""
            [{"id":\(id),"obj":"paper1","images":[],"user":\(user),"anonymous":false,"create_time":"",
              "update_time":"","like":false,"like_num":0,"comment_num":0,"own":false,"rate":0,
              "reply_user":\(user),"reply_obj":"","text":"评论","sub":[]}]
            """.utf8)
            return (data, response)
        }
    }

    @Test(.timeLimit(.minutes(1))) func commentsAppearWhilePaperDetailsArePending() async throws {
        let transport = Transport()
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "paper-paging"), cookie: "fixture-cookie") }, refresh: { _ in })
        let model = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "文章", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: PaperService(session: session))
        let loading = Task { await model.refreshAll() }
        defer { loading.cancel(); transport.pendingDetail?.resume(throwing: CancellationError()); transport.pendingDetail = nil }
        try await waitForTestEvent { transport.pendingDetail != nil && !transport.pages.isEmpty }
        try await waitForTestEvent { model.commentState.status == .loaded }
        #expect(model.commentState.items.map(\.id) == [1])
        transport.pendingDetail?.resume()
        transport.pendingDetail = nil
        await loading.value
        #expect(model.commentState.status == .loaded)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func repeatedCommentsAdvanceOrRetainTheRetryPosition(stalled: Bool) async throws {
        let transport = Transport()
        transport.stalls = stalled
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"),
            credentials: { .init(identity: .init(accountIdentifier: "paper-paging"), cookie: "fixture-cookie") }, refresh: { _ in })
        let model = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "文章", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: PaperService(session: session))
        await model.refreshComments()
        await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
        #expect(model.commentState.items.map(\.id) == (stalled ? [1] : [1, 2]))
        #expect(model.commentState.nextPage == 4 && !model.commentState.isLoadingMore)
        #expect((model.alert != nil) == stalled)
        #expect(transport.pages == (stalled ? [0, 1, 2, 3, 4] : [0, 1, 2, 3]))
        if stalled {
            transport.stalls = false
            await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
            #expect(model.commentState.items.map(\.id) == [1, 2] && transport.pages.last == 4)
        }
    }
}

extension GalleryRecommendationPrefetchTests {
    @Test @MainActor func articleListItemsShareTheWholeBodyRenderBudget() throws {
        func raw(_ counts: [Int]) throws -> String {
            let blocks = counts.map { ["type": "list", "data": ["items": Array(repeating: "x", count: $0)]] as [String: Any] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": blocks]), as: UTF8.self)
        }
        for counts in [[3_000], [128, 129], Array(repeating: 32, count: 9)] {
            let content = try raw(counts)
            #expect(content.utf8.count < PaperContentResourceLimits.maximumBodyBytes)
            let result = PaperContentRenderer.blocks(from: content)
            #expect(result.count == 1)
            if case .requiresOriginal = result[0] {} else { Issue.record("渲染节点超额需要原文入口") }
        }
        let result = PaperContentRenderer.blocks(from: try raw([128, 128]))
        #expect(result.count == 2)
        for block in result {
            if case let .list(_, items, _) = block { #expect(items.count == 128 && items.allSatisfy { String($0.characters) == "x" }) }
            else { Issue.record("预算内的短列表需要完整展示") }
        }
    }

    @Test func composerTracksUnsavedChangesAgainstInitialValues() {
        for paper in [nil, editingPaper("正文")] {
            let model = PaperComposerViewModel(editingPaper: paper, initialContent: "正文")
            #expect(!model.hasUnsavedChanges)
            for field in [\PaperComposerViewModel.title, \.intro, \.content] {
                let original = model[keyPath: field]
                model[keyPath: field] += "修改"
                #expect(model.hasUnsavedChanges)
                model[keyPath: field] = original
                #expect(!model.hasUnsavedChanges)
            }
            model.anonymous.toggle()
            #expect(model.hasUnsavedChanges)
            model.anonymous.toggle()
            #expect(!model.hasUnsavedChanges)
        }
    }

    private final class PaperSavingService: PaperComposerServicing {
        var bodies: [String] = []
        var versions: [String] = []
        var pending: CheckedContinuation<Void, Never>?
        var suspend = false
        var unknownResult = false
        private func save(_ content: String) async {
            bodies.append(content)
            if suspend { await withCheckedContinuation { pending = $0 } }
        }
        func createPaper(title: String, intro: String, content: String, anonymous: Bool, publicEdit: Bool) async throws -> Int {
            await save(content)
            if unknownResult { throw CommunityCreateOutcomeUnknown(underlying: URLError(.networkConnectionLost)) }
            return 42
        }
        func updatePaper(id: Int, title: String, intro: String, content: String, anonymous: Bool, publicEdit: Bool, lastUpdatedAt: String) async throws {
            versions.append(lastUpdatedAt)
            await save(content)
        }
    }

    private func editingPaper(_ content: String) -> PaperDetail {
        PaperDetail(id: 1, title: "标题", intro: "简介", content: content, createTime: "", updateTime: "2026-10-01T08:00:00Z",
            updateUser: .placeholder(id: 7, nickname: "用户"), anonymous: false, likeNum: 0, commentNum: 0,
            publicEdit: true, like: false, own: true)
    }

    @Test(.timeLimit(.minutes(1))) func uncertainPaperCreationStopsAnotherSubmission() async {
        let service = PaperSavingService()
        service.unknownResult = true
        let model = PaperComposerViewModel(editingPaper: nil, initialContent: "正文")
        model.title = "标题"; model.intro = "简介"
        #expect(await model.submit(service: service) == false)
        service.unknownResult = false
        #expect(await model.submit(service: service) == false)
        #expect(service.bodies.count == 1 && model.alert?.title == "发布结果待确认" && !model.isSubmitting)
    }

    @Test @MainActor func articleRenderingNormalizesDuplicateEmptyAndMissingBlockIdentities() throws {
        let blocks = ["same", "same", "", "block-0"].map {
            ["id": $0, "type": "paragraph", "data": ["text": "正文"]] as [String: Any]
        } + [["type": "unknown"], ["type": "paragraph", "data": ["text": String(repeating: "x", count: PaperContentResourceLimits.maximumBlockBytes + 1)]]]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": blocks]), as: UTF8.self)
        let first = PaperContentRenderer.blocks(from: raw).map(\.id)
        #expect(first.count == blocks.count && Set(first).count == first.count)
        #expect(PaperContentRenderer.blocks(from: raw).map(\.id) == first)
        #expect(PaperContentRenderer.blocks(from: "正文").map(\.id) == PaperContentRenderer.blocks(from: "正文").map(\.id))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        #"{"blocks":[{"id":"p","type":"paragraph","data":{"text":"<b>重点</b>"}},{"id":"i","type":"image","data":{"file":{"url":"https://example.com/a.png"}}}]}"#,
        #"{"blocks":[{"id":"i","type":"image","data":{"file":{"url":"https://example.com/a.png"}}}]}"#,
        #"{"blocks":[{"type":"header","data":{"text":"标题","level":2}},{"type":"list","data":{"items":["一","二"]}}]}"#,
        #"{"blocks":[{"type":"paragraph","data":{"text":"正文"},"tunes":{"alignment":"center"}}]}"#
    ])
    func metadataEditingPreservesFormattedImageAndExtendedBlocks(raw: String) async {
        let service = PaperSavingService()
        let model = PaperComposerViewModel(editingPaper: editingPaper(raw), initialContent: PaperEditorContentBuilder.plainText(from: raw))
        #expect(model.canEditBody == false)
        model.title = "新标题"
        model.content = "修改正文"
        #expect(await model.submit(service: service))
        #expect(service.bodies == [raw])
        #expect(service.versions == ["2026-10-01T08:00:00Z"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["body", "blocks", "block", "plain"])
    func metadataEditingPreservesResourceLimitedBody(kind: String) async {
        let raw: String
        switch kind {
        case "body":
            raw = PaperEditorContentBuilder.editorJSON(from: String(repeating: "x",
                count: PaperContentResourceLimits.maximumBodyBytes + 1))
        case "blocks":
            raw = PaperEditorContentBuilder.editorJSON(from: Array(repeating: "正文",
                count: PaperContentResourceLimits.maximumBlocks + 1).joined(separator: "\n\n"))
        case "block":
            raw = PaperEditorContentBuilder.editorJSON(from: "保留段落\n\n" + String(repeating: "x",
                count: PaperContentResourceLimits.maximumBlockBytes + 1))
        default:
            raw = String(repeating: "x", count: PaperContentResourceLimits.maximumBlockBytes + 1)
        }
        let service = PaperSavingService()
        let model = PaperComposerViewModel(editingPaper: editingPaper(raw),
            initialContent: PaperEditorContentBuilder.plainText(from: raw))
        #expect(model.canEditBody == false)
        model.title = "新标题"
        model.content = "修改剩余正文"
        #expect(await model.submit(service: service))
        #expect(service.bodies == [raw])
        #expect(service.versions == ["2026-10-01T08:00:00Z"])
    }

    @Test(.timeLimit(.minutes(1))) func plainBodyEditsRoundTripEscapedTextAndKeepUntouchedSource() async {
        let raw = PaperEditorContentBuilder.editorJSON(from: "正文 <内容>\n第二行")
        let service = PaperSavingService()
        let model = PaperComposerViewModel(editingPaper: editingPaper(raw), initialContent: PaperEditorContentBuilder.plainText(from: raw))
        #expect(model.canEditBody)
        #expect(await model.submit(service: service))
        #expect(service.bodies == [raw])
        model.content = "新正文 <内容>\n第二行\n\n下一段"
        #expect(await model.submit(service: service))
        #expect(PaperEditorContentBuilder.plainText(from: service.bodies[1]) == model.content)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func rewrittenPaperBodiesStayWithinTheRendererBudget(editing: Bool) async {
        let bodies = [String(repeating: "x", count: PaperContentResourceLimits.maximumBlockBytes + 1),
            Array(repeating: "正文", count: PaperContentResourceLimits.maximumBlocks + 1).joined(separator: "\n\n"),
            String(repeating: "&", count: PaperContentResourceLimits.maximumBlockBytes / 2)]
        for body in bodies {
            let service = PaperSavingService()
            let model = PaperComposerViewModel(editingPaper: editing ? editingPaper("正文") : nil, initialContent: editing ? "正文" : "")
            model.title = "标题"; model.intro = "简介"; model.content = body
            #expect(await model.submit(service: service) == false)
            #expect(service.bodies.isEmpty && model.alert != nil && !model.isSubmitting)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func paperSubmissionCancellationEndsItsLifecycleAndAllowsAReopenedComposer(editing: Bool) async throws {
        let service = PaperSavingService()
        service.suspend = true
        let model = PaperComposerViewModel(editingPaper: editing ? editingPaper("正文") : nil, initialContent: "正文")
        model.title = "标题"; model.intro = "简介"
        let task = Task { await model.submit(service: service) }
        try await waitForTestEvent { !(service.pending == nil) }
        #expect(model.isSubmitting)
        #expect(await model.submit(service: service) == false)
        task.cancel()
        service.pending?.resume()
        #expect(await task.value == false)
        #expect(model.isSubmitting == false && model.alert == nil)
        #expect(service.bodies.count == 1)
        service.suspend = false
        let reopened = PaperComposerViewModel(editingPaper: nil, initialContent: "正文")
        reopened.title = "标题"; reopened.intro = "简介"
        #expect(await reopened.submit(service: service))
        #expect(service.bodies.count == 2)
    }

}

@MainActor
struct PaperContentRecoveryTests {
    @Test func restoredDraftKeepsItsOriginalEditVersion() {
        let paper = PaperDetail(id: 1, title: "当前标题", intro: "", content: "正文", createTime: "", updateTime: "current-version",
            updateUser: .placeholder(id: 1, nickname: "作者"), anonymous: false, likeNum: 0, commentNum: 0,
            publicEdit: false, like: false, own: true)
        let model = PaperComposerViewModel(editingPaper: paper, initialContent: "正文")
        let draft = PaperComposerDraftSnapshot(paperID: 1, baselineUpdatedAt: "saved-version", title: "草稿标题",
            intro: "草稿简介", content: "草稿正文", anonymous: true)
        model.restoreDraft(draft)
        #expect(model.draftSnapshot == draft && model.hasUnsavedChanges)
    }

    @Test(arguments: [#"{"blocks":null}"#, #"{"blocks":[null]}"#, #"{"blocks":"text"}"#, #"{"blocks":["#, "[1]"])
    func malformedEditorDocumentsKeepTheOriginalReadingPath(raw: String) {
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(blocks.count == 1)
        if case .requiresOriginal = blocks[0] {} else { Issue.record("结构异常需要完整原文入口。") }
    }

    @Test func malformedBlocksKeepSurroundingReadableParagraphs() {
        let raw = #"{"blocks":[{"type":"paragraph","data":{"text":"前文"}},null,{"type":"paragraph","data":{"text":"后文"}}]}"#
        let blocks = PaperContentRenderer.blocks(from: raw)
        #expect(PaperEditorContentBuilder.plainText(from: blocks) == "前文\n\n后文")
        #expect(blocks.count == 3)
        if case .requiresOriginal = blocks[1] {} else { Issue.record("损坏段落需要原文恢复。") }
        #expect(PaperEditorContentBuilder.plainText(from: "普通正文") == "普通正文")
        #expect(PaperEditorContentBuilder.plainText(from: "[公告] 原样正文") == "[公告] 原样正文")
    }

    @Test(.timeLimit(.minutes(1)))
    func longBodyPreparationServicesPendingMainActorWork() async throws {
        let sourceBlocks = Array(repeating: ["type": "paragraph", "data": ["text": "<b>正文</b> <a href=\"https://example.com\">链接</a>"]] as [String: Any], count: 128)
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["blocks": sourceBlocks]), as: UTF8.self)
        var serviced = false
        let interaction = Task { serviced = true }
        let blocks = try await PaperContentRenderer.blocksForDisplay(from: raw)
        #expect(serviced && blocks.count == 128)
        await interaction.value
        let cancelled = Task { try await PaperContentRenderer.blocksForDisplay(from: raw) }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("取消后应结束正文准备。") }
        catch is CancellationError { #expect(cancelled.isCancelled) }
    }
}
