//
//  CourseDetailViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

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
            return "回复 @\(targetComment.user.nickname)"
        }
    }

    var placeholder: String {
        switch self {
        case .course:
            return "写点什么吧"
        case let .comment(_, targetComment):
            return "回复 @\(targetComment.user.nickname)"
        }
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
            guard mainComment.id != targetComment.id else { return nil }
            return targetComment.user.id
        }
    }
}

@MainActor
/// 课程详情状态机。
final class CourseDetailViewModel: ObservableObject {
    @Published private(set) var course: CourseDetail?
    @Published private(set) var status: CourseDetailLoadStatus = .idle
    @Published private(set) var isLikingCourse = false
    @Published private(set) var commentState = GalleryCommentState()
    @Published private(set) var historyGrades: [CourseHistoryGrade] = []
    @Published private(set) var historyGradeStatus: CourseHistoryGradeLoadStatus = .idle
    @Published private(set) var likingCommentIDs: Set<Int> = []
    @Published private(set) var isSubmittingComment = false
    @Published var alert: AppAlert?

    let initialCourse: CourseSummary

    private let service: any CourseDetailServicing
    private var hasBootstrapped = false

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
        let hadCourse = course != nil
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

        handleCourseResult(await courseResult, hadCourse: hadCourse)
        handleCommentRefreshResult(await commentResult)
    }

    func loadMoreCommentsIfNeeded(currentComment: GalleryComment?) async {
        guard let currentComment else { return }
        guard
            commentState.status == .loaded,
            !commentState.isLoadingMore,
            commentState.canLoadMore,
            commentState.items.suffix(4).contains(where: { $0.id == currentComment.id })
        else {
            return
        }

        commentState.isLoadingMore = true
        defer { commentState.isLoadingMore = false }

        let nextPage = commentState.nextPage
        let result = await loadResult { [self] in
            try await self.service.fetchComments(courseID: self.initialCourse.id, page: nextPage)
        }

        switch result {
        case let .success(comments):
            commentState.items.append(contentsOf: comments)
            commentState.nextPage += 1
            commentState.canLoadMore = !comments.isEmpty
        case let .failure(error):
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
        let number = resolvedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else {
            historyGradeStatus = .failed("课程号为空，无法加载历史成绩。")
            return
        }

        historyGradeStatus = .loading
        let result = await loadResult { [self] in
            try await self.service.fetchCourseHistories(number: number)
        }

        switch result {
        case let .success(grades):
            historyGrades = grades.sorted { lhs, rhs in
                lhs.term.localizedStandardCompare(rhs.term) == .orderedDescending
            }
            historyGradeStatus = .loaded
        case let .failure(error):
            if isCourseDetailCancellation(error) {
                historyGradeStatus = .idle
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

    func likeComment(_ comment: GalleryComment) async {
        guard !likingCommentIDs.contains(comment.id) else { return }
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.like(objectID: "comment\(comment.id)")
            commentState.items = commentState.items.updatingLike(for: comment.id, like: result.like, likeNum: result.likeNum)
        } catch {
            if isCourseDetailCancellation(error) { return }
            alert = AppAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    func submitComment(text: String, anonymous: Bool, rate: Int?, target: CourseCommentComposerTarget) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alert = AppAlert(title: "发送失败", message: "评论不能为空。")
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

    private func handleCourseResult(_ result: Result<CourseDetail, Error>, hadCourse: Bool) {
        switch result {
        case let .success(course):
            self.course = course
            status = .loaded
        case let .failure(error):
            if isCourseDetailCancellation(error) {
                if !hadCourse {
                    status = .idle
                }
                return
            }

            if hadCourse {
                status = .loaded
                alert = AppAlert(title: "刷新课程详情失败", message: error.localizedDescription)
                return
            }

            status = .failed(error.localizedDescription)
            alert = AppAlert(title: "加载课程详情失败", message: error.localizedDescription)
        }
    }

    private func handleCommentRefreshResult(_ result: Result<[GalleryComment], Error>) {
        switch result {
        case let .success(comments):
            commentState.items = comments
            commentState.status = .loaded
            commentState.nextPage = 1
            commentState.canLoadMore = !comments.isEmpty
            commentState.isLoadingMore = false
        case let .failure(error):
            if isCourseDetailCancellation(error) {
                commentState.status = .idle
                commentState.isLoadingMore = false
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
        commentState.items = []
        commentState.isLoadingMore = false
        commentState.nextPage = 0
        commentState.canLoadMore = true
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
