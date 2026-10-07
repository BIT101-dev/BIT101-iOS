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
        func fetchCourse(id: Int) async throws -> CourseDetail {
            detailCalls += 1
            let captured = detailResult
            if let gate = firstDetailGate { firstDetailGate = nil; await gate.pause() }
            return try captured.get()
        }
        func fetchCourseHistories(number: String) async throws -> [CourseHistoryGrade] { try historyResult.get() }
        func fetchComments(courseID: Int, page: Int?) async throws -> [CommunityComment] {
            commentRequests.append(page)
            return try page.flatMap { pages[$0] } ?? commentResult.get()
        }
        func like(objectID: String) async throws -> CommunityLikeResult {
            likedObjects.append(objectID)
            return CommunityLikeResult(like: true, likeNum: 9)
        }
        func createComment(objectID: String, text: String, replyObjectID: String?, replyUID: Int?, anonymous: Bool, rate: Int?) async throws -> CommunityComment {
            submitted = (objectID, text, replyObjectID, replyUID, anonymous, rate)
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
        viewModel.alert = nil
        service.detailResult = .failure(CancellationError())
        service.commentResult = .failure(CancellationError())
        await viewModel.refresh()
        #expect(viewModel.course == Self.detail)
        #expect(viewModel.alert == nil)
        #expect(viewModel.commentState.isLoadingMore == false)
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
}
