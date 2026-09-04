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
    @Binding var requestedCourse: CourseNavigationRequest?
    @State private var deepLinkedCourse: CourseSummary?
    @State private var deepLinkAlert: AppAlert?

    init(
        viewModel: CourseListViewModel,
        requestedCourse: Binding<CourseNavigationRequest?> = .constant(nil)
    ) {
        self.viewModel = viewModel
        _requestedCourse = requestedCourse
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
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if requestedCourse == nil {
                await viewModel.bootstrapIfNeeded()
            }
        }
        .onChange(of: viewModel.searchText) { oldValue, newValue in
            viewModel.clearSearchIfNeeded(from: oldValue, to: newValue)
        }
        .diagnosticAlert(item: $viewModel.alert)
        .diagnosticAlert(item: $deepLinkAlert)
        .navigationDestination(item: $deepLinkedCourse) { course in
            CourseDetailView(initialCourse: course)
                // 课程详情页持有自己的 StateObject；切换课程时强制按课程 ID 重建，
                // 避免在已有详情页上复用上一门课的评论状态。
                .id(course.id)
        }
        .task(id: requestedCourse?.id) {
            await openRequestedCourseIfNeeded()
        }
        .background(AppDesignSystem.Palette.groupedBackground)
    }

    private func openRequestedCourseIfNeeded() async {
        guard let request = requestedCourse else { return }

        if let query = request.searchQuery,
           let results = request.searchResults
        {
            viewModel.applyPreparedSearch(query: query, items: results)
        }

        if let preparedCourse = request.preparedCourse {
            deepLinkedCourse = preparedCourse
        } else if request.hasLookupIdentity {
            do {
                let number = (request.lookupCourseNumber ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (request.lookupCourseName ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let search = number.isEmpty ? name : number
                guard !search.isEmpty else {
                    throw CourseLookupError.missingIdentity
                }
                let candidates = try await CourseService().fetchCourses(search: search, page: 0)
                guard let course = CourseLookupMatcher.bestMatch(
                    courseNumber: number,
                    courseName: name,
                    teacher: "",
                    candidates: candidates
                ) else {
                    throw CourseLookupError.notFound
                }
                deepLinkedCourse = course
            } catch let error as CourseLookupError {
                deepLinkAlert = AppAlert(title: "无法打开课程评价", message: error.localizedDescription)
            } catch {
                deepLinkAlert = AppAlert(title: "无法打开课程评价", message: error.localizedDescription)
            }
        } else {
            do {
                let detail = try await CourseService().fetchCourse(id: request.courseID)
                deepLinkedCourse = CourseSummary(detail: detail)
            } catch {
                deepLinkAlert = AppAlert(title: "无法打开课程", message: error.localizedDescription)
            }
        }

        // 与话题入口相同，提前改变 `.task(id:)` 的 id 会取消正在进行的网络请求。
        if requestedCourse?.id == request.id {
            requestedCourse = nil
        }
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

private enum CourseLookupError: LocalizedError {
    case missingIdentity
    case notFound

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            return "成绩记录缺少课程号和课程名。"
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
        HStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 6) {
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
                height: AppDesignSystem.Size.compactPrimaryRowHeight
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
                height: AppDesignSystem.Size.compactSecondaryRowHeight
            )
        }
    }
}
