#if os(iOS)
import MediaKit
import CommunityUI
import TransportCore
import DesignSystemKit
import SwiftUI

/// 课程页具体内容，供独立页面和“成绩 / 课程”合并页使用。
public struct CoursePageContent: View {
    private let dependencies: CourseDependencies
    private let media: MediaEnvironment
    private let profiles: CommunityProfileDestination
    @ObservedObject var viewModel: CourseListViewModel

    public var body: some View {
        content.environment(dependencies)
    }

    private var content: some View {
        Group {
            switch viewModel.state.status {
            case .idle where viewModel.state.items.isEmpty,
                 .loading where viewModel.state.items.isEmpty:
                AppLoadingState(title: viewModel.hasActiveSearch ? "正在搜索课程" : "正在加载课程")
                    .background(AppDesignSystem.Palette.Background.grouped)

            case let .failed(message) where viewModel.state.items.isEmpty:
                AppFailureState(
                    title: viewModel.hasActiveSearch ? "搜索失败" : "加载失败",
                    systemImage: "books.vertical.circle",
                    message: message,
                    retryTitle: "重新加载",
                    onRetry: {
                        Task {
                            await viewModel.refresh()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppDesignSystem.Palette.Background.grouped)

            default:
                List {
                    Section {
                        CourseSearchRow(
                            text: $viewModel.searchText,
                            onSubmit: {
                                Task {
                                    await viewModel.submitSearch()
                                }
                            }
                        )
                    }

                    Section {
                        courseSection
                    }
                }
                .appGroupedListStyle()
                .background(AppDesignSystem.Palette.Background.grouped)
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .onChange(of: viewModel.searchText) { oldValue, newValue in
            viewModel.clearSearchIfNeeded(from: oldValue, to: newValue)
        }
        .diagnosticAlert(item: $viewModel.alert)
        .background(AppDesignSystem.Palette.Background.grouped)
    }

    @ViewBuilder
    private var courseSection: some View {
        if viewModel.state.items.isEmpty {
            if viewModel.hasActiveSearch {
                AppEmptyState(
                    title: "没有找到课程",
                    systemImage: "magnifyingglass",
                    message: "换个关键词试试。"
                )
                .frame(maxWidth: .infinity)
            } else {
                AppEmptyState(
                    title: "暂无课程",
                    systemImage: "books.vertical"
                )
                .frame(maxWidth: .infinity)
            }
        } else {
            ForEach(viewModel.state.items) { course in
                NavigationLink {
                    CourseDetailView(dependencies: dependencies, media: media, profiles: profiles, initialCourse: course)
                } label: {
                    CourseListRow(course: course)
                }
                .buttonStyle(.plain)
                .task {
                    await viewModel.loadMoreIfNeeded(currentCourse: course)
                }
                .appInteractiveListRow()
            }

            if viewModel.state.isLoadingMore {
                AppInlineLoadingState()
            }
        }
    }
    public init(viewModel: CourseListViewModel, dependencies: CourseDependencies, media: MediaEnvironment, profiles: CommunityProfileDestination) {
        self.dependencies = dependencies
        self.media = media
        self.profiles = profiles
        self.viewModel = viewModel
    }
}

/// 日程、成绩和外部深链统一使用的课程解析流程。
///
/// 所有入口先通过同一个解析器确认课程，再进入同一个 `CourseDetailView`。
struct CourseEvaluationRouteResolver {
    private let listService: any CourseListServicing
    private let detailService: any CourseDetailServicing

    init(
        listService: any CourseListServicing,
        detailService: any CourseDetailServicing
    ) {
        self.listService = listService
        self.detailService = detailService
    }

    func resolve(_ request: CourseNavigationRequest) async throws -> CourseNavigationRequest {
        if request.preparedCourse != nil {
            return request
        }

        if request.hasLookupIdentity {
            let name = request.lookupCourseName ?? ""
            let number = request.lookupCourseNumber ?? ""
            let teacher = request.lookupTeacher ?? ""
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CourseEvaluationError.missingIdentity
            }
            guard let lookup = try await CourseEvaluationResolver(service: listService).resolve(
                courseName: name,
                courseNumber: number,
                teacher: teacher
            ) else {
                throw CourseEvaluationError.notFound
            }
            return CourseNavigationRequest(
                courseID: lookup.selectedCourse.id,
                lookupCourseName: name,
                lookupCourseNumber: number,
                lookupTeacher: teacher,
                preparedCourse: lookup.selectedCourse,
                searchQuery: lookup.searchQuery,
                searchResults: lookup.searchResults
            )
        }

        guard request.courseID > 0 else {
            throw CourseEvaluationError.missingIdentity
        }
        return CourseNavigationRequest(
            courseID: request.courseID,
            preparedCourse: CourseSummary(detail: try await detailService.fetchCourse(id: request.courseID))
        )
    }
}

/// 日程和成绩共用的课程评价检索入口。
///
/// 解析成功后进入后续路由，解析失败时在当前页面展示 alert。
public struct CourseEvaluationLink: View {
    private let dependencies: CourseDependencies
    let request: CourseNavigationRequest
    let onResolved: (CourseNavigationRequest) -> Void
    @State private var isResolving = false
    @State private var alert: AppAlert?
    @State private var diagnosticAlert: AppAlert?

    public init(
        dependencies: CourseDependencies,
        request: CourseNavigationRequest,
        onResolved: @escaping (CourseNavigationRequest) -> Void
    ) {
        self.dependencies = dependencies
        self.request = request
        self.onResolved = onResolved
    }

    public var body: some View {
        Button {
            Task { await resolveAndNavigate() }
        } label: {
            AppCourseEvaluationRow(isLoading: isResolving)
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .diagnosticAlert(item: $diagnosticAlert)
    }

    private func resolveAndNavigate() async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }

        do {
            onResolved(try await CourseEvaluationRouteResolver(listService: dependencies.list, detailService: dependencies.detail).resolve(request))
        } catch {
            if TaskCancellation.matches(error) { return }
            if error is CourseEvaluationError {
                alert = AppAlert.userInput(title: "无法打开课程评价", message: error.localizedDescription)
            } else {
                diagnosticAlert = AppAlert(title: "课程评价加载失败", message: error.localizedDescription)
            }
        }
    }
}

/// 外部深链使用的课程评价目的地。
///
/// 外部深链在导航后加载课程并显示失败状态；日程和成绩入口使用
/// `CourseEvaluationLink`，在导航前处理失败。
public struct CourseEvaluationDestination: View {
    private let scene: CourseEvaluationScene
    private let identity: [ObjectIdentifier]
    private let requestID: UUID
    public init(dependencies: CourseDependencies, media: MediaEnvironment, profiles: CommunityProfileDestination, request: CourseNavigationRequest) {
        scene = CourseEvaluationScene(dependencies: dependencies, media: media, profiles: profiles, request: request)
        identity = [ObjectIdentifier(dependencies), ObjectIdentifier(media)]
        requestID = request.id
    }
    public var body: some View { scene.id(identity).id(requestID) }
}

private struct CourseEvaluationScene: View {
    private let dependencies: CourseDependencies
    private let media: MediaEnvironment
    private let profiles: CommunityProfileDestination
    let request: CourseNavigationRequest
    @State private var course: CourseSummary?
    @State private var errorMessage: String?
    @State private var expectedErrorMessage: String?
    @State private var expectedAlert: AppAlert?

    var body: some View {
        Group {
            if let course {
                CourseDetailView(dependencies: dependencies, media: media, profiles: profiles, initialCourse: course)
                    .id(course.id)
            } else if let expectedErrorMessage {
                AppEmptyState(
                    title: "未找到课程",
                    systemImage: "book.closed",
                    message: expectedErrorMessage
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                AppFailureState(
                    title: "无法打开课程评价",
                    systemImage: "book.closed",
                    message: errorMessage,
                    retryTitle: "重试",
                    onRetry: {
                        Task { await resolve() }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AppLoadingState(title: "正在加载课程评价")
            }
        }
        .background(AppDesignSystem.Palette.Background.grouped)
        .navigationTitle("课程评价")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $expectedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .task(id: request.id) {
            await resolve()
        }
    }

    private func resolve() async {
        course = nil
        errorMessage = nil
        expectedErrorMessage = nil
        expectedAlert = nil

        do {
            let resolvedRequest = try await CourseEvaluationRouteResolver(listService: dependencies.list, detailService: dependencies.detail).resolve(request)
            try Task.checkCancellation()
            guard let preparedCourse = resolvedRequest.preparedCourse else {
                throw CourseEvaluationError.notFound
            }
            course = preparedCourse
        } catch let error as CourseEvaluationError {
            expectedErrorMessage = error.localizedDescription
            expectedAlert = AppAlert(title: "无法打开课程评价", message: error.localizedDescription)
        } catch {
            if TaskCancellation.matches(error) { return }
            errorMessage = error.localizedDescription
        }
    }
    init(dependencies: CourseDependencies, media: MediaEnvironment, profiles: CommunityProfileDestination, request: CourseNavigationRequest) {
        self.dependencies = dependencies
        self.media = media
        self.profiles = profiles
        self.request = request
    }
}

private enum CourseEvaluationError: LocalizedError {
    case missingIdentity
    case notFound

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            return "课程记录缺少课程号和课程名。"
        case .notFound:
            return "学业课程中没有找到对应课程。"
        }
    }
}

/// 课程页顶部搜索栏。
private struct CourseSearchRow: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.regular) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppDesignSystem.Foreground.secondary)
                .accessibilityHidden(true)

            TextField("", text: $text, prompt: AppInputPrompt.text("在这里搜索课程哦"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppDesignSystem.Typography.body)
                        .foregroundStyle(AppDesignSystem.Foreground.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
    }
}

/// 课程列表紧凑行。
private struct CourseListRow: View {
    let course: CourseSummary

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tiny) {
            AppFixedColumnRow(
                items: [
                    AppFixedColumnItem(
                        text: course.name.isEmpty ? "未命名课程" : course.name,
                        ratio: 0.64,
                        font: AppDesignSystem.Typography.title,
                        color: AppDesignSystem.Foreground.primaryColor
                    ),
                    AppFixedColumnItem(
                        text: CourseRatingText.text(from: course.rate, empty: "-"),
                        ratio: 0.16,
                        font: AppDesignSystem.Typography.subheadlineEmphasis,
                        color: AppDesignSystem.Foreground.primaryColor,
                        alignment: .trailing
                    ),
                    AppFixedColumnItem(
                        text: "\(course.commentNum)评",
                        ratio: 0.20,
                        font: AppDesignSystem.Typography.caption,
                        color: AppDesignSystem.Foreground.secondaryColor,
                        alignment: .trailing
                    ),
                ],
                height: AppDesignSystem.Size.CompactRow.primaryHeight
            )

            AppFixedColumnRow(
                items: [
                    AppFixedColumnItem(
                        text: course.number.isEmpty ? "-" : course.number,
                        ratio: 0.30,
                        font: AppDesignSystem.Typography.caption,
                        color: AppDesignSystem.Foreground.secondaryColor
                    ),
                    AppFixedColumnItem(
                        text: course.teachersName.isEmpty ? "-" : course.teachersName,
                        ratio: 0.45,
                        font: AppDesignSystem.Typography.caption,
                        color: AppDesignSystem.Foreground.secondaryColor
                    ),
                    AppFixedColumnItem(
                        text: "\(course.likeNum)赞",
                        ratio: 0.25,
                        font: AppDesignSystem.Typography.caption,
                        color: AppDesignSystem.Foreground.secondaryColor,
                        alignment: .trailing
                    ),
                ],
                height: AppDesignSystem.Size.CompactRow.secondaryHeight
            )
        }
    }
}

#endif
