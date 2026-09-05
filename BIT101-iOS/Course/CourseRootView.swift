//
//  CourseRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import SwiftUI

/// 课程页根视图。
///
/// 当前版本提供课程浏览和详情入口。
struct CourseRootView: View {
    @StateObject private var viewModel: CourseListViewModel

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: CourseListViewModel())
    }

    @MainActor
    init(viewModel: CourseListViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        CoursePageContent(viewModel: viewModel)
    }
}

/// 课程页具体内容。
///
/// 独立出来后，既能继续作为单独页面使用，也能被“成绩 / 课程”合并页复用。
struct CoursePageContent: View {
    @ObservedObject var viewModel: CourseListViewModel

    init(viewModel: CourseListViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Group {
            switch viewModel.state.status {
            case .idle where viewModel.state.items.isEmpty,
                 .loading where viewModel.state.items.isEmpty:
                AppLoadingState(title: viewModel.hasActiveSearch ? "正在搜索课程" : "正在加载课程")
                    .background(AppDesignSystem.Palette.groupedBackground)

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
                .background(AppDesignSystem.Palette.groupedBackground)

            default:
                List {
                    Section {
                        CourseSearchRow(
                            text: $viewModel.searchText,
                            onSubmit: {
                                Task {
                                    await viewModel.submitSearch()
                                }
                            },
                            onClear: {
                                let previousText = viewModel.searchText
                                viewModel.searchText = ""
                                viewModel.clearSearchIfNeeded(from: previousText, to: viewModel.searchText)
                            }
                        )
                    }

                    Section{
                        courseSection
                    }
                }
                .appGroupedListStyle()
                .background(AppDesignSystem.Palette.groupedBackground)
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .onChange(of: viewModel.searchText) { oldValue, newValue in
            viewModel.clearSearchIfNeeded(from: oldValue, to: newValue)
        }
        .diagnosticAlert(item: $viewModel.alert)
        .background(AppDesignSystem.Palette.groupedBackground)
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
                    CourseDetailView(initialCourse: course)
                } label: {
                    CourseListRow(course: course)
                }
                .buttonStyle(.plain)
                .task {
                    await viewModel.loadMoreIfNeeded(currentCourse: course)
                }
            }

            if viewModel.state.isLoadingMore {
                AppInlineLoadingState()
            }
        }
    }
}

/// 日程、成绩和外部深链统一使用的课程解析流程。
///
/// 所有入口先通过同一个解析器确认课程，再进入同一个 `CourseDetailView`。
struct CourseEvaluationRouteResolver {
    private let listService: any CourseListServicing
    private let detailService: any CourseDetailServicing

    init(
        listService: any CourseListServicing = CourseService(),
        detailService: any CourseDetailServicing = CourseService()
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
/// 先解析，成功后才执行各自的后续路由；失败直接在当前页面展示 alert。
struct CourseEvaluationLink: View {
    let request: CourseNavigationRequest
    let onResolved: (CourseNavigationRequest) -> Void
    @State private var isResolving = false
    @State private var alert: AppAlert?
    @State private var diagnosticAlert: AppAlert?

    init(
        request: CourseNavigationRequest,
        onResolved: @escaping (CourseNavigationRequest) -> Void
    ) {
        self.request = request
        self.onResolved = onResolved
    }

    var body: some View {
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
            onResolved(try await CourseEvaluationRouteResolver().resolve(request))
        } catch {
            if TaskCancellation.matches(error) { return }
            if error is CourseEvaluationError {
                alert = AppAlert(title: "无法打开课程评价", message: error.localizedDescription)
            } else {
                diagnosticAlert = AppAlert(title: "课程评价加载失败", message: error.localizedDescription)
            }
        }
    }
}

/// 外部深链使用的课程评价目的地。
///
/// 外部深链已经发生导航，因此保留页面级加载/失败态；日程和成绩的普通入口
/// 使用 `CourseEvaluationLink`，在导航前就地处理失败。
struct CourseEvaluationDestination: View {
    let request: CourseNavigationRequest
    @State private var course: CourseSummary?
    @State private var errorMessage: String?
    @State private var expectedErrorMessage: String?
    @State private var expectedAlert: AppAlert?

    var body: some View {
        Group {
            if let course {
                CourseDetailView(initialCourse: course)
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
        .background(AppDesignSystem.Palette.groupedBackground)
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
            let resolvedRequest = try await CourseEvaluationRouteResolver().resolve(request)
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
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: AppDesignSystem.Spacing.control) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("在这里搜索课程哦", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 课程列表紧凑行。
private struct CourseListRow: View {
    let course: CourseSummary

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignSystem.Spacing.tight) {
            AppFixedColumnRow(
                items: [
                    AppFixedColumnItem(
                        text: course.name.isEmpty ? "未命名课程" : course.name,
                        ratio: 0.64,
                        font: .headline,
                        color: .primary
                    ),
                    AppFixedColumnItem(
                        text: CourseRatingText.text(from: course.rate, empty: "-"),
                        ratio: 0.16,
                        font: .subheadline.weight(.semibold),
                        color: AppDesignSystem.Palette.highlight,
                        alignment: .trailing
                    ),
                    AppFixedColumnItem(
                        text: "\(course.commentNum)评",
                        ratio: 0.20,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: AppDesignSystem.Size.compactRow.primaryHeight
            )

            AppFixedColumnRow(
                items: [
                    AppFixedColumnItem(
                        text: course.number.isEmpty ? "-" : course.number,
                        ratio: 0.30,
                        font: .caption,
                        color: .secondary
                    ),
                    AppFixedColumnItem(
                        text: course.teachersName.isEmpty ? "-" : course.teachersName,
                        ratio: 0.45,
                        font: .caption,
                        color: .secondary
                    ),
                    AppFixedColumnItem(
                        text: "\(course.likeNum)赞",
                        ratio: 0.25,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: AppDesignSystem.Size.compactRow.secondaryHeight
            )
        }
    }
}
