import ScheduleSync
import ClientCore
import StorageCore
import SchedulePersistence
@testable import GalleryFeature
@testable import PaperFeature
@testable import ScheduleFeature
import ScheduleDomain
import CommunityCore
import Foundation
import Testing
@testable import BIT101_iOS

@Suite("Gallery hidden user policy")
struct GalleryContentFilterTests {
    @Test("Hiding a user also hides replies targeting that user")
    func hidesReplyTarget() {
        let hiddenIDs: Set<Int> = [42]

        #expect(GalleryContentFilter.shouldHideComment(
            authorID: 42,
            replyTargetID: 8,
            isAnonymous: false,
            hiddenUserIDs: hiddenIDs,
            hideAnonymousContent: false
        ))
        #expect(GalleryContentFilter.shouldHideComment(
            authorID: 8,
            replyTargetID: 42,
            isAnonymous: false,
            hiddenUserIDs: hiddenIDs,
            hideAnonymousContent: false
        ))
    }

    @Test("Anonymous filtering remains an independent preference")
    func keepsAnonymousContentWhenPreferenceIsOff() {
        #expect(!GalleryContentFilter.shouldHideComment(
            authorID: 8,
            replyTargetID: 0,
            isAnonymous: true,
            hiddenUserIDs: [],
            hideAnonymousContent: false
        ))
        #expect(GalleryContentFilter.shouldHideComment(
            authorID: 8,
            replyTargetID: 0,
            isAnonymous: true,
            hiddenUserIDs: [],
            hideAnonymousContent: true
        ))
    }
}

@Suite("Schedule cache migration and reconciliation")
struct ScheduleCacheMigrationTests {
    private struct LegacyCache: Encodable {
        let primaryScheduleTitle: String
        let currentTerm: String
        let courses: [CourseRecord]
        let updatedAt: Date
    }

    @Test("Legacy single-term caches migrate without losing courses or timestamps")
    func legacyCacheMigration() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let course = makeCourse(id: "course-1", term: "2025-2026-1")
        let legacy = LegacyCache(
            primaryScheduleTitle: "  一份名字很长的课表  ",
            currentTerm: course.term,
            courses: [course],
            updatedAt: timestamp
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduleCache.self, from: encoder.encode(legacy))

        #expect(decoded.courses == [course])
        #expect(decoded.manualFirstDayStringsByTerm.isEmpty)
        #expect(decoded.cachedCoursesByTerm[course.term] == [course])
        #expect(decoded.termSchedulesByTerm[course.term]?.courses == [course])
        #expect(decoded.termSchedulesByTerm[course.term]?.updatedAt == timestamp)
        #expect(decoded.coursesUpdatedAt == timestamp)
        #expect(decoded.primaryScheduleTitle.count == scheduleNameCharacterLimit)
        #expect(decoded.iCloudSyncEnabled)
        #expect(decoded.cloudSyncBaselineAt == .distantPast)
        #expect(!decoded.hasUnpushedCloudChanges)
    }

    @Test("Unreadable cache data is kept out of the save path")
    func corruptCacheBlocksReplacement() throws {
        let unreadable = ScheduleCacheStore.decodeCache(Data("invalid cache".utf8))

        #expect(unreadable.isUnreadable)
        #expect(!unreadable.allowsWrite)
        #expect(ScheduleCacheLoadResult.missing.allowsWrite)

        let cache = ScheduleCache()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let readable = ScheduleCacheStore.decodeCache(try encoder.encode(cache))

        #expect(!readable.isUnreadable)
        #expect(readable.allowsWrite)
    }

    @Test("Legacy cache migration preserves row-specific negative weeks")
    func rowSpecificNegativeWeeksSurviveCacheDecoding() throws {
        let course = CourseRecord(
            id: "negative-row",
            term: "2026-2027-1",
            name: "文献检索",
            teacher: "",
            classroom: "文萃楼M227",
            description: "-2周 星期二 6-9节 文萃楼M227,-1周 星期四 6-9节 文萃楼M227",
            weeks: [-1],
            weekday: 4,
            startSection: 6,
            endSection: 9,
            campus: "",
            number: "100960001",
            credit: 1,
            hour: 16,
            type: "",
            category: "",
            department: ""
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object: [String: Any] = [
            "storedCourseScheduleParserVersion": 1,
            "currentTerm": course.term,
            "firstDayString": "2026-08-31",
            "courses": try JSONSerialization.jsonObject(with: encoder.encode([course]))
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduleCache.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.courses.first?.weeks == [-1])
        #expect(decoded.cachedCoursesByTerm[course.term]?.first?.weeks == [-1])
        #expect(decoded.termSchedulesByTerm[course.term]?.courses.first?.weeks == [-1])
    }

    @Test("DDL sync timestamp survives cache encoding")
    func ddlUpdatedAtRoundTrip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_123)
        var cache = ScheduleCache()
        cache.ddlUpdatedAt = timestamp
        cache.cloudSyncBaselineAt = timestamp
        cache.cloudSyncBaselineRecordTag = "record-v3"
        cache.hasUnpushedCloudChanges = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ScheduleCache.self, from: encoder.encode(cache))
        #expect(decoded.ddlUpdatedAt == timestamp)
        #expect(decoded.cloudSyncBaselineAt == timestamp)
        #expect(decoded.cloudSyncBaselineRecordTag == "record-v3")
        #expect(decoded.hasUnpushedCloudChanges)
    }

    @Test("Reconciliation only applies a newer remote cache when allowed")
    func reconciliationPolicy() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)

        #expect(ScheduleCacheReconciliationPolicy.decision(
            localUpdatedAt: old,
            remoteUpdatedAt: new,
            allowsRemoteApply: true
        ) == .applyRemote)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localUpdatedAt: new,
            remoteUpdatedAt: old,
            allowsRemoteApply: true
        ) == .uploadLocal)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localUpdatedAt: new,
            remoteUpdatedAt: old,
            allowsRemoteApply: false
        ) == .uploadLocal)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localUpdatedAt: old,
            remoteUpdatedAt: new,
            allowsRemoteApply: false
        ) == .noChange)
        #expect(ScheduleCacheReconciliationPolicy.decision(
            localUpdatedAt: new,
            remoteUpdatedAt: new,
            allowsRemoteApply: true
        ) == .noChange)
        #expect(!ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: false,
            localBaselineRecordTag: "record-v1",
            remoteRecordTag: "record-v2",
            localUpdatedAt: new,
            remoteUpdatedAt: old
        ))
        #expect(!ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: true,
            localBaselineRecordTag: "record-v1",
            remoteRecordTag: "record-v1",
            localUpdatedAt: new,
            remoteUpdatedAt: old
        ))
        #expect(ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: true,
            localBaselineRecordTag: "record-v1",
            remoteRecordTag: "record-v2",
            localUpdatedAt: new,
            remoteUpdatedAt: old
        ))
        #expect(!ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: true,
            localBaselineRecordTag: "",
            remoteRecordTag: "record-v2",
            localUpdatedAt: new,
            remoteUpdatedAt: old
        ))
        #expect(ScheduleCacheReconciliationPolicy.hasConcurrentChanges(
            localHasUnpushedChanges: true,
            localBaselineRecordTag: "",
            remoteRecordTag: "record-v2",
            localUpdatedAt: old,
            remoteUpdatedAt: new
        ))
    }

    @Test("Cloud state comparison tracks user content across school refreshes")
    func cloudStateComparison() throws {
        let original = ScheduleCache()
        var refreshed = original
        refreshed.currentTerm = "2026-2027-1"
        refreshed.courseData.store(TermScheduleSnapshot(term: refreshed.currentTerm, firstDayString: "",
            courses: [], exams: [], updatedAt: Date()))
        refreshed.updatedAt = Date()
        refreshed.cloudSyncBaselineAt = Date()
        refreshed.cloudSyncBaselineRecordTag = "confirmed-record"
        refreshed.hasUnpushedCloudChanges = true
        #expect(try ScheduleCloudSyncState.matches(original, refreshed))

        refreshed.showSunday.toggle()
        #expect(try ScheduleCloudSyncState.matches(original, refreshed) == false)
    }

    @Test("Local cache timestamps advance when the device clock moves backward")
    func cacheTimestampRemainsMonotonic() {
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        let movedBackward = Date(timeIntervalSince1970: 1_600_000_000)
        let advanced = ScheduleCacheTimestamp.next(after: previous, now: movedBackward)

        #expect(advanced > previous)
        #expect(advanced.timeIntervalSince(previous) >= 0.001)
        #expect(ScheduleCacheTimestamp.next(after: previous, now: previous.addingTimeInterval(10))
            == previous.addingTimeInterval(10))

        let preciseRecordDate = Date(timeIntervalSince1970: 1_700_000_000.123)
        let roundedPayloadDate = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ScheduleCacheTimestamp.restored(
            recordDate: preciseRecordDate,
            payloadDate: roundedPayloadDate
        ) == preciseRecordDate)
        let serverDate = preciseRecordDate.addingTimeInterval(3)
        #expect(ScheduleCacheTimestamp.restored(
            recordDate: preciseRecordDate,
            payloadDate: roundedPayloadDate,
            serverDate: serverDate
        ) == serverDate)
        #expect(ScheduleCacheTimestamp.restored(
            recordDate: preciseRecordDate.addingTimeInterval(2),
            payloadDate: roundedPayloadDate
        ) == nil)
    }

    private func makeCourse(id: String, term: String) -> CourseRecord {
        CourseRecord(
            id: id,
            term: term,
            name: "高等数学",
            teacher: "张老师",
            classroom: "理教201",
            description: "",
            weeks: [1, 2],
            weekday: 1,
            startSection: 1,
            endSection: 2,
            campus: "良乡",
            number: "MATH-1",
            credit: 4,
            hour: 64,
            type: "必修",
            category: "公共课",
            department: "数学学院"
        )
    }
}

@Suite("Free-classroom request lifecycle")
@MainActor
struct ScheduleClassroomCoordinatorTests {
    private actor CancellationProbe {
        private var didObserveCancellation = false
        private var startedDeadline = false
        func beginDeadline() { startedDeadline = true }
        func deadlineStarted() -> Bool { startedDeadline }

        func recordCancellation() {
            didObserveCancellation = true
        }

        func observedCancellation() -> Bool {
            didObserveCancellation
        }
    }

    @Test("Only the newest request can finish shared loading state")
    func staleRequestsCannotFinish() {
        let coordinator = ScheduleClassroomCoordinator()
        let first = coordinator.beginRequest(hasVisibleResults: false)
        let second = coordinator.beginRequest(hasVisibleResults: false)

        #expect(first.shouldShowInitialSpinner)
        #expect(second.shouldShowInitialSpinner)
        #expect(!coordinator.finish(first.id))
        #expect(coordinator.isRequestInFlight)
        #expect(coordinator.finish(second.id))
        #expect(!coordinator.isRequestInFlight)
    }

    @Test("Authentication time is outside the classroom request deadline")
    func authenticationUsesIndependentDeadline() async throws {
        let probe = CancellationProbe()
        let coordinator = ScheduleClassroomCoordinator(waitForDeadline: { _ in
            await probe.beginDeadline()
            try await Task.sleep(for: .seconds(30))
        })
        let value = try await coordinator.withAuthenticationThenTimeout {
            #expect(await probe.deadlineStarted() == false)
            await Task.yield()
            #expect(await probe.deadlineStarted() == false)
        } operation: { 42 }

        #expect(value == 42)
    }

    @Test("Classroom operation timeout remains enforced after authentication")
    func operationTimeoutIsEnforced() async {
        let coordinator = ScheduleClassroomCoordinator(timeoutNanoseconds: 5_000_000)
        let cancellationProbe = CancellationProbe()

        do {
            _ = try await coordinator.withAuthenticationThenTimeout {
            } operation: {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    await cancellationProbe.recordCancellation()
                    throw CancellationError()
                }
                return 42
            }
            Issue.record("空教室请求超时契约失败")
        } catch is ClassroomRequestTimeoutError {
            #expect(await cancellationProbe.observedCancellation())
        } catch {
            Issue.record("空教室请求错误：\(error)")
        }
    }
}

@Suite("Schedule authentication continuation")
@MainActor
struct ScheduleCourseSyncCoordinatorTests {
    private func context() -> (ScheduleCourseSyncCoordinator, SemesterStartDateService, BITLoginAuthenticationChallenge) {
        let service = SemesterStartDateService()
        let repository = ScheduleRepository(session: { AppStorageSession(accountIdentifier: "continuation") },
            load: { _ in .missing }, save: { _, _, _ in })
        let challenge = BITLoginAuthenticationChallenge(challengeID: "continuation", accessToken: "token",
            status: "waiting_sms", maskedPhone: "138****0000", expiresIn: 300)
        return (ScheduleCourseSyncCoordinator(service: service, repository: repository, virtualNetworkLikely: { false }), service, challenge)
    }

    @Test("Classroom SMS authentication keeps the selected challenge")
    func classroomAuthenticationContinuation() {
        let (coordinator, _, challenge) = context()
        coordinator.waitForClassroomAuthentication(challenge)
        #expect(coordinator.continuation == .classroomRefresh)
        #expect(coordinator.smsChallenge?.challengeID == challenge.challengeID)
        #expect(coordinator.courseSyncTerm == nil)
        coordinator.dismissSMSChallenge()
        #expect(coordinator.smsChallenge == nil)
    }

    @Test("Service responses select the suspended operation and block overlapping requests")
    func recordsContinuationPurpose() async {
        let (coordinator, service, challenge) = context()
        service.authenticationChallenge = challenge
        await coordinator.syncCourses(term: "2025-2026-2", selectTerm: { _ in }, applyPayload: { _ in })
        #expect(coordinator.continuation == .courseSync(term: "2025-2026-2"))
        await coordinator.loadAvailableTerms()
        #expect(coordinator.courseSyncTerm == "2025-2026-2")
        coordinator.dismissSMSChallenge()
        await coordinator.loadAvailableTerms()
        #expect(coordinator.continuation == .availableTerms)
        #expect(coordinator.courseSyncTerm == nil)
        coordinator.reset()
        #expect(coordinator.continuation == nil)
    }
}

@Suite("Gallery recommendation prefetch")
@MainActor
struct GalleryRecommendationPrefetchTests {
    private final class DetailSortingService: GalleryPosterDetailServicing, PaperDetailServicing {
        let poster: GalleryPosterDetail
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
        private var started: CheckedContinuation<Void, Never>?
        init(poster: CommunityPoster) { self.poster = GalleryPosterDetail(poster: poster) }
        func pause() async {
            await withCheckedContinuation {
                response = $0
                started?.resume()
                started = nil
            }
        }
        func waitForDetail() async {
            if response != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func finish() { response?.resume(); response = nil }
        private func pauseIfRequested(_ key: String) async throws {
            guard suspendRequests || suspendedRequestKeys.contains(key) else { return }
            enteredRequests.insert(key)
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelledRequests.insert(key); throw error }
        }
        private func pauseDetail() async throws {
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
                publicEdit: false, like: false, own: ownsPaper)
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

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func cancelledCommentSubmissionRetainsTheNewEditorAndAllowsRetry(paper: Bool) async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        let comment = CommunityComment(id: 1, obj: "poster1", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: 0, own: false,
            rate: 0, replyUser: user, replyObj: "", text: "评论", sub: [])
        service.commentCreation = { [weak service] in await service?.pause(); return comment }
        let gallery = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "",
            likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        func submit() async -> Bool {
            if paper { return await article.submitComment(text: "comment", anonymous: false, target: .paper(paperID: 1)) }
            return await gallery.submitComment(text: "comment", anonymous: false, target: .poster(posterID: 1))
        }
        var editor = "first"
        let submission = Task { if await submit() { editor = "" } }
        await service.waitForDetail()
        submission.cancel()
        editor = "reopened"
        service.finish()
        await submission.value
        #expect(editor == "reopened" && service.detailCalls == 0)
        #expect(paper ? article.alert == nil : gallery.alert == nil)
        #expect(paper ? article.isSubmittingComment == false : gallery.isSubmittingComment == false)
        service.commentCreation = { comment }
        let retry = Task { await submit() }
        await service.waitForDetail()
        service.finish()
        #expect(await retry.value)
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
        while pending == nil { await Task.yield() }
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
        await service.waitForDetail(); service.finish(); await load.value
        var pending: CheckedContinuation<Void, Never>?
        service.paperDeletion = { await withCheckedContinuation { pending = $0 }; if fails { throw URLError(.timedOut) } }
        let deletion = Task { await model.deletePaper() }
        while pending == nil { await Task.yield() }
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
        while pendingRead == nil { await Task.yield() }
        let liking = Task { if paper { await article.toggleCommentLike(child) } else { await model.likeComment(child) } }
        while pendingLike == nil { await Task.yield() }
        if likeFinishesFirst { pendingLike?.resume(); await liking.value; pendingRead?.resume(); await reading.value }
        else { pendingRead?.resume(); await reading.value; pendingLike?.resume(); await liking.value }
        let state = paper ? article.commentState : model.commentState
        #expect(state.items.first?.sub.first?.like == true && state.items.first?.sub.first?.likeNum == 17)
        #expect(state.status == .loaded && (paper ? article.likingCommentIDs.isEmpty : model.likingCommentIDs.isEmpty))
    }

    private final class PaperSavingService: PaperComposerServicing {
        var bodies: [String] = []
        var versions: [String] = []
        var pending: CheckedContinuation<Void, Never>?
        var suspend = false
        private func save(_ content: String) async {
            bodies.append(content)
            if suspend { await withCheckedContinuation { pending = $0 } }
        }
        func createPaper(title: String, intro: String, content: String, anonymous: Bool, publicEdit: Bool) async throws -> Int {
            await save(content)
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

    @Test(arguments: [
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

    @Test func plainBodyEditsRoundTripEscapedTextAndKeepUntouchedSource() async {
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
    func paperSubmissionCancellationEndsItsLifecycleAndAllowsAReopenedComposer(editing: Bool) async {
        let service = PaperSavingService()
        service.suspend = true
        let model = PaperComposerViewModel(editingPaper: editing ? editingPaper("正文") : nil, initialContent: "正文")
        model.title = "标题"; model.intro = "简介"
        let task = Task { await model.submit(service: service) }
        while service.pending == nil { await Task.yield() }
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
        while service.enteredRequests != expected || service.completedRequests.count != 2 - expected.count { await Task.yield() }
        entry.cancel()
        await entry.value
        #expect(service.cancelledRequests == expected)
        #expect((paper ? paperModel.paperStatus : galleryModel.posterStatus) == (expected.contains("body") ? .idle : .loaded))
        #expect((paper ? paperModel.commentState : galleryModel.commentState).status == (expected.contains("comments") ? .idle : .loaded))
        #expect(paper ? paperModel.alert == nil : galleryModel.alert == nil)
        service.suspendedRequestKeys = []
        let retry = Task { await refresh() }
        await service.waitForDetail()
        service.finish()
        await retry.value
        #expect((paper ? paperModel.paperStatus : galleryModel.posterStatus) == .loaded)
        #expect((paper ? paperModel.commentState : galleryModel.commentState).status == .loaded)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false], [true, false])
    func detailReadsRetainSuccessfulLikesIncludingTheFirstPaperLoad(paper: Bool, likeStartsFirst: Bool) async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        let gallery = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let article = PaperDetailViewModel(initialPaper: PaperSummary(id: 1, title: "initial", intro: "", likeNum: 0, commentNum: 0, updateTime: ""), service: service)
        var pendingLike: CheckedContinuation<Void, Never>?
        service.likeGate = { if likeStartsFirst { await withCheckedContinuation { pendingLike = $0 } } }
        func like() async { if paper { await article.likePaper() } else { await gallery.likePoster() } }
        let mutation = likeStartsFirst ? Task { await like() } : nil
        if likeStartsFirst { while pendingLike == nil { await Task.yield() } }
        let refresh = Task { if paper { await article.refreshAll() } else { await gallery.refreshAll() } }
        await service.waitForDetail()
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
    func galleryCommentSortingRetainsTheInFlightBodyResult() async throws {
        let poster = try makePoster(id: 1)
        let service = DetailSortingService(poster: poster)
        let model = GalleryPosterDetailViewModel(initialPoster: poster, service: service)
        let task = Task { await model.refreshAll() }
        await service.waitForDetail()
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
        await service.waitForDetail()
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
        private let beforeResponse: (@MainActor (Int) async -> Void)?

        init(batches: [Int: GalleryPageBatch<CommunityPoster>] = [:], beforeResponse: (@MainActor (Int) async -> Void)? = nil) {
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
            await beforeResponse?(sourcePage)
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

    @Test("A cancelled generation preserves the next generation's cached page", .timeLimit(.minutes(1)))
    func cancelledPagePreservesTheReplacementRequest() async throws {
        var requestCount = 0
        var firstResponse: CheckedContinuation<Void, Never>?
        var firstRequestStarted: CheckedContinuation<Void, Never>?
        let service = FeedServiceStub(
            batches: [0: GalleryPageBatch<CommunityPoster>(items: [], nextSourcePage: 1, canLoadMore: false)],
            beforeResponse: { _ in
                requestCount += 1
                if requestCount == 1 {
                    await withCheckedContinuation { continuation in
                        firstResponse = continuation
                        firstRequestStarted?.resume()
                        firstRequestStarted = nil
                    }
                }
            }
        )
        let coordinator = GalleryRecommendPrefetchCoordinator(service: service)
        let firstRequest = Task { @MainActor in try await coordinator.takePage(for: 0) }
        defer { firstRequest.cancel(); firstResponse?.resume() }
        if firstResponse == nil {
            await withCheckedContinuation { firstRequestStarted = $0 }
        }

        coordinator.reset()
        let replacement = try await coordinator.takePage(for: 0)
        firstResponse?.resume()
        firstResponse = nil
        await #expect(throws: CancellationError.self) { try await firstRequest.value }

        let cached = try await coordinator.takePage(for: 0)
        #expect(cached.page == replacement.page)
        #expect(await service.requestedPages() == [0, 0])
    }

    @Test("Prefetched pages merge stably and never duplicate a source request")
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
        for _ in 0..<100 {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
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
