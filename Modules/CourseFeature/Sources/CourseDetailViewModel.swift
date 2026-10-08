import TransportCore
import CommunityCore
import DesignSystemKit
import Combine
import Foundation

private func isCourseDetailCancellation(_ error: Error) -> Bool {
    TaskCancellation.matches(error)
}

/// 课程评论输入目标。
///
/// 顶层评论直接挂在课程对象下；回复评论则同时记录“主评论”和“当前回复目标”，
/// 这样既能正确决定提交对象，也能在 UI 上还原“回复谁”的文案。
enum CourseCommentComposerTarget: Identifiable, Equatable {
    case course(courseID: Int)
    case comment(mainComment: CommunityComment, targetComment: CommunityComment)

    var id: String {
        switch self {
        case let .course(courseID):
            return "course-\(courseID)"
        case let .comment(mainComment, targetComment):
            return "comment-\(mainComment.id)-\(targetComment.id)"
        }
    }

    var title: String {
        switch self {
        case .course:
            return "发表评论"
        case let .comment(_, targetComment):
            return "回复 @\(targetCommentDisplayName(targetComment))"
        }
    }

    var placeholder: String {
        switch self {
        case .course:
            return "写点什么吧"
        case let .comment(_, targetComment):
            return "回复 @\(targetCommentDisplayName(targetComment))"
        }
    }

    private func targetCommentDisplayName(_ comment: CommunityComment) -> String {
        comment.anonymous ? AppUserPresentation.anonymousName : comment.user.nickname
    }

    var objectID: String {
        switch self {
        case let .course(courseID):
            return "course\(courseID)"
        case let .comment(mainComment, _):
            return "comment\(mainComment.id)"
        }
    }

    var replyObjectID: String? {
        switch self {
        case .course:
            return nil
        case let .comment(mainComment, targetComment):
            guard mainComment.id != targetComment.id else { return nil }
            return "comment\(targetComment.id)"
        }
    }

    var replyUID: Int? {
        switch self {
        case .course:
            return nil
        case let .comment(mainComment, targetComment):
            guard mainComment.id != targetComment.id, targetComment.user.id > 0 else { return nil }
            return targetComment.user.id
        }
    }
}

@MainActor
final class CourseDetailViewModel: ObservableObject {
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
    private var latestLikeResult: CommunityLikeResult?
    private var refreshGeneration = 0
    private var historyGeneration = 0
    private var cachedCourseCredits: [CommunityCourseCredit] = []
    private let loadCourseCredits: @MainActor () async -> [CommunityCourseCredit]

    init(initialCourse: CourseSummary, service: any CourseDetailServicing, loadCourseCredits: @escaping @MainActor () async -> [CommunityCourseCredit]) {
        self.initialCourse = initialCourse
        self.service = service
        self.loadCourseCredits = loadCourseCredits
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
           let course = courses.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name && $0.credit > 0 }) {
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

    var sharedMaterialsURL: URL? {
        courseExternalURL()
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        cachedCourseCredits = await loadCourseCredits()
        await refresh()
        if status == .idle || commentState.status == .idle { hasBootstrapped = false }
    }

    /// 并行刷新课程详情和评论首屏。
    func refresh() async {
        let likeRevisionAtStart = likeRevision
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let hadCourse = course != nil
        let previousStatus = status
        let previousCommentState = commentState
        if !hadCourse {
            status = .loading
        }
        resetCommentStateForRefresh()

        async let courseResult = loadResult { [self] in
            try await self.service.fetchCourse(id: self.initialCourse.id)
        }
        async let commentResult = loadResult { [self] in
            try await self.service.fetchComments(courseID: self.initialCourse.id, page: nil)
        }

        let resolvedCourseResult = await courseResult
        guard refreshGeneration == generation else { return }
        handleCourseResult(resolvedCourseResult, previousStatus: previousStatus, likeRevisionAtStart: likeRevisionAtStart)

        let resolvedCommentResult = await commentResult
        guard refreshGeneration == generation else { return }
        handleCommentRefreshResult(resolvedCommentResult, previousState: previousCommentState)
    }

    func loadMoreCommentsIfNeeded(currentComment: CommunityComment?) async {
        guard let currentComment else { return }
        let generation = refreshGeneration
        guard
            commentState.status == .loaded,
            !commentState.isLoadingMore,
            commentState.canLoadMore,
            commentState.items.suffix(4).contains(where: { $0.id == currentComment.id })
        else {
            return
        }

        let nextPage = commentState.nextPage
        let likeRevisionAtStart = commentState.likeRevision
        commentState.isLoadingMore = true
        defer {
            if refreshGeneration == generation {
                commentState.isLoadingMore = false
            }
        }

        let result = await loadResult { [self] in
            try await self.service.fetchComments(courseID: self.initialCourse.id, page: nextPage)
        }

        switch result {
        case let .success(comments):
            guard refreshGeneration == generation else { return }
            commentState.appendPage(commentState.applyingLikes(to: comments, since: likeRevisionAtStart))
        case let .failure(error):
            guard refreshGeneration == generation else { return }
            if isCourseDetailCancellation(error) { return }
            alert = AppAlert(title: "加载更多评论失败", message: error.localizedDescription)
        }
    }

    func loadHistoryGradesIfNeeded() async {
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
            if isCourseDetailCancellation(error) {
                historyGradeStatus = historyGrades.isEmpty ? .idle : .loaded
                return
            }
            historyGradeStatus = .failed(error.localizedDescription)
        }
    }

    func likeCourse() async {
        guard !isLikingCourse else { return }
        isLikingCourse = true
        defer { isLikingCourse = false }

        do {
            let result = try await service.like(objectID: "course\(initialCourse.id)")
            try Task.checkCancellation()
            likeRevision &+= 1
            latestLikeResult = result
            if let course {
                self.course = course.updatingLike(result.like, likeNum: result.likeNum)
            } else {
                self.course = fallbackCourseDetail(like: result.like, likeNum: result.likeNum)
            }
        } catch {
            if isCourseDetailCancellation(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    func likeComment(_ comment: CommunityComment) async {
        guard !likingCommentIDs.contains(comment.id) else { return }
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.like(objectID: "comment\(comment.id)")
            try Task.checkCancellation()
            commentState.recordLike(result, for: comment.id)
        } catch {
            if isCourseDetailCancellation(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    func submitComment(text: String, anonymous: Bool, rate: Int?, target: CourseCommentComposerTarget) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alert = AppAlert.userInput(title: "发送失败", message: "评论不能为空。")
            return false
        }
        guard !isSubmittingComment else { return false }
        if case .course = target, !(1 ... 10).contains(rate ?? 0) {
            alert = AppAlert.userInput(title: "请选择评分", message: "课程评价需要选择 0.5 至 5 星评分。")
            return false
        }

        isSubmittingComment = true
        defer { isSubmittingComment = false }

        do {
            try Task.checkCancellation()
            _ = try await service.createComment(
                objectID: target.objectID,
                text: trimmed,
                replyObjectID: target.replyObjectID,
                replyUID: target.replyUID,
                anonymous: anonymous,
                rate: rate
            )
            try Task.checkCancellation()
            await refresh()
            try Task.checkCancellation()
            return true
        } catch {
            if Task.isCancelled || isCourseDetailCancellation(error) { return false }
            alert = AppAlert(title: "发送失败", message: error.localizedDescription)
            return false
        }
    }

    /// 详情首屏还没回来时，点赞仍然需要一个最小可展示的详情快照承接状态。
    private func fallbackCourseDetail(like: Bool, likeNum: Int) -> CourseDetail {
        CourseDetail(
            id: initialCourse.id,
            name: initialCourse.name,
            number: initialCourse.number,
            credit: initialCourse.credit,
            likeNum: likeNum,
            commentNum: initialCourse.commentNum,
            rate: initialCourse.rate,
            teachersName: initialCourse.teachersName,
            teachersNumber: initialCourse.teachersNumber,
            like: like
        )
    }

    private func handleCourseResult(_ result: Result<CourseDetail, Error>, previousStatus: CourseDetailLoadStatus, likeRevisionAtStart: Int) {
        switch result {
        case let .success(course):
            if likeRevision != likeRevisionAtStart, let latestLikeResult {
                self.course = course.updatingLike(latestLikeResult.like, likeNum: latestLikeResult.likeNum)
            } else {
                self.course = course
                latestLikeResult = nil
            }
            status = .loaded
        case let .failure(error):
            if isCourseDetailCancellation(error) {
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
                alert = AppAlert(title: "刷新课程详情失败", message: error.localizedDescription)
                return
            }

            status = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载课程详情失败", message: error.localizedDescription)
        }
    }

    private func handleCommentRefreshResult(
        _ result: Result<[CommunityComment], Error>,
        previousState: CommunityCommentState
    ) {
        switch result {
        case let .success(comments):
            commentState.applyFirstPage(commentState.applyingLikes(to: comments, since: previousState.likeRevision))
            commentState.status = .loaded
        case let .failure(error):
            let cancelled = isCourseDetailCancellation(error)
            commentState.restoreAfterRefreshFailure(previousState, failureStatus: cancelled ? nil : .failed(error.localizedDescription))
            if cancelled { return }
            alert = AppAlert(title: "加载评论失败", message: error.localizedDescription)
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
