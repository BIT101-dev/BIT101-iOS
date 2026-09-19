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
    case comment(mainComment: GalleryComment, targetComment: GalleryComment)

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

    private func targetCommentDisplayName(_ comment: GalleryComment) -> String {
        comment.anonymous ? "匿名用户" : comment.user.nickname
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
    @Published private(set) var commentState = GalleryCommentState()
    @Published private(set) var historyGrades: [CourseHistoryGrade] = []
    @Published private(set) var historyGradeStatus: CourseHistoryGradeLoadStatus = .idle
    @Published private(set) var historyGradesAllowsDiagnostics = true
    @Published private(set) var likingCommentIDs: Set<Int> = []
    @Published private(set) var isSubmittingComment = false
    @Published var alert: AppAlert?

    let initialCourse: CourseSummary

    private let service: any CourseDetailServicing
    private var hasBootstrapped = false
    private var refreshGeneration = 0
    private var historyGeneration = 0

    init(initialCourse: CourseSummary, service: (any CourseDetailServicing)? = nil) {
        self.initialCourse = initialCourse
        self.service = service ?? CourseService()
    }

    var resolvedName: String {
        course?.name ?? initialCourse.name
    }

    var resolvedNumber: String {
        course?.number ?? initialCourse.number
    }

    var resolvedCreditText: String {
        guard let credit = course?.credit ?? initialCourse.credit ?? localScheduleCredit else {
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
        let courses = ScheduleCacheStore.load().courses

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
        await refresh()
    }

    /// 并行刷新课程详情和评论首屏。
    func refresh() async {
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
        handleCourseResult(resolvedCourseResult, previousStatus: previousStatus)

        let resolvedCommentResult = await commentResult
        guard refreshGeneration == generation else { return }
        handleCommentRefreshResult(resolvedCommentResult, previousState: previousCommentState)
    }

    func loadMoreCommentsIfNeeded(currentComment: GalleryComment?) async {
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
            commentState.appendPage(comments)
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
        let generation = refreshGeneration
        isLikingCourse = true
        defer { isLikingCourse = false }

        do {
            let result = try await service.like(objectID: "course\(initialCourse.id)")
            guard refreshGeneration == generation else { return }
            if let course {
                self.course = course.updatingLike(result.like, likeNum: result.likeNum)
            } else {
                self.course = fallbackCourseDetail(like: result.like, likeNum: result.likeNum)
            }
        } catch {
            guard refreshGeneration == generation else { return }
            if isCourseDetailCancellation(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    func likeComment(_ comment: GalleryComment) async {
        guard !likingCommentIDs.contains(comment.id) else { return }
        let generation = refreshGeneration
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.like(objectID: "comment\(comment.id)")
            guard refreshGeneration == generation else { return }
            commentState.items = commentState.items.updatingLike(for: comment.id, like: result.like, likeNum: result.likeNum)
        } catch {
            guard refreshGeneration == generation else { return }
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

        isSubmittingComment = true
        defer { isSubmittingComment = false }

        do {
            _ = try await service.createComment(
                objectID: target.objectID,
                text: trimmed,
                replyObjectID: target.replyObjectID,
                replyUID: target.replyUID,
                anonymous: anonymous,
                rate: rate
            )
            await refresh()
            return true
        } catch {
            if isCourseDetailCancellation(error) { return false }
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

    private func handleCourseResult(_ result: Result<CourseDetail, Error>, previousStatus: CourseDetailLoadStatus) {
        switch result {
        case let .success(course):
            self.course = course
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
        _ result: Result<[GalleryComment], Error>,
        previousState: GalleryCommentState
    ) {
        switch result {
        case let .success(comments):
            commentState.applyFirstPage(comments)
            commentState.status = .loaded
        case let .failure(error):
            if isCourseDetailCancellation(error) {
                var restoredState = previousState
                restoredState.isLoadingMore = false
                if !restoredState.items.isEmpty {
                    restoredState.status = .loaded
                } else if case .loading = restoredState.status {
                    restoredState.status = .idle
                }
                commentState = restoredState
                return
            }

            commentState.status = .failed(error.localizedDescription)
            commentState.canLoadMore = false
            commentState.isLoadingMore = false
            alert = AppAlert(title: "加载评论失败", message: error.localizedDescription)
        }
    }

    private func resetCommentStateForRefresh() {
        commentState.status = .loading
        commentState.resetPagination()
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

    private func loadResult<T>(_ operation: @escaping () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}

private extension Array where Element == GalleryComment {
    func updatingLike(for commentID: Int, like: Bool, likeNum: Int) -> [GalleryComment] {
        map { comment in
            let updatedSub = comment.sub.updatingLike(for: commentID, like: like, likeNum: likeNum)
            let updated = comment.replacingSubComments(updatedSub)
            if updated.id == commentID {
                return updated.updatingLike(like, likeNum: likeNum)
            }
            return updated
        }
    }
}
