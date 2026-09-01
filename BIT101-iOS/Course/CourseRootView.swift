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
                ProgressView(viewModel.hasActiveSearch ? "正在搜索课程" : "正在加载课程")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))

            case let .failed(message) where viewModel.state.items.isEmpty:
                ContentUnavailableView {
                    Label(viewModel.hasActiveSearch ? "搜索失败" : "加载失败", systemImage: "books.vertical.circle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重新加载") {
                        Task {
                            await viewModel.refresh()
                        }
                    }
                    DiagnosticRecoveryActions(
                        title: viewModel.hasActiveSearch ? "搜索失败" : "加载失败",
                        message: message
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))

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
                .listStyle(.insetGrouped)
                .background(Color(.systemGroupedBackground))
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .onChange(of: viewModel.searchText) { oldValue, newValue in
            viewModel.clearSearchIfNeeded(from: oldValue, to: newValue)
        }
        .diagnosticAlert(item: $viewModel.alert)
        .diagnosticAlert(item: $deepLinkAlert)
        .navigationDestination(item: $deepLinkedCourse) { course in
            CourseDetailView(initialCourse: course)
        }
        .task(id: requestedCourse?.id) {
            await openRequestedCourseIfNeeded()
        }
        .background(Color(.systemGroupedBackground))
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
                ContentUnavailableView(
                    "没有找到课程",
                    systemImage: "magnifyingglass",
                    description: Text("换个关键词试试。")
                )
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "暂无课程",
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
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 6)
            }
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
            CourseFixedColumnRow(
                items: [
                    CourseFixedColumnItem(
                        text: course.name.isEmpty ? "未命名课程" : course.name,
                        ratio: 0.64,
                        font: .headline,
                        color: .primary
                    ),
                    CourseFixedColumnItem(
                        text: CourseRatingText.text(from: course.rate, empty: "-"),
                        ratio: 0.16,
                        font: .subheadline.weight(.semibold),
                        color: .orange,
                        alignment: .trailing
                    ),
                    CourseFixedColumnItem(
                        text: "\(course.commentNum)评",
                        ratio: 0.20,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: 22
            )

            CourseFixedColumnRow(
                items: [
                    CourseFixedColumnItem(
                        text: course.number.isEmpty ? "-" : course.number,
                        ratio: 0.30,
                        font: .caption,
                        color: .secondary
                    ),
                    CourseFixedColumnItem(
                        text: course.teachersName.isEmpty ? "-" : course.teachersName,
                        ratio: 0.45,
                        font: .caption,
                        color: .secondary
                    ),
                    CourseFixedColumnItem(
                        text: "\(course.likeNum)赞",
                        ratio: 0.25,
                        font: .caption,
                        color: .secondary,
                        alignment: .trailing
                    ),
                ],
                height: 20
            )
        }
    }
}

/// 课程列表固定比例列。
private struct CourseFixedColumnItem {
    let text: String
    let ratio: CGFloat
    let font: Font
    let color: Color
    var alignment: Alignment = .leading
}

/// 按固定比例分配宽度的一行文本。
private struct CourseFixedColumnRow: View {
    let items: [CourseFixedColumnItem]
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Text(item.text)
                        .font(item.font)
                        .foregroundStyle(item.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .monospacedDigit()
                        .frame(
                            width: totalWidth * item.ratio,
                            height: height,
                            alignment: item.alignment
                        )
                }
            }
        }
        .frame(height: height)
    }
}
