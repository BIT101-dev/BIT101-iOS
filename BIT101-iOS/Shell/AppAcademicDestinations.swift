import ScoreDomain
import ScorePorts
import CourseFeature
import MediaKit
import ScoreFeature
import ScheduleDomain
import DesignSystemKit
import SwiftUI

enum ScoreSurface: String, CaseIterable, Identifiable, Hashable {
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

/// 成绩与课程入口共享分区选择与课程路由，各自沿原生浏览分栏呈现。
struct ScoreRootView: View {
    private let scene: ScoreRootScene
    private let identity: ObjectIdentifier

    init(courses: CourseDependencies, transcriptService: any TrustedTranscriptServicing,
         requestedCourse: Binding<CourseNavigationRequest?> = .constant(nil), selection: Binding<ScoreSurface>? = nil,
         showingCourses: Bool? = nil) {
        scene = ScoreRootScene(courses: courses, transcriptService: transcriptService, requestedCourse: requestedCourse,
            selection: selection, showingCourses: showingCourses)
        identity = ObjectIdentifier(courses)
    }

    var body: some View { scene.id(identity) }
}

private struct ScoreRootScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppCommunityDestinations.self) private var destinations
    private let courses: CourseDependencies
    @EnvironmentObject private var scoreViewModel: ScoreViewModel
    @StateObject private var courseViewModel: CourseListViewModel
    private let transcriptService: any TrustedTranscriptServicing
    @Environment(\.appExpandedNavigation) private var expandedNavigation
    private let showingCourses: Bool?
    @State private var localSurface: ScoreSurface = .score
    private let selection: Binding<ScoreSurface>?
    private var selectedSurface: ScoreSurface {
        get { selection?.wrappedValue ?? localSurface }
        nonmutating set {
            if let selection { selection.wrappedValue = newValue }
            else { localSurface = newValue }
        }
    }
    @Binding private var requestedCourse: CourseNavigationRequest?

    init(
        courses: CourseDependencies,
        transcriptService: any TrustedTranscriptServicing,
        requestedCourse: Binding<CourseNavigationRequest?> = .constant(nil),
        selection: Binding<ScoreSurface>? = nil,
        showingCourses: Bool? = nil
    ) {
        self.courses = courses
        self.selection = selection
        self.showingCourses = showingCourses
        _courseViewModel = StateObject(wrappedValue: courses.makeListViewModel())
        self.transcriptService = transcriptService
        _requestedCourse = requestedCourse
    }

    var body: some View {
        Group {
            if displayedSurface == .score {
                ScoreListPage(viewModel: scoreViewModel, transcriptService: transcriptService,
                    onSurfaceStep: switchSurface, onSearchCourse: openCourseSearch)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("home.score-surface")
            } else {
                CourseBrowserPage(viewModel: courseViewModel, dependencies: courses, media: destinations.media,
                    profiles: destinations.profiles, selection: detailRequest, onSurfaceStep: switchSurface)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("home.course-surface")
            }
        }
        .accessibilityElement(children: .contain)
        .animation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion), value: selectedSurface)
        .safeAreaInset(edge: .top, spacing: AppDesignSystem.Spacing.none) {
            if !expandedNavigation { surfaceTabs }
        }
        .background(AppDesignSystem.Palette.Background.grouped)
        .task(id: requestedCourse?.id) {
            guard displayedSurface == .course, let requestedCourse else { return }
            selectedSurface = .course
            if requestedCourse.isSearchRequest, let query = requestedCourse.searchQuery {
                if requestedCourse.searchResults != nil { prepareCourseSurface(requestedCourse) }
                else { await courseViewModel.search(for: query) }
                if self.requestedCourse?.id == requestedCourse.id { self.requestedCourse = nil }
            } else {
                prepareCourseSurface(requestedCourse)
            }
        }
    }

    private var displayedSurface: ScoreSurface {
        showingCourses.map { $0 ? .course : .score } ?? selectedSurface
    }

    private var surfaceTabs: some View {
        AppTopSegmentedPicker(title: "成绩内容", selection: surfaceSelection) {
            ForEach(ScoreSurface.allCases) { surface in Text(surface.title).tag(surface) }
        }
    }

    private var detailRequest: Binding<CourseNavigationRequest?> {
        Binding(get: { requestedCourse?.isSearchRequest == true ? nil : requestedCourse },
            set: { requestedCourse = $0 })
    }

    /// 成绩记录缺少教师字段时，页面进入课程搜索页，由用户选择具体教师。
    private func openCourseSearch(_ courseName: String) {
        selectedSurface = .course
        requestedCourse = .search(query: courseName)
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

    /// 该方法按步长将当前分区切换到相邻分区。
    private func switchSurface(step: Int) {
        guard !expandedNavigation else { return }
        let allSurfaces = ScoreSurface.allCases
        guard let currentIndex = allSurfaces.firstIndex(of: selectedSurface) else { return }

        let nextIndex = currentIndex + step
        guard allSurfaces.indices.contains(nextIndex) else { return }

        switchSurface(to: allSurfaces[nextIndex])
    }

    /// 该方法切换指定分区并播放渐变动画。
    private func switchSurface(to surface: ScoreSurface) {
        guard surface != selectedSurface else { return }

        withAnimation(AppDesignSystem.Motion.transition(reduceMotion: reduceMotion)) {
            selectedSurface = surface
        }
    }
}
