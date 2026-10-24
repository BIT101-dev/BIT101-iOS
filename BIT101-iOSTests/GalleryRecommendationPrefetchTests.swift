import ClientCore
import CommunityCore
import CommunityTransport
import Foundation
@testable import GalleryFeature
@testable import PaperFeature
import Testing
import TransportCore
@testable import BIT101_iOS

@Suite("Gallery recommendation prefetch")
@MainActor
struct GalleryRecommendationPrefetchTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func confirmedCommentsAppearThroughTheFollowingRefreshFailure(paper: Bool) async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        let failure = URLError(.notConnectedToInternet)
        service.detailError = failure
        var commentRefreshFailed = false
        service.commentHandler = { _ in commentRefreshFailed = true; throw failure }
        let user = CommunityUser.placeholder(id: 7, nickname: "作者")
        service.commentCreation = {
            CommunityComment(id: 2, obj: paper ? "paper1" : "poster1", images: [], user: user,
                anonymous: false, createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0,
                own: true, rate: 0, replyUser: user, replyObj: "", text: "评论", sub: [])
        }
        let gallery = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "标题", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        let submitted = paper
            ? await article.submitComment(text: "评论", anonymous: false, target: .paper(paperID: 1))
            : await gallery.submitComment(text: "评论", anonymous: false, target: .poster(posterID: 1))
        #expect(submitted && (paper ? article.commentState.items : gallery.commentState.items).map(\.id) == [2])
        try await waitForTestEvent {
            commentRefreshFailed && (paper ? article.commentState.status : gallery.commentState.status) == .loaded
        }
        #expect((paper ? article.alert : gallery.alert) != nil)
        #expect((paper ? article.commentState.items : gallery.commentState.items).map(\.id) == [2])
    }

    @Test(.timeLimit(.minutes(1))) func completedCommentsAppearWhilePosterDetailsArePending() async throws {
        let service = DetailSortingService(poster: try makePoster(id: 1))
        let model = GalleryPosterDetailViewModel(initialPoster: service.poster.asPoster, service: service)
        let loading = Task { await model.refreshAll() }
        defer { loading.cancel(); service.finish() }
        try await service.waitForDetail()
        try await waitForTestEvent { model.commentState.status == .loaded }
        #expect(service.completedRequests.contains("comments") && model.posterStatus == .loading)
        service.finish()
        await loading.value
    }

    @Test(.timeLimit(.minutes(1))) func contentPreferenceChangesClearLoadedFeedsAndRebuildTheSelectedPage() async throws {
        let service = FeedServiceStub(batches: [0: .init(items: [try makePoster(id: 1)], nextSourcePage: 1, canLoadMore: false)])
        let model = GalleryViewModel(service: service)
        await model.refreshSelectedFeed()
        #expect(model.state(for: .recommend).posters.count == 1)
        model.selectedFeed = .newest
        model.contentPreferencesDidChange()
        #expect(model.state(for: .recommend).posters.isEmpty && model.searchState.posters.isEmpty)
        await model.enqueueRefresh(for: .newest).value
        model.selectedFeed = .recommend
        await model.enqueueRefresh(for: .recommend).value
        #expect(await service.requestedPages().count == 2)
    }
    private final class DetailSortingService: GalleryPosterDetailServicing, PaperDetailServicing {
        func setSubscription(objectID: String, level: GallerySubscriptionLevel) async throws { poster = poster.updatingSubscription(level) }
        var poster: GalleryPosterDetail
        var paperLiked = false
        var pausesDetail = true
        var detailError: (any Error)?
        var likeError: (any Error)?
        var likeCalls = 0
        var suspendRequests = false
        var suspendedRequestKeys: Set<String> = []
        var completedRequests: Set<String> = []
        var commentHandler: (@MainActor (Int?) async throws -> [CommunityComment])?
        var commentCreation: (@MainActor () async throws -> CommunityComment)?
        var ownsPaper = false
        var paperDeletion: (@MainActor () async throws -> Void)?
        var paperDeleteCalls = 0
        var detailCalls = 0
        var enteredRequests: Set<String> = []
        var cancelledRequests: Set<String> = []
        private var response: CheckedContinuation<Void, Never>?
        init(poster: CommunityPoster) { self.poster = GalleryPosterDetail(poster: poster) }
        func pause() async {
            await withCheckedContinuation {
                response = $0
            }
        }
        func waitForDetail() async throws {
            try await waitForTestEvent { response != nil }
        }
        func finish() { response?.resume(); response = nil }
        private func pauseIfRequested(_ key: String) async throws {
            guard suspendRequests || suspendedRequestKeys.contains(key) else { return }
            enteredRequests.insert(key)
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelledRequests.insert(key); throw error }
        }
        private func pauseDetail() async throws {
            if let detailError { throw detailError }
            guard pausesDetail else { return }
            if suspendRequests || suspendedRequestKeys.contains("body") { try await pauseIfRequested("body") }
            else if suspendedRequestKeys.isEmpty { await pause() }
        }
        func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
            detailCalls += 1; try await pauseDetail(); completedRequests.insert("body"); return poster
        }
        func fetchPaper(id: Int) async throws -> PaperDetail {
            detailCalls += 1
            try await pauseDetail()
            completedRequests.insert("body")
            return PaperDetail(id: id, title: "loaded", intro: "", content: "", createTime: "", updateTime: "",
                updateUser: poster.user, anonymous: false, likeNum: 0, commentNum: 0,
                publicEdit: false, like: paperLiked, own: ownsPaper)
        }
        func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment> {
            try await pauseIfRequested("comments")
            let comments = try await commentHandler?(page) ?? []
            completedRequests.insert("comments")
            return .init(items: comments, nextSourcePage: (page ?? 0) + 1, canLoadMore: !comments.isEmpty)
        }
        func fetchComments(paperID: Int, order: CommunityCommentOrder, page: Int?) async throws -> [CommunityComment] {
            try await pauseIfRequested("comments")
            let comments = try await commentHandler?(page) ?? []
            completedRequests.insert("comments"); return comments
        }
        var likeGate: (@MainActor () async -> Void)?
        func like(objectID: String) async throws -> CommunityLikeResult {
            likeCalls += 1
            if let likeError { throw likeError }
            await likeGate?()
            return CommunityLikeResult(like: true, likeNum: 17)
        }
        func likePaper(id: Int) async throws -> CommunityLikeResult { try await like(objectID: "paper\(id)") }
        func sendLike(objectID: String) async throws -> CommunityLikeResult { try await like(objectID: objectID) }
        private func makeComment() async throws -> CommunityComment {
            guard let commentCreation else { throw CancellationError() }
            return try await commentCreation()
        }
        func createComment(objectID: String, text: String, replyObjectID: String?, replyUID: Int?, anonymous: Bool, imageMids: [String]) async throws -> CommunityComment { try await makeComment() }
        func createComment(objectID: String, text: String, replyObjectID: String?, replyUID: Int?, anonymous: Bool) async throws -> CommunityComment { try await makeComment() }
        func deleteComment(id: Int) async throws {}
        func deletePoster(id: Int) async throws {}
        func deletePaper(id: Int) async throws { paperDeleteCalls += 1; try await paperDeletion?() }
        func updatePaper(id: Int, title: String, intro: String, content: String, anonymous: Bool, publicEdit: Bool, lastUpdatedAt: String) async throws {}
    }

    @Test(.timeLimit(.minutes(1)), arguments: [(false, false), (false, true), (true, false), (true, true)], [false, true])
    func uncertainLikesRequireAConfirmedReadBeforeAnotherToggle(scene: (Bool, Bool), readFails: Bool) async throws {
        let (paper, comment) = scene
        let service = DetailSortingService(poster: try makePoster(id: 1))
        service.pausesDetail = false
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        let original = CommunityComment(id: 1, obj: "fixture", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: true,
            rate: 0, replyUser: user, replyObj: "", text: "评论", sub: [])
        service.commentHandler = { _ in [original] }
        let gallery = GalleryPosterDetailViewModel(initialPoster: service.poster.asPoster, service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "标题", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        func refresh() async { if paper { await article.refreshAll() } else { await gallery.refreshAll() } }
        func toggle() async {
            if comment { if paper { await article.toggleCommentLike(original) } else { await gallery.likeComment(original) } }
            else { if paper { await article.likePaper() } else { await gallery.likePoster() } }
        }
        await refresh()
        service.poster = service.poster.updatingLike(true, likeNum: 17); service.paperLiked = true
        service.likeError = CommunityToggleOutcomeUnknown(underlying: URLError(.networkConnectionLost))
        service.commentHandler = { _ in
            if readFails && comment { throw URLError(.timedOut) }
            return [original.updatingLike(true, likeNum: 17)]
        }
        if readFails && !comment { service.detailError = URLError(.timedOut) }
        await toggle()
        #expect(service.likeCalls == 1)
        if readFails {
            await toggle(); #expect(service.likeCalls == 1)
            service.detailError = nil; service.commentHandler = { _ in [original.updatingLike(true, likeNum: 17)] }
            await refresh()
        }
        #expect(comment ? (paper ? article.commentState.items.first?.like : gallery.commentState.items.first?.like) == true : (paper ? article.isPaperLiked : gallery.poster.like))
        service.likeError = nil; await toggle(); #expect(service.likeCalls == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func cancelledCommentSubmissionRetainsTheNewEditorAndAllowsRetry(paper: Bool) async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        let comment = CommunityComment(id: 1, obj: "poster1", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false,
            rate: 0, replyUser: user, replyObj: "", text: "评论", sub: [])
        service.commentCreation = { [weak service] in await service?.pause(); try Task.checkCancellation(); return comment }
        let gallery = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        func submit() async -> Bool {
            if paper { return await article.submitComment(text: "comment", anonymous: false, target: .paper(paperID: 1)) }
            return await gallery.submitComment(text: "comment", anonymous: false, target: .poster(posterID: 1))
        }
        var editor = "first"
        let submission = Task { if await submit() { editor = "" } }
        try await service.waitForDetail()
        submission.cancel()
        editor = "reopened"
        service.finish()
        await submission.value
        #expect(editor == "reopened" && service.detailCalls == 0)
        #expect(paper ? article.alert == nil : gallery.alert == nil)
        #expect(paper ? article.isSubmittingComment == false : gallery.isSubmittingComment == false)
        service.commentCreation = { comment }
        let retry = Task { await submit() }
        try await service.waitForDetail()
        service.finish()
        #expect(await retry.value)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func uncertainCommentStopsAnotherSubmission(paper: Bool) async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        var submissions = 0
        service.commentCreation = {
            submissions += 1
            throw CommunityCreateOutcomeUnknown(underlying: URLError(.networkConnectionLost))
        }
        let gallery = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "标题", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        func submit() async -> Bool {
            if paper { return await article.submitComment(text: "评论", anonymous: false, target: .paper(paperID: 1)) }
            return await gallery.submitComment(text: "评论", anonymous: false, target: .poster(posterID: 1))
        }
        #expect(await submit() == false)
        #expect(await submit() == false)
        #expect(submissions == 1 && service.detailCalls == 0)
        #expect((paper ? article.alert?.title : gallery.alert?.title) == "发送结果待确认")
        #expect((paper ? article.alert?.message : gallery.alert?.message) == CommunityCreateOutcomeUnknown.commentReviewMessage)
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        service.commentCreation = {
            submissions += 1
            return CommunityComment(id: 1, obj: paper ? "paper1" : "poster1", images: [], user: user, anonymous: false,
                createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: true,
                rate: 0, replyUser: user, replyObj: "", text: "新的评论", sub: [])
        }
        defer { service.finish() }
        let refresh = Task { if paper { await article.refreshAll() } else { await gallery.refreshAll() } }
        try await service.waitForDetail(); service.finish(); await refresh.value
        let retry = Task {
            if paper { return await article.submitComment(text: "新的评论", anonymous: false, target: .paper(paperID: 1)) }
            return await gallery.submitComment(text: "新的评论", anonymous: false, target: .poster(posterID: 1))
        }
        try await service.waitForDetail(); service.finish()
        #expect(await retry.value)
        #expect(submissions == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func acceptedCommentKeepsSuccessWhenItsRefreshIsCancelled(paper: Bool) async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        service.commentCreation = {
            CommunityComment(id: 1, obj: "poster1", images: [], user: user, anonymous: false,
                createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: true,
                rate: 0, replyUser: user, replyObj: "", text: "评论", sub: [])
        }
        let gallery = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "标题", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        let submission = Task {
            if paper { return await article.submitComment(text: "评论", anonymous: false, target: .paper(paperID: 1)) }
            return await gallery.submitComment(text: "评论", anonymous: false, target: .poster(posterID: 1))
        }
        try await service.waitForDetail()
        submission.cancel()
        service.finish()
        #expect(await submission.value)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
    func failedCommentRefreshRetiresItsOlderPaginationAndAllowsTheNextPage(paper: Bool, scenario: (Bool, Bool)) async throws {
        let (cancelled, changesOrder) = scenario
        let service = DetailSortingService(poster: try makePoster(id: 1))
        let model = GalleryPosterDetailViewModel(initialPoster: try makePoster(id: 1), service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "", likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        func refresh() async { if paper { await article.refreshComments() } else { await model.refreshComments() } }
        func state() -> CommunityCommentState { paper ? article.commentState : model.commentState }
        func next(_ comment: CommunityComment) async { if paper { await article.loadMoreCommentsIfNeeded(currentComment: comment) } else { await model.loadMoreCommentsIfNeeded(currentComment: comment) } }
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        let comment = CommunityComment(id: 1, obj: "poster1", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false,
            rate: 0, replyUser: user, replyObj: "", text: "评论", sub: [])
        service.commentHandler = { _ in [comment] }
        if paper { await article.setCommentOrder(.like) } else { await model.setCommentOrder(.like) }
        var pending: CheckedContinuation<Void, Never>?
        var pages = 0
        service.commentHandler = { page in
            guard page != nil else { if cancelled { throw CancellationError() }; throw URLError(.timedOut) }
            pages += 1
            if pages == 1 { await withCheckedContinuation { pending = $0 } }
            return []
        }
        let oldPage = Task { await next(comment) }
        try await waitForTestEvent { !(pending == nil) }
        #expect(state().isLoadingMore)
        if changesOrder {
            if paper { await article.setCommentOrder(.newest) } else { await model.setCommentOrder(.newest) }
        } else { await refresh() }
        #expect(state().status == .loaded && state().isLoadingMore == false)
        #expect((paper ? article.commentOrder : model.commentOrder) == .like && state().order == .like)
        #expect(state().nextPage == 1 && state().canLoadMore)
        pending?.resume()
        await oldPage.value
        #expect(state().items == [comment])
        await next(comment)
        #expect(pages == 2 && state().isLoadingMore == false)
        #expect((paper ? article.alert == nil : model.alert == nil) == cancelled)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func paperDeletionOwnsItsRequestAndReleasesAdmissionAfterFailure(fails: Bool) async throws {
        let service = DetailSortingService(poster: try makePoster(id: 1))
        service.ownsPaper = true
        let model = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "", likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        let load = Task { await model.refreshAll() }
        try await service.waitForDetail(); service.finish(); await load.value
        var pending: CheckedContinuation<Void, Never>?
        service.paperDeletion = { await withCheckedContinuation { pending = $0 }; if fails { throw URLError(.timedOut) } }
        let deletion = Task { await model.deletePaper() }
        try await waitForTestEvent { !(pending == nil) }
        #expect(model.isDeletingPaper && service.paperDeleteCalls == 1)
        #expect(await model.deletePaper() == false)
        #expect(model.isDeletingPaper && service.paperDeleteCalls == 1)
        pending?.resume()
        #expect(await deletion.value == !fails)
        #expect(model.isDeletingPaper == false)
        if fails {
            #expect(model.alert != nil)
            service.paperDeletion = {}
            #expect(await model.deletePaper())
            #expect(service.paperDeleteCalls == 2)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
    func commentLikesConvergeWithConcurrentRefresh(paper: Bool, scenario: (Bool, Bool)) async throws {
        let (likeFinishesFirst, readFails) = scenario
        let service = DetailSortingService(poster: try makePoster(id: 1))
        let model = GalleryPosterDetailViewModel(initialPoster: try makePoster(id: 1), service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "", likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        let child = CommunityComment(id: 2, obj: "comment1", images: [], user: user, anonymous: false, createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false, rate: 0, replyUser: user, replyObj: "", text: "回复", sub: [])
        let parent = CommunityComment(id: 1, obj: "poster1", images: [], user: user, anonymous: false, createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 1, own: false, rate: 0, replyUser: user, replyObj: "", text: "评论", sub: [child])
        func refresh() async { if paper { await article.refreshComments() } else { await model.refreshComments() } }
        service.commentHandler = { _ in [parent] }
        await refresh()
        var pendingRead: CheckedContinuation<Void, Never>?, pendingLike: CheckedContinuation<Void, Never>?
        service.commentHandler = { _ in await withCheckedContinuation { pendingRead = $0 }; if readFails { throw URLError(.timedOut) }; return [parent] }
        service.likeGate = { await withCheckedContinuation { pendingLike = $0 } }
        let reading = Task { await refresh() }
        try await waitForTestEvent { !(pendingRead == nil) }
        let liking = Task { if paper { await article.toggleCommentLike(child) } else { await model.likeComment(child) } }
        try await waitForTestEvent { !(pendingLike == nil) }
        if likeFinishesFirst { pendingLike?.resume(); await liking.value; pendingRead?.resume(); await reading.value }
        else { pendingRead?.resume(); await reading.value; pendingLike?.resume(); await liking.value }
        let state = paper ? article.commentState : model.commentState
        #expect(state.items.first?.sub.first?.like == true && state.items.first?.sub.first?.likeNum == 17)
        #expect(state.status == .loaded && (paper ? article.likingCommentIDs.isEmpty : model.likingCommentIDs.isEmpty))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false], ["all", "body", "comments"])
    func cancellingCommunityDetailCancelsBothRequestsAndAllowsReentry(paper: Bool, pending: String) async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        let expected: Set<String> = pending == "all" ? ["body", "comments"] : [pending]
        service.suspendedRequestKeys = expected
        let galleryModel = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let paperModel = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        func refresh() async {
            if paper { await paperModel.bootstrapIfNeeded() } else { await galleryModel.bootstrapIfNeeded() }
        }
        let entry = Task { await refresh() }
        try await waitForTestEvent { !(service.enteredRequests != expected || service.completedRequests.count != 2 - expected.count) }
        entry.cancel()
        await entry.value
        #expect(service.cancelledRequests == expected)
        #expect((paper ? paperModel.paperStatus : galleryModel.posterStatus) == (expected.contains("body") ? .idle : .loaded))
        #expect((paper ? paperModel.commentState : galleryModel.commentState).status == (expected.contains("comments") ? .idle : .loaded))
        #expect(paper ? paperModel.alert == nil : galleryModel.alert == nil)
        service.suspendedRequestKeys = []
        let previousDetailCalls = service.detailCalls
        let retry = Task { await refresh() }
        if paper || expected.contains("body") {
            try await service.waitForDetail()
            service.finish()
        }
        await retry.value
        #expect(service.detailCalls == previousDetailCalls + (paper || expected.contains("body") ? 1 : 0))
        #expect((paper ? paperModel.paperStatus : galleryModel.posterStatus) == .loaded)
        #expect((paper ? paperModel.commentState : galleryModel.commentState).status == .loaded)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false], [true, false])
    func detailRefreshRetainsSuccessfulLikesAcrossRequestCompletionOrders(paper: Bool, likeStartsFirst: Bool) async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        let gallery = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "", likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        service.pausesDetail = false
        if paper { await article.refreshAll() } else { await gallery.refreshAll() }
        service.pausesDetail = true
        var pendingLike: CheckedContinuation<Void, Never>?
        service.likeGate = { if likeStartsFirst { await withCheckedContinuation { pendingLike = $0 } } }
        func like() async { if paper { await article.likePaper() } else { await gallery.likePoster() } }
        let mutation = likeStartsFirst ? Task { await like() } : nil
        if likeStartsFirst { try await waitForTestEvent { !(pendingLike == nil) } }
        let refresh = Task { if paper { await article.refreshAll() } else { await gallery.refreshAll() } }
        try await service.waitForDetail()
        if let mutation { pendingLike?.resume(); await mutation.value } else { await like() }
        #expect(paper ? article.isPaperLiked : gallery.poster.like)
        #expect(paper ? article.resolvedLikeNum == 17 : gallery.poster.likeNum == 17)
        service.finish()
        await refresh.value
        #expect(paper ? article.paper?.like == true : gallery.poster.like)
        #expect(paper ? article.paper?.likeNum == 17 : gallery.poster.likeNum == 17)
        #expect(paper ? article.paper?.title == "loaded" : gallery.poster.id == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func hydratedPosterKeepsTheResolvedDetailUntilExplicitRefresh() async throws {
        let service = DetailSortingService(poster: try makePoster(id: 1))
        let detail = service.poster.updatingLike(true, likeNum: 17)
        service.pausesDetail = false
        let model = GalleryPosterDetailViewModel(initialPoster: detail.asPoster, initialDetail: detail, service: service)
        await model.bootstrapIfNeeded()
        #expect(model.poster == detail && model.hasKnownLikeState && service.detailCalls == 0)
        await model.refreshAll()
        #expect(service.detailCalls == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func initialDetailLikesWaitForTheCurrentUsersRead(paper: Bool) async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        service.poster = service.poster.updatingLike(true, likeNum: 17)
        service.paperLiked = true
        let gallery = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "", likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        func like() async { if paper { await article.likePaper() } else { await gallery.likePoster() } }
        await like()
        #expect(service.likeCalls == 0 && !(paper ? article.hasKnownLikeState : gallery.hasKnownLikeState))
        let loading = Task { if paper { await article.refreshAll() } else { await gallery.refreshAll() } }
        defer { loading.cancel(); service.finish() }
        try await service.waitForDetail()
        await like()
        #expect(service.likeCalls == 0)
        service.finish(); await loading.value
        #expect(paper ? article.isPaperLiked && article.hasKnownLikeState : gallery.poster.like && gallery.hasKnownLikeState)
    }

    @Test(.timeLimit(.minutes(1)))
    func galleryCommentSortingRetainsTheInFlightBodyResult() async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        let model = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let task = Task { await model.refreshAll() }
        try await service.waitForDetail()
        await model.setCommentOrder(.oldest)
        service.finish()
        await task.value
        #expect(model.posterStatus == .loaded)
        #expect(model.commentState.status == .loaded)
        #expect(model.commentOrder == .oldest)
    }

    @Test(.timeLimit(.minutes(1)))
    func paperCommentSortingRetainsTheInFlightBodyResult() async throws {
        let service = DetailSortingService(poster: try makePoster(id: 1))
        let model = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        let task = Task { await model.refreshAll() }
        try await service.waitForDetail()
        await model.setCommentOrder(.oldest)
        service.finish()
        await task.value
        #expect(model.paperStatus == .loaded)
        #expect(model.paper?.title == "loaded")
        #expect(model.commentState.status == .loaded)
        #expect(model.commentOrder == .oldest)
    }

    private final class FeedServiceStub: GalleryFeedServicing {
        private let batches: [Int: GalleryPageBatch<CommunityPoster>]
        private let requestLog = RequestLog()
        private let beforeResponse: (@MainActor (Int) async throws -> Void)?

        init(batches: [Int: GalleryPageBatch<CommunityPoster>] = [:], beforeResponse: (@MainActor (Int) async throws -> Void)? = nil) {
            self.batches = batches
            self.beforeResponse = beforeResponse
        }

        func requestedPages() async -> [Int] {
            await requestLog.snapshot()
        }

        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }

        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            await requestLog.append(sourcePage)
            try await beforeResponse?(sourcePage)
            await Task.yield()
            guard let batch = batches[sourcePage] else {
                throw URLError(.resourceUnavailable)
            }
            return batch
        }

        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            GalleryPageBatch<CommunityPoster>(items: [], nextSourcePage: startPage + 1, canLoadMore: false)
        }

        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            .init(items: [], nextSourcePage: (page ?? 0) + 1, canLoadMore: false)
        }

        private actor RequestLog {
            private var pages: [Int] = []

            func append(_ page: Int) {
                pages.append(page)
            }

            func snapshot() -> [Int] {
                pages
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func recoveredNetworkReplacesAFailedBackgroundPrefetch() async throws {
        var requests = 0
        let service = FeedServiceStub(batches: [0: .init(items: [], nextSourcePage: 1, canLoadMore: false)],
            beforeResponse: { _ in
                requests += 1
                if requests == 1 { throw URLError(.notConnectedToInternet) }
            })
        let coordinator = GalleryRecommendPrefetchCoordinator(service: service)
        await coordinator.start(from: 0).value
        #expect(try await coordinator.takePage(for: 0).page == 0)
        #expect(await service.requestedPages() == [0, 0])
    }

    @Test("A cancelled generation preserves the next generation's cached page", .timeLimit(.minutes(1)))
    func cancelledPagePreservesTheReplacementRequest() async throws {
        var requestCount = 0
        var firstResponse: CheckedContinuation<Void, Never>?
        let service = FeedServiceStub(
            batches: [0: GalleryPageBatch<CommunityPoster>(items: [], nextSourcePage: 1, canLoadMore: false)],
            beforeResponse: { _ in
                requestCount += 1
                if requestCount == 1 {
                    await withCheckedContinuation { continuation in
                        firstResponse = continuation
                    }
                }
            }
        )
        let coordinator = GalleryRecommendPrefetchCoordinator(service: service)
        let firstRequest = Task { @MainActor in try await coordinator.takePage(for: 0) }
        defer { firstRequest.cancel(); firstResponse?.resume() }
        try await waitForTestEvent { firstResponse != nil }

        coordinator.reset()
        let replacement = try await coordinator.takePage(for: 0)
        firstResponse?.resume()
        firstResponse = nil
        await #expect(throws: CancellationError.self) { try await firstRequest.value }

        let cached = try await coordinator.takePage(for: 0)
        #expect(cached.page == replacement.page)
        #expect(await service.requestedPages() == [0, 0])
    }

    @Test("Prefetched pages merge stably and never duplicate a source request", .timeLimit(.minutes(1)))
    func stablePrefetchMerge() async throws {
        let first = try makePoster(id: 1)
        let second = try makePoster(id: 2)
        let third = try makePoster(id: 3)
        let service = FeedServiceStub(batches: [
            0: GalleryPageBatch<CommunityPoster>(items: [first, first], nextSourcePage: 1, canLoadMore: true),
            1: GalleryPageBatch<CommunityPoster>(items: [first, second], nextSourcePage: 2, canLoadMore: true),
            2: GalleryPageBatch<CommunityPoster>(items: [second, third], nextSourcePage: 3, canLoadMore: true),
        ])
        let viewModel = GalleryViewModel(service: service)

        await viewModel.refresh(feed: .recommend)
        #expect(await waitUntil {
            await service.requestedPages().contains(2)
        })

        #expect(viewModel.state(for: .recommend).posters.map(\.id) == [1])
        await viewModel.loadMoreIfNeeded(for: .recommend, currentPoster: first)
        #expect(viewModel.state(for: .recommend).posters.map(\.id) == [1, 2])

        await viewModel.loadMoreIfNeeded(for: .recommend, currentPoster: second)
        #expect(viewModel.state(for: .recommend).posters.map(\.id) == [1, 2, 3])
        let requestedPages = await service.requestedPages()
        #expect(requestedPages.filter { $0 == 0 }.count == 1)
        #expect(requestedPages.filter { $0 == 1 }.count == 1)
        #expect(requestedPages.filter { $0 == 2 }.count == 1)
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        do {
            try await waitForAsyncTestEvent { await condition() }
            return true
        } catch { return false }
    }

    private func makePoster(id: Int) throws -> CommunityPoster {
        let json = """
        {
          "anonymous": false,
          "claim": { "id": 1, "text": "校园" },
          "comment_num": 0,
          "create_time": "2026-08-12T00:00:00Z",
          "edit_time": "2026-08-12T00:00:00Z",
          "id": \(id),
          "images": [],
          "like_num": 0,
          "public": true,
          "tags": [],
          "text": "内容 \(id)",
          "title": "标题 \(id)",
          "update_time": "2026-08-12T00:00:00Z",
          "user": {
            "id": 1,
            "create_time": "2026-08-12T00:00:00Z",
            "nickname": "测试用户",
            "avatar": { "mid": "avatar", "url": "", "low_url": "" },
            "motto": "",
            "identity": {
              "id": 1,
              "color": "#000000",
              "text": "用户",
              "create_time": "2026-08-12T00:00:00Z",
              "update_time": "2026-08-12T00:00:00Z",
              "delete_time": null
            }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CommunityPoster.self, from: Data(json.utf8))
    }
}
