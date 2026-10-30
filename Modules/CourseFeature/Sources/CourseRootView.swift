#if os(iOS)
import MediaKit
import CommunityUI
import TransportCore
import DesignSystemKit
import SwiftUI

public struct CourseBrowserPage: View {
    @Binding private var selection: CourseNavigationRequest?
    private let viewModel: CourseListViewModel
    private let dependencies: CourseDependencies
    private let media: MediaEnvironment
    private let profiles: CommunityProfileDestination
    private let onSurfaceStep: ((Int) -> Void)?

    public init(viewModel: CourseListViewModel, dependencies: CourseDependencies, media: MediaEnvironment,
                profiles: CommunityProfileDestination, selection: Binding<CourseNavigationRequest?>,
                onSurfaceStep: ((Int) -> Void)? = nil) {
        self.viewModel = viewModel; self.dependencies = dependencies; self.media = media; self.profiles = profiles
        _selection = selection
        self.onSurfaceStep = onSurfaceStep
    }

    public var body: some View {
        AppBrowserLayout(selection: $selection, title: "选择一门课程", symbol: "books.vertical") {
            CoursePageContent(viewModel: viewModel, dependencies: dependencies, selection: Binding(
                get: { selection?.preparedCourse }, set: { course in
                    selection = course.map { CourseNavigationRequest(courseID: $0.id, preparedCourse: $0) }
                }))
            .simultaneousGesture(makeHorizontalSwitchGesture { onSurfaceStep?($0) })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("course.browse")
        } detail: { request in
            if let course = request.preparedCourse {
                CourseDetailView(dependencies: dependencies, media: media, profiles: profiles, initialCourse: course)
                    .id(course.id)
            } else {
                CourseEvaluationDestination(dependencies: dependencies, media: media, profiles: profiles, request: request)
            }
        }
    }
}

/// 课程列表与搜索由原生浏览分栏承载。
public struct CoursePageContent: View {
    @Environment(\.appPageIsVisible) private var isVisible
    @Environment(\.appInteractionEvidence) private var interactionEvidence
    private let dependencies: CourseDependencies
    @ObservedObject var viewModel: CourseListViewModel
    @Binding private var selection: CourseSummary?

    public var body: some View {
        content.environment(dependencies)
    }

    private var content: some View {
        List {
            Section { searchRow }.appGroupedSectionStyle()
            Section { courseSection }.appGroupedSectionStyle()
        }
        .accessibilityIdentifier("interaction.CoursePageContent.list")
        .appGroupedListStyle()
        .refreshable {
            interactionEvidence?("interaction.CoursePageContent.refreshable", "refresh")
            await viewModel.refresh()
        }
        .task(id: isVisible) {
            guard isVisible else { viewModel.cancelRefreshOperations(); return }
            await viewModel.bootstrapIfNeeded()
        }
        .onChange(of: viewModel.searchText) { oldValue, newValue in
            viewModel.clearSearchIfNeeded(from: oldValue, to: newValue)
        }
        .communityReadRecovery(networkPath: dependencies.networkPath, isEnabled: isVisible) {
            await viewModel.retryAfterConnectivityRecovery()
        }
        .onDisappear { viewModel.cancelRefreshOperations() }
        .diagnosticAlert(item: $viewModel.alert)
        .background(AppDesignSystem.Palette.Background.grouped)
    }

    private var searchRow: some View {
        CourseSearchRow(text: $viewModel.searchText, onSubmit: { Task { await viewModel.submitSearch() } })
    }

    @ViewBuilder
    private var courseSection: some View {
        CommunityResultsContext(viewModel.displayedQueryDescription)
        switch viewModel.state.status {
        case .idle where viewModel.state.items.isEmpty, .loading where viewModel.state.items.isEmpty:
            AppLoadingState(title: viewModel.hasActiveSearch ? "正在搜索课程" : "正在加载课程")
        case let .failed(message) where viewModel.state.items.isEmpty:
            AppFailureState(title: viewModel.hasActiveSearch ? "搜索失败" : "加载失败",
                systemImage: "books.vertical.circle", message: message, retryTitle: "重新加载",
                underlyingError: viewModel.state.failureCause,
                onRetry: { Task { await viewModel.refresh() } })
        default:
            courseResults
        }
    }

    @ViewBuilder
    private var courseResults: some View {
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
                AppBrowserListRow(isSelected: selection?.id == course.id, action: { selection = course }) {
                    CourseListRow(course: course)
                }
                .task(id: viewModel.state.status == .loaded ? viewModel.state.nextPage : nil) {
                    await viewModel.loadMoreIfNeeded(currentCourse: course)
                }
                .accessibilityIdentifier("ui.course-page-content.course")
            }

            CommunityPaginationFooter(isLoading: viewModel.state.isLoadingMore,
                errorMessage: viewModel.state.paginationError) {
                await viewModel.loadMoreIfNeeded(currentCourse: viewModel.state.items.last)
            }
        }
    }
    public init(viewModel: CourseListViewModel, dependencies: CourseDependencies, selection: Binding<CourseSummary?>) {
        self.dependencies = dependencies
        self.viewModel = viewModel
        _selection = selection
    }
}

/// 日程和成绩共用的课程评价检索入口。
///
/// 解析成功后进入详情，检索失败时提供保留条件的课程搜索入口。
public struct CourseEvaluationLink: View {
    private let scene: CourseEvaluationLinkScene
    private let dependencyID: ObjectIdentifier
    private let requestID: UUID

    public init(dependencies: CourseDependencies, request: CourseNavigationRequest,
        onResolved: @escaping (CourseNavigationRequest) -> Void) {
        scene = CourseEvaluationLinkScene(dependencies: dependencies, request: request, onResolved: onResolved)
        dependencyID = ObjectIdentifier(dependencies)
        requestID = request.id
    }

    public var body: some View { scene.id(dependencyID).id(requestID) }
}

private struct CourseEvaluationLinkScene: View {
    private let dependencies: CourseDependencies
    let request: CourseNavigationRequest
    let onResolved: (CourseNavigationRequest) -> Void
    @State private var isResolving = false
    @State private var alert: AppAlert?
    @State private var diagnosticAlert: AppAlert?
    @State private var canSearch = false
    @State private var searchRecovery: CourseNavigationRequest?

    init(
        dependencies: CourseDependencies,
        request: CourseNavigationRequest,
        onResolved: @escaping (CourseNavigationRequest) -> Void
    ) {
        self.dependencies = dependencies
        self.request = request
        self.onResolved = onResolved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.regular) {
            Button {
                isResolving = true
            } label: {
                AppCourseEvaluationRow(isLoading: isResolving)
            }
            .buttonStyle(.plain)
            .disabled(isResolving)
            .task(id: isResolving) {
                guard isResolving else { return }
                await resolveAndNavigate()
            }
            .onDisappear { isResolving = false }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("知道了"))
                )
            }
            .diagnosticAlert(item: $diagnosticAlert)
            .accessibilityIdentifier("ui.course-evaluation-link.open")
            if canSearch {
                Button("搜索课程") {
                    if let searchRecovery { onResolved(searchRecovery); return }
                    let name = request.lookupCourseName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    onResolved(.search(query: name.isEmpty ? (request.lookupCourseNumber ?? "") : name))
                }
                .appInteractiveListRow()
                .accessibilityIdentifier("course.evaluation.search")
            }
        }
    }

    private func resolveAndNavigate() async {
        defer { isResolving = false }
        searchRecovery = nil

        do {
            let resolved = try await CourseEvaluationRouteResolver(listService: dependencies.list, detailService: dependencies.detail).resolve(request)
            try Task.checkCancellation()
            onResolved(resolved)
        } catch {
            if Task.isCancelled || TaskCancellation.matches(error) { return }
            canSearch = request.hasLookupIdentity
            if let recovery = error as? CourseEvaluationSearchRecovery {
                searchRecovery = CourseNavigationRequest(courseID: 0, searchQuery: recovery.query, searchResults: recovery.items)
            }
            if error is CourseEvaluationError {
                alert = AppAlert.userInput(title: "无法打开课程评价", message: error.localizedDescription)
            } else {
                diagnosticAlert = AppAlert(title: "课程评价加载失败",
                    error: (error as? CourseEvaluationSearchRecovery)?.underlying ?? error)
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
    @State private var preparedDetail: CourseDetail?
    @State private var errorMessage: String?
    @State private var expectedErrorMessage: String?
    @State private var expectedAlert: AppAlert?

    var body: some View {
        Group {
            if let course {
                CourseDetailView(dependencies: dependencies, media: media, profiles: profiles, initialCourse: course, initialDetail: preparedDetail)
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
        preparedDetail = nil
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
            preparedDetail = resolvedRequest.preparedDetail
        } catch let error as CourseEvaluationError {
            expectedErrorMessage = error.localizedDescription
            expectedAlert = AppAlert(title: "无法打开课程评价", error: error)
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

/// 课程页顶部搜索栏。
private struct CourseSearchRow: View {
    @Environment(\.appInteractionEvidence) private var interactionEvidence
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
                .onSubmit {
                    interactionEvidence?("interaction.CourseSearchRow.onSubmit", "submit")

                    onSubmit()
                }

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
                    .accessibilityIdentifier("ui.course-search-row.清除搜索")
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
