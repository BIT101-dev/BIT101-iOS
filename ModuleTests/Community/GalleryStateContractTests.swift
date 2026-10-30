import BIT101TestSupport
@testable import CommunityCore
import CommunityTransport
import CommunityUI
import Foundation
import os
import Testing
import Combine
import TransportCore
@testable import CourseFeature
@testable import PaperFeature
@testable import GalleryFeature
@testable import MineFeature

@MainActor
struct GalleryStateContractTests {
    @Test func resourceReadsPublishOneBatchAndReleaseCompletedConfirmationHistory() {
        var owner = 1
        let updates = CommunityResourceUpdates(currentOwner: { owner })
        var batches: [[CommunityResourceMetrics]] = []
        let observer = updates.changes.sink { batches.append($0) }
        defer { observer.cancel() }
        let earlier = updates.beginRead()
        updates.confirmLike(objectID: "poster1", count: 9)
        let freshRead = updates.beginRead()
        let values = (1...200).map { listPoster($0) }
        let fresh = updates.resolve(values, since: freshRead)
        #expect(batches.count == 2 && batches.last?.count == 200 && fresh.count == 200)
        updates.finishRead(freshRead)
        #expect(updates.pendingResourceCount == 1)
        #expect(updates.resolve(listPoster(1), since: earlier).likeNum == 0)
        updates.finishRead(earlier)
        #expect(updates.pendingResourceCount == 0)
        let abandoned = updates.beginRead()
        owner = 2
        let active = updates.beginRead()
        updates.finishRead(abandoned)
        updates.confirmLike(objectID: "poster2", count: 7)
        #expect(updates.resolve(listPoster(2), since: active).likeNum == 7)
        updates.finishRead(active)
        #expect(updates.pendingResourceCount == 0)
    }

    @Test func batchedMetricsPreserveIndependentFieldsAndTheLatestConfirmedValue() {
        var items = CommunityPagedItems<CommunityPoster>()
        items.replace(with: [listPoster(1), listPoster(2)])
        let changed = items.apply([.init(objectID: "poster1", likeNum: 9),
            .init(objectID: "poster1", commentNum: 3), .init(objectID: "poster1", likeNum: 10)])
        #expect(changed)
        #expect(items.items.map(\.likeNum) == [10, 0] && items.items.map(\.commentNum) == [3, 0])
        let unchanged = items.apply([.init(objectID: "poster1"), .init(objectID: "other", likeNum: 8)])
        #expect(!unchanged)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledSearchRecoveryReleasesAnEarlierPaginationSnapshot() async {
        let service = Feed()
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = "搜索"
        await model.search()
        let (events, entered) = AsyncStream<Void>.makeStream()
        var pending: [CheckedContinuation<Void, Never>] = []
        service.beforeSearch = { await withCheckedContinuation { pending.append($0); entered.yield(()) } }
        let paging = Task { await model.loadMoreSearch(currentPoster: model.searchState.posters.last) }
        var starts = events.makeAsyncIterator()
        _ = await starts.next()
        #expect(model.searchState.isLoadingMore)
        let refresh = Task { await model.search() }
        defer { paging.cancel(); refresh.cancel(); pending.forEach { $0.resume() }; entered.finish() }
        _ = await starts.next()
        refresh.cancel()
        let held = pending; pending.removeAll(); held.forEach { $0.resume() }
        await refresh.value; await paging.value
        #expect(model.searchState.posters.map(\.id) == [1] && !model.searchState.isLoadingMore)
        service.beforeSearch = nil
        await model.loadMoreSearch(currentPoster: model.searchState.posters.last)
        #expect(model.searchState.posters.map(\.id) == [1, 2] && !model.searchState.isLoadingMore)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["course", "paper", "gallery", "search", "mine", "profile"], ["error", "cancel", "exit", "success"])
    func restoredListsKeepMetricsReceivedDuringRefresh(kind: String, ending: String) async throws {
        let user = #"{"id":7,"create_time":"","nickname":"作者","avatar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":0,"color":"","text":"","create_time":"","update_time":""}}"#
        let poster = #"{"id":1,"anonymous":false,"claim":{"id":0,"text":""},"comment_num":1,"create_time":"","edit_time":"","images":[],"like_num":1,"public":true,"tags":[],"text":"正文","title":"帖子","update_time":"","user":\#(user)}"#
        let course = #"{"id":1,"name":"课程","number":"CS1","credit":3,"like_num":1,"comment_num":1,"rate":8,"teachers_name":"教师","teachers_number":"T1"}"#
        let paper = #"{"id":1,"title":"文章","intro":"摘要","like_num":1,"comment_num":1,"update_time":""}"#
        let transport = PausedMetricsTransport()
        let base = transport.base
        var replaceSecond = false
        base.responseForRequest = { request in
            let object: String
            switch request.url?.path {
            case "/courses": object = course
            case "/papers": object = paper
            case "/posters": object = poster
            default: throw URLError(.unsupportedURL)
            }
            return (200, "[" + object + "," + object.replacingOccurrences(of: #""id":1,"#, with: "\"id\":\(replaceSecond ? 3 : 2),") + "]")
        }
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), credentials: {
                .init(identity: .init(accountIdentifier: "metrics-restore"), cookie: "fixture")
            }, refresh: { _ in })
        let updates = CommunityResourceUpdates(currentOwner: { session.currentCredentials.identity })
        let preferences = { CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false) }
        let refresh: () async -> Void, snapshot: () -> [CommunityResourceMetrics], page: () -> Int
        let publish: () throws -> Void, exit: () -> Void
        func publishCurrent<Item: CommunityResourceItem>(_ items: [Item]) throws {
            let item = try #require(items.first)
            _ = updates.resolve(item.updatingCommunityMetrics(.init(objectID: item.communityObjectID,
                likeNum: 9, commentNum: 4, rate: 9.5)), since: updates.beginRead())
        }
        switch kind {
        case "course":
            let model = CourseListViewModel(service: CourseService(session: session, resourceUpdates: updates))
            refresh = { await model.refresh() }; snapshot = { model.state.items.map(\.communityMetrics) }; page = { model.state.nextPage }
            publish = { try publishCurrent(model.state.items) }; exit = { model.cancelRefreshOperations() }
        case "paper":
            let model = PaperListViewModel(service: PaperService(session: session, resourceUpdates: updates))
            refresh = { await model.refresh() }; snapshot = { model.state.items.map(\.communityMetrics) }; page = { model.state.nextPage }
            publish = { try publishCurrent(model.state.items) }; exit = { model.cancelRefreshOperations() }
        case "gallery", "search":
            let model = GalleryViewModel(service: GalleryService(session: session, preferences: preferences, resourceUpdates: updates))
            if kind == "search" {
                model.searchQuery.text = "内容"
                refresh = { await model.performSearch() }; snapshot = { model.searchState.posters.map(\.communityMetrics) }; page = { model.searchState.nextPage }
                publish = { try publishCurrent(model.searchState.posters) }
            } else {
                refresh = { await model.refresh(feed: .newest) }; snapshot = { model.state(for: .newest).posters.map(\.communityMetrics) }; page = { model.state(for: .newest).nextPage }
                publish = { try publishCurrent(model.state(for: .newest).posters) }
            }
            exit = { model.cancelPendingOperations() }
        case "mine":
            let model = MineViewModel(service: MineService(session: session, preferences: preferences, resourceUpdates: updates))
            refresh = { await model.refreshPosters() }; snapshot = { model.posterState.items.map(\.communityMetrics) }; page = { model.posterState.nextPage }
            publish = { try publishCurrent(model.posterState.items) }; exit = {}
        default:
            let model = UserProfileViewModel(userID: 7, service: MineService(session: session, preferences: preferences, resourceUpdates: updates))
            refresh = { await model.refreshPosters() }; snapshot = { model.posterState.items.map(\.communityMetrics) }; page = { model.posterState.nextPage }
            publish = { try publishCurrent(model.posterState.items) }; exit = {}
        }
        await refresh()
        let identities = snapshot().map(\.objectID), nextPage = page()
        #expect(identities.count == 2)
        let (events, entered) = AsyncStream<Void>.makeStream()
        var pending: CheckedContinuation<Void, any Error>?
        transport.beforeRequest = { try await withCheckedThrowingContinuation { pending = $0; entered.yield(()) } }
        let request = Task { await refresh() }
        defer { request.cancel(); pending?.resume(throwing: CancellationError()); entered.finish() }
        var starts = events.makeAsyncIterator()
        _ = await starts.next()
        if ending == "success" {
            updates.confirmLike(objectID: try #require(identities.first), count: 9)
            replaceSecond = true
        } else { try publish() }
        #expect(snapshot().first?.likeNum == 9)
        if ending == "cancel" || ending == "exit" {
            if ending == "exit" { exit() }
            request.cancel()
        }
        let held = try #require(pending); pending = nil
        if ending == "success" { held.resume() }
        else { held.resume(throwing: ending == "error" ? URLError(.networkConnectionLost) : CancellationError()) }
        await request.value
        if ending == "success" {
            #expect(snapshot().map(\.objectID) == identities.map { $0.hasSuffix("2") ? String($0.dropLast()) + "3" : $0 })
            #expect(snapshot().first?.likeNum == 9 && snapshot().first?.commentNum == 1)
        } else {
            #expect(snapshot().map(\.objectID) == identities && page() == nextPage)
            #expect(snapshot().first?.likeNum == 9 && snapshot().first?.commentNum == 4)
            if kind == "course" { #expect(snapshot().first?.rate == 9.5) }
        }
    }

    private final class PausedMetricsTransport: HTTPTransport {
        let base = ServiceContractTests.Transport([])
        var beforeRequest: (() async throws -> Void)?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await data(for: request, maximumBytes: nil) }
        func data(for request: URLRequest, maximumBytes: Int?) async throws -> (Data, URLResponse) {
            try await beforeRequest?()
            return try await base.data(for: request, maximumBytes: maximumBytes)
        }
    }

    @Test(.timeLimit(.minutes(1))) func imageOnlyCommentsKeepTheirUploadedAttachments() async {
        let service = SubscriptionDetails(), user = CommunityUser.placeholder(id: 7, nickname: "用户")
        let image = CommunityImage(mid: "photo", url: "https://example.invalid/photo.jpg", lowUrl: "")
        let created = CommunityComment(id: 9, obj: "poster1", images: [image], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: true, rate: 0,
            replyUser: user, replyObj: "", text: "", sub: [])
        service.createdComment = created; service.comments = [created]
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        let target = CommunityCommentComposerTarget.poster(posterID: 1)
        #expect(await model.submitComment(text: " \n", anonymous: false, target: target) == false)
        #expect(service.submissions.isEmpty)
        #expect(await model.submitComment(text: " \n", anonymous: false, imageMids: [image.mid], target: target))
        #expect(service.submissions.count == 1 && service.submissions.first?.text == "")
        #expect(service.submissions.first?.imageMids == [image.mid])
        #expect(model.commentState.items.first?.images == [image])
    }

    @Test(.timeLimit(.minutes(1))) func satisfiedEventsCompleteAtTheWaitingBoundary() async throws {
        try await waitForTestEvent(timeout: .zero) { true }
    }
    @Test func resourceMetricsKeepConfirmedWritesAcrossOlderReadsAndAccountChanges() {
        var owner = 1
        let updates = CommunityResourceUpdates(currentOwner: { owner })
        var items = CommunityPagedItems<CommunityPoster>()
        items.replace(with: [listPoster(1), listPoster(2)])
        let observer = updates.changes.sink { items.apply($0) }
        defer { observer.cancel() }
        let earlier = updates.beginRead()
        updates.confirmLike(objectID: "poster1", count: 9)
        #expect(items.items.map(\.likeNum) == [9, 0] && items.items.map(\.id) == [1, 2])
        #expect(updates.resolve(listPoster(1), since: earlier).likeNum == 9)
        updates.invalidateComments(objectID: "poster1")
        #expect(updates.resolve(listPoster(1), since: earlier).likeNum == 9)
        let fresh = listPoster(1).updatingCommunityMetrics(.init(objectID: "poster1", likeNum: 10, commentNum: 3))
        _ = updates.resolve(fresh, since: updates.beginRead())
        let delayed = updates.resolve(listPoster(1), since: earlier)
        #expect(delayed.likeNum == 10 && delayed.commentNum == 3)
        owner = 2
        updates.confirmLike(objectID: "poster1", count: 50)
        #expect(items.items.first?.likeNum == 10)
        #expect(updates.resolve(listPoster(2), since: updates.beginRead()).likeNum == 0)
    }

    @Test func resourceMetricsMergeIndependentFieldsAcrossConcurrentLikesAndReads() throws {
        let updates = CommunityResourceUpdates(currentOwner: { 1 })
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let initial = try decoder.decode(CourseSummary.self, from: Data(#"{"id":1,"name":"课程","number":"CS1","credit":3,"like_num":1,"comment_num":3,"rate":8,"teachers_name":"教师","teachers_number":"T1"}"#.utf8))
        let earlier = updates.beginRead()
        updates.confirmLike(objectID: "course1", count: 1)
        _ = updates.resolve(initial, since: updates.beginRead())
        let concurrent = updates.beginRead()
        updates.confirmLike(objectID: "course1", count: 2)
        let incoming = initial.updatingCommunityMetrics(.init(objectID: "course1", commentNum: 4, rate: 9))
        let resolved = updates.resolve(incoming, since: concurrent)
        #expect(resolved.likeNum == 2 && resolved.commentNum == 4 && resolved.rate == 9)
        let delayed = updates.resolve(initial, since: earlier)
        #expect(delayed.likeNum == 2 && delayed.commentNum == 4 && delayed.rate == 9)
        updates.invalidateComments(objectID: "course1")
        let refreshed = updates.beginRead()
        updates.confirmLike(objectID: "course1", count: 7)
        let fresh = updates.resolve(initial.updatingCommunityMetrics(.init(objectID: "course1", commentNum: 6, rate: 7.5)), since: refreshed)
        #expect(fresh.likeNum == 7 && fresh.commentNum == 6 && fresh.rate == 7.5)
        let late = updates.resolve(initial, since: concurrent)
        #expect(late.likeNum == 7 && late.commentNum == 6 && late.rate == 7.5)
    }

    @Test(.timeLimit(.minutes(1))) func confirmedInteractionsProjectAcrossCommunityListsWithoutReloadingTheirPages() async throws {
        let user = #"{"id":1,"create_time":"","nickname":"作者","avatar":{"mid":"","url":"","low_url":""},"motto":"","identity":{"id":0,"color":"","text":"","create_time":"","update_time":""}}"#
        let paper = #"{"id":1,"title":"文章","intro":"摘要","like_num":1,"comment_num":1,"update_time":""}"#
        let course = #"{"id":1,"name":"课程","number":"CS1","credit":3,"like_num":1,"comment_num":1,"rate":8,"teachers_name":"教师","teachers_number":"T1"}"#
        let poster = #"{"id":1,"anonymous":false,"claim":{"id":0,"text":""},"comment_num":1,"create_time":"","edit_time":"","images":[],"like_num":1,"public":true,"tags":[],"text":"正文","title":"帖子","update_time":"","user":\#(user)}"#
        let comment = #"{"id":2,"obj":"OBJECT","images":[],"user":\#(user),"anonymous":false,"create_time":"","update_time":"","like":false,"like_num":0,"comment_num":0,"own":true,"rate":8,"reply_user":\#(user),"reply_obj":"","text":"新评论","sub":[]}"#
        let transport = ServiceContractTests.Transport([])
        transport.responseForRequest = { request in
            switch request.url?.path {
            case "/papers": return (200, "[" + paper + "]")
            case "/courses": return (200, "[" + course + "]")
            case "/posters": return (200, "[" + poster + "]")
            case "/reaction/like": return (200, #"{"like":true,"like_num":9}"#)
            case "/reaction/comments":
                let body = try #require(request.httpBody)
                let object = try #require((JSONSerialization.jsonObject(with: body) as? [String: Any])?["obj"] as? String)
                return (200, comment.replacingOccurrences(of: "OBJECT", with: object))
            case "/papers/1": return (200, String(paper.dropLast()) + #", "content":"正文","create_time":"","update_user":\#(user),"anonymous":false,"public_edit":true,"like":true,"own":true}"#)
            case "/courses/1": return (200, String(course.dropLast()) + #", "like":true}"#)
            case "/posters/1": return (200, String(poster.dropLast()) + #", "like":true,"own":true,"plugins":"[]"}"#)
            default: throw URLError(.unsupportedURL)
            }
        }
        let session = CommunitySession(httpClient: HTTPClient(transport: transport, observer: nil),
            baseURL: AppURL.required("https://example.invalid"), credentials: {
                .init(identity: .init(accountIdentifier: "projection"), cookie: "fixture")
            }, refresh: { _ in })
        let updates = CommunityResourceUpdates(currentOwner: { session.currentCredentials.identity })
        let preferences = { CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false, useWebView: false, hideMakeupOutliers: false) }
        let papers = PaperService(session: session, resourceUpdates: updates), courses = CourseService(session: session, resourceUpdates: updates)
        let gallery = GalleryService(session: session, preferences: preferences, resourceUpdates: updates)
        let mine = MineService(session: session, preferences: preferences, resourceUpdates: updates)
        let paperModel = PaperListViewModel(service: papers), courseModel = CourseListViewModel(service: courses)
        let galleryModel = GalleryViewModel(service: gallery), mineModel = MineViewModel(service: mine)
        await paperModel.refresh(); await courseModel.refresh(); await galleryModel.refresh(feed: .newest); await mineModel.refreshPosters()
        _ = try await papers.likePaper(id: 1)
        _ = try await courses.like(objectID: "course1")
        _ = try await gallery.like(objectID: "poster1")
        #expect(paperModel.state.items.first?.likeNum == 9 && courseModel.state.items.first?.likeNum == 9)
        #expect(galleryModel.state(for: .newest).posters.first?.likeNum == 9 && mineModel.posterState.items.first?.likeNum == 9)
        #expect(transport.requests.count == 7)
        _ = try await papers.createComment(objectID: "paper1", text: "新评论", replyObjectID: nil, replyUID: nil, anonymous: false)
        #expect(paperModel.needsRefresh)
        transport.responseForRequest = { request in
            switch request.url?.path {
            case "/reaction/comments": return (200, comment.replacingOccurrences(of: "OBJECT", with: "course1"))
            case "/courses/1":
                return (200, String(course.dropLast()).replacingOccurrences(of: #""rate":8"#, with: #""rate":9.5"#)
                    .replacingOccurrences(of: #""comment_num":1"#, with: #""comment_num":6"#)
                    .replacingOccurrences(of: #""like_num":1"#, with: #""like_num":9"#) + #", "like":true}"#)
            case "/papers/1": return (200, String(paper.dropLast()).replacingOccurrences(of: #""comment_num":1"#, with: #""comment_num":5"#)
                .replacingOccurrences(of: #""like_num":1"#, with: #""like_num":9"#)
                + #", "content":"正文","create_time":"","update_user":\#(user),"anonymous":false,"public_edit":true,"like":true,"own":true}"#)
            default: throw URLError(.unsupportedURL)
            }
        }
        _ = try await papers.fetchPaper(id: 1)
        #expect(paperModel.state.items.first?.commentNum == 5 && paperModel.state.items.first?.likeNum == 9 && paperModel.state.items.map(\.id) == [1])
        #expect(transport.requests.count == 9)
        _ = try await courses.createComment(objectID: "course1", text: "新评价", replyObjectID: nil, replyUID: nil, anonymous: false, rate: 8)
        _ = try await courses.fetchCourse(id: 1)
        #expect(courseModel.state.items.first?.rate == 9.5 && courseModel.state.items.first?.commentNum == 6)
        #expect(transport.requests.count == 11)
    }
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func commentRecoveryKeepsTheReadPositionAndClearsItsFailure(pagination: Bool) async {
        let service = SubscriptionDetails(), user = CommunityUser.placeholder(id: 1, nickname: "作者")
        func comment(_ id: Int) -> CommunityComment {
            .init(id: id, obj: "poster1", images: [], user: user, anonymous: false, createTime: "", updateTime: "",
                like: false, likeNum: 0, commentNum: 0, own: false, rate: 0, replyUser: user, replyObj: "", text: "评论", sub: [])
        }
        service.commentPages[0] = .init(items: [comment(1)], nextSourcePage: 1, canLoadMore: true)
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        await model.refreshComments()
        service.commentFailure = URLError(.notConnectedToInternet)
        if pagination { await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last) }
        else { await model.refreshComments() }
        #expect(model.commentState.items.map(\.id) == [1] && model.commentState.needsRefresh == !pagination)
        service.commentFailure = nil
        service.commentPages[pagination ? 1 : 0] = .init(items: [comment(2)], nextSourcePage: 2, canLoadMore: false)
        await model.retryCommentsIfNeeded()
        #expect(model.commentState.items.map(\.id) == (pagination ? [1, 2] : [2]))
        #expect(!model.commentState.needsRefresh && model.commentState.paginationError == nil && service.posterRequests == 0)
    }

    @Test(.timeLimit(.minutes(1))) func detailReappearancePreservesCommentsAndWriteReview() async {
        let service = SubscriptionDetails()
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        service.comments = [.init(id: 1, obj: "poster1", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false, rate: 0,
            replyUser: user, replyObj: "", text: "已加载评论", sub: [])]
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        var preferences = CommunityPreferenceSnapshot(hideBots: false, hiddenUserIDs: [], hideAnonymous: false,
            useWebView: false, hideMakeupOutliers: false)
        await model.loadContent(filter: .init(preferences: preferences))
        service.creationFailure = CommunityCreateOutcomeUnknown(underlying: URLError(.networkConnectionLost))
        let target = CommunityCommentComposerTarget.poster(posterID: 1)
        #expect(await model.submitComment(text: "待确认评论", anonymous: false, target: target) == false)
        let submission = CommunityCommentSubmission(objectID: "poster1", text: "待确认评论", anonymous: false,
            replyObjectID: nil, replyUID: nil)
        #expect(model.commentReview.needsReview(submission))
        service.commentFailure = URLError(.notConnectedToInternet)
        let requests = service.commentRequests
        preferences.galleryUseWebView = true
        await model.loadContent(filter: .init(preferences: preferences))
        #expect(model.commentState.items.map(\.id) == [1] && model.commentReview.needsReview(submission))
        #expect(service.commentRequests == requests)
        preferences.galleryHiddenUserIDs = [7]
        await model.loadContent(filter: .init(preferences: preferences))
        #expect(model.commentState.items.isEmpty && model.commentReview.needsReview(submission))
        service.commentFailure = nil
        service.comments = []
        let posterRequests = service.posterRequests
        await model.retryFailedContentIfNeeded()
        #expect(model.commentState.status == .loaded && service.posterRequests == posterRequests)
    }

    @Test(.timeLimit(.minutes(1))) func returningToSubscriptionsPreservesTheLoadedPages() async {
        let service = Subscriptions()
        service.pages = [0: [subscription(1)], 1: [subscription(2)]]
        let model = GallerySubscriptionsViewModel(service: service)
        await model.bootstrapIfNeeded()
        await model.loadMore()
        await model.bootstrapIfNeeded()
        #expect(service.requests == [0, 1] && model.items.map(\.id) == [1, 2])
    }

    private final class Subscriptions: GallerySubscriptionServicing {
        var pages: [Int: [GallerySubscription]] = [:]
        var failedPage: Int?
        var failure: (any Error)?
        var gate: ListRequestGate<[GallerySubscription]>?
        var requests: [Int] = []
        func fetchSubscriptions(page: Int) async throws -> [GallerySubscription] {
            requests.append(page)
            if let failure { throw failure }
            if failedPage == page { throw URLError(.notConnectedToInternet) }
            if page > 0, let gate { return try await gate.request() }
            return pages[page] ?? []
        }
    }

    private func subscription(_ id: Int) -> GallerySubscription {
        .init(id: id, subscriptionTime: "", obj: "poster\(id)", level: .silent, text: "话题\(id)")
    }

    private final class SubscriptionDetails: GalleryPosterDetailServicing {
        var poster = GalleryPosterDetail(poster: listPoster(1)).updatingSubscription(.none)
        var failure: (any Error)?
        var writeGate: ListRequestGate<Void>?
        var readGate: ListRequestGate<GalleryPosterDetail>?
        var writes = 0
        var readFailure: (any Error)?
        var comments: [CommunityComment] = []
        var commentPages: [Int: GalleryPageBatch<CommunityComment>] = [:]
        var commentFailure: (any Error)?
        var creationFailure: any Error = URLError(.unsupportedURL)
        var createdComment: CommunityComment?
        var submissions: [CommunityCommentSubmission] = []
        var commentRequests = 0
        var commentQueries: [(order: CommunityCommentOrder, page: Int?)] = []
        var posterRequests = 0
        func fetchPoster(id: Int) async throws -> GalleryPosterDetail {
            posterRequests += 1
            if let readFailure { throw readFailure }
            if let readGate { return try await readGate.request() }
            return poster
        }
        func setSubscription(objectID: String, level: GallerySubscriptionLevel) async throws {
            writes += 1
            if let failure { throw failure }
            if let writeGate { try await writeGate.request() }
            poster = poster.updatingSubscription(level)
        }
        func fetchComments(objectID: String, order: CommunityCommentOrder, page: Int?) async throws -> GalleryPageBatch<CommunityComment> {
            commentRequests += 1
            commentQueries.append((order, page))
            if let commentFailure { throw commentFailure }
            if let batch = commentPages[page ?? 0] { return batch }
            return .init(items: comments, nextSourcePage: 0, canLoadMore: false)
        }
        func like(objectID: String) async throws -> CommunityLikeResult { throw URLError(.unsupportedURL) }
        func createComment(objectID: String, text: String, replyObjectID: String?, replyUID: Int?, anonymous: Bool, imageMids: [String]) async throws -> CommunityComment {
            submissions.append(.init(objectID: objectID, text: text, anonymous: anonymous,
                replyObjectID: replyObjectID, replyUID: replyUID, imageMids: imageMids))
            if let createdComment { return createdComment }
            throw creationFailure
        }
        func deleteComment(id: Int) async throws { throw URLError(.unsupportedURL) }
        func deletePoster(id: Int) async throws { throw URLError(.unsupportedURL) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func detailRefreshFailurePreservesConfirmedSubscriptionActions(loaded: Bool) async {
        let service = SubscriptionDetails()
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        if loaded { await model.refreshAll() }
        service.readFailure = URLError(.timedOut)
        await model.refreshAll()
        #expect(model.alert?.title == "加载帖子失败")
        #expect(model.posterStatus == (loaded ? .loaded : .failed(URLError(.timedOut).localizedDescription)))
        #expect(await model.setSubscription(.comment) == loaded)
        #expect(service.writes == (loaded ? 1 : 0))
        service.readFailure = nil
        await model.refreshAll()
        #expect(model.posterStatus == .loaded)
        #expect(await model.setSubscription(.update))
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionWriteFailuresKeepConfirmedStateAndCanBeRetried() async {
        let service = SubscriptionDetails()
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        await model.refreshAll()
        #expect(await model.setSubscription(.silent))
        service.failure = URLError(.networkConnectionLost)
        #expect(await model.setSubscription(.update) == false)
        #expect(model.poster.subscription == .silent && !model.isSavingSubscription && model.alert != nil)
        service.failure = nil
        #expect(await model.setSubscription(.update))
        #expect(model.poster.subscription == .update && service.writes == 3)
        #expect(model.poster.updatingLike(true, likeNum: 1).subscription == .update)
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionSaveSurvivesAnOlderRefreshAndSerializesRepeatedTaps() async throws {
        let service = SubscriptionDetails()
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        await model.refreshAll()
        let oldPoster = service.poster
        let write = ListRequestGate<Void>(), read = ListRequestGate<GalleryPosterDetail>()
        service.writeGate = write
        let saving = Task { await model.setSubscription(.comment) }
        try await write.waitUntilRequested()
        #expect(await model.setSubscription(.silent) == false && service.writes == 1)
        service.readGate = read
        let refresh = Task { await model.refreshAll() }
        try await read.waitUntilRequested()
        write.finish(())
        #expect(await saving.value)
        read.finish(oldPoster)
        await refresh.value
        #expect(model.poster.subscription == .comment && model.posterStatus == .loaded)
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionPaginationDeduplicatesAndRetainsFailedPageForRetry() async {
        let service = Subscriptions()
        service.pages = [0: [subscription(1)], 1: [subscription(1), subscription(2)]]
        let model = GallerySubscriptionsViewModel(service: service)
        await model.refresh()
        service.failedPage = 1
        await model.loadMore()
        #expect(model.items.map(\.id) == [1] && model.canLoadMore && !model.isLoadingMore && model.alert != nil)
        service.failedPage = nil
        await model.loadMore()
        #expect(model.items.map(\.id) == [1, 2] && service.requests == [0, 1, 1])
        await model.loadMore()
        #expect(!model.canLoadMore && model.status == .loaded)
        service.pages[0] = []
        await model.refresh()
        #expect(model.items.isEmpty && !model.canLoadMore && model.status == .loaded)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func subscriptionDuplicatePagesAdvanceWithinTheSharedProgressBound(stalled: Bool) async {
        let service = Subscriptions()
        service.pages = Dictionary(uniqueKeysWithValues: (0...4).map { ($0, [subscription(1)]) })
        if !stalled { service.pages[3] = [subscription(2)] }
        let model = GallerySubscriptionsViewModel(service: service)
        await model.refresh()
        await model.loadMore()
        #expect(service.requests == (stalled ? [0, 1, 2, 3, 4] : [0, 1, 2, 3]))
        #expect(model.items.map(\.id) == (stalled ? [1] : [1, 2]))
        if stalled {
            #expect(model.alert != nil && !model.isLoadingMore && model.canLoadMore)
            service.pages[4] = [subscription(2)]
            await model.loadMore()
            #expect(service.requests.last == 4 && model.items.map(\.id) == [1, 2])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionRefreshSupersedesAnOlderNextPage() async throws {
        let service = Subscriptions()
        service.pages[0] = [subscription(1)]
        let model = GallerySubscriptionsViewModel(service: service)
        await model.refresh()
        let gate = ListRequestGate<[GallerySubscription]>()
        service.gate = gate
        let page = Task { await model.loadMore() }
        try await gate.waitUntilRequested()
        service.pages[0] = [subscription(2)]
        await model.refresh()
        gate.finish([subscription(3)])
        await page.value
        #expect(model.items.map(\.id) == [2] && model.status == .loaded && !model.isLoadingMore)
        service.failedPage = 0
        await model.refresh()
        #expect(model.items.map(\.id) == [2] && model.alert != nil && model.status == .loaded)
    }

    private nonisolated struct IndexedItem: Identifiable {
        let value: Int
        let reads: OSAllocatedUnfairLock<Int>
        var id: Int { reads.withLock { $0 += 1 }; return value }
    }
    private final class Feed: GalleryFeedServicing {
        var queryLog: [GallerySearchQuery] = []
        var failed = false
        var repeated = false
        var recommendRequests: [Int] = []
        var searchRequests: [Int] = []
        var searchPages: [Int: GalleryPageBatch<CommunityPoster>] = [:]
        var sourcePages: [Int: GalleryPageBatch<CommunityPoster>] = [:]
        var failedSearchPage: Int?
        var beforeSearch: (() async throws -> Void)?
        var totalPages: Int?
        var body = ""
        var decodesIndependentBodies = false
        func fetchFeed(kind: GalleryFeedKind, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            let page = page ?? 0
            if let batch = sourcePages[page] { return batch }
            if let totalPages {
                let items = try (page * 100 + 1 ... (page + 1) * 100).map { id in
                    if decodesIndependentBodies {
                        let data = try JSONSerialization.data(withJSONObject: ["id": id, "anonymous": false,
                            "text": body + "\(id)", "user": ["id": 1]])
                        return try JSONDecoder().decode(CommunityPoster.self, from: data)
                    }
                    return GalleryStateContractTests.poster(id, text: body)
                }
                return .init(items: items, nextSourcePage: page + 1, canLoadMore: page + 1 < totalPages)
            }
            return .init(items: [GalleryStateContractTests.poster(page + 1)], nextSourcePage: page + 1, canLoadMore: true)
        }
        func fetchRecommendPage(sourcePage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            recommendRequests.append(sourcePage)
            return .init(items: [GalleryStateContractTests.poster(repeated ? 1 : sourcePage + 1)], nextSourcePage: sourcePage + 1, canLoadMore: true)
        }
        func fetchBotFeed(startPage: Int) async throws -> GalleryPageBatch<CommunityPoster> {
            try await fetchFeed(kind: .bot, page: startPage)
        }
        func searchPosters(query: GallerySearchQuery, page: Int?) async throws -> GalleryPageBatch<CommunityPoster> {
            queryLog.append(query)
            let sourcePage = page ?? 0
            searchRequests.append(sourcePage)
            try await beforeSearch?()
            if failed || failedSearchPage == sourcePage { throw URLError(.notConnectedToInternet) }
            if let batch = searchPages[sourcePage] { return batch }
            return try await fetchFeed(kind: .newest, page: page)
        }
    }

    private final class Report: GalleryReportServicing {
        var types: [GalleryReportType] = []
        var failed = false
        var submissions = 0
        var submitted: (objectID: String, typeID: Int, text: String)?
        var pending: CheckedContinuation<Void, Never>?
        var failure: (any Error)?
        func fetchReportTypes() async throws -> [GalleryReportType] {
            if failed { throw URLError(.notConnectedToInternet) }
            return types
        }
        func report(objectID: String, typeID: Int, text: String) async throws {
            submissions += 1
            submitted = (objectID, typeID, text)
            if let failure { throw failure }
            await withCheckedContinuation { pending = $0 }
            try Task.checkCancellation()
        }
    }

    private static func poster(_ id: Int, text: String = "") -> CommunityPoster {
        .init(anonymous: false, claim: .init(id: 0, text: ""), commentNum: 0, createTime: "", editTime: "", id: id,
            images: [], likeNum: 0, public: true, tags: [], text: text, title: "帖子", updateTime: "",
            user: .placeholder(id: 1, nickname: "作者"))
    }

    @Test(.timeLimit(.minutes(1))) func failedSearchKeepsTheSuccessfulQueryAndPaginationSnapshot() async {
        let service = Feed()
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = "原查询"
        await model.performSearch()
        let previous = model.searchState
        model.searchQuery.text = "新查询"
        service.failed = true
        await model.performSearch()
        #expect(model.searchState.posters == previous.posters && model.searchState.status == .loaded)
        #expect(model.searchState.needsRefresh)
        #expect(model.displayedQueryDescription == "“原查询”的话题 · 最新")
        #expect(model.searchState.nextPage == previous.nextPage && model.searchState.canLoadMore)
        service.failed = false
        await model.loadMoreSearchResultsIfNeeded(currentPoster: previous.posters.last)
        #expect(service.queryLog.last?.text == "原查询" && model.searchState.posters.map(\.id) == [1, 2])
        await model.performSearch()
        #expect(model.displayedQueryDescription == nil)
        #expect(!model.searchState.needsRefresh)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func duplicateSourcePagesKeepTheFeedAndSearchRetryCursor(search: Bool) async {
        let service = Feed()
        for page in 0...5 {
            service.sourcePages[page] = .init(items: [listPoster(page == 5 ? 2 : 1)],
                nextSourcePage: page + 1, canLoadMore: page < 5)
        }
        let model = GalleryViewModel(service: service)
        if search { await model.performSearch() } else { await model.refresh(feed: .newest) }
        func state() -> GalleryFeedState { search ? model.searchState : model.state(for: .newest) }
        func next() async {
            if search { await model.loadMoreSearchResultsIfNeeded(currentPoster: state().posters.last) }
            else { await model.loadMoreIfNeeded(for: .newest, currentPoster: state().posters.last) }
        }
        await next()
        #expect(state().posters.map(\.id) == [1] && state().nextPage == 4 && state().paginationError != nil)
        await next()
        #expect(state().posters.map(\.id) == [1, 2] && state().nextPage == 6 && state().paginationError == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateCommentPagesKeepTheirRetryCursor() async {
        let service = SubscriptionDetails()
        let user = listUser(1)
        for page in 0...5 {
            let comment = CommunityComment(id: page == 5 ? 2 : 1, obj: "poster1", images: [], user: user,
                anonymous: false, createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0,
                own: false, rate: 0, replyUser: user, replyObj: "", text: "评论", sub: [])
            service.commentPages[page] = .init(items: [comment], nextSourcePage: page + 1, canLoadMore: page < 5)
        }
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        await model.refreshComments()
        await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
        #expect(model.commentState.items.map(\.id) == [1] && model.commentState.nextPage == 4 && model.commentState.paginationError != nil)
        await model.loadMoreCommentsIfNeeded(currentComment: model.commentState.items.last)
        #expect(model.commentState.items.map(\.id) == [1, 2] && model.commentState.nextPage == 6 && model.commentState.paginationError == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingSortChangesKeepsAnEmptyLoadedPageAndItsOrderTogether() async {
        let service = SubscriptionDetails()
        service.commentPages[0] = .init(items: [], nextSourcePage: 5, canLoadMore: true, sourceIDs: Array(1...5))
        service.commentPages[5] = .init(items: [], nextSourcePage: 6, canLoadMore: false)
        let model = GalleryPosterDetailViewModel(initialPoster: listPoster(1), service: service)
        await model.refreshComments()
        service.commentFailure = CancellationError()
        await model.setCommentOrder(.like)
        #expect(model.commentOrder == .newest && model.commentState.status == .loaded && model.commentState.nextPage == 5)
        service.commentFailure = nil
        await model.loadMoreCommentsIfNeeded(currentComment: nil)
        #expect(service.commentQueries.last?.order == .newest && service.commentQueries.last?.page == 5)
        #expect(model.commentState.nextPage == 6 && !model.commentState.canLoadMore)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func subscriptionRecoveryRetainsItsIntentThroughCancellation(loaded: Bool) async {
        let service = Subscriptions()
        let recovering = GallerySubscriptionsViewModel(service: service)
        if loaded { service.pages[0] = [subscription(1)]; await recovering.refresh() }
        service.failure = URLError(.notConnectedToInternet)
        await recovering.refresh()
        let status = recovering.status
        service.failure = CancellationError()
        await recovering.refresh()
        #expect(recovering.status == status && recovering.needsRefresh)
        service.failure = nil
        await recovering.refresh()
        #expect(recovering.status == .loaded && !recovering.needsRefresh)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellingSearchRecoveryStopsItsOwnedRequest(pagination: Bool) async throws {
        let service = Feed()
        let recovering = GalleryViewModel(service: service)
        await recovering.search()
        service.failed = true
        if pagination { await recovering.loadMoreSearch(currentPoster: recovering.searchState.posters.last) }
        else { await recovering.search() }
        service.failed = false
        var started = false, cancelled = false
        service.beforeSearch = {
            started = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true; throw error }
        }
        let task = Task {
            if pagination { await recovering.loadMoreSearch(currentPoster: recovering.searchState.posters.last) }
            else { await recovering.search() }
        }
        try await waitForTestEvent { started }
        task.cancel(); await task.value
        #expect(cancelled && recovering.searchState.posters.map(\.id) == [1])
        #expect(pagination ? recovering.searchState.paginationError != nil : recovering.searchState.needsRefresh)
        service.beforeSearch = nil
        if pagination { await recovering.loadMoreSearch(currentPoster: recovering.searchState.posters.last) }
        else { await recovering.search() }
        #expect(pagination ? recovering.searchState.paginationError == nil : !recovering.searchState.needsRefresh)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func feedAndSearchKeepLongBrowsingHistoryWithinTheTextPreviewBudget(search: Bool) async {
        let service = Feed()
        service.totalPages = 200
        service.body = String(repeating: "正文", count: 4_096)
        service.decodesIndependentBodies = true
        let model = GalleryViewModel(service: service)
        if search { await model.performSearch() }
        else { await model.refresh(feed: .newest) }
        for _ in 1..<200 {
            if search { await model.loadMoreSearchResultsIfNeeded(currentPoster: model.searchState.posters.last) }
            else { await model.loadMoreIfNeeded(for: .newest, currentPoster: model.state(for: .newest).posters.last) }
        }
        let state = search ? model.searchState : model.state(for: .newest)
        #expect(state.posters.map(\.id) == Array(1...20_000))
        #expect(state.nextPage == 200 && !state.canLoadMore && !state.isLoadingMore && model.alert == nil)
        let retainedBytes = state.posters.reduce(0) { $0 + $1.text.utf8.count }
        #expect(retainedBytes <= state.posters.count * CommunityTextLimits.maximumPreviewBytes)
        #expect(state.posters.first?.text == CommunityTextLimits.displayText(service.body, preview: true))
        #expect(state.posters.last?.text == state.posters.first?.text)
    }

    @Test(arguments: [0, -1, 1])
    func posterListsPreserveDisplayFieldsAndRequireResourceIdentity(id: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "anonymous": true, "title": "可读标题", "text": "可读正文"])
        if id > 0 {
            let poster = try JSONDecoder().decode(CommunityPoster.self, from: data)
            #expect(poster.title == "可读标题" && poster.text == "可读正文" && poster.anonymous)
            #expect(poster.tags.isEmpty && poster.images.isEmpty && poster.createTime.isEmpty)
        } else {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(CommunityPoster.self, from: data) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func searchPaginationCrossesDuplicatePagesAndStopsAtTheEnd() async {
        let service = Feed()
        service.searchPages = [0: .init(items: [Self.poster(1)], nextSourcePage: 1, canLoadMore: true),
            1: .init(items: [Self.poster(1)], nextSourcePage: 2, canLoadMore: true),
            2: .init(items: [Self.poster(2)], nextSourcePage: 3, canLoadMore: true),
            3: .init(items: [], nextSourcePage: 4, canLoadMore: false)]
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = "搜索"
        await model.performSearch()
        await model.loadMoreSearchResultsIfNeeded(currentPoster: Self.poster(1))
        #expect(model.searchState.posters.map(\.id) == [1, 2] && model.searchState.nextPage == 3)
        #expect(service.searchRequests == [0, 1, 2] && model.alert == nil)
        await model.loadMoreSearchResultsIfNeeded(currentPoster: Self.poster(2))
        #expect(service.searchRequests == [0, 1, 2, 3])
        #expect(model.searchState.posters.map(\.id) == [1, 2] && !model.searchState.canLoadMore && !model.searchState.isLoadingMore)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["repeated", "stalled", "failed"])
    func searchPaginationFailuresKeepTheRetryPosition(scenario: String) async {
        let service = Feed()
        for page in 0...4 {
            service.searchPages[page] = .init(items: [Self.poster(1)],
                nextSourcePage: scenario == "stalled" && page == 1 ? 1 : page + 1, canLoadMore: true)
        }
        if scenario == "failed" { service.failedSearchPage = 2 }
        let model = GalleryViewModel(service: service)
        model.searchQuery.text = "搜索"
        await model.performSearch()
        await model.loadMoreSearchResultsIfNeeded(currentPoster: Self.poster(1))
        let retryPage = scenario == "repeated" ? 4 : scenario == "failed" ? 2 : 1
        #expect(model.searchState.posters.map(\.id) == [1] && model.searchState.nextPage == retryPage)
        #expect(!model.searchState.isLoadingMore && model.searchState.canLoadMore && model.alert != nil)
        #expect(service.searchRequests == (scenario == "repeated" ? [0, 1, 2, 3, 4] : scenario == "stalled" ? [0, 1] : [0, 1, 2]))
        service.failedSearchPage = nil
        service.searchPages[retryPage] = .init(items: [Self.poster(2)], nextSourcePage: retryPage + 1, canLoadMore: false)
        await model.loadMoreSearchResultsIfNeeded(currentPoster: Self.poster(1))
        #expect(model.searchState.posters.map(\.id) == [1, 2] && model.searchState.nextPage == retryPage + 1)
        #expect(service.searchRequests.last == retryPage && !model.searchState.canLoadMore && !model.searchState.isLoadingMore)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedRecommendPagesPreserveTheRetryPosition() async {
        let service = Feed()
        service.repeated = true
        let model = GalleryViewModel(service: service)
        await model.refresh(feed: .recommend)
        await model.loadMoreIfNeeded(for: .recommend, currentPoster: Self.poster(1))
        let state = model.state(for: .recommend)
        #expect(state.posters.map(\.id) == [1] && state.isLoadingMore == false && state.nextPage == 4)
        #expect(model.alert != nil && service.recommendRequests.allSatisfy { $0 <= 4 })
        service.repeated = false
        await model.loadMoreIfNeeded(for: .recommend, currentPoster: Self.poster(1))
        #expect(model.state(for: .recommend).posters.map(\.id) == [1, 6] && model.state(for: .recommend).nextPage == 6)
        #expect(model.state(for: .recommend).paginationError == nil)
        #expect(service.recommendRequests.filter { $0 < 4 } == [0, 1, 2, 3])
        model.cancelPendingOperations()
    }

    @Test(.timeLimit(.minutes(1))) func memoryPressureReleasesInactiveFeedsAndRetainsTheActiveCursor() async {
        let model = GalleryViewModel(service: Feed())
        await model.refresh(feed: .newest)
        await model.refresh(feed: .follow)
        model.selectedFeed = .newest
        model.releaseInactiveFeeds()
        #expect(model.state(for: .follow).posters.isEmpty && model.state(for: .follow).status == .idle)
        #expect(model.state(for: .newest).posters.map(\.id) == [1] && model.state(for: .newest).nextPage == 1)
    }

    @Test(.timeLimit(.minutes(1))) func reportCategoriesRespectRemoteEmptyAndFailureResults() async throws {
        let service = Report()
        let model = GalleryReportViewModel(service: service)
        await model.loadReportTypes()
        #expect(model.reportTypes.isEmpty && model.selectedTypeID == nil)
        #expect(await model.submit(objectID: "poster1") == false && service.submissions == 0)
        service.failed = true
        await model.loadReportTypes()
        #expect(model.errorMessage != nil && model.selectedTypeID == nil)
        service.failed = false
        service.types = try JSONDecoder().decode([GalleryReportType].self,
            from: Data(#"[{"id":42,"text":" 服务端类型\n"},{"id":42,"text":"重复类型"},{"id":7,"text":" "},{"id":7,"text":"其他类型"}]"#.utf8))
        await model.loadReportTypes()
        #expect(model.reportTypes.map(\.id) == [42, 7] && model.selectedTypeID == 42 && model.errorMessage == nil)
        #expect(model.reportTypes.map(\.text) == ["服务端类型", "其他类型"])
        #expect(!model.isLoading && !model.isSubmitting)
        model.selectedTypeID = 999
        #expect(await model.submit(objectID: "poster1") == false && service.submissions == 0)
        model.selectedTypeID = 7
        model.text = "  举报说明\n"
        let submission = Task { await model.submit(objectID: "poster1") }
        try await waitForTestEvent { service.pending != nil }
        #expect(model.isSubmitting && service.submissions == 1)
        let pending = try #require(service.pending)
        service.pending = nil
        pending.resume()
        #expect(await submission.value)
        #expect(service.submitted?.objectID == "poster1" && service.submitted?.typeID == 7)
        #expect(service.submitted?.text == "举报说明" && !model.isSubmitting && model.errorMessage == nil)
    }

    @Test(.timeLimit(.minutes(1))) func reportResponseLossPausesRepeatedSubmission() async throws {
        let service = Report()
        service.types = try JSONDecoder().decode([GalleryReportType].self, from: Data(#"[{"id":42,"text":"类型"}]"#.utf8))
        service.failure = CommunityCreateOutcomeUnknown(underlying: URLError(.networkConnectionLost))
        let model = GalleryReportViewModel(service: service)
        await model.loadReportTypes()
        #expect(await model.submit(objectID: "poster1") == false)
        #expect(model.resultNeedsReview && model.errorMessage == CommunityCreateOutcomeUnknown.reportReviewMessage)
        #expect(await model.submit(objectID: "poster1") == false && service.submissions == 1)
        await model.loadReportTypes()
        #expect(model.resultNeedsReview && model.errorMessage != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func closingReportCancelsTheOwnedSubmissionAndItsLateCompletion() async throws {
        let service = Report()
        service.types = try JSONDecoder().decode([GalleryReportType].self, from: Data(#"[{"id":42,"text":"类型"}]"#.utf8))
        let model = GalleryReportViewModel(service: service)
        await model.loadReportTypes()
        let task = Task { await model.submit(objectID: "poster1") }
        try await waitForTestEvent { !(service.pending == nil) }
        #expect(await model.submit(objectID: "poster1") == false && service.submissions == 1)
        model.cancel()
        service.pending?.resume()
        #expect(await task.value == false && model.errorMessage == nil && model.isSubmitting == false)
    }

    @Test func minePaginationReadsEachIncomingIDOnce() {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        var state = MinePagedState<IndexedItem>()
        for page in 0..<1_000 {
            state.appendPage((page * 100 ..< (page + 1) * 100).map { IndexedItem(value: $0, reads: reads) })
        }
        #expect(reads.withLock { $0 } == 100_000 && state.items.count == 100_000)
        state.resetPagination()
        state.applyFirstPage([IndexedItem(value: 1, reads: reads), IndexedItem(value: 1, reads: reads)])
        state.appendPage([IndexedItem(value: 2, reads: reads)])
        #expect(state.items.map(\.id) == [1, 2])
    }

    @Test func pageStateAdvancesAndStopsOnEmptyPages() {
        struct Item: Identifiable { let id: Int }
        var state = MinePagedState<Item>()
        state.applyFirstPage([Item(id: 1), Item(id: 2)])
        #expect(state.nextPage == 1 && state.shouldLoadMore(currentID: 2))
        state.isLoadingMore = true
        #expect(!state.shouldLoadMore(currentID: 2))
        state.appendPage([])
        #expect(state.nextPage == 2 && !state.canLoadMore && !state.isLoadingMore)
        state.resetPagination()
        #expect(state.items.isEmpty && state.nextPage == 0 && state.canLoadMore)
    }

    @Test(.timeLimit(.minutes(1)))
    func largePaginationKeepsAnIncrementalIndexAndStableOrder() {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        func item(_ value: Int) -> IndexedItem { .init(value: value, reads: reads) }
        var storage = CommunityPagedItems<IndexedItem>()
        for page in 0..<1_000 { storage.append((page * 100 ..< (page + 1) * 100).map(item)) }
        storage.append((0..<100_000).map(item))
        #expect(reads.withLock { $0 } == 200_000)
        #expect(storage.items.map(\.id) == Array(0..<100_000) && storage.ids.count == 100_000)
        storage.replace(with: [item(5)])
        storage.append([item(0), item(5)])
        #expect(storage.items.map(\.id) == [5, 0] && storage.ids == [0, 5])
    }
}
