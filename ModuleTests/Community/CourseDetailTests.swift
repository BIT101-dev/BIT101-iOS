import CommunityCore
import Foundation
import Testing
@testable import CourseFeature

@MainActor
struct CourseDetailTests {
    private static let detail = CourseDetail(id: 42, name: "操作系统", number: "CS101", credit: 3.5,
        likeNum: 1, commentNum: 2, rate: 8, teachersName: " 教师 ", teachersNumber: " T1 ", like: false)

    private final class Gate {
        var pending: CheckedContinuation<Void, Never>?
        var entered: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { pending = $0; entered?.resume(); entered = nil }
        }
        func waitForEntry() async {
            if pending != nil { return }
            await withCheckedContinuation { entered = $0 }
        }
        func resume() { pending?.resume(); pending = nil }
    }

    private final class Service: CourseDetailServicing {
        var detailResult: Result<CourseDetail, Error> = .success(CourseDetailTests.detail)
        var commentResult: Result<[CommunityComment], Error> = .success([])
        var historyResult: Result<[CourseHistoryGrade], Error> = .success([])
        var pages: [Int: [CommunityComment]] = [:]
        var detailCalls = 0
        var commentRequests: [Int?] = []
        var likedObjects: [String] = []
        var submitted: (String, String, String?, Int?, Bool, Int?)?
        var firstDetailGate: Gate?
        var commentGate: Gate?
        var commentReadGate: Gate?
        var likeGate: Gate?
        var suspendRequests = false
        var enteredRequests: Set<String> = []
        var cancelledRequests: Set<String> = []
        private func pauseIfRequested(_ key: String) async throws {
            guard suspendRequests else { return }
            enteredRequests.insert(key)
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelledRequests.insert(key); throw error }
        }
        func fetchCourse(id: Int) async throws -> CourseDetail {
            detailCalls += 1
            try await pauseIfRequested("body")
            let captured = detailResult
            if let gate = firstDetailGate { firstDetailGate = nil; await gate.pause() }
            return try captured.get()
        }
        func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] { try historyResult.get() }
        func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment] {
            commentRequests.append(page)
            try await pauseIfRequested("comments")
            let captured = page.flatMap { pages[$0] }.map { Result<[CommunityComment], Error>.success($0) } ?? commentResult
            if let gate = commentReadGate { commentReadGate = nil; await gate.pause() }
            return try captured.get()
        }
        func like(objectID: String) async throws -> CommunityLikeResult {
            likedObjects.append(objectID)
            if let gate = likeGate { likeGate = nil; await gate.pause() }
            return CommunityLikeResult(like: true, likeNum: 9)
        }
        func createComment(objectID: String, text: String, replyObjectID: String?, replyUID: Int?, anonymous: Bool, rate: Int?) async throws -> CommunityComment {
            submitted = (objectID, text, replyObjectID, replyUID, anonymous, rate)
            if let gate = commentGate { commentGate = nil; await gate.pause() }
            return CourseDetailTests.comment(9)
        }
    }

    private static func comment(_ id: Int, sub: [CommunityComment] = []) -> CommunityComment {
        let user = CommunityUser.placeholder(id: 7, nickname: "用户")
        return CommunityComment(id: id, obj: "course42", images: [], user: user, anonymous: false,
            createTime: "", updateTime: "", like: false, likeNum: 0, commentNum: sub.count, own: true,
            rate: 0, replyUser: user, replyObj: "", text: "评论", sub: sub)
    }

    private func model(_ service: Service) -> CourseDetailViewModel {
        CourseDetailViewModel(initialCourse: CourseSummary(detail: Self.detail), service: service,
            loadCourseCredits: { [CommunityCourseCredit(number: "CS101", name: "操作系统", credit: 4)] })
    }

    @Test func cancelledCommentSubmissionRetainsTheNewEditorAndAllowsRetry() async {
        let service = Service()
        let gate = Gate()
        service.commentGate = gate
        let viewModel = model(service)
        var editor = "first"
        let submission = Task {
            if await viewModel.submitComment(text: "first", anonymous: false, rate: 6, target: .course(courseID: 42)) {
                editor = ""
            }
        }
        await gate.waitForEntry()
        submission.cancel()
        editor = "reopened"
        gate.resume()
        await submission.value
        #expect(editor == "reopened" && viewModel.alert == nil && viewModel.isSubmittingComment == false)
        #expect(service.detailCalls == 0 && service.commentRequests.isEmpty)
        #expect(await viewModel.submitComment(text: "retry", anonymous: false, rate: 6, target: .course(courseID: 42)))
        #expect(service.submitted?.1 == "retry" && service.detailCalls == 1)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheCourseEntryCancelsBothRequestsAndAllowsReentry() async {
        let service = Service()
        service.suspendRequests = true
        let viewModel = model(service)
        let entry = Task { await viewModel.bootstrapIfNeeded() }
        while service.enteredRequests.count < 2 { await Task.yield() }
        entry.cancel()
        await entry.value
        #expect(service.cancelledRequests == ["body", "comments"])
        #expect(viewModel.status == .idle && viewModel.commentState.status == .idle && viewModel.alert == nil)
        service.suspendRequests = false
        await viewModel.bootstrapIfNeeded()
        #expect(viewModel.status == .loaded && viewModel.commentState.status == .loaded)
        #expect(service.detailCalls == 2 && service.commentRequests.count == 2)
    }

    @Test func courseBootstrapRestoresItsCreditSourceAndLoadsEachInitialRequestOnce() async {
        let service = Service()
        service.commentResult = .success([Self.comment(1)])
        let viewModel = model(service)
        #expect(viewModel.resolvedCreditText == "3.5")
        await viewModel.bootstrapIfNeeded()
        await viewModel.bootstrapIfNeeded()
        #expect(service.detailCalls == 1 && service.commentRequests.count == 1)
        #expect(viewModel.status == .loaded && viewModel.commentState.status == .loaded)
        #expect(viewModel.resolvedCreditText == "4")
        #expect(viewModel.resolvedTeachersName == "教师" && viewModel.resolvedTeachersNumber == "T1")
        #expect(viewModel.resolvedRate == 8 && viewModel.sharedMaterialsURL != nil)
    }

    @Test func courseRefreshPreservesLoadedDataAcrossFailuresAndCancellation() async {
        let service = Service()
        service.commentResult = .success([Self.comment(1)])
        let viewModel = model(service)
        await viewModel.refresh()
        service.detailResult = .failure(URLError(.notConnectedToInternet))
        service.commentResult = .failure(URLError(.notConnectedToInternet))
        await viewModel.refresh()
        #expect(viewModel.course == Self.detail)
        #expect(viewModel.status == .loaded)
        #expect(viewModel.alert != nil)
        #expect(viewModel.commentState.items == [Self.comment(1)])
        #expect(viewModel.commentState.status == .loaded && viewModel.commentState.nextPage == 1 && viewModel.commentState.canLoadMore)
        viewModel.alert = nil
        service.detailResult = .failure(CancellationError())
        service.commentResult = .failure(CancellationError())
        await viewModel.refresh()
        #expect(viewModel.course == Self.detail)
        #expect(viewModel.alert == nil)
        #expect(viewModel.commentState.isLoadingMore == false)
        #expect(viewModel.commentState.items == [Self.comment(1)] && viewModel.commentState.canLoadMore)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func commentLikesConvergeWithConcurrentRefreshIncludingFailedReads(likeFinishesFirst: Bool, readFails: Bool) async {
        let service = Service()
        let comment = Self.comment(1, sub: [Self.comment(2)])
        service.commentResult = .success([comment])
        let viewModel = model(service)
        await viewModel.refresh()
        let readGate = Gate(), likeGate = Gate()
        service.commentReadGate = readGate; service.likeGate = likeGate
        if readFails { service.commentResult = .failure(URLError(.timedOut)) }
        let refresh = Task { await viewModel.refresh() }
        await readGate.waitForEntry()
        let like = Task { await viewModel.likeComment(comment.sub[0]) }
        await likeGate.waitForEntry()
        if likeFinishesFirst { likeGate.resume(); await like.value; readGate.resume(); await refresh.value }
        else { readGate.resume(); await refresh.value; likeGate.resume(); await like.value }
        #expect(viewModel.commentState.items.first?.sub.first?.like == true)
        #expect(viewModel.commentState.items.first?.sub.first?.likeNum == 9)
        #expect(viewModel.commentState.status == .loaded && viewModel.likingCommentIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func supersededCourseRefreshKeepsTheNewerDetail() async {
        let service = Service()
        let gate = Gate()
        service.firstDetailGate = gate
        let viewModel = model(service)
        let old = Task { await viewModel.refresh() }
        await gate.waitForEntry()
        service.detailResult = .success(Self.detail.updatingLike(true, likeNum: 77))
        await viewModel.refresh()
        gate.resume()
        await old.value
        #expect(viewModel.resolvedLikeNum == 77 && viewModel.isCourseLiked)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func successfulCourseLikeSurvivesAnOlderDetailRead(likeStartsFirst: Bool) async {
        let service = Service()
        let detailGate = Gate()
        let likeGate = Gate()
        service.firstDetailGate = detailGate
        let viewModel = model(service)
        var like: Task<Void, Never>?
        if likeStartsFirst {
            service.likeGate = likeGate
            like = Task { await viewModel.likeCourse() }
            await likeGate.waitForEntry()
        }
        let refresh = Task { await viewModel.refresh() }
        await detailGate.waitForEntry()
        if let like { likeGate.resume(); await like.value } else { await viewModel.likeCourse() }
        #expect(viewModel.isCourseLiked && viewModel.resolvedLikeNum == 9)
        detailGate.resume()
        await refresh.value
        #expect(viewModel.isCourseLiked && viewModel.resolvedLikeNum == 9)
        #expect(viewModel.resolvedName == Self.detail.name)
    }

    @Test func coursePagingDeduplicatesAndHistorySortingRetainsItsRetryPath() async {
        let service = Service()
        service.commentResult = .success([Self.comment(1), Self.comment(2)])
        service.pages[1] = [Self.comment(2), Self.comment(3)]
        service.pages[2] = []
        let viewModel = model(service)
        await viewModel.refresh()
        await viewModel.loadMoreCommentsIfNeeded(currentComment: viewModel.commentState.items.last)
        #expect(viewModel.commentState.items.map(\.id) == [1, 2, 3])
        await viewModel.loadMoreCommentsIfNeeded(currentComment: viewModel.commentState.items.last)
        #expect(viewModel.commentState.canLoadMore == false)
        service.historyResult = .failure(URLError(.timedOut))
        await viewModel.loadHistoryGradesIfNeeded()
        service.historyResult = .success([
            CourseHistoryGrade(term: "2025-2026-2", avgScore: 80, maxScore: 90, studentNum: 10),
            CourseHistoryGrade(term: "2026-2027-1", avgScore: 85, maxScore: 95, studentNum: 20)])
        await viewModel.loadHistoryGradesIfNeeded()
        #expect(viewModel.historyGradeStatus == .loaded)
        #expect(viewModel.historyGrades.map(\.term) == ["2026-2027-1", "2025-2026-2"])
        service.historyResult = .failure(CancellationError())
        await viewModel.reloadHistoryGrades()
        #expect(viewModel.historyGradeStatus == .loaded && viewModel.historyGrades.count == 2)
    }

    @Test func courseLikesAndReplySubmissionKeepTheNestedCommentIdentity() async {
        let service = Service()
        let child = Self.comment(2)
        let main = Self.comment(1, sub: [child])
        service.commentResult = .success([main])
        let viewModel = model(service)
        await viewModel.refresh()
        await viewModel.likeCourse()
        await viewModel.likeComment(child)
        #expect(viewModel.isCourseLiked && viewModel.resolvedLikeNum == 9)
        #expect(viewModel.commentState.items.first?.sub.first?.like == true)
        #expect(service.likedObjects == ["course42", "comment2"])
        #expect(await viewModel.submitComment(text: "  ", anonymous: false, rate: nil, target: .course(courseID: 42)) == false)
        #expect(service.submitted == nil)
        #expect(await viewModel.submitComment(text: " 回复 ", anonymous: true, rate: 8,
            target: .comment(mainComment: main, targetComment: child)))
        #expect(service.submitted?.0 == "comment1" && service.submitted?.1 == "回复")
        #expect(service.submitted?.2 == "comment2" && service.submitted?.3 == 7)
        #expect(service.submitted?.4 == true && service.submitted?.5 == 8)
        #expect(viewModel.isSubmittingComment == false)
    }

    @Test(arguments: [nil, 0, -1, 11] as [Int?])
    func courseReviewsRequireAnExplicitValidRating(_ rate: Int?) async {
        let service = Service()
        let viewModel = model(service)
        #expect(await viewModel.submitComment(text: "功能验收", anonymous: false, rate: rate, target: .course(courseID: 42)) == false)
        #expect(service.submitted == nil && viewModel.alert?.title == "请选择评分")
    }
}
