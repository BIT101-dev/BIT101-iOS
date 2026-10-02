import ScoreDomain
import CourseFeature
import MediaKit
import ScoreFeature
import ScheduleDomain
import DesignSystemKit
import SwiftUI

private enum ScoreSurface: String, CaseIterable, Identifiable, Hashable {
    case score
    case course

    var id: String { rawValue }

    var title: String {
        switch self {
        case .score:
            return "成绩"
        case .course:
            return "课程"
        }
    }
}

/// 成绩与课程合并主页。
///
/// 页面提供“成绩 / 课程”的顶部切换。
struct ScoreRootView: View {
    @Environment(AppCommunityDestinations.self) private var destinations
    private let courses: CourseDependencies
    @EnvironmentObject private var scoreViewModel: ScoreViewModel
    @StateObject private var courseViewModel: CourseListViewModel
    private let transcriptService: any TrustedTranscriptServicing
    @State private var selectedSurface: ScoreSurface = .score
    @Binding private var requestedCourse: CourseNavigationRequest?

    init(
        courses: CourseDependencies,
        transcriptService: any TrustedTranscriptServicing,
        requestedCourse: Binding<CourseNavigationRequest?> = .constant(nil)
    ) {
        self.courses = courses
        _courseViewModel = StateObject(wrappedValue: courses.makeListViewModel())
        self.transcriptService = transcriptService
        _requestedCourse = requestedCourse
    }

    var body: some View {
        ZStack {
            switch selectedSurface {
            case .score:
                ScoreListPage(
                    viewModel: scoreViewModel,
                    transcriptService: transcriptService,
                    onSearchCourse: openCourseSearch
                )
                    .simultaneousGesture(surfaceSwitchGesture)
                    .transition(.opacity)
            case .course:
                CoursePageContent(viewModel: courseViewModel, dependencies: courses, media: destinations.media, profiles: destinations.profiles)
                    .simultaneousGesture(surfaceSwitchGesture)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: selectedSurface)
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            AppTopSegmentedPicker(title: "成绩内容", selection: surfaceSelection) {
                ForEach(ScoreSurface.allCases) { surface in
                    Text(surface.title).tag(surface)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $requestedCourse) { request in
            if let preparedCourse = request.preparedCourse {
                CourseDetailView(dependencies: courses, media: destinations.media, profiles: destinations.profiles, initialCourse: preparedCourse)
                    .id(preparedCourse.id)
            } else {
                CourseEvaluationDestination(dependencies: courses, media: destinations.media, profiles: destinations.profiles, request: request)
            }
        }
        .task(id: requestedCourse?.id) {
            guard let requestedCourse else { return }
            selectedSurface = .course
            prepareCourseSurface(requestedCourse)
        }
    }

    /// 成绩记录缺少教师字段时，页面进入课程搜索页，由用户选择具体教师。
    private func openCourseSearch(_ courseName: String) {
        selectedSurface = .course
        requestedCourse = nil
        Task {
            await courseViewModel.search(for: courseName)
        }
    }

    private func prepareCourseSurface(_ request: CourseNavigationRequest) {
        guard let query = request.searchQuery,
              let results = request.searchResults
        else { return }
        courseViewModel.applyPreparedSearch(query: query, items: results)
    }

    /// 页面使用受控绑定切换顶部 segmented 分区。
    ///
    /// 点击和滑动切换都调用同一条分区切换路径并播放动画。
    private var surfaceSelection: Binding<ScoreSurface> {
        Binding(
            get: { selectedSurface },
            set: { newSurface in
                switchSurface(to: newSurface)
            }
        )
    }

    /// 该手势使用左右轻扫切换分区。
    private var surfaceSwitchGesture: some Gesture {
        makeHorizontalSwitchGesture(onStep: switchSurface)
    }

    /// 该方法按步长将当前分区切换到相邻分区。
    private func switchSurface(step: Int) {
        let allSurfaces = ScoreSurface.allCases
        guard let currentIndex = allSurfaces.firstIndex(of: selectedSurface) else { return }

        let nextIndex = currentIndex + step
        guard allSurfaces.indices.contains(nextIndex) else { return }

        switchSurface(to: allSurfaces[nextIndex])
    }

    /// 该方法切换指定分区并播放渐变动画。
    private func switchSurface(to surface: ScoreSurface) {
        guard surface != selectedSurface else { return }

        withAnimation(.easeInOut) {
            selectedSurface = surface
        }
    }
}
