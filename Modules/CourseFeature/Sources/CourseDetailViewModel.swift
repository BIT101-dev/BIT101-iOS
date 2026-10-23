import CommunityUI
import TransportCore
import CommunityCore
import CommunityTransport
import DesignSystemKit
import Combine
import Foundation

@MainActor
final class CourseDetailViewModel: ObservableObject {
    let pendingOperations = CommunityDetailTasks()
    @Published private(set) var course: CourseDetail?
    @Published private(set) var status: CourseDetailLoadStatus = .idle
    @Published private(set) var isLikingCourse = false
    @Published private(set) var commentState = CommunityCommentState()
    @Published private(set) var historyGrades: [CourseHistoryGrade] = []
    @Published private(set) var historyGradeStatus: CourseHistoryGradeLoadStatus = .idle
    @Published private(set) var historyGradesAllowsDiagnostics = true
    @Published private(set) var likingCommentIDs: Set<Int> = []
    @Published private(set) var isSubmittingComment = false
    @Published var alert: AppAlert?

    let initialCourse: CourseSummary

    private let service: any CourseDetailServicing
    private var hasBootstrapped = false
    private var likeRevision = 0
    private var likeResultNeedsReview = false
    private var latestLikeResult: CommunityLikeResult?
    private var refreshGeneration = 0
    private var commentRefreshGeneration = 0
    private var historyGeneration = 0
    private var historyGradeNumber: String?
    private var cachedCourseCredits: [CommunityCourseCredit] = []
    private let loadCourseCredits: @MainActor () async -> [CommunityCourseCredit]

    init(initialCourse: CourseSummary, initialDetail: CourseDetail? = nil, service: any CourseDetailServicing, loadCourseCredits: @escaping @MainActor () async -> [CommunityCourseCredit]) {
        self.initialCourse = initialCourse
        self.service = service
        self.loadCourseCredits = loadCourseCredits
        course = initialDetail
        if initialDetail != nil { status = .loaded }
    }

    var resolvedName: String {
        course?.name ?? initialCourse.name
    }

    var resolvedNumber: String {
        course?.number ?? initialCourse.number
    }

    var resolvedCreditText: String {
        guard let credit = localScheduleCredit ?? course?.credit ?? initialCourse.credit else {
            return "-"
        }
        if credit.rounded() == credit {
            return String(format: "%.0f", credit)
        }
        return String(format: "%.1f", credit)
    }

    private var localScheduleCredit: Double? {
        let number = resolvedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = resolvedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let courses = cachedCourseCredits

        if !number.isEmpty,
           let course = courses.first(where: { $0.number.trimmingCharacters(in: .whitespacesAndNewlines) == number && $0.credit > 0 }) {
            return Double(course.credit)
        }

        if !name.isEmpty,
           let course = courses.first(where: {
               let candidateNumber = $0.number.trimmingCharacters(in: .whitespacesAndNewlines)
               return (number.isEmpty || candidateNumber.isEmpty)
                   && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name && $0.credit > 0
           }) {
            return Double(course.credit)
        }

        return nil
    }

    var resolvedTeachersName: String {
        let value = course?.teachersName ?? initialCourse.teachersName
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedTeachersNumber: String {
        let value = course?.teachersNumber ?? initialCourse.teachersNumber
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var resolvedRate: Double {
        course?.rate ?? initialCourse.rate
    }

    var resolvedLikeNum: Int {
        course?.likeNum ?? initialCourse.likeNum
    }

    var resolvedCommentNum: Int {
        course?.commentNum ?? initialCourse.commentNum
    }

    var isCourseLiked: Bool {
        course?.like ?? false
    }
    var hasKnownLikeState: Bool { course != nil }

    var sharedMaterialsURL: URL? {
        courseExternalURL()
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        cachedCourseCredits = await loadCourseCredits()
        if course != nil { await refreshComments() }
        else { await refresh() }
        if status == .idle || commentState.status == .idle { hasBootstrapped = false }
    }

    /// 并行刷新课程详情和评论首屏。
    func refresh() async {
        let likeRevisionAtStart = likeRevision
        refreshGeneration &+= 1
        commentRefreshGeneration &+= 1
        let generation = refreshGeneration
        let commentsGeneration = commentRefreshGeneration
        let hadCourse = course != nil
        let previousStatus = status
        let previousCommentState = commentState
        if !hadCourse {
            status = .loading
        }
        resetCommentStateForRefresh()

        async let courseRefresh: Void = { @MainActor [self] in
            let result = await loadResult { [self] in try await service.fetchCourse(id: initialCourse.id) }
            guard refreshGeneration == generation else { return }
            handleCourseResult(result, previousStatus: previousStatus, likeRevisionAtStart: likeRevisionAtStart)
        }()
        async let commentRefresh: Void = { @MainActor [self] in
            let result = await loadResult { [self] in try await service.fetchComments(courseID: initialCourse.id, page: nil) }
            guard commentRefreshGeneration == commentsGeneration else { return }
            handleCommentRefreshResult(result, previousState: previousCommentState)
        }()
        _ = await (courseRefresh, commentRefresh)
    }

    func refreshComments() async {
        commentRefreshGeneration &+= 1
        let generation = commentRefreshGeneration
        let previousState = commentState
        resetCommentStateForRefresh()
        let result = await loadResult { [self] in
            try await service.fetchComments(courseID: initialCourse.id, page: nil)
        }
        guard generation == commentRefreshGeneration else { return }
        handleCommentRefreshResult(result, previousState: previousState)
    }

    func loadMoreCommentsIfNeeded(currentComment: CommunityComment?) async {
        guard let currentComment else { return }
        let generation = commentRefreshGeneration
        guard
            commentState.status == .loaded,
            !commentState.isLoadingMore,
            commentState.canLoadMore,
            commentState.items.suffix(4).contains(where: { $0.id == currentComment.id })
        else {
            return
        }

        let likeRevisionAtStart = commentState.likeRevision
        commentState.isLoadingMore = true
        defer {
            if commentRefreshGeneration == generation {
                commentState.isLoadingMore = false
            }
        }

        let result = await loadResult { [self] in
            var progress = CommunityPageProgress<Int>()
            while true {
                let comments = try await self.service.fetchComments(courseID: self.initialCourse.id, page: commentState.nextPage)
                try Task.checkCancellation()
                guard commentRefreshGeneration == generation else { throw CancellationError() }
                try progress.record(comments.map(\.id), knownIDs: commentState.pagedItems.ids)
                if comments.isEmpty || comments.contains(where: { !commentState.pagedItems.ids.contains($0.id) }) { return comments }
                commentState.nextPage += 1
            }
        }

        switch result {
        case let .success(comments):
            guard commentRefreshGeneration == generation else { return }
            commentState.confirmRead(in: comments)
            commentState.appendPage(commentState.applyingLocalChanges(to: comments, since: likeRevisionAtStart))
            commentState.canLoadMore = !comments.isEmpty
            commentState.paginationError = nil
        case let .failure(error):
            guard commentRefreshGeneration == generation else { return }
            if TaskCancellation.matches(error) { return }
            commentState.paginationError = error.localizedDescription
            alert = AppAlert(title: "加载更多评论失败", error: error)
        }
    }

    func loadHistoryGradesIfNeeded() async {
        if historyGradeNumber != resolvedNumber.trimmingCharacters(in: .whitespacesAndNewlines) {
            await reloadHistoryGrades()
            return
        }
        switch historyGradeStatus {
        case .idle, .failed:
            break
        case .loading, .loaded:
            return
        }
        await reloadHistoryGrades()
    }

    func reloadHistoryGrades() async {
        historyGeneration &+= 1
        let generation = historyGeneration
        let number = resolvedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        historyGradeNumber = number
        guard !number.isEmpty else {
            historyGradesAllowsDiagnostics = false
            historyGradeStatus = .failed("课程号为空，无法加载历史成绩。")
            return
        }

        historyGradesAllowsDiagnostics = true
        historyGradeStatus = .loading
        let result = await loadResult { [self] in
            try await self.service.fetchCourseHistories(number: number)
        }

        guard historyGeneration == generation else { return }
        switch result {
        case let .success(grades):
            historyGrades = grades.sorted { lhs, rhs in
                lhs.term.localizedStandardCompare(rhs.term) == .orderedDescending
            }
            historyGradeStatus = .loaded
        case let .failure(error):
            if TaskCancellation.matches(error) {
                historyGradeStatus = historyGrades.isEmpty ? .idle : .loaded
                return
            }
            historyGradeStatus = .failed(error.localizedDescription)
        }
    }

    func likeCourse() async {
        guard hasKnownLikeState else { return }
        guard !likeResultNeedsReview else {
            alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage)
            return
        }
        guard !isLikingCourse else { return }
        isLikingCourse = true
        defer { isLikingCourse = false }

        do {
            let result = try await service.like(objectID: "course\(initialCourse.id)")
            likeRevision &+= 1
            latestLikeResult = result
            if let course {
                self.course = course.updatingLike(result.like, likeNum: result.likeNum)
            }
        } catch {
            if error is CommunityToggleOutcomeUnknown {
                likeResultNeedsReview = true
                await refresh()
                if likeResultNeedsReview { alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage) }
                return
            }
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "点赞失败", error: error)
        }
    }

    func likeComment(_ comment: CommunityComment) async {
        guard !commentState.likesNeedingReview.contains(comment.id) else {
            alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage)
            return
        }
        guard !likingCommentIDs.contains(comment.id) else { return }
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.like(objectID: "comment\(comment.id)")
            commentState.recordLike(result, for: comment.id)
        } catch {
            if error is CommunityToggleOutcomeUnknown {
                commentState.recordUncertainLike(for: comment.id)
                await refresh()
                if commentState.likesNeedingReview.contains(comment.id) { alert = AppAlert(title: "点赞结果待确认", message: CommunityToggleOutcomeUnknown.reviewMessage) }
                return
            }
            if TaskCancellation.matches(error) { return }
            alert = AppAlert(title: "点赞失败", error: error)
        }
    }

    var commentReview: CommunityCommentReviewActions {
        .init(needsReview: { self.commentState.needsReview($0) },
            acknowledge: { self.commentState.acknowledgeSubmissionReview($0) })
    }

    func submitComment(text: String, anonymous: Bool, rate: Int?, target: CommunityCommentComposerTarget) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alert = AppAlert.userInput(title: "发送失败", message: "评论不能为空。")
            return false
        }
        guard !isSubmittingComment else { return false }
        let submission = CommunityCommentSubmission(objectID: target.objectID, text: trimmed,
            anonymous: anonymous, replyObjectID: target.replyObjectID, replyUID: target.replyUID, rate: rate)
        guard !commentState.needsReview(submission) else {
            alert = AppAlert(title: "发送结果待确认", message: CommunityCreateOutcomeUnknown.commentReviewMessage)
            return false
        }
        if case .course = target, !(1 ... 10).contains(rate ?? 0) {
            alert = AppAlert.userInput(title: "请选择评分", message: "课程评价需要选择 0.5 至 5 星评分。")
            return false
        }

        isSubmittingComment = true
        defer { isSubmittingComment = false }

        do {
            try Task.checkCancellation()
            let created = try await service.createComment(
                objectID: target.objectID,
                text: trimmed,
                replyObjectID: target.replyObjectID,
                replyUID: target.replyUID,
                anonymous: anonymous,
                rate: rate
            )
            let parent: CommunityComment?
            if case let .comment(mainComment, _) = target { parent = mainComment } else { parent = nil }
            commentState.recordCreated(created, replyingTo: parent)
            pendingOperations.enqueue { [weak self] in await self?.refresh() }
            return true
        } catch {
            if error is CommunityCreateOutcomeUnknown {
                commentState.recordUncertainSubmission(submission)
                alert = AppAlert(title: "发送结果待确认", message: CommunityCreateOutcomeUnknown.commentReviewMessage)
                return false
            }
            if Task.isCancelled || TaskCancellation.matches(error) { return false }
            alert = AppAlert(title: "发送失败", error: error)
            return false
        }
    }

    /// 首屏详情与已确认的点赞结果共同更新当前课程状态。
    private func handleCourseResult(_ result: Result<CourseDetail, Error>, previousStatus: CourseDetailLoadStatus, likeRevisionAtStart: Int) {
        switch result {
        case let .success(course):
            likeResultNeedsReview = false
            if likeRevision != likeRevisionAtStart, let latestLikeResult {
                self.course = course.updatingLike(latestLikeResult.like, likeNum: latestLikeResult.likeNum)
            } else {
                self.course = course
                latestLikeResult = nil
            }
            status = .loaded
        case let .failure(error):
            if TaskCancellation.matches(error) {
                if course == nil {
                    status = previousStatus
                    if case .loading = previousStatus {
                        status = .idle
                    }
                } else {
                    status = .loaded
                }
                return
            }

            if course != nil {
                status = .loaded
                alert = AppAlert(title: "刷新课程详情失败", error: error)
                return
            }

            status = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载课程详情失败", error: error)
        }
    }

    private func handleCommentRefreshResult(
        _ result: Result<[CommunityComment], Error>,
        previousState: CommunityCommentState
    ) {
        switch result {
        case let .success(comments):
            commentState.confirmRead(in: comments)
            commentState.applyFirstPage(commentState.applyingLocalChanges(to: comments, since: previousState.likeRevision))
            commentState.canLoadMore = !comments.isEmpty
            commentState.paginationError = nil
            commentState.status = .loaded
        case let .failure(error):
            let cancelled = TaskCancellation.matches(error)
            commentState.restoreAfterRefreshFailure(previousState, failureStatus: cancelled ? nil : .failed(error.localizedDescription))
            if cancelled { return }
            alert = AppAlert(title: "加载评论失败", error: error)
        }
    }

    private func resetCommentStateForRefresh() {
        commentState.status = .loading
        commentState.isLoadingMore = false
    }

    private func courseExternalURL() -> URL? {
        let name = resolvedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = resolvedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !number.isEmpty else { return nil }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")

        guard let pathComponent = "\(name)-\(number)".addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }

        return URL(string: "https://onedrive.bit101.cn/zh-CN/course/\(pathComponent)")
    }

    private func loadResult<T: Sendable>(_ operation: @MainActor () async throws -> T) async -> Result<T, Error> {
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            return .success(value)
        } catch {
            return .failure(error)
        }
    }
}
